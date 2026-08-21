import { posix } from "node:path";

export const PROTOCOL_VERSION = 1;
export const LOOPBACK_HOST = "127.0.0.1";
export const MAX_REQUEST_BYTES = 1024 * 1024;
export const MAX_RESPONSE_BYTES = 64 * 1024;
export const MAX_ANNOTATIONS = 200;
export const MAX_PATH_CHARS = 4096;
export const MAX_COMMENT_CHARS = 16 * 1024;
export const MAX_SOURCE_CHARS = 64 * 1024;
export const MAX_SOURCE_LINES = 1000;
export const MAX_LINE_NUMBER = 10_000_000;

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
  annotations: ReviewAnnotation[];
}

export type BridgeRequest = PingRequest | SubmitRequest;

export type DeliveryStatus = "accepted" | "queued";

export interface SuccessResponse {
  protocolVersion: typeof PROTOCOL_VERSION;
  ok: true;
  type: "pong" | "submitted";
  sessionId: string;
  status?: DeliveryStatus;
  count?: number;
}

export interface ErrorResponse {
  protocolVersion: typeof PROTOCOL_VERSION;
  ok: false;
  error: string;
}

export type BridgeResponse = SuccessResponse | ErrorResponse;

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

export function parseRequest(value: unknown): BridgeRequest | undefined {
  if (!isRecord(value)) return undefined;
  if (value.protocolVersion !== PROTOCOL_VERSION) return undefined;
  if (!isNonEmptyString(value.token, 256)) return undefined;
  if (!isNonEmptyString(value.sessionId, 256)) return undefined;
  if (!isNonEmptyString(value.projectRoot, MAX_PATH_CHARS)) return undefined;

  if (value.type === "ping") {
    if (!hasOnlyKeys(value, BASE_KEYS)) return undefined;
    return value as unknown as PingRequest;
  }

  if (value.type === "submit") {
    if (!hasOnlyKeys(value, [...BASE_KEYS, "annotations"])) return undefined;
    if (!Array.isArray(value.annotations)) return undefined;
    if (value.annotations.length === 0 || value.annotations.length > MAX_ANNOTATIONS) return undefined;
    if (!value.annotations.every(validateAnnotation)) return undefined;
    return value as unknown as SubmitRequest;
  }

  return undefined;
}

export function errorResponse(error: string): ErrorResponse {
  return {
    protocolVersion: PROTOCOL_VERSION,
    ok: false,
    error: error.slice(0, 512),
  };
}
