import { describe, expect, test } from "bun:test"
import { createServer } from "node:net"
import { mkdtemp, rm } from "node:fs/promises"
import { join } from "node:path"
import { tmpdir } from "node:os"
import plugin from "../src/index.js"

const OpenClientPlugin = plugin.server

describe("plugin failure isolation", () => {
  test("first reachable bridge health is notification-ready after successful initialization", async () => {
    const dataDir = await mkdtemp(join(tmpdir(), "openclient-index-ready-"))
    const notificationPort = await availablePort()
    const input = {
      client: { app: { log: async () => {} }, session: { get: async () => ({ error: new Error("unused") }) } },
      serverUrl: new URL("http://127.0.0.1:52001"), directory: "/repo", project: { id: "project" },
    }
    const hooks = await OpenClientPlugin(input as never, { notifications: {
      enabled: true, publicOrigin: "https://notify.example.com", port: notificationPort, dataDir,
    } })
    try {
      const bridgePort = await bridgePortFor(52001)
      const health = await fetch(`http://127.0.0.1:${bridgePort}/openclient/v1/health`).then((response) => response.json())
      expect(health.notifications).toEqual({
        version: 1,
        state: "ready",
        publicOrigin: "https://notify.example.com",
        pairing: {
          version: 1,
          cliPath: expect.stringMatching(/\/dist\/notifications\/src\/cli\.mjs$/),
          dataDir,
        },
      })
    } finally {
      await hooks.dispose?.()
      await rm(dataDir, { recursive: true, force: true })
    }
  })

  test("notification startup and rejected diagnostics do not disable or leak native tools", async () => {
    const occupied = createServer()
    await new Promise<void>((resolve, reject) => occupied.listen(0, "127.0.0.1", resolve).once("error", reject))
    const address = occupied.address()
    if (!address || typeof address === "string") throw new Error("No occupied test port")
    const input = {
      client: { app: { log: async () => { throw new Error("logging unavailable") } } },
      serverUrl: new URL("http://127.0.0.1:51999"),
      directory: "/repo",
      project: { id: "project" },
    }
    try {
      const hooks = await OpenClientPlugin(input as never, { notifications: {
        enabled: true, publicOrigin: "https://notify.example.com", port: address.port,
      } })
      expect(Object.keys(hooks.tool ?? {})).toContain("openclient_get_tool_list")
      expect(Object.keys(hooks.tool ?? {})).toContain("openclient_execute_tool")
      const bridgePort = await bridgePortFor(51999)
      expect(bridgePort).toBeGreaterThanOrEqual(4070)
      const health = await fetch(`http://127.0.0.1:${bridgePort}/openclient/v1/health`).then((response) => response.json())
      expect(health.notifications.state).toBe("unavailable")
      await hooks.dispose?.()
      await expect(fetch(`http://127.0.0.1:${bridgePort}/openclient/v1/health`)).rejects.toThrow()
    } finally {
      await new Promise<void>((resolve) => occupied.close(() => resolve()))
    }
  })

  test("notification options reject non-boolean enabled and unknown fields", async () => {
    const input = {
      client: { app: { log: async () => {} } }, serverUrl: new URL("http://127.0.0.1:52000"), directory: "/repo", project: { id: "project" },
    }
    const hooks = await OpenClientPlugin(input as never, { notifications: { enabled: "true", unexpected: true } as never })
    expect(Object.keys(hooks.tool ?? {})).toContain("openclient_get_tool_list")
    const bridgePort = await bridgePortFor(52000)
    const health = await fetch(`http://127.0.0.1:${bridgePort}/openclient/v1/health`).then((response) => response.json())
    expect(health.notifications.state).toBe("unavailable")
    await hooks.dispose?.()
  })
})

async function bridgePortFor(openCodePort: number): Promise<number> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    for (let port = 4070; port <= 4090; port += 1) {
      try {
        const health = await fetch(`http://127.0.0.1:${port}/openclient/v1/health`).then((response) => response.json())
        if (health.openCodePort === openCodePort) return port
      } catch { /* Try the next bridge port. */ }
    }
    await Bun.sleep(5)
  }
  throw new Error("Native bridge was not found")
}

async function availablePort(): Promise<number> {
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("No available test port")
  await new Promise<void>((resolve) => server.close(() => resolve()))
  return address.port
}
