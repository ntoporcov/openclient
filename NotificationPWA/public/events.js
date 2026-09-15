const text = {
  en: {
    context: "OC Notify", title: "Events", back: "Notification Settings", backAccessibility: "Back to Notification Settings", refresh: "Refresh events", sourceTitle: "This project’s plugin", noBridge: "No bridge activity recorded", lastSeen: "Bridge seen {time}", lastEvent: "Last event {kind} · {time}",
    unpairedTitle: "Pair this device first", unpairedBody: "Events are private to each paired device.", openSettings: "Open Notification Settings", emptyTitle: "No events received", emptyBody: "No notification events have been recorded for this device since companion history began.",
    coverage: "Only events received by this companion appear here. Events ignored before forwarding, including skipped subagent completions, may not appear.", proof: "“Accepted by push service” confirms only that the push service accepted the request. It does not prove that iOS displayed it.", persistenceWarning: "History could not be saved and may not survive a companion restart.", loadError: "Events could not be refreshed. Existing results are still shown.",
    notUpdated: "Not refreshed yet", updatedNow: "Updated just now", updatedSeconds: "Updated {count} seconds ago", updatedMinute: "Updated 1 minute ago", updatedMinutes: "Updated {count} minutes ago", eventCountOne: "1 event", eventCountMany: "{count} events", trace: "Trace details", received: "Received", scheduled: "Scheduled", finished: "Finished", sessionID: "Session ID", projectID: "Project ID", eventID: "Event ID", pushStatus: "Push HTTP status", projectFallback: "Project {id}", sessionFallback: "Session {id}", global: "Global", unknownProject: "Unknown project", unknownSession: "Unknown session",
    kindTest: "Test notification", kindIdle: "Session idle", kindPermission: "Permission request", kindQuestion: "Question", kindUnknown: "Notification event",
    outcomeScheduled: "Scheduled", outcomeSending: "Sending", outcomeAccepted: "Accepted by push service", outcomeCancelled: "Cancelled", outcomeExpired: "Subscription expired", outcomeFailed: "Failed", outcomeSkipped: "Skipped", outcomeInterrupted: "Interrupted by restart", outcomeUnknown: "Unknown outcome",
    reasonOptOut: "Real-event notifications were disabled for this device.", reasonSubscriptionMissing: "This device had no push subscription.", reasonQueueFull: "The companion’s pending notification limit was reached.", reasonNewerActivity: "A newer activity cycle cancelled this idle alert.", reasonSessionError: "The session ended with an error.", reasonRequestResolved: "The request was resolved before the alert was sent.", reasonSessionDeleted: "The session was deleted.", reasonSubscriptionExpired: "The push service reported an expired subscription.", reasonPushRejected: "The push service rejected the request.", reasonPushUnavailable: "The push service or network was unavailable.", reasonRestarted: "The companion restarted before its in-memory timer finished.", reasonPayload: "The safe push payload limit was exceeded.", reasonDeviceReset: "The device was reset."
  },
  "pt-BR": {
    context: "OC Notify", title: "Eventos", back: "Ajustes de Notificação", backAccessibility: "Voltar aos Ajustes de Notificação", refresh: "Atualizar eventos", sourceTitle: "Plugin deste projeto", noBridge: "Nenhuma atividade da ponte registrada", lastSeen: "Ponte vista às {time}", lastEvent: "Último evento: {kind} · {time}",
    unpairedTitle: "Emparelhe este dispositivo primeiro", unpairedBody: "Os eventos são privados para cada dispositivo emparelhado.", openSettings: "Abrir Ajustes de Notificação", emptyTitle: "Nenhum evento recebido", emptyBody: "Nenhum evento de notificação foi registrado para este dispositivo desde o início do histórico do companion.",
    coverage: "Somente eventos recebidos por este companion aparecem aqui. Eventos ignorados antes do encaminhamento, incluindo conclusões de subagentes ignoradas, podem não aparecer.", proof: "“Aceito pelo serviço push” confirma apenas que o serviço push aceitou a solicitação. Isso não comprova que o iOS a exibiu.", persistenceWarning: "Não foi possível salvar o histórico; ele pode não sobreviver à reinicialização do companion.", loadError: "Não foi possível atualizar os eventos. Os resultados existentes continuam visíveis.",
    notUpdated: "Ainda não atualizado", updatedNow: "Atualizado agora", updatedSeconds: "Atualizado há {count} segundos", updatedMinute: "Atualizado há 1 minuto", updatedMinutes: "Atualizado há {count} minutos", eventCountOne: "1 evento", eventCountMany: "{count} eventos", trace: "Detalhes de rastreamento", received: "Recebido", scheduled: "Agendado", finished: "Concluído", sessionID: "ID da sessão", projectID: "ID do projeto", eventID: "ID do evento", pushStatus: "Status HTTP do push", projectFallback: "Projeto {id}", sessionFallback: "Sessão {id}", global: "Global", unknownProject: "Projeto desconhecido", unknownSession: "Sessão desconhecida",
    kindTest: "Notificação de teste", kindIdle: "Sessão ociosa", kindPermission: "Pedido de permissão", kindQuestion: "Pergunta", kindUnknown: "Evento de notificação",
    outcomeScheduled: "Agendado", outcomeSending: "Enviando", outcomeAccepted: "Aceito pelo serviço push", outcomeCancelled: "Cancelado", outcomeExpired: "Inscrição expirada", outcomeFailed: "Falhou", outcomeSkipped: "Ignorado", outcomeInterrupted: "Interrompido pela reinicialização", outcomeUnknown: "Resultado desconhecido",
    reasonOptOut: "As notificações de eventos reais estavam desativadas neste dispositivo.", reasonSubscriptionMissing: "Este dispositivo não tinha uma inscrição push.", reasonQueueFull: "O limite de notificações pendentes do companion foi atingido.", reasonNewerActivity: "Um ciclo de atividade mais recente cancelou este alerta de ociosidade.", reasonSessionError: "A sessão terminou com um erro.", reasonRequestResolved: "A solicitação foi resolvida antes do envio do alerta.", reasonSessionDeleted: "A sessão foi excluída.", reasonSubscriptionExpired: "O serviço push informou que a inscrição expirou.", reasonPushRejected: "O serviço push rejeitou a solicitação.", reasonPushUnavailable: "O serviço push ou a rede estava indisponível.", reasonRestarted: "O companion reiniciou antes de o temporizador em memória terminar.", reasonPayload: "O limite seguro do payload push foi excedido.", reasonDeviceReset: "O dispositivo foi redefinido."
  },
  it: {
    context: "OC Notify", title: "Eventi", back: "Impostazioni Notifiche", backAccessibility: "Torna alle Impostazioni Notifiche", refresh: "Aggiorna eventi", sourceTitle: "Plugin di questo progetto", noBridge: "Nessuna attività del bridge registrata", lastSeen: "Bridge rilevato alle {time}", lastEvent: "Ultimo evento: {kind} · {time}",
    unpairedTitle: "Prima abbina questo dispositivo", unpairedBody: "Gli eventi sono privati per ogni dispositivo abbinato.", openSettings: "Apri Impostazioni Notifiche", emptyTitle: "Nessun evento ricevuto", emptyBody: "Nessun evento di notifica è stato registrato per questo dispositivo dall’inizio della cronologia del companion.",
    coverage: "Qui compaiono solo gli eventi ricevuti da questo companion. Gli eventi ignorati prima dell’inoltro, incluse le conclusioni dei sottoagenti ignorate, potrebbero non comparire.", proof: "“Accettata dal servizio push” conferma solo che il servizio push ha accettato la richiesta. Non prova che iOS l’abbia mostrata.", persistenceWarning: "Impossibile salvare la cronologia; potrebbe non sopravvivere al riavvio del companion.", loadError: "Impossibile aggiornare gli eventi. I risultati esistenti restano visibili.",
    notUpdated: "Non ancora aggiornato", updatedNow: "Aggiornato ora", updatedSeconds: "Aggiornato {count} secondi fa", updatedMinute: "Aggiornato 1 minuto fa", updatedMinutes: "Aggiornato {count} minuti fa", eventCountOne: "1 evento", eventCountMany: "{count} eventi", trace: "Dettagli di tracciamento", received: "Ricevuto", scheduled: "Programmato", finished: "Terminato", sessionID: "ID sessione", projectID: "ID progetto", eventID: "ID evento", pushStatus: "Stato HTTP push", projectFallback: "Progetto {id}", sessionFallback: "Sessione {id}", global: "Globale", unknownProject: "Progetto sconosciuto", unknownSession: "Sessione sconosciuta",
    kindTest: "Notifica di prova", kindIdle: "Sessione inattiva", kindPermission: "Richiesta di autorizzazione", kindQuestion: "Domanda", kindUnknown: "Evento di notifica",
    outcomeScheduled: "Programmata", outcomeSending: "Invio in corso", outcomeAccepted: "Accettata dal servizio push", outcomeCancelled: "Annullata", outcomeExpired: "Iscrizione scaduta", outcomeFailed: "Non riuscita", outcomeSkipped: "Ignorata", outcomeInterrupted: "Interrotta dal riavvio", outcomeUnknown: "Esito sconosciuto",
    reasonOptOut: "Le notifiche degli eventi reali erano disattivate per questo dispositivo.", reasonSubscriptionMissing: "Questo dispositivo non aveva un’iscrizione push.", reasonQueueFull: "È stato raggiunto il limite di notifiche in sospeso del companion.", reasonNewerActivity: "Un ciclo di attività più recente ha annullato questo avviso di inattività.", reasonSessionError: "La sessione è terminata con un errore.", reasonRequestResolved: "La richiesta è stata risolta prima dell’invio dell’avviso.", reasonSessionDeleted: "La sessione è stata eliminata.", reasonSubscriptionExpired: "Il servizio push ha segnalato un’iscrizione scaduta.", reasonPushRejected: "Il servizio push ha rifiutato la richiesta.", reasonPushUnavailable: "Il servizio push o la rete non era disponibile.", reasonRestarted: "Il companion si è riavviato prima della fine del timer in memoria.", reasonPayload: "È stato superato il limite sicuro del payload push.", reasonDeviceReset: "Il dispositivo è stato reimpostato."
  }
};

const language = navigator.language.toLowerCase().startsWith("pt") ? "pt-BR" : navigator.language.toLowerCase().startsWith("it") ? "it" : "en";
const strings = text[language];
const $ = (id) => document.getElementById(id);
const token = localStorage.getItem("notification-pwa-device-token");
const clean = (value, limit = 256) => typeof value === "string" ? Array.from(value.replace(/[\u0000-\u001f\u007f-\u009f]/gu, " ").replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/gu, "").replace(/\s+/gu, " ").trim()).slice(0, limit).join("") : "";
const format = (template, values) => Object.entries(values).reduce((result, [key, value]) => result.replace(`{${key}}`, value), template);
const kindKeys = { test: "kindTest", idle: "kindIdle", permission: "kindPermission", question: "kindQuestion" };
const outcomeKeys = { scheduled: "outcomeScheduled", sending: "outcomeSending", accepted: "outcomeAccepted", cancelled: "outcomeCancelled", expired: "outcomeExpired", failed: "outcomeFailed", skipped: "outcomeSkipped", interrupted: "outcomeInterrupted" };
const reasonKeys = { "opt-out": "reasonOptOut", "subscription-missing": "reasonSubscriptionMissing", "queue-full": "reasonQueueFull", "newer-activity": "reasonNewerActivity", "session-error": "reasonSessionError", "request-resolved": "reasonRequestResolved", "session-deleted": "reasonSessionDeleted", "subscription-expired": "reasonSubscriptionExpired", "push-rejected": "reasonPushRejected", "push-unavailable": "reasonPushUnavailable", "companion-restarted": "reasonRestarted", "payload-too-large": "reasonPayload", "device-reset": "reasonDeviceReset" };
const dateTime = new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "medium" });
let controller;
let lastSuccess = 0;
let hasResults = false;
let requestGeneration = 0;

document.documentElement.lang = language;
document.title = `${strings.title} · ${strings.context}`;
document.querySelectorAll("[data-i18n]").forEach((element) => { element.textContent = strings[element.dataset.i18n]; });
document.querySelectorAll("[data-i18n-aria]").forEach((element) => { element.setAttribute("aria-label", strings[element.dataset.i18nAria]); });

function localizedKind(kind) { return strings[kindKeys[kind]] || strings.kindUnknown; }
function localizedOutcome(outcome) { return strings[outcomeKeys[outcome]] || strings.outcomeUnknown; }
function validDate(value) { const date = new Date(value); return Number.isFinite(date.valueOf()) ? date : null; }
function shortID(value) { return clean(value, 16); }
function displayProject(record) {
  return clean(record.projectName, 80) || clean(record.directoryName, 80) || (record.projectID === "global" ? strings.global : shortID(record.projectID) ? format(strings.projectFallback, { id: shortID(record.projectID) }) : strings.unknownProject);
}
function displaySession(record) { return clean(record.sessionTitle, 120) || (shortID(record.sessionID) ? format(strings.sessionFallback, { id: shortID(record.sessionID) }) : strings.unknownSession); }
function addDetail(list, label, value) {
  if (!value) return;
  const term = document.createElement("dt"); const detail = document.createElement("dd");
  term.textContent = label; detail.textContent = value; list.append(term, detail);
}
function eventCard(record, expanded) {
  const item = document.createElement("li"); const article = document.createElement("article"); const heading = document.createElement("div");
  const copy = document.createElement("div"); const title = document.createElement("strong"); const caption = document.createElement("span"); const badge = document.createElement("span");
  article.className = `event-card outcome-${clean(record.outcome, 24) || "unknown"}`; heading.className = "event-heading"; copy.className = "row-copy"; badge.className = "outcome-badge";
  title.textContent = localizedKind(record.kind); caption.textContent = `${displayProject(record)} · ${displaySession(record)}`; badge.textContent = localizedOutcome(record.outcome);
  copy.append(title, caption); heading.append(copy, badge); article.append(heading);
  const reasonKey = reasonKeys[record.reason];
  if (reasonKey) { const reason = document.createElement("p"); reason.className = "event-reason"; reason.textContent = strings[reasonKey]; article.append(reason); }
  const details = document.createElement("details"); const summary = document.createElement("summary"); const list = document.createElement("dl");
  details.dataset.eventID = record.id;
  details.open = expanded.has(record.id);
  summary.textContent = strings.trace;
  addDetail(list, strings.received, validDate(record.receivedAt) ? dateTime.format(validDate(record.receivedAt)) : "");
  addDetail(list, strings.scheduled, validDate(record.scheduledAt) ? dateTime.format(validDate(record.scheduledAt)) : "");
  addDetail(list, strings.finished, validDate(record.finishedAt) ? dateTime.format(validDate(record.finishedAt)) : "");
  addDetail(list, strings.sessionID, clean(record.sessionID)); addDetail(list, strings.projectID, clean(record.projectID)); addDetail(list, strings.eventID, clean(record.eventID, 768));
  addDetail(list, strings.pushStatus, Number.isInteger(record.pushStatus) ? String(record.pushStatus) : "");
  details.append(summary, list); article.append(details); item.append(article); return item;
}
function renderSource(source) {
  const seen = validDate(source?.lastSeenAt); const received = validDate(source?.lastReceivedAt);
  $("source-dot").classList.toggle("seen", Boolean(seen));
  $("source-summary").textContent = received ? format(strings.lastEvent, { kind: localizedKind(source.lastKind), time: dateTime.format(received) }) : seen ? format(strings.lastSeen, { time: dateTime.format(seen) }) : strings.noBridge;
}
function render(data) {
  const events = Array.isArray(data.events) ? data.events.slice(0, 200) : [];
  const expanded = new Set([...$("event-list").querySelectorAll("details[open]")].map((details) => details.dataset.eventID));
  $("event-list").replaceChildren(...events.map((record) => eventCard(record, expanded)));
  $("events-content").hidden = events.length === 0; $("events-empty").hidden = events.length !== 0; $("events-unpaired").hidden = true;
  $("events-count").textContent = events.length === 1 ? strings.eventCountOne : format(strings.eventCountMany, { count: String(events.length) });
  $("persistence-warning").hidden = data.persistence !== "failed"; renderSource(data.source); hasResults = true;
}
function updateAge() {
  if (!lastSuccess) return $("last-updated").textContent = strings.notUpdated;
  const seconds = Math.max(0, Math.floor((Date.now() - lastSuccess) / 1000));
  $("last-updated").textContent = seconds < 5 ? strings.updatedNow : seconds < 60 ? format(strings.updatedSeconds, { count: String(seconds) }) : seconds < 120 ? strings.updatedMinute : format(strings.updatedMinutes, { count: String(Math.floor(seconds / 60)) });
}
async function refresh() {
  if (!token) { $("events-unpaired").hidden = false; $("events-empty").hidden = true; $("events-content").hidden = true; return; }
  const generation = ++requestGeneration;
  controller?.abort(); controller = new AbortController();
  try {
    const response = await fetch("/api/events", { headers: { Authorization: `Bearer ${token}` }, signal: controller.signal });
    if (response.status === 401) { $("events-unpaired").hidden = false; $("events-empty").hidden = true; $("events-content").hidden = true; return; }
    if (!response.ok) throw new Error("events-fetch-failed");
    const data = await response.json();
    if (generation !== requestGeneration) return;
    render(data); lastSuccess = Date.now(); $("events-error").hidden = true; updateAge();
  } catch (error) {
    if (error.name === "AbortError") return;
    $("events-error").textContent = strings.loadError; $("events-error").hidden = false;
    if (!hasResults) { $("events-empty").hidden = false; $("events-content").hidden = true; }
  }
}

$("events-refresh").addEventListener("click", refresh);
document.addEventListener("visibilitychange", () => { if (document.hidden) controller?.abort(); else refresh(); });
setInterval(() => { if (!document.hidden) refresh(); }, 3000);
setInterval(updateAge, 1000);
refresh();
