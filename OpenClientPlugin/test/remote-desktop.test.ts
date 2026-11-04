import { describe, expect, test } from "bun:test"
import { createServer, type Socket } from "node:net"
import { parseVNCTarget, probeVNC, RemoteDesktopDiscovery } from "../src/remote-desktop.js"

async function withServer(action: (socket: Socket) => void, run: (port: number) => Promise<void>) {
  const sockets = new Set<Socket>()
  const server = createServer((socket) => {
    sockets.add(socket)
    socket.on("error", () => {})
    socket.on("close", () => sockets.delete(socket))
    action(socket)
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  try {
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("Missing test address")
    await run(address.port)
  } finally {
    for (const socket of sockets) socket.destroy()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
}

describe("VNC discovery", () => {
  test("accepts hosts, explicit ports and IPv6", () => {
    expect(parseVNCTarget("vnc://localhost")).toEqual({ host: "localhost", port: 5900 })
    expect(parseVNCTarget("vnc://[::1]:5901")).toEqual({ host: "::1", port: 5901 })
  })

  test("rejects credentials, unrelated protocols and URL suffixes", () => {
    for (const value of ["https://localhost", "vnc://user:secret@localhost", "vnc://localhost/path", "vnc://localhost?password=secret", "vnc://localhost#fragment", "vnc://localhost:0", "vnc://localhost:65536"]) {
      expect(() => parseVNCTarget(value)).toThrow()
    }
  })

  test("reads fragmented greetings without sending client data", async () => {
    let clientBytes = 0
    await withServer((socket) => {
      socket.on("data", (data) => { clientBytes += data.length })
      socket.write("RFB 003.")
      setTimeout(() => { if (!socket.destroyed) socket.write("008\n") }, 10)
    }, async (port) => {
      expect(await probeVNC({ host: "127.0.0.1", port })).toBe("003.008")
    })
    expect(clientBytes).toBe(0)
  })

  test("does not mistake a listening HTTP service for VNC", async () => {
    await withServer((socket) => { socket.end("HTTP/1.1 200 OK\r\n") }, async (port) => {
      expect(await probeVNC({ host: "127.0.0.1", port })).toBeUndefined()
    })
  })

  test("bounds silent servers and incomplete greetings", async () => {
    for (const greeting of ["", "RFB 003."]) {
      await withServer((socket) => { if (greeting) socket.write(greeting) }, async (port) => {
        expect(await probeVNC({ host: "127.0.0.1", port }, 30)).toBeUndefined()
      })
    }
  })

  test("coalesces probes and advertises detection, not control readiness", async () => {
    let connections = 0
    await withServer((socket) => {
      connections++
      socket.write("RFB 003.889\n")
    }, async (port) => {
      const discovery = new RemoteDesktopDiscovery(`vnc://127.0.0.1:${port}`)
      const results = await Promise.all([discovery.capability(), discovery.capability()])
      expect(results[0]).toEqual({ version: 1, transport: "rfb", state: "detected", protocolVersion: "003.889" })
      expect(results[1]).toEqual(results[0])
      expect(await discovery.capability()).toEqual(results[0])
      expect(connections).toBe(1)
    })
  })

  test("missing and invalid configuration are safe health states", async () => {
    expect((await new RemoteDesktopDiscovery(undefined).capability()).state).toBe("unconfigured")
    const capability = await new RemoteDesktopDiscovery("vnc://user:secret@localhost").capability()
    expect(capability.state).toBe("unavailable")
    expect(JSON.stringify(capability)).not.toContain("secret")
  })
})
