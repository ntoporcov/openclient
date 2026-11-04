# Remote desktop and human handoff

## Product contract

Two entry points share one host-scoped desktop viewer:

- A plugin tool requests human help, presenting a transcript card with the reason and an Open Remote Desktop action. Its execution remains pending until the user explicitly chooses Done or Cancel. Closing the viewer does not complete the tool.
- Projects exposes Remote Desktop when the connected plugin supports a usable viewer session. Manual access is independent of chat execution.

The desktop must be the same interactive desktop used by the agent. A separate virtual login session does not satisfy a login handoff.

## Setup (first working version)

### Native client prototype

Current native authentication uses OpenCode V2's authenticated plugin RPC (`openclient.desktop.open` and `.complete`). The app reuses its active OpenCode client credentials; it never asks for a separate desktop bridge token. The RPC returns a 30-second single-use WebSocket ticket and an opaque target identifier. The bridge's legacy HTTP control endpoints remain token-protected for older clients. Fresh V2 hosts only need the VNC URL; the token/token-file option is optional legacy compatibility. This native flow requires the updated V2 plugin.

The Mac login form offers **Save computer credentials**, off by default. Credentials are saved only after a successful native connection, in an app-only `WhenUnlockedThisDeviceOnly` Keychain item scoped by OpenCode server/account and VNC target. Reopening the viewer automatically authenticates from Keychain. A failed saved attempt is not automatically retried within that viewer; reconnect presents manual login. The options menu can forget saved credentials and reconnect. No credentials are displayed from Keychain or sent through RPC, plugin metadata, or chat.

Credential-flow verification: both native integration tests passed without skips on iPhone 18 Pro Max / iOS 27.0, iPad Pro 13-inch M5 / iOS 27.0, and iPhone Duo / iOS 27.1. Coverage includes rejected credentials not being saved, successful Keychain writes, automatic reconnect, scope isolation, stale saved passwords returning to manual entry, forgetting, opting out, and rejected OpenCode authorization. Live V2 RPC ticket issuance and handoff response shape were checked; anonymous calls return 401. Physical login UI and Duo fold transitions still require hands-on verification because native device UI automation is unavailable.

The iOS client now uses RoyalVNCKit (pinned to `090b96eddeee183e9fec293c5cd881d302a4349d`) rather than loading the noVNC webpage. Authentication fields, errors, framebuffer presentation, text entry, Escape/Tab/Delete, and direct pointer down/drag/up are native. Projects and human handoffs share this same presentation.

RoyalVNCKit exposes a TCP client but no public custom-transport injection. `OpenClientDesktopTunnel` binds an ephemeral IPv4 loopback port, accepts one local connection, closes the listener, and forwards binary traffic over a URLSession WebSocket with the existing single-use ticket and Origin validation. Each direction waits for its write completion before reading more data. No VNC destination or credentials are added to the plugin API. Closing/backgrounding cancels authentication, disconnects the library, and tears down the tunnel.

`OpenClientNativeDesktopSession` owns protocol operations and bridges SDK callbacks to the main-actor store. SwiftUI consumes the store and forwards user intent. In-memory credentials are cleared after the authentication attempt; opt-in persistence uses Keychain. Clipboard synchronization is disabled.

This first native version fits the full desktop to the available area. Pinch zoom/pan, richer modifier/hardware-keyboard handling, cursor rendering, accessibility navigation within the remote desktop, and sustained-frame performance tuning remain follow-up work. Real Mac login and shared-session selection still need user validation.

Native integration fixture: run `bun test/fixtures/native-desktop.ts` from `OpenClientPlugin`, then run `NativeRemoteDesktopTests` on a simulator. The fixture uses fake credentials and never connects to the real Mac desktop.

Native validation: the authentication/framebuffer/input/reconnect integration test passed without skips on iPhone 18 Pro Max (iOS 27.0), iPad Pro 13-inch M5 (iOS 27.0), and iPhone Duo (iOS 27.1). It verifies successful ARD authentication, a 320×180 framebuffer, keyboard/pointer delivery, rejected credentials, and a fresh successful connection afterward. This is protocol integration coverage, not visual layout or Duo fold-transition coverage. Physical-device UI automation is currently unavailable in the tool session; final Mac login and interaction feel require hands-on verification.

The tokenless native signed iPhone build and full localization lane passed. Installed and launched on Nic iPhone, with the process confirmed running. Open Projects → Remote Desktop to sign in and optionally save computer credentials. The user previously confirmed real Mac login, streaming, and pointer focus with the native viewer.

Launch packaging correction: RoyalVNCKit is a dynamic package product and must be explicitly embedded and signed in both app targets. The app targets also need framework runtime search paths. Without these, physical-device launch failed in dyld even though simulator integration tests passed using the Mac build directory. After correcting `project.yml`, the signed framework was verified inside the iPhone app bundle, the fresh build was installed and launched on Nic iPhone, and the app process remained running.

### Legacy webpage compatibility

The plugin still serves its webpage for older installed app builds. The following noVNC notes describe that compatibility path, not the native client.

Build the plugin with `npm run build` in `OpenClientPlugin/`. Its packaged `dist/` includes the viewer, noVNC license, and corresponding source. This branch has not been published to npm.

The viewer pins noVNC 1.5.0. The npm 1.6.0 CommonJS distribution contains a transitive top-level `await` that Bun cannot bundle; upgrades must be checked with the browser build and a real renderer smoke test.

On HTTP LAN/VPN origins, WebKit omits WebCrypto. The viewer uses `@noble/ciphers` for ARD's required AES-128-ECB credential encryption on those origins, retaining noVNC's implementation when WebCrypto is available. Asynchronous viewer failures now show an error instead of leaving “Connecting…” indefinitely.

The authentication fix passed 87 plugin tests and a Safari smoke test through the VPN HTTP address with WebCrypto unavailable: synthetic ARD credentials were decrypted/validated by the fixture server and its framebuffer rendered correctly. An injected asynchronous failure displayed the localized retry message. The live bridge's viewer bundle was verified byte-for-byte against the new build; no host restart or iOS reinstall is needed for this fix. Real Mac login remains a user verification step.

Configure the environment of the OpenCode process that loads this plugin:

For managed hosts, prefer explicit plugin options (the token stays in a separate mode-600 file):

```json
"remoteDesktop": {
  "url": "vnc://127.0.0.1:5900",
  "tokenFile": "/absolute/path/to/remote-desktop-token"
}
```

Place this object alongside `serverURL` inside the plugin's `options`. A missing/unreadable token file disables legacy HTTP control access rather than falling back to another token. For current V2/native clients, omit `tokenFile`; OpenCode RPC authorizes access. Alternatively, hosts that forward environment variables can use:

```sh
export OPENCLIENT_VNC_URL=vnc://127.0.0.1:5900
export OPENCLIENT_REMOTE_DESKTOP_TOKEN="$(openssl rand -hex 32)"
```

For older clients, keep the generated token in your local secret configuration and enter it in their token prompt. Current native clients bypass this legacy flow. Neither credential is included in chat/tool metadata. OpenCode V2 watches plugin configuration; use its configuration reload when needed.

This version uses the existing plugin bridge over a private LAN/VPN connection (for example Tailscale). It does not add an Internet relay or TLS termination. Do not expose the plain HTTP bridge to the public Internet; use an encrypted VPN/tunnel for remote connections.

Enable the host's VNC/Screen Sharing service separately. Use the existing interactive desktop, not a separate virtual login session, when completing an agent login handoff.

## Detection boundary

Set `OPENCLIENT_VNC_URL=vnc://127.0.0.1:5900` in the plugin host environment and restart OpenCode. This is explicit host configuration, not a tool-supplied network target. URLs cannot contain credentials.

The bridge health response includes an additive `remoteDesktop` field:

```json
{
  "version": 1,
  "transport": "rfb",
  "state": "detected",
  "protocolVersion": "003.008",
  "viewerAvailable": true
}
```

States are `unconfigured`, `unavailable`, and `detected`. Detection reads the 12-byte RFB server greeting with a one-second deadline. It does not authenticate or send input. Results are cached for five seconds and concurrent probes coalesce. Target addresses and credentials are not advertised.

iOS preserves this advertisement on its discovered bridge endpoint. Older plugins and malformed optional advertisements remain compatible. `detected` alone does not enable the button. `viewerAvailable` also requires V2 RPC authorization support or a legacy access token of at least 32 characters. The desktop may still request login or reject its credentials. Capability is refreshed when the plugin connection is discovered/reconnected, and checked again when opening a viewer session.

## Transport and lifecycle

- Current native clients call `POST /api/rpc/openclient.desktop/open` on OpenCode using the existing server authentication. Legacy `POST /openclient/v1/desktop/sessions` requires the host-configured bearer token and rejects browser-origin requests. Both issue random 30-second, single-use tickets.
- The native tunnel consumes the internal viewer URL fragment and uses the ticket once to open the binary WebSocket with the bridge Origin. No webpage is loaded. The legacy webpage consumes/removes its fragment similarly.
- The bridge proxies only the host-configured VNC target, with bounded buffering and at most eight pending/active viewer sessions. Streams expire after one hour and close on viewer dismissal or plugin shutdown. VNC credentials are negotiated by RoyalVNCKit (or legacy noVNC) with the VNC server, not stored by the plugin.
- The native viewer supports touch pointer gestures, software text entry, and Escape/Tab/Delete. It scales the desktop to fit without changing the host display resolution. Reconnect mints a new ticket. Backgrounding the iOS app closes its viewer stream.
- `openclient_request_remote_access(reason)` is registered for OpenCode v1 and v2. V2 disables Code Mode wrapping so the live transcript retains the native renderer payload. The tool publishes the request ID, originating session/message and reason, then awaits the human response.
- Native Done/Cancel calls the authenticated handoff endpoint. Responses must match the request's session/message. Closing the sheet does not resolve the request. Tool abort removes the pending request; shutdown or a 30-minute timeout cancels it. Pending requests are memory-only and cannot survive a plugin restart.

## Remaining validation / follow-up

- Verify the new opt-in saved-login UX on the real Mac. The user confirmed native Mac login, streaming, and pointer focus before this credential-saving change.
- Exercise long-running sessions, cellular/VPN reconnects, drag/scroll and keyboard ergonomics on physical devices.
- Integrate an authenticated encrypted cloud transport if access without a VPN becomes a product requirement.

## Verification

Initial host probe on November 3, 2026 found `RFB 003.889` at `127.0.0.1:5900`. The bundled viewer subsequently reached its real macOS username/password prompt in Safari via the binary bridge. No desktop credentials were entered.

- Plugin tests use real loopback TCP servers for fragmented RFB greetings, non-VNC services, silent/partial peers, probe coalescing and credential-free configuration.
- Transport tests cover authentication, browser-origin rejection, single-use tickets, exact binary forwarding, handoff ownership, explicit completion, abort and shutdown.
- A synthetic RFB desktop (`OpenClientPlugin/test/fixtures/vnc-server.ts`) rendered a 320×180 framebuffer in Safari. Pixel readback confirmed rendering; server-side event capture confirmed Escape, text input, and pointer down/up at the expected desktop coordinates.
- iOS tests cover backward-compatible discovery, authenticated ticket requests, fragment-only viewer tickets, invalid tickets and rejected authentication.
- Validation run: 84 plugin tests passed; TypeScript checking and the plugin build passed. Three native contract tests passed on each of iPhone 18 Pro Max (iOS 27.0), iPad Pro 13-inch M5 (iOS 27.0), and iPhone Duo (iOS 27.1). These were unit tests, not folded/unfolded Duo UI validation.
- Both catalog/source lint and the full Fastlane compiler-extraction localization lane passed. A signed iPhone build was installed on Nic iPhone; automatic launch was denied because the device was locked, so physical-device UI verification remains pending.
- The final feature requires physical iPhone testing against the actual desktop: login handoff, manual access, reconnect, cancel, tool abort and same-host/multiple-project behavior.
