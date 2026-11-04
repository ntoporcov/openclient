import { createConnection } from "node:net"
import { readFile } from "node:fs/promises"

export type RemoteDesktopOptions = { url?: string; tokenFile?: string }

/** Explicit options also work in managed hosts that filter process environment variables. */
export async function remoteDesktopBridgeOptions(options?: RemoteDesktopOptions) {
  let token: string | undefined
  if (options?.tokenFile !== undefined) {
    try { token = (await readFile(options.tokenFile, "utf8")).trim() }
    catch { token = "" }
  }
  return { remoteDesktopURL: options?.url, remoteDesktopToken: token }
}

export type RemoteDesktopCapability = {
  version: 1
  state: "unconfigured" | "unavailable" | "detected"
  transport: "rfb"
  protocolVersion?: string
}

export type VNCTarget = { host: string; port: number }

/** Credentials are negotiated by the viewer, never embedded in configuration URLs. */
export function parseVNCTarget(value: string): VNCTarget {
  const url = new URL(value)
  if (url.protocol !== "vnc:" || !url.hostname || url.username || url.password
    || (url.pathname !== "" && url.pathname !== "/") || url.search || url.hash) {
    throw new Error("Expected vnc://host[:port] without credentials or a path")
  }
  const port = url.port ? Number(url.port) : 5900
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid VNC port")
  return { host: url.hostname.replace(/^\[|\]$/g, ""), port }
}

/** Read only the greeting; never authenticate, select a desktop, or send input. */
export function probeVNC(target: VNCTarget, timeoutMS = 1000): Promise<string | undefined> {
  return new Promise((resolve) => {
    const socket = createConnection({ host: target.host, port: target.port })
    const greeting = Buffer.alloc(12)
    let received = 0
    let finished = false
    const finish = (version?: string) => {
      if (finished) return
      finished = true
      clearTimeout(deadline)
      socket.destroy()
      resolve(version)
    }
    // Bound DNS lookup and peers trickling partial bytes with an absolute deadline.
    const deadline = setTimeout(() => finish(), timeoutMS)
    socket.on("error", () => finish())
    socket.on("close", () => finish())
    socket.on("data", (data: Buffer) => {
      const length = Math.min(data.length, greeting.length - received)
      data.copy(greeting, received, 0, length)
      received += length
      if (received !== greeting.length) return
      const match = /^RFB (\d{3}\.\d{3})\n$/.exec(greeting.toString("ascii"))
      finish(match?.[1])
    })
  })
}

export class RemoteDesktopDiscovery {
  private cached?: { expires: number; value: RemoteDesktopCapability }
  private pending?: Promise<RemoteDesktopCapability>

  constructor(private readonly configuredURL: string | undefined) {}

  capability(): Promise<RemoteDesktopCapability> {
    if (this.cached && this.cached.expires > Date.now()) return Promise.resolve(this.cached.value)
    if (this.pending) return this.pending
    this.pending = this.discover().then((value) => {
      this.cached = { expires: Date.now() + 5000, value }
      return value
    }).finally(() => { this.pending = undefined })
    return this.pending
  }

  private async discover(): Promise<RemoteDesktopCapability> {
    const base = { version: 1, transport: "rfb" } as const
    if (!this.configuredURL) return { ...base, state: "unconfigured" }
    try {
      const protocolVersion = await probeVNC(parseVNCTarget(this.configuredURL))
      return protocolVersion
        ? { ...base, state: "detected", protocolVersion }
        : { ...base, state: "unavailable" }
    } catch {
      return { ...base, state: "unavailable" }
    }
  }
}
