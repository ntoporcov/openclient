import { networkInterfaces } from "node:os"
import { OpenClientBridge } from "./bridge.js"
import { parseClientMessage, protocolVersion } from "./protocol.js"
import { mintNotificationSetupTicket, notificationCapability, type SetupDraft } from "./notifications.js"
import {
  ImageResourceError,
  ImageResourceManager,
  defaultImageRegistryPath,
  type ImageResourceManagerOptions,
} from "./image.js"
import {
  VideoResourceError,
  VideoResourceManager,
  defaultVideoRegistryPath,
  type VideoResourceManagerOptions,
} from "./video.js"

const websocketPath = "/openclient/v1/ws"
const healthPath = "/openclient/v1/health"
const notificationSetupPath = "/openclient/v1/notifications/setup"
const imageContentRoute = /^\/openclient\/v1\/image\/resources\/([A-Za-z0-9_-]{32})\/content$/
const videoResourceRoute = /^\/openclient\/v1\/video\/resources\/([A-Za-z0-9_-]{32})\/stream$/
const videoStreamRoute = /^\/openclient\/v1\/video\/streams\/([A-Za-z0-9_-]{32})$/
const videoAssetRoute = /^\/openclient\/v1\/video\/streams\/([A-Za-z0-9_-]{32})\/(playlist\.m3u8|init\.mp4|segment-\d{6}\.m4s)$/

type SocketData = {
  connectionID: string
}

export type BridgeServer = {
  bridge: OpenClientBridge
  imageResources: ImageResourceManager
  videoResources: VideoResourceManager
  port: number
  advertisedURLs: string[]
  stop(): Promise<void>
}

export type BridgeServerOptions = {
  openCodePort: number
  onLog?: (level: "info" | "warn" | "error", message: string) => void
  image?: ImageResourceManagerOptions
  video?: VideoResourceManagerOptions
}

export function startBridgeServer(options: BridgeServerOptions): BridgeServer {
  const bridge = new OpenClientBridge()
  const imageResources = new ImageResourceManager({
    ...options.image,
    registryPath: options.image?.registryPath ?? defaultImageRegistryPath(options.openCodePort),
  })
  const videoResources = new VideoResourceManager({
    ...options.video,
    registryPath: options.video?.registryPath ?? defaultVideoRegistryPath(options.openCodePort),
  })
  const registrationTimers = new Map<string, ReturnType<typeof setTimeout>>()
  const setupRateBuckets = new Map<string, number[]>()

  const server = (() => {
    try {
      return bindFirstAvailable((port) => Bun.serve<SocketData>({
    id: null,
    hostname: "::",
    port,
    async fetch(request, bunServer) {
      const url = new URL(request.url)
       if (url.pathname === healthPath) {
         return Response.json({
           service: "openclient-plugin",
           protocol: protocolVersion,
           port,
           openCodePort: options.openCodePort,
           notifications: notificationCapability(),
          })
        }
        if (url.pathname === notificationSetupPath) {
          if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } })
          if (request.headers.has("origin")) return safeSetupError(403, "Browser-origin requests are not allowed.")
          if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("content-type") ?? "")) return safeSetupError(415, "Requests must use application/json.")
          const remote = bunServer.requestIP(request)?.address ?? "unknown"
          if (rateLimited(setupRateBuckets, remote, 10, 10 * 60_000)) return safeSetupError(429, "Too many setup requests. Wait before trying again.")
          const capability = notificationCapability()
          if (capability.state !== "ready") return safeSetupError(capability.state === "unavailable" ? 503 : 403, "Notifications are not ready.")
          try {
            const draft = await parseSetupDraft(request)
            const ticket = mintNotificationSetupTicket(draft)
            return ticket ? Response.json(ticket, { headers: { "Cache-Control": "no-store" } }) : safeSetupError(503, "Notifications are not ready.")
          } catch (error) {
            return safeSetupError(error instanceof SetupRequestError ? error.status : 400, error instanceof SetupRequestError ? error.message : "Invalid setup request.")
          }
        }
       const imageMatch = imageContentRoute.exec(url.pathname)
       if (imageMatch) {
         if (request.method !== "GET") {
           return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } })
         }
         const resourceID = imageMatch[1]
         if (!resourceID) return new Response("Not found", { status: 404 })
         try {
           const content = await imageResources.load(resourceID)
           return new Response(content.bytes, {
             headers: {
               "Content-Type": content.contentType,
               "Content-Length": String(content.sizeBytes),
               "Cache-Control": "private, no-store, max-age=0",
               "X-Content-Type-Options": "nosniff",
             },
           })
         } catch (error) {
           if (!(error instanceof ImageResourceError)) {
             options.onLog?.("error", `Image request failed: ${error instanceof Error ? error.message : String(error)}`)
           }
           return imageErrorResponse(error)
         }
       }
       const resourceMatch = videoResourceRoute.exec(url.pathname)
      if (resourceMatch) {
        const resourceID = resourceMatch[1]
        if (!resourceID) return new Response("Not found", { status: 404 })
        try {
          if (request.method === "POST") {
            return Response.json(await videoResources.start(resourceID), {
              headers: { "Cache-Control": "no-store" },
            })
          }
          if (request.method === "DELETE") {
            return await videoResources.stop(resourceID)
              ? new Response(null, { status: 204 })
              : new Response("Not found", { status: 404 })
          }
          return new Response("Method not allowed", { status: 405, headers: { Allow: "POST, DELETE" } })
        } catch (error) {
          if (!(error instanceof VideoResourceError)) {
            options.onLog?.("error", `Video request failed: ${error instanceof Error ? error.message : String(error)}`)
          }
          return videoErrorResponse(error)
        }
      }
      const assetMatch = videoAssetRoute.exec(url.pathname)
      const streamMatch = videoStreamRoute.exec(url.pathname)
      if (streamMatch) {
        if (request.method !== "DELETE") {
          return new Response("Method not allowed", { status: 405, headers: { Allow: "DELETE" } })
        }
        const streamID = streamMatch[1]
        if (!streamID) return new Response("Not found", { status: 404 })
        return await videoResources.stopStream(streamID)
          ? new Response(null, { status: 204 })
          : new Response("Not found", { status: 404 })
      }
      if (assetMatch) {
        if (request.method !== "GET") {
          return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } })
        }
        const streamID = assetMatch[1]
        const fileName = assetMatch[2]
        if (!streamID || !fileName) return new Response("Not found", { status: 404 })
        const asset = await videoResources.asset(streamID, fileName)
        if (!asset) return new Response("Not found", { status: 404 })
        return new Response(Bun.file(asset.path), {
          headers: {
            "Content-Type": asset.contentType,
            "Cache-Control": asset.cacheControl,
            "X-Content-Type-Options": "nosniff",
          },
        })
      }
      if (url.pathname !== websocketPath) return new Response("Not found", { status: 404 })
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return new Response("WebSocket upgrade required", { status: 426 })
      }
      const upgraded = bunServer.upgrade(request, {
        data: { connectionID: crypto.randomUUID() },
      })
      return upgraded ? undefined : new Response("WebSocket upgrade failed", { status: 400 })
    },
    idleTimeout: 30,
    websocket: {
      open(socket) {
        const timer = setTimeout(() => {
          socket.close(4002, "Registration timed out")
        }, 10_000)
        registrationTimers.set(socket.data.connectionID, timer)
      },
      message(socket, payload) {
        if (typeof payload !== "string") {
          socket.close(1003, "Only text messages are supported")
          return
        }
        try {
          const message = parseClientMessage(payload)
          bridge.handleMessage(socket.data.connectionID, socket, message)
          if (message.type === "register") {
            const timer = registrationTimers.get(socket.data.connectionID)
            if (timer) clearTimeout(timer)
            registrationTimers.delete(socket.data.connectionID)
          }
        } catch (error) {
          options.onLog?.("warn", error instanceof Error ? error.message : String(error))
          socket.close(1008, "Invalid OpenClient protocol message")
        }
      },
      close(socket) {
        const timer = registrationTimers.get(socket.data.connectionID)
        if (timer) clearTimeout(timer)
        registrationTimers.delete(socket.data.connectionID)
        bridge.disconnect(socket.data.connectionID)
      },
      idleTimeout: 120,
      maxPayloadLength: 1_048_576,
      backpressureLimit: 1_048_576,
      closeOnBackpressureLimit: true,
      sendPings: true,
      perMessageDeflate: false,
    },
      }))
    } catch (error) {
      void Promise.all([imageResources.stopAll(), videoResources.stopAll()])
      throw error
    }
  })()
  const port = server.port
  if (port === undefined) {
    server.stop(true)
    void Promise.all([imageResources.stopAll(), videoResources.stopAll()])
    throw new Error("OpenClient bridge did not receive a bound port")
  }

  const advertisedURLs = interfaceAddresses().map((address) => `ws://${address}:${port}${websocketPath}`)
  options.onLog?.("info", `OpenClient bridge listening on port ${port}`)
  for (const url of advertisedURLs) options.onLog?.("info", `OpenClient bridge available at ${url}`)

  return {
    bridge,
    imageResources,
    videoResources,
    port,
    advertisedURLs,
    async stop() {
      for (const timer of registrationTimers.values()) clearTimeout(timer)
      registrationTimers.clear()
      bridge.stop()
      server.stop(true)
      await Promise.all([imageResources.stopAll(), videoResources.stopAll()])
    },
  }
}

class SetupRequestError extends Error {
  constructor(readonly status: number, message: string) { super(message) }
}

async function parseSetupDraft(request: Request): Promise<SetupDraft> {
  const declared = Number(request.headers.get("content-length"))
  if (Number.isFinite(declared) && declared > 4_096) throw new SetupRequestError(413, "Request body is too large.")
  const bytes = await request.arrayBuffer()
  if (bytes.byteLength > 4_096) throw new SetupRequestError(413, "Request body is too large.")
  let body: unknown
  try { body = JSON.parse(new TextDecoder().decode(bytes)) }
  catch { throw new SetupRequestError(400, "Request body must be valid JSON.") }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new SetupRequestError(400, "Invalid setup request.")
  const value = body as Record<string, unknown>
  if (Object.keys(value).sort().join(",") !== "baseURL,profile,username") throw new SetupRequestError(400, "Invalid setup request fields.")
  if (typeof value.baseURL !== "string" || typeof value.username !== "string" || (value.profile !== "legacy" && value.profile !== "v2")) throw new SetupRequestError(400, "Invalid setup request.")
  const baseURL = value.baseURL.trim()
  if (!baseURL || baseURL.length > 2_048 || /[\u0000-\u001f\u007f]/.test(baseURL) || value.username.length > 128 || /[\u0000-\u001f\u007f]/.test(value.username)) throw new SetupRequestError(400, "Invalid setup request.")
  let parsed: URL
  try { parsed = new URL(baseURL) } catch { throw new SetupRequestError(400, "Invalid server URL.") }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password || parsed.search || parsed.hash) throw new SetupRequestError(400, "Server URL must not contain credentials, a query, or a fragment.")
  return { baseURL, username: value.username, profile: value.profile }
}

function safeSetupError(status: number, error: string): Response {
  return Response.json({ error }, { status, headers: { "Cache-Control": "no-store" } })
}

function rateLimited(buckets: Map<string, number[]>, key: string, maximum: number, windowMS: number): boolean {
  const now = Date.now()
  const recent = (buckets.get(key) ?? []).filter((value) => value > now - windowMS)
  if (recent.length >= maximum) return true
  recent.push(now)
  buckets.set(key, recent)
  return false
}

function imageErrorResponse(error: unknown): Response {
  const status = error instanceof ImageResourceError ? error.status : 500
  const message = error instanceof ImageResourceError && status !== 500
    ? error.message
    : "Image service failed"
  return Response.json({ error: message }, {
    status,
    headers: { "Cache-Control": "no-store" },
  })
}

function videoErrorResponse(error: unknown): Response {
  const status = error instanceof VideoResourceError ? error.status : 500
  const message = error instanceof VideoResourceError && status !== 500
    ? error.message
    : "Video service failed"
  return Response.json({ error: message }, {
    status,
    headers: { "Cache-Control": "no-store" },
  })
}

export function bindFirstAvailable<T>(
  create: (port: number) => T,
  start = 4070,
  end = 4090,
): T {
  for (let port = start; port <= end; port += 1) {
    try {
      return create(port)
    } catch (error) {
      if (isAddressInUse(error)) continue
      throw error
    }
  }
  throw new Error(`No OpenClient bridge port is available in ${start}-${end}`)
}

export function isAddressInUse(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false
  const direct = "code" in error ? error.code : undefined
  const cause = "cause" in error && typeof error.cause === "object" && error.cause !== null && "code" in error.cause
    ? error.cause.code
    : undefined
  return direct === "EADDRINUSE" || cause === "EADDRINUSE"
}

function interfaceAddresses(): string[] {
  const addresses = new Set<string>()
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.internal) continue
      if (entry.family === "IPv4") {
        addresses.add(entry.address)
      } else if (entry.family === "IPv6") {
        addresses.add(`[${entry.address}]`)
      }
    }
  }
  return [...addresses].sort()
}
