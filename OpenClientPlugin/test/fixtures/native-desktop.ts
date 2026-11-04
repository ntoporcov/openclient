import { startVNCFixture } from "./vnc-server.js"
import { startBridgeServer } from "../../src/bridge-server.js"

// Explicit local-only fixture for the native integration test. No real desktop.
const fixture = await startVNCFixture({ username: "fixture-user", password: "fixture-password" })
const bridge = startBridgeServer({ openCodePort: 65533, remoteDesktopURL: `vnc://127.0.0.1:${fixture.port}`,
  remoteDesktopToken: "fixture-only-token-32-characters-long" })
const inspection = Bun.serve({ hostname: "127.0.0.1", port: 14079, async fetch(request) {
  const ticket = new URL(request.url).pathname === "/session" ? await bridge.remoteDesktop.ticket() : undefined
  return Response.json({ fixture: "native-desktop", events: fixture.events,
    viewerURL: ticket ? `http://127.0.0.1:${bridge.port}/openclient/v1/desktop/viewer#ticket=${ticket}` : undefined })
} })
console.log(`Native desktop fixture ready (PID ${process.pid})`)
process.on("SIGTERM", async () => { inspection.stop(true); await bridge.stop(); await fixture.stop(); process.exit(0) })
