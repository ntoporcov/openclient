import { afterEach, describe, expect, test } from "bun:test"
import { createServer } from "node:net"
import { generateKeyPairSync, randomBytes } from "node:crypto"
import { mkdtemp, rm } from "node:fs/promises"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { acquireNotifications, notificationCapability } from "../src/notifications.js"
import { startBridgeServer } from "../src/server.js"
import webpush from "web-push"

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => { while (cleanups.length) await cleanups.pop()?.() })

describe("notification native setup contract", () => {
  test("web-push encrypts a payload and sends the generated request through Bun HTTP", async () => {
    let received = new Uint8Array()
    let encoding = ""
    const receiver = Bun.serve({
      hostname: "127.0.0.1", port: 0,
      async fetch(request) {
        encoding = request.headers.get("content-encoding") ?? ""
        received = new Uint8Array(await request.arrayBuffer())
        return new Response(null, { status: 201 })
      },
    })
    try {
      const applicationKeys = webpush.generateVAPIDKeys()
      const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
      const jwk = publicKey.export({ format: "jwk" })
      if (!jwk.x || !jwk.y) throw new Error("Missing test EC coordinates")
      const p256dh = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]).toString("base64url")
      const details = webpush.generateRequestDetails({
        endpoint: `http://127.0.0.1:${receiver.port}/push`,
        keys: { p256dh, auth: randomBytes(16).toString("base64url") },
      }, "private notification body", {
        vapidDetails: { subject: "mailto:test@example.com", publicKey: applicationKeys.publicKey, privateKey: applicationKeys.privateKey },
      })
      const response = await fetch(details.endpoint, { method: details.method, headers: details.headers, body: details.body })
      expect(response.status).toBe(201)
      expect(encoding).toBe("aes128gcm")
      expect(received.byteLength).toBeGreaterThan(20)
      expect(new TextDecoder().decode(received)).not.toContain("private notification body")
    } finally { receiver.stop(true) }
  })

  test("reports ready and mints only a bounded prefill ticket", async () => {
    const dataDir = await mkdtemp(join(tmpdir(), "openclient-notifications-"))
    const port = await availablePort()
    const lease = await acquireNotifications({
      options: { enabled: true, publicOrigin: "https://notify.example.com", port, dataDir },
      client: { session: { get: async () => ({ error: new Error("unused") }) } },
      directory: "/repo",
      project: { id: "project" },
      getServerURL: () => new URL("http://127.0.0.1:4096"),
      onLog() {},
    })
    const bridge = startBridgeServer({ openCodePort: 4096 })
    cleanups.push(async () => { await bridge.stop(); await lease.release(); await rm(dataDir, { recursive: true, force: true }) })

    const health = await fetch(`http://127.0.0.1:${bridge.port}/openclient/v1/health`).then((response) => response.json())
    expect(health.notifications).toEqual({ version: 1, state: "ready", publicOrigin: "https://notify.example.com" })
    const response = await fetch(`http://127.0.0.1:${bridge.port}/openclient/v1/notifications/setup`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ baseURL: "  http://Mac.local:4096/path/  ", username: "", profile: "v2" }),
    })
    expect(response.status).toBe(200)
    const ticket = await response.json() as { url: string; code: string; expiresAt: string }
    expect(ticket.code).toMatch(/^[A-F0-9]{10}$/)
    expect(ticket.url).toBe(`https://notify.example.com/#setup=${ticket.code}`)
    expect(JSON.stringify(ticket)).not.toContain("Mac.local")
    expect(new Date(ticket.expiresAt).getTime()).toBeLessThanOrEqual(Date.now() + 10 * 60_000)

    const browser = await fetch(`http://127.0.0.1:${bridge.port}/openclient/v1/notifications/setup`, {
      method: "POST", headers: { "Content-Type": "application/json", Origin: "https://notify.example.com" },
      body: JSON.stringify({ baseURL: "http://localhost:4096", username: "", profile: "legacy" }),
    })
    expect(browser.status).toBe(403)
    const embedded = await fetch(`http://127.0.0.1:${bridge.port}/openclient/v1/notifications/setup`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ baseURL: "http://user:password@localhost:4096?secret=yes", username: "", profile: "legacy" }),
    })
    expect(embedded.status).toBe(400)
    expect(await embedded.text()).not.toContain("password")
    for (const invalid of [
      { baseURL: "https://example.com/\u0007", username: "", profile: "legacy" },
      { baseURL: "https://example.com/", username: "x".repeat(129), profile: "legacy" },
      { baseURL: "https://example.com/", username: "bad\nname", profile: "legacy" },
    ]) {
      const rejected = await fetch(`http://127.0.0.1:${bridge.port}/openclient/v1/notifications/setup`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(invalid),
      })
      expect(rejected.status).toBe(400)
    }
  })

  test("shares one service across directories and serializes final release", async () => {
    const firstDir = await mkdtemp(join(tmpdir(), "openclient-notifications-"))
    const secondDir = await mkdtemp(join(tmpdir(), "openclient-notifications-other-"))
    const port = await availablePort()
    const base = {
      client: { session: { get: async () => ({ error: new Error("unused") }) } },
      project: { id: "project" }, getServerURL: () => new URL("http://127.0.0.1:4096"), onLog() {},
    }
    const [first, second] = await Promise.all([
      acquireNotifications({ ...base, directory: "/first", options: { enabled: true, publicOrigin: "https://notify.example.com", port, dataDir: firstDir } }),
      acquireNotifications({ ...base, directory: "/second", options: { enabled: true, publicOrigin: "https://notify.example.com", port, dataDir: firstDir } }),
    ])
    expect(notificationCapability().state).toBe("ready")
    await expect(acquireNotifications({ ...base, directory: "/conflict", options: { enabled: true, publicOrigin: "https://other.example.com", port: await availablePort(), dataDir: secondDir } })).rejects.toThrow("configured differently")
    await first.release()
    expect(notificationCapability().state).toBe("ready")
    await second.release()
    expect(notificationCapability().state).toBe("unconfigured")
    const retry = await acquireNotifications({ ...base, directory: "/retry", options: { enabled: true, publicOrigin: "https://other.example.com", port: await availablePort(), dataDir: secondDir } })
    await retry.release()
    await Promise.all([rm(firstDir, { recursive: true, force: true }), rm(secondDir, { recursive: true, force: true })])
  })
})

async function availablePort(): Promise<number> {
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("No test port")
  await new Promise<void>((resolve) => server.close(() => resolve()))
  return address.port
}
