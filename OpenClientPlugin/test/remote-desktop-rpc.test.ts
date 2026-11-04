import { expect, test } from "bun:test"
import type { Plugin } from "@opencode/plugin"
import { registerDesktopRPC } from "../src/remote-desktop-rpc.js"
import { RemoteDesktopSessions } from "../src/remote-desktop-session.js"
import { startVNCFixture } from "./fixtures/vnc-server.js"

test("authenticated RPC issues single-use tickets without enabling anonymous bridge access", async () => {
  const fixture = await startVNCFixture({ username: "fixture-user", password: "fixture-password" })
  const desktop = new RemoteDesktopSessions(`vnc://127.0.0.1:${fixture.port}`, undefined, true)
  let handlers: {
    open(): Promise<{ ticket: string; targetID: string }>
    complete(input: { requestID: string; sessionID: string; messageID: string; outcome: string }): Promise<{ completed: boolean }>
  } | undefined
  const ctx = { rpc: { register: async (_definition: unknown, value: unknown) => {
    handlers = value as typeof handlers
    return { dispose: async () => {} }
  } } } as unknown as Plugin.Context
  try {
    await registerDesktopRPC(ctx, desktop)
    expect(desktop.enabled).toBe(true)
    for (const authorization of [undefined, "Bearer undefined", "Bearer arbitrary"]) {
      expect(desktop.authorized(new Request("http://localhost/openclient/v1/desktop/sessions", {
        headers: authorization ? { authorization } : {},
      }))).toBe(false)
    }
    const first = await handlers!.open()
    expect(first.ticket.length).toBe(43)
    expect(first.targetID).toMatch(/^[a-f0-9]{64}$/)
    expect(desktop.consume(first.ticket)).toBe(true)
    expect(desktop.consume(first.ticket)).toBe(false)
    expect((await handlers!.open()).targetID).toBe(first.targetID)
    const handoff = desktop.handoffs.request({ sessionID: "session", messageID: "message", reason: "fixture" }, new AbortController().signal)
    expect((await handlers!.complete({ ...handoff.request, messageID: "wrong", outcome: "done" })).completed).toBe(false)
    expect((await handlers!.complete({ ...handoff.request, outcome: "done" })).completed).toBe(true)
    expect(await handoff.result).toBe("done")
    expect((await handlers!.complete({ ...handoff.request, outcome: "done" })).completed).toBe(false)
  } finally { desktop.stop(); await fixture.stop() }
})
