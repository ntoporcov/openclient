import type { Plugin } from "@opencode/plugin"
import { acquireBridge } from "./lifecycle.js"
import { acquireNotifications } from "./notifications.js"
import { normalizeV2NotificationEvent, normalizeV2Session } from "./notifications-v2.js"
import { registerV2Tools } from "./tools-v2.js"
import type { OpenClientPluginOptions } from "./index.js"

// V2 provides in-process domain APIs, but no server URL on its plugin context.
// Use the host's explicit serve arguments (never guess based on the API version).
export function v2ServerURL(options: Pick<OpenClientPluginOptions, "serverURL">, argv = process.argv, env = process.env): URL {
  if (options.serverURL !== undefined) {
    const url = new URL(options.serverURL)
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
      throw new Error("serverURL must be an HTTP(S) origin without credentials")
    }
    return url
  }
  const index = argv.indexOf("--port")
  const raw = index >= 0 ? argv[index + 1] : argv.find((value) => value.startsWith("--port="))?.slice(7) ?? env.OPENCODE_SERVER_PORT
  // Default serve port is 4096. Other embedding modes must supply their origin.
  if (raw === undefined && !argv.includes("serve")) throw new Error("This v2 host requires the OpenClient serverURL option")
  const port = Number(raw ?? 4096)
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid OpenCode server port")
  return new URL(`http://127.0.0.1:${port}`)
}

export async function setupV2(ctx: Plugin.Context): Promise<Plugin.Cleanup> {
  const options = ctx.options as OpenClientPluginOptions
  const serverURL = v2ServerURL(options)
  const log = (level: "info" | "warn" | "error", message: string) => {
    console[level === "info" ? "info" : level]("[openclient-plugin]", message)
  }
  const notifications = await acquireNotifications({
    options: options.notifications,
    // Early v2 previews omit instance location. This key is only for cycle
    // deduplication; notification destinations always come from session.get.
    directory: ctx.location?.directory ?? serverURL.origin,
    project: ctx.location ? { ...ctx.location.project, worktree: ctx.location.project.canonical } : undefined,
    getServerURL: () => serverURL,
    client: { session: { get: async (input: { path: { id: string }; signal?: AbortSignal }) => {
      const sessionID = input.path.id as Parameters<Plugin.Context["session"]["get"]>[0]["sessionID"]
      const session = await ctx.session.get({ sessionID }, { signal: input.signal })
      const data = normalizeV2Session(session)
      if (!data) throw new Error("Invalid canonical v2 session")
      return { data }
    } } },
    onLog: log,
  }).catch(() => {
    log("error", "Notifications failed to start; check notification port and configuration")
    return undefined
  })
  let bridge: Awaited<ReturnType<typeof acquireBridge>>
  try {
    bridge = await acquireBridge({ openCodePort: Number(serverURL.port || (serverURL.protocol === "https:" ? 443 : 80)), onLog: log })
  } catch (error) {
    await notifications?.release()
    throw error
  }
  const controller = new AbortController()
  let registration: Awaited<ReturnType<typeof registerV2Tools>> | undefined
  try {
    registration = await registerV2Tools(ctx, bridge.server.bridge, bridge.server.videoResources, bridge.server.imageResources, controller.signal)
    void notifications?.source?.advertise()
    // Public events span all locations. Each location instance owns only its events.
    const iterator = ctx.event.subscribe({ signal: controller.signal })[Symbol.asyncIterator]()
    // Preview hosts ignore subscribe({signal}); race the pending next() with
    // cancellation, then explicitly return the iterator to release its scope.
    let cancelNext: () => void = () => {}
    const cancelled = new Promise<IteratorResult<Awaited<ReturnType<typeof iterator.next>>["value"]>>((resolve) => {
      cancelNext = () => resolve({ done: true, value: undefined })
    })
    controller.signal.addEventListener("abort", cancelNext, { once: true })
    const events = (async () => {
      try {
        while (!controller.signal.aborted) {
          const next = await Promise.race([iterator.next(), cancelled])
          if (next.done) break
          const event = next.value
          if (controller.signal.aborted) break
          if (ctx.location && event.location && event.location.directory !== ctx.location.directory) continue
          if (ctx.location && event.location && "workspaceID" in event.location && event.location.workspaceID !== ctx.location.workspaceID) continue
          const normalized = normalizeV2NotificationEvent(event)
          if (normalized) notifications?.adapter?.handle(normalized)
          void notifications?.source?.advertise()
        }
      } catch {
        if (!controller.signal.aborted) log("error", "Notification event subscription ended unexpectedly")
      }
    })()
    let released = false
    return async () => {
      if (released) return
      released = true
      controller.abort()
      await events
      try {
        await iterator.return?.()
        await registration?.dispose()
      } finally {
        try { await notifications?.release() } finally { await bridge.release() }
      }
    }
  } catch (error) {
    controller.abort()
    try { await registration?.dispose() } finally {
      try { await notifications?.release() } finally { await bridge.release() }
    }
    throw error
  }
}
