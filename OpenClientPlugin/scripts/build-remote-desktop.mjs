import { mkdir, copyFile, cp } from "node:fs/promises"
import { spawnSync } from "node:child_process"

await mkdir("dist/remote-desktop-web", { recursive: true })
const result = spawnSync("bun", ["build", "remote-desktop-web/viewer.js", "--target=browser", "--minify", "--outfile=dist/remote-desktop-web/viewer.js"], { stdio: "inherit" })
if (result.status !== 0) process.exit(result.status ?? 1)
await copyFile("remote-desktop-web/index.html", "dist/remote-desktop-web/index.html")
await copyFile("node_modules/@novnc/novnc/LICENSE.txt", "dist/remote-desktop-web/noVNC-LICENSE.txt")
await cp("node_modules/@novnc/novnc/lib", "dist/remote-desktop-web/noVNC-source", { recursive: true })
