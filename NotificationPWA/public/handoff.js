const copy = {
  en: ["OC Notify", "Notification received", "Continue to the matching session in OpenClient.", "Open in OpenClient", "iOS may require this tap even when auto-open is enabled.", "Notification Settings"],
  "pt-BR": ["OC Notify", "Notificação recebida", "Continue para a sessão correspondente no OpenClient.", "Abrir no OpenClient", "O iOS pode exigir este toque mesmo com a abertura automática ativada.", "Ajustes de Notificação"],
  it: ["OC Notify", "Notifica ricevuta", "Continua nella sessione corrispondente in OpenClient.", "Apri in OpenClient", "iOS potrebbe richiedere questo tocco anche con l’apertura automatica abilitata.", "Impostazioni Notifiche"]
};
const language = navigator.language.toLowerCase().startsWith("pt") ? "pt-BR" : navigator.language.toLowerCase().startsWith("it") ? "it" : "en";
document.documentElement.lang = language;
const [context, title, body, button, fallback, settings] = copy[language];
document.title = context;
Object.entries({ context, title, body, fallback, settings }).forEach(([id, value]) => { document.getElementById(id).textContent = value; });
const open = document.getElementById("open");
open.textContent = button;
let autoOpenTimer;
function applyTarget(target = NotificationHandoff.fromFragment(location.hash)) {
  const destination = NotificationHandoff.openClientURL(target);
  open.href = destination;
  if (autoOpenTimer !== undefined) clearTimeout(autoOpenTimer);
  autoOpenTimer = undefined;
  if (localStorage.getItem("notification-pwa-auto-open") === "true") {
    autoOpenTimer = setTimeout(() => { location.href = destination; }, 500);
  }
}
addEventListener("hashchange", () => applyTarget());
addEventListener("pageshow", () => applyTarget());
navigator.serviceWorker?.addEventListener("message", (event) => {
  const target = NotificationHandoff.validate(event.data?.target);
  if (target) applyTarget(target);
});
applyTarget();
