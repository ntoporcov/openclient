import RFBModule from "@novnc/novnc/lib/rfb.js"
import LegacyCryptoModule from "@novnc/novnc/lib/crypto/crypto.js"
import { installARDEncryptionFallback } from "../src/remote-desktop-crypto.ts"

const RFB = RFBModule.default ?? RFBModule
installARDEncryptionFallback(LegacyCryptoModule.default ?? LegacyCryptoModule, Boolean(window.crypto?.subtle))

const language = new URLSearchParams(location.hash.slice(1)).get("language") ?? navigator.language
const translations = {
  en: ["Connecting…", "Connected", "Disconnected. Close and reopen to reconnect.", "Desktop authentication failed.", "Username", "Password", "Sign in", "Type here", "Missing access ticket.", "Unable to connect to the desktop. Close and reopen to retry."],
  it: ["Connessione…", "Connesso", "Disconnesso. Chiudi e riapri per riconnetterti.", "Autenticazione del desktop non riuscita.", "Nome utente", "Password", "Accedi", "Scrivi qui", "Ticket di accesso mancante.", "Impossibile connettersi al desktop. Chiudi e riapri per riprovare."],
  pt: ["Conectando…", "Conectado", "Desconectado. Feche e reabra para reconectar.", "Falha na autenticação do desktop.", "Nome de usuário", "Senha", "Entrar", "Digite aqui", "Ticket de acesso ausente.", "Não foi possível conectar à área de trabalho. Feche e reabra para tentar novamente."],
}
const strings = translations[language.split("-")[0]] ?? translations.en
const $ = (id) => document.getElementById(id)
const parameters = new URLSearchParams(location.hash.slice(1))
const ticket = parameters.get("ticket")
history.replaceState(null, "", location.pathname)
$("userLabel").textContent = strings[4]
$("passwordLabel").textContent = strings[5]
$("login").textContent = strings[6]
$("text").placeholder = strings[7]
$("text").setAttribute("aria-label", strings[7])
$("status").textContent = ticket ? strings[0] : strings[8]

let activeRFB
let failed = false
const fail = () => {
  failed = true
  $("status").textContent = strings[9]
  $("password").value = ""
  $("credentials").hidden = true
  activeRFB?.disconnect()
}
// noVNC's asynchronous authentication can reject outside its event callbacks.
// Never leave the user on Connecting or expose exception/credential details.
window.addEventListener("unhandledrejection", fail)
window.addEventListener("error", fail)

if (ticket) {
  const url = new URL("socket", location.href)
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:"
  url.searchParams.set("ticket", ticket)
  const rfb = new RFB($("screen"), url.href, { shared: true })
  activeRFB = rfb
  rfb.scaleViewport = true
  rfb.resizeSession = false
  rfb.background = "#121212"
  rfb.addEventListener("connect", () => { $("status").textContent = strings[1] })
  rfb.addEventListener("disconnect", () => { if (!failed) $("status").textContent = strings[2]; $("credentials").hidden = true })
  rfb.addEventListener("securityfailure", () => { failed = true; $("status").textContent = strings[3] })
  rfb.addEventListener("credentialsrequired", (event) => {
    $("credentials").hidden = false
    const username = event.detail.types.includes("username")
    $("username").hidden = !username
    $("userLabel").hidden = !username
    $(username ? "username" : "password").focus()
  })
  document.querySelector("form").addEventListener("submit", (event) => {
    event.preventDefault()
    rfb.sendCredentials({ username: $("username").value, password: $("password").value })
    $("password").value = ""
    $("credentials").hidden = true
    rfb.focus()
  })
  $("escape").onclick = () => rfb.sendKey(0xff1b, "Escape")
  $("tab").onclick = () => rfb.sendKey(0xff09, "Tab")
  const modifiers = new Map()
  const modifierKeys = [["control", 0xffe3, "ControlLeft"], ["alt", 0xffe9, "AltLeft"], ["meta", 0xffeb, "MetaLeft"]]
  const releaseModifiers = () => {
    for (const [id, keysym, code] of modifierKeys) {
      if (modifiers.get(id)) rfb.sendKey(keysym, code, false)
      modifiers.set(id, false)
      $(id).setAttribute("aria-pressed", "false")
      $(id).style.background = "#333"
    }
  }
  for (const [id, keysym, code] of modifierKeys) {
    $(id).onclick = () => {
      const down = !modifiers.get(id)
      modifiers.set(id, down)
      $(id).setAttribute("aria-pressed", String(down))
      $(id).style.background = down ? "#7050c0" : "#333"
      rfb.sendKey(keysym, code, down)
    }
  }
  $("text").addEventListener("input", (event) => {
    if (event.isComposing) return
    for (const char of $("text").value) {
      const code = char.codePointAt(0)
      rfb.sendKey(code <= 0xff ? code : 0x01000000 | code)
    }
    $("text").value = ""
  })
  $("text").addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); rfb.sendKey(0xff0d, "Enter") }
    if (event.key === "Backspace") { event.preventDefault(); rfb.sendKey(0xff08, "Backspace") }
  })
  window.addEventListener("pagehide", () => { releaseModifiers(); rfb.disconnect() })
  document.addEventListener("visibilitychange", () => { if (document.hidden) releaseModifiers() })
}
