import { createHash, timingSafeEqual } from "node:crypto";
import { createServer, type Server, type Socket } from "node:net";

import {
  LOOPBACK_HOST,
  MAX_REQUEST_BYTES,
  PROTOCOL_VERSION,
  errorResponse,
  parseRequest,
  type BridgeManifest,
  type BridgeResponse,
  type DeliveryStatus,
  type ReviewAnnotation,
} from "./protocol";
import { removeManifest, writeManifest } from "./registry";

const CONNECTION_TIMEOUT_MS = 5000;

export interface ReviewBridgeOptions {
  sessionId: string;
  shortId: string;
  projectRoot: string;
  sessionName?: string;
  token: string;
  onSubmit: (prompt: string, count: number) => Promise<DeliveryStatus> | DeliveryStatus;
  onError?: (error: Error) => void;
}

function tokensMatch(actual: string, expected: string): boolean {
  const actualDigest = createHash("sha256").update(actual).digest();
  const expectedDigest = createHash("sha256").update(expected).digest();
  return timingSafeEqual(actualDigest, expectedDigest);
}

function formatLocation(annotation: ReviewAnnotation): string {
  return annotation.startLine === annotation.endLine
    ? String(annotation.startLine)
    : `${annotation.startLine}-${annotation.endLine}`;
}

function formatReviewPrompt(projectRoot: string, annotations: ReviewAnnotation[]): string {
  const lines = [
    "Apply all code review comments below to the project.",
    "Inspect the current files before editing. The excerpts show what Neovim displayed when the review was submitted and can include unsaved buffer text.",
    "After you make the changes, briefly summarize what you changed and identify any comment that you could not apply.",
    "",
    `Project root: ${JSON.stringify(projectRoot)}`,
    "",
  ];

  annotations.forEach((annotation, index) => {
    const width = String(annotation.endLine).length;
    lines.push(`## Comment ${index + 1}`);
    lines.push(`File: ${JSON.stringify(annotation.path)}`);
    lines.push(`Lines: ${formatLocation(annotation)}`);
    lines.push("");
    lines.push("Review comment:");
    for (const commentLine of annotation.comment.split(/\r?\n/)) {
      lines.push(`> ${commentLine}`);
    }
    lines.push("");
    lines.push("Source excerpt:");
    annotation.source.forEach((sourceLine, sourceIndex) => {
      const lineNumber = String(annotation.startLine + sourceIndex).padStart(width, " ");
      lines.push(`    ${lineNumber} | ${sourceLine}`);
    });
    lines.push("");
  });

  return lines.join("\n").trimEnd();
}

export class ReviewBridge {
  private readonly options: ReviewBridgeOptions;
  private readonly server: Server;
  private readonly sockets = new Set<Socket>();
  private active = false;
  private manifest?: BridgeManifest;
  private manifestPath?: string;
  private manifestWrites: Promise<void> = Promise.resolve();

  constructor(options: ReviewBridgeOptions) {
    this.options = options;
    this.server = createServer((socket) => this.accept(socket));
  }

  isActive(): boolean {
    return this.active;
  }

  getManifest(): BridgeManifest | undefined {
    return this.manifest;
  }

  async start(): Promise<BridgeManifest> {
    if (this.active && this.manifest) return this.manifest;

    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        this.server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        this.server.off("error", onError);
        resolve();
      };

      this.server.once("error", onError);
      this.server.once("listening", onListening);
      this.server.listen(0, LOOPBACK_HOST);
    });

    this.server.on("error", (error) => this.options.onError?.(error));

    const address = this.server.address();
    if (!address || typeof address === "string") {
      await this.closeServer();
      throw new Error("Pi Neovim bridge did not receive a TCP port");
    }

    this.active = true;
    const manifest: BridgeManifest = {
      protocolVersion: PROTOCOL_VERSION,
      sessionId: this.options.sessionId,
      shortId: this.options.shortId,
      projectRoot: this.options.projectRoot,
      pid: process.pid,
      host: LOOPBACK_HOST,
      port: address.port,
      token: this.options.token,
      startedAt: new Date().toISOString(),
      ...(this.options.sessionName ? { sessionName: this.options.sessionName } : {}),
    };
    this.manifest = manifest;

    try {
      this.manifestPath = await writeManifest(manifest);
    } catch (error) {
      this.active = false;
      await this.closeServer();
      throw error;
    }

    return manifest;
  }

  async updateSessionName(sessionName: string | undefined): Promise<void> {
    if (!this.active || !this.manifest) return;

    this.manifest = {
      ...this.manifest,
      sessionName: sessionName || undefined,
    };

    this.manifestWrites = this.manifestWrites.then(async () => {
      if (!this.active || !this.manifest) return;
      this.manifestPath = await writeManifest(this.manifest);
    });

    return this.manifestWrites;
  }

  async stop(): Promise<void> {
    if (!this.active && !this.manifestPath) return;
    this.active = false;

    await this.manifestWrites.catch(() => undefined);
    for (const socket of this.sockets) socket.destroy();
    this.sockets.clear();
    await this.closeServer();
    await removeManifest(this.manifestPath, this.options.token);
    this.manifestPath = undefined;
  }

  private accept(socket: Socket): void {
    if (!this.active) {
      socket.destroy();
      return;
    }

    this.sockets.add(socket);
    socket.setEncoding("utf8");
    socket.setNoDelay(true);
    socket.setTimeout(CONNECTION_TIMEOUT_MS, () => socket.destroy());
    socket.once("close", () => this.sockets.delete(socket));

    let contents = "";
    let bytes = 0;
    let handled = false;

    const respond = (response: BridgeResponse) => {
      if (socket.destroyed) return;
      handled = true;
      socket.end(`${JSON.stringify(response)}\n`);
    };

    socket.on("data", (chunk: string | Buffer) => {
      if (handled) return;
      const text = typeof chunk === "string" ? chunk : chunk.toString("utf8");
      bytes += Buffer.byteLength(text);
      if (bytes > MAX_REQUEST_BYTES) {
        respond(errorResponse("Request is too large"));
        return;
      }

      contents += text;
      const newline = contents.indexOf("\n");
      if (newline < 0) return;

      socket.pause();
      const requestLine = contents.slice(0, newline);
      if (contents.slice(newline + 1).trim().length > 0) {
        respond(errorResponse("Only one request is allowed per connection"));
        return;
      }

      void this.handleRequestLine(requestLine).then(respond);
    });

    socket.once("end", () => {
      if (!handled) respond(errorResponse("Request must end with a newline"));
    });
    socket.once("error", () => {
      socket.destroy();
    });
  }

  private async handleRequestLine(line: string): Promise<BridgeResponse> {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch {
      return errorResponse("Request is not valid JSON");
    }

    const request = parseRequest(raw);
    if (!request) return errorResponse("Request does not match protocol version 1");
    if (!tokensMatch(request.token, this.options.token)) return errorResponse("Authentication failed");
    if (request.sessionId !== this.options.sessionId || request.projectRoot !== this.options.projectRoot) {
      return errorResponse("Session does not match this bridge");
    }
    if (!this.active) return errorResponse("Bridge is shutting down");

    if (request.type === "ping") {
      return {
        protocolVersion: PROTOCOL_VERSION,
        ok: true,
        type: "pong",
        sessionId: this.options.sessionId,
      };
    }

    try {
      const prompt = formatReviewPrompt(this.options.projectRoot, request.annotations);
      const status = await this.options.onSubmit(prompt, request.annotations.length);
      return {
        protocolVersion: PROTOCOL_VERSION,
        ok: true,
        type: "submitted",
        sessionId: this.options.sessionId,
        status,
        count: request.annotations.length,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return errorResponse(`Pi did not accept the review: ${message}`);
    }
  }

  private async closeServer(): Promise<void> {
    if (!this.server.listening) return;
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}
