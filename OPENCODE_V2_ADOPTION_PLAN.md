# OpenCode v2 Implementation And Verification Guide

## Current Handoff: September 9, 2026

The user-approved public policy is **automatic detection by default and only**, with no API picker. This supersedes earlier Legacy-default and explicit Experimental/v2 opt-in instructions. The separate remote release rollout flag remains **Track Later**; implementing that flag is not required for this approved default change. OUR v2 plugin/native bridge/browser automation remain explicitly deferred until OpenCode v2 release and settled contracts.

Main's final source-verification run `cold-scroll-unit-final.xcresult` reports **1,383 passed, 13 skipped, zero failed per device** on the required iPhone and iPad simulators. The known unrelated `ResponseTurnCaptionTests/testCaptionOccupiesSpaceOnlyWhileRevealed` failure is explicitly excluded, not passing. Accounting: 1,396 reported outcomes (1,383 passed plus 13 skipped), plus one excluded = 1,397 including the exclusion; skipped tests were not executed. This supersedes `auto-detection-final-unit-1` (1,382 passed, 13 skipped, one excluded) and the earlier 1,372-pass handoff. `auto-detection-final-ui-1` passed **three automatic-connection UI tests per device**. This is not an unqualified all-green suite claim.

The real-app cold-position bug consumed the initial-bottom token before the collection had usable bounds. `ChatView` now retains the pending request and retries after layout, marks the token handled only after success, and cancels pending positioning on user drag. `cold-scroll-before` reproduced **-54 versus expected 200**; `cold-scroll-after` passed **13 tests on each simulator**.

Full five-native-composer-turn core acceptance passed on the **iPhone simulator** in `acceptance-next17155-gjs5t1i_/acceptance-ui.xcresult` and the **iPad simulator** in `acceptance-next17155-rxm_tpkk/acceptance-ui.xcresult`, in separate runs. After the fix, normal cold relaunch shows the latest canonical content among five user/five assistant messages, without test scrolling or refresh. The final combined run's **iPhone test failed in Photo Picker: no selected item and Done disabled**. Preserve that failure; these separate passes are not a new clean combined matrix.

All fixture processes are reported stopped; no personal-server or paid-provider calls were made. Manual widget execution, actual Share-host invocation and Shortcuts were not tested; the user will check Shortcuts. Main confirmed current localization lint **passed for 1,492 entries across seven catalogs**; the cold-position fix adds no copy. This documentation pass did not rerun lint.

Main confirmed a fresh `iphoneos` build in `.derived-data-device` succeeded, strict code-sign verification passed, and `devicectl` installation of `com.ntoporcov.openclient` on Nic iPhone **SUCCEEDED**. Log: `auto-detection-device-build.log` under the approved temporary opencode directory. The automatic-detection/cold-position build is **now installed**, superseding the Thinking-sequence baseline. **Launch FAILED because the phone was locked**; unlock the phone and open OpenClient manually. Prior positive feedback applies to the previous build, not hands-on validation of this one. This handoff edits only the four requested Markdown files, with no source/script code, builds, tests or server calls. No commit or push was requested; obtain the current user's approval before committing.

## Optimistic Send Presentation (Historical: September 8, 2026)

Transcript continuity follow-up restores the one-shot composer-entry slide for newly staged Legacy and v2 messages. Per-row entry signatures and stable hosting identity preserve the animation through exact-ID canonical replacement. Ordinary insertions, deletions, response-caption changes and streaming-chunk completion use serialized incremental collection updates rather than whole-transcript reloads. A drag-generation guard prevents batch completion from overriding a user's intervening history scroll. The 1.5-second status delay and canonical/admission boundaries are unchanged. Final focused validation in `transcript-drag-acceptance.xcresult` passed 23 unit tests plus the extended Legacy/v2 root/window UI test per required simulator; the full suite was not rerun. The device build installed successfully, with launch blocked by the locked phone.

Follow-up polish delays the entire status row until 1.5 seconds after the original send, with zero reserved height before that deadline. Confirmed admission suppresses the row entirely; unresolved sends then receive the two-second visual progress animation. The thinking placeholder appears immediately without awaiting HTTP completion and yields to visible assistant content. Focused validation (`optimistic-send-polish-validation.xcresult`) passed 16 unit and five UI tests per required simulator. The corrected phone build installed successfully; automatic launch was blocked by the locked device. The full suite was not rerun for this follow-up.

The large composer recovery card is replaced by an optimistic user bubble in the displayed transcript, with a two-point progress indicator and Show status. The two-second animation approaches 94% without asserting delivery; actual admission controls completion, and Reduce Motion uses a static decoration. Local presentation anchors include preceding canonical and local submission IDs so queued inputs keep their order as earlier inputs become canonical. These display rows remain outside canonical stores, disk caches, and admission evidence; status checking never resends. This supersedes earlier descriptions of a separate composer recovery card.

Focused validation in `optimistic-send-anchor-fix.xcresult` passed 12 unit and three UI tests on each iPhone 17 Pro Max and iPad Pro 13-inch (M5), iOS 26.3.1, Xcode 26.3. The earlier full-suite run also contained an unrelated response-caption layout test failure; it was not changed or represented as passing. Shipping-bundle localization validation and the fresh device build/signing passed, and the polished build installed and launched on Nic iPhone. The selected-session deletion crash investigation remains paused at the user's request, with its existing candidate unchanged.

## History Disclosure Correction (Historical: September 8, 2026)

Session-list pagination requires the same terminal-page check independently of message history. `listV2Sessions` now clears continuation on short pages and checks one record beyond full pages while retaining the original cursor and its filters. The shared path covers main and workspace session lists. Verification: `session-list-fix-unit-2.xcresult` records 1,239 passes and 13 opt-in skips per simulator; `session-list-fix-ui-4.xcresult` records one pass on each required simulator. Live UI covers two terminal roots and 52 roots loaded as 50 plus two; live GETs also confirm the exactly-50 terminal boundary. The corrected phone build installed successfully; automatic launch was blocked by the locked device.

The next-17155 message endpoint emits cursors on every nonempty page, including terminal pages. Cursor presence alone does not establish older history. Short pages terminate; full pages use one read-only `limit=1` existence check while preserving the original opaque continuation cursor. A failed check preserves the continuation, and cancellation propagates. Hidden metadata does not count toward disclosure controls, and history loads report actual newly added canonical message IDs rather than the requested render-window size.

Verified on iPhone 17 Pro Max and iPad Pro 13-inch (M5), iOS 26.3.1, Xcode 26.3: 1,234 unit tests passed and 13 opt-in live tests skipped per device (`history-fix-unit-1.xcresult`); two focused UI tests passed per device (`history-fix-ui-2.xcresult`). UI covers terminal short/long answers and revealing two genuinely hidden messages. Live API checks cover exact 200-message termination and a 202-message continuation without consuming the probe row. Bundles are in the approved temporary opencode directory. The fresh corrected device build was installed and launched on Nic iPhone.

Last updated: September 9, 2026. History-disclosure results above and dated pass-specific handoffs below are historical; the current handoff above controls latest evidence and phone status.

## Scope And Evidence

Support legacy OpenCode and the experimental `/api/...` HttpAPI in the same app without changing legacy wire contracts. Here, **v2** means the HttpAPI, not the legacy root-path API described by the upstream SDK directory named `packages/sdk/js/src/v2`.

- Pinned upstream contract: `anomalyco/opencode@41cb354c3eac138959b1a6c4690385b7c3a6d666`.
- Live-verified package contract: `0.0.0-next-17155`. This runtime differs from the pinned source; do not assume they are interchangeable.
- Current scope includes general submission recovery for Legacy and v2 and actual next-17155 scripted core UI acceptance. The user's recovery issue was Legacy. This is bounded main-reported source/verification, not committed/released/full parity; concurrent response-copy work is separate.
- Historical September 8 units: `acceptance-part-end-unit-final.xcresult`, 1,290 passed, 13 skipped, 1,303 total per device. Core UI: `acceptance-next17155-binfvy2o/acceptance-ui.xcresult`, one passed, zero failures/skips per device. Localization: 1,490 keys across seven catalogs passed. Both fresh owned simulators used stable Xcode 26.3 / iOS 26.3.1. These are not the current final counts.
- Historical September 8 recovery build/signing/install succeeded; launch failed because Nic iPhone was locked (`submission-recovery-device-build.log`). The now-installed automatic-detection build and its locked-phone launch failure are recorded above. No separate harness target exists.
- The confidence goal remains experimental "mostly works", not full parity or a two-day delivery commitment. Public automatic-only detection is now approved independently of the deferred remote rollout flag. Use [the parity checklist](V2_PARITY_CHECKLIST.md) to prioritize remaining evidence.
- **Explicit user deferral:** OUR v2 `OpenClientPlugin`, native bridge and browser automation wait until OpenCode v2 is released and contracts settle. Do not implement the plugin now or treat this decision as a current blocker. Server v2 plugin support exists; the legacy plugin function needs a future object `setup`/effect and transport port. Manual in-app browsing is separate.

## Connection Contract

- Public new connections and saved-server loading use **Automatic only**, without a Legacy/Experimental API picker. Saved user preferences `legacy`, `v2`, `automatic`, and missing preferences normalize to `automatic`; the resolved connection profile is separate. The public saved-server loader is shared by the main app and headless Shortcuts.
- Explicit internal/test overrides remain supported and are captured by the factory, not overwritten by public saved-preference migration. Internal Legacy skips the v2 probe; internal explicit v2 never falls back. These are not public picker instructions.
- Automatic probes authenticated `GET /api/health`. A valid v2 response requires `healthy: true`, a string `version`, and an integer `pid >= 0`; it selects v2, including on dual-stack servers.
- Unavailability (404, 405, successful HTML, or the recognized older minimal `{"healthy":true}` response) permits fallback to `/global/health` and legacy bootstrap. That recognized minimal response is not a valid v2 contract and is distinct from arbitrary malformed JSON.
- Authentication errors (401/403), network/TLS/timeouts, other HTTP errors, and other malformed or unhealthy responses fail the connection. No silent legacy fallback is allowed for these failures.
- Resolve before bootstrap and keep the profile fixed until disconnect. V2 bootstrap or operation failures do not switch profiles.
- **No mutations are automatically retried**, either on the same API or against another version/route. An uncertain prompt admission is reconciled with canonical reads and events, not resent.

Implementation: `Models/OpenCodeServerConfig.swift`, `Models/OpenCodeSavedServer.swift`, `API/OpenCodeAPIClient.swift` (`probeV2`), and `Coordinators/ConnectionCoordinator.swift`, under `OpenCodeIOSClient/`.

### Saved Data And Credentials

- Preference migration does not retype historical widget, Live Activity, window or cache records. Existing profile IDs remain unchanged; absent historical profiles still mean legacy. No migrated-record type or schema is introduced. Raw `serverID` and its Keychain identity remain unchanged.
- Legacy plaintext credentials migrate to Keychain only with verified readback. An existing Keychain value wins, including a deliberately blank value. Never replace it with the plaintext candidate.
- A deferred credential migration failure preserves the original persisted raw bytes. Central persistence must block metadata rewrites, save, edit, delete and remember operations while migration is unresolved, so no route can discard the only credential copy. Surface the new secure-storage error and let the user retry; failure is not permission to sanitize or overwrite the record.
- The public loader enforces this policy for both main-app and headless Shortcuts paths; explicit internal factory-captured overrides stay separate from migrated public preferences.

### Experimental Notice

After successful bootstrap, show the nonblocking experimental-v2 banner only for the actual bound v2 backend UUID. Hide it during loading, loading overlays, and inactive connection state; a stale or merely requested profile cannot show it. Dismissal is per connection lifetime, with no new persistent acknowledgement; an SSE reconnect does not reset dismissal.

Global Forms retain presentation priority. The banner does not gate chat or require acknowledgement to send. Report a Bug uses the canonical bare `https://github.com/ntoporcov/openclient/issues`, with no query or prefilled payload; Help uses the same shared Support URL in `AppSupportURLs.swift`. Notice and secure-storage error source keys/translations belong in the localization catalogs. Main confirmed current lint passed for 1,492 entries across seven catalogs; the cold-position fix adds no copy, and this documentation pass does not rerun lint.

### Offline Boundary

Experimental read-through/offline behavior under automatic detection remains unvalidated. Before a successful network probe there is no known API profile, so the client cannot read the v1 cache as a substitute when offline. This intentional known-profile boundary is not permission to fall back to legacy or relabel historical cache records. Earlier live-discovery/503-transcript cache evidence below does not validate this cold no-network path.

## Implemented Surfaces

These paths are implemented. Contract fixtures, isolated-server tests, and UI coverage are distinguished in the verification section below.

| Surface | Current behavior |
| --- | --- |
| Navigation | Location/project discovery and selection; directory-scoped session listing, creation, cursor pagination, and active status hydration. |
| Chat | Projected transcript/older pages, exact next-17155 input/assistant events, typed files/mentions and pinned inbox handling. General recovery covers Legacy and v2. Normal-mode scripted core UI verifies streaming, interruption, Photos media, background catch-up and cold transcript relaunch; not paid inference. Canonical reconciliation remains authoritative. |
| Composer configuration | Attachment URI/name encoding, agent mentions, model/variant and agent selection, catalog loading, commands with arguments/files, and session compaction. Session selection mutations are coordinated before sends. |
| Permissions | Directory/session hydration and session-scoped `once`, `always`, or `reject` replies. |
| Forms/questions | Native session forms plus pass 6 location-owned global MCP requests, reachable without a session and from chat. Typed submission/cancellation, defaults, optional/conditional fields, custom multiselect and explicit external acknowledgement use the shared engine; provider policy remains narrower. |
| Git/files | Branch information, file status, working/branch diffs, file listing/search, raw text/binary reads, and enabled workspace picker. This is not general Git mutation support. |
| MCP | Status listing and server connect/disconnect. |
| Project discovery/workspaces | Typed directory browsing/resolution, inventory, copy creation/removal/refresh, destination cancellation and new-chat navigation. Runtime-specific limits are below. |
| Project appearance | Read-only for v2: next-17155 lacks the metadata writer. Do not advertise full v2 project PATCH support; legacy metadata editing remains separate. |
| Project actions | Editor/chips and non-destructive owned-run orchestration in both profiles. Server sessions are retained; local hiding/journal recovery is not server archive. Paid two-turn execution remains untested. |
| Session lifecycle | Rename, delete, and fork; fork uses `through` for the current end or `before` a specified message, not subagent-parent semantics. |
| Home/configurations | Configurations/local settings, Activity, Home session search, quick new chat, and session previews restored. Reads use core services plus OpenCode-specific hydration where needed; no arbitrary server configuration writes. |
| Provider integrations | Typed v2 integration discovery, API-key connection, OAuth `auto` and `code` attempts, attempt status/cancellation, and stored-credential removal. No legacy auth endpoints or fallback. See the integration boundary below. |
| Plugins | Plugin listing preserves the runtime's available metadata. Missing runtime state is shown as unknown, not inferred to mean active or successfully loaded. |
| Terminal/PTY | Standard `/api/pty` CRUD, native authenticated WebSocket connection, resize, UTF-16 cursor replay, and normal-exit handling. Stale responses from a previous server cannot update the new connection. |
| Read-through cache | Isolated v2 namespace; unchanged legacy disk keys and SwiftData schema. Cached transcript presentation plus guarded canonical HTTP reconciliation, not fully offline navigation. |
| Widgets | Profile-owned snapshots/routes plus typed v2 new-session/command actions with canonical target/catalog validation, create-once checkpoints and admission/metering ownership. No fallback/fabricated commands; valid-command execution remains unverified. |
| Live Activities | Profile/server/session/OS activity identity, v2 permission transport, Open App for typed forms, exact-record cold-tap admission and same-owner reconnect reconciliation. Finite background assertion, no APNs; native lifecycle UI verified, cold-process OS restore/Lock Screen/Dynamic Island not verified. |
| Fun and Games | Find the Bug (12 languages) and Find the Place use core default-directory/session/selection/setup admission with persistent profile-scoped per-session setup guards. Scripted English/Swift backend setup/answer smoke passes; native gameplay UI remains untested beyond chooser/cancel. |
| Detached chat | Dedicated `ChatWindowContext` and real per-window facade isolate presentation state while sharing canonical stores and one event source. Explicit profile/canonical directory/workspace routes; native iPad two-view editing verified. Not independent primary app-shell copies or verified OS restoration. |

### Pass 3 Corrections (Historical)

Historical gates in passes 3-7 below describe those passes only. Pass 8 supersedes widget mutation, game, Live Activity and dedicated-window gates; the plugin is explicitly deferred, not the next implementation task.

- Model variants come from explicit catalog variant IDs even when `capabilities.output` contains only `text`; variants do not falsely imply reasoning output. Legacy reasoning-capability gating is unchanged. Millisecond `time.released` is preserved as an ISO-8601 `releaseDate` so age-based model visibility works.
- Subagent HTTP and live tool metadata preserve agent identity and child `sessionID`/status. Child navigation uses metadata, not output-text parsing or legacy title heuristics; a completed background tool does not imply its child session finished.
- V2 provider presentation reuses the v1 `ProviderConfigurationRow`, provider branding, grouping/search conventions, and authentication summaries. Transport and typed v2 forms remain separate; visual reuse does not mean legacy auth fallback.
- Activity, Home search across catalog scopes, quick new chat, and canonical/live row previews are restored, including injected-core paths. Connection/scope guards reject stale results after navigation or reconnect.
- Pass 3 blocked v2 persistent caching; pass 7 supersedes that gate with isolated read-through caching below. Pass 5 enables validated Share handoff; failed routing retains its payload, and consumption occurs only on successful handoff to the owned sheet.
- Pass 3 gated project actions. Pass 4 supersedes that gate with the typed-command and non-destructive owned-run flow described below; game/widget actions are not enabled by this change. Share is a separate pass 5 integration.

### Pass 4 Workspaces And Actions

- `BackendConnection` now has optional typed `commands`, `projectLifecycle`, `worktrees`, `worktreeReset`, and `sessionForms` services. UI/action availability follows actual service support, not capability names alone. The production factory wires these services; this is not only a mock injection seam.
- The factory enables copy management for the exact verified runtime `0.0.0-next-17155` (and legacy's own implementation). V2 inventory uses `GET /api/project/:id/directories`; create/remove use `POST`/`DELETE /experimental/project/:id/copy`, and refresh uses `POST /experimental/project/:id/copy/refresh`. Do not substitute the pinned/newer `/api/worktree` contract or probe mutation routes.
- V2 creation requires an explicit absolute destination parent. Its optional copy name is not proof of v1 named-branch/startup behavior. Local Git roots and managed copies are distinguished; dirty removal requires an explicit force decision, never an automatic retry. Removal retains server sessions. Inventory refresh is not destructive reset.
- Project resolution preserves the selected clone root and the server's distinct canonical path across reconnect. Workspace session loading/pagination uses core session APIs with scope/cursor guards; Files exposes the workspace picker. Directory selection/discovery is implemented, not arbitrary repository initialization or complete browser integration.
- `ProjectActionCoordinator` and `ProjectActionStore` own run sequencing and the scoped journal. Both profiles retain server sessions, hide only owned runs locally, reveal attention/failure/interruption, and expose `recoverActionRunHistory`. No delete fallback or archive simulation is used. HTTP acceptance or idle alone cannot establish success: the coordinator requires canonical completed-turn evidence and a run-specific evaluation result.
- The full two-turn action coordinator is mock-tested. Actual paid command-plus-evaluation execution is **not tested**; the real-server command test exercises the production encoder with `resume: false` and verifies the owned pending receipt without provider execution. Widget/game wiring was added separately in pass 8; Share handoff in pass 5.

### Pass 5 Integrations And Legacy Fix

- Foreground Talk uses core session creation/submission, canonical chat hydration and queued selection coordination before POST. Uncertain admission retains its message identity; permission/form/paywall/navigation/connection/audio guards remain. UI evidence covers availability and cancellation without recording, not actual ASR/TTS or provider-backed voice turns. Pass 8 adds Live Activity transport separately.
- Shortcuts/App Intents use typed short-lived connections without SSE, optional `sessionSelection` before POST, and persisted unresolved-operation ownership/read reconciliation without reposting. Pass 7 closes the first-100 pagination and canonical destination revalidation follow-ups. Locks remain process-local, not cross-process atomic. Historical isolated-server discovery/create/model-selection tests did not send prompts through the Shortcuts host.
- Share uses core services and session/selection checkpoints, exact saved-configuration and destination validation, retained edits/paywall drafts, and explicit rejected-input retry without recreating the session. Uncertain admission is reconciled, not reposted. UI tests seed payload storage and deliver URLs through the system; actual share-extension invocation and provider-backed sends remain unverified.
- Manual browser UI is enabled independently of the native bridge. WebViews/history/title ownership are scoped by connection lifetime/project/directory; one nonpersistent WebKit data store is replaced on reconnect, and requests do not inherit OpenCode auth. Native bridge browser automation remains gated.
- Major legacy regression fixed: `OpenCodeManagedEventBatcher`'s scheduled timer called `flush()`, which cancelled its own task; backend cancellation guards then discarded delivered events. `API/OpenCodeEventManager.swift` now clears the timer handle in `flushScheduledEvents()` before flushing. Two regressions in `OpenCodeStreamingTests.swift` cover uncancelled timer callbacks and directory/active-transcript updates without refresh. The separate v2 input/inbox mismatch, addressed in pass 7, was not its cause.

### Foreground Reconciliation

The shared foreground coalescer refreshes the active chat even when the retained SSE connection is healthy. Activation invalidation and per-session latest-HTTP-request guards reject slow/out-of-order snapshots, stale selections, and replaced connections. This supplements the shared event pipeline with lifecycle-triggered canonical reads, not polling or mutation retries. Unit coverage includes suspended prior activation and out-of-order responses. Earlier UI used a snapshot proxy; latest normal-mode acceptance additionally verifies actual-runtime background completion and foreground catch-up without pull.

### General Submission Recovery

The user's actual issue was **Legacy**, not only v2. Before scripted acceptance, the real adapter regression reproduced `POST /session/.../prompt_async` returning 408, newer canonical live messages, then a GET missing the original input. The old merge left the unknown original at the tail as a normal message. Retained submission payload is now separate from canonical transcript; queued/uncertain cards perform status GETs only, never automatically POST again.

Same-owner reconnect, keyed by raw server identity and resolved profile with session/scope ownership, retains unknown text, files, mentions and original message ID in process memory. Foreign scopes remain isolated. **Recovery does not persist across actual app kill; no database was added.** Exact canonical evidence overrides old local-prefix assumptions. Optimistic rows, disk cache and widget admission ledgers cannot falsely confirm admission; canonical evidence remains preserved despite local ledger changes. Existing persisted shortcuts/checkpoints/read-through caches are separate mechanisms.

Source/unit evidence uses the real adapter with mocked 408 responses; seeded root and dedicated-window UI verifies recovery in both profiles. This is not personal-server restart evidence or proof of physical-phone symptom resolution.

### Core Acceptance Fixes

New Session awaited execution and hid streaming behind its sheet; it now returns after admission with a guarded completion-reconciliation task. Unfinished HTTP responses with empty bodies erased live deltas; preservation now applies only to a matching unfinished live-owned part. Completed canonical content wins, including a completed part within an ongoing message. These are production fixes, not fabricated UI streaming or optimistic state promoted to canonical evidence.

### Backend Injection Boundary

`OpenClientComposition(backendFactory:)` forwards to `AppViewModel(backendFactory:)`. `BackendFactory.connect()` returns a fresh `BackendConnection` with typed project/session/chat/model services and one event source. The normal iOS and macOS roots still construct the default composition; no second product target exists. See [Backend Injection](BACKEND_INJECTION.md) for the actual protocols, a short composition example, and separate-product identity requirements.

`BackendInjectionTests.testFullFacadeFlowUsesInjectedBackendWithoutAnOpenCodeClient` exercises core navigation, catalog selection, transcript hydration, create/send/live updates/interrupt, search, rename, delete, and previews using an in-memory harness. Pass 4 adds typed optional services for commands/actions, project lifecycle/worktrees/reset, and session forms; pass 5 adds session selection and optional pending-input read evidence. This is real service injection through facades, not proof that every feature is harness-agnostic. Remaining OpenCode-only features use `OpenCodeBackendAdapter` and `requireOpenCodeClient(for:)` guards. V2's event sink still performs specialized projection and revision-guarded canonical reconciliation; it is not fully normalized into generic backend mutations. Incomplete generic extraction is a backend-injection limitation, not automatically a missing v2 feature.

### Session Form Boundary

Pass 4 replaces the narrow session-question presentation with native forms backed by `BackendForm`, `SessionFormStore`, and `SessionFormCoordinator`. The shared engine supports `string`, `multiselect`, `number`, `integer`, and `boolean` values, optional/default fields, supported `eq`/`neq` conditions, and custom multiselect values. Hidden values/defaults are omitted, not leaked into answers. External links require explicit acknowledgement; opening a link is not completion.

Session pattern/format metadata is preserved with server-authoritative validation rather than pretending Swift validation matches JavaScript. Unknown fields/constraints remain explicitly unsupported, not silently flattened. Typed answer/cancel operations reconcile canonical form status after uncertain outcomes without mutation retry. Session HTTP hydration and socket/event delivery are covered; pass 6 adds global MCP elicitation below.

### Pass 6 Global Requests And Guard

- `Facades/GlobalFormsFacade.swift` owns stores by canonical `BackendFormLocation` (directory plus workspace) within one connection lifetime. `BackendGlobalFormsService` extends `BackendSessionFormsService`; `BackendConnection.globalForms` is a computed optional conformance, not a second independent service slot.
- `API/OpenCodeAPIClient.swift:listV2GlobalForms` reads `GET /api/form/request`, filters `sessionID == "global"`, and retains the response's canonical `location`, including default-location/explicit-scope aliases. Immutable `BackendFormReference` origins carry `location[directory]` and `location[workspace]` through `GET /api/session/global/form/:id`, `GET /api/session/global/form/:id/state`, `POST /api/session/global/form/:id/reply` and `POST /api/session/global/form/:id/cancel`. No active-project substitution or mutation-route fallback.
- Bootstrap, scope changes and reconnect canonically hydrate through the shared SSE pipeline. Located global events update their owner; missing-location events invalidate/reload known stores and default inventory, never assign the request to the active project. Connection/request/store revision guards and settlement tombstones reject stale resurrection. The review fix schedules a fresh canonical read when overlapping default/explicit hydration or local settlement causes store replacement to be refused; cancelled stale reads do not retry.
- `Views/Shared/GlobalFormsView.swift` exposes a native Project Requests sheet through the root/sessionless project flow and chat. Close preserves location-owned drafts; submit/cancel settles the current request and advances to the next. New-input gates preserve busy stop/interrupt and active dictation/conversation stop controls. `AppViewModel+Sessions.swift:sendV2TextPrompt` refunds only the unowned prepaid allowance if a late global request blocks the attempt before POST, without refunding an existing admission owner or another day's reservation.
- Pass 6's `Facades/LiveActivityFacade.swift:startConfig` centralized manual/toggle/auto-start capability/profile checks, initially excluding v2. Pass 8 supersedes that v2 gate with profile-owned transport below; unsupported injected and closed connections remain guarded and credentials come from the owner, not stale saved configuration.

Research boundary: lead-reported pass 6 source/TUI and runtime-contract research covered the [pinned revision](https://github.com/anomalyco/opencode/tree/41cb354c3eac138959b1a6c4690385b7c3a6d666) and [next-17155 package](https://www.npmjs.com/package/opencode-ai/v/0.0.0-next-17155), with global-request handling found in TUI Home and chat. These are contract/research references, not verified exact web-presentation links. The native sheet is an explicit iOS adaptation preserving location ownership, typed answers and request lifecycle; exact web visual parity was not established. Actual MCP external-URL completion notifications were not exercised; opening a link alone is not completion.

### Provider Integration Boundary

Provider integration forms now reuse the shared form engine with a deliberately narrower provider policy. Existing GitHub Copilot public/enterprise support includes simple `eq`/`neq` conditions, supported defaults, optional/required fields, and supported constraints for `string`, `multiselect`, `number`, `integer`, and `boolean` values. Provider custom multiselect, session external acknowledgement, and pattern/format metadata are not thereby enabled for provider forms. Hidden fields are omitted; server validation remains authoritative.

API-key writes and OAuth `auto`/`code` attempt workflows, cancellation, and stored-credential removal stay on the v2 integration/credential contract. External/environment-managed and command-based authentication are not native connection workflows; environment credentials cannot be removed through stored-credential deletion. Complex conditions, unsupported field types/metadata or validation constraints remain explicitly unsupported rather than flattened. Arbitrary custom-provider creation and general server configuration writes are not implemented; the writer contract remains unverified, not confirmed absent.

Provider authentication and credential mutations are validated with mocks and contract fixtures only. No actual personal provider sign-ins or real provider credential writes were performed in this pass.

### Pass 7 Scoped Adoption

- Shortcuts session discovery follows cursors beyond 100 with deduplication/repeated-cursor protection. `OpenCodeShortcutService` freshly validates canonical session ID, directory, workspace, root status and project before mutation, including selection and prompt paths. The captured resolved profile owns operation hashes/locks, not a changing saved negotiation preference; original legacy pending hashes remain compatible. Read reconciliation does not repost. `ShortcutPendingOperationStore` locks are process-local only.
- Runtime source/public OpenAPI research confirms next-17155 `session.input.admitted`, `session.input.promoted` and `session.input.cancelled`, not `session.input.delivered`. `OpenCodeManagedV2Event` decodes materialized input files and agent mentions; `ChatStore` preserves admission versus transcript promotion and pinned `session.inbox.*` behavior. Exact assistant step/text/reasoning/tool fixtures cover projection without model inference. Main's confirmed final unit run includes the action-source spelling correction to `session.input.promoted`.
- Next-17155 public runtime OpenAPI has no canonical todo endpoint/event; source research found only old migration references. Keep canonical todos gated on this runtime, never infer them from tool outputs. This evidence does not establish absence in all future versions.
- `OpenCodeLocalCacheIdentity` uses a separate v2 namespace, including workspace scope, without changing legacy disk keys or migrating the SwiftData schema. `testOnDiskV1LegacyRecordsRemainReadableBesideV2AndTombstones` passes. V2 disk rows are presentation-only, not canonical IDs, admission evidence or validated history; accepted canonical HTTP transcripts drive writes. Older-page disk ordering and cold hydration races are fixed: disk presence does not suppress a fresh HTTP read, canonical empty wins, and recovery clears only the owned 503 error.
- Cache UI coverage keeps discovery live while transcript HTTP returns 503. It verifies cold cached transcript presentation and later reconciliation, not fully offline navigation or a cold disconnected v2 bootstrap. Connection/lifecycle/revision guards and namespace isolation remain required.
- `OpenCodeProfileIdentity`, widget snapshot publication/storage, extension readers and existing-session deep links carry explicit resolved profile ownership. Old missing profiles remain legacy; unknown values fail closed. Authoritative empty catalogs clear owned stale entries, separate from not-refreshed inventories. Pass 8 adds typed command/new-session actions to this pass 7 read boundary.
- Pass 7's `ChatWindowRestorationCoordinator` validated the actual legacy adapter's server ID and canonical session/directory, rejected conflicting cached ownership and invalidated on connection-lifetime changes. Pass 8 extends admission and adds dedicated per-window state below; OS restoration remains unverified.

Those were bounded pass 7 closures. Pass 8 supersedes the game, widget mutation, Live Activity transport and per-window implementation gaps as follows; plugin work is explicitly deferred by the user.

### Pass 8 Ownership And Integrations

- **Live Activity identity:** `OpenCodeShared/OpenCodeChatActivityAttributes.swift` persists resolved profile, server/session ownership, project ID, canonical directory and workspace; actions also match the exact OS activity ID. Missing persisted profile means legacy, unknown profile fails closed. Canonical directory is preserved even for Global; separate `requestDirectory` makes legacy Global transport unscoped without destroying identity.
- **Live Activity transport/lifecycle:** `OpenCodeLiveActivityActionClient`, `LiveActivityFacade` and `LiveActivityBackgroundBridge` implement v2 permission replies and typed-form Open App routing, never flattening forms into legacy `[[String]]` answers. Background work uses a finite assertion, not APNs or indefinite execution. Cold-tap routing matches the exact OS record, connects to or joins the saved server/resolved profile, hydrates canonical session and pending permissions, and rechecks ownership after awaits. Same-owner reconnect retains/reconciles activities instead of stopping all. Real native ActivityKit start/retain/reconnect/stop passed UI on both simulators; cold-process OS restoration and Lock Screen/Dynamic Island behavior remain unverified.
- **Widget actions:** `AppViewModel+DeepLinks.swift` routes new-session/command actions through typed backend services and canonical target/catalog validation. No alternate mutation routes or fabricated commands. Checkpoints create once and match exact session/message admission. Canonical acceptance wins over late rejection even after admission-ledger pruning; accepted reservations are not refunded. Reservations are one-shot and capture their commerce owner/day. Same-owner settled completion retires the handoff on reconnect, and all route errors are owned. UI verifies new-draft cancellation and missing-command handling, not execution of a valid command.
- **Games:** `FunAndGamesCoordinator` and `FunAndGamesStore` implement Find the Bug's 12 languages and Find the Place through core default-directory resolution, session creation, selection barrier and hidden setup with stable input identity. Uncertain setup reads canonical transcript/pending evidence without reposting. Profile-scoped per-session rejected setup persists so returning to an old session cannot become an unmetered ordinary send. Mock game flow is verified; chooser/cancel UI is not actual provider execution or gameplay.
- **Dedicated chat windows:** `Coordinators/ChatWindowContext.swift`, `ChatWindowRestorationCoordinator` and window-bound `ChatFacade` isolate selection, draft/attachments, focus, navigation/history, hydration, form editing, browser and errors. Child contexts and scoped MCP/todo refresh use the window's owner. Canonical session/chat stores, connection, session model-configuration barrier and one shared event source remain shared. MCP still uses OpenCode compatibility; this is not generic all-harness independence. Audio leases prevent an inactive window from deactivating another window's audio.
- **Window admission/evidence:** Routes carry explicit profile, canonical directory and workspace; absent legacy profile remains legacy and unknown profiles fail closed. Native iPad two-view UI preserved the root draft while editing the child; iPhone hides the action. Dedicated contexts are real presentation lifetimes, not independent multiwindow copies of the primary app shell. Physical audio/keyboard behavior and OS restoration remain unverified.

These implemented paths do not establish full v1 parity, fully offline navigation, server writer/destructive contracts, or provider-backed execution. Typed inline Live Activity forms are unavailable; Open App is the intentional supported presentation.

### Terminal Boundary

The native client uses authenticated `/api/pty/:id/connect` WebSocket upgrades directly; browser tickets are not required. PTY reads and mutations use the standard `/api/pty` routes, not legacy routes or bridge-only endpoints. Resize, replay cursors counted in UTF-16 code units, normal process exits, and server-switch stale-response guards are implemented.

Terminal root resolution is separate from session-list scope. Global uses the server's default directory for the terminal without changing the Global session-list scope. The modifier controls and keyboard-dismiss button now share an `HStack`, fixing their overlap.

## Wire And Sync Rules

- Keep v2 DTOs distinct from legacy DTOs and normalize into existing project/session/chat stores and facades. Most transport code lives in `API/OpenCodeAPIClient.swift`; routing and reconciliation live in `AppViewModel+Projects.swift`, `AppViewModel+Sessions.swift`, and `AppViewModel+Events.swift` under `ViewModels/AppViewModel/`.
- Location-scoped endpoints use `location[directory]` and `location[workspace]`; session-list filters use their own directory/project/workspace contract. Session and transcript responses are `{ data, cursor }` pages, not legacy arrays. Cursor follow-ups must not reconstruct initial filters.
- Prompt admission is durable pending input, not proof of delivery into the projected transcript. Prompt files use `{ uri, name }`; projected user files contain materialized `{ data, mime, name }`. Model references use `{ providerID, id, variant }`, and agent identity uses the agent ID.
- **Inbox divergence:** pinned upstream uses `GET /api/session/:id/inbox`; live-verified `0.0.0-next-17155` uses `/api/session/:id/pending`. The current resolver selects `pending` for versions ending in `next-17155`, otherwise `inbox`. This is a known-contract selection, not endpoint trial-and-error or evidence that every other runtime is compatible.
- **Event contracts:** pass 7 maps next-17155 `session.input.admitted/promoted/cancelled` while preserving pinned `session.inbox.enqueued/cancelled/delivered`. Runtime source/OpenAPI and exact assistant-event fixtures establish contract/projection coverage, not paid generation. `session.input.delivered` is not the runtime event. This former mismatch is separate from the fixed legacy timer cancellation bug.
- Admission reconciliation first checks the projected message and then the selected pending-input endpoint. A missing message, absent queue ID, or failed queue read does not prove rejection. Do not turn errors into an empty queue or try an alternate route. Preserve uncertain input until canonical evidence resolves it.
- The released package also has provider `disabled` metadata where newer source has `activation`, and extra command metadata. Transport decoding accommodates these known differences.
- Keep one shared event owner on `/api/event`. `OpenCodeEventManager`, `OpenCodeEventStream`, `ChatStore`, and directory stores normalize/reduce execution, content, tool, interaction, and lifecycle events. SSE comments count as activity. Byte-level framing preserves blank separators, CR/LF/CRLF, UTF-8 and an initial BOM; Foundation's `AsyncBytes.lines` omits the blank lines needed to dispatch events promptly. SSE IDs/retry fields are parsed, but the global feed provides no replay guarantee.
- Shared catalog, agent, command, credential, and plugin events invalidate the relevant loaded configuration state and trigger canonical rereads through the shared pipeline, not separate event listeners or legacy fallback. PTY lifecycle events also use the shared event owner; terminal socket data remains on the PTY WebSocket.
- The v2 event stream is volatile. Reconnect and missed-event reconciliation reread canonical projects, sessions, statuses, interactions, and the loaded transcript range. Generation/lifecycle/stream revision guards prevent stale reads from overwriting newer state or reviving deleted sessions. Reconciliation is not mutation retry or cross-version fallback.

## Remaining Gaps

Pass 8 supersedes the blanket Live Activity, widget action, game and dedicated-window implementation gates. Prioritize remaining verification and unavailable server contracts, not reimplementation of those paths:

- Pass 6 closes global MCP elicitation/project presentation and the centralized Live Activity start guard; remaining external-MCP verification is not a missing native client implementation.
- Server-contract gaps: project metadata writes, destructive reset/session archive, and v1 named-branch/startup setup have no verified supported contract on next-17155. Appearance remains read-only; copy refresh is not reset.
- Custom-provider/configuration writer remains unverified. External/command authentication and unsupported integration schemas require external management; typed key/OAuth and stored-credential removal are implemented but real personal writes/sign-ins are unverified.
- Canonical todos remain gated: no endpoint/event in next-17155 public runtime OpenAPI, only old migration references in source research. Do not parse tool outputs or claim all future runtimes lack support.
- Shortcuts pagination and canonical destination validation are implemented; process-local locks/persisted ownership are not cross-process atomic exclusion. Real Shortcuts-host sends remain unverified; the user will check manually.
- Live Activity identity, permission transport/Open App forms, widget typed actions and dedicated per-window state are implemented. Verify cold-process OS restoration, Lock Screen/Dynamic Island, physical audio/keyboard/window restoration, actual valid widget commands and game/provider turns. Native lifecycle/two-view UI and cancellation/mock evidence do not establish these outcomes. Typed inline Live Activity forms remain unavailable; Open App is by design, not missing legacy answer wiring.
- OUR v2 plugin/native bridge/browser automation are explicitly deferred until OpenCode v2 release and settled contracts, not a current blocker or implementation priority. V2 supports plugins; do not implement the deferred port or fall back to legacy transport. Primary app shells are not independent multiwindow copies, and window MCP still depends on OpenCode compatibility.
- V2 read-through persistence is enabled with profile isolation and unchanged legacy storage. Fully offline navigation remains unverified/unimplemented by this bounded work: cached UI discovery stays live and only transcript HTTP is blocked with 503.
- Normal composer streaming, reasoning, interrupt/follow-up, Photos media, background catch-up and cold transcript relaunch now pass against the actual runtime with a local scripted model. Paid inference/sign-in, voice ASR/TTS, Safari Share actual-host invocation and paid two-turn actions remain unverified. Ten backend smoke scenarios including command/game flows are not native widget/game execution UI evidence; those UI checks remain open.

Do not expand general Git mutation or repository-initialization parity without proof of a corresponding v1 feature. Generic backend extraction and a second product target are separate architecture/product work, not a blanket v2 feature deficit.

Capability checks belong in facades/action boundaries as well as UI visibility. An unavailable feature must not masquerade as successful empty server state.

## Verification Guide

Fixture coverage exists in `OpenCodeAPIClientTests`, `CoordinatorTests`, `OpenCodeSavedServerTests`, `ChatStoreTests`, `DirectoryStoreTests`, `OpenCodeStreamingTests`, `V2SessionWorkflowTests`, `V2ConfigurationTests`, `TerminalFeatureTests`, and shortcut/bridge/facade tests under `OpenCodeIOSClientTests/`. Earlier passes add `V2LiveFeatureTests` and `BackendInjectionTests`. Pass 4 adds `BackendWorktreeTests`, `ProjectActionTests`, `SessionFormTests`, `ForegroundChatRefreshTests`, and isolated `BackendFeatureLiveTests`. Test presence alone is not a passing result.

Live tests in `OpenCodeV2LiveAPIClientTests` are opt-in:

| Environment variable | Meaning |
| --- | --- |
| `OPENCODE_V2_TEST_BASE_URL` | Disposable v2 server URL; tests skip when unset/empty. |
| `OPENCODE_V2_TEST_USERNAME` | Server HTTP username; defaults to `opencode`. |
| `OPENCODE_V2_TEST_PASSWORD` | Server HTTP password; defaults to empty. Use authenticated test-server credentials for the authentication test. |

Run only against an **isolated, disposable, empty-config server** with its own temporary working directory, home/config/data locations, and loopback listener. Do not inherit personal provider credentials, auth stores, provider environment variables, plugins, or MCP configuration. HTTP test-server credentials are separate from model-provider credentials. Do not point these tests at real LAN/personal servers.

The live suite creates, renames, imports, forks, and deletes fixture sessions and creates/answers/cancels forms. Prompt/command fixtures use `resume: false`; transcript fixtures are imported so tests do not need model-provider execution. Pass 4 also creates owned Git copies, writes an owned dirty-file fixture through an authenticated PTY socket, checks force-required removal and retained sessions, and cleans up only owned resources. Isolation is still required if interrupted. Never add provider credentials merely to make contract tests pass.

### Historical Verification: September 8, 2026

Main-reported on **each fresh owned iPhone 17 Pro Max and iPad Pro 13-inch (M5), stable Xcode 26.3, iOS 26.3.1**:

| Evidence | Confirmed result | Boundary |
| --- | --- | --- |
| `acceptance-part-end-unit-final.xcresult` | 1,290 passed, 13 skipped, 1,303 total per device | Final unit matrix; skipped live tests are not renewed evidence. |
| `acceptance-next17155-binfvy2o/acceptance-ui.xcresult` | One passed, zero failures/skips per device | Five native composer turns in one normal-mode core test against next-17155; not both-profile execution or all-UI coverage. |
| `acceptance-ui-attachments` in that run directory | First/progress visible before provider finish; reasoning separate; Stop closes provider HTTP, canonical `aborted`, successful follow-up | Actual runtime and scripted model transport/rendering, not paid inference. |
| Native Photos PNG | 6,247 bytes, matching canonical/provider fingerprint | Native composer attachment, not Safari Share extension invocation. |
| Background and cold relaunch | Background completion, foreground catch-up without pull; cold normal relaunch with saved credentials and five user/five assistant messages, unique IDs | Transcript restoration, not uncertain-payload persistence or ActivityKit OS restoration. |
| Earlier backend smoke | Ten actual-server scenarios passed, including command/game flows | Not Safari Share actual-host, widget execution UI or gameplay UI. |
| Localization | 1,490 keys across seven catalogs passed | Main-reported, not rerun by this documentation update. |

Artifacts are under `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/`. Recovery's both-profile seeded root/dedicated-window UI and source/unit real-adapter mocked-408 evidence are separate from this next-17155 core test; no personal-server restart evidence is claimed.

[Acceptance fixtures](scripts/acceptance/README.md) use actual installed next-17155 and a gated local scripted model, not imported assistant messages or injected app events. Sandbox egress permits only loopback 14097/14098; each run has private HOME/XDG/database/token, no paid-provider fallback, personal 4096/4097 mutations or user plugin.

Main confirmed fresh `.derived-data-device` build, strict code-sign verification and installation of `com.ntoporcov.openclient`; log `submission-recovery-device-build.log`. **Launch failed: phone locked.** Live Activity cold-process OS restoration, Lock Screen/Dynamic Island and physical background behavior remain unverified. This update changes documentation only, with no tests/builds, app code, device or server mutation. Concurrent response-copy work is not attributed here.

### Pass 8 Historical Verification: September 7, 2026

Main-reported on each iPhone 17 Pro Max and iPad Pro 13-inch (M5), iOS 26.3.1, Xcode 26.3:

| Evidence | Confirmed result | Boundary |
| --- | --- | --- |
| `pass8-release-unit-1.xcresult` | 1,223 passed, 13 opt-in live skipped, 1,236 total per destination | Final confirmed unit matrix; skipped live contracts are not renewed evidence. |
| `pass8-release-ui-1.xcresult` | Six passed, zero failures, zero skips per destination | Final confirmed UI matrix: native ActivityKit start/retain/reconnect/stop; widget new-draft cancel/missing command; game chooser cancellation; iPad native two-view root-draft preservation/child editing and iPhone hidden action. Not all-UI coverage. |
| Localization | 1,479 keys, seven catalogs passed | Main repeated the check successfully; not a run by this documentation update. |

No source fix was needed for the final matrix. It supersedes the earlier 1,216-pass unit review and `pass8-final-ui-3.xcresult`. Bundles and `pass8-release-ui-1-attachments` are under `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/`.

Main confirmed a fresh quiet `xcodebuild` for `iphoneos` in `.derived-data-device`, successful `codesign --verify --deep --strict`, and installation/launch of `com.ntoporcov.openclient` on Nic iPhone. Build log: `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass8-device-build.log`. **Pass 8 is the confirmed installed phone baseline**, superseding pass 7 and retaining the legacy SSE fix.

These results do not establish cold-process OS Live Activity restoration, Lock Screen/Dynamic Island/background behavior, physical audio/keyboard restoration, manual valid-command execution, actual gameplay or provider inference. This update changes documentation only and runs no tests/builds or code/device/server mutations.

### Pass 7 Historical Verification: September 7, 2026

Lead-reported on iPhone 17 Pro Max and iPad Pro 13-inch (M5), iOS 26.3.1, Xcode 26.3:

| Evidence | Result | Boundary |
| --- | --- | --- |
| `pass7-cache-unit-fixed-1.xcresult` | Each: 1,133 passed, 13 opt-in live skipped, 1,146 total | Completed unit evidence after cache fixes, including existing on-disk V1 compatibility. Not a fresh opt-in live run. |
| `pass7-final-unit` | Main confirmed each: 1,133 passed, 13 opt-in live skipped, 1,146 total | Final source after the action-source spelling correction `session.input.delivered` -> `session.input.promoted`. |
| `pass7-ui-final-2` | iPhone five passed; iPad four passed and one cache failure | Preserve the failure; not one clean combined run. |
| `pass7-cache-ui-fixed-2` and `pass7-cache-ui-fixed-3` | One targeted cache UI pass on each destination across the reruns | Later production fixes cover older-page ordering, cold disk hydration/fresh HTTP, canonical empty and owned 503 clearing. Discovery remains live, transcript HTTP alone is blocked. |
| Earlier pass 7 widget/global-form/session-form/valid-Share selections | Passing evidence on both destinations | No invented combined count or claim of all-UI coverage. |

Historical pass 7 device build/signing/install/launch succeeded; log: `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass7-device-build.log`. That baseline retained the legacy SSE fix and is now superseded by pass 8. Pass 7 localization passed for **1,476 entries across seven catalogs**.

This documentation-only update ran no tests/builds and made no code or server changes. Launch does not establish hands-on streaming symptom resolution or provider execution. Exact runtime/source/OpenAPI event checks are not model inference; real provider/voice/Share-extension/Shortcuts-host/paid-action evidence is still owed.

### Pass 6 Historical Verification: September 6, 2026

Lead-confirmed on **each** iPhone 17 Pro Max and iPad Pro 13-inch (M5), iOS 26.3.1, Xcode 26.3:

| Evidence | Result per destination | Boundary |
| --- | --- | --- |
| `pass6-review-unit-1.xcresult` | 1,076 passed, 13 opt-in live skipped, 1,089 total | Includes global location/connection isolation, canonical hydration overlap/retry/tombstones, pre-POST prepaid refund, Live Activity guard/ownership and retained legacy SSE regressions. |
| `pass6-review-ui-1.xcresult` | Two UI passed, zero skipped | New global forms: sessionless hydration, typed boolean `false`/integer answer, located SSE, next-request advancement, Close/draft retention and chat-blocking cancellation; existing native session-form flow also passes. |

Both bundles and reviewed `pass6-review-ui-1-attachments` were retained directly under `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/`. Pass 6 localization passed for **1,476 entries across seven catalogs**, including build extraction; not a new pass 7 count. At that handoff, disposable 14097 was stopped and owned fixtures settled; persistent 4096/4097 were untouched.

No actual MCP external-URL completion notification, real provider execution/authentication or voice authentication/ASR/TTS is established. Not all earlier UI regressions or opt-in live contracts were rerun.

The lead confirmed the fresh pass 6 `iphoneos` build completed, logged at `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass6-device-build.log`; `codesign --verify --deep --strict` succeeded. `devicectl` installed `com.ntoporcov.openclient` on Nic iPhone and process launch succeeded. That historical baseline included the legacy SSE fix, global forms and centralized Live Activity guard and is now superseded by pass 7. Launch alone does not establish hands-on MCP behavior or user confirmation that the legacy streaming symptom is resolved.

### Pass 5 Historical Verification: September 6, 2026

The following results are lead-reported; this documentation update did not rerun tests, build, or mutate a server. Destinations are iPhone 17 Pro Max and iPad Pro 13-inch (M5), iOS 26.3.1, Xcode 26.3.

| Evidence | iPhone | iPad | Availability / limit |
| --- | --- | --- | --- |
| `pass5-legacy-fix.xcresult`, pass 5 full unit/contract suite | 1,059 passed, 13 opt-in live skipped, 1,072 total | 1,059 passed, 13 opt-in live skipped, 1,072 total | Retained artifact; includes the two new legacy streaming regressions. Not a rerun of all live contracts or UI tests. |
| `pass5-form-picker-final-1.xcresult`, pass 5 form rerun | 1 passed, 0 skipped | 1 passed, 0 skipped | Retained artifact. Harness fixes ensure full viewport visibility and target the trailing picker label; no production form changes. |
| `pass5-regression-final`, older-UI regression | 4 passed | 3 passed, form failed | Recorded historical result: proxy foreground refresh, cold relaunch, forms and workspace. Latest form rerun above supersedes that form failure. |
| `pass5-complete-1.xcresult` plus `pass5-share-final-1.xcresult` | 1,070 unit/contracts and six new UI tests have passing evidence across the runs | Same | Historical pre-host-restart evidence, no skips. First run had five UI passes and valid-Share preview-dismissal failure; final Share rerun passed. Not one clean combined run. |

Retained pass 5 bundles are directly under `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/`: `pass5-legacy-fix.xcresult` and `pass5-form-picker-final-1.xcresult`. Earlier temporary bundles/attachments were lost when the host restarted and temporary storage was cleared; their names below are historical identifiers, not claims of current path availability.

The six new pass 5 UI selections cover cold/warm unvalidated Share, warm valid Share edits/target mismatch/revalidation/PNG preview/cancel, Talk chooser cancellation/existing-chat availability without recording, and two manual-browser history/isolation flows. Warm Share uses `XCUIDevice.shared.system.open` with same-PID assertions; the DEBUG hook seeds stored payloads only, not routing/readiness. This is not actual share-extension invocation. Historical `Pass5LiveIntegrationTests` used isolated server 14097 for discovery/create/model selection without prompts; the latest suite's 13 opt-in live skips do not renew that evidence.

The lead confirmed a fresh `iphoneos` build in `.derived-data-device`, with log `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass5-device-build.log`; `codesign --verify --deep --strict` succeeded. `devicectl` installed `com.ntoporcov.openclient` on Nic iPhone and process launch succeeded. That historical pass 5 baseline included the legacy batch-timer fix and is superseded by pass 6. Localization lint passed for 1,472 entries across seven catalogs.

User confirmation of actual on-phone legacy streaming is still pending; build/install/launch does not visually verify the reported symptom. Hands-on terminal interactions also remain unverified. Other verification still owed: actual voice ASR/TTS, real Share extension invocation, Shortcuts-host sends, personal provider OAuth/key writes, paid two-turn action execution, and provider-generated assistant streaming. Pass 7 supersedes the historical runtime event-contract follow-up with source/OpenAPI and fixture coverage, not inference evidence.

### Pass 4 Historical Verification: September 5, 2026

| Destination | Historical unit/contract tests, lead-reported | Historical UI status |
| --- | --- | --- |
| iPhone 17 Pro Max, iOS 26.3.1 | All 995 passed; includes isolated real-server contracts | Three pass 4 UI tests passed |
| iPad Pro 13-inch (M5), iOS 26.3.1 | All 995 passed; includes isolated real-server contracts | Three pass 4 UI tests passed |

Historical result identifiers are `pass4-unit-final.xcresult` and `pass4-ui-complete.xcresult`; each recorded both simulator destinations. Those temporary bundles are no longer available after cleanup. Localization catalog/source and compiler-extraction checks passed in that pass.

| Passing UI selection on each destination | Evidence boundary |
| --- | --- |
| `testV2ActiveChatRefreshesOnForegroundWithoutPullThroughSnapshotProxy` | Production background/foreground lifecycle and changed HTTP transcript responses through a test-only loopback snapshot proxy, with healthy SSE and no change events. No pull-to-refresh. **Not actual-server message mutation.** |
| `testV2NativeFormAppearsInOpenChatSubmitsTypedAnswerAndCancelsAgainstIsolatedBackend` | Native full-form presentation in an open chat, typed submission and cancellation against the isolated server. |
| `testV2WorkspaceDestinationCancellationAndOwnedSessionNavigationAgainstIsolatedBackend` | Explicit destination flow, cancellation without creation, and owned workspace/new-chat navigation. |

The original server has no message PATCH route, and re-importing the same session ID returns 409. The proxy deliberately changes read snapshots to test production lifecycle reconciliation without claiming a server mutation that the runtime cannot perform. Unit tests separately verify coalescing, activation invalidation, and latest-request protection under slow/out-of-order responses. The fresh `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app` was built, installed, and launched on Nic iPhone. Hands-on validation against the user's active conversations remains separate from installation.

Real-server contract tests are not real provider inference or authentication: provider sign-ins/credential writes remain mock/fixture-validated only. Hands-on physical-device streaming, model generation/interruption, attachments/model/agent/commands, permissions/forms, Git, MCP, provider sign-in, and terminal interactions remain release checks.

### Historical Verification

All records below are from September 5, 2026 on iOS Simulator 26.3.1. Bundle names are historical identifiers only; earlier temporary artifacts were cleared and are not currently available or committed.

| Pass / bundle | Historical evidence, not current pass 8 validation |
| --- | --- |
| Pass 1: `v2-complete-validation.xcresult` | Each destination: 797 unit/contract tests including six real-server tests, plus one UI smoke, 798 passed with no failures/skips. iPhone portrait and iPad landscape. Source and compiler-extracted localization lint passed. |
| Pass 2: `pass2-final.xcresult` | Each destination: all 851 unit/contract tests passed, including real configuration reads and PTY SSE/socket coverage. Both iPhone UI tests passed; not evidence of both iPad UI tests passing in this bundle. |
| Pass 2: `pass2-ui-final-ipad-2.xcresult` | Both iPad UI tests passed after fixes/reruns, portrait regular width. Landscape rotation failed, so pass 2 landscape is unverified. |
| Pass 2: `pass2-ui-final-iphone.xcresult` | Both iPhone UI tests passed in the final portrait rerun. Not a single clean initial run across destinations. |
| Pass 3: `pass3-unit-complete.xcresult`, `pass3-ui-final.xcresult` | Each destination: 897 unit/contract tests and two live UI tests passed with no skips. UI covered provider grouping, Home/search/Activity, direct chat opening, settings/plugins and terminal. Localization source/catalog and extraction checks passed; its fresh device build was installed/launched on Nic iPhone. |

Pass 2 localization lint passed for 1,421 entries including compiler extraction. Its fresh `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app` was built, installed, and launched on Nic iPhone; that does not validate pass 4.

The earlier live UI selections were `testV2GlobalSessionSmokeAgainstIsolatedBackend` and `testV2ConfigurationAndTerminalSmokeAgainstIsolatedBackend`. They cover connection/navigation/imported transcripts and configuration/terminal without paid inference; they are not the three pass 4 selections above. Before rerunning, inspect loopback/temporary-root isolation guards, forward live-test variables with `TEST_RUNNER_`, and follow the current simulator policy. Historical device names are not a policy override.

## Future Work

Unlock Nic iPhone and open OpenClient manually: the fresh automatic-detection/cold-position build is installed, but launch failed because the phone was locked. Obtain hands-on feedback without treating prior Thinking-sequence feedback as validation of this build. Preserve the final combined-run iPhone Photo Picker failure alongside separate passing five-turn core runs. Continue Safari Share actual-host and native widget/game execution UI, cold-process Live Activity OS restoration/Lock Screen/Dynamic Island/physical background behavior, and physical window audio/keyboard/restoration checks. The user will check Shortcuts manually. Ten scripted backend smoke scenarios are not host/UI execution evidence. Implemented integration paths are not blanket next-to-do gates. See [the parity checklist](V2_PARITY_CHECKLIST.md).

Keep next-17155 todos blocked; runtime `session.input.promoted` mapping is already implemented. Metadata/reset/archive/setup and custom-provider/configuration writers lack verified available runtime contracts; do not invent routes. Fully offline navigation is outside bounded read-through caching, including the intentional no-profile-before-probe boundary; typed Live Activity forms intentionally open the app. Obtain scoped hands-on MCP feedback and explicitly authorized MCP external completion, voice, Share extension, Shortcuts-host, provider authentication/generation and paid two-turn evidence. No speculative fallback or mutation retry. OUR v2 plugin/native bridge/browser automation remain explicitly deferred until OpenCode v2 release/contracts settle, not current blockers. Generic injection remains incomplete, including window MCP compatibility; no second target or independent primary app-shell copies are claimed. Remote release feature-flag work stays Track Later, separately from the user-approved automatic-only default. No full v1 parity claim.
