import type { Plugin } from "@opencode-ai/plugin"
import { acquireBridge } from "./lifecycle.js"
import { acquireNotifications, type NotificationsOptions } from "./notifications.js"
import { createOpenClientTools } from "./tools.js"

export type OpenClientPluginOptions = {
  notifications?: NotificationsOptions
}

const OpenClientPlugin = async (input: Parameters<Plugin>[0], options: OpenClientPluginOptions = {}) => {
  const { client } = input
  let notifications: Awaited<ReturnType<typeof acquireNotifications>> | undefined
  notifications = await acquireNotifications({
    options: options.notifications,
    client,
    directory: input.directory,
    project: input.project,
    getServerURL: () => input.serverUrl,
    onLog: (level, message) => void log(level, message),
  }).catch((error) => {
    void log("error", `Notifications failed to start: ${error instanceof Error ? error.message : String(error)}`)
    return undefined
  })

  let lease: Awaited<ReturnType<typeof acquireBridge>>
  try {
    lease = await acquireBridge({
      openCodePort: normalizedPort(input.serverUrl),
      onLog: (level, message) => void log(level, message),
    })
  } catch (error) {
    await notifications?.release()
    await log("error", `WebSocket bridge failed to start: ${error instanceof Error ? error.message : String(error)}`)
    return {}
  }

  try {
    void notifications?.source?.advertise()
    const tools = createOpenClientTools(
      lease.server.bridge,
      lease.server.videoResources,
      lease.server.imageResources,
    )
    return {
      event: async ({ event }: { event: unknown }) => {
        void notifications?.source?.advertise()
        notifications?.adapter?.handle(event)
      },
      dispose: async () => {
        const active = notifications
        notifications = undefined
        try { await active?.release() } finally { await lease.release() }
      },
      tool: tools,
    }
  } catch (error) {
    try {
      await notifications?.release()
    } finally {
      await lease.release()
    }
    await log("error", `OpenClient plugin composition failed: ${error instanceof Error ? error.message : String(error)}`)
    return {}
  }

  async function log(level: "info" | "warn" | "error", message: string): Promise<void> {
    try {
      await client.app.log({
        body: {
          service: "openclient-plugin",
          level,
          message,
        },
      })
    } catch {
      // Diagnostics must never change bridge or notification availability.
    }
  }
}

export default OpenClientPlugin

function normalizedPort(url: URL): number {
  if (!url.port) return url.protocol === "https:" ? 443 : 80
  const port = Number(url.port)
  if (!Number.isInteger(port)) throw new Error(`Invalid OpenCode server port: ${url.port}`)
  return port
}
