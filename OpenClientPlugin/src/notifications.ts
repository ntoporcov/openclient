import { resolve } from "node:path"
import { fileURLToPath } from "node:url"

export type NotificationsOptions = {
  enabled: boolean
  publicOrigin?: string
  port?: number
  dataDir?: string
}

export type SetupDraft = {
  baseURL: string
  username: string
  profile: "legacy" | "v2"
}

type NotificationService = {
  publicOrigin: URL
  ingest(event: unknown): Promise<unknown>
  updateSource(endpoint: unknown): Promise<unknown>
  mintSetupTicket(draft: SetupDraft): { url: string; code: string; expiresAt: string }
  stop(): Promise<void>
}

type NotificationModule = {
  createNotificationServer(options: Record<string, unknown>): Promise<NotificationService>
}

type Adapter = { handle(event: unknown): void; idle(): Promise<void> }
type BridgeModule = {
  createPluginBridge(options: Record<string, unknown>): Adapter
  createSourceEndpointAdvertiser(options: Record<string, unknown>): { advertise(): Promise<boolean> }
}

type NotificationState = {
  key?: string
  promise?: Promise<NotificationService>
  service?: NotificationService
  leases: number
  reservations: number
  stopping?: Promise<void>
  unavailable?: boolean
}

const stateKey = Symbol.for("@openclient/opencode-plugin/notifications")
const global = globalThis as typeof globalThis & { [stateKey]?: NotificationState }

export type NotificationLease = {
  adapter?: Adapter
  source?: { advertise(): Promise<boolean> }
  release(): Promise<void>
}

export type NotificationCapability = {
  version: 1
  state: "ready" | "unconfigured" | "unavailable"
  publicOrigin?: string
  pairing?: { version: 1; cliPath: string; dataDir: string }
}

export function notificationCapability(): NotificationCapability {
  const state = global[stateKey]
  if (state?.service && state.key) {
    const options = JSON.parse(state.key) as { dataDir?: string }
    return {
      version: 1,
      state: "ready",
      publicOrigin: state.service.publicOrigin.origin,
      pairing: {
        version: 1,
        cliPath: notificationCLIPath(),
        dataDir: options.dataDir ?? defaultNotificationDataDir(),
      },
    }
  }
  return { version: 1, state: state?.unavailable ? "unavailable" : "unconfigured" }
}

export function mintNotificationSetupTicket(draft: SetupDraft) {
  const service = global[stateKey]?.service
  if (!service) return undefined
  return service.mintSetupTicket(draft)
}

export async function acquireNotifications(input: {
  options?: NotificationsOptions
  client: unknown
  directory: string
  project: unknown
  getServerURL(): URL
  onLog(level: "info" | "warn" | "error", message: string): void
}): Promise<NotificationLease> {
  const state = global[stateKey] ?? { leases: 0, reservations: 0 }
  global[stateKey] = state
  state.reservations ??= 0
  let enabled: boolean
  try { enabled = validateOptionsShape(input.options) }
  catch (error) { state.unavailable = true; throw error }
  if (!enabled) return { async release() {} }
  if (state.stopping) {
    await state.stopping
    return acquireNotifications(input)
  }
  let options: ReturnType<typeof normalizeOptions>
  try { options = normalizeOptions(input.options!) }
  catch (error) { state.unavailable = true; throw error }
  const key = JSON.stringify(options)
  if (state.key && state.key !== key) throw new Error("Notification service is already configured differently in this process")
  state.key = key
  state.reservations += 1
  state.promise ??= loadNotificationModule().then((module) => module.createNotificationServer({
    publicOrigin: options.publicOrigin,
    port: options.port,
    dataDir: options.dataDir,
    listen: { port: options.port },
  })).then((service) => {
    state.service = service
    state.unavailable = false
    return service
  }).catch((error) => {
    state.promise = undefined
    state.service = undefined
    state.unavailable = true
    state.key = undefined
    throw error
  })
  let service: NotificationService
  try { service = await state.promise }
  catch (error) { state.reservations = Math.max(0, state.reservations - 1); throw error }
  let adapter: Adapter
  let source: { advertise(): Promise<boolean> }
  try {
    const bridgeModule = await loadBridgeModule()
    adapter = bridgeModule.createPluginBridge({
      client: input.client,
      directory: input.directory,
      project: input.project,
      service,
      onError: (message: string) => input.onLog("warn", message),
    })
    source = bridgeModule.createSourceEndpointAdvertiser({
      getServerURL: input.getServerURL,
      service,
      onError: (message: string) => input.onLog("warn", message),
    })
  } catch (error) {
    state.reservations = Math.max(0, state.reservations - 1)
    await stopIfUnused(state, service, true)
    throw error
  }
  state.reservations = Math.max(0, state.reservations - 1)
  state.leases += 1
  let released = false
  return {
    adapter,
    source,
    async release() {
      if (released) return
      released = true
      try {
        await adapter.idle()
      } finally {
        state.leases = Math.max(0, state.leases - 1)
        await stopIfUnused(state, service, false)
      }
    },
  }
}

function validateOptionsShape(options: NotificationsOptions | undefined): boolean {
  if (options === undefined) return false
  if (!options || typeof options !== "object" || Array.isArray(options)) throw new Error("notifications must be an object")
  const keys = Object.keys(options)
  if (keys.some((key) => !["enabled", "publicOrigin", "port", "dataDir"].includes(key))) throw new Error("notifications contains an unsupported option")
  if (typeof options.enabled !== "boolean") throw new Error("notifications.enabled must be a boolean")
  return options.enabled
}

async function stopIfUnused(state: NotificationState, service: NotificationService, unavailable: boolean): Promise<void> {
  if (state.leases || state.reservations || state.service !== service || state.stopping) return
  state.service = undefined
  state.promise = undefined
  state.unavailable = unavailable
  const stopping = service.stop().finally(() => {
    if (state.stopping !== stopping) return
    state.stopping = undefined
    state.key = undefined
  })
  state.stopping = stopping
  await stopping
}

function normalizeOptions(options: NotificationsOptions) {
  if (typeof options.publicOrigin !== "string") throw new Error("notifications.publicOrigin is required when notifications are enabled")
  const origin = new URL(options.publicOrigin)
  if (origin.protocol !== "https:" || origin.pathname !== "/" || origin.username || origin.password || origin.search || origin.hash) throw new Error("notifications.publicOrigin must be an HTTPS origin without a path, credentials, query, or fragment")
  const port = options.port ?? 4319
  if (!Number.isInteger(port) || port < 1 || port > 65_535) throw new Error("notifications.port must be an integer from 1 through 65535")
  if (options.dataDir !== undefined && (typeof options.dataDir !== "string" || !options.dataDir.trim())) throw new Error("notifications.dataDir must be a non-empty path")
  return { publicOrigin: origin.origin, port, ...(options.dataDir ? { dataDir: resolve(options.dataDir) } : {}) }
}

function defaultNotificationDataDir(): string {
  const stateHome = process.env.XDG_STATE_HOME || (process.env.HOME ? resolve(process.env.HOME, ".local", "state") : undefined)
  if (!stateHome) throw new Error("notifications.dataDir is required when no user state directory is available")
  return resolve(stateHome, "opencode", "openclient", "notifications")
}

function notificationCLIPath(): string {
  return fileURLToPath(new URL("../dist/notifications/src/cli.mjs", import.meta.url))
}

async function loadNotificationModule(): Promise<NotificationModule> {
  const path = fileURLToPath(new URL("../dist/notifications/src/server.mjs", import.meta.url))
  return import(path) as Promise<NotificationModule>
}

async function loadBridgeModule(): Promise<BridgeModule> {
  const path = fileURLToPath(new URL("../dist/notifications/src/plugin-bridge.mjs", import.meta.url))
  return import(path) as Promise<BridgeModule>
}
