# Remote desktop and human handoff

## Product contract

Two entry points share one host-scoped desktop viewer:

- A plugin tool requests human help and immediately returns a durable transcript card with the reason and an Open Remote Desktop action. The agent is instructed to end its turn and wait for a user message. Done prepares a follow-up draft; only the user's Send resumes the conversation. Closing the viewer alone does not change the draft.
- Projects exposes Remote Desktop when the connected plugin supports a usable viewer session. Manual access is independent of chat execution.

The desktop must be the same interactive desktop used by the agent. A separate virtual login session does not satisfy a login handoff.

## Setup (first working version)

### Toolbar personalization and loading game

Long-press the Projects Remote Desktop button to choose a persistent toolbar icon or forget the current computer's saved credentials. Credential deletion resolves the authenticated host's current target and removes only its server/account/target-scoped Keychain entry.

While connecting, only Close remains in the viewer toolbar. Once landscape layout is established, the loading screen offers a reaction game: tap randomly positioned icons as they appear. The fastest positive reaction time is retained locally across launches. Rotation out of landscape or backgrounding stops the round. The first stream frame immediately replaces the game and reveals the desktop controls; credential prompts and connection errors also take precedence.

Validation: record persistence/invalid-result unit coverage and the landscape start → target tap → best-score restore UI flow passed on iPhone 18 Pro Max (iOS 27.0), iPad Pro 13-inch M5 (iOS 27.0), and iPhone Duo (iOS 27.1). Duo fold transitions and live toolbar-menu/credential-removal behavior still require manual checks. Device build and full localization extraction passed; installed and launched on Nic iPhone.

### Native client prototype

In-chat handoffs use a prominent full-width **Open Remote Desktop** button. In the viewer, an info toolbar button opens the AI's instructions in a compact popover. The blue Done checkmark closes the viewer and prepares “I’ve finished the desktop task. Please continue.” in the originating chat's composer, without sending it. Existing text is preserved and the follow-up appended once; mentions and attachments remain intact. Drafts use the existing window/session-scoped persistence flow. The card remains reopenable after app/host restarts because its payload is part of the completed tool result (`mode: "draft"`), not transient tool progress or an in-memory pending request. There is no separate Cancel request action. The desktop title disappears after the first frame. While the keyboard is visible, a dedicated dismiss button remains beside the function-key row above it.

Draft-handoff verification: 17 focused plugin tests passed, including immediate return without progress publication or a pending request. Three iOS tests passed on each required simulator (iPhone 18 Pro Max/iOS 27.0, iPad Pro 13-inch M5/iOS 27.0, iPhone Duo/iOS 27.1), covering completed-card decoding/round-trip, preserving existing draft text, duplicate suppression, and legacy-mode decoding. Signed device build and localization extraction passed. The app was installed on Nic iPhone, but launch was blocked by the lock screen; end-to-end composer presentation and Duo transitions still need manual verification.

Viewer controls: Remote Desktop is a separate Projects toolbar group beside the plugin connection button. On iOS, the bottom toolbar has a glass tap-to-click toggle (off by default) and a keyboard show/hide action. Two-finger pan and pinch zoom remain available in either mode. With click mode off, one-finger panning also works; with it on, single taps send a complete click at the transformed framebuffer coordinate. Letterbox taps are ignored. A two-second bottom toast confirms click-mode changes. The keyboard row shares the terminal's glass key styling, with paste, Escape, Tab, Control/Alt, punctuation, interrupt, arrows, Delete, and Return. Modifier keys are released when the row closes. Close/options remain in the top toolbar; handoff completion remains explicit. Keyboard resizing preserves zoom and the framebuffer point at the viewport center, clamping only at the desktop edges.

The iOS viewer uses SwiftUI's `fullScreenCover` for reliable toolbar presentation, with a visible UIKit hosting controller applying landscape after `viewDidAppear`, including while connecting or authenticating. It restores the prior orientation on dismissal. iPad orientation is left to the system. A previous custom UIKit presenter attached to the toolbar background regressed the open button and was removed; orientation changes must not require presenting from that background controller. The desktop extends beneath transparent top/bottom toolbars and device safe areas, with scroll-edge effects disabled; its aspect ratio is preserved, so differing host/device ratios can still produce letterboxing. Keyboard and handoff actions overlay the stream. The installed SDK exposes no public Duo posture API, so the options menu includes an explanatory unfold hint rather than identifying Duo through screen-size heuristics.

Control validation: framebuffer coordinate mapping (fit, zoom, pan, letterbox rejection), preservation of zoom and center across keyboard-sized viewport changes, and two-finger recognizer availability in click mode passed on iPhone 18 Pro Max/iOS 27.0, iPad Pro 13-inch (M5)/iOS 27.0, and iPhone Duo/iOS 27.1 (three tests per device, no skips). Signed device build and full compiler-extraction localization checks passed. The latest build was installed on Nic iPhone through the CoreDevice fallback; launch was blocked by the lock screen. Landscape presentation, native toolbar/keyboard/toast appearance, and Duo folded/unfolded transitions remain hands-on checks because native device screenshot/hierarchy tools are unavailable.

Current native authentication uses OpenCode V2's authenticated plugin RPC (`openclient.desktop.open` and `.complete`). The app reuses its active OpenCode client credentials; it never asks for a separate desktop bridge token. The RPC returns a 30-second single-use WebSocket ticket and an opaque target identifier. The bridge's legacy HTTP control endpoints remain token-protected for older clients. Fresh V2 hosts only need the VNC URL; the token/token-file option is optional legacy compatibility. This native flow requires the updated V2 plugin.

The Mac login form offers **Save computer credentials**, off by default. Credentials are saved only after a successful native connection, in an app-only `WhenUnlockedThisDeviceOnly` Keychain item scoped by OpenCode server/account and VNC target. Reopening the viewer automatically authenticates from Keychain. A failed saved attempt is not automatically retried within that viewer; reconnect presents manual login. The options menu can forget saved credentials and reconnect. No credentials are displayed from Keychain or sent through RPC, plugin metadata, or chat.

Credential-flow verification: both native integration tests passed without skips on iPhone 18 Pro Max / iOS 27.0, iPad Pro 13-inch M5 / iOS 27.0, and iPhone Duo / iOS 27.1. Coverage includes rejected credentials not being saved, successful Keychain writes, automatic reconnect, scope isolation, stale saved passwords returning to manual entry, forgetting, opting out, and rejected OpenCode authorization. Live V2 RPC ticket issuance and handoff response shape were checked; anonymous calls return 401. Physical login UI and Duo fold transitions still require hands-on verification because native device UI automation is unavailable.

The iOS client uses RoyalVNCKit rather than loading the noVNC webpage. `Vendor/RoyalVNCKit` contains an MIT-licensed snapshot of revision `090b96eddeee183e9fec293c5cd881d302a4349d`, with a small receive-only clipboard callback (documented in `OPENCLIENT.md`). Authentication fields, errors, framebuffer presentation, text entry, Escape/Tab/Delete, and direct pointer down/drag/up are native. Projects and human handoffs share this same presentation.

RoyalVNCKit exposes a TCP client but no public custom-transport injection. `OpenClientDesktopTunnel` binds an ephemeral IPv4 loopback port, accepts one local connection, closes the listener, and forwards binary traffic over a URLSession WebSocket with the existing single-use ticket and Origin validation. Each direction waits for its write completion before reading more data. No VNC destination or credentials are added to the plugin API. Closing/backgrounding cancels authentication, disconnects the library, and tears down the tunnel.

`OpenClientNativeDesktopSession` owns protocol operations and bridges SDK callbacks to the main-actor store. SwiftUI consumes the store and forwards user intent. In-memory credentials are cleared after the authentication attempt; opt-in persistence uses Keychain. Automatic clipboard synchronization remains disabled.

### Receive-only clipboard history

#### Host clipboard transport (after build 101)

Build 101's Apple VNC clipboard extension still did not deliver text on the live
Mac. Native viewers now opt into a clipboard control channel on the existing
ticketed WebSocket (`clipboard=1`). The host advertises availability only on macOS
when the configured VNC hostname is loopback or a local interface address. After
desktop authentication, the client subscribes; the host observes its own logged-in
user's NSPasteboard with one short-lived AppKit/JXA process per viewer. It checks
changeCount every 100 ms, reads only changed plain text, and sends bounded JSON
text frames separately from binary RFB traffic. No Swift compiler/helper install
is required. Closing the viewer terminates the observer. Older hosts receive no
unknown control commands, and legacy binary-only viewers receive no text frames.

This requires both the updated iOS app and the updated host plugin. The host
clipboard is for same-Mac viewing; it is not a substitute for a separately
configured remote computer or another user's login session. History continues to
be receive-only; only tapping a history item writes the iPhone clipboard.
OSLog category `DesktopClipboard` reports capability and observer readiness,
without clipboard contents. Malformed or oversized control frames are ignored
and never enter the VNC stream.

Host validation: plugin typechecking/build and 90 tests passed (one opt-in live
test skipped by the default suite). The explicit native AppKit observer test
passed using both an isolated named pasteboard and the actual general Mac
pasteboard. Initial general-board tests revealed competing Simulator/CoreDevice
clipboard-sync writes: the synthetic copy was replaced repeatedly within two
seconds. Temporarily pausing only the Simulator `dtpasteboardd` processes removed
that interference; they were resumed in cleanup. `OPENCLIENT_LIVE_CLIPBOARD_TEST=1`
enables the native test; also set `OPENCLIENT_GENERAL_CLIPBOARD_TEST=1` to test the
actual desktop board. The test preserves all original clipboard flavors unless
another process changes the clipboard during the test.

Eight iOS tests passed without skips on each of iPhone 18 Pro Max/iOS 27.0,
iPad Pro 13-inch M5/iOS 27.0, and iPhone Duo/iOS 27.1. The native integration
fixture verifies authenticated WebSocket clipboard text reaches the shared
history without writing the device pasteboard, while VNC authentication,
framebuffer/input, saved credentials, and reconnect continue working. Signed
device build passed. This combines a real Mac pasteboard test and fixture-driven
iOS transport tests; physical-iPhone end-to-end validation and Duo fold
transitions remain outstanding.

Click mode starts enabled. Tap sends a click; double-tap sends a double-click (word selection in supporting desktop apps). A 350 ms hold gives a light haptic: releasing without deliberate movement sends only a right-click, preserving existing selection; moving at least 8 screen points starts a left-button drag from the hold location. Dragging selects text or moves desktop objects using the remote app's own behavior and never automatically right-clicks afterward. A one-time hint appears when the first desktop frame arrives. Two-finger pan/zoom remains available and cancels pending holds or releases any held remote mouse button before taking over. Turning click mode off, resizing, cancellation, or removing the surface does the same. The viewer options menu's **Copy selection** sends ⌘C to the Mac; the resulting clipboard update enters the history below.

Selection verification: six surface tests plus an actual double-tap/hold-and-drag/stationary-hold UI test passed on each required simulator (iPhone 18 Pro Max/iOS 27.0, iPad Pro 13-inch M5/iOS 27.0, iPhone Duo/iOS 27.1), with no skips. Tests verify a stationary hold sends only a right-click, dragging never adds a right-click, and navigation cancellation does neither. Signed device build and localization extraction passed. Installation was blocked by unavailable Nic iPhone connectivity, including the direct CoreDevice fallback; haptic feel and live desktop selection/copy still need on-device confirmation. Duo fold transitions remain untested.

Ordinary RFB ServerCutText events are delivered to a main-actor history without reading or writing the iOS pasteboard or sending clipboard contents back to the computer. The clipboard button appears when text has been captured, briefly bounces on new captures (respecting Reduce Motion), and opens a popover. Tapping an item explicitly copies its full text to the device clipboard; Clear removes the cached history.

The viewer, Projects toolbar, and chat handoff cards share the connected server/account's history. Closing the viewer retains it in memory until the app process ends. Switching the authenticated target clears that server's old history, and late events from another target/connection are ignored. History holds up to 40 distinct text items, each at most 64 KiB UTF-8. Recopying an older item promotes it; repeated unchanged updates do not animate or duplicate it. Clipboard contents are not persisted or logged.

The receive-only adapter now subscribes to Apple pasteboard updates for Apple-advertising servers, requests contents when a promise arrives, and decodes compressed UTF-8/UTF-16 plain-text flavors. It keeps the existing RFB version negotiation. Standard ServerCutText remains supported. Images, files, rich text, and standard RFB extended clipboard negotiation are not supported. Live macOS delivery has not yet been verified: the earlier standard-RFB fixture passing did not establish Mac compatibility, and build 100 device feedback confirmed that no clipboard button appeared after copying.

Top-row input: the viewer hides the navigation bar and uses individual system-styled buttons in a transparent overlay. The space between Close and the trailing controls has no hit target, allowing desktop clicks underneath. The previous transparent navigation bar still intercepted those clicks despite its hidden background.

Build-100 feedback follow-up verification: all five clipboard tests and seven pointer/gesture tests passed on each required simulator. The additional top-control-gap UI test passed on iPhone 18 Pro Max/iOS 27.0, iPad Pro 13-inch M5/iOS 27.0, and iPhone Duo/iOS 27.1 after fixing the test's Duo orientation/coordinate setup to use landscape and surface-relative coordinates. It verifies gap taps reach the desktop while Close does not click through. Apple protocol fixtures verify subscription, promise/request exchange, compressed Unicode text, UTF-16BE, recovery after malformed flavor data, and no device-pasteboard writes. The signed device build passed. Live Mac subscription compatibility and Duo folded/unfolded transitions remain unverified.

Verification: three unit/integration tests and one popover UI test passed on each of iPhone 18 Pro Max/iOS 27.0, iPad Pro 13-inch M5/iOS 27.0, and iPhone Duo/iOS 27.1. The local RFB fixture delivers a real ServerCutText message with automatic redirection off and checks that the device clipboard change count stays unchanged. UI coverage checks capture, explicit copy intent, and history after viewer dismissal. Device build and full localization extraction passed; installed and launched on Nic iPhone. Live macOS clipboard delivery and Duo fold transitions remain manual checks.

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
- New cards return immediately with `mode: "draft"`; Done only updates the originating composer's draft and never calls the completion RPC or sends a prompt. Legacy cards without that mode retain the authenticated completion endpoint. Those older waiting requests remain session/message-bound, are removed on abort, and cancel on shutdown or timeout.

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
