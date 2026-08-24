import { createHash, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer, type Server, type Socket } from "node:net";
import { join } from "node:path";

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
  type SubmittedResponse,
  type SubmitRequest,
} from "./protocol";
import { removeManifest, writeManifest } from "./registry";

const CONNECTION_TIMEOUT_MS = 5000;
const RESULT_CACHE_SIZE = 128;
const REVIEW_PROMPT_PATH = ".pi/nvim-review-prompt.md";
const DEFAULT_REVIEW_INSTRUCTIONS = [
  "Process each review comment independently according to its requested outcome.",
  "",
  "- If a comment asks for an explanation or information, answer it directly. Do not modify files for that comment.",
  "- If a comment requests a code change, implement it.",
  "- If a comment contains both a question and a change request, answer the question and implement only the explicit change.",
  "- If the intent is ambiguous, explain the ambiguity and ask for clarification instead of making a speculative change.",
  "- Classify by meaning, not grammar or punctuation. For example, \"Can you rename this?\" is a change request, while \"Can you explain this?\" is a question.",
  "",
  "Inspect the current files before answering or editing. Source excerpts can contain unsaved or outdated buffer text.",
  "",
  "In the final response, use separate sections for changes made, questions answered, and comments that need clarification.",
].join("\n");

export type BridgeState = "starting" | "running" | "stopping" | "stopped";

export interface ReviewBridgeOptions {
  sessionId: string;
  shortId: string;
  projectRoot: string;
  sessionName?: string;
  token: string;
  onSubmit: (prompt: string, count: number) => Promise<DeliveryStatus> | DeliveryStatus;
  onError?: (error: Error) => void;
}

interface RequestContext {
  controller: AbortController;
  deliveryStarted: boolean;
}

interface CachedResult {
  fingerprint: string;
  response: SubmittedResponse;
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

async function readReviewInstructions(projectRoot: string, signal: AbortSignal): Promise<string> {
  const promptPath = join(projectRoot, REVIEW_PROMPT_PATH);

  try {
    return (await readFile(promptPath, { encoding: "utf8", signal })).trim();
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return DEFAULT_REVIEW_INSTRUCTIONS;
    }

    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Could not read ${REVIEW_PROMPT_PATH}: ${message}`);
  }
}

function formatReviewPrompt(
  projectRoot: string,
  annotations: ReviewAnnotation[],
  instructions: string,
): string {
  const lines = instructions === "" ? [] : [instructions, ""];
  lines.push(`Project root: ${JSON.stringify(projectRoot)}`, "");

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

function submissionFingerprint(request: SubmitRequest): string {
  const canonical = request.annotations.map((annotation) => [
    annotation.path,
    annotation.startLine,
    annotation.endLine,
    annotation.comment,
    annotation.source,
  ]);
  return createHash("sha256").update(JSON.stringify(canonical)).digest("hex");
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

export class ReviewBridge {
  private readonly options: ReviewBridgeOptions;
  private readonly server: Server;
  private readonly sockets = new Set<Socket>();
  private readonly handlers = new Set<Promise<void>>();
  private readonly requestContexts = new Set<RequestContext>();
  private readonly resultCache = new Map<string, CachedResult>();
  private state: BridgeState = "stopped";
  private manifest?: BridgeManifest;
  private manifestPath?: string;
  private manifestWrites: Promise<void> = Promise.resolve();
  private activeSubmissionId?: string;
  private startPromise?: Promise<BridgeManifest>;
  private stopPromise?: Promise<void>;

  constructor(options: ReviewBridgeOptions) {
    this.options = options;
    this.server = createServer((socket) => this.accept(socket));
    this.server.on("error", (error) => {
      if (this.state === "running") this.options.onError?.(error);
    });
  }

  isActive(): boolean {
    return this.state === "running";
  }

  getState(): BridgeState {
    return this.state;
  }

  getManifest(): BridgeManifest | undefined {
    return this.manifest;
  }

  async start(): Promise<BridgeManifest> {
    if (this.state === "running" && this.manifest) return this.manifest;
    if (this.state === "starting" && this.startPromise) return this.startPromise;
    if (this.state === "stopping") throw new Error("Pi Neovim bridge is stopping");

    this.state = "starting";
    this.stopPromise = undefined;
    this.startPromise = (async () => {
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

      if (this.state !== "starting") throw new Error("Pi Neovim bridge stopped while starting");
      const address = this.server.address();
      if (!address || typeof address === "string") {
        throw new Error("Pi Neovim bridge did not receive a TCP port");
      }

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
      this.manifestPath = await writeManifest(manifest);
      if (this.state !== "starting") throw new Error("Pi Neovim bridge stopped while starting");
      this.manifest = manifest;
      this.state = "running";
      return manifest;
    })();

    try {
      return await this.startPromise;
    } catch (error) {
      if (this.state !== "stopping") this.state = "stopped";
      await this.closeServer();
      throw error;
    } finally {
      this.startPromise = undefined;
    }
  }

  async updateSessionName(sessionName: string | undefined): Promise<void> {
    if (this.state !== "running" || !this.manifest) return;

    this.manifest = {
      ...this.manifest,
      sessionName: sessionName || undefined,
    };

    this.manifestWrites = this.manifestWrites.then(async () => {
      if (this.state !== "running" || !this.manifest) return;
      this.manifestPath = await writeManifest(this.manifest);
    });

    return this.manifestWrites;
  }

  async stop(): Promise<void> {
    if (this.state === "stopped" && !this.manifestPath) return;
    if (this.state === "stopping" && this.stopPromise) return this.stopPromise;

    this.state = "stopping";
    this.stopPromise = (async () => {
      await this.startPromise?.catch(() => undefined);
      await this.manifestWrites.catch(() => undefined);

      // Work that has not entered onSubmit is cancelled. Once delivery starts,
      // shutdown drains it so that bridge state cannot move backwards while Pi
      // is accepting the review.
      for (const context of this.requestContexts) {
        if (!context.deliveryStarted) context.controller.abort();
      }
      for (const socket of this.sockets) socket.destroy();
      this.sockets.clear();
      await this.closeServer();
      await Promise.allSettled([...this.handlers]);
      await removeManifest(this.manifestPath, this.options.token);
      this.manifestPath = undefined;
      this.manifest = undefined;
      this.activeSubmissionId = undefined;
      this.resultCache.clear();
      this.state = "stopped";
    })();

    return this.stopPromise;
  }

  private accept(socket: Socket): void {
    if (this.state !== "running") {
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
    let requestStarted = false;
    let responded = false;

    const respond = (response: BridgeResponse) => {
      if (responded || socket.destroyed) return;
      responded = true;
      socket.end(`${JSON.stringify(response)}\n`);
    };

    socket.on("data", (chunk: string | Buffer) => {
      if (requestStarted || responded) return;
      const text = typeof chunk === "string" ? chunk : chunk.toString("utf8");
      bytes += Buffer.byteLength(text);
      if (bytes > MAX_REQUEST_BYTES) {
        respond(errorResponse("invalid_request", "Request is too large", false));
        return;
      }

      contents += text;
      const newline = contents.indexOf("\n");
      if (newline < 0) return;

      requestStarted = true;
      socket.pause();
      const requestLine = contents.slice(0, newline);
      if (contents.slice(newline + 1).trim().length > 0) {
        respond(errorResponse("invalid_request", "Only one request is allowed per connection", false));
        return;
      }

      const context: RequestContext = { controller: new AbortController(), deliveryStarted: false };
      this.requestContexts.add(context);
      let handler: Promise<void>;
      handler = this.handleRequestLine(requestLine, context)
        .then(respond)
        .catch((error: unknown) => {
          const message = error instanceof Error ? error.message : String(error);
          respond(errorResponse("internal_error", message, true, { sessionId: this.options.sessionId }));
        })
        .finally(() => {
          this.requestContexts.delete(context);
          this.handlers.delete(handler);
        });
      this.handlers.add(handler);
    });

    socket.once("end", () => {
      if (!requestStarted && !responded) {
        respond(errorResponse("invalid_request", "Request must end with a newline", false));
      }
    });
    socket.once("error", () => socket.destroy());
  }

  private async handleRequestLine(line: string, context: RequestContext): Promise<BridgeResponse> {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch {
      return errorResponse("invalid_json", "Request is not valid JSON", false);
    }

    const parsed = parseRequest(raw);
    if (!parsed.ok) {
      return errorResponse(parsed.code, parsed.message, false, {
        sessionId: parsed.sessionId,
        submissionId: parsed.submissionId,
      });
    }

    const request = parsed.request;
    const responseContext = {
      sessionId: request.sessionId,
      ...(request.type === "submit" ? { submissionId: request.submissionId } : {}),
    };
    if (!tokensMatch(request.token, this.options.token)) {
      return errorResponse("authentication_failed", "Authentication failed", false, responseContext);
    }
    if (request.sessionId !== this.options.sessionId || request.projectRoot !== this.options.projectRoot) {
      return errorResponse("stale_session", "Session does not match this bridge", false, responseContext);
    }
    if (this.state !== "running" || context.controller.signal.aborted) {
      return errorResponse("bridge_stopping", "Bridge is shutting down", true, responseContext);
    }

    if (request.type === "ping") {
      return {
        protocolVersion: PROTOCOL_VERSION,
        ok: true,
        type: "pong",
        sessionId: this.options.sessionId,
      };
    }

    const fingerprint = submissionFingerprint(request);
    const cached = this.resultCache.get(request.submissionId);
    if (cached) {
      if (cached.fingerprint !== fingerprint) {
        return errorResponse(
          "invalid_request",
          "Submission ID was already used for different content",
          false,
          responseContext,
        );
      }
      return cached.response;
    }

    if (this.activeSubmissionId) {
      return errorResponse(
        "busy",
        `Submission ${this.activeSubmissionId} is still being delivered`,
        true,
        responseContext,
      );
    }

    this.activeSubmissionId = request.submissionId;
    try {
      const instructions = await readReviewInstructions(this.options.projectRoot, context.controller.signal);
      if (this.state !== "running" || context.controller.signal.aborted) {
        return errorResponse("bridge_stopping", "Bridge is shutting down", true, responseContext);
      }

      const prompt = formatReviewPrompt(this.options.projectRoot, request.annotations, instructions);
      context.deliveryStarted = true;
      const status = await this.options.onSubmit(prompt, request.annotations.length);
      const response: SubmittedResponse = {
        protocolVersion: PROTOCOL_VERSION,
        ok: true,
        type: "submitted",
        sessionId: this.options.sessionId,
        submissionId: request.submissionId,
        status,
        count: request.annotations.length,
      };
      this.cacheResult(request.submissionId, fingerprint, response);
      return response;
    } catch (error) {
      if (isAbortError(error) || context.controller.signal.aborted || this.state !== "running") {
        return errorResponse("bridge_stopping", "Bridge is shutting down", true, responseContext);
      }
      const message = error instanceof Error ? error.message : String(error);
      return errorResponse("internal_error", `Pi did not accept the review: ${message}`, true, responseContext);
    } finally {
      if (this.activeSubmissionId === request.submissionId) this.activeSubmissionId = undefined;
    }
  }

  private cacheResult(submissionId: string, fingerprint: string, response: SubmittedResponse): void {
    this.resultCache.set(submissionId, { fingerprint, response });
    while (this.resultCache.size > RESULT_CACHE_SIZE) {
      const oldest = this.resultCache.keys().next().value as string | undefined;
      if (!oldest) break;
      this.resultCache.delete(oldest);
    }
  }

  private async closeServer(): Promise<void> {
    if (!this.server.listening) return;
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}
