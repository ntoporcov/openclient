import { cp, mkdir, rm } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const sourceRoot = path.resolve(packageRoot, "../NotificationPWA")
const outputRoot = path.join(packageRoot, "dist", "notifications")

await import(path.join(sourceRoot, "scripts", "generate-icons.mjs"))
await rm(outputRoot, { recursive: true, force: true })
await mkdir(outputRoot, { recursive: true })
await Promise.all([
  cp(path.join(sourceRoot, "src"), path.join(outputRoot, "src"), { recursive: true }),
  cp(path.join(sourceRoot, "public"), path.join(outputRoot, "public"), { recursive: true }),
  cp(path.join(sourceRoot, "THIRD-PARTY-NOTICES.md"), path.join(outputRoot, "THIRD-PARTY-NOTICES.md")),
])
