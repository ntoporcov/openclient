import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createPluginBridge, createSourceEndpointAdvertiser } from "../src/plugin-bridge.mjs";

async function fixture(sessions, options = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), "notification-plugin-"));
  const tokenFile = path.join(dir, "token"); await writeFile(tokenFile, "safe-token", { mode: 0o600 });
  const sent = [];
  const client = options.client || { session: { get: async ({ path, query }) => ({ data: sessions[path.id], error: null, query }) } };
  const warnings = [];
  const bridge = createPluginBridge({ client, directory: "/repo", project: options.project, tokenFile, timeoutMs: options.timeoutMs || 2_000, onError: (message) => warnings.push(message), fetchImpl: options.fetchImpl || (async (_url, request) => { sent.push(JSON.parse(request.body).event); return { ok: true }; }) });
  return { bridge, sent, warnings, close: () => rm(dir, { recursive: true, force: true }) };
}

test("active root session emits one canonical idle notification and ignores deprecated idle", async (t) => {
  const app = await fixture({ ses_root: { id: "ses_root", projectID: "project_1", directory: "/repo" } }); t.after(app.close);
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "busy" } } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "idle" } } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "idle" } } });
  app.bridge.handle({ type: "session.idle", properties: { sessionID: "ses_root" } });
  await app.bridge.idle();
  assert.deepEqual(app.sent.map((event) => event.kind), ["activity", "idle"]);
  assert.deepEqual(app.sent[1].target, { sessionID: "ses_root", projectID: "project_1", directory: "/repo" });
});

test("fresh canonical session and project updates produce bounded display context", async (t) => {
  const sessions = { ses_root: { id: "ses_root", projectID: "project_1", directory: "/repo", title: "Initial title" } };
  const app = await fixture(sessions, { project: { id: "project_1", name: "Old name", worktree: "/wrong" } }); t.after(app.close);
  app.bridge.handle({ type: "project.updated", properties: { id: "project_1", name: `openclient\u202e${"😀".repeat(100)}`, worktree: "/repo" } });
  sessions.ses_root.title = `Improve\nnotification captions ${"é".repeat(150)}`;
  app.bridge.handle({ type: "question.asked", properties: { id: "q_context", sessionID: "ses_root" } });
  await app.bridge.idle();
  assert.equal(app.sent[0].context.projectName.includes("\u202e"), false);
  assert.equal(Array.from(app.sent[0].context.projectName).length, 80);
  assert.equal(app.sent[0].context.sessionTitle.startsWith("Improve notification captions"), true);
  assert.equal(Array.from(app.sent[0].context.sessionTitle).length, 120);
});

test("mismatched projects never label a child session and use its directory basename", async (t) => {
  const app = await fixture({ ses_child: { id: "ses_child", projectID: "project_child", directory: "/work/child-project", title: "Child task", parentID: "ses_root" } }, { project: { id: "project_parent", name: "Parent project", worktree: "/work/parent" } }); t.after(app.close);
  app.bridge.handle({ type: "permission.asked", properties: { id: "perm_child", sessionID: "ses_child" } });
  await app.bridge.idle();
  assert.deepEqual(app.sent[0].context, { projectName: "child-project", sessionTitle: "Child task" });
});

test("matched project worktree supplies project fallback while a missing title is omitted", async (t) => {
  const app = await fixture({ ses_root: { id: "ses_root", projectID: "project_1", directory: "/work/session-directory" } }, { project: { id: "project_1", worktree: "/work/canonical-project" } }); t.after(app.close);
  app.bridge.handle({ type: "question.asked", properties: { id: "q_missing_title", sessionID: "ses_root" } });
  await app.bridge.idle();
  assert.deepEqual(app.sent[0].context, { projectName: "canonical-project" });
});

test("hung canonical lookup times out and the serial queue resumes", async (t) => {
  const sessions = { ses_next: { id: "ses_next", projectID: "project_1", directory: "/repo" } };
  const client = { session: { get: ({ path }) => path.id === "ses_hung" ? new Promise(() => {}) : Promise.resolve({ data: sessions[path.id], error: null }) } };
  const app = await fixture(sessions, { client, timeoutMs: 20 }); t.after(app.close);
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_hung", status: { type: "busy" } } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_hung", status: { type: "idle" } } });
  app.bridge.handle({ type: "question.asked", properties: { id: "q_next", sessionID: "ses_next" } });
  await app.bridge.idle();
  assert.deepEqual(app.sent.map((event) => event.kind), ["activity", "question"]);
  assert.deepEqual(app.warnings, ["Notification bridge session lookup timed out."]);
});

test("HTTP bridge errors emit only a sanitized fail-open diagnostic", async (t) => {
  const app = await fixture({}, { fetchImpl: async () => ({ ok: false, status: 503 }) }); t.after(app.close);
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_1", status: { type: "busy" } } });
  await app.bridge.idle();
  assert.deepEqual(app.warnings, ["Notification bridge HTTP request failed (status 503)."]);
  assert.ok(!app.warnings[0].includes("safe-token"));
  assert.ok(!app.warnings[0].includes("127.0.0.1"));
});

test("canonical lookup rejects a different returned session ID", async (t) => {
  const client = { session: { get: async () => ({ data: { id: "ses_other", projectID: "project_1", directory: "/repo" }, error: null }) } };
  const app = await fixture({}, { client }); t.after(app.close);
  app.bridge.handle({ type: "question.asked", properties: { id: "q_1", sessionID: "ses_expected" } });
  await app.bridge.idle();
  assert.deepEqual(app.sent, []);
  assert.deepEqual(app.warnings, ["Notification bridge task failed."]);
});

test("parallel plugin instances derive the same process-cycle idle event ID", async (t) => {
  const sessions = { ses_parallel: { id: "ses_parallel", projectID: "project_1", directory: "/repo" } };
  const first = await fixture(sessions); const second = await fixture(sessions);
  t.after(first.close); t.after(second.close);
  const busy = { type: "session.status", properties: { sessionID: "ses_parallel", status: { type: "busy" } } };
  const idle = { type: "session.status", properties: { sessionID: "ses_parallel", status: { type: "idle" } } };
  first.bridge.handle(busy); second.bridge.handle(busy); first.bridge.handle(idle); second.bridge.handle(idle);
  await Promise.all([first.bridge.idle(), second.bridge.idle()]);
  assert.equal(first.sent.find((event) => event.kind === "idle").eventID, second.sent.find((event) => event.kind === "idle").eventID);
});

test("replacement plugin instance completes a cycle armed before reload", async (t) => {
  const sessions = { ses_reload: { id: "ses_reload", projectID: "project_1", directory: "/repo" } };
  const beforeReload = await fixture(sessions); const afterReload = await fixture(sessions);
  t.after(beforeReload.close); t.after(afterReload.close);
  beforeReload.bridge.handle({ type: "session.status", properties: { sessionID: "ses_reload", status: { type: "busy" } } });
  await beforeReload.bridge.idle();
  afterReload.bridge.handle({ type: "session.status", properties: { sessionID: "ses_reload", status: { type: "idle" } } });
  await afterReload.bridge.idle();
  assert.deepEqual(afterReload.sent.map((event) => event.kind), ["idle"]);
});

test("errors suppress completion and a later cycle can complete", async (t) => {
  const app = await fixture({ ses_root: { id: "ses_root", projectID: "project_1", directory: "/repo" } }); t.after(app.close);
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "busy" } } });
  app.bridge.handle({ type: "session.error", properties: { sessionID: "ses_root" } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "idle" } } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "busy" } } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "idle" } } });
  await app.bridge.idle();
  assert.deepEqual(app.sent.map((event) => event.kind), ["activity", "error", "activity", "idle"]);
});

test("subagent completion is skipped and resolved child interactions suppress late scheduling", async (t) => {
  const app = await fixture({ ses_child: { id: "ses_child", projectID: "project_1", directory: "/repo", parentID: "ses_root" } }); t.after(app.close);
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_child", status: { type: "busy" } } });
  app.bridge.handle({ type: "session.status", properties: { sessionID: "ses_child", status: { type: "idle" } } });
  const permission = { type: "permission.asked", properties: { id: "perm_1", sessionID: "ses_child" } };
  app.bridge.handle(permission); app.bridge.handle(permission);
  app.bridge.handle({ type: "permission.replied", properties: { requestID: "perm_1", sessionID: "ses_child" } });
  await app.bridge.idle();
  assert.deepEqual(app.sent.map((event) => event.kind), ["activity", "permission-resolved"]);
});

test("source advertiser reads the server URL lazily and sends only sanitized protocol and port", async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), "notification-source-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const tokenFile = path.join(dir, "token"); await writeFile(tokenFile, "safe-token", { mode: 0o600 });
  let serverURL = new URL("http://user:secret@0.0.0.0:4096/path?token=nope");
  const requests = [];
  const advertiser = createSourceEndpointAdvertiser({
    getServerURL: () => serverURL,
    tokenFile,
    now: () => 120_000,
    fetchImpl: async (_url, request) => { requests.push(JSON.parse(request.body)); return { ok: true }; }
  });
  assert.equal(await advertiser.advertise(), false);
  serverURL = new URL("http://0.0.0.0:4096");
  assert.equal(await advertiser.advertise(), true);
  assert.deepEqual(requests, [{ source: "openclient-ios-local", sourceEndpoint: { protocol: "http", port: 4096 } }]);
});

test("source advertisement is fail-open and retries unchanged metadata after the bounded interval", async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), "notification-source-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const tokenFile = path.join(dir, "token"); await writeFile(tokenFile, "safe-token", { mode: 0o600 });
  let current = 1;
  let attempts = 0;
  const warnings = [];
  const advertiser = createSourceEndpointAdvertiser({
    getServerURL: () => new URL("https://localhost"), tokenFile, now: () => current,
    onError: (message) => warnings.push(message), fetchImpl: async () => { attempts += 1; throw new Error("secret failure"); }
  });
  assert.equal(await advertiser.advertise(), false);
  assert.equal(await advertiser.advertise(), false);
  current += 60_000;
  assert.equal(await advertiser.advertise(), false);
  assert.equal(attempts, 2);
  assert.deepEqual(warnings, ["Notification bridge source hint failed.", "Notification bridge source hint failed."]);
});
