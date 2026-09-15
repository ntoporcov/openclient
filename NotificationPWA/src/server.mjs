import http from "node:http";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, open, readFile, rename, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import webpush from "web-push";
import { BRIDGE_SOURCE } from "./plugin-bridge.mjs";
import { buildHandoffTarget, canonicalSessionTarget, defaultDestination, validateDestination } from "./session-target.mjs";
import { sanitizeSourceEndpoint, validateSourceEndpoint } from "./source-endpoint.mjs";
import { cleanDisplayText, validateDisplayContext } from "./display-context.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const publicDir = path.join(root, "public");
const staticFiles = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]], ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]], ["/styles.css", ["styles.css", "text/css; charset=utf-8"]],
  ["/events.html", ["events.html", "text/html; charset=utf-8"]], ["/events.js", ["events.js", "text/javascript; charset=utf-8"]],
  ["/sw.js", ["sw.js", "text/javascript; charset=utf-8"]], ["/handoff-core.js", ["handoff-core.js", "text/javascript; charset=utf-8"]],
  ["/manifest.webmanifest", ["manifest.webmanifest", "application/manifest+json"]], ["/handoff.html", ["handoff.html", "text/html; charset=utf-8"]],
  ["/handoff.js", ["handoff.js", "text/javascript; charset=utf-8"]], ["/icons/icon-180.png", ["icons/icon-180.png", "image/png"]],
  ["/icons/icon-192.png", ["icons/icon-192.png", "image/png"]], ["/icons/icon-512.png", ["icons/icon-512.png", "image/png"]]
]);
const EVENT_KINDS = new Set(["activity", "idle", "error", "permission", "question", "permission-resolved", "question-resolved", "session-deleted"]);
const MAX_PUSH_PAYLOAD_BYTES = 3_500;
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const constantEqual = (a, b) => {
  const left = Buffer.from(a); const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
};

export function allowedPushEndpoint(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || (url.port && url.port !== "443") || url.username || url.password) return false;
    const host = url.hostname.toLowerCase();
    return host === "web.push.apple.com" || host.endsWith(".push.apple.com") || host === "fcm.googleapis.com" || host === "updates.push.services.mozilla.com";
  } catch { return false; }
}

async function readJSON(file, fallback) {
  try { return JSON.parse(await readFile(file, "utf8")); } catch (error) { if (error.code === "ENOENT") return fallback; throw error; }
}
async function writePrivate(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  await writeFile(temporary, value, { mode: 0o600 });
  await rename(temporary, file);
}
const writePrivateJSON = (file, value) => writePrivate(file, JSON.stringify(value, null, 2));
function sendJSON(response, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": data.length, "Cache-Control": "no-store" });
  response.end(data);
}
function readBody(request, limit = 8_192) {
  return new Promise((resolve, reject) => {
    let size = 0; let oversized = false; const chunks = [];
    request.on("data", (chunk) => { size += chunk.length; if (size > limit) oversized = true; else if (!oversized) chunks.push(chunk); });
    request.on("end", () => {
      if (oversized) return reject(Object.assign(new Error("Request body is too large."), { status: 413 }));
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); }
      catch { reject(Object.assign(new Error("Request body must be valid JSON."), { status: 400 })); }
    });
    request.on("error", reject);
  });
}
function cleanDevice(device) {
  return { ...device, destination: (() => {
    try { return validateDestination(device.destination); } catch { return defaultDestination(); }
  })() };
}
function validID(value) { return typeof value === "string" && /^[A-Za-z0-9._:-]{1,256}$/.test(value); }
function validateBridgeEvent(event) {
  if (!event || typeof event !== "object" || Array.isArray(event) || !EVENT_KINDS.has(event.kind)) throw new TypeError("Unsupported bridge event.");
  const keys = {
    activity: ["kind", "sessionID"], error: ["kind", "sessionID"], "session-deleted": ["kind", "sessionID"],
    idle: ["kind", "eventID", "target", "context"], permission: ["kind", "eventID", "requestID", "target", "context"], question: ["kind", "eventID", "requestID", "target", "context"],
    "permission-resolved": ["kind", "requestID", "sessionID"], "question-resolved": ["kind", "requestID", "sessionID"]
  }[event.kind];
  const required = keys.filter((key) => key !== "context");
  if (Object.keys(event).some((key) => !keys.includes(key)) || required.some((key) => !(key in event))) throw new TypeError("Bridge event fields are invalid.");
  if (event.sessionID !== undefined && !validID(event.sessionID)) throw new TypeError("Invalid bridge identifiers.");
  if (event.requestID !== undefined && !validID(event.requestID)) throw new TypeError("Invalid bridge identifiers.");
  if (event.eventID !== undefined && (typeof event.eventID !== "string" || !event.eventID || event.eventID.length > 768)) throw new TypeError("Invalid bridge identifiers.");
  if (event.target !== undefined) {
    if (!event.target || typeof event.target !== "object" || Array.isArray(event.target) || Object.keys(event.target).some((key) => !["sessionID", "projectID", "directory", "workspaceID"].includes(key))) throw new TypeError("Invalid canonical target.");
    canonicalSessionTarget({ id: event.target.sessionID, projectID: event.target.projectID, directory: event.target.directory, workspaceID: event.target.workspaceID });
  }
  const context = validateDisplayContext(event.context);
  const { context: _untrustedContext, ...canonical } = event;
  return { ...canonical, ...(context ? { context } : {}) };
}

function pushPayload(kind, data, context) {
  const payload = { kind, data, ...(context ? { context } : {}) };
  if (Buffer.byteLength(JSON.stringify(payload)) <= MAX_PUSH_PAYLOAD_BYTES) return payload;
  const compact = context ? validateDisplayContext({ projectName: context.projectName ? Array.from(context.projectName).slice(0, 40).join("") : undefined, sessionTitle: context.sessionTitle ? Array.from(context.sessionTitle).slice(0, 60).join("") : undefined }) : undefined;
  const smaller = { kind, data, ...(compact ? { context: compact } : {}) };
  if (Buffer.byteLength(JSON.stringify(smaller)) <= MAX_PUSH_PAYLOAD_BYTES) return smaller;
  const canonicalOnly = { kind, data };
  if (Buffer.byteLength(JSON.stringify(canonicalOnly)) <= MAX_PUSH_PAYLOAD_BYTES) return canonicalOnly;
  throw new TypeError("Canonical notification target exceeds the safe Web Push payload size.");
}

export function validatePublicOrigin(value) {
  const publicOrigin = new URL(value);
  if (publicOrigin.protocol !== "https:" || publicOrigin.pathname !== "/" || publicOrigin.search || publicOrigin.hash || publicOrigin.username || publicOrigin.password) throw new Error("PUBLIC_ORIGIN must be an HTTPS origin without a path, credentials, query, or fragment.");
  return publicOrigin;
}

export function defaultNotificationDataDir() {
  const stateHome = process.env.XDG_STATE_HOME || (process.env.HOME ? path.join(process.env.HOME, ".local", "state") : null);
  if (!stateHome) throw new Error("A notification data directory must be configured when no user state directory is available.");
  return path.join(stateHome, "opencode", "openclient", "notifications");
}

async function acquireOwnerLock(dataDir) {
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  await import("node:fs/promises").then(({ chmod }) => chmod(dataDir, 0o700));
  const lockPath = path.join(dataDir, "owner.lock");
  const owner = `${process.pid}:${randomBytes(16).toString("hex")}`;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const handle = await open(lockPath, "wx", 0o600);
      await handle.writeFile(owner);
      await handle.close();
      return async () => {
        try {
          if ((await readFile(lockPath, "utf8")) === owner) await unlink(lockPath);
        } catch (error) { if (error.code !== "ENOENT") throw error; }
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      let record;
      try { record = await readFile(lockPath, "utf8"); }
      catch { throw new Error("Notification data directory ownership lock cannot be verified safely."); }
      const match = /^([1-9]\d*):([a-f0-9]{32})$/.exec(record);
      if (!match) throw new Error("Notification data directory ownership lock cannot be verified safely.");
      const pid = Number(match[1]);
      if (!Number.isSafeInteger(pid)) throw new Error("Notification data directory ownership lock cannot be verified safely.");
      let dead = false;
      try { process.kill(pid, 0); } catch (probe) { dead = probe.code === "ESRCH"; }
      if (!dead || attempt > 0) throw new Error("Notification data directory is already owned by another live process.");
      await unlink(lockPath).catch(() => {});
    }
  }
  throw new Error("Notification data directory ownership could not be established.");
}

export async function createNotificationServer(options = {}) {
  const configuredOrigin = options.publicOrigin || process.env.PUBLIC_ORIGIN;
  if (!configuredOrigin) throw new Error("PUBLIC_ORIGIN is required.");
  const publicOrigin = validatePublicOrigin(configuredOrigin);
  const dataDir = path.resolve(options.dataDir || process.env.DATA_DIR || defaultNotificationDataDir());
  const minDelay = options.minDelaySeconds ?? 5; const maxDelay = options.maxDelaySeconds ?? 120;
  const maxDevices = options.maxDevices ?? 5; const maxPending = options.maxPending ?? 20; const maxHistory = options.maxHistory ?? 100; const maxEventDedupe = options.maxEventDedupe ?? 2_000;
  const now = options.now || Date.now; const timerFactory = options.timerFactory || setTimeout; const timerClear = options.timerClear || clearTimeout;
  const server = http.createServer((request, response) => requestHandler(request, response));
  let requestHandler = (_request, response) => sendJSON(response, 503, { error: "Notification service is starting." });
  if (options.listen) await new Promise((resolve, reject) => {
    const onError = (error) => { server.off("listening", onListening); reject(error); };
    const onListening = () => { server.off("error", onError); resolve(); };
    server.once("error", onError); server.once("listening", onListening);
    server.listen(options.listen.port, "127.0.0.1");
  });
  let releaseOwner;
  try { releaseOwner = await acquireOwnerLock(dataDir); }
  catch (error) { if (server.listening) await new Promise((resolve) => server.close(resolve)); throw error; }

  try {
  const vapidFile = path.join(dataDir, "vapid.json");
  let vapid = await readJSON(vapidFile, null);
  if (!vapid) { vapid = webpush.generateVAPIDKeys(); await writePrivateJSON(vapidFile, vapid); }
  const bridgeTokenFile = path.join(dataDir, "bridge-token");
  let bridgeToken;
  try { bridgeToken = (await readFile(bridgeTokenFile, "utf8")).trim(); } catch (error) {
    if (error.code !== "ENOENT") throw error;
    bridgeToken = randomBytes(32).toString("base64url"); await writePrivate(bridgeTokenFile, bridgeToken);
  }
  const devicesFile = path.join(dataDir, "devices.json");
  let devices = (await readJSON(devicesFile, [])).map(cleanDevice);
  const eventsFile = path.join(dataDir, "events.json");
  const storedEvents = await readJSON(eventsFile, {});
  const knownDeviceIDs = new Set(devices.map((device) => device.id));
  const histories = new Map(Object.entries(storedEvents?.devices && typeof storedEvents.devices === "object" ? storedEvents.devices : {})
    .filter(([deviceID, records]) => knownDeviceIDs.has(deviceID) && Array.isArray(records))
    .map(([deviceID, records]) => [deviceID, records.slice(-200)]));
  let sourceHistory = storedEvents?.source && typeof storedEvents.source === "object" ? storedEvents.source : null;
  const jobs = new Map(); const rateBuckets = new Map(); const eventDedupe = new Map(); const inFlightSends = new Set(); const ownedMutations = new Set();
  let closed = false; let pairingInProgress = false; let persistence = Promise.resolve(); let eventPersistence = Promise.resolve(); let eventPersistenceRunning = false; let eventPersistenceDirty = false; let eventPersistenceState = "ok"; let lastBridgeEvent = null;
  let sourceEndpoint = sanitizeSourceEndpoint(options.openCodeServerURL ?? process.env.OPENCODE_SERVER_URL);
  if (sourceEndpoint) sourceEndpoint = { ...sourceEndpoint, provenance: "configuration" };
  const sender = options.pushSender || ((subscription, payload) => webpush.sendNotification(subscription, payload, {
    TTL: 300,
    timeout: options.pushTimeoutMS ?? 10_000,
    vapidDetails: { subject: `mailto:notification-pwa@${publicOrigin.hostname}`, publicKey: vapid.publicKey, privateKey: vapid.privateKey }
  }));
  const runOwnedMutation = (operation) => {
    if (closed) return Promise.resolve();
    const mutation = Promise.resolve().then(() => closed ? undefined : operation());
    ownedMutations.add(mutation);
    void mutation.then(() => ownedMutations.delete(mutation), () => ownedMutations.delete(mutation));
    return mutation;
  };
  const persistDevices = () => {
    if (closed) return Promise.resolve();
    const snapshot = structuredClone(devices);
    persistence = persistence.catch(() => {}).then(() => closed ? undefined : writePrivateJSON(devicesFile, snapshot));
    return persistence;
  };
  const eventsWriter = options.eventsWriter || writePrivateJSON;
  const persistEvents = () => {
    if (closed) return Promise.resolve();
    eventPersistenceDirty = true;
    if (eventPersistenceRunning) return eventPersistence;
    eventPersistenceRunning = true;
    eventPersistence = eventPersistence.catch(() => {}).then(async () => {
      while (eventPersistenceDirty && !closed) {
        eventPersistenceDirty = false;
        const snapshot = structuredClone({ version: 1, source: sourceHistory, devices: Object.fromEntries(histories) });
        try { await eventsWriter(eventsFile, snapshot); eventPersistenceState = "ok"; } catch { eventPersistenceState = "failed"; }
      }
    }).finally(() => {
      eventPersistenceRunning = false;
      if (eventPersistenceDirty && !closed) void persistEvents();
    });
    return eventPersistence;
  };
  const historyFor = (deviceID) => { if (!histories.has(deviceID)) histories.set(deviceID, []); return histories.get(deviceID); };
  const addRecord = (device, input) => {
    if (closed) return null;
    const record = { id: input.id || randomBytes(8).toString("hex"), ...input };
    const history = historyFor(device.id); history.push(record); if (history.length > 200) history.splice(0, history.length - 200);
    void persistEvents();
    return record;
  };
  const transitionRecord = (job, outcome, reason, pushStatus) => {
    if (closed) return;
    const record = historyFor(job.deviceID).find((item) => item.id === job.id);
    if (!record) return;
    record.outcome = outcome; record.finishedAt = new Date(now()).toISOString();
    if (reason) record.reason = reason; else delete record.reason;
    if (Number.isInteger(pushStatus) && pushStatus >= 400 && pushStatus <= 599) record.pushStatus = pushStatus; else delete record.pushStatus;
    void persistEvents();
  };
  const recordInput = (event, receivedAt) => ({
    kind: event.kind, ...(event.eventID ? { eventID: event.eventID } : {}), ...(event.requestID ? { requestID: event.requestID } : {}),
    ...(event.target?.sessionID ? { sessionID: event.target.sessionID } : {}), ...(event.target?.projectID ? { projectID: event.target.projectID } : {}),
    ...(event.context?.projectName ? { projectName: event.context.projectName } : {}), ...(event.context?.sessionTitle ? { sessionTitle: event.context.sessionTitle } : {}),
    ...(event.target?.directory && event.target.directory !== "/" && cleanDisplayText(path.posix.basename(event.target.directory), 80) ? { directoryName: cleanDisplayText(path.posix.basename(event.target.directory), 80) } : {}), receivedAt
  });
  const publicEvent = (record) => Object.fromEntries(["id", "kind", "eventID", "requestID", "sessionID", "projectID", "projectName", "sessionTitle", "directoryName", "receivedAt", "scheduledAt", "finishedAt", "outcome", "reason", "pushStatus"]
    .filter((key) => record?.[key] !== undefined).map((key) => [key, record[key]]));
  const publicSource = () => sourceHistory ? {
    name: BRIDGE_SOURCE,
    ...(typeof sourceHistory.lastSeenAt === "string" ? { lastSeenAt: sourceHistory.lastSeenAt } : {}),
    ...(typeof sourceHistory.lastReceivedAt === "string" ? { lastReceivedAt: sourceHistory.lastReceivedAt } : {}),
    ...(EVENT_KINDS.has(sourceHistory.lastKind) ? { lastKind: sourceHistory.lastKind } : {})
  } : null;
  const interruptedAt = new Date(now()).toISOString();
  let interrupted = false;
  for (const records of histories.values()) for (const record of records) if (record?.outcome === "scheduled" || record?.outcome === "sending") {
    record.outcome = "interrupted"; record.reason = "companion-restarted"; record.finishedAt = interruptedAt; interrupted = true;
  }
  if (interrupted) void persistEvents();
  const limited = (key, count, windowMs) => {
    const cutoff = now() - windowMs; const hits = (rateBuckets.get(key) || []).filter((time) => time > cutoff);
    if (hits.length >= count) return true; hits.push(now()); rateBuckets.set(key, hits); return false;
  };
  const pendingCount = () => [...jobs.values()].filter((job) => job.state === "scheduled").length;
  const pruneJobs = () => {
    const finished = [...jobs.values()].filter((job) => job.state !== "scheduled");
    for (const job of finished.slice(0, Math.max(0, finished.length - maxHistory))) jobs.delete(job.id);
  };
  const cancelWhere = (predicate, reason, message) => {
    for (const job of jobs.values()) if (job.state === "scheduled" && predicate(job)) {
      timerClear(job.timer); job.state = "cancelled"; job.message = message; job.finishedAt = new Date(now()).toISOString();
      transitionRecord(job, "cancelled", reason);
    }
    pruneJobs();
  };
  const finishJob = async (job) => {
    if (closed) return;
    const device = devices.find((item) => item.id === job.deviceID);
    if (job.state !== "scheduled") return;
    if (!device?.subscription) {
      job.state = "cancelled"; job.message = "The push subscription is unavailable."; job.finishedAt = new Date(now()).toISOString();
      transitionRecord(job, "cancelled", "subscription-missing");
      cancelWhere((candidate) => candidate.deviceID === job.deviceID && candidate.id !== job.id, "subscription-missing", "The push subscription is unavailable.");
      pruneJobs(); return;
    }
    job.state = "sending";
    transitionRecord(job, "sending");
    const subscriptionGeneration = device.subscriptionGeneration || 0;
    const send = Promise.resolve().then(() => sender(device.subscription, JSON.stringify(job.payload)));
    inFlightSends.add(send);
    try {
      await send;
      if (closed) return;
      job.state = "delivered"; job.message = "The push service accepted the notification.";
      transitionRecord(job, "accepted");
    } catch (error) {
      if (closed) return;
      if (error?.statusCode === 404 || error?.statusCode === 410) {
        const subscriptionIsCurrent = (device.subscriptionGeneration || 0) === subscriptionGeneration;
        if (subscriptionIsCurrent) device.subscription = null;
        job.state = "expired"; job.message = "The push subscription expired. Enable notifications again.";
        transitionRecord(job, "expired", "subscription-expired", error.statusCode);
        if (subscriptionIsCurrent) {
          cancelWhere((candidate) => candidate.deviceID === device.id && candidate.id !== job.id, "subscription-expired", "The push subscription expired.");
          await persistDevices().catch(() => {});
        }
      } else {
        const status = Number.isInteger(error?.statusCode) && error.statusCode >= 400 && error.statusCode <= 599 ? error.statusCode : undefined;
        job.state = "failed"; job.message = "The push service rejected the notification. Try again later.";
        transitionRecord(job, "failed", status ? "push-rejected" : "push-unavailable", status);
      }
    } finally { inFlightSends.delete(send); }
    job.finishedAt = new Date(now()).toISOString(); pruneJobs();
  };
  const schedule = (device, { delaySeconds, kind = "test", eventID, requestID, target, payload, receivedAt = new Date(now()).toISOString(), record = {} }) => {
    if (closed) throw Object.assign(new Error("Notification service is stopping."), { status: 503 });
    const scheduledAt = now() + delaySeconds * 1_000;
    const job = { id: randomBytes(8).toString("hex"), deviceID: device.id, kind, eventID, requestID, sessionID: target?.sessionID, state: "scheduled", message: "Waiting for the server-side timer.", scheduledAt: new Date(scheduledAt).toISOString(), payload };
    addRecord(device, { id: job.id, kind, ...(eventID ? { eventID } : {}), ...(requestID ? { requestID } : {}), ...record, receivedAt, scheduledAt: job.scheduledAt, outcome: "scheduled" });
    jobs.set(job.id, job); job.timer = timerFactory(() => finishJob(job).catch(() => {}), Math.max(0, scheduledAt - now())); return job;
  };
  const publicJob = ({ timer, deviceID, payload, eventID, requestID, sessionID, ...job }) => job;
  const authenticate = (request) => {
    const value = request.headers.authorization || ""; if (!value.startsWith("Bearer ")) return null;
    const hash = sha256(value.slice(7)); return devices.find((device) => constantEqual(device.tokenHash, hash)) || null;
  };
  const apiGuard = (request, response) => {
    const isRead = ["GET", "HEAD"].includes(request.method);
    const originIsValid = isRead ? !request.headers.origin || request.headers.origin === publicOrigin.origin : request.headers.origin === publicOrigin.origin;
    if (request.headers.host !== publicOrigin.host || !originIsValid) { sendJSON(response, 403, { error: "This request did not come from the configured PWA origin." }); return false; }
    if (!isRead && !/^application\/json(?:\s*;|$)/i.test(request.headers["content-type"] || "")) { sendJSON(response, 415, { error: "Requests must use application/json." }); return false; }
    return true;
  };

  const setupTickets = new Map();
  const pruneSetupTickets = () => { for (const [code, ticket] of setupTickets) if (ticket.expiresAt <= now()) setupTickets.delete(code); };
  const mintSetupTicket = (draft) => {
    if (closed) throw Object.assign(new Error("Notification service is stopping."), { status: 503 });
    const validated = validateDestination({ ...draft, optIn: false, delaySeconds: 15 }, { allowDisabled: false });
    const setupDraft = { baseURL: validated.baseURL, username: validated.username, profile: validated.profile };
    const expiresAt = now() + Math.min(options.setupTTLMS ?? 10 * 60_000, 10 * 60_000);
    pruneSetupTickets();
    if (setupTickets.size >= (options.maxSetupTickets ?? 64)) throw Object.assign(new Error("Too many pending setup codes."), { status: 429 });
    let code; do { code = randomBytes(5).toString("hex").toUpperCase(); } while (setupTickets.has(code));
    setupTickets.set(code, { draft: setupDraft, expiresAt });
    return { url: `${publicOrigin.origin}/#setup=${code}`, code, expiresAt: new Date(expiresAt).toISOString() };
  };
  const redeemSetupTicket = (code) => {
    if (closed) return null;
    pruneSetupTickets();
    const normalized = typeof code === "string" ? code.trim().toUpperCase() : "";
    const ticket = setupTickets.get(normalized);
    if (!ticket) return null;
    setupTickets.delete(normalized);
    return structuredClone(ticket.draft);
  };

  requestHandler = async (request, response) => {
    try {
      const url = new URL(request.url, publicOrigin);
      response.setHeader("X-Content-Type-Options", "nosniff"); response.setHeader("Referrer-Policy", "no-referrer");
      response.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
      response.setHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
      if (url.pathname === "/health") return sendJSON(response, 200, { ok: true });
      if (url.pathname.startsWith("/api/")) {
        if (!apiGuard(request, response)) return;
        const remote = request.socket.remoteAddress || "unknown";
        if (url.pathname === "/api/pair" && request.method === "POST") {
          if (limited(`pair:${remote}`, 10, 10 * 60_000)) return sendJSON(response, 429, { error: "Too many pairing attempts. Wait before trying again." });
          if (pairingInProgress) return sendJSON(response, 409, { error: "Another pairing attempt is in progress. Try again." });
          pairingInProgress = true;
          try {
            const body = await readBody(request); const pairingFile = path.join(dataDir, "pairing.json"); const pairing = await readJSON(pairingFile, null);
            if (!pairing || pairing.expiresAt < now() || typeof body.code !== "string" || !constantEqual(pairing.hash, sha256(body.code.trim().toUpperCase()))) return sendJSON(response, 401, { error: "The pairing code is invalid or expired. Generate a fresh code locally." });
            if (devices.length >= maxDevices) return sendJSON(response, 409, { error: "The paired-device limit has been reached. Reset an existing device first." });
            if (closed) return sendJSON(response, 503, { error: "Notification service is stopping." });
            await runOwnedMutation(() => unlink(pairingFile).catch(() => {}));
            if (closed) return sendJSON(response, 503, { error: "Notification service is stopping." });
            const token = randomBytes(32).toString("base64url");
            devices.push({ id: randomBytes(8).toString("hex"), tokenHash: sha256(token), subscription: null, destination: defaultDestination(), createdAt: new Date(now()).toISOString() });
            await persistDevices(); return sendJSON(response, 201, { token });
          } finally { pairingInProgress = false; }
        }
        const device = authenticate(request);
        if (!device) return sendJSON(response, 401, { error: "Pair this installed PWA before using notifications." });
        if (url.pathname === "/api/setup/redeem" && request.method === "POST") {
          if (limited(`setup-redeem:${device.id}`, 10, 10 * 60_000)) return sendJSON(response, 429, { error: "Too many setup-code attempts. Wait before trying again." });
          const body = await readBody(request);
          if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).some((key) => key !== "code")) return sendJSON(response, 400, { error: "Only a setup code may be redeemed." });
          const draft = redeemSetupTicket(body.code);
          if (!draft) return sendJSON(response, 401, { error: "The connection setup code is invalid or expired." });
          return sendJSON(response, 200, draft);
        }
        if (url.pathname === "/api/config" && request.method === "GET") return sendJSON(response, 200, { vapidPublicKey: vapid.publicKey });
        if (url.pathname === "/api/destination" && request.method === "GET") return sendJSON(response, 200, { destination: device.destination });
        if (url.pathname === "/api/destination" && request.method === "PUT") {
          const body = await readBody(request); const destination = validateDestination(body);
          if (device.destination.optIn && !destination.optIn) cancelWhere((job) => job.deviceID === device.id && job.kind !== "test", "opt-out", "Real-event notifications were disabled.");
          device.destination = destination; await persistDevices();
          return sendJSON(response, 200, { destination: device.destination });
        }
        if (url.pathname === "/api/subscription" && request.method === "POST") {
          const { subscription } = await readBody(request);
          if (!subscription || !allowedPushEndpoint(subscription.endpoint) || typeof subscription.keys?.p256dh !== "string" || typeof subscription.keys?.auth !== "string" || subscription.keys.p256dh.length > 512 || subscription.keys.auth.length > 256) return sendJSON(response, 400, { error: "The browser returned an unsupported push subscription." });
          device.subscriptionGeneration = (device.subscriptionGeneration || 0) + 1;
          device.subscription = { endpoint: subscription.endpoint, expirationTime: subscription.expirationTime ?? null, keys: { p256dh: subscription.keys.p256dh, auth: subscription.keys.auth } };
          await persistDevices(); return sendJSON(response, 200, { subscribed: true });
        }
        if (url.pathname === "/api/test" && request.method === "POST") {
          if (limited(`send:${device.id}`, 5, 60_000)) return sendJSON(response, 429, { error: "Too many tests were scheduled. Wait one minute." });
          const receivedAt = new Date(now()).toISOString();
          if (!device.subscription) { addRecord(device, { kind: "test", receivedAt, finishedAt: receivedAt, outcome: "skipped", reason: "subscription-missing" }); return sendJSON(response, 409, { error: "Enable notifications on this device before scheduling a test." }); }
          if (pendingCount() >= maxPending) { addRecord(device, { kind: "test", receivedAt, finishedAt: receivedAt, outcome: "skipped", reason: "queue-full" }); return sendJSON(response, 503, { error: "The pending notification limit has been reached." }); }
          const body = await readBody(request);
          if (Object.keys(body).some((key) => key !== "delaySeconds")) return sendJSON(response, 400, { error: "Only a notification delay can be configured." });
          if (typeof body.delaySeconds !== "number" || !Number.isFinite(body.delaySeconds) || body.delaySeconds < minDelay || body.delaySeconds > maxDelay) return sendJSON(response, 400, { error: `Delay must be between ${minDelay} and ${maxDelay} seconds.` });
          const job = schedule(device, { delaySeconds: body.delaySeconds, receivedAt, payload: { jobID: randomBytes(8).toString("hex") } });
          job.payload.jobID = job.id; return sendJSON(response, 202, { job: publicJob(job) });
        }
        if (url.pathname === "/api/status" && request.method === "GET") {
          const ownJobs = [...jobs.values()].filter((job) => job.deviceID === device.id).slice(-20).reverse().map(publicJob);
          return sendJSON(response, 200, { subscribed: Boolean(device.subscription), destination: device.destination, jobs: ownJobs, bridge: lastBridgeEvent, ...(sourceEndpoint ? { sourceEndpoint } : {}) });
        }
        if (url.pathname === "/api/events" && request.method === "GET") {
          return sendJSON(response, 200, { events: historyFor(device.id).map(publicEvent).reverse(), source: publicSource(), persistence: eventPersistenceState });
        }
        if (url.pathname === "/api/device" && request.method === "DELETE") {
          await readBody(request); cancelWhere((job) => job.deviceID === device.id, "device-reset", "The device was reset.");
          devices = devices.filter((candidate) => candidate.id !== device.id); histories.delete(device.id); void persistEvents(); await persistDevices(); return sendJSON(response, 200, { reset: true });
        }
        return sendJSON(response, 404, { error: "API endpoint not found." });
      }
      const staticEntry = staticFiles.get(url.pathname);
      if (!staticEntry || !["GET", "HEAD"].includes(request.method)) { response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" }); return response.end("Not found"); }
      const [file, contentType] = staticEntry; const data = await readFile(path.join(publicDir, file)); response.setHeader("Content-Type", contentType);
      response.setHeader("Cache-Control", ["sw.js", "app.js", "events.js", "handoff.js", "handoff-core.js", "index.html", "events.html", "handoff.html"].includes(file) ? "no-cache" : "public, max-age=300");
      response.writeHead(200, { "Content-Length": data.length }); response.end(request.method === "HEAD" ? undefined : data);
    } catch (error) { if (!response.headersSent) sendJSON(response, error.status || (error instanceof TypeError ? 400 : 500), { error: error.status || error instanceof TypeError ? error.message : "The server could not complete this request." }); else response.end(); }
  };

  const processBridgeBody = async (body, isMetadata = false) => {
    if (closed) throw Object.assign(new Error("Notification service is stopping."), { status: 503 });
    if (isMetadata) {
      if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).some((key) => !["source", "sourceEndpoint"].includes(key)) || body.source !== BRIDGE_SOURCE) throw new TypeError("Unsupported bridge metadata.");
      const endpoint = validateSourceEndpoint(body.sourceEndpoint);
      if (!endpoint) throw new TypeError("Invalid source endpoint.");
      sourceEndpoint = { ...endpoint, provenance: "plugin" };
      sourceHistory = { ...(sourceHistory || { name: BRIDGE_SOURCE }), lastSeenAt: new Date(now()).toISOString() }; void persistEvents();
      return { accepted: true };
    }
    if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).some((key) => !["source", "event"].includes(key)) || body.source !== BRIDGE_SOURCE) throw new TypeError("Unsupported bridge event.");
    const event = validateBridgeEvent(body.event);
    const receivedAt = new Date(now()).toISOString();
    lastBridgeEvent = { at: receivedAt, kind: event.kind, status: "accepted" };
    sourceHistory = { name: BRIDGE_SOURCE, lastSeenAt: receivedAt, lastReceivedAt: receivedAt, lastKind: event.kind }; void persistEvents();
    if (event.kind === "activity") cancelWhere((job) => job.kind === "idle" && job.sessionID === event.sessionID, "newer-activity", "A newer activity cycle started.");
    else if (event.kind === "error") cancelWhere((job) => job.sessionID === event.sessionID, "session-error", "The session ended with an error.");
    else if (event.kind === "permission-resolved" || event.kind === "question-resolved") cancelWhere((job) => job.requestID === event.requestID, "request-resolved", "The request was already resolved.");
    else if (event.kind === "session-deleted") cancelWhere((job) => job.sessionID === event.sessionID, "session-deleted", "The session was deleted.");
    else {
      const canonical = canonicalSessionTarget({ id: event.target?.sessionID, projectID: event.target?.projectID, directory: event.target?.directory, workspaceID: event.target?.workspaceID });
      const dedupeKey = `${body.source}:${event.eventID}`;
      if (eventDedupe.has(dedupeKey)) {
        lastBridgeEvent = { ...lastBridgeEvent, status: "duplicate", scheduled: 0 };
        return { accepted: true, duplicate: true };
      }
      const baseRecord = recordInput(event, receivedAt); const eligibleDevices = [];
      for (const device of devices) {
        if (!device.subscription) addRecord(device, { ...baseRecord, finishedAt: receivedAt, outcome: "skipped", reason: "subscription-missing" });
        else if (!device.destination.optIn) addRecord(device, { ...baseRecord, finishedAt: receivedAt, outcome: "skipped", reason: "opt-out" });
        else eligibleDevices.push(device);
      }
      if (pendingCount() + eligibleDevices.length > maxPending) {
        for (const device of eligibleDevices) addRecord(device, { ...baseRecord, finishedAt: receivedAt, outcome: "skipped", reason: "queue-full" });
        throw Object.assign(new Error("The pending notification limit has been reached."), { status: 503 });
      }
      let prepared;
      try { prepared = eligibleDevices.map((device) => {
        const destination = structuredClone(device.destination); const target = buildHandoffTarget(destination, canonical);
        return { device, payload: pushPayload(event.kind, target, event.context) };
      }); } catch (error) {
        for (const device of eligibleDevices) addRecord(device, { ...baseRecord, finishedAt: receivedAt, outcome: "failed", reason: "payload-too-large" });
        throw error;
      }
      eventDedupe.set(dedupeKey, now());
      while (eventDedupe.size > maxEventDedupe) eventDedupe.delete(eventDedupe.keys().next().value);
      for (const { device, payload } of prepared) schedule(device, { delaySeconds: device.destination.delaySeconds, kind: event.kind, eventID: event.eventID, requestID: event.requestID, target: canonical, payload, receivedAt, record: baseRecord });
      lastBridgeEvent = { ...lastBridgeEvent, status: prepared.length ? "scheduled" : "no-opted-in-device", scheduled: prepared.length };
    }
    return { accepted: true };
  };

  const ingestionServer = http.createServer(async (request, response) => {
    try {
      if (request.method !== "POST" || !["/ingest", "/metadata"].includes(request.url)) return sendJSON(response, 404, { error: "Not found." });
      const remote = request.socket.remoteAddress;
      if (remote !== "127.0.0.1" && remote !== "::1" && remote !== "::ffff:127.0.0.1") return sendJSON(response, 403, { error: "Loopback access only." });
      const authorization = request.headers.authorization || "";
      if (!authorization.startsWith("Bearer ") || !constantEqual(authorization.slice(7), bridgeToken)) return sendJSON(response, 401, { error: "Unauthorized." });
      if (!/^application\/json(?:\s*;|$)/i.test(request.headers["content-type"] || "")) return sendJSON(response, 415, { error: "Requests must use application/json." });
      const isMetadata = request.url === "/metadata";
      if (limited(isMetadata ? "bridge-metadata" : "bridge", isMetadata ? 10 : 240, 60_000)) return sendJSON(response, 429, { error: "Bridge rate limit reached." });
      const body = await readBody(request);
      return sendJSON(response, 202, await processBridgeBody(body, isMetadata));
    } catch (error) { return sendJSON(response, error.status || (error instanceof TypeError ? 400 : 500), { error: error instanceof TypeError || error.status ? error.message : "Bridge event failed." }); }
  });
  const closeTimers = () => { for (const job of jobs.values()) if (job.timer) timerClear(job.timer); };
  server.addListener("close", closeTimers);
  let stopped = false;
  return {
    server, ingestionServer, publicOrigin, dataDir, bridgeTokenFile,
    mintSetupTicket,
    ingest: (event) => processBridgeBody({ source: BRIDGE_SOURCE, event }),
    updateSource: (sourceEndpoint) => processBridgeBody({ source: BRIDGE_SOURCE, sourceEndpoint }, true),
    flushEvents: () => Promise.all([persistence.catch(() => {}), eventPersistence.catch(() => {})]),
    async stop() {
      if (stopped) return; stopped = true; closed = true;
      eventPersistenceDirty = false;
      closeTimers();
      await Promise.all([closeHTTPServer(server), closeHTTPServer(ingestionServer)]);
      await settleWithin(Promise.all([...inFlightSends].map((send) => send.catch(() => {}))), options.shutdownTimeoutMS ?? 5_000);
      await Promise.all([persistence.catch(() => {}), eventPersistence.catch(() => {}), ...ownedMutations].map((operation) => operation.catch(() => {})));
      await releaseOwner();
    }
  };
  } catch (error) {
    if (server.listening) await new Promise((resolve) => server.close(resolve));
    await releaseOwner();
    throw error;
  }
}

async function closeHTTPServer(server) {
  if (!server.listening) return;
  const closed = new Promise((resolve) => server.close(resolve));
  const completed = await settleWithin(closed, 2_000);
  if (!completed) server.closeAllConnections?.();
}

async function settleWithin(promise, timeoutMS) {
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMS);
    timer.unref?.();
  });
  try { return await Promise.race([promise.then(() => true), timeout]); }
  finally { clearTimeout(timer); }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { server, ingestionServer, publicOrigin } = await createNotificationServer();
  server.listen(4319, "127.0.0.1", () => console.log(`Notification PWA listening on 127.0.0.1:4319 for ${publicOrigin.origin}`));
  ingestionServer.listen(4320, "127.0.0.1", () => console.log("OpenCode notification bridge listening on 127.0.0.1:4320"));
}
