#!/usr/bin/env node

import { randomBytes, createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argumentIndex = process.argv.indexOf("--data-dir");
if (argumentIndex >= 0 && !process.argv[argumentIndex + 1]) throw new Error("--data-dir requires a path.");
const stateHome = process.env.XDG_STATE_HOME || (process.env.HOME ? path.join(process.env.HOME, ".local", "state") : null);
const defaultDataDir = stateHome ? path.join(stateHome, "opencode", "openclient", "notifications") : path.join(root, ".data");
const dataDir = path.resolve(argumentIndex >= 0 ? process.argv[argumentIndex + 1] : process.env.DATA_DIR || defaultDataDir);

if (process.argv[2] !== "pair") {
  console.error("Usage: openclient-notify pair [--data-dir PATH]");
  process.exitCode = 1;
} else {
  const code = randomBytes(5).toString("hex").toUpperCase();
  const record = {
    hash: createHash("sha256").update(code).digest("hex"),
    expiresAt: Date.now() + 10 * 60_000
  };
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  await writeFile(path.join(dataDir, "pairing.json"), JSON.stringify(record), { mode: 0o600 });
  console.log(`Pairing code (valid 10 minutes, one use): ${code}`);
}
