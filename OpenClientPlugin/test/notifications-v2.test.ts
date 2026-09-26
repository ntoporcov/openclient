import { describe, expect, test } from "bun:test"
import { normalizeV2NotificationEvent, normalizeV2Session } from "../src/notifications-v2.js"

describe("v2 notification normalization", () => {
  test("maps forms to the legacy question lifecycle", () => {
    expect(normalizeV2NotificationEvent({
      id: "evt_1", type: "form.created", location: { directory: "/actual" },
      data: { form: { id: "frm_1", sessionID: "ses_1", title: "Choose", fields: [] } },
    })).toEqual({ type: "question.asked", properties: { id: "frm_1", sessionID: "ses_1" } })
    expect(normalizeV2NotificationEvent({ type: "form.replied", data: { id: "frm_1", sessionID: "ses_1", answer: { key: "yes" } } }))
      .toEqual({ type: "question.replied", properties: { requestID: "frm_1", sessionID: "ses_1" } })
    expect(normalizeV2NotificationEvent({ type: "form.cancelled", data: { id: "frm_1", sessionID: "ses_1" } }))
      .toEqual({ type: "question.rejected", properties: { requestID: "frm_1", sessionID: "ses_1" } })
  })

  test("maps schema-shaped permissions and session status", () => {
    const permission = { id: "per_1", sessionID: "ses_1", action: "write", resources: ["/tmp/a"], source: { type: "tool", messageID: "msg_1", id: "call_1" } }
    expect(normalizeV2NotificationEvent({ type: "permission.asked", data: permission })).toEqual({ type: "permission.asked", properties: permission })
    expect(normalizeV2NotificationEvent({ type: "permission.replied", data: { sessionID: "ses_1", requestID: "per_1", reply: "once" } }))
      .toEqual({ type: "permission.replied", properties: { sessionID: "ses_1", requestID: "per_1", reply: "once" } })
    expect(normalizeV2NotificationEvent({ type: "session.status", data: { sessionID: "ses_1", status: { type: "busy" } } }))
      .toEqual({ type: "session.status", properties: { sessionID: "ses_1", status: { type: "busy" } } })
  })

  test("maps session turn failures but not tool failures or malformed events", () => {
    expect(normalizeV2NotificationEvent({ type: "session.execution.failed", data: { sessionID: "ses_1", error: { name: "Error" } } }))
      .toEqual({ type: "session.error", properties: { sessionID: "ses_1", error: { name: "Error" } } })
    expect(normalizeV2NotificationEvent({ type: "session.tool.failed", data: { sessionID: "ses_1", error: {} } })).toBeUndefined()
    expect(normalizeV2NotificationEvent({ type: "session.execution.interrupted", data: { sessionID: "ses_1" } }))
      .toEqual({ type: "session.error", properties: { sessionID: "ses_1" } })
    expect(normalizeV2NotificationEvent({ type: "session.execution.succeeded", data: {} })).toBeUndefined()
    expect(normalizeV2NotificationEvent({ type: "session.deleted", data: { sessionID: "ses_1" } }))
      .toEqual({ type: "session.deleted", properties: { sessionID: "ses_1" } })
    expect(normalizeV2NotificationEvent({ type: "form.created", data: { form: { id: "frm_1" } } })).toBeUndefined()
    expect(normalizeV2NotificationEvent({ type: "session.status", data: { sessionID: "ses_1", status: { type: "unknown" } } })).toBeUndefined()
  })
})

describe("v2 session normalization", () => {
  test("exposes canonical location values through the legacy session shape", () => {
    const session = normalizeV2Session({
      id: "ses_1", projectID: "project_1", parentID: "ses_parent", title: "Demo",
      location: { directory: "/workspace/project", workspaceID: "work_1" },
    })
    expect(session).toMatchObject({
      id: "ses_1", projectID: "project_1", directory: "/workspace/project", workspaceID: "work_1",
      parentID: "ses_parent", location: { directory: "/workspace/project", workspaceID: "work_1", projectID: "project_1" },
    })
  })

  test("fails closed when canonical target fields are missing or invalid", () => {
    expect(normalizeV2Session({ id: "ses_1", location: { directory: "/workspace" } })).toBeUndefined()
    expect(normalizeV2Session({ id: "ses_1", projectID: "project_1", location: {} })).toBeUndefined()
    expect(normalizeV2Session({ id: "ses_1", projectID: "project_1", location: { directory: "/workspace", workspaceID: 1 } })).toBeUndefined()
    expect(normalizeV2Session(null)).toBeUndefined()
  })
})

test("v2 events drive the shared notification adapter using the canonical session target", async () => {
  const modulePath = "../dist/notifications/src/plugin-bridge.mjs"
  const { createPluginBridge } = await import(modulePath)
  const delivered: Array<Record<string, unknown>> = []
  const adapter = createPluginBridge({
    directory: "/plugin-instance", project: undefined,
    client: { session: { get: async () => ({ data: normalizeV2Session({
      id: "ses_v2integration", projectID: "project_actual", title: "Actual session",
      location: { directory: "/actual/location", workspaceID: "wrk_actual" },
    }) }) } },
    service: { ingest: async (event: Record<string, unknown>) => delivered.push(event) },
    onError: (message: string) => { throw new Error(message) },
  })
  const handle = (type: string, data: Record<string, unknown>) => adapter.handle(normalizeV2NotificationEvent({ type, data }))
  handle("session.execution.started", { sessionID: "ses_v2integration" })
  handle("session.execution.succeeded", { sessionID: "ses_v2integration" })
  // Hosts that also emit the legacy status must not send duplicate completions.
  handle("session.status", { sessionID: "ses_v2integration", status: { type: "idle" } })
  handle("form.created", { form: { id: "frm_v2integration", sessionID: "ses_v2integration" } })
  handle("permission.asked", { id: "per_v2integration", sessionID: "ses_v2integration", action: "write", resources: ["/actual/file"] })
  await adapter.idle()
  for (const kind of ["idle", "question", "permission"]) {
    expect(delivered.find((event) => event.kind === kind)?.target).toEqual({
      sessionID: "ses_v2integration", projectID: "project_actual", directory: "/actual/location", workspaceID: "wrk_actual",
    })
  }
  handle("form.replied", { id: "frm_v2integration", sessionID: "ses_v2integration" })
  handle("permission.replied", { requestID: "per_v2integration", sessionID: "ses_v2integration", reply: "once" })
  handle("session.deleted", { sessionID: "ses_v2integration" })
  await adapter.idle()
  expect(delivered.map((event) => event.kind)).toEqual([
    "activity", "idle", "question", "permission", "question-resolved", "permission-resolved", "session-deleted",
  ])
})
