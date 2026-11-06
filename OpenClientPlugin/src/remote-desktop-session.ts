import { randomBytes, timingSafeEqual } from "node:crypto"
import { createConnection, type Socket } from "node:net"
import type { ServerWebSocket } from "bun"
import { parseVNCTarget, RemoteDesktopDiscovery } from "./remote-desktop.js"
import { RemoteDesktopHandoffs } from "./remote-desktop-handoff.js"
import { isLocalDesktopHost, observeMacClipboard, type ClipboardObserver } from "./remote-desktop-clipboard.js"

export type DesktopSocketData = { desktopTicket: string; clipboard?: boolean }
type Peer = ServerWebSocket<DesktopSocketData>

/** Host-scoped, binary transport. The browser negotiates VNC authentication end-to-end. */
export class RemoteDesktopSessions {
  readonly discovery: RemoteDesktopDiscovery
  readonly handoffs = new RemoteDesktopHandoffs()
  private readonly tickets = new Map<string, number>()
  private readonly connections = new Map<Peer, { tcp: Socket; expiry: ReturnType<typeof setTimeout>; clipboardAvailable: boolean; stopClipboard?: () => void }>()

  constructor(private readonly targetURL?: string, private readonly token?: string, private readonly rpcEnabled = false,
    private readonly observeClipboard: ClipboardObserver = observeMacClipboard) {
    this.discovery = new RemoteDesktopDiscovery(targetURL)
  }

  get enabled() { return Boolean(this.targetURL && (this.rpcEnabled || (this.token && this.token.length >= 32))) }
  // Static so a hot-reloaded RPC can also address an existing bridge lease
  // created by the previous plugin module generation.
  static credentialScope(session: RemoteDesktopSessions) { return session.targetURL ?? "" }

  authorized(request: Request): boolean {
    if (!this.enabled || !this.token || this.token.length < 32 || request.headers.has("origin")) return false
    const actual = Buffer.from(request.headers.get("authorization") ?? "")
    const expected = Buffer.from(`Bearer ${this.token}`)
    return actual.length === expected.length && timingSafeEqual(actual, expected)
  }

  async capability() {
    const detected = await this.discovery.capability()
    return { ...detected, viewerAvailable: this.enabled && detected.state === "detected" }
  }

  async ticket(): Promise<string | undefined> {
    const now = Date.now()
    for (const [key, expiry] of this.tickets) if (expiry <= now) this.tickets.delete(key)
    if (this.tickets.size + this.connections.size >= 8 || !(await this.capability()).viewerAvailable) return
    // Recheck after the async probe so concurrent requests cannot exceed the bound.
    if (this.tickets.size + this.connections.size >= 8) return
    const ticket = randomBytes(32).toString("base64url")
    this.tickets.set(ticket, Date.now() + 30_000)
    return ticket
  }

  consume(ticket: string): boolean {
    const expiry = this.tickets.get(ticket)
    this.tickets.delete(ticket)
    return expiry !== undefined && expiry > Date.now()
  }

  open(peer: Peer) {
    if (!this.enabled || this.connections.size >= 8) { peer.close(1013, "Unavailable"); return }
    let target
    try { target = parseVNCTarget(this.targetURL!) } catch { peer.close(1011, "Unavailable"); return }
    const tcp = createConnection({ host: target.host, port: target.port })
    const expiry = setTimeout(() => peer.close(1000, "Session expired"), 60 * 60_000)
    const clipboardAvailable = process.platform === "darwin" && isLocalDesktopHost(target.host)
    this.connections.set(peer, { tcp, expiry, clipboardAvailable })
    if (peer.data.clipboard) peer.send(JSON.stringify({ type: "clipboard.capability", available: clipboardAvailable }))
    tcp.setTimeout(10_000, () => peer.close(1011, "Desktop unavailable"))
    tcp.once("connect", () => tcp.setTimeout(0))
    tcp.on("data", (data) => {
      const sent = peer.sendBinary(data)
      if (sent === -1) tcp.pause()
      else if (sent === 0) peer.close(1011, "Desktop stream closed")
    })
    tcp.on("error", () => peer.close(1011, "Desktop unavailable"))
    tcp.on("close", () => peer.close(1000, "Desktop disconnected"))
  }

  message(peer: Peer, payload: string | Buffer) {
    const connection = this.connections.get(peer)
    if (!connection) { peer.close(1003, "Binary data required"); return }
    if (typeof payload === "string") {
      if (peer.data.clipboard && connection.clipboardAvailable && payload === '{"type":"clipboard.subscribe"}') {
        connection.stopClipboard ??= this.observeClipboard((text) => {
          if (this.connections.get(peer) !== connection) return
          // Drop captures for a backlogged viewer rather than grow the socket queue.
          if (peer.getBufferedAmount() <= 1_048_576) peer.send(JSON.stringify({ type: "clipboard.text", text }))
        }, (ready) => {
          if (this.connections.get(peer) === connection) peer.send(JSON.stringify({ type: "clipboard.status", ready }))
        })
        return
      }
      peer.close(1003, "Unsupported desktop control")
      return
    }
    if (connection.tcp.writableLength + payload.length > 1_048_576) {
      peer.close(1009, "Input limit exceeded")
      return
    }
    connection.tcp.write(payload)
  }

  drain(peer: Peer) { this.connections.get(peer)?.tcp.resume() }

  close(peer: Peer) {
    const connection = this.connections.get(peer)
    this.connections.delete(peer)
    if (connection) { connection.stopClipboard?.(); clearTimeout(connection.expiry); connection.tcp.destroy() }
  }

  stop() {
    this.handoffs.stop()
    this.tickets.clear()
    for (const peer of this.connections.keys()) { peer.close(1001, "Server stopped"); this.close(peer) }
  }
}
