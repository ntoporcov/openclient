import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const publicFile = (name) => readFile(new URL(`../public/${name}`, import.meta.url), "utf8");

const deferred = () => {
  let resolve;
  const promise = new Promise((completion) => { resolve = completion; });
  return { promise, resolve };
};

async function appHarness({ permission = "default", supportsPush = true, request, hostname = "notify.example" }) {
  const source = await publicFile("app.js");
  const elements = new Map();
  const listeners = new Map();
  const element = (id = "generated") => {
    if (elements.has(id)) return elements.get(id);
    const value = {
      id, value: id === "username" ? "opencode" : id === "profile" ? "legacy" : id === "delay" ? "15" : "", checked: false,
      hidden: false, disabled: false, open: true, dataset: {}, className: "", textContent: "", tagName: id === "profile" ? "SELECT" : "INPUT",
      type: ["real-events", "auto-open"].includes(id) ? "checkbox" : "text",
      addEventListener: (type, callback) => listeners.set(`${id}:${type}`, callback),
      setAttribute: () => {}, replaceChildren: (...children) => { value.children = children; }, append: () => {},
      classList: { add: (name) => { value.className += ` ${name}`; }, toggle: (name, enabled) => { value.className = enabled ? `${value.className} ${name}` : value.className.replace(name, ""); } }
    };
    elements.set(id, value);
    return value;
  };
  const storage = new Map([["notification-pwa-device-token", "token"]]);
  const serviceWorker = { register: async () => ({ update: async () => {} }), addEventListener: () => {} };
  const navigator = { language: "en", userAgent: "test", platform: "test", maxTouchPoints: 0, standalone: false, ...(supportsPush ? { serviceWorker } : {}) };
  const Notification = { permission };
  const window = { isSecureContext: true, location: { hostname }, ...(supportsPush ? { PushManager: function PushManager() {}, Notification } : {}) };
  const context = {
    window, navigator, Notification, Uint8Array, atob, confirm: () => true,
    localStorage: { getItem: (key) => storage.get(key) || null, setItem: (key, value) => storage.set(key, value), removeItem: (key) => storage.delete(key) },
    document: { documentElement: {}, title: "", querySelectorAll: () => [], getElementById: element, createElement: () => element(`generated-${elements.size}`) },
    fetch: async (path, options) => ({ ok: true, json: async () => request(path, options) })
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return { context, element, listeners };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("settings markup preserves functional IDs and native control semantics", async () => {
  const html = await publicFile("index.html");
  for (const id of ["pair-code", "pair", "enable", "base-url", "username", "profile", "real-events", "save-destination", "auto-open", "delay", "schedule", "status", "refresh", "jobs", "reset"]) {
    assert.match(html, new RegExp(`id=["']${id}["']`), `missing #${id}`);
  }
  assert.equal(html.match(/id="delay"/g)?.length, 1);
  assert.match(html, /id="delay"[^>]+min="5"[^>]+max="120"/);
  assert.match(html, /id="real-events"[^>]+role="switch"/);
  assert.match(html, /id="auto-open"[^>]+role="switch"/);
  assert.match(html, /id="status-banner"[^>]+aria-live="polite"/);
  assert.match(html, /id="advanced-details"/);
  assert.match(html, /id="connection-summary"/);
  assert.doesNotMatch(html, /TRANSPORT PROTOTYPE|fake-status-bar|drag-handle/);
});

test("PWA pages use translucent standalone status bars without a header gradient", async () => {
  for (const file of ["index.html", "events.html", "handoff.html"]) {
    const html = await publicFile(file);
    assert.match(html, /name="apple-mobile-web-app-capable" content="yes"/);
    assert.match(html, /name="apple-mobile-web-app-status-bar-style" content="black-translucent"/);
    assert.match(html, /viewport-fit=cover/);
    assert.doesNotMatch(html, /pastel-backdrop/);
  }
  assert.match(await publicFile("styles.css"), /env\(safe-area-inset-top\)/);
});

test("events screen is a separate discoverable authenticated diagnostic surface", async () => {
  const [settings, events, source] = await Promise.all([publicFile("index.html"), publicFile("events.html"), publicFile("events.js")]);
  assert.match(settings, /href="\/events\.html"/);
  assert.match(events, /class="back-link" href="\/"/);
  for (const id of ["events-refresh", "source-summary", "events-error", "persistence-warning", "events-unpaired", "events-empty", "events-content", "event-list", "last-updated"]) assert.match(events, new RegExp(`id=["']${id}["']`));
  assert.match(source, /Authorization: `Bearer \$\{token\}`/);
  assert.match(source, /visibilitychange/);
  assert.match(source, /setInterval\(\(\) => \{ if \(!document\.hidden\) refresh\(\); \}, 3000\)/);
  assert.match(source, /controller\?\.abort\(\)/);
  assert.doesNotMatch(source, /innerHTML|subscription\.endpoint|baseURL|username|password|Delivered to iPhone/);
});

test("settings localization covers every markup key in all supported languages", async () => {
  const [html, source] = await Promise.all([publicFile("index.html"), publicFile("app.js")]);
  const declaration = source.slice(source.indexOf("const text = "), source.indexOf("\n\nconst language"));
  const context = {};
  vm.createContext(context);
  vm.runInContext(`${declaration}; globalThis.translations = text;`, context);
  const markupKeys = [...html.matchAll(/data-i18n(?:-aria)?="([^"]+)"/g)].map((match) => match[1]);
  for (const language of ["en", "pt-BR", "it"]) {
    assert.deepEqual(markupKeys.filter((key) => !context.translations[language][key]), [], `${language} has missing UI copy`);
    assert.deepEqual(Object.keys(context.translations[language]), Object.keys(context.translations.en), `${language} key set differs from English`);
    assert.match(context.translations[language].activityCountOne, /^1\s/);
    assert.match(context.translations[language].activityCountMany, /\{count\}/);
  }
});

test("events localization covers markup and semantic outcomes in every supported language", async () => {
  const [html, source] = await Promise.all([publicFile("events.html"), publicFile("events.js")]);
  const declaration = source.slice(source.indexOf("const text = "), source.indexOf("\n\nconst language"));
  const context = {};
  vm.createContext(context);
  vm.runInContext(`${declaration}; globalThis.translations = text;`, context);
  const markupKeys = [...html.matchAll(/data-i18n(?:-aria)?="([^"]+)"/g)].map((match) => match[1]);
  for (const language of ["en", "pt-BR", "it"]) {
    assert.deepEqual(markupKeys.filter((key) => !context.translations[language][key]), [], `${language} has missing Events copy`);
    assert.deepEqual(Object.keys(context.translations[language]), Object.keys(context.translations.en), `${language} Events key set differs from English`);
    assert.match(context.translations[language].eventCountOne, /^1\s/);
    assert.match(context.translations[language].eventCountMany, /\{count\}/);
    assert.ok(context.translations[language].outcomeAccepted);
    assert.ok(context.translations[language].reasonRestarted);
  }
});

test("handoff keeps the safe action IDs and a normal settings return path", async () => {
  const html = await publicFile("handoff.html");
  assert.match(html, /id="open" href="openclient:\/\/"/);
  assert.match(html, /id="settings" href="\/"/);
  assert.doesNotMatch(html, /SAFE HANDOFF|TRANSPORT PROTOTYPE/);
});

test("browser permission truth takes priority over a retained server subscription", async () => {
  const state = { subscribed: true, destination: { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 }, jobs: [], bridge: null };
  const denied = await appHarness({ permission: "denied", request: async () => state });
  await settle();
  assert.equal(denied.element("permission-summary").textContent, "Blocked in Settings");
  assert.equal(denied.element("status").textContent, "Notification permission is blocked. You can change it in Settings.");

  const unsupported = await appHarness({ supportsPush: false, request: async () => state });
  await settle();
  assert.equal(unsupported.element("permission-summary").textContent, "Unavailable in this browser");
  assert.equal(unsupported.element("status").textContent, "This browser does not support installed-app notifications.");
});

test("slow initial hydration does not overwrite destination edits", async () => {
  const status = deferred();
  const app = await appHarness({ request: () => status.promise });
  app.element("base-url").value = "https://editing.example";
  app.listeners.get("base-url:input")();
  status.resolve({ subscribed: false, destination: { optIn: true, baseURL: "https://saved.example", username: "saved", profile: "v2", delaySeconds: 30 }, jobs: [], bridge: null });
  await settle();
  assert.equal(app.element("base-url").value, "https://editing.example");
  assert.equal(app.element("save-state").textContent, "Unsaved changes");
});

test("fresh paired blank destination receives an unsaved suggestion while saved identity remains exact", async () => {
  const blank = { subscribed: false, destination: { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 }, sourceEndpoint: { protocol: "http", port: 4096, provenance: "plugin" }, jobs: [], bridge: null };
  const fresh = await appHarness({ hostname: "notify.example", request: async () => blank });
  await settle();
  assert.equal(fresh.element("base-url").value, "http://notify.example:4096");
  assert.equal(fresh.element("connection-summary").textContent, "http://notify.example:4096");
  assert.equal(fresh.element("save-state").textContent, "Unsaved changes");
  assert.equal(fresh.element("suggested-label").hidden, false);

  const savedURL = "HTTP://Saved.Example:4096/custom/";
  const saved = await appHarness({ request: async () => ({ ...blank, destination: { ...blank.destination, baseURL: savedURL } }) });
  await settle();
  assert.equal(saved.element("base-url").value, savedURL);
  assert.equal(saved.element("connection-summary").textContent, savedURL);
  assert.equal(saved.element("save-state").textContent, "Saved");
  assert.equal(saved.element("suggested-label").hidden, true);
});

test("late metadata fills an untouched blank destination but preserves later edits", async () => {
  let state = { subscribed: false, destination: { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 }, jobs: [], bridge: null };
  const app = await appHarness({ request: async () => state });
  await settle();
  assert.equal(app.element("base-url").value, "");
  assert.equal(app.element("advanced-details").open, true);
  state = { ...state, sourceEndpoint: { protocol: "http", port: 4096, provenance: "configuration" } };
  await app.listeners.get("refresh:click")();
  assert.equal(app.element("base-url").value, "http://notify.example:4096");
  assert.equal(app.element("advanced-details").open, false);
  app.element("base-url").value = "https://custom.example/";
  app.listeners.get("base-url:input")();
  state = { ...state, sourceEndpoint: { protocol: "https", port: 443, provenance: "plugin" } };
  await app.listeners.get("refresh:click")();
  assert.equal(app.element("base-url").value, "https://custom.example/");
});

test("completed save clears dirty state only when the submitted form is unchanged", async () => {
  const save = deferred();
  const initial = { subscribed: false, destination: { optIn: false, baseURL: "https://saved.example", username: "opencode", profile: "legacy", delaySeconds: 15 }, jobs: [], bridge: null };
  const app = await appHarness({ request: (path, options) => path === "/api/destination" && options?.method === "PUT" ? save.promise : initial });
  await settle();
  app.element("base-url").value = "https://submitted.example";
  app.listeners.get("base-url:input")();
  const saving = app.listeners.get("save-destination:click")();
  app.element("base-url").value = "https://new-edit.example";
  app.listeners.get("base-url:input")();
  save.resolve({});
  await saving;
  assert.equal(app.element("base-url").value, "https://new-edit.example");
  assert.equal(app.element("save-state").textContent, "Unsaved changes");
  assert.equal(app.element("save-destination").disabled, false);
  assert.equal(app.element("status").textContent, "Submitted destination saved. Newer changes remain unsaved.");
});
