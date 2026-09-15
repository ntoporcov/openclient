importScripts("/handoff-core.js");
const CACHE = "notification-pwa-shell-v9";
const SHELL = ["/", "/index.html", "/styles.css", "/app.js", "/events.html", "/events.js", "/handoff.html", "/handoff.js", "/handoff-core.js", "/manifest.webmanifest", "/icons/icon-180.png", "/icons/icon-192.png", "/icons/icon-512.png"];

self.addEventListener("install", (event) => event.waitUntil(caches.open(CACHE).then((cache) => Promise.all(SHELL.map(async (path) => {
  const response = await fetch(new Request(path, { cache: "no-cache" }));
  if (!response.ok) throw new Error(`Unable to cache ${path}`);
  await cache.put(path, response);
})))));
self.addEventListener("activate", (event) => event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))));
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/api/") || url.pathname === "/health") return;
  event.respondWith((async () => {
    try {
      const response = await fetch(event.request, { cache: "no-cache" });
      if (response.ok && !url.search && SHELL.includes(url.pathname)) {
        try {
          const cache = await caches.open(CACHE);
          await cache.put(url.pathname, response.clone());
        } catch { /* A cache write failure must not replace a successful network response. */ }
      }
      return response;
    } catch {
      if (!url.search) {
        const exact = await caches.match(url.pathname);
        if (exact) return exact;
      }
      if (event.request.mode === "navigate") return caches.match(url.pathname === "/handoff.html" ? "/handoff.html" : url.pathname === "/events.html" ? "/events.html" : "/index.html");
      return caches.match(url.pathname);
    }
  })());
});
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data?.json() || {}; } catch { data = {}; }
  const language = self.navigator.language.toLowerCase();
  const localized = {
    en: { idle: "Session is idle", permission: "OpenCode needs permission", question: "OpenCode has a question", test: ["OpenClient handoff ready", "Tap to open the safe handoff page."], project: "Project", session: "Session", global: "Global" },
    pt: { idle: "A sessão do OpenCode está ociosa", permission: "O OpenCode precisa de permissão", question: "O OpenCode tem uma pergunta", test: ["Passagem para o OpenClient pronta", "Toque para abrir a página de passagem segura."], project: "Projeto", session: "Sessão", global: "Global" },
    it: { idle: "La sessione OpenCode è inattiva", permission: "OpenCode richiede un’autorizzazione", question: "OpenCode ha una domanda", test: ["Passaggio a OpenClient pronto", "Tocca per aprire la pagina di passaggio sicuro."], project: "Progetto", session: "Sessione", global: "Globale" }
  };
  const table = language.startsWith("pt") ? localized.pt : language.startsWith("it") ? localized.it : localized.en;
  const target = NotificationHandoff.validate(data.data);
  const clean = (value, limit) => {
    if (typeof value !== "string") return "";
    const normalized = value.replace(/[\u0000-\u001f\u007f-\u009f]/gu, " ").replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/gu, "").replace(/\s+/gu, " ").trim();
    return Array.from(normalized).slice(0, limit).join("");
  };
  const shortID = (value) => clean(value, 16);
  const context = data.context && typeof data.context === "object" && !Array.isArray(data.context) ? data.context : {};
  const directoryName = target?.directory && target.directory !== "/" ? clean(target.directory.split("/").filter(Boolean).pop(), 80) : "";
  const projectName = clean(context.projectName, 80) || directoryName || (target?.projectID === "global" ? table.global : target?.projectID ? `${table.project} ${shortID(target.projectID)}` : table.project);
  const sessionTitle = clean(context.sessionTitle, 120) || (target?.sessionID ? `${table.session} ${shortID(target.sessionID)}` : table.session);
  const isReal = ["idle", "permission", "question"].includes(data.kind);
  const title = isReal ? table[data.kind] : table.test[0];
  const body = isReal ? `${projectName} · ${sessionTitle}` : table.test[1];
  event.waitUntil(self.registration.showNotification(title, {
    body,
    icon: "/icons/icon-192.png?v=5",
    badge: "/icons/icon-192.png?v=5",
    tag: typeof data.jobID === "string" ? data.jobID : `${data.kind || "test"}:${target?.sessionID || "openclient"}`,
    data: target ? { target } : {}
  }));
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = NotificationHandoff.validate(event.notification.data?.target);
  const handoff = `/handoff.html${target ? NotificationHandoff.fragment(target) : ""}`;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (clients) => {
    const existing = clients.find((client) => new URL(client.url).pathname === "/handoff.html");
    if (existing) {
      const navigated = await existing.navigate(handoff);
      (navigated || existing).postMessage(target ? { target } : {});
      return (navigated || existing).focus();
    }
    return self.clients.openWindow(handoff);
  }));
});
