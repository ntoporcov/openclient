#!/usr/bin/env node

import { mkdir, rm, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const DEFAULT_URL = process.env.OPENCLIENT_NOTIFY_URL ?? "https://openclient.example/";
const DEFAULT_OUTPUT = join(ROOT, ".data/ui-screenshots");
const CHROME = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const cases = [
  ["mobile-light-paired", 390, 844, true, "light", true, "saved"],
  ["mobile-dark-paired", 390, 844, true, "dark", true, "saved"],
  ["desktop-light-paired", 1280, 1000, false, "light", true, "saved"],
  ["mobile-light-fresh", 390, 844, true, "light", true, "fresh"],
  ["narrow-light-unpaired", 320, 740, true, "light", false, "none"],
];

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1] ?? fallback;
};
const TARGET_URL = option("--url", DEFAULT_URL);
const OUTPUT = option("--output", DEFAULT_OUTPUT);
const TIMEOUT = Number(option("--timeout", "30000"));
async function deadline(promise, ms = TIMEOUT) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms);
      timer.unref?.();
    })]);
  } finally {
    clearTimeout(timer);
  }
}

class CDP {
  constructor(socket) {
    this.socket = socket;
    this.id = 0;
    this.pending = new Map();
    this.events = new Map();
    socket.addEventListener("message", ({ data }) => {
      const message = JSON.parse(data);
      if (message.id) {
        const request = this.pending.get(message.id);
        if (!request) return;
        this.pending.delete(message.id);
        message.error ? request.reject(new Error(message.error.message)) : request.resolve(message.result);
      } else (this.events.get(message.method) ?? []).forEach((handler) => handler(message.params, message.sessionId));
    });
  }
  on(method, handler) { this.events.set(method, [...(this.events.get(method) ?? []), handler]); }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  close() { this.socket.close(); }
}

function response(body, status = 200) {
  return { responseCode: status, responseHeaders: [{ name: "Content-Type", value: "application/json" }], body: Buffer.from(JSON.stringify(body)).toString("base64") };
}

async function launch() {
  const profile = join(ROOT, `.data/ui-browser-${process.pid}-${Date.now()}`);
  await mkdir(profile, { recursive: true });
  const chrome = spawn(CHROME, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  const listening = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Chrome did not expose a DevTools endpoint")), TIMEOUT);
    timer.unref?.();
    chrome.stderr.on("data", (chunk) => {
      stderr += chunk;
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    chrome.once("error", reject);
  });
  try {
    const browserURL = await deadline(listening);
    const socket = new WebSocket(browserURL);
    await deadline(new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", reject, { once: true });
    }));
    return { chrome, profile, cdp: new CDP(socket) };
  } catch (error) {
    await stop(chrome, profile);
    throw error;
  }
}

async function stop(chrome, profile) {
  if (chrome && chrome.exitCode === null) {
    chrome.kill("SIGTERM");
    const grace = new Promise((resolve) => {
      const timer = setTimeout(resolve, 1000);
      timer.unref?.();
    });
    await Promise.race([once(chrome, "exit"), grace]);
    if (chrome.exitCode === null) {
      chrome.kill("SIGKILL");
      await once(chrome, "exit").catch(() => {});
    }
  }
  if (profile) await rm(profile, { recursive: true, force: true });
}

async function runCase(browser, [name, width, height, mobile, scheme, paired, destinationMode]) {
  const { cdp } = browser;
  const target = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId: target.targetId, flatten: true });
  const call = (method, params) => cdp.send(method, params, sessionId);
  const errors = [];
  cdp.on("Runtime.exceptionThrown", (event, eventSessionId) => {
    if (eventSessionId === sessionId) errors.push(event.exceptionDetails?.text ?? "JavaScript exception");
  });
  const fixtureScript = `
    localStorage.setItem("notification-pwa-auto-open", "false");
    ${paired ? 'localStorage.setItem("notification-pwa-device-token", "smoke-token");' : 'localStorage.removeItem("notification-pwa-device-token");'}
    try { Object.defineProperty(navigator, "clipboard", { configurable: true, value: { readText: async () => "ocnotify:v1:ABCDEF1234:0123456789", writeText: async () => {} } }); } catch {}
    try { Object.defineProperty(Notification, "permission", { configurable: true, get: () => "granted" }); } catch {}
    try { Notification.requestPermission = () => Promise.resolve("granted"); } catch {}
  `;
  await call("Page.addScriptToEvaluateOnNewDocument", { source: fixtureScript });
  await call("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile, screenWidth: width, screenHeight: height });
  await call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: scheme }] });
  await call("Runtime.enable");
  await call("Page.enable");
  await call("Fetch.enable", { patterns: [{ urlPattern: "*://*/api/*", requestStage: "Request" }] });
  cdp.on("Fetch.requestPaused", async ({ requestId, request }, eventSessionId) => {
    if (eventSessionId !== sessionId) return;
    const path = new globalThis.URL(request.url).pathname;
    let body = { ok: true };
    let status = 200;
    if (path === "/api/status") body = paired ? { subscribed: true, destination: { optIn: destinationMode === "saved", baseURL: destinationMode === "saved" ? "http://mac.local:4096" : "", username: "opencode", profile: "legacy", delaySeconds: 15 }, sourceEndpoint: { protocol: "http", port: 4096, provenance: "plugin" }, jobs: [], bridge: null } : { subscribed: false, destination: null, jobs: [], bridge: null };
    else if (path === "/api/events" && paired) body = { persistence: "ok", source: { name: "openclient-ios-local", lastSeenAt: new Date().toISOString(), lastReceivedAt: new Date().toISOString(), lastKind: "idle" }, events: [
      { id: "accepted", kind: "idle", sessionID: "ses_demo_accepted", projectID: "project_demo", projectName: "OpenClient", sessionTitle: "Notification event history", receivedAt: new Date(Date.now() - 18000).toISOString(), scheduledAt: new Date(Date.now() - 15000).toISOString(), finishedAt: new Date(Date.now() - 3000).toISOString(), outcome: "accepted" },
      { id: "cancelled", kind: "permission", eventID: "permission:demo", sessionID: "ses_demo_cancelled", projectID: "project_demo", directoryName: "openclient", receivedAt: new Date(Date.now() - 80000).toISOString(), scheduledAt: new Date(Date.now() - 70000).toISOString(), finishedAt: new Date(Date.now() - 65000).toISOString(), outcome: "cancelled", reason: "request-resolved" },
      { id: "skipped", kind: "question", sessionID: "ses_demo_skipped", projectID: "project_demo", receivedAt: new Date(Date.now() - 120000).toISOString(), finishedAt: new Date(Date.now() - 120000).toISOString(), outcome: "skipped", reason: "opt-out" }
    ] };
    else if (path === "/api/destination" && request.method === "PUT") body = { ok: true };
    else if (path === "/api/setup/redeem" && request.method === "POST" && paired) body = { baseURL: "http://native-saved.local:4096/", username: "", profile: "legacy" };
    else if (path === "/api/test" && request.method === "POST") body = { job: { id: "demo", state: "scheduled", scheduledAt: Date.now() + 15000, message: "Smoke test" } };
    else if (path === "/api/config") body = { vapidPublicKey: "" };
    else if (!paired && path !== "/api/status") status = 401;
    try { await call("Fetch.fulfillRequest", { requestId, ...response(body, status) }); } catch { /* target may have closed */ }
  });
  await call("Page.navigate", { url: TARGET_URL });
  const evaluate = async (expression) => {
    const result = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text ?? "Runtime evaluation failed");
    if (!result.result) throw new Error("Runtime evaluation returned no result");
    return result.result.value;
  };
  await deadline(evaluate(`new Promise(resolve => { const check = () => document.readyState === "complete" && document.querySelector("#status") ? resolve(true) : setTimeout(check, 50); check(); })`));
  const controls = await evaluate(`["paste-setup","transfer-status","enable","base-url","username","profile","delay","real-events","save-destination","auto-open","schedule","status","refresh","jobs","reset"].filter(id => !document.getElementById(id))`);
  if (controls.length) throw new Error(`${name}: missing controls: ${controls.join(", ")}`);
  const expectedURL = destinationMode === "fresh" ? `http://${new URL(TARGET_URL).hostname}:4096` : "http://mac.local:4096";
  const initialState = await deadline(evaluate(`new Promise(resolve => { const check = () => { const text = document.querySelector("#status").textContent; const initialized = ${paired ? `/notifications are enabled|paired/i.test(text) && document.querySelector("#base-url").value === ${JSON.stringify(expectedURL)}` : '/pair|ready/i.test(text)'}; if (initialized) resolve({ status: text, baseURL: document.querySelector("#base-url").value, advancedOpen: document.querySelector("#advanced-details").open }); else setTimeout(check, 50); }; check(); })`));
  const dimensions = await evaluate(`({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth, status: document.querySelector("#status").textContent, hint: [...document.querySelectorAll(".section-footer")].some(e => /close|leave/i.test(e.textContent)) })`);
  if (dimensions.scrollWidth > dimensions.width) throw new Error(`${name}: horizontal overflow (${dimensions.scrollWidth} > ${dimensions.width})`);
  if (!paired && !/pair|ready/i.test(dimensions.status)) throw new Error(`${name}: unexpected unpaired status: ${dimensions.status}`);
  if (paired && !/enabled|paired/i.test(initialState.status)) throw new Error(`${name}: unexpected paired status: ${initialState.status}`);
  const capture = async (filename) => {
    await evaluate(`document.fonts.ready.then(() => new Promise(resolve => setTimeout(resolve, 250)))`);
    const { cssContentSize: size } = await call("Page.getLayoutMetrics");
    const shot = await call("Page.captureScreenshot", { format: "png", captureBeyondViewport: true, fromSurface: true, clip: { x: 0, y: 0, width: size.width, height: size.height, scale: 1 } });
    await writeFile(join(OUTPUT, `${filename}.png`), Buffer.from(shot.data, "base64"));
  };
  await capture(name);
  if (paired) {
    if (initialState.baseURL !== expectedURL || initialState.advancedOpen) throw new Error(`${name}: initial destination simplification failed`);
    await evaluate(`(() => { document.getElementById("advanced-details").open = true; const set = (id, value) => { const e = document.getElementById(id); e.value = value; e.dispatchEvent(new Event("input", { bubbles: true })); }; set("base-url", "http://smoke.local:4096"); set("username", "opencode"); document.getElementById("real-events").click(); document.getElementById("save-destination").click(); return true; })()`);
    await deadline(evaluate(`new Promise(resolve => { const check = () => /destination saved/i.test(document.querySelector("#status").textContent) ? resolve(true) : setTimeout(check, 50); check(); })`));
    await evaluate(`document.getElementById("schedule").click()`);
    await deadline(evaluate(`new Promise(resolve => { const check = () => /scheduled for/i.test(document.querySelector("#status").textContent) ? resolve(true) : setTimeout(check, 50); check(); })`));
    const afterRefresh = await evaluate(`(async () => { document.getElementById("refresh").click(); await new Promise(r => setTimeout(r, 100)); return ({ status: document.querySelector("#status").textContent, hint: [...document.querySelectorAll(".section-footer")].some(e => /close|leave/i.test(e.textContent)) }); })()`);
    if (!afterRefresh.hint || !/enabled|paired/i.test(afterRefresh.status)) throw new Error(`${name}: refresh verification failed`);
    const priorOptIn = await evaluate(`document.getElementById("real-events").checked`);
    await evaluate(`document.getElementById("paste-setup").click()`);
    await deadline(evaluate(`new Promise(resolve => { const check = () => /Setup complete/i.test(document.querySelector("#status").textContent) ? resolve(true) : setTimeout(check, 50); check(); })`));
    const imported = await evaluate(`({ baseURL: document.getElementById("base-url").value, username: document.getElementById("username").value, optIn: document.getElementById("real-events").checked, dirty: !document.getElementById("save-destination").disabled })`);
    if (imported.baseURL !== "http://native-saved.local:4096/" || imported.username !== "" || imported.optIn !== priorOptIn || imported.dirty) throw new Error(`${name}: native connection import changed consent, identity, or save state`);
  } else if (!dimensions.hint) throw new Error(`${name}: missing leave/close hint`);
  await call("Page.navigate", { url: new URL("/events.html", TARGET_URL).href });
  await deadline(evaluate(`new Promise(resolve => { const check = () => { const ready = document.readyState === "complete" && document.querySelector("#events-refresh"); const state = ${paired ? 'document.querySelectorAll("#event-list > li").length === 3' : '!document.querySelector("#events-unpaired").hidden'}; if (ready && state) resolve(true); else setTimeout(check, 50); }; check(); })`));
  const eventsState = await evaluate(`({ overflow: document.documentElement.scrollWidth > innerWidth, cards: document.querySelectorAll("#event-list > li").length, unpaired: !document.querySelector("#events-unpaired").hidden, proof: document.body.textContent.includes("Accepted by push service") })`);
  if (eventsState.overflow || (paired && (eventsState.cards !== 3 || !eventsState.proof)) || (!paired && !eventsState.unpaired)) throw new Error(`${name}: events screen verification failed`);
  if (paired) {
    const retained = await evaluate(`(async () => { document.querySelector("#event-list details").open = true; document.getElementById("events-refresh").click(); await new Promise(resolve => setTimeout(resolve, 150)); return document.querySelector("#event-list details").open; })()`);
    if (!retained) throw new Error(`${name}: refresh collapsed trace details`);
  }
  await capture(`${name}-events`);
  if (paired && mobile) {
    await call("Page.navigate", { url: new URL("/handoff.html", TARGET_URL).href });
    await deadline(evaluate(`new Promise(resolve => { const check = () => document.readyState === "complete" && document.querySelector("#open") ? resolve(true) : setTimeout(check, 50); check(); })`));
    const handoff = await evaluate(`({ href: document.querySelector("#open").getAttribute("href"), settings: Boolean(document.querySelector('a[href="/"]')), overflow: document.documentElement.scrollWidth > innerWidth })`);
    if (handoff.href !== "openclient://" || !handoff.settings || handoff.overflow) throw new Error(`${name}: handoff verification failed`);
    await capture(`mobile-${scheme}-handoff`);
  }
  if (errors.length) throw new Error(`${name}: ${errors.join("; ")}`);
  await cdp.send("Target.closeTarget", { targetId: target.targetId });
  return name;
}

await mkdir(OUTPUT, { recursive: true });
let browser;
try {
  browser = await launch();
  for (const item of cases) console.log(`Checking ${item[0]}...`, await runCase(browser, item));
  console.log(`Screenshots written to ${OUTPUT}`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  browser?.cdp.close();
  await stop(browser?.chrome, browser?.profile);
}
