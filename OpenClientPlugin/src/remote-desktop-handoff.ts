import { randomUUID } from "node:crypto"

export type DesktopHandoff = { requestID: string; sessionID: string; messageID: string; reason: string }
export type DesktopOutcome = "done" | "cancelled"

export class RemoteDesktopHandoffs {
  private readonly pending = new Map<string, { request: DesktopHandoff; finish: (outcome: DesktopOutcome) => void }>()

  request(input: Omit<DesktopHandoff, "requestID">, signal: AbortSignal) {
    signal.throwIfAborted()
    if (this.pending.size >= 32) throw new Error("Too many pending remote desktop requests")
    const request = { ...input, requestID: randomUUID() }
    const result = new Promise<DesktopOutcome>((resolve, reject) => {
      const cleanup = () => { clearTimeout(timer); signal.removeEventListener("abort", abort); this.pending.delete(request.requestID) }
      const abort = () => { cleanup(); reject(new DOMException("Remote desktop request aborted", "AbortError")) }
      const timer = setTimeout(() => { cleanup(); resolve("cancelled") }, 30 * 60_000)
      this.pending.set(request.requestID, { request, finish: (outcome) => { cleanup(); resolve(outcome) } })
      signal.addEventListener("abort", abort, { once: true })
    })
    return { request, result }
  }

  complete(requestID: string, sessionID: string, messageID: string, outcome: DesktopOutcome): boolean {
    const entry = this.pending.get(requestID)
    if (!entry || entry.request.sessionID !== sessionID || entry.request.messageID !== messageID) return false
    entry.finish(outcome)
    return true
  }

  stop() { for (const entry of this.pending.values()) entry.finish("cancelled") }
}
