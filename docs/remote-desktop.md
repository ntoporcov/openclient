# Remote desktop and human handoff

## Product contract

Two entry points share one host-scoped desktop viewer:

- A plugin tool requests human help, presenting a transcript card with the reason and an Open Remote Desktop action. Its execution remains pending until the user explicitly chooses Done or Cancel. Closing the viewer does not complete the tool.
- Projects exposes Remote Desktop when the connected plugin supports a usable viewer session. Manual access is independent of chat execution.

The desktop must be the same interactive desktop used by the agent. A separate virtual login session does not satisfy a login handoff.

## Setup (first working version)

Build the plugin with `npm run build` in `OpenClientPlugin/`. Its packaged `dist/` includes the viewer, noVNC license, and corresponding source. This branch has not been published to npm.

The viewer pins noVNC 1.5.0. The npm 1.6.0 CommonJS distribution contains a transitive top-level `await` that Bun cannot bundle; upgrades must be checked with the browser build and a real renderer smoke test.

Configure the environment of the OpenCode process that loads this plugin:

```sh
export OPENCLIENT_VNC_URL=vnc://127.0.0.1:5900
export OPENCLIENT_REMOTE_DESKTOP_TOKEN="$(openssl rand -hex 32)"
```

Keep the generated token in your local secret configuration. Restart the plugin host, reconnect OpenClient, and open **Remote Desktop** in Projects. Enter that token in the native sheet; it stays in memory for that presentation. Then enter your desktop credentials in the viewer's login form. Neither credential is included in chat/tool metadata.

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

iOS preserves this advertisement on its discovered bridge endpoint. Older plugins and malformed optional advertisements remain compatible. `detected` alone does not enable the button. `viewerAvailable` also requires an explicitly configured access token of at least 32 characters. The desktop may still request login or reject its credentials. Capability is refreshed when the plugin connection is discovered/reconnected, and checked again when opening a viewer session.

## Transport and lifecycle

- `POST /openclient/v1/desktop/sessions` requires the host-configured bearer token and rejects browser-origin requests. It returns a random 30-second, single-use ticket.
- The native viewer puts that ticket in the URL fragment, not a page query or transcript. The page consumes/removes the fragment and uses the ticket once to open the binary WebSocket. The upgrade requires a matching page Origin.
- The bridge proxies only the host-configured VNC target, with bounded buffering and at most eight pending/active viewer sessions. Streams expire after one hour and close on viewer dismissal or plugin shutdown. VNC credentials are negotiated by noVNC with the VNC server, not stored by the plugin.
- The viewer supports touch pointer gestures, software text entry, Escape/Tab and Control/Alt/Command modifiers, plus hardware keyboard input. It scales the desktop to fit without changing the host display resolution. Reconnect mints a new ticket. Backgrounding the iOS app closes its viewer stream.
- `openclient_request_remote_access(reason)` is registered for OpenCode v1 and v2. V2 disables Code Mode wrapping so the live transcript retains the native renderer payload. The tool publishes the request ID, originating session/message and reason, then awaits the human response.
- Native Done/Cancel calls the authenticated handoff endpoint. Responses must match the request's session/message. Closing the sheet does not resolve the request. Tool abort removes the pending request; shutdown or a 30-minute timeout cancels it. Pending requests are memory-only and cannot survive a plugin restart.

## Remaining validation / follow-up

- Complete a real macOS desktop login on the iPhone and verify that the agent's already-open browser is visible. Authentication negotiation is confirmed; login and shared-session selection still need the user's credentials.
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
