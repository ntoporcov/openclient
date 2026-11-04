import { expect, test } from "bun:test"
import { createServer, type Socket } from "node:net"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { startBridgeServer } from "../src/bridge-server.js"
import { RemoteDesktopHandoffs } from "../src/remote-desktop-handoff.js"
import { RemoteDesktopSessions } from "../src/remote-desktop-session.js"
import { createOpenClientTools } from "../src/tools.js"
import type { DesktopHandoff } from "../src/remote-desktop-handoff.js"

const token = "test-only-remote-desktop-token-32-characters"

test("agent tool publishes a pending native card and returns only after explicit completion", async () => {
  const desktop = new RemoteDesktopSessions("vnc://localhost", token)
  desktop.capability = async () => ({ version: 1, transport: "rfb", state: "detected", viewerAvailable: true })
  const tools = createOpenClientTools({} as never, {} as never, {} as never, desktop)
  let publish!: (request: DesktopHandoff) => void
  const published = new Promise<DesktopHandoff>((resolve) => { publish = resolve })
  let finished = false
  const execution = tools.openclient_request_remote_access.execute({ reason: "Sign in to the test application" }, {
    sessionID: "session", messageID: "message", abort: new AbortController().signal,
    metadata(update: { metadata: { renderer: string; payload: DesktopHandoff } }) {
      expect(update.metadata.renderer).toBe("openclient.remote-desktop")
      publish(update.metadata.payload)
    },
  } as never).then((value) => { finished = true; return value })
  const request = await published
  expect(finished).toBe(false)
  expect(request.reason).toBe("Sign in to the test application")
  desktop.handoffs.complete(request.requestID, request.sessionID, request.messageID, "done")
  const result = await execution as { output: string }
  expect(JSON.parse(result.output)).toEqual({ outcome: "done" })
  expect(finished).toBe(true)
})

test("desktop auth requires explicit strong configuration and rejects browser-origin ticket minting", () => {
  const sessions = new RemoteDesktopSessions("vnc://localhost", token)
  expect(sessions.authorized(new Request("http://localhost", { headers: { authorization: `Bearer ${token}` } }))).toBe(true)
  expect(sessions.authorized(new Request("http://localhost", { headers: { authorization: `Bearer ${token}`, origin: "http://localhost" } }))).toBe(false)
  expect(sessions.authorized(new Request("http://localhost", { headers: { authorization: "Bearer wrong" } }))).toBe(false)
  expect(new RemoteDesktopSessions("vnc://localhost", "short").enabled).toBe(false)
  expect(new RemoteDesktopSessions(undefined, token).enabled).toBe(false)
})

test("handoff completion is bound to its chat and message and only resolves once", async () => {
  const manager = new RemoteDesktopHandoffs()
  const { request, result } = manager.request({ sessionID: "session", messageID: "message", reason: "Sign in" }, new AbortController().signal)
  expect(manager.complete(request.requestID, "other", "message", "done")).toBe(false)
  expect(manager.complete(request.requestID, "session", "other", "done")).toBe(false)
  expect(manager.complete(request.requestID, "session", "message", "done")).toBe(true)
  expect(await result).toBe("done")
  expect(manager.complete(request.requestID, "session", "message", "done")).toBe(false)
})

test("handoffs cancel on abort and plugin shutdown", async () => {
  const manager = new RemoteDesktopHandoffs()
  const controller = new AbortController()
  const aborted = manager.request({ sessionID: "session", messageID: "message", reason: "Sign in" }, controller.signal)
  controller.abort()
  await expect(aborted.result).rejects.toThrow("aborted")
  expect(manager.complete(aborted.request.requestID, "session", "message", "done")).toBe(false)
  const stopped = manager.request({ sessionID: "session", messageID: "message", reason: "Sign in" }, new AbortController().signal)
  manager.stop()
  expect(await stopped.result).toBe("cancelled")
})

test("authenticated single-use viewer tickets carry binary traffic and reject replay and foreign origins", async () => {
  const sockets = new Set<Socket>()
  const vnc = createServer((socket) => {
    sockets.add(socket)
    socket.on("close", () => sockets.delete(socket))
    socket.on("error", () => {})
    socket.write("RFB 003.008\n")
    socket.on("data", (bytes) => socket.write(bytes))
  })
  await new Promise<void>((resolve) => vnc.listen(0, "127.0.0.1", resolve))
  const address = vnc.address()
  if (!address || typeof address === "string") throw new Error("No test port")
  const root = await mkdtemp(join(tmpdir(), "openclient-desktop-test-"))
  const bridge = startBridgeServer({ openCodePort: 4096,
    remoteDesktopURL: `vnc://127.0.0.1:${address.port}`, remoteDesktopToken: token,
    image: { registryPath: join(root, "images.json") },
    video: { rootDirectory: join(root, "video"), registryPath: join(root, "videos.json") },
  })
  const origin = `http://127.0.0.1:${bridge.port}`
  const auth = { authorization: `Bearer ${token}` }
  let client: WebSocket | undefined
  try {
    const health = await (await fetch(`${origin}/openclient/v1/health`)).json() as any
    expect(health.remoteDesktop.viewerAvailable).toBe(true)
    expect((await fetch(`${origin}/openclient/v1/desktop/sessions`, { method: "POST" })).status).toBe(401)
    expect((await fetch(`${origin}/openclient/v1/desktop/sessions`, { method: "POST", headers: { ...auth, origin } })).status).toBe(401)
    const response = await fetch(`${origin}/openclient/v1/desktop/sessions`, { method: "POST", headers: auth })
    const { ticket } = await response.json() as { ticket: string }
    expect(ticket).toHaveLength(43)
    expect(response.headers.get("cache-control")).toBe("no-store")
    const socketURL = `${origin.replace("http:", "ws:")}/openclient/v1/desktop/socket?ticket=${ticket}`
    const WS = WebSocket as unknown as { new(url: string, options: Bun.WebSocketOptions): WebSocket }
    client = new WS(socketURL, { headers: { origin } })
    client.binaryType = "arraybuffer"
    const bytes = await new Promise<Uint8Array>((resolve, reject) => {
      let greeted = false
      client!.onerror = () => reject(new Error("WebSocket failed"))
      client!.onmessage = (event) => {
        const data = new Uint8Array(event.data as ArrayBuffer)
        if (!greeted) {
          expect(new TextDecoder().decode(data)).toBe("RFB 003.008\n")
          greeted = true
          client!.send(new Uint8Array([0, 255, 17, 128]))
        } else resolve(data)
      }
    })
    expect([...bytes]).toEqual([0, 255, 17, 128])
    expect(bridge.remoteDesktop.consume(ticket)).toBe(false)
    const unauthorized = await fetch(`${origin}/openclient/v1/desktop/socket?ticket=${ticket}`, {
      headers: { origin: "https://other.example", upgrade: "websocket" },
    })
    expect(unauthorized.status).toBe(403)
    const handoff = bridge.remoteDesktop.handoffs.request({ sessionID: "session", messageID: "message", reason: "Sign in" }, new AbortController().signal)
    const complete = await fetch(`${origin}/openclient/v1/desktop/handoffs/${handoff.request.requestID}`, {
      method: "POST", headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ sessionID: "session", messageID: "message", outcome: "done" }),
    })
    expect(complete.status).toBe(204)
    expect(await handoff.result).toBe("done")
    const viewer = await fetch(`${origin}/openclient/v1/desktop/viewer`)
    expect(viewer.status).toBe(200)
    expect(viewer.headers.get("content-security-policy")).toContain("frame-ancestors 'none'")
  } finally {
    client?.close()
    await bridge.stop()
    for (const socket of sockets) socket.destroy()
    await new Promise<void>((resolve) => vnc.close(() => resolve()))
    await rm(root, { recursive: true, force: true })
  }
})
