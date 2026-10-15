# Native DSH prototype

The existing OpenClient UI can run against DSH through `DSHBackendFactory`.
The separate `DSHClient` target uses the same UI with a DSH-only composition.
The adapter targets the installed **DSH 0.2.0-rc.2** wire contract.

## Launch

In the **DSHClient** app, paste the full URL printed by `dsh web` into the secure
**DSH launch URL** field and tap **Connect to DSH**. For tailnet access, use the
trusted Tailscale Serve hostname rather than the server's loopback address.

Successful login is saved as one device-local Keychain record. The app reconnects
on the next launch. Disconnect returns to the login screen while retaining the
saved server; **Sign Out** deletes its credentials and closes the connection.
An invalid/expired login can be replaced with a fresh launch URL. A failed login
does not overwrite the previous saved login. Keychain failures are surfaced.

Codex/provider authentication remains owned by DSH: use **Open DSH in Browser**
from the saved-server screen to access the web interface and configure providers.
This explicitly opens the authenticated launch URL in your browser; the app never
collects your ChatGPT password or an OpenAI API key.

For developer automation, a process environment variable is still supported:

```text
OPENCLIENT_DSH_URL=https://your-host.example/?token=<current DSH launch token>
```

Use a local, unshared Xcode scheme or inject the variable with `simctl launch`.
Do not commit the token. The URL activates the DSH backend and automatically
connects through the normal connection coordinator. Without this variable the
OpenClient app uses its usual composition. OpenClient Release builds ignore it;
the separate DSHClient target uses it in both configurations.

For the separate target, select the **DSHClient** scheme. Its bundle
identifier is **com.ntoporcov.dshclient** (confirmed in ASC), version **0.1.0 (1)**. It installs beside
OpenClient with an independent app sandbox and private Keychain group. Both Debug
and Release builds select DSH; missing configuration shows the login screen
rather than selecting an OpenCode backend. The environment variable is optional.

The user-facing app name is **OpenClient**, with `DshIcon.icon` as its app icon.
Support and privacy-policy links are shared with the existing OpenClient app.
The internal target, scheme, and product remain `DSHClient` to keep build outputs
distinct. The ASC bundle identifier is confirmed as `com.ntoporcov.dshclient`.

Target identity and build configuration live in `project.yml`, with localized
bundle/privacy copy and entitlements under `DSHClient/`. This target embeds no OpenClient
extensions, has no OpenClient URL scheme, and requests no OpenClient app group.
Its UI test target is `DSHClientUITests` and reuses the read-only DSH navigation
test. No ASC record, provisioning profile, or upload lane is created here.

If the identity changes, update the DSH bundle identifiers, validation
script, Keychain Info.plist entries and entitlement together in `project.yml`
and `DSHClient/DSHClient.entitlements`; update the display name translations in
`DSHClient/InfoPlist.xcstrings`. Signing uses the existing local team override.

The token is exchanged at the server root for an authority-bound cookie. HTTP
RPC and the WebSocket use the same ephemeral URLSession. Neither the token nor
cookie is written into OpenClient settings. DSHClient stores the launch credential
only in its private Keychain; cookies remain ephemeral and are reacquired on
reconnect. A Tailscale Serve hostname must be in DSH's trusted-host list.

## Implemented boundary

- Workspace snapshots → shared project navigation.
- Add Project registers an existing host directory with `workspace/create`.
  Browse-capable hosts use `directoryPicker/list`; native-chooser hosts (including
  the current Mac setup) accept an absolute path in the shared directory field.
  The server validates the path on selection and returns an existing workspace
  unchanged when already registered. This flow does not create filesystem folders.
  When the host reports `directory-picker/unavailable`, the picker explains how
  to enable browsing and retains manual absolute-path entry.

### Remote directory browsing requirement

DSH's automatic directory picker chooses native mode for a local macOS launch
bound to loopback. A Tailscale Serve reverse proxy does not change that boot-time
decision. For remote clients, replace the automatic/native picker composition
row with `@deepseek-ai/dsh-host-directory-picker-browse`, then restart DSH and
reopen Add Project. Do not compose both: they register the same service.

The installed adaptive-picker documentation confirms the composition swap, but
does not expose a model-facing self-configuration action. A future model-help
button should prepare a request to inspect the installed host composition and
identify its supported persistent override; it must not claim that submitting a
prompt has enabled browsing. An automatic configuration button awaits a verified
configuration path and restart workflow for the installed DSH distribution.

### App Store Connect / TestFlight

Use the DSH-specific lanes with a UTF-8 locale:

```sh
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios dsh_latest_testflight_build
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios dsh_archive
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios dsh_beta
# Retry a failed transfer using the existing exported IPA:
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios dsh_upload
```

`dsh_beta` reads the DSH target's marketing version from `project.yml`, queries
App Store Connect for `com.ntoporcov.dshclient`, sets only that target's build
number to the latest uploaded build plus one, regenerates the project, archives
the `DSHClient` Release scheme, and uploads the exported IPA to TestFlight.
It uses the existing ignored Fastlane API-key environment and local signing
override. Outputs are isolated under `build/fastlane/dsh/`; derived data is
`build/dsh-derived-data/`. Run uploads serially so two jobs cannot reserve the same
build number. Upload does not submit for App Review or distribute externally;
Apple processing continues after Fastlane returns.
The upload lane verifies the IPA bundle identifier and uses a space-free temporary
directory under `build/fastlane/dsh/tmp` to avoid Fastlane/altool shell quoting
failures with macOS paths such as `Library/Application Support`.

### Account setup and connection form

The development host now runs DSH through the user LaunchAgent
`~/Library/LaunchAgents/com.ntoporcov.dsh.plist` (`com.ntoporcov.dsh`). It starts at
macOS login and restarts on exit, keeping the loopback port 3080 and existing
Tailscale Serve entry. Logs are in `~/Library/Logs/DSH/` (private directory;
stdout contains the process launch URL). Restart with
`launchctl kickstart -k gui/$(id -u)/com.ntoporcov.dsh`; inspect with
`launchctl print gui/$(id -u)/com.ntoporcov.dsh`. This is a per-user login service,
not a pre-login system daemon. The plist pins Node v26.10.0; update its executable
and PATH if that installation is removed during a Node upgrade.

The Add Connection form shares OpenClient's icon picker and supports an optional
connection name, a common server URL, and horizontally selectable authentication
cards. Token mode accepts a separate secret field or a full launch URL; finishing
URL editing separates a launch link into its origin and token. Account mode shows
username/password fields. Name and icon metadata are saved by sanitized origin in
UserDefaults only after successful connection; authentication remains in Keychain.
When a login is saved, the connection screen opens with its named/icon row rather
than the editor. Tap the row to reconnect, Edit to update it, or the plus button
to open a blank editor. Cancel returns to the saved connection without deleting it.

The connection sheet supports both ordinary DSH launch URLs and username/password
login through `dsh-auth-gate` in password mode. Account credentials live in the
same private Keychain record as legacy launch credentials; existing records remain
readable. Each new account connection posts a form to `/auth/login`, follows the
same-origin launch-token bridge and keeps both cookies in the connection's
ephemeral URLSession. Passwords never enter the URL. Cross-origin and HTTPS-to-HTTP
redirects are rejected. TOTP and forced password-change flows are currently
browser-only; the native app reports an authentication failure for those accounts.

Local server setup: `dsh-auth-gate@0.16.0` in the web profile, password mode,
`cookieSecure: true`, and `publicHost: https://mini.tail3fe6db.ts.net`. Its standalone
CLI required profile-local links to the installed host's `@deepseek-ai/cordis` and
`@deepseek-ai/dsh-storage-domain` packages (not separate copies). If a future package
operation removes these links, recreate them against the active DSH installation
before running the account CLI. User passwords are stored as hashes in DSH's auth
user file, not in this repository or the profile patch.
- Workspace live ordering, renames, removals and replacement reconnect baselines.
- Activity uses a typed native status service, preloads transcript previews and
  observes running/idle updates through the same multiplexed connection.
- Session listing, creation, renaming, and title search.
- Available model catalog and reasoning effort → shared model picker.
- Agent presets from `agentPresets/list` → new-session agent picker. Broken presets
  are excluded from selection; display names remain separate from request IDs.
  Default leaves preset resolution to the server. Existing chats show their canonical
  `agentPreset` projection and available description read-only in the toolbar;
  agent switching is intentionally limited to new-session creation in this client.
- New-session Full Access toggle appears when the host permission catalog offers
  both `workspace-write` and `danger-full-access`. It starts off for every sheet,
  requires explicit confirmation to enable, and resets on connection changes.
  Off explicitly selects Workspace Write, rather than inheriting a potentially
  elevated server default. The adapter creates the blank session, executes
  `/permission <preset>` through `commands/execute`, then verifies the session's
  `permissions` projection before allowing the first prompt. Failure leaves a
  blank session and reports its ID; no prompt is sent. Server defaults are unchanged.
  Permission-catalog authentication, transport, or decoding failures fail connection
  bootstrap instead of silently hiding the toggle and inheriting an unknown default.
- Existing-session header permissions toggle uses the same `/permission` command,
  including during a running turn. Enabling requires confirmation; disabling selects
  Workspace Write. The canonical `session/control` stream updates the displayed
  mode across clients, with sequenced reads preventing older state from winning.
  Opening the header refreshes state once; unknown state disables changes and offers
  Retry. Failed writes reconcile from the server rather than optimistically rolling
  back. This changes only the current session, never the agent preset or global default.
- The chat context ring uses `contextPressure.projectedTokens ?? pressureTokens`
  divided by its canonical `contextWindow`, matching DSH's web meter. It does not
  use cumulative token usage, transcript length, or model-catalog guesses. Unknown
  capacity/usage is visually distinct from a genuine zero.
- The context sheet presents server token/cache totals, approximate composition,
  completed-step timing and throughput, last/next model and reasoning, agent preset,
  permissions and plan state, session identity/lineage, goal state, and additional
  plugin projection metadata. Unsupported cost/message totals stay unavailable;
  reasoning is already included in output and compaction summary usage is separate.
- Canonical `session/control` baselines/deltas and `session/follow` snapshots share
  one per-key sequenced state. Stale list hints never overwrite it; omitted baseline
  keys clear old values. Reconnect invalidates live metrics without discarding fresh
  follow snapshots that arrive before the new control baseline. Session updates feed
  the existing DirectoryStore and ChatFacade, including while a turn is busy.
- History via `session/follow`, older pages via `session/page`.
- Text prompt admission with caller-generated request identity; interruption.
- One authenticated `/api/remote.mux` WebSocket with independent logical streams.
- Live text/reasoning blocks and ordinary tool-call/result cards.
- Physical reconnect reopens streams and applies replacement baselines.
- Canonical human messages retain `source.rpcId`, matching optimistic UI identity.

Transport, DSH wire state, and projection live under
`OpenCodeIOSClient/Backends/DSH/`. Shared views and reducers consume normalized
values. The existing `OpenCode…` domain type names do not imply OpenCode wire
compatibility.

## MCP management semantics

DSH currently exposes MCP clients as Cordis plugin declarations, not OpenCode-style
project configuration. The native MCP surfaces in projects and chats share the
connection's current-profile inventory. **A managed toggle persists a change for
all projects, chats, and users using that DSH server profile.** It is not a
project-only or chat-only override, and the UI requires confirmation of that scope.

- `pluginInventory/list` supplies safe public inventory and read-only agent-preset
  compositions. `pluginManager/listPlugins` supplies addressability. Only exact
  `@deepseek-ai/dsh-mcp-client` declarations are included; custom wrapper plugins
  and declarations in disabled/absent bundles may not appear. Entry IDs identify
  plugins, not necessarily their configured MCP server names.
- `pluginManager/setPluginEnabled` receives the full entry ID and desired Boolean.
  Its result distinguishes applied, restart-required, overridden, failed, and
  cancelled changes. A successful HTTP/RPC response or `changed: true` alone is not
  success. The adapter rereads authoritative inventory, including after ambiguous
  write failures. Read-only/unaddressable and preset declaration rows cannot toggle.
- `enabled` is effective plugin enablement, including disabled ancestors. Fiber
  lifecycle (`active`, `loading`, etc.) is **not MCP connection health**: an active
  plugin may have failed its MCP connection. The app does not invent connection,
  authentication, tool-count, or project-inheritance statuses.
- The existing multiplexed `$events` observer delivers `plugin-manager/changed`
  invalidations. CLI/hand-edited config changes do not emit that event, so the UI
  also refreshes on entry and supports manual refresh. There is no polling or
  additional WebSocket. State and pending writes are shared across native windows.
- Configuration credentials/commands/URLs are not read or edited. MCP creation,
  OAuth, project-local settings, and per-chat tool restrictions require additional
  DSH APIs; generic plugin-management controls are not substitutes for those APIs.

## Prototype limits

- Core chat is text-only; attachment, agent mention, and skill submissions are rejected before admission.
- Permissions/questions, arbitrary plugin UI, terminal/files, widgets and
  Live Activities are not advertised as backend capabilities yet. Use DSH's web
  UI for pending interactions during this spike.
- DSH archival is not mapped onto the shared Delete operation; Delete currently
  returns an unsupported-operation error.
- Subagent history, failed-attempt presentation and compaction/rewrite presentation
  need further parity work. Activity's pending-interaction grouping awaits the
  permissions/questions adapter.
- Session follows remain retained for the connection lifetime. A session-scoped
  subscription lease should precede production use with many opened sessions.
- Sequence/index gaps fail visibly rather than appending potentially corrupt
  text. Reopening/refreshing the session acquires a replacement baseline.
- Branding, DSH-specific commerce/shortcuts, extension support,
  and release distribution remain follow-up work. The separate target is a
  development foundation, not yet an App Store-ready product.

## Verification

`DSHBackendTests` exercises wire projection and reconnect baselines without a
server. Run it with `BackendInjectionTests` on both policy-approved simulators.

`DSHMCPServiceTests` and `ManagedMCPFacadeTests` exercise MCP wire filtering,
addressability, profile-only mutation arguments, ambiguous outcomes, readback,
event/reconnect ordering, shared-window state, captured confirmations, stale
contexts, read-only modes, and OpenCode compatibility. These tests use fixtures;
they do not enable or disable real server plugins. The physical MCP smoke tests
open project/chat inventories and refresh them, optionally opening a confirmation
and **cancelling** it; they never apply a live MCP configuration change.

MCP implementation validation:

- iPhone simulator: 317 selected tests passed, including all 36 new MCP tests.
- iPad simulator: 65 selected MCP/backend/legacy-routing tests passed.
- Signed DSH Release build and strict signature/bundle-ID verification passed.
- Three other OpenCode tests failed in the initial wider run and were excluded
  from the final focused run, not counted as passes:
  `AppShellFacadeTests.testManualBrowserIsAvailableForV2WithoutAdvertisingBridgeCapability`,
  `AppShellFacadeTests.testV2RecentOpenKeepsCanonicalHydrationReadyWhenSelectionCompletesConcurrently`,
  and `ChatWindowAdapterTests.testConfigurationBarrierOrdersEveryFacadeSubmissionPathAcrossWindowsAndRoot`.
  Their failures concern bridge capability, missing skill/command fixture routes,
  and command request-body expectations respectively; those paths were not changed
  as part of MCP management.
- Physical iPhone verification: both project and chat MCP smoke tests passed
  (2 passed, 0 failed, 0 skipped) after installing the latest signed build.
  Both surfaces loaded and refreshed canonical empty inventory. No standard MCP
  entries were exposed, so no live toggle/confirmation was exercised and no MCP
  configuration was changed. Screenshots confirmed readable scope/empty-state
  text after strengthening contrast in the translucent chat panel.

`DSHLiveTests` is explicitly opt-in through the **test process** environment
variable `DSH_SMOKE_URL`. It creates one labelled smoke-test session, sends one
small Codex request, checks incremental delivery, and reconnects through a fresh
native backend to compare canonical history. It leaves the labelled session
available for inspection. No existing conversation is modified.

`DSHPrototypeUITests` attaches to a prelaunched prototype and opens an existing
smoke-test conversation through workspace/session navigation. It sends no prompts.

Validated on 2026-10-02 with Xcode 27.0 and iOS 27.0:

- iPhone 18 Pro Max: projection/backend regression tests, live Codex streaming and
  fresh-connection history comparison, and native navigation/history UI passed.
- iPad Pro 13-inch (M5): the same checks passed.

Live tests used the tailnet HTTPS endpoint and the configured Codex subscription.
Physical network-drop recovery and native permission/question handling remain
outside this verification.

The separate DSHClient Debug target was also installed alongside OpenClient on
both simulators and passed `DSHClientUITests/DSHPrototypeUITests`. Its bundle ID,
independent version, and absence of embedded OpenClient extensions were checked
in the built app. Localization lint includes the target-specific InfoPlist catalog
and the shared compiler-emitted UI catalogs.
The DSHClient Release simulator build also passed for both destinations.

Login validation on both simulator classes additionally covers isolated Keychain
save/read/update/delete, invalid and expired credentials, persistence failure,
and sign-out while a connection is in flight. Native UI tests confirmed that a
saved login reconnects after relaunch with no environment variable, and that
sign-out survives relaunch and returns to the secure login form.

Workspace/Activity validation covers registry replacement, ordering, renames,
removals, explicit membership precedence, native status hydration, transcript
previews, live busy-to-idle transitions and removal from Recent. Live UI checks
on both simulator classes opened the populated DSH Activity page and then the
existing workspace/session history without sending new model requests.

## Protocol references

- [Connection RPC/authentication](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/client/connection)
- [Typert gateway and stream framing](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/gateway)
- [Session controller](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/session-controller)
- [Workspace controller](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/api/workspace-controller)

These upstream links move; installed package declarations and observed traffic
for the pinned DSH version are the compatibility reference for this spike.
