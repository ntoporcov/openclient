# OpenClient Notification PWA

OC Notify is now bundled into `OpenClientPlugin`. This directory remains the
canonical notification source and isolated development/test harness; the plugin
build packages it into `OpenClientPlugin/dist/notifications`. See
[`OpenClientPlugin/README.md`](../OpenClientPlugin/README.md) for installation,
app-initiated setup, and the controlled cutover from the standalone companion.
The former `.opencode/plugins/notification-pwa.ts` wrapper has been retired.
Do not run a standalone companion against the same port or data directory as
the bundled service.

A local prototype that turns OpenCode lifecycle events into iPhone Home Screen PWA Web Push notifications. Tapping a real event notification opens a cached same-origin handoff page, which offers only the fixed `openclient://widget/session` route for the canonical OpenCode session.

It does not modify the native app, store native credentials, poll OpenCode, expose an arbitrary push API, or execute anything through a deep link.

## Architecture

- The OpenClient plugin owns the shared notification service and creates a directory-scoped adapter from `src/plugin-bridge.mjs` for each plugin instance.
- The plugin consumes only the OpenCode `event` hook. It tracks `session.status` activity cycles, ignores deprecated `session.idle`, obtains canonical session metadata through the injected legacy SDK client, and lazily advertises only the listener protocol and effective port from `PluginInput.serverUrl`.
- The plugin posts bounded structured events to an authenticated listener at `127.0.0.1:4320`. The random bearer token is generated once in `.data/bridge-token` with mode `0600`.
- The public PWA/API server remains at `127.0.0.1:4319`; only this port is proxied through private Tailscale HTTPS on `8443`.
- Each paired device has its own explicit opt-in, exact OpenClient server identity, profile, and 5–120 second real-event delay. Settings are snapshotted when a notification is scheduled.
- Web Push encryption carries a validated session target plus separate bounded display context. The service worker transfers only the target in a bounded URL fragment to the cached handoff page; the fragment is not sent to the web server.
- The authenticated Events screen shows a redacted, per-device companion ledger. It distinguishes receipt, scheduling, push-service acceptance, cancellation, failure, expiration, opt-out, and restart interruption without claiming that iOS displayed a notification.

## Standalone Development

Requires Node.js 20 or newer. From `NotificationPWA/`:

```bash
export PATH="/opt/homebrew/bin:$PATH"
npm install
PUBLIC_ORIGIN="https://your-device.your-tailnet.ts.net:8443" \
OPENCODE_SERVER_URL="http://0.0.0.0:4096" \
DATA_DIR="$PWD/.data" \
npm start
```

The process binds `127.0.0.1:4319` and `127.0.0.1:4320`. The existing private proxy should continue to expose only the public listener:

```bash
"/Applications/Tailscale.app/Contents/MacOS/Tailscale" serve --bg --https=8443 http://127.0.0.1:4319
```

Do not proxy port `4320`. Keep Tailscale connected on the iPhone. This uses Serve, not public Funnel, and does not alter the existing port 443 proxy.

`OPENCODE_SERVER_URL` is an explicit operator-configured startup hint for standalone development. It is sanitized to protocol and effective port only; it is not probed or treated as proof of external reachability. The bundled service uses its plugin's lazy `serverUrl` getter directly, without the private HTTP ingestion listener. Restarting the owning runtime cancels in-memory pending notification timers but preserves VAPID keys, paired devices, subscriptions, and exact destination settings in the configured data directory.

Keep this command running while notifications are enabled. Stop it with the terminal's normal interrupt when the prototype is not needed.

## Status

Public health contains no secrets:

```bash
curl http://127.0.0.1:4319/health
```

Expected result:

```json
{"ok":true}
```

In the paired PWA, open **View All Events** under Recent Activity to inspect the current device’s event ledger. The screen refreshes every three seconds only while visible and preserves existing results through transient refresh errors. Bridge timestamps report only the last observed metadata heartbeat or event, not current connectivity. The diagnostic response contains no bridge token, device token, subscription endpoint, destination server identity, native password, or VAPID key.

## Pair And Configure iPhone

Existing paired devices do not need to pair again. A new device can be paired with:

```bash
npm run pair -- --data-dir "$PWD/.data"
```

Then on iPhone:

1. Open the private HTTPS URL in Safari and choose Share, then Add to Home Screen.
2. Launch the installed Home Screen app and pair only if it is not already paired.
3. Tap **Enable on this device** to create or refresh its Web Push subscription.
4. OC Notify may suggest a URL using its PWA hostname plus the advertised OpenCode protocol and port. This is unverified. Open **Advanced** if it does not exactly match the URL saved in OpenClient; raw spelling, including a trailing slash, is identity-significant.
5. Enter the saved username, normally `opencode`, or leave it empty for a saved no-auth server. Explicitly choose `Legacy` or `V2`; there is no automatic profile mode.
6. Choose a real-event delay from 5–120 seconds; the default is 15 seconds so there is time to leave the app.
7. Enable **Send real OpenCode notifications to this device**, then tap **Save destination**.

This destination only identifies an existing native saved server. It does not add that server to OpenClient, test its credentials, configure it, or authenticate it. If the URL, username, or profile does not exactly match OpenClient's saved identity, the native handoff safely fails to select the session.

The manual delayed test button remains available and does not require real-event opt-in. The existing experimental auto-open preference remains in browser local storage; iOS may still require the explicit handoff button.

## Event Contract

Plugin hook:

```ts
async ({ client, directory, project }) => ({
  event: async ({ event }) => { /* bounded fire-and-forget enqueue */ }
})
```

Loopback ingestion:

```http
POST http://127.0.0.1:4320/ingest
Authorization: Bearer <persisted local bridge token>
Content-Type: application/json
```

The event body is internal and fixed to source `openclient-ios-local`. Accepted kinds are `activity`, `idle`, `error`, `permission`, `question`, `permission-resolved`, `question-resolved`, and `session-deleted`. Notification-producing events may include only `context: { projectName, sessionTitle }`; null, absent, empty, or whitespace-only values are omitted, while unknown keys and non-string values are rejected. There is no endpoint for arbitrary notification text, URLs, actions, or deep links.

Sanitized listener metadata uses a separate authenticated loopback route:

```http
POST http://127.0.0.1:4320/metadata
Authorization: Bearer <persisted local bridge token>
Content-Type: application/json

{"source":"openclient-ios-local","sourceEndpoint":{"protocol":"http","port":4096}}
```

Only `http` or `https` and an integer port from 1 through 65535 are accepted. Hostnames, credentials, paths, query strings, fragments, headers, SDK client configuration, and the rest of `PluginInput` are never accepted or exposed.

Public paired-device API:

- `GET /api/destination`: current nonsecret destination and opt-in.
- `PUT /api/destination`: `{ optIn, baseURL, username, profile, delaySeconds }`.
- `GET /api/status`: subscription state, unchanged destination, bounded recent job history, last bridge diagnostic, and optional `sourceEndpoint: { protocol, port, provenance }`. Provenance is `configuration` for `OPENCODE_SERVER_URL` or `plugin` for lazy plugin metadata; neither means detected, verified, or externally reachable.
- `GET /api/events`: up to 200 newest redacted records for the authenticated device plus persisted bridge timestamps and ledger-persistence status. Records contain only bounded identifiers, sanitized caption context, a directory basename, timestamps, semantic outcome/reason codes, and an optional safe push HTTP status.
- `POST /api/test`: `{ delaySeconds }` for the original delayed transport test.

All public device APIs require the existing per-device bearer token and exact PWA origin checks. Mutations require JSON and the exact browser `Origin`.

## Notification Semantics

- `busy` or `retry` followed by `idle` schedules one root-session **Session is idle** notification. Idle does not claim success.
- Repeated idle, idle without observed activity, deprecated `session.idle`, and completion after `session.error` are suppressed.
- Root completion excludes canonical sessions with `parentID`.
- Permission and question requests notify for the actual session, including child sessions.
- Real notification captions use the canonical project's current name and fresh canonical session title, for example `openclient · Improve notification captions`. Missing context from older pending/plugin payloads falls back to a project directory basename or bounded project/session identifiers with localized labels.
- Replies, rejections, session deletion, errors, and newer activity cancel applicable delayed notifications.
- Session and project titles necessarily appear on the Lock Screen when notification previews are enabled. No request title, question text, permission metadata, message content, full filesystem path, credentials, or server-supplied URL is included in display context.

The only generated native route is:

```text
openclient://widget/session?profile=legacy|v2&serverID=...&sessionID=...&projectID=...[&directory=...][&workspaceID=...]
```

Each value uses `encodeURIComponent`; spaces therefore encode as `%20`, not `+`. Legacy `/` directories are omitted, while V2 preserves them. Old `jobID`-only notifications continue to open the handoff page with the original root `openclient://` fallback.

## Storage And Limits

- `.data/vapid.json`, `.data/devices.json`, and `.data/bridge-token` are private, gitignored persistence. Never delete `.data/` during an upgrade.
- Existing device records without destination settings load as opted out.
- Pairing, tests, bridge ingestion, device count, request body size, pending timers, queue size, dedupe history, and displayed history are bounded.
- Push endpoints remain restricted to known Apple, Mozilla, and Google services.
- Pending jobs are intentionally in memory and do not survive a Node restart.
- Redacted event history is stored separately in `.data/events.json` with mode `0600`. On startup, historical `scheduled` records become `interrupted` with reason `companion-restarted`; notifications are never replayed. Deleting a paired device also deletes its ledger.
- “Accepted by push service” means the remote push service accepted the request. It cannot prove that iOS displayed it.
- Context is normalized to one line, stripped of control and bidirectional override characters, Unicode-safely capped at 80 project and 120 session characters, and shrunk or omitted before the canonical target if needed to stay below the safe Web Push payload budget. An oversized target is rejected with a bounded diagnostic rather than scheduled.

After updating public files, restart the Node companion so it serves `notification-pwa-shell-v9`; existing installed PWAs update their service worker without reinstalling or pairing again. Restart OpenCode separately only when the plugin bridge changed. Do not delete `.data/`.

## Verify

Tests inject fake senders and temporary data directories. They never send a real notification or modify `.data/`.

```bash
npm test
npm audit
```

The plugin can be smoke-imported with the repository-local Bun, without starting OpenCode:

```bash
../OpenClientPlugin/node_modules/.bin/bun -e 'import plugin from "../OpenClientPlugin/dist/index.js"; console.log(typeof plugin)'
```
