import { readFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalSessionTarget } from "./session-target.mjs";
import { sanitizeSourceEndpoint } from "./source-endpoint.mjs";
import { displayContextForSession } from "./display-context.mjs";

export const BRIDGE_SOURCE = "openclient-ios-local";
const DEFAULT_TOKEN_FILE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../.data/bridge-token");
const PROCESS_ID = randomBytes(8).toString("hex");
const sharedCycles = new Map();
const MAX_SHARED_CYCLES = 2_000;
const SOURCE_ADVERTISE_INTERVAL_MS = 60_000;

function boundedString(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256 ? value : undefined;
}

export function createPluginBridge({ client, directory, project, service, fetchImpl = fetch, tokenFile = DEFAULT_TOKEN_FILE, bridgeURL = "http://127.0.0.1:4320/ingest", timeoutMs = 2_000, maxQueue = 100, maxDedupe = 1_000, maxCycles = 500, onError = (message) => console.warn(message) }) {
  const cycles = new Map();
  const seen = new Map();
  const projects = new Map();
  const resolvedRequests = new Set();
  if (project && typeof project === "object" && boundedString(project.id)) projects.set(project.id, project);
  const queue = [];
  let running = false;

  const remember = (key) => {
    if (seen.has(key)) return false;
    seen.set(key, Date.now());
    while (seen.size > maxDedupe) seen.delete(seen.keys().next().value);
    return true;
  };
  const post = async (event) => {
    if (service) return service.ingest(event);
    const token = (await readFile(tokenFile, "utf8")).trim();
    if (!token) return;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(bridgeURL, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ source: BRIDGE_SOURCE, event }),
        signal: controller.signal
      });
      if (!response?.ok) {
        const status = Number.isInteger(response?.status) && response.status >= 100 && response.status <= 599 ? response.status : "unknown";
        throw new Error(`bridge-http:${status}`);
      }
    } finally { clearTimeout(timer); }
  };
  const report = (error) => {
    const match = /^bridge-http:(\d{3}|unknown)$/.exec(error?.message || "");
    try { onError(match ? `Notification bridge HTTP request failed (status ${match[1]}).` : error?.message === "session-lookup-timeout" ? "Notification bridge session lookup timed out." : "Notification bridge task failed."); } catch { /* Diagnostics must remain fail-open. */ }
  };
  const drain = async () => {
    if (running) return;
    running = true;
    while (queue.length) {
      try { await queue.shift()(); } catch (error) { report(error); }
    }
    running = false;
  };
  const enqueue = (task) => {
    if (queue.length >= maxQueue) queue.shift();
    queue.push(task);
    void drain();
  };
  const setCycle = (sessionID, cycle) => {
    cycles.delete(sessionID);
    cycles.set(sessionID, cycle);
    while (cycles.size > maxCycles) cycles.delete(cycles.keys().next().value);
  };
  const loadTarget = async (sessionID) => {
    const controller = new AbortController();
    let timer;
    const timeout = new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error("session-lookup-timeout")); }, timeoutMs); });
    let result;
    try {
      result = await Promise.race([client.session.get({ path: { id: sessionID }, query: { directory }, signal: controller.signal }), timeout]);
    } finally { clearTimeout(timer); }
    if (result?.error || !result?.data) throw new Error("Canonical session lookup failed.");
    if (result.data.id !== sessionID) throw new Error("Canonical session ID mismatch.");
    return { session: result.data, target: canonicalSessionTarget(result.data), context: displayContextForSession(result.data, projects) };
  };

  const handle = (raw) => {
    const type = raw?.type;
    const properties = raw?.properties;
    if (type === "project.updated") {
      if (properties && typeof properties === "object" && boundedString(properties.id)) projects.set(properties.id, properties);
      return;
    }
    const sessionID = boundedString(properties?.sessionID ?? properties?.info?.id);
    if (!sessionID) return;

    if (type === "session.status") {
      const status = properties?.status?.type;
      if (status === "busy" || status === "retry") {
        const cycle = cycles.get(sessionID) || { active: false, cycleID: "", failed: false };
        if (!cycle.active) {
          const sharedKey = `${directory}\0${sessionID}`;
          let shared = sharedCycles.get(sharedKey);
          if (!shared?.active) shared = { active: true, cycleID: randomBytes(8).toString("hex"), failed: false };
          shared.failed = false;
          sharedCycles.delete(sharedKey); sharedCycles.set(sharedKey, shared);
          while (sharedCycles.size > MAX_SHARED_CYCLES) sharedCycles.delete(sharedCycles.keys().next().value);
          cycle.cycleID = shared.cycleID;
        }
        cycle.active = true;
        cycle.failed = false;
        setCycle(sessionID, cycle);
        const key = `activity:${sessionID}:${cycle.cycleID}:${status}`;
        if (remember(key)) enqueue(() => post({ kind: "activity", sessionID }));
        return;
      }
      if (status !== "idle") return;
      const sharedKey = `${directory}\0${sessionID}`;
      const shared = sharedCycles.get(sharedKey);
      const cycle = cycles.get(sessionID) || (shared?.active ? { active: true, cycleID: shared.cycleID, failed: Boolean(shared.failed) } : undefined);
      if (!cycle?.active || cycle.failed) return;
      cycle.active = false;
      setCycle(sessionID, cycle);
      if (shared?.cycleID === cycle.cycleID) shared.active = false;
      const key = `${PROCESS_ID}:idle:${sessionID}:${cycle.cycleID}`;
      if (!remember(key)) return;
      enqueue(async () => {
        const { session, target, context } = await loadTarget(sessionID);
        const current = cycles.get(sessionID);
        if (current?.active || current?.cycleID !== cycle.cycleID || current?.failed) return;
        if (session.parentID) return;
        await post({ kind: "idle", eventID: key, target, context });
      });
      return;
    }
    if (type === "session.idle") return;
    if (type === "session.error") {
      const cycle = cycles.get(sessionID) || { active: false, cycleID: "", failed: false };
      cycle.active = false;
      cycle.failed = true;
      setCycle(sessionID, cycle);
      const sharedKey = `${directory}\0${sessionID}`;
      const shared = sharedCycles.get(sharedKey);
      if (shared?.cycleID === cycle.cycleID) { shared.active = false; shared.failed = true; }
      const key = `error:${sessionID}:${cycle.cycleID}`;
      if (remember(key)) enqueue(() => post({ kind: "error", sessionID }));
      return;
    }
    if (type === "permission.asked" || type === "question.asked") {
      const requestID = boundedString(properties?.id);
      if (!requestID) return;
      const kind = type === "permission.asked" ? "permission" : "question";
      const key = `${kind}:${requestID}`;
      if (!remember(key)) return;
      enqueue(async () => {
        const { target, context } = await loadTarget(sessionID);
        if (resolvedRequests.has(requestID)) return;
        await post({ kind, eventID: key, requestID, target, context });
      });
      return;
    }
    if (["permission.replied", "question.replied", "question.rejected"].includes(type)) {
      const requestID = boundedString(properties?.requestID ?? properties?.permissionID);
      if (!requestID) return;
      const kind = type.startsWith("permission") ? "permission-resolved" : "question-resolved";
      const key = `${kind}:${requestID}`;
      resolvedRequests.add(requestID);
      while (resolvedRequests.size > maxDedupe) resolvedRequests.delete(resolvedRequests.values().next().value);
      if (remember(key)) enqueue(() => post({ kind, requestID, sessionID }));
      return;
    }
    if (type === "session.deleted") {
      cycles.delete(sessionID);
      sharedCycles.delete(`${directory}\0${sessionID}`);
      const key = `deleted:${sessionID}`;
      if (remember(key)) enqueue(() => post({ kind: "session-deleted", sessionID }));
    }
  };

  return { handle, idle: () => new Promise((resolve) => {
    const check = () => running || queue.length ? setTimeout(check, 5) : resolve();
    check();
  }) };
}

export function createSourceEndpointAdvertiser({ getServerURL, service, fetchImpl = fetch, tokenFile = DEFAULT_TOKEN_FILE, metadataURL = "http://127.0.0.1:4320/metadata", timeoutMs = 2_000, intervalMs = SOURCE_ADVERTISE_INTERVAL_MS, now = Date.now, onError = (message) => console.warn(message) }) {
  let lastKey = "";
  let lastAttempt = 0;
  let running = false;
  const advertise = async () => {
    let endpoint;
    try { endpoint = sanitizeSourceEndpoint(getServerURL()); } catch { endpoint = null; }
    if (!endpoint) return false;
    const key = `${endpoint.protocol}:${endpoint.port}`;
    const current = now();
    if (running || (key === lastKey && current - lastAttempt < intervalMs)) return false;
    lastKey = key;
    lastAttempt = current;
    running = true;
    try {
      if (service) { await service.updateSource(endpoint); return true; }
      const token = (await readFile(tokenFile, "utf8")).trim();
      if (!token) return false;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetchImpl(metadataURL, {
          method: "POST",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ source: BRIDGE_SOURCE, sourceEndpoint: endpoint }),
          signal: controller.signal
        });
        if (!response?.ok) throw new Error("source-endpoint-http");
        return true;
      } finally { clearTimeout(timer); }
    } catch {
      try { onError("Notification bridge source hint failed."); } catch { /* Diagnostics must remain fail-open. */ }
      return false;
    } finally { running = false; }
  };
  return { advertise };
}

export async function notificationPWAPlugin(input) {
  const bridge = createPluginBridge({ client: input.client, directory: input.directory, project: input.project });
  const source = createSourceEndpointAdvertiser({ getServerURL: () => input.serverUrl });
  void source.advertise();
  return { event: async ({ event }) => {
    void source.advertise();
    bridge.handle(event);
  } };
}
