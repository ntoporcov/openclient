import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, stat, unlink, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createNotificationServer } from "../src/server.mjs";

const origin = "https://openclient.example:8443";
const endpoint = "https://web.push.apple.com/QM-safe-test-endpoint";
const subscription = { endpoint, keys: { p256dh: "test-public-key", auth: "test-auth-key" } };
const hash = (value) => createHash("sha256").update(value).digest("hex");

async function fixture(pushSender = async () => {}, options = {}) {
  const dataDir = await mkdtemp(path.join(tmpdir(), "notification-pwa-"));
  await options.setup?.(dataDir);
  const app = await createNotificationServer({ dataDir, publicOrigin: origin, minDelaySeconds: 0.03, maxDelaySeconds: 1, pushSender, ...options.server });
  await new Promise((resolve) => app.server.listen(0, "127.0.0.1", resolve));
  await new Promise((resolve) => app.ingestionServer.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${app.server.address().port}`;
  const bridgeBase = `http://127.0.0.1:${app.ingestionServer.address().port}`;
  const request = (pathname, options = {}) => new Promise((resolve, reject) => {
    const body = options.body || "";
    const headers = { Host: new URL(origin).host, Origin: origin, ...(body ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } : {}), ...options.headers };
    if (options.omitOrigin) delete headers.Origin;
    const request = http.request(`${base}${pathname}`, {
      method: options.method || "GET",
      headers
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        const data = Buffer.concat(chunks).toString("utf8");
        resolve({ status: response.statusCode, json: async () => JSON.parse(data) });
      });
    });
    request.on("error", reject);
    request.end(body);
  });
  const bridge = async (event, suppliedToken) => {
    const token = suppliedToken ?? (await readFile(app.bridgeTokenFile, "utf8")).trim();
    const response = await fetch(`${bridgeBase}/ingest`, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ source: "openclient-ios-local", event }) });
    return { status: response.status, json: () => response.json() };
  };
  const metadata = async (sourceEndpoint, suppliedToken) => {
    const token = suppliedToken ?? (await readFile(app.bridgeTokenFile, "utf8")).trim();
    const response = await fetch(`${bridgeBase}/metadata`, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ source: "openclient-ios-local", sourceEndpoint }) });
    return { status: response.status, json: () => response.json() };
  };
  return { ...app, base, bridgeBase, bridge, metadata, dataDir, request, close: async () => {
    await Promise.all([new Promise((resolve) => app.server.close(resolve)), new Promise((resolve) => app.ingestionServer.close(resolve))]);
    await app.flushEvents();
    await rm(dataDir, { recursive: true, force: true });
  } };
}

async function pair(app, code = "ABC123") {
  await writeFile(path.join(app.dataDir, "pairing.json"), JSON.stringify({ hash: hash(code), expiresAt: Date.now() + 60_000 }), { mode: 0o600 });
  const response = await app.request("/api/pair", { method: "POST", body: JSON.stringify({ code }) });
  assert.equal(response.status, 201);
  return (await response.json()).token;
}

async function subscribe(app, token, value = subscription) {
  return app.request("/api/subscription", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ subscription: value }) });
}

test("health exposes no secrets and APIs enforce exact origin and auth", async (t) => {
  const app = await fixture(); t.after(app.close);
  const health = await fetch(`${app.base}/health`);
  assert.deepEqual(await health.json(), { ok: true });
  const wrongOrigin = await app.request("/api/status", { headers: { Origin: "https://example.com" } });
  assert.equal(wrongOrigin.status, 403);
  const unauthenticated = await app.request("/api/status");
  assert.equal(unauthenticated.status, 401);
  assert.equal((await fetch(`${app.base}/ingest`, { method: "POST" })).status, 404);
  assert.equal((await fetch(`${app.base}/metadata`, { method: "POST" })).status, 404);
  assert.equal((await fetch(`${app.bridgeBase}/ingest`, { method: "POST" })).status, 401);
  assert.equal((await fetch(`${app.bridgeBase}/metadata`, { method: "POST" })).status, 401);
  assert.equal((await app.request("/events.html")).status, 200);
  assert.equal((await app.request("/events.js")).status, 200);
  assert.equal((await app.bridge({ kind: "idle", eventID: "idle:ses_1:1", target: { sessionID: "ses_1", projectID: "project_1" }, deepLink: "openclient://action" })).status, 400);
});

test("configured source hint is sanitized for paired status without changing destination", async (t) => {
  const app = await fixture(async () => {}, { server: { openCodeServerURL: "http://0.0.0.0:4096" } }); t.after(app.close);
  const token = await pair(app);
  const body = await (await app.request("/api/status", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.deepEqual(body.sourceEndpoint, { protocol: "http", port: 4096, provenance: "configuration" });
  assert.deepEqual(body.destination, { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 });
  assert.deepEqual(await (await fetch(`${app.base}/health`)).json(), { ok: true });
});

test("authenticated private metadata replaces a configured hint and rejects invalid fields", async (t) => {
  const app = await fixture(async () => {}, { server: { openCodeServerURL: "not a URL" } }); t.after(app.close);
  const token = await pair(app);
  assert.equal((await app.metadata({ protocol: "http", port: 4096 }, "wrong-token")).status, 401);
  assert.equal((await app.metadata({ protocol: "ftp", port: 21 })).status, 400);
  assert.equal((await app.metadata({ protocol: "https", port: 443, hostname: "secret" })).status, 400);
  assert.equal((await app.metadata({ protocol: "https", port: 443 })).status, 202);
  const status = await (await app.request("/api/status", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.deepEqual(status.sourceEndpoint, { protocol: "https", port: 443, provenance: "plugin" });
  const events = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.deepEqual(events.events, []);
  assert.equal(events.source.name, "openclient-ios-local");
  assert.ok(events.source.lastSeenAt);
  assert.equal(events.source.lastReceivedAt, undefined);
});

test("old persisted devices default to real-event opt-out", async (t) => {
  let sends = 0;
  const oldToken = "old-device-token";
  const app = await fixture(async () => { sends += 1; }, {
    setup: (dataDir) => writeFile(path.join(dataDir, "devices.json"), JSON.stringify([{ id: "old", tokenHash: hash(oldToken), subscription, createdAt: new Date().toISOString() }]), { mode: 0o600 })
  }); t.after(app.close);
  const status = await app.request("/api/status", { headers: { Authorization: `Bearer ${oldToken}` } });
  assert.deepEqual((await status.json()).destination, { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 });
  assert.equal((await app.bridge({ kind: "idle", eventID: "idle:ses_old:1", target: { sessionID: "ses_old", projectID: "project" } })).status, 202);
  assert.equal(sends, 0);
});

test("real events snapshot opted-in destinations and cancellation prevents delivery", async (t) => {
  const timers = [];
  const payloads = [];
  const app = await fixture(async (_subscription, payload) => payloads.push(JSON.parse(payload)), {
    server: { timerFactory: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; }, timerClear: (timer) => { timer.cancelled = true; } }
  }); t.after(app.close);
  const token = await pair(app);
  await subscribe(app, token);
  const auth = { Authorization: `Bearer ${token}` };
  const destination = { optIn: true, baseURL: "http://Mac.local:4096/", username: "OpenCode", profile: "legacy", delaySeconds: 15 };
  assert.equal((await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify(destination) })).status, 200);
  const target = { sessionID: "ses_123", projectID: "project_1", directory: "/tmp/repo", workspaceID: "workspace_1" };
  await app.bridge({ kind: "permission", eventID: "permission:perm_1", requestID: "perm_1", target, context: { projectName: " openclient ", sessionTitle: "Improve\nnotification captions" } });
  await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify({ ...destination, baseURL: "https://changed.example" }) });
  await timers[0].callback();
  assert.equal(payloads[0].data.serverID, "http://mac.local:4096/|opencode");
  assert.equal(payloads[0].data.directory, "/tmp/repo");
  assert.deepEqual(payloads[0].context, { projectName: "openclient", sessionTitle: "Improve notification captions" });
  await app.bridge({ kind: "question", eventID: "question:q_1", requestID: "q_1", target });
  await app.bridge({ kind: "question-resolved", requestID: "q_1", sessionID: "ses_123" });
  assert.equal(timers[1].cancelled, true);
  await timers[1].callback();
  assert.equal(payloads.length, 1);
});

test("event ledger is authenticated, redacted, per-device, and tracks push acceptance", async (t) => {
  const timers = [];
  const app = await fixture(async () => {}, { server: { timerFactory: (callback) => { const timer = { callback }; timers.push(timer); return timer; } } }); t.after(app.close);
  const first = await pair(app, "FIRST1"); await subscribe(app, first);
  await app.request("/api/destination", { method: "PUT", headers: { Authorization: `Bearer ${first}` }, body: JSON.stringify({ optIn: true, baseURL: "http://secret-host.local:4096", username: "private-user", profile: "legacy", delaySeconds: 15 }) });
  const second = await pair(app, "SECOND2");
  await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${first}` }, body: JSON.stringify({ delaySeconds: 0.5 }) });
  let firstEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${first}` } })).json();
  let secondEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${second}` } })).json();
  assert.equal(firstEvents.events[0].outcome, "scheduled");
  assert.deepEqual(secondEvents.events, []);

  const target = { sessionID: "ses_private", projectID: "project_private", directory: "/Users/private/work/openclient" };
  await app.bridge({ kind: "idle", eventID: "idle:private:1", target, context: { projectName: "OpenClient", sessionTitle: "Private title" } });
  firstEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${first}` } })).json();
  secondEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${second}` } })).json();
  assert.deepEqual({ outcome: firstEvents.events[0].outcome, projectName: firstEvents.events[0].projectName, sessionTitle: firstEvents.events[0].sessionTitle, directoryName: firstEvents.events[0].directoryName }, { outcome: "scheduled", projectName: "OpenClient", sessionTitle: "Private title", directoryName: "openclient" });
  assert.deepEqual({ outcome: secondEvents.events[0].outcome, reason: secondEvents.events[0].reason }, { outcome: "skipped", reason: "subscription-missing" });
  assert.equal(JSON.stringify(firstEvents).includes("secret-host"), false);
  assert.equal(JSON.stringify(firstEvents).includes("private-user"), false);
  assert.equal(JSON.stringify(firstEvents).includes("/Users/private"), false);
  assert.equal(firstEvents.source.name, "openclient-ios-local");
  assert.equal(firstEvents.source.lastKind, "idle");
  await timers[1].callback();
  firstEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${first}` } })).json();
  assert.equal(firstEvents.events[0].outcome, "accepted");
  assert.ok(firstEvents.events[0].finishedAt);
  assert.equal((await app.request("/api/events")).status, 401);
});

test("event ledger records opt-out, queue capacity, and safe push failure reasons", async (t) => {
  const timers = [];
  let sendError = Object.assign(new Error("raw push body must not escape"), { statusCode: 503 });
  const app = await fixture(async () => { throw sendError; }, { server: { maxPending: 1, timerFactory: (callback) => { const timer = { callback }; timers.push(timer); return timer; } } }); t.after(app.close);
  const optedOut = await pair(app, "OUT111"); await subscribe(app, optedOut);
  const active = await pair(app, "ACTIVE2"); await subscribe(app, active);
  await app.request("/api/destination", { method: "PUT", headers: { Authorization: `Bearer ${active}` }, body: JSON.stringify({ optIn: true, baseURL: "http://localhost:4096", username: "opencode", profile: "legacy", delaySeconds: 15 }) });
  await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${active}` }, body: JSON.stringify({ delaySeconds: 0.5 }) });
  const target = { sessionID: "ses_capacity", projectID: "project_1" };
  assert.equal((await app.bridge({ kind: "idle", eventID: "idle:capacity:1", target })).status, 503);
  let activeEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${active}` } })).json();
  let optedOutEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${optedOut}` } })).json();
  assert.deepEqual({ outcome: activeEvents.events[0].outcome, reason: activeEvents.events[0].reason }, { outcome: "skipped", reason: "queue-full" });
  assert.deepEqual({ outcome: optedOutEvents.events[0].outcome, reason: optedOutEvents.events[0].reason }, { outcome: "skipped", reason: "opt-out" });
  await timers[0].callback();
  activeEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${active}` } })).json();
  assert.deepEqual({ outcome: activeEvents.events[1].outcome, reason: activeEvents.events[1].reason, pushStatus: activeEvents.events[1].pushStatus }, { outcome: "failed", reason: "push-rejected", pushStatus: 503 });
  assert.equal(JSON.stringify(activeEvents).includes("raw push body"), false);

  sendError = Object.assign(new Error("gone"), { statusCode: 410 });
  await subscribe(app, active);
  await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${active}` }, body: JSON.stringify({ delaySeconds: 0.5 }) });
  await timers[1].callback();
  activeEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${active}` } })).json();
  assert.deepEqual({ outcome: activeEvents.events[0].outcome, reason: activeEvents.events[0].reason, pushStatus: activeEvents.events[0].pushStatus }, { outcome: "expired", reason: "subscription-expired", pushStatus: 410 });

  sendError = new Error("private network details");
  await subscribe(app, active);
  await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${active}` }, body: JSON.stringify({ delaySeconds: 0.5 }) });
  await timers[2].callback();
  activeEvents = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${active}` } })).json();
  assert.deepEqual({ outcome: activeEvents.events[0].outcome, reason: activeEvents.events[0].reason, pushStatus: activeEvents.events[0].pushStatus }, { outcome: "failed", reason: "push-unavailable", pushStatus: undefined });
  assert.equal(JSON.stringify(activeEvents).includes("private network details"), false);
});

test("event history is bounded, private, and marks pending timers interrupted on startup", async (t) => {
  const token = "restart-device-token";
  const records = Array.from({ length: 205 }, (_, index) => ({ id: `record-${index}`, kind: "idle", sessionID: `ses_${index}`, receivedAt: new Date(index + 1).toISOString(), scheduledAt: new Date(index + 2).toISOString(), outcome: "scheduled", rawSecret: "must-not-escape" }));
  const app = await fixture(async () => {}, { setup: async (dataDir) => {
    await writeFile(path.join(dataDir, "devices.json"), JSON.stringify([{ id: "restart-device", tokenHash: hash(token), subscription, destination: { optIn: true, baseURL: "http://localhost:4096", username: "opencode", profile: "legacy", delaySeconds: 15 }, createdAt: new Date().toISOString() }]), { mode: 0o600 });
    await writeFile(path.join(dataDir, "events.json"), JSON.stringify({ version: 1, source: null, devices: { "restart-device": records, deletedDevice: [{ id: "leak", outcome: "accepted" }] } }), { mode: 0o600 });
  } }); t.after(app.close);
  await app.flushEvents();
  const result = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.equal(result.events.length, 200);
  assert.equal(result.events.every((event) => event.outcome === "interrupted" && event.reason === "companion-restarted" && event.finishedAt), true);
  assert.equal(JSON.stringify(result).includes("leak"), false);
  assert.equal(JSON.stringify(result).includes("must-not-escape"), false);
  assert.equal((await stat(path.join(app.dataDir, "events.json"))).mode & 0o777, 0o600);
});

test("event API reports isolated persistence failures without failing ingestion", async (t) => {
  const app = await fixture(async () => {}, { server: { eventsWriter: async () => { throw new Error("disk details"); } } }); t.after(app.close);
  const token = await pair(app); await subscribe(app, token);
  await app.bridge({ kind: "idle", eventID: "idle:persistence:1", target: { sessionID: "ses_1", projectID: "project_1" } });
  await app.flushEvents();
  const result = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.equal(result.persistence, "failed");
  assert.equal(result.events[0].outcome, "skipped");
  assert.equal(JSON.stringify(result).includes("disk details"), false);
});

test("private ingestion strictly validates optional display context", async (t) => {
  const app = await fixture(); t.after(app.close);
  const base = { kind: "idle", eventID: "idle:context:1", target: { sessionID: "ses_1", projectID: "project_1" } };
  assert.equal((await app.bridge({ ...base, context: null })).status, 202);
  assert.equal((await app.bridge({ ...base, eventID: "idle:context:2", context: { projectName: "   ", sessionTitle: null } })).status, 202);
  assert.equal((await app.bridge({ ...base, eventID: "idle:context:3", context: { projectName: { text: "evil" } } })).status, 400);
  assert.equal((await app.bridge({ ...base, eventID: "idle:context:4", context: { projectName: "safe", href: "openclient://evil" } })).status, 400);
});

test("push budget shrinks context without changing routing and rejects an oversized target", async (t) => {
  const timers = []; const payloads = [];
  const app = await fixture(async (_subscription, payload) => payloads.push(payload), {
    server: { timerFactory: (callback) => { const timer = { callback }; timers.push(timer); return timer; } }
  }); t.after(app.close);
  const token = await pair(app); await subscribe(app, token); const auth = { Authorization: `Bearer ${token}` };
  const destination = { optIn: true, baseURL: `https://example.com/${"a".repeat(1_300)}`, username: "opencode", profile: "v2", delaySeconds: 15 };
  await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify(destination) });
  const target = { sessionID: "ses_budget", projectID: "project_budget", directory: `/tmp/${"b".repeat(1_300)}` };
  const response = await app.bridge({ kind: "idle", eventID: "idle:budget:1", target, context: { projectName: "😀".repeat(80), sessionTitle: "😀".repeat(120) } });
  assert.equal(response.status, 202);
  await timers[0].callback();
  assert.ok(Buffer.byteLength(payloads[0]) <= 3_500);
  const payload = JSON.parse(payloads[0]);
  assert.equal(payload.data.directory, target.directory);
  assert.equal(payload.data.sessionID, target.sessionID);

  await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify({ ...destination, baseURL: `https://example.com/${"a".repeat(1_950)}` }) });
  const oversized = await app.bridge({ kind: "idle", eventID: "idle:budget:2", target: { ...target, directory: `/tmp/${"b".repeat(1_950)}` } });
  assert.equal(oversized.status, 400);
  assert.match((await oversized.json()).error, /safe Web Push payload size/);
  const retry = await app.bridge({ kind: "idle", eventID: "idle:budget:2", target });
  assert.equal(retry.status, 202);
  assert.equal((await retry.json()).duplicate, undefined);
});

test("new activity and deletion cancel stale session notifications", async (t) => {
  const timers = [];
  const app = await fixture(async () => assert.fail("cancelled push must not send"), {
    server: { timerFactory: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; }, timerClear: (timer) => { timer.cancelled = true; } }
  }); t.after(app.close);
  const token = await pair(app); await subscribe(app, token);
  await app.request("/api/destination", { method: "PUT", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ optIn: true, baseURL: "http://localhost:4096", username: "opencode", profile: "v2", delaySeconds: 15 }) });
  const target = { sessionID: "ses_1", projectID: "project_1", directory: "/" };
  await app.bridge({ kind: "idle", eventID: "idle:ses_1:1", target });
  await app.bridge({ kind: "activity", sessionID: "ses_1" });
  assert.equal(timers[0].cancelled, true);
  let events = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.deepEqual({ outcome: events.events[0].outcome, reason: events.events[0].reason }, { outcome: "cancelled", reason: "newer-activity" });
  await app.bridge({ kind: "permission", eventID: "permission:p_1", requestID: "p_1", target });
  await app.bridge({ kind: "session-deleted", sessionID: "ses_1" });
  assert.equal(timers[1].cancelled, true);
  events = await (await app.request("/api/events", { headers: { Authorization: `Bearer ${token}` } })).json();
  assert.deepEqual({ outcome: events.events[0].outcome, reason: events.events[0].reason }, { outcome: "cancelled", reason: "session-deleted" });
});

test("bridge event IDs are idempotent across duplicate ingestion", async (t) => {
  const timers = [];
  const app = await fixture(async () => {}, {
    server: { timerFactory: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; }, timerClear: (timer) => { timer.cancelled = true; } }
  }); t.after(app.close);
  const token = await pair(app); await subscribe(app, token);
  await app.request("/api/destination", { method: "PUT", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ optIn: true, baseURL: "http://localhost:4096", username: "", profile: "legacy", delaySeconds: 15 }) });
  const event = { kind: "permission", eventID: "permission:p_once", requestID: "p_once", target: { sessionID: "ses_1", projectID: "project_1" } };
  assert.equal((await app.bridge(event)).status, 202);
  const duplicate = await app.bridge(event);
  assert.equal(duplicate.status, 202);
  assert.equal((await duplicate.json()).duplicate, true);
  assert.equal(timers.length, 1);
});

test("opting out cancels real-event jobs but preserves manual tests", async (t) => {
  const timers = [];
  const app = await fixture(async () => {}, {
    server: { timerFactory: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; }, timerClear: (timer) => { timer.cancelled = true; } }
  }); t.after(app.close);
  const token = await pair(app); await subscribe(app, token); const auth = { Authorization: `Bearer ${token}` };
  const destination = { optIn: true, baseURL: "http://localhost:4096", username: "opencode", profile: "legacy", delaySeconds: 15 };
  await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify(destination) });
  await app.request("/api/test", { method: "POST", headers: auth, body: JSON.stringify({ delaySeconds: 0.5 }) });
  await app.bridge({ kind: "question", eventID: "question:q_optout", requestID: "q_optout", target: { sessionID: "ses_1", projectID: "project_1" } });
  await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify({ ...destination, optIn: false }) });
  assert.equal(timers[0].cancelled, false);
  assert.equal(timers[1].cancelled, true);
  const jobs = (await (await app.request("/api/status", { headers: auth })).json()).jobs;
  assert.equal(jobs.find((job) => job.kind === "test").state, "scheduled");
  assert.equal(jobs.find((job) => job.kind === "question").state, "cancelled");
});

test("one-time pairing authenticates only the current device", async (t) => {
  const app = await fixture(); t.after(app.close);
  const token = await pair(app);
  const reused = await app.request("/api/pair", { method: "POST", body: JSON.stringify({ code: "ABC123" }) });
  assert.equal(reused.status, 401);
  const status = await app.request("/api/status", { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(status.status, 200);
  assert.deepEqual((await status.json()).jobs, []);
  const statusWithoutOrigin = await app.request("/api/status", { omitOrigin: true, headers: { Authorization: `Bearer ${token}` } });
  assert.equal(statusWithoutOrigin.status, 200);
  const postWithoutOrigin = await app.request("/api/subscription", { method: "POST", omitOrigin: true, headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ subscription }) });
  assert.equal(postWithoutOrigin.status, 403);
});

test("connection setup tickets require a paired device, redeem once, expire, and never change destination", async (t) => {
  let current = Date.now();
  const app = await fixture(async () => {}, { server: { now: () => current, setupTTLMS: 500 } }); t.after(app.close);
  const ticket = app.mintSetupTicket({ baseURL: "http://Mac.local:4096/", username: "", profile: "v2" });
  assert.match(ticket.code, /^[A-F0-9]{10}$/);
  assert.equal(ticket.url, `${origin}/#setup=${ticket.code}`);
  assert.ok(new Date(ticket.expiresAt).getTime() <= current + 10 * 60_000);
  assert.equal((await app.request("/api/setup/redeem", { method: "POST", body: JSON.stringify({ code: ticket.code }) })).status, 401);
  const token = await pair(app);
  const auth = { Authorization: `Bearer ${token}` };
  const redeemed = await app.request("/api/setup/redeem", { method: "POST", headers: auth, body: JSON.stringify({ code: ticket.code.toLowerCase() }) });
  assert.equal(redeemed.status, 200);
  const draft = await redeemed.json();
  assert.deepEqual(draft, { baseURL: "http://Mac.local:4096/", username: "", profile: "v2" });
  assert.deepEqual((await (await app.request("/api/status", { headers: auth })).json()).destination, { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 });
  assert.equal((await app.request("/api/destination", { method: "PUT", headers: auth, body: JSON.stringify({ ...draft, optIn: false, delaySeconds: 15 }) })).status, 200);
  assert.equal((await app.request("/api/setup/redeem", { method: "POST", headers: auth, body: JSON.stringify({ code: ticket.code }) })).status, 401);
  const expired = app.mintSetupTicket({ baseURL: "https://example.com", username: "private", profile: "legacy" });
  current += 501;
  assert.equal((await app.request("/api/setup/redeem", { method: "POST", headers: auth, body: JSON.stringify({ code: expired.code }) })).status, 401);
  assert.throws(() => app.mintSetupTicket({ baseURL: "https://example.com", username: "x".repeat(129), profile: "legacy" }), /username/);
  assert.throws(() => app.mintSetupTicket({ baseURL: "https://example.com/\u0007", username: "", profile: "legacy" }), /baseURL/);
});

test("late push completion cannot write after stop releases storage to a new owner", async (t) => {
  const timers = []; let rejectOldSend;
  const oldSend = new Promise((_, reject) => { rejectOldSend = reject; });
  const app = await fixture(() => oldSend, { server: {
    shutdownTimeoutMS: 10,
    timerFactory: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; },
    timerClear: (timer) => { timer.cancelled = true; }
  } });
  t.after(app.close);
  const token = await pair(app); await subscribe(app, token); const auth = { Authorization: `Bearer ${token}` };
  await app.request("/api/test", { method: "POST", headers: auth, body: JSON.stringify({ delaySeconds: 0.5 }) });
  const oldCompletion = timers[0].callback();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await app.stop();

  const replacement = await createNotificationServer({ dataDir: app.dataDir, publicOrigin: origin });
  await new Promise((resolve) => replacement.server.listen(0, "127.0.0.1", resolve));
  const replacementRequest = requestFor(replacement.server, origin);
  const replacementSubscription = { ...subscription, endpoint: `${endpoint}-replacement` };
  assert.equal((await replacementRequest("/api/subscription", { method: "POST", headers: auth, body: JSON.stringify({ subscription: replacementSubscription }) })).status, 200);
  await replacement.ingest({ kind: "idle", eventID: "idle:new-owner:1", target: { sessionID: "ses_new", projectID: "project_new" } });
  await replacement.flushEvents();
  const devicesBefore = await readFile(path.join(app.dataDir, "devices.json"), "utf8");
  const eventsBefore = await readFile(path.join(app.dataDir, "events.json"), "utf8");

  rejectOldSend(Object.assign(new Error("gone"), { statusCode: 410 }));
  await oldCompletion;
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(await readFile(path.join(app.dataDir, "devices.json"), "utf8"), devicesBefore);
  assert.equal(await readFile(path.join(app.dataDir, "events.json"), "utf8"), eventsBefore);
  await replacement.stop();
});

test("listener and owner conflicts fail before existing records are mutated", async (t) => {
  const dataDir = await mkdtemp(path.join(tmpdir(), "notification-owner-"));
  const marker = path.join(dataDir, "events.json");
  const original = JSON.stringify({ version: 1, devices: {}, marker: "unchanged" });
  await writeFile(marker, original, { mode: 0o600 });
  const occupied = http.createServer();
  await new Promise((resolve) => occupied.listen(0, "127.0.0.1", resolve));
  const port = occupied.address().port;
  await assert.rejects(createNotificationServer({ dataDir, publicOrigin: origin, listen: { port } }), /address already in use/i);
  assert.equal(await readFile(marker, "utf8"), original);
  await new Promise((resolve) => occupied.close(resolve));

  const lock = path.join(dataDir, "owner.lock");
  for (const unsafeRecord of ["", "not-a-complete-owner-record"]) {
    await writeFile(lock, unsafeRecord, { mode: 0o600 });
    await assert.rejects(createNotificationServer({ dataDir, publicOrigin: origin, listen: { port: 0 } }), /cannot be verified safely/);
    assert.equal(await readFile(lock, "utf8"), unsafeRecord);
    await unlink(lock);
  }

  const first = await createNotificationServer({ dataDir, publicOrigin: origin, listen: { port } });
  t.after(async () => { await first.stop(); await rm(dataDir, { recursive: true, force: true }); });
  await assert.rejects(createNotificationServer({ dataDir, publicOrigin: origin, listen: { port: 0 } }), /already owned/);
});

function requestFor(server, publicOrigin) {
  const base = `http://127.0.0.1:${server.address().port}`;
  return (pathname, options = {}) => new Promise((resolve, reject) => {
    const body = options.body || "";
    const request = http.request(`${base}${pathname}`, { method: options.method || "GET", headers: { Host: new URL(publicOrigin).host, Origin: publicOrigin, ...(body ? { "Content-Type": "application/json" } : {}), ...options.headers } }, (response) => {
      const chunks = []; response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, json: async () => JSON.parse(Buffer.concat(chunks).toString("utf8")) }));
    });
    request.on("error", reject); request.end(body);
  });
}

test("subscription endpoint rejects non-push-service endpoints", async (t) => {
  const app = await fixture(); t.after(app.close);
  const token = await pair(app);
  const rejected = await subscribe(app, token, { ...subscription, endpoint: "https://example.com/collect" });
  assert.equal(rejected.status, 400);
});

test("mutation content type and schedule bounds are enforced", async (t) => {
  const app = await fixture(); t.after(app.close);
  const token = await pair(app);
  await subscribe(app, token);
  const wrongType = await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "text/plain" }, body: JSON.stringify({ delaySeconds: 0.05 }) });
  assert.equal(wrongType.status, 415);
  const tooLong = await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ delaySeconds: 2 }) });
  assert.equal(tooLong.status, 400);
  const removedRouteInput = await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ delaySeconds: 0.05, deepLink: "openclient://" }) });
  assert.equal(removedRouteInput.status, 400);
});

test("server timer returns immediately and later sends the fixed payload", async (t) => {
  let sentAt = 0;
  let sentPayload;
  const started = Date.now();
  const app = await fixture(async (_subscription, payload) => { sentAt = Date.now(); sentPayload = JSON.parse(payload); }); t.after(app.close);
  const token = await pair(app);
  assert.equal((await subscribe(app, token)).status, 200);
  const response = await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ delaySeconds: 0.06 }) });
  assert.equal(response.status, 202);
  assert.equal(sentAt, 0);
  const scheduled = await response.json();
  assert.equal(scheduled.job.state, "scheduled");
  await new Promise((resolve) => setTimeout(resolve, 110));
  assert.ok(sentAt - started >= 50);
  assert.deepEqual(Object.keys(sentPayload), ["jobID"]);
  const status = await app.request("/api/status", { headers: { Authorization: `Bearer ${token}` } });
  assert.equal((await status.json()).jobs[0].state, "delivered");
});

test("expired push subscriptions are removed and reported clearly", async (t) => {
  const app = await fixture(async () => { throw Object.assign(new Error("gone"), { statusCode: 410 }); }); t.after(app.close);
  const token = await pair(app);
  await subscribe(app, token);
  await app.request("/api/test", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ delaySeconds: 0.03 }) });
  await new Promise((resolve) => setTimeout(resolve, 70));
  const status = await app.request("/api/status", { headers: { Authorization: `Bearer ${token}` } });
  const result = await status.json();
  assert.equal(result.subscribed, false);
  assert.equal(result.jobs[0].state, "expired");
  const stored = JSON.parse(await readFile(path.join(app.dataDir, "devices.json"), "utf8"));
  assert.equal(stored[0].subscription, null);
});

test("an expired subscription terminates sibling jobs and releases pending capacity", async (t) => {
  const timers = [];
  const app = await fixture(async () => { throw Object.assign(new Error("gone"), { statusCode: 410 }); }, {
    server: { maxPending: 2, timerFactory: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; }, timerClear: (timer) => { timer.cancelled = true; } }
  }); t.after(app.close);
  const token = await pair(app); await subscribe(app, token); const auth = { Authorization: `Bearer ${token}` };
  await app.request("/api/test", { method: "POST", headers: auth, body: JSON.stringify({ delaySeconds: 0.5 }) });
  await app.request("/api/test", { method: "POST", headers: auth, body: JSON.stringify({ delaySeconds: 0.5 }) });
  await timers[0].callback();
  assert.equal(timers[1].cancelled, true);
  let status = await (await app.request("/api/status", { headers: auth })).json();
  assert.deepEqual(new Set(status.jobs.map((job) => job.state)), new Set(["expired", "cancelled"]));
  await subscribe(app, token);
  assert.equal((await app.request("/api/test", { method: "POST", headers: auth, body: JSON.stringify({ delaySeconds: 0.5 }) })).status, 202);
  status = await (await app.request("/api/status", { headers: auth })).json();
  assert.equal(status.jobs[0].state, "scheduled");
});
