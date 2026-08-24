import { posix } from "node:path";

export const PROTOCOL_VERSION = 2;
export const LOOPBACK_HOST = "127.0.0.1";
export const MAX_REQUEST_BYTES = 1024 * 1024;
export const MAX_RESPONSE_BYTES = 64 * 1024;
export const MAX_ANNOTATIONS = 200;
export const MAX_PATH_CHARS = 4096;
export const MAX_COMMENT_CHARS = 16 * 1024;
export const MAX_SOURCE_CHARS = 64 * 1024;
export const MAX_SOURCE_LINES = 1000;
export const MAX_LINE_NUMBER = 10_000_000;
export const MAX_SUBMISSION_ID_CHARS = 128;

export interface BridgeManifest {
  protocolVersion: typeof PROTOCOL_VERSION;
  sessionId: string;
  shortId: string;
  projectRoot: string;
  pid: number;
  host: typeof LOOPBACK_HOST;
  port: number;
  token: string;
  startedAt: string;
  sessionName?: string;
}

export interface ReviewAnnotation {
  path: string;
  startLine: number;
  endLine: number;
  comment: string;
  source: string[];
}

interface RequestBase {
  protocolVersion: typeof PROTOCOL_VERSION;
  token: string;
  sessionId: string;
  projectRoot: string;
}

export interface PingRequest extends RequestBase {
  type: "ping";
}

export interface SubmitRequest extends RequestBase {
  type: "submit";
  submissionId: string;
  annotations: ReviewAnnotation[];
}

export type BridgeRequest = PingRequest | SubmitRequest;
export type DeliveryStatus = "accepted" | "queued";

export interface PongResponse {
  protocolVersion: typeof PROTOCOL_VERSION;
  ok: true;
  type: "pong";
  sessionId: string;
}

export interface SubmittedResponse {
  protocolVersion: typeof PROTOCOL_VERSION;
  ok: true;
  type: "submitted";
  sessionId: string;
  submissionId: string;
  status: DeliveryStatus;
  count: number;
}

export type SuccessResponse = PongResponse | SubmittedResponse;

export type ErrorCode =
  | "invalid_json"
  | "incompatible_version"
  | "invalid_request"
  | "authentication_failed"
  | "stale_session"
  | "bridge_stopping"
  | "busy"
  | "timeout"
  | "transport_error"
  | "invalid_response"
  | "internal_error";

export interface ErrorResponse {
  protocolVersion: typeof PROTOCOL_VERSION;
  ok: false;
  code: ErrorCode;
  message: string;
  retryable: boolean;
  sessionId?: string;
  submissionId?: string;
}

export type BridgeResponse = SuccessResponse | ErrorResponse;

export type RequestParseResult =
  | { ok: true; request: BridgeRequest }
  | {
    ok: false;
    code: "incompatible_version" | "invalid_request";
    message: string;
    sessionId?: string;
    submissionId?: string;
  };

const BASE_KEYS = ["protocolVersion", "type", "token", "sessionId", "projectRoot"] as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(record: Record<string, unknown>, allowed: readonly string[]): boolean {
  const allowedSet = new Set(allowed);
  return Object.keys(record).every((key) => allowedSet.has(key));
}

function isNonEmptyString(value: unknown, maxChars: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxChars;
}

function isPositiveInteger(value: unknown, maximum: number): value is number {
  return Number.isInteger(value) && (value as number) > 0 && (value as number) <= maximum;
}

function isSubmissionId(value: unknown): value is string {
  return isNonEmptyString(value, MAX_SUBMISSION_ID_CHARS)
    && /^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(value);
}

function isSafeRelativePath(value: unknown): value is string {
  if (!isNonEmptyString(value, MAX_PATH_CHARS)) return false;
  if (/^[\x00-\x1f]/.test(value) || /[\x00-\x1f]/.test(value)) return false;
  if (value.includes("\\") || posix.isAbsolute(value)) return false;

  const normalized = posix.normalize(value);
  return normalized === value && normalized !== "." && normalized !== ".." && !normalized.startsWith("../");
}

function validateAnnotation(value: unknown): value is ReviewAnnotation {
  if (!isRecord(value)) return false;
  if (!hasOnlyKeys(value, ["path", "startLine", "endLine", "comment", "source"])) return false;
  if (!isSafeRelativePath(value.path)) return false;
  if (!isPositiveInteger(value.startLine, MAX_LINE_NUMBER)) return false;
  if (!isPositiveInteger(value.endLine, MAX_LINE_NUMBER)) return false;
  if (value.endLine < value.startLine) return false;
  if (value.endLine - value.startLine + 1 > MAX_SOURCE_LINES) return false;
  if (!isNonEmptyString(value.comment, MAX_COMMENT_CHARS) || value.comment.trim().length === 0) return false;
  if (!Array.isArray(value.source) || value.source.length !== value.endLine - value.startLine + 1) return false;
  if (
    value.source.length > MAX_SOURCE_LINES
    || !value.source.every((line) => typeof line === "string" && !line.includes("\n") && !line.includes("\r"))
  ) return false;

  const sourceChars = value.source.reduce((total, line) => total + line.length + 1, 0);
  return sourceChars <= MAX_SOURCE_CHARS;
}

export function parseRequest(value: unknown): RequestParseResult {
  if (!isRecord(value)) {
    return { ok: false, code: "invalid_request", message: "Request must be a JSON object" };
  }

  const sessionId = typeof value.sessionId === "string" ? value.sessionId.slice(0, 256) : undefined;
  const submissionId = typeof value.submissionId === "string"
    ? value.submissionId.slice(0, MAX_SUBMISSION_ID_CHARS)
    : undefined;

  if (value.protocolVersion !== PROTOCOL_VERSION) {
    return {
      ok: false,
      code: "incompatible_version",
      message: `Protocol version ${String(value.protocolVersion)} is not supported`,
      ...(sessionId ? { sessionId } : {}),
      ...(submissionId ? { submissionId } : {}),
    };
  }
  if (!isNonEmptyString(value.token, 256)) {
    return { ok: false, code: "invalid_request", message: "Request token is invalid", sessionId, submissionId };
  }
  if (!isNonEmptyString(value.sessionId, 256)) {
    return { ok: false, code: "invalid_request", message: "Request session ID is invalid", submissionId };
  }
  if (!isNonEmptyString(value.projectRoot, MAX_PATH_CHARS)) {
    return { ok: false, code: "invalid_request", message: "Request project root is invalid", sessionId, submissionId };
  }

  if (value.type === "ping") {
    if (!hasOnlyKeys(value, BASE_KEYS)) {
      return { ok: false, code: "invalid_request", message: "Ping request has unknown fields", sessionId };
    }
    return { ok: true, request: value as unknown as PingRequest };
  }

  if (value.type === "submit") {
    if (!hasOnlyKeys(value, [...BASE_KEYS, "submissionId", "annotations"])) {
      return { ok: false, code: "invalid_request", message: "Submit request has unknown fields", sessionId, submissionId };
    }
    if (!isSubmissionId(value.submissionId)) {
      return { ok: false, code: "invalid_request", message: "Submission ID is invalid", sessionId, submissionId };
    }
    if (!Array.isArray(value.annotations) || value.annotations.length === 0 || value.annotations.length > MAX_ANNOTATIONS) {
      return { ok: false, code: "invalid_request", message: "Annotation count is invalid", sessionId, submissionId };
    }
    if (!value.annotations.every(validateAnnotation)) {
      return { ok: false, code: "invalid_request", message: "One or more annotations are invalid", sessionId, submissionId };
    }
    return { ok: true, request: value as unknown as SubmitRequest };
  }

  return { ok: false, code: "invalid_request", message: "Request type is invalid", sessionId, submissionId };
}

export function errorResponse(
  code: ErrorCode,
  message: string,
  retryable: boolean,
  context: { sessionId?: string; submissionId?: string } = {},
): ErrorResponse {
  return {
    protocolVersion: PROTOCOL_VERSION,
    ok: false,
    code,
    message: message.slice(0, 512),
    retryable,
    ...(context.sessionId ? { sessionId: context.sessionId.slice(0, 256) } : {}),
    ...(context.submissionId ? { submissionId: context.submissionId.slice(0, MAX_SUBMISSION_ID_CHARS) } : {}),
  };
}
