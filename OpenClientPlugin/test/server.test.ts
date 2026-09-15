import { describe, expect, test } from "bun:test"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { bindFirstAvailable, isAddressInUse, startBridgeServer } from "../src/server.js"
import type { VideoProcess } from "../src/video.js"
import { jpegPreview } from "./fixtures.js"

describe("bridge port selection", () => {
  test("uses the first available port", () => {
    const attempted: number[] = []
    const selected = bindFirstAvailable((port) => {
      attempted.push(port)
      if (port < 4072) throw Object.assign(new Error("busy"), { code: "EADDRINUSE" })
      return port
    })
    expect(selected).toBe(4072)
    expect(attempted).toEqual([4070, 4071, 4072])
  })

  test("recognizes nested address errors", () => {
    expect(isAddressInUse({ cause: { code: "EADDRINUSE" } })).toBe(true)
    expect(isAddressInUse({ code: "EACCES" })).toBe(false)
  })

  test("does not hide non-address errors", () => {
    expect(() => bindFirstAvailable(() => {
      throw Object.assign(new Error("denied"), { code: "EACCES" })
    })).toThrow("denied")
  })

  test("serves health and WebSocket RPC", async () => {
    const openCodePort = 4096
    const temporary = await mkdtemp(join(tmpdir(), "openclient-server-test-"))
    const server = startBridgeServer({
      openCodePort,
      image: {
        registryPath: join(temporary, "state", "image-resources.json"),
      },
      video: {
        rootDirectory: join(temporary, "hls"),
        registryPath: join(temporary, "state", "video-resources.json"),
      },
    })
    try {
      const health = await fetch(`http://127.0.0.1:${server.port}/openclient/v1/health`)
      expect(await health.json()).toEqual({
        service: "openclient-plugin",
        protocol: 1,
        port: server.port,
        openCodePort,
        notifications: { version: 1, state: "unconfigured" },
      })

      const WebSocketWithOptions = WebSocket as unknown as {
        new(url: string | URL, options?: Bun.WebSocketOptions): WebSocket
      }
      const socket = new WebSocketWithOptions(`ws://127.0.0.1:${server.port}/openclient/v1/ws`)
      let markRegistered: () => void = () => {}
      let rejectRegistration: (error: Error) => void = () => {}
      const registered = new Promise<void>((resolve, reject) => {
        markRegistered = resolve
        rejectRegistration = reject
      })
      socket.addEventListener("open", () => {
        socket.send(JSON.stringify({
          protocol: 1,
          type: "register",
          clientID: "integration-client",
          displayName: "Integration iPhone",
          appVersion: "1.0",
        }))
      })
      socket.addEventListener("message", (event) => {
        const message = JSON.parse(String(event.data)) as { type: string; id?: string; method?: string }
        if (message.type === "registered") {
          socket.send(JSON.stringify({
            protocol: 1,
            type: "session_updated",
            sessionID: "session",
          }))
          markRegistered()
        }
        if (message.type === "request" && message.method === "list_tools" && message.id) {
          socket.send(JSON.stringify({
            protocol: 1,
            type: "response",
            id: message.id,
            ok: true,
            result: {
              tools: [{ id: "status", description: "Status", inputSchema: {} }],
            },
          }))
        }
      })
      socket.addEventListener("error", () => rejectRegistration(new Error("WebSocket connection failed")))
      socket.addEventListener("close", (event) => {
        rejectRegistration(new Error(`WebSocket closed before registration: ${event.code} ${event.reason}`))
      })
      await registered
      await Bun.sleep(10)
      const clients = await server.bridge.listTools({
        sessionID: "session",
        signal: new AbortController().signal,
      })
      expect(clients[0]?.tools[0]?.id).toBe("status")
      socket.close()
    } finally {
      await server.stop()
      await rm(temporary, { recursive: true, force: true })
    }
  })

  test("starts and serves lazy HLS over HTTP without WebSocket media", async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openclient-video-http-test-"))
    const source = join(temporary, "demo.mp4")
    await writeFile(source, "mp4")
    let spawnCount = 0
    const processes: HTTPFakeProcess[] = []
    const server = startBridgeServer({
      openCodePort: 4096,
      image: {
        registryPath: join(temporary, "state", "image-resources.json"),
      },
      video: {
        rootDirectory: join(temporary, "hls"),
        registryPath: join(temporary, "state", "video-resources.json"),
        readinessTimeoutMS: 1_000,
        readinessPollMS: 5,
        probe: async () => JSON.stringify({
          streams: [{ width: 640, height: 480 }],
          format: { duration: "1.5" },
        }),
        preview: async () => jpegPreview(96, 72),
        spawn(command) {
          spawnCount += 1
          const process = new HTTPFakeProcess()
          processes.push(process)
          const playlist = command.at(-1)
          const segmentPattern = command[command.indexOf("-hls_segment_filename") + 1]
          if (!playlist || !segmentPattern) throw new Error("Missing fake ffmpeg output paths")
          void Promise.resolve().then(async () => {
            await mkdir(join(playlist, ".."), { recursive: true })
            await writeFile(segmentPattern.replace("%06d", "000000"), "segment")
            await writeFile(join(playlist, "../init.mp4"), "init")
            await writeFile(playlist, "#EXTM3U\n#EXTINF:4,\nsegment-000000.m4s\n")
          })
          return process
        },
      },
    })
    try {
      const resource = await server.videoResources.createResource({
        filePath: source,
        context: {
          clientID: "client",
          sessionID: "session",
          messageID: "message",
          agent: "build",
          directory: temporary,
          worktree: temporary,
        },
      })
      const baseURL = `http://127.0.0.1:${server.port}`
      const started = await fetch(`${baseURL}${resource.startPath}`, { method: "POST" })
      expect(started.status).toBe(200)
      const result = await started.json() as { streamID: string; hlsPath: string; stopPath: string }
      expect(result.hlsPath).toBe(`/openclient/v1/video/streams/${result.streamID}/playlist.m3u8`)
      expect(result.stopPath).toBe(`/openclient/v1/video/streams/${result.streamID}`)
      expect(spawnCount).toBe(1)

      const repeated = await fetch(`${baseURL}${resource.startPath}`, { method: "POST" })
      const secondResult = await repeated.json() as { streamID: string; hlsPath: string; stopPath: string }
      expect(secondResult.streamID).not.toBe(result.streamID)
      expect(spawnCount).toBe(2)

      const playlist = await fetch(`${baseURL}${result.hlsPath}`)
      expect(playlist.headers.get("content-type")).toContain("application/vnd.apple.mpegurl")
      expect(await playlist.text()).toContain("segment-000000.m4s")
      const traversal = await fetch(`${baseURL}/openclient/v1/video/streams/${result.streamID}/../demo.mp4`)
      expect(traversal.status).toBe(404)

      expect((await fetch(`${baseURL}${result.stopPath}`, { method: "DELETE" })).status).toBe(204)
      expect((await fetch(`${baseURL}${result.hlsPath}`)).status).toBe(404)
      expect(processes[0]?.signals).toContain("SIGTERM")
      expect((await fetch(`${baseURL}${secondResult.hlsPath}`)).status).toBe(200)
      expect((await fetch(`${baseURL}${secondResult.stopPath}`, { method: "DELETE" })).status).toBe(204)
      expect(processes[1]?.signals).toContain("SIGTERM")
    } finally {
      await server.stop()
      await rm(temporary, { recursive: true, force: true })
    }
  })

  test("serves bounded original image content only from the opaque GET route", async () => {
    const temporary = await mkdtemp(join(tmpdir(), "openclient-image-http-test-"))
    const source = join(temporary, "photo.webp")
    const sourceBytes = new TextEncoder().encode("original webp bytes")
    await writeFile(source, sourceBytes)
    const server = startBridgeServer({
      openCodePort: 4096,
      image: {
        registryPath: join(temporary, "state", "image-resources.json"),
        probe: async () => JSON.stringify({
          streams: [{ codec_name: "webp", width: 640, height: 480 }],
        }),
        preview: async () => jpegPreview(96, 72),
      },
      video: {
        rootDirectory: join(temporary, "hls"),
        registryPath: join(temporary, "state", "video-resources.json"),
      },
    })
    try {
      const resource = await server.imageResources.createResource({
        filePath: source,
        context: {
          clientID: "client",
          sessionID: "session",
          messageID: "message",
          agent: "build",
          directory: temporary,
          worktree: temporary,
        },
      })
      const baseURL = `http://127.0.0.1:${server.port}`
      const response = await fetch(`${baseURL}${resource.contentPath}`)
      expect(response.status).toBe(200)
      expect(response.headers.get("content-type")).toBe("image/webp")
      expect(response.headers.get("content-length")).toBe(String(sourceBytes.byteLength))
      expect(response.headers.get("cache-control")).toContain("private")
      expect(response.headers.get("cache-control")).toContain("no-store")
      expect(response.headers.get("x-content-type-options")).toBe("nosniff")
      expect(Array.from(new Uint8Array(await response.arrayBuffer()))).toEqual(Array.from(sourceBytes))

      expect((await fetch(`${baseURL}${resource.contentPath}`, { method: "POST" })).status).toBe(405)
      expect((await fetch(`${baseURL}${resource.contentPath}/../private.webp`)).status).toBe(404)
      expect((await fetch(`${baseURL}/openclient/v1/image/resources/${resource.resourceID}/content/extra`)).status).toBe(404)

      await writeFile(source, "changed webp")
      expect((await fetch(`${baseURL}${resource.contentPath}`)).status).toBe(409)
    } finally {
      await server.stop()
      await rm(temporary, { recursive: true, force: true })
    }
  })
})

class HTTPFakeProcess implements VideoProcess {
  readonly signals: Array<NodeJS.Signals | number | undefined> = []
  readonly exited: Promise<number>
  private resolveExit: (code: number) => void = () => {}

  constructor() {
    this.exited = new Promise((resolve) => {
      this.resolveExit = resolve
    })
  }

  kill(signal?: NodeJS.Signals | number): void {
    this.signals.push(signal)
    this.resolveExit(0)
  }
}
