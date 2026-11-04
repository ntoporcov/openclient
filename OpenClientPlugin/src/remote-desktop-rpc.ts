import { Rpc } from "@opencode/plugin/rpc"
import type { Plugin } from "@opencode/plugin"
import { createHash } from "node:crypto"
import { RemoteDesktopSessions } from "./remote-desktop-session.js"

// This control plane runs behind OpenCode's own HTTP authentication, never on
// the unauthenticated discovery bridge. Only the single-use ticket crosses it.
export const DesktopRPC = Rpc.define({
  id: "openclient.desktop",
  events: {},
  methods: {
    open: {
      input: { type: "object", additionalProperties: false },
      output: { type: "object", properties: { ticket: { type: "string" }, targetID: { type: "string" } }, required: ["ticket", "targetID"], additionalProperties: false },
    },
    complete: {
      input: { type: "object", properties: {
        requestID: { type: "string" }, sessionID: { type: "string" },
        messageID: { type: "string" }, outcome: { type: "string", enum: ["done", "cancelled"] },
      }, required: ["requestID", "sessionID", "messageID", "outcome"], additionalProperties: false },
      output: { type: "object", properties: { completed: { type: "boolean" } }, required: ["completed"], additionalProperties: false },
    },
  },
})

export function registerDesktopRPC(ctx: Plugin.Context, desktop: RemoteDesktopSessions) {
  return ctx.rpc.register(DesktopRPC, {
    open: async () => {
      const ticket = await desktop.ticket()
      if (!ticket) throw new Error("Desktop unavailable")
      return { ticket, targetID: createHash("sha256").update(RemoteDesktopSessions.credentialScope(desktop)).digest("hex") }
    },
    complete: async (input) => {
      const value = input as { requestID: string; sessionID: string; messageID: string; outcome: "done" | "cancelled" }
      if (!/^[a-f0-9-]{36}$/.test(value.requestID)) throw new Error("Invalid handoff ID")
      return { completed: desktop.handoffs.complete(value.requestID, value.sessionID, value.messageID, value.outcome) }
    },
  })
}
