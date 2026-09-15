import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

test("service worker awaits successful shell caching and skips request-specific URLs", async () => {
  const source = await readFile(new URL("../public/sw.js", import.meta.url), "utf8");
  assert.match(source, /notification-pwa-shell-v9/);
  assert.match(source, /"\/events\.html"/);
  assert.match(source, /"\/events\.js"/);
  assert.doesNotMatch(source, /skipWaiting\s*\(/);
  const listeners = new Map(); const puts = [];
  const response = { ok: true, clone: () => ({ copy: true }) };
  const context = {
    URL, importScripts: () => {}, NotificationHandoff: { validate: () => null },
    fetch: async () => response,
    caches: { open: async () => ({ addAll: async () => {}, put: async (...args) => puts.push(args) }), keys: async () => [], delete: async () => {}, match: async () => null },
    self: {
      location: { origin: "https://pwa.example" }, navigator: { language: "en" }, registration: {}, clients: { claim: async () => {} },
      skipWaiting: async () => {}, addEventListener: (type, callback) => listeners.set(type, callback)
    }
  };
  vm.createContext(context); vm.runInContext(source, context);
  let handled;
  listeners.get("fetch")({ request: { method: "GET", url: "https://pwa.example/app.js", mode: "same-origin" }, respondWith: (value) => { handled = value; } });
  assert.equal(await handled, response);
  assert.deepEqual(puts.map(([key]) => key), ["/app.js"]);
  listeners.get("fetch")({ request: { method: "GET", url: "https://pwa.example/handoff.html?private=1", mode: "navigate" }, respondWith: (value) => { handled = value; } });
  assert.equal(await handled, response);
  assert.deepEqual(puts.map(([key]) => key), ["/app.js"]);
});

async function showPush(payload, language = "en") {
  const source = await readFile(new URL("../public/sw.js", import.meta.url), "utf8");
  const listeners = new Map(); const shown = [];
  const context = {
    URL, importScripts: () => {},
    NotificationHandoff: { validate: (value) => value && value.v === 1 ? structuredClone(value) : null },
    fetch: async () => ({ ok: true }), caches: { open: async () => ({ put: async () => {} }), keys: async () => [], delete: async () => {}, match: async () => null },
    self: {
      location: { origin: "https://pwa.example" }, navigator: { language },
      registration: { showNotification: async (...args) => shown.push(args) },
      clients: {}, addEventListener: (type, callback) => listeners.set(type, callback)
    }
  };
  vm.createContext(context); vm.runInContext(source, context);
  let pending;
  listeners.get("push")({ data: { json: () => structuredClone(payload) }, waitUntil: (value) => { pending = value; } });
  await pending;
  return shown[0];
}

const target = { v: 1, profile: "legacy", serverID: "http://mac.local:4096/|opencode", sessionID: "ses_notification_123456789", projectID: "project_1", directory: "/tmp/openclient" };

test("real push kinds use contextual captions without changing routing data", async () => {
  for (const [kind, headline] of [["idle", "Session is idle"], ["permission", "OpenCode needs permission"], ["question", "OpenCode has a question"]]) {
    const [title, options] = await showPush({ kind, data: target, context: { projectName: "openclient", sessionTitle: "Improve notification captions" } });
    assert.equal(title, headline);
    assert.equal(options.body, "openclient · Improve notification captions");
    assert.deepEqual(options.data.target, target);
    assert.equal(options.icon, "/icons/icon-192.png?v=5");
    assert.equal(options.badge, "/icons/icon-192.png?v=5");
  }
});

test("missing and older context use localized safe target fallbacks", async () => {
  let [, options] = await showPush({ kind: "idle", data: target });
  assert.equal(options.body, "openclient · Session ses_notification");
  [, options] = await showPush({ kind: "question", data: { ...target, directory: "/", projectID: "global" } }, "pt-BR");
  assert.equal(options.body, "Global · Sessão ses_notification");
  [, options] = await showPush({ kind: "permission", data: { ...target, directory: undefined } }, "it");
  assert.equal(options.body, "Progetto project_1 · Sessione ses_notification");
});

test("job-only tests retain test wording and hostile display context is bounded text", async () => {
  let [title, options] = await showPush({ jobID: "job_1" });
  assert.equal(title, "OpenClient handoff ready");
  assert.equal(options.body, "Tap to open the safe handoff page.");
  const projectName = `Prógetto\n${"😀".repeat(100)}\u202eevil`;
  const sessionTitle = `<b>${"é".repeat(150)}</b>`;
  [title, options] = await showPush({ kind: "idle", data: target, context: { projectName, sessionTitle, href: "https://evil.example" } });
  assert.equal(title, "Session is idle");
  assert.ok(!options.body.includes("\n"));
  assert.ok(!options.body.includes("\u202e"));
  assert.ok(options.body.includes("<b>"));
  assert.ok(Array.from(options.body.split(" · ")[0]).length <= 80);
  assert.ok(Array.from(options.body.split(" · ")[1]).length <= 120);
  assert.deepEqual(options.data.target, target);
});
