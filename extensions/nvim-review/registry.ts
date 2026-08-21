import { createHash, randomBytes } from "node:crypto";
import { chmod, lstat, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { tmpdir, userInfo } from "node:os";
import { join, resolve } from "node:path";

import type { BridgeManifest } from "./protocol";

const DIRECTORY_MODE = 0o700;
const FILE_MODE = 0o600;

function userKey(): string {
  const identity = typeof process.getuid === "function" ? String(process.getuid()) : userInfo().username;
  return identity.replace(/[^A-Za-z0-9_.-]/g, "_");
}

export function registryDirectory(): string {
  const override = process.env.PI_NVIM_REGISTRY;
  return override ? resolve(override) : join(tmpdir(), `pi-nvim-${userKey()}`);
}

async function ensureRegistryDirectory(): Promise<string> {
  const directory = registryDirectory();
  await mkdir(directory, { recursive: true, mode: DIRECTORY_MODE });

  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`Registry path is not a safe directory: ${directory}`);
  }

  await chmod(directory, DIRECTORY_MODE);
  return directory;
}

export function manifestFilename(sessionId: string): string {
  return `${createHash("sha256").update(sessionId).digest("hex")}.json`;
}

export async function writeManifest(manifest: BridgeManifest): Promise<string> {
  const directory = await ensureRegistryDirectory();
  const target = join(directory, manifestFilename(manifest.sessionId));
  const temporary = join(directory, `.${manifestFilename(manifest.sessionId)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`);
  const contents = `${JSON.stringify(manifest)}\n`;

  let installed = false;
  try {
    await writeFile(temporary, contents, { encoding: "utf8", flag: "wx", mode: FILE_MODE });
    await chmod(temporary, FILE_MODE);
    await rename(temporary, target);
    installed = true;
    await chmod(target, FILE_MODE);
  } catch (error) {
    await unlink(installed ? target : temporary).catch(() => undefined);
    throw error;
  }

  return target;
}

export async function removeManifest(path: string | undefined, token: string): Promise<void> {
  if (!path) return;

  try {
    const current = JSON.parse(await readFile(path, "utf8")) as { token?: unknown };
    if (current.token !== token) return;
    await unlink(path);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") throw error;
  }
}
