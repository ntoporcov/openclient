import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

test("cached handoff validates, round-trips, and builds only the fixed session route", async () => {
  const source = await readFile(new URL("../public/handoff-core.js", import.meta.url), "utf8");
  const context = { TextEncoder, TextDecoder, btoa, atob };
  vm.createContext(context); vm.runInContext(source, context);
  const target = { v: 1, profile: "v2", serverID: "https://host/|user name", sessionID: "ses_1", projectID: "project_1", directory: "/tmp/a b" };
  const fragment = context.NotificationHandoff.fragment(target);
  const decoded = context.NotificationHandoff.fromFragment(fragment);
  assert.equal(JSON.stringify(decoded), JSON.stringify(target));
  assert.equal(context.NotificationHandoff.openClientURL(decoded), "openclient://widget/session?profile=v2&serverID=https%3A%2F%2Fhost%2F%7Cuser%20name&sessionID=ses_1&projectID=project_1&directory=%2Ftmp%2Fa%20b");
  assert.equal(context.NotificationHandoff.openClientURL({ ...target, profile: "automatic" }), "openclient://");
});

test("reused handoff page replaces the target and cancels stale auto-open", async () => {
  const core = await readFile(new URL("../public/handoff-core.js", import.meta.url), "utf8");
  const handoff = await readFile(new URL("../public/handoff.js", import.meta.url), "utf8");
  const listeners = new Map(); const timers = []; const elements = new Map();
  const element = (id) => { if (!elements.has(id)) elements.set(id, { id, textContent: "", href: "" }); return elements.get(id); };
  const context = {
    TextEncoder, TextDecoder, btoa, atob,
    navigator: { language: "en", serviceWorker: { addEventListener: (type, callback) => listeners.set(`sw:${type}`, callback) } },
    document: { documentElement: {}, getElementById: element }, localStorage: { getItem: () => "true" },
    location: { hash: "", href: "" }, addEventListener: (type, callback) => listeners.set(type, callback),
    setTimeout: (callback) => { const timer = { callback, cancelled: false }; timers.push(timer); return timer; },
    clearTimeout: (timer) => { timer.cancelled = true; }
  };
  vm.createContext(context); vm.runInContext(core, context);
  const a = { v: 1, profile: "legacy", serverID: "http://a|", sessionID: "ses_a", projectID: "project_1" };
  const b = { v: 1, profile: "v2", serverID: "http://b|user", sessionID: "ses_b", projectID: "project_2", directory: "/repo" };
  context.location.hash = context.NotificationHandoff.fragment(a);
  vm.runInContext(handoff, context);
  context.location.hash = context.NotificationHandoff.fragment(b);
  listeners.get("hashchange")();
  assert.equal(timers[0].cancelled, true);
  assert.match(element("open").href, /sessionID=ses_b/);
  listeners.get("sw:message")({ data: { target: b } });
  assert.equal(timers[1].cancelled, true);
  timers[2].callback();
  assert.equal(context.location.href, element("open").href);
  assert.match(context.location.href, /sessionID=ses_b/);
});
