export type LegacyNotificationEvent = {
  type: string
  properties: Record<string, unknown>
}

type UnknownRecord = Record<string, unknown>

export function normalizeV2NotificationEvent(raw: unknown): LegacyNotificationEvent | undefined {
  if (!isRecord(raw) || typeof raw.type !== "string" || !isRecord(raw.data)) return undefined

  const data = raw.data
  switch (raw.type) {
    case "session.execution.started":
    case "session.execution.succeeded":
      if (!hasString(data, "sessionID")) return undefined
      return {
        type: "session.status",
        properties: { sessionID: data.sessionID, status: { type: raw.type.endsWith("started") ? "busy" : "idle" } },
      }
    case "form.created": {
      const form = data.form
      if (!isRecord(form) || !hasString(form, "id") || !hasString(form, "sessionID")) return undefined
      return { type: "question.asked", properties: { id: form.id, sessionID: form.sessionID } }
    }
    case "form.replied":
      return lifecycleEvent("question.replied", data, "id")
    case "form.cancelled":
      return lifecycleEvent("question.rejected", data, "id")
    case "permission.asked":
      if (!hasString(data, "id") || !hasString(data, "sessionID") || typeof data.action !== "string" || !Array.isArray(data.resources)) return undefined
      return { type: raw.type, properties: data }
    case "permission.replied":
      if (!hasString(data, "sessionID") || !hasString(data, "requestID") || !isPermissionReply(data.reply)) return undefined
      return { type: raw.type, properties: data }
    case "session.status":
      if (!hasString(data, "sessionID") || !isSessionStatus(data.status)) return undefined
      return { type: raw.type, properties: data }
    case "session.deleted":
      return hasString(data, "sessionID") ? { type: raw.type, properties: { sessionID: data.sessionID } } : undefined
    case "session.execution.failed":
    case "session.execution.interrupted":
    case "session.step.failed":
    case "session.compaction.failed":
      return hasString(data, "sessionID") ? { type: "session.error", properties: data } : undefined
    default:
      return undefined
  }
}

export function normalizeV2Session(raw: unknown): UnknownRecord | undefined {
  if (!isRecord(raw) || !hasString(raw, "id") || !hasString(raw, "projectID") || !isRecord(raw.location) || !hasString(raw.location, "directory")) {
    return undefined
  }

  const sourceLocation = raw.location as UnknownRecord
  const location = { ...sourceLocation, projectID: raw.projectID }
  const result: UnknownRecord = {
    ...raw,
    projectID: raw.projectID,
    directory: sourceLocation.directory,
    location,
  }
  if (sourceLocation.workspaceID !== undefined) {
    if (typeof sourceLocation.workspaceID !== "string") return undefined
    result.workspaceID = sourceLocation.workspaceID
  }
  if (raw.parentID !== undefined && typeof raw.parentID !== "string") return undefined
  return result
}

function lifecycleEvent(type: string, data: UnknownRecord, sourceKey: string): LegacyNotificationEvent | undefined {
  if (!hasString(data, sourceKey) || !hasString(data, "sessionID")) return undefined
  return { type, properties: { requestID: data[sourceKey], sessionID: data.sessionID } }
}

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function hasString(record: UnknownRecord, key: string): record is UnknownRecord & Record<string, string> {
  return typeof record[key] === "string" && record[key].length > 0
}

function isPermissionReply(value: unknown): value is "once" | "always" | "reject" {
  return value === "once" || value === "always" || value === "reject"
}

function isSessionStatus(value: unknown): boolean {
  if (!isRecord(value) || (value.type !== "idle" && value.type !== "busy" && value.type !== "retry")) return false
  if (value.type !== "retry") return true
  return typeof value.attempt === "number" && Number.isInteger(value.attempt) && value.attempt >= 0 &&
    typeof value.message === "string" && typeof value.next === "number" && Number.isInteger(value.next) && value.next >= 0
}
