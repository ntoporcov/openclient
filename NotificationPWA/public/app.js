const text = {
  en: {
    context: "OpenCode", title: "OC Notify", refresh: "Refresh status", thisDevice: "This device", notPaired: "Not paired", checking: "Paired · Checking notifications", pairedDevice: "Paired · Notifications not enabled", enabledDevice: "Paired · Notifications enabled", deniedDevice: "Paired · Notifications blocked",
    installTitle: "Add to Home Screen", installBody: "In Safari, tap Share, then Add to Home Screen. Open the installed app to enable notifications.", setupTitle: "Connection Setup Code", setupLabel: "Connection setup code", useConnection: "Use Connection", setupHint: "Install or reopen this Home Screen app, enter this code, pair the device with a separate Mac pairing code if needed, then tap Use Connection. Review the draft and tap Save Changes.", setupImported: "Connection draft imported. Review it, then tap Save Changes. Your notification preference is unchanged.", setupPairFirst: "Pair this device with a separate pairing code first. This connection code will remain here.",
    pairTitle: "Pair this device", pairNeeded: "Required", repair: "Re-pair or reset", pairLabel: "Pairing code", pairButton: "Pair Device", pairHint: "Generate a fresh 10-minute code with npm run pair on the Mac.",
    permissionHeading: "Device Permissions", notifyButton: "Enable Notifications", permissionNotEnabled: "Not enabled", permissionEnabled: "Enabled", permissionDenied: "Blocked in Settings", permissionUnavailable: "Unavailable in this browser", notifyHint: "iOS shows its permission prompt only after you tap this row.",
    destinationTitle: "OpenClient Destination", connectionLabel: "Connection", suggested: "Suggested", advanced: "Advanced", manualSetup: "Manual setup required", destinationHelp: "Suggested from this app. Must match the server saved in OpenClient; edit in Advanced if needed.", baseURLLabel: "Server URL", usernameLabel: "Username", profileLabel: "Server Profile", profileLegacy: "Legacy", profileV2: "V2",
    deliveryHeading: "Delivery", realEventsLabel: "OpenCode Activity", realEventsSublabel: "Notify for idle sessions and requests", autoLabel: "Try Auto-Open", autoSublabel: "Continue from handoff automatically", delayLabel: "Notification Delay", seconds: "sec", deliveryHelp: "OpenCode Activity starts only after you save. Auto-open is experimental and iOS may still require a tap.", saveDestination: "Save Changes", saved: "Saved", unsaved: "Unsaved changes",
    testTitle: "Test Notification", testButton: "Schedule Test Notification", leaveHint: "Uses the delay above. After scheduling, close or leave this app; the server timer continues.",
    activityTitle: "Recent Activity", noActivity: "No recent notification activity.", viewAllEvents: "View All Events", activityCountOne: "1 item", activityCountMany: "{count} items", reset: "Unsubscribe and Reset Device", resetConfirm: "Unsubscribe from notifications and remove this device’s pairing?",
    ready: "Ready to pair.", paired: "Paired. Enable notifications when you are ready.", enabled: "Notifications are enabled on this device.", destinationSaved: "Destination saved. OpenCode Activity is {state}.", destinationSavedWithChanges: "Submitted destination saved. Newer changes remain unsaved.", on: "on", off: "off", scheduled: "Scheduled for {time}. You can close or leave this app now.", resetDone: "This device was reset.",
    homeRequired: "Add this app to the Home Screen and open it there before enabling notifications.", unsupported: "This browser does not support installed-app notifications.", denied: "Notification permission is blocked. You can change it in Settings.", secure: "A secure HTTPS connection is required.", unknown: "Something went wrong. Try again.",
    bridgeActivity: "OpenCode activity", bridgeDetail: "Last event: {kind} · {status}", kindTest: "Test notification", kindIdle: "Session idle", kindPermission: "Permission request", kindQuestion: "Question", kindError: "Session error", kindActivity: "Session activity", kindResolved: "Request resolved", kindDeleted: "Session deleted", stateScheduled: "Scheduled", stateSending: "Sending", statePartiallyScheduled: "Partially scheduled", stateNoOptedInDevice: "No opted-in device", stateDelivered: "Accepted by push service", stateCancelled: "Cancelled", stateExpired: "Subscription expired", stateFailed: "Failed", stateAccepted: "Accepted", stateIgnored: "Ignored", stateDuplicate: "Duplicate", stateUnavailable: "Status unavailable"
  },
  "pt-BR": {
    context: "OpenCode", title: "OC Notify", refresh: "Atualizar status", thisDevice: "Este dispositivo", notPaired: "Não emparelhado", checking: "Emparelhado · Verificando notificações", pairedDevice: "Emparelhado · Notificações desativadas", enabledDevice: "Emparelhado · Notificações ativadas", deniedDevice: "Emparelhado · Notificações bloqueadas",
    installTitle: "Adicionar à Tela de Início", installBody: "No Safari, toque em Compartilhar e Adicionar à Tela de Início. Abra o app instalado para ativar as notificações.", setupTitle: "Código de Configuração da Conexão", setupLabel: "Código de configuração da conexão", useConnection: "Usar Conexão", setupHint: "Instale ou reabra este app da Tela de Início, digite este código, emparelhe o dispositivo com um código separado do Mac se necessário e toque em Usar Conexão. Revise o rascunho e toque em Salvar Alterações.", setupImported: "Rascunho da conexão importado. Revise-o e toque em Salvar Alterações. Sua preferência de notificação permanece inalterada.", setupPairFirst: "Primeiro emparelhe este dispositivo com um código de emparelhamento separado. Este código de conexão permanecerá aqui.",
    pairTitle: "Emparelhar este dispositivo", pairNeeded: "Obrigatório", repair: "Emparelhar novamente ou redefinir", pairLabel: "Código de emparelhamento", pairButton: "Emparelhar Dispositivo", pairHint: "Gere no Mac um código novo válido por 10 minutos com npm run pair.",
    permissionHeading: "Permissões do Dispositivo", notifyButton: "Ativar Notificações", permissionNotEnabled: "Desativadas", permissionEnabled: "Ativadas", permissionDenied: "Bloqueadas nos Ajustes", permissionUnavailable: "Indisponíveis neste navegador", notifyHint: "O iOS mostra o pedido de permissão somente depois que você toca nesta linha.",
    destinationTitle: "Destino no OpenClient", connectionLabel: "Conexão", suggested: "Sugerida", advanced: "Avançado", manualSetup: "Configuração manual necessária", destinationHelp: "Sugerida por este app. Deve corresponder ao servidor salvo no OpenClient; edite em Avançado se necessário.", baseURLLabel: "URL do Servidor", usernameLabel: "Nome de Usuário", profileLabel: "Perfil do Servidor", profileLegacy: "Legado", profileV2: "V2",
    deliveryHeading: "Entrega", realEventsLabel: "Atividade do OpenCode", realEventsSublabel: "Notificar sobre sessões ociosas e solicitações", autoLabel: "Tentar Abertura Automática", autoSublabel: "Continuar automaticamente após a passagem", delayLabel: "Atraso da Notificação", seconds: "s", deliveryHelp: "A Atividade do OpenCode começa somente após salvar. A abertura automática é experimental e o iOS ainda pode exigir um toque.", saveDestination: "Salvar Alterações", saved: "Salvo", unsaved: "Alterações não salvas",
    testTitle: "Notificação de Teste", testButton: "Agendar Notificação de Teste", leaveHint: "Usa o atraso acima. Depois de agendar, feche ou saia deste app; o temporizador do servidor continua.",
    activityTitle: "Atividade Recente", noActivity: "Nenhuma atividade de notificação recente.", viewAllEvents: "Ver Todos os Eventos", activityCountOne: "1 item", activityCountMany: "{count} itens", reset: "Cancelar Inscrição e Redefinir", resetConfirm: "Cancelar as notificações e remover o emparelhamento deste dispositivo?",
    ready: "Pronto para emparelhar.", paired: "Emparelhado. Ative as notificações quando quiser.", enabled: "As notificações estão ativadas neste dispositivo.", destinationSaved: "Destino salvo. A Atividade do OpenCode está {state}.", destinationSavedWithChanges: "Destino enviado salvo. As alterações mais recentes continuam não salvas.", on: "ativada", off: "desativada", scheduled: "Agendada para {time}. Agora você pode fechar ou sair deste app.", resetDone: "Este dispositivo foi redefinido.",
    homeRequired: "Adicione este app à Tela de Início e abra-o por lá antes de ativar as notificações.", unsupported: "Este navegador não oferece notificações para apps instalados.", denied: "As notificações estão bloqueadas. Você pode alterá-las nos Ajustes.", secure: "É necessária uma conexão HTTPS segura.", unknown: "Algo deu errado. Tente novamente.",
    bridgeActivity: "Atividade do OpenCode", bridgeDetail: "Último evento: {kind} · {status}", kindTest: "Notificação de teste", kindIdle: "Sessão ociosa", kindPermission: "Pedido de permissão", kindQuestion: "Pergunta", kindError: "Erro da sessão", kindActivity: "Atividade da sessão", kindResolved: "Solicitação resolvida", kindDeleted: "Sessão excluída", stateScheduled: "Agendada", stateSending: "Enviando", statePartiallyScheduled: "Parcialmente agendada", stateNoOptedInDevice: "Nenhum dispositivo participante", stateDelivered: "Aceita pelo serviço push", stateCancelled: "Cancelada", stateExpired: "Inscrição expirada", stateFailed: "Falhou", stateAccepted: "Aceito", stateIgnored: "Ignorado", stateDuplicate: "Duplicado", stateUnavailable: "Status indisponível"
  },
  it: {
    context: "OpenCode", title: "OC Notify", refresh: "Aggiorna stato", thisDevice: "Questo dispositivo", notPaired: "Non abbinato", checking: "Abbinato · Verifica notifiche", pairedDevice: "Abbinato · Notifiche non abilitate", enabledDevice: "Abbinato · Notifiche abilitate", deniedDevice: "Abbinato · Notifiche bloccate",
    installTitle: "Aggiungi alla schermata Home", installBody: "In Safari, tocca Condividi e Aggiungi alla schermata Home. Apri l’app installata per abilitare le notifiche.", setupTitle: "Codice di Configurazione Connessione", setupLabel: "Codice di configurazione connessione", useConnection: "Usa Connessione", setupHint: "Installa o riapri questa app dalla schermata Home, inserisci il codice, abbina il dispositivo con un codice Mac separato se necessario, quindi tocca Usa Connessione. Controlla la bozza e tocca Salva Modifiche.", setupImported: "Bozza della connessione importata. Controllala, quindi tocca Salva Modifiche. La preferenza per le notifiche rimane invariata.", setupPairFirst: "Prima abbina questo dispositivo con un codice di abbinamento separato. Questo codice di connessione rimarrà qui.",
    pairTitle: "Abbina questo dispositivo", pairNeeded: "Obbligatorio", repair: "Abbina di nuovo o reimposta", pairLabel: "Codice di abbinamento", pairButton: "Abbina Dispositivo", pairHint: "Genera sul Mac un nuovo codice valido 10 minuti con npm run pair.",
    permissionHeading: "Permessi del Dispositivo", notifyButton: "Abilita Notifiche", permissionNotEnabled: "Non abilitate", permissionEnabled: "Abilitate", permissionDenied: "Bloccate nelle Impostazioni", permissionUnavailable: "Non disponibili in questo browser", notifyHint: "iOS mostra la richiesta di autorizzazione solo dopo aver toccato questa riga.",
    destinationTitle: "Destinazione OpenClient", connectionLabel: "Connessione", suggested: "Suggerita", advanced: "Avanzate", manualSetup: "Configurazione manuale richiesta", destinationHelp: "Suggerita da questa app. Deve corrispondere al server salvato in OpenClient; modificala in Avanzate se necessario.", baseURLLabel: "URL Server", usernameLabel: "Nome Utente", profileLabel: "Profilo Server", profileLegacy: "Legacy", profileV2: "V2",
    deliveryHeading: "Consegna", realEventsLabel: "Attività OpenCode", realEventsSublabel: "Notifica sessioni inattive e richieste", autoLabel: "Prova Apertura Automatica", autoSublabel: "Continua automaticamente dal passaggio", delayLabel: "Ritardo Notifica", seconds: "sec", deliveryHelp: "Attività OpenCode inizia solo dopo il salvataggio. L’apertura automatica è sperimentale e iOS potrebbe richiedere un tocco.", saveDestination: "Salva Modifiche", saved: "Salvato", unsaved: "Modifiche non salvate",
    testTitle: "Notifica di Prova", testButton: "Programma Notifica di Prova", leaveHint: "Usa il ritardo indicato sopra. Dopo la programmazione, chiudi o lascia l’app; il timer del server continua.",
    activityTitle: "Attività Recente", noActivity: "Nessuna attività di notifica recente.", viewAllEvents: "Vedi Tutti gli Eventi", activityCountOne: "1 elemento", activityCountMany: "{count} elementi", reset: "Annulla Iscrizione e Reimposta", resetConfirm: "Annullare le notifiche e rimuovere l’abbinamento di questo dispositivo?",
    ready: "Pronto per l’abbinamento.", paired: "Abbinato. Abilita le notifiche quando vuoi.", enabled: "Le notifiche sono abilitate su questo dispositivo.", destinationSaved: "Destinazione salvata. Attività OpenCode è {state}.", destinationSavedWithChanges: "Destinazione inviata salvata. Le modifiche più recenti non sono ancora salvate.", on: "attiva", off: "disattiva", scheduled: "Programmata per le {time}. Ora puoi chiudere o lasciare l’app.", resetDone: "Il dispositivo è stato reimpostato.",
    homeRequired: "Aggiungi l’app alla schermata Home e aprila da lì prima di abilitare le notifiche.", unsupported: "Questo browser non supporta le notifiche per app installate.", denied: "Le notifiche sono bloccate. Puoi modificarle nelle Impostazioni.", secure: "È necessaria una connessione HTTPS sicura.", unknown: "Si è verificato un problema. Riprova.",
    bridgeActivity: "Attività OpenCode", bridgeDetail: "Ultimo evento: {kind} · {status}", kindTest: "Notifica di prova", kindIdle: "Sessione inattiva", kindPermission: "Richiesta di autorizzazione", kindQuestion: "Domanda", kindError: "Errore sessione", kindActivity: "Attività sessione", kindResolved: "Richiesta risolta", kindDeleted: "Sessione eliminata", stateScheduled: "Programmata", stateSending: "Invio in corso", statePartiallyScheduled: "Programmata in parte", stateNoOptedInDevice: "Nessun dispositivo aderente", stateDelivered: "Accettata dal servizio push", stateCancelled: "Annullata", stateExpired: "Iscrizione scaduta", stateFailed: "Non riuscita", stateAccepted: "Accettato", stateIgnored: "Ignorato", stateDuplicate: "Duplicato", stateUnavailable: "Stato non disponibile"
  }
};

const language = navigator.language.toLowerCase().startsWith("pt") ? "pt-BR" : navigator.language.toLowerCase().startsWith("it") ? "it" : "en";
const strings = text[language];
document.documentElement.lang = language;
document.title = strings.title;
document.querySelectorAll("[data-i18n]").forEach((element) => { element.textContent = strings[element.dataset.i18n]; });
document.querySelectorAll("[data-i18n-aria]").forEach((element) => { element.setAttribute("aria-label", strings[element.dataset.i18nAria]); });

const $ = (id) => document.getElementById(id);
function suggestedBaseURL(hostname, sourceEndpoint) {
  if (!sourceEndpoint || !["http", "https"].includes(sourceEndpoint.protocol) || !Number.isInteger(sourceEndpoint.port) || sourceEndpoint.port < 1 || sourceEndpoint.port > 65535) return "";
  if (typeof hostname !== "string" || !hostname || /[\u0000-\u0020/?#@]/.test(hostname)) return "";
  const host = hostname.includes(":") ? `[${hostname.replace(/^\[|\]$/g, "")}]` : hostname;
  const defaultPort = sourceEndpoint.protocol === "http" ? 80 : 443;
  return `${sourceEndpoint.protocol}://${host}${sourceEndpoint.port === defaultPort ? "" : `:${sourceEndpoint.port}`}`;
}
const tokenKey = "notification-pwa-device-token";
const autoKey = "notification-pwa-auto-open";
const setupKey = "notification-pwa-setup-code";
const destinationControls = ["base-url", "username", "profile", "real-events", "delay"].map($);
let token = localStorage.getItem(tokenKey);
let destinationLoaded = false;
let destinationDirty = false;
let subscribed = false;
let showingSuggestion = false;

const fragmentSetup = /^#setup=([A-Fa-f0-9]{10})$/.exec(window.location.hash)?.[1]?.toUpperCase();
if (fragmentSetup) {
  localStorage.setItem(setupKey, fragmentSetup);
  history.replaceState(null, "", `${location.pathname}${location.search}`);
}
const pendingSetup = fragmentSetup || localStorage.getItem(setupKey) || "";
$("setup-code").value = pendingSetup;
$("setup-section").hidden = false;

$("auto-open").checked = localStorage.getItem(autoKey) === "true";
$("auto-open").addEventListener("change", () => localStorage.setItem(autoKey, String($("auto-open").checked)));

function setStatus(message) { $("status").textContent = message; }
function supported() { return window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window; }
function isIOSDevice() { return /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1); }
function installedOnIOS() { return !isIOSDevice() || navigator.standalone === true; }
function notificationPermission() { return "Notification" in window ? Notification.permission : "unsupported"; }

function updateDevicePresentation() {
  const summary = $("device-summary");
  const permission = notificationPermission();
  $("device-dot").className = "state-dot";
  if (!token) {
    summary.textContent = strings.notPaired;
    $("permission-summary").textContent = supported() ? strings.permissionNotEnabled : strings.permissionUnavailable;
  } else if (permission === "denied") {
    summary.textContent = strings.deniedDevice;
    $("permission-summary").textContent = strings.permissionDenied;
    $("device-dot").classList.add("paired");
  } else if (!supported()) {
    summary.textContent = strings.pairedDevice;
    $("permission-summary").textContent = strings.permissionUnavailable;
    $("device-dot").classList.add("paired");
  } else if (subscribed) {
    summary.textContent = strings.enabledDevice;
    $("permission-summary").textContent = strings.permissionEnabled;
    $("device-dot").classList.add("enabled");
  } else {
    summary.textContent = destinationLoaded ? strings.pairedDevice : strings.checking;
    $("permission-summary").textContent = supported() ? strings.permissionNotEnabled : strings.permissionUnavailable;
    $("device-dot").classList.add("paired");
  }
  $("pairing-summary").textContent = token ? strings.repair : strings.pairNeeded;
  if (token && !$("pairing-details").dataset.userToggled) $("pairing-details").open = false;
  $("save-destination").disabled = !token || !destinationDirty;
}

function updateSaveState(dirty) {
  destinationDirty = dirty;
  $("save-state").textContent = dirty ? strings.unsaved : strings.saved;
  $("save-state").classList.toggle("unsaved", dirty);
  $("save-destination").disabled = !token || !dirty;
}

function updateConnectionSummary() {
  const value = $("base-url").value;
  $("connection-summary").textContent = value || strings.manualSetup;
  $("suggested-label").hidden = !showingSuggestion || !value;
}

function destinationFromForm() {
  return { optIn: $("real-events").checked, baseURL: $("base-url").value, username: $("username").value, profile: $("profile").value, delaySeconds: Number($("delay").value) };
}

function destinationMatchesForm(destination) {
  const current = destinationFromForm();
  return current.optIn === destination.optIn && current.baseURL === destination.baseURL && current.username === destination.username && current.profile === destination.profile && current.delaySeconds === destination.delaySeconds;
}

function resetDestinationForm() {
  $("base-url").value = "";
  $("username").value = "opencode";
  $("profile").value = "legacy";
  $("delay").value = 15;
  $("real-events").checked = false;
  showingSuggestion = false;
  destinationLoaded = false;
  $("advanced-details").open = true;
  updateSaveState(false);
  updateConnectionSummary();
}

function decodeKey(value) {
  const padded = `${value}${"=".repeat((4 - value.length % 4) % 4)}`.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

async function api(path, options = {}) {
  const headers = { ...(options.body ? { "Content-Type": "application/json" } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) };
  const response = await fetch(path, { ...options, headers: { ...headers, ...options.headers } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || strings.unknown);
  return body;
}

const kindKeys = {
  test: "kindTest", idle: "kindIdle", permission: "kindPermission", question: "kindQuestion", error: "kindError", activity: "kindActivity",
  "permission-resolved": "kindResolved", "question-resolved": "kindResolved", "session-deleted": "kindDeleted"
};
const stateKeys = { scheduled: "stateScheduled", sending: "stateSending", "partially-scheduled": "statePartiallyScheduled", "no-opted-in-device": "stateNoOptedInDevice", delivered: "stateDelivered", cancelled: "stateCancelled", expired: "stateExpired", failed: "stateFailed", accepted: "stateAccepted", ignored: "stateIgnored", duplicate: "stateDuplicate" };
function localizedKind(kind) { return strings[kindKeys[kind]] || strings.bridgeActivity; }
function localizedState(state) { return strings[stateKeys[state]] || strings.stateUnavailable; }
function activityRow(title, detail) {
  const item = document.createElement("li");
  const heading = document.createElement("strong");
  const sublabel = document.createElement("span");
  heading.textContent = title;
  sublabel.textContent = detail;
  item.append(heading, sublabel);
  return item;
}

async function refresh() {
  if (!token) {
    destinationLoaded = false;
    updateDevicePresentation();
    return setStatus(strings.ready);
  }
  try {
    const state = await api("/api/status");
    subscribed = state.subscribed;
    if (state.destination && (!destinationLoaded || (!destinationDirty && !$("base-url").value && state.destination.baseURL === ""))) {
      if (!destinationDirty) {
        $("base-url").value = state.destination.baseURL;
        $("username").value = state.destination.username;
        $("profile").value = state.destination.profile;
        $("delay").value = state.destination.delaySeconds;
        $("real-events").checked = state.destination.optIn;
        const suggestion = state.destination.baseURL === "" ? suggestedBaseURL(window.location.hostname, state.sourceEndpoint) : "";
        if (suggestion) {
          $("base-url").value = suggestion;
          showingSuggestion = true;
          $("advanced-details").open = false;
          updateSaveState(true);
        } else {
          showingSuggestion = false;
          updateSaveState(false);
          if (!state.destination.baseURL) $("advanced-details").open = true;
        }
        updateConnectionSummary();
      }
      destinationLoaded = true;
    }
    const rows = state.jobs.map((job) => activityRow(localizedKind(job.kind), `${new Date(job.scheduledAt).toLocaleTimeString()} · ${localizedState(job.state)}`));
    if (state.bridge) rows.unshift(activityRow(strings.bridgeActivity, strings.bridgeDetail.replace("{kind}", localizedKind(state.bridge.kind)).replace("{status}", localizedState(state.bridge.status))));
    $("jobs").replaceChildren(...rows);
    $("empty-activity").hidden = rows.length > 0;
    $("activity-count").textContent = rows.length === 1 ? strings.activityCountOne : rows.length > 1 ? strings.activityCountMany.replace("{count}", rows.length) : "";
    const permission = notificationPermission();
    setStatus(permission === "denied" ? strings.denied : !supported() ? strings.unsupported : state.subscribed ? strings.enabled : strings.paired);
    updateDevicePresentation();
  } catch (error) {
    setStatus(error.message);
    updateDevicePresentation();
  }
}

destinationControls.forEach((control) => {
  control.addEventListener(control.type === "checkbox" || control.tagName === "SELECT" ? "change" : "input", () => {
    if (control.id === "base-url") showingSuggestion = false;
    updateSaveState(true);
    updateConnectionSummary();
  });
});
$("pairing-details").addEventListener("toggle", () => { $("pairing-details").dataset.userToggled = "true"; });

$("pair").addEventListener("click", async () => {
  try {
    const result = await api("/api/pair", { method: "POST", body: JSON.stringify({ code: $("pair-code").value }) });
    token = result.token;
    localStorage.setItem(tokenKey, token);
    subscribed = false;
    resetDestinationForm();
    $("pair-code").value = "";
    $("pairing-details").open = false;
    setStatus(strings.paired);
    updateDevicePresentation();
    await refresh();
  } catch (error) { setStatus(error.message); }
});

$("setup-code").addEventListener("input", () => {
  const code = $("setup-code").value.trim().toUpperCase();
  $("setup-section").hidden = false;
  if (/^[A-F0-9]{10}$/.test(code)) localStorage.setItem(setupKey, code);
});
$("use-connection").addEventListener("click", async () => {
  const code = $("setup-code").value.trim().toUpperCase();
  if (!token) return setStatus(strings.setupPairFirst);
  try {
    const draft = await api("/api/setup/redeem", { method: "POST", body: JSON.stringify({ code }) });
    $("base-url").value = draft.baseURL;
    $("username").value = draft.username;
    $("profile").value = draft.profile;
    showingSuggestion = false;
    $("advanced-details").open = true;
    updateConnectionSummary();
    updateSaveState(true);
    localStorage.removeItem(setupKey);
    $("setup-section").hidden = true;
    setStatus(strings.setupImported);
  } catch (error) { setStatus(error.message); }
});

async function saveDestination() {
  if (!token) return setStatus(strings.ready);
  try {
    const destination = destinationFromForm();
    await api("/api/destination", { method: "PUT", body: JSON.stringify(destination) });
    destinationLoaded = true;
    const hasNewerChanges = !destinationMatchesForm(destination);
    updateSaveState(hasNewerChanges);
    setStatus(hasNewerChanges ? strings.destinationSavedWithChanges : strings.destinationSaved.replace("{state}", destination.optIn ? strings.on : strings.off));
  } catch (error) { setStatus(error.message); }
}
$("save-destination").addEventListener("click", saveDestination);

$("enable").addEventListener("click", async () => {
  if (!window.isSecureContext) return setStatus(strings.secure);
  if (!supported()) return setStatus(strings.unsupported);
  if (!installedOnIOS()) return setStatus(strings.homeRequired);
  if (!token) return setStatus(strings.ready);
  try {
    const permissionPromise = Notification.requestPermission();
    const permission = await permissionPromise;
    if (permission !== "granted") { updateDevicePresentation(); return setStatus(strings.denied); }
    await navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" });
    const registration = await navigator.serviceWorker.ready;
    const config = await api("/api/config");
    let subscription = await registration.pushManager.getSubscription();
    if (!subscription) subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decodeKey(config.vapidPublicKey) });
    await api("/api/subscription", { method: "POST", body: JSON.stringify({ subscription: subscription.toJSON() }) });
    subscribed = true;
    setStatus(strings.enabled);
    updateDevicePresentation();
  } catch (error) { setStatus(error.message || strings.unknown); updateDevicePresentation(); }
});

$("schedule").addEventListener("click", async () => {
  try {
    const result = await api("/api/test", { method: "POST", body: JSON.stringify({ delaySeconds: Number($("delay").value) }) });
    await refresh();
    setStatus(strings.scheduled.replace("{time}", new Date(result.job.scheduledAt).toLocaleTimeString()));
  } catch (error) { setStatus(error.message); }
});

$("refresh").addEventListener("click", refresh);
$("reset").addEventListener("click", async () => {
  if (!confirm(strings.resetConfirm)) return;
  try {
    const registration = "serviceWorker" in navigator ? await navigator.serviceWorker.getRegistration() : null;
    const subscription = await registration?.pushManager.getSubscription();
    await subscription?.unsubscribe();
    if (token) await api("/api/device", { method: "DELETE", body: "{}" });
  } catch { /* Local cleanup still makes this device safe to pair again. */ }
  token = null;
  subscribed = false;
  resetDestinationForm();
  localStorage.removeItem(tokenKey);
  $("jobs").replaceChildren();
  $("empty-activity").hidden = false;
  $("activity-count").textContent = "";
  $("pairing-details").open = true;
  updateDevicePresentation();
  setStatus(strings.resetDone);
});

$("install-note").hidden = !isIOSDevice() || installedOnIOS();
$("empty-activity").hidden = false;
updateDevicePresentation();
updateConnectionSummary();
if (supported()) navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).then((registration) => registration.update()).catch(() => {});
refresh();
