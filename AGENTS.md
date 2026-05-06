# OpenCode iOS Client Notes

This project aims to stay aligned with the upstream OpenCode client architecture and interaction patterns from `~/opencode`, especially the web/app implementation.

## Goal

Build a native iOS client that follows upstream OpenCode behavior closely enough that future improvements can be guided by the existing OpenCode app patterns rather than ad hoc client-specific behavior.

Priority areas:

- One shared SSE/event pipeline
- Typed event handling
- Centralized bootstrap/hydration
- Project -> Session -> Chat navigation
- Session-local live state like todos/messages
- First-party UI for permissions, questions, todos, and tool activity

## Upstream Reference Files

These local upstream files were identified as the main references for architecture and behavior:

- `~/opencode/packages/app/src/context/global-sdk.tsx`
- `~/opencode/packages/app/src/context/global-sync.tsx`
- `~/opencode/packages/app/src/context/global-sync/bootstrap.ts`
- `~/opencode/packages/app/src/context/global-sync/event-reducer.ts`
- `~/opencode/packages/app/src/context/sync.tsx`
- `~/opencode/packages/sdk/js/src/v2/gen/types.gen.ts`

## Confirmed Upstream Patterns

### Shared event pipeline

Upstream uses one shared SSE/global event owner and fans events out by `directory`.

Relevant upstream file:

- `packages/app/src/context/global-sdk.tsx`

Current iOS direction:

- `OpenCodeIOSClient/API/OpenCodeEventManager.swift`

### Typed event models

Upstream uses generated discriminated event types in the SDK.

Relevant upstream file:

- `packages/sdk/js/src/v2/gen/types.gen.ts`

Current iOS direction:

- `OpenCodeIOSClient/Models/OpenCodeModels.swift`
  - `OpenCodeTypedEvent`
  - `OpenCodeEventEnvelope`
  - `OpenCodeGlobalEventEnvelope`

### Reducer-style event application

Upstream applies global and directory/session events through reducer helpers rather than scattering event mutation in views.

Relevant upstream file:

- `packages/app/src/context/global-sync/event-reducer.ts`

Current iOS direction:

- `OpenCodeIOSClient/Models/OpenCodeStateReducer.swift`

### Centralized bootstrap

Upstream bootstraps global state and directory/session state separately.

Relevant upstream file:

- `packages/app/src/context/global-sync/bootstrap.ts`

Current iOS direction:

- `OpenCodeIOSClient/API/OpenCodeBootstrap.swift`

## What We Learned About the Server

### Projects

- `GET /project/current` works
- `GET /project` returns known projects
- Non-global projects are scoped by `directory`
- `global` is special:
  - bare `GET /session` returns global sessions
  - `GET /session?directory=/` does not
- Project discovery appears implicit from directory selection/worktree state
- `PATCH /project/:id?directory=...` updates an existing project, but does not create one
- Project id for git repos appears tied to the repo's first commit hash
- Web flow appears to use directory search + session roots query + SSE `project.updated`

### Sessions

- Scoped session list: `GET /session?directory=...`
- Scoped session creation: `POST /session?directory=...`
- Discovery/warm-up pattern observed: `GET /session?directory=...&roots=true&limit=55`

### Todos

- Source of truth is `GET /session/:id/todo`
- Todo tool message detail is useful for context/debugging, but should not be treated as the canonical todo state
- Hide todo strip when all items are `completed`

### Permissions

Important corrections discovered during implementation:

- Permissions are not driven by `/tui/control/*`
- Correct live event: `permission.asked`
- Correct reply endpoint: `POST /permission/:requestID/reply`
- Initial hydration endpoint: `GET /permission`
- Actual permission list payload shape differs from earlier assumptions:
  - `permission`
  - `patterns`
  - `always`
  - `metadata`
  - `sessionID`
  - `tool.messageID`
  - `tool.callID`

### Questions

- Initial hydration endpoint: `GET /question`
- Reply endpoint: `POST /question/:requestID/reply`
- Reject endpoint: `POST /question/:requestID/reject`
- Live events:
  - `question.asked`
  - `question.replied`
  - `question.rejected`
- Upstream question payloads can omit defaultable fields:
  - `multiple` may be missing and should default to `false`
  - `custom` may be missing and should default to `true`
- Question live-event decoding is easy to break if the generic event envelope model does not carry question-specific fields like `questions`

### Streaming

Important streaming findings:

- The client now receives raw SSE payloads correctly
- On-device event framing required parser adjustments beyond naive blank-line assumptions
- Upstream reducer behavior for `message.part.delta` is simple append-to-field
- iOS client keeps two practical guards on top:
  - create placeholder assistant message if deltas arrive before shell objects exist
  - preserve text when later empty `part.updated` would otherwise wipe it
- Typed-event decode failures used to fail silently at the SSE boundary; the event manager now logs dropped events into the existing debug log.

### Typed Event Decode Failures

When a live SSE event is visible in raw payloads but does not update UI state, suspect typed-event decode mismatch before suspecting view logic.

Common symptoms:

- `permission.asked` works in-chat but `question.asked` does not
- bootstrap hydration via `GET /question` works, but live question UI never appears
- debug logs show raw events arriving, but no corresponding `question changed` reducer log
- the stream appears healthy, but the only new clue is a `drop event: untyped ...` debug line

How to identify it:

1. Compare the live SSE payload shape with `OpenCodeEventProperties` and the target typed model in `OpenCodeIOSClient/Models/OpenCodeModels.swift`.
2. Check upstream generated SDK types in `~/opencode/packages/sdk/js/src/v2/gen/types.gen.ts` for optional vs required fields.
3. Look for asymmetry between similar event types.
   Example: `permission.asked` had tolerant parsing while `question.asked` originally required a strict decode.
4. Use the debug probe log and look for lines like:
   - `drop event: untyped question.asked dir=/tmp/project`
   - `drop event: invalid global envelope ...`
   - `drop event: missing inner envelope dir=...`

How to fix it:

1. Ensure `OpenCodeEventProperties` includes the event-specific fields needed to reconstruct the typed payload.
   Example: `question.asked` needs `questions`.
2. Match upstream optional/default semantics in Swift models.
   Example: `OpenCodeQuestion.multiple` should default to `false`, and `custom` should default to `true` when omitted.
3. Prefer tolerant decoding for event payloads that the server or upstream may evolve.
4. Add regression tests for both:
   - a valid payload with omitted optional/defaultable fields
   - an invalid/incomplete payload that should surface as a dropped-event debug message rather than fail silently

## Current iOS Structure

Main project files:

- `OpenCodeIOSClient/API/OpenCodeAPIClient.swift`
- `OpenCodeIOSClient/API/OpenCodeEventStream.swift`
- `OpenCodeIOSClient/API/OpenCodeEventManager.swift`
- `OpenCodeIOSClient/API/OpenCodeBootstrap.swift`
- `OpenCodeIOSClient/Models/OpenCodeModels.swift`
- `OpenCodeIOSClient/Models/OpenCodeStateReducer.swift`
- `OpenCodeIOSClient/ViewModels/AppViewModel.swift`
- `OpenCodeIOSClient/Views/RootView.swift`
- `OpenCodeIOSClient/Views/ProjectListView.swift`
- `OpenCodeIOSClient/Views/SessionListView.swift`
- `OpenCodeIOSClient/Views/ChatView.swift`

Navigation shape:

- Projects
- Sessions
- Chat

This is implemented with `NavigationSplitView` so it can adapt better across iPhone/iPad/macOS-style layouts.

## New Learnings From Upstream Review

Recent comparison against `~/opencode` clarified several important gaps between the current iOS architecture and the upstream app architecture.

### Current iOS gap summary

- `AppViewModel` is still the dominant state owner and mixes:
  - bootstrap orchestration
  - network hydration
  - direct state mutation
  - selection/reset logic
  - optimistic UI state
- Reducer coverage is partial:
  - `OpenCodeStateReducer` handles some global/session events
  - `OpenCodeStreamReducer` handles message/part streaming behavior
  - sessions, todos, selection, and many bootstrap transitions still mutate outside reducers
- `OpenCodeEventManager` currently owns a single `/global/event` stream, which is directionally correct, but upstream's key behavior is fanout by `directory` from one shared owner.
- The current iOS client still relies on fallback refresh/polling in places where upstream expects bootstrap plus reducer-driven live events to be the main source of truth.
- Typed event modeling in iOS is ahead of reducer application coverage; several modeled events are not yet fully applied, especially:
  - `session.created`
  - `session.updated`
  - `session.deleted`
  - `session.diff`
  - `todo.updated`
  - `message.removed`
  - `message.part.removed`

### Confirmed upstream architecture details worth mirroring

- Upstream has one shared SSE owner in `global-sdk.tsx`.
- Events are fanned out by `directory`, with missing directory treated as `global`.
- Bootstrap is explicitly split into:
  - global bootstrap
  - directory bootstrap
- State ownership is explicitly separated into:
  - one global store
  - one child store per directory
  - session-local caches inside directory state
- Event application is reducer-driven rather than view-driven.
- Upstream coalesces noisy stream events and treats newer full `message.part.updated` state as canonical over stale deltas.
- UI components consume higher-level sync facades (`useGlobalSync`, `useSync`) rather than mutating raw event state directly.

## Current Principle

When behavior is unclear, prefer matching the upstream OpenCode client flow from `~/opencode` over inventing new app-specific semantics.

In particular:

- Prefer one shared event manager over many listeners
- Prefer reducer-style state application over inline mutation
- Prefer bootstrap + live event sync over fallback polling
- Keep todos session-local
- Keep permissions/questions first-class and hydrated up front
- Keep project/session/chat separation explicit in navigation

## Refactor Map

The current refactor should continue in this order.

1. Split store ownership
- Keep a small global/app store for:
  - connection
  - server health/config
  - projects/current project
  - shared readiness/error state
- Introduce directory-scoped state containers for:
  - sessions
  - selected session id
  - session statuses
  - messages/parts
  - todos
  - permissions
  - questions
  - per-directory hydration readiness

2. Shrink `AppViewModel`
- Move raw event application and canonical data mutation out of `AppViewModel`.
- Keep `AppViewModel` as a higher-level facade/coordinator for:
  - bootstrap
  - store selection
  - user actions
  - view-facing derived state

3. Expand reducer ownership
- Extend reducer coverage so reducers own:
  - `session.created`
  - `session.updated`
  - `session.deleted`
  - `session.status`
  - `session.diff` where needed for previews/status
  - `todo.updated`
  - `message.removed`
  - `message.part.removed`
  - permission/question lifecycle cleanup
- Preserve the existing iOS stream guards unless upstream behavior proves they are unnecessary:
  - create placeholder assistant messages when deltas arrive early
  - avoid wiping text on later empty `part.updated`

4. Align bootstrap to upstream phases
- Phase 1: global bootstrap
  - health
  - config
  - projects
  - current project
- Phase 2: directory bootstrap
  - sessions
  - directory project/path
  - permissions/questions
  - session statuses
- Session hydration should become a narrower follow-up step, not the main place where canonical state is assembled.

5. Keep one shared event manager, but route by directory
- Continue using a single SSE owner.
- Fan out global vs directory events into the relevant state container.
- Match upstream semantics by treating missing directory as global.

6. Reduce fallback refresh logic
- Audit and gradually remove:
  - `startLiveRefresh`
  - `scheduleReload`
  - broad post-send reload paths
- Only remove refresh paths after the corresponding reducer/event path is trusted.

7. Expose a sync-style facade to views
- Views should consume derived project/session/chat state from a thin facade.
- Avoid direct mutation paths from views into raw arrays/maps held by `AppViewModel`.

## State Separation Map

The long-term direction is for `AppViewModel` to become a coordinator/facade rather than the owner of canonical app data. It may route user actions, select the active stores, and expose view-facing derived state, but domain state should live in focused stores that can be hydrated, reduced, cached, and tested independently.

### Highest-priority surfaces

- **Connection/app shell state**
  - Current state includes `config`, `backendMode`, `isConnected`, `serverVersion`, `isLoading`, `errorMessage`, recent servers, and saved-server sheet state.
  - Target owner: `ConnectionStore` or `AppSessionStore`.
  - Keep this global. It should coordinate global bootstrap and teardown without owning project/session/chat arrays.

- **Project state**
  - Current state includes `projects`, `currentProject`, `selectedDirectory`, project picker/search state, and create-project form state.
  - Target owner: `ProjectStore`.
  - This store should expose the active directory scope used by directory/session stores.

- **Directory/workspace sync state**
  - Current state is mostly `OpenCodeDirectoryState`.
  - Target owner: `DirectoryStore`, keyed by directory, with missing directory treated as `global`.
  - This should own directory bootstrap state, sessions, commands, statuses, pending interactions, and session-local child stores.

- **Session list state**
  - Current state includes `directoryState.sessions`, `sessionPreviews`, `pinnedSessionIDsByScope`, `workspaceSessionsByDirectory`, and `pendingActionRunsBySessionID`.
  - Target owner: `SessionStore` or a session-list slice inside `DirectoryStore`.
  - The session list should consume a prepared snapshot rather than assembling rows directly from unrelated `AppViewModel` maps.

- **Chat session state**
  - Current state includes `directoryState.messages`, `cachedMessagesBySessionID`, `toolMessageDetails`, selected-session hydration flags, and stream/transcript buffering.
  - Target owner: `ChatStore` per session, backed later by SwiftData/Core Data as a read-through cache.
  - Chat open should read cached messages immediately, then reconcile from server bootstrap and live SSE events.

### Next-priority surfaces

- **Composer state**
  - Current state includes `draftMessage`, `draftAttachments`, `messageDraftsByChatKey`, `composerResetToken`, and active composer focus/streaming flags.
  - Target owner: `ComposerStore`, scoped per session and persisted by server/workspace/session key.
  - Navigation should save/restore drafts through this store rather than mutating active draft fields directly.

- **Model, agent, and command configuration**
  - Current state includes `availableAgents`, `availableProviders`, `defaultModelsByProviderID`, `newSessionDefaults`, `selectedAgentNamesBySessionID`, `selectedModelsBySessionID`, and `selectedVariantsBySessionID`.
  - Target owner: `ModelConfigurationStore`.
  - This store should provide defaults for new sessions and effective selections for sends/actions.

- **Permissions and questions**
  - Current state includes `directoryState.permissions` and `directoryState.questions`.
  - Target owner: `SessionInteractionStore` or the interaction slice inside `ChatStore`.
  - Permissions/questions are first-class pending user actions. They should be hydrated up front, reduced from live events, and cleaned up by lifecycle events per session.

- **Todos**
  - Current state includes `directoryState.todos`.
  - Target owner: `SessionTodoStore` or the todo slice inside `ChatStore`.
  - Todos are session-local. `GET /session/:id/todo` remains the source of truth, with `todo.updated` reducing the active cache.

- **VCS/files state**
  - Current state includes `vcsInfo`, `vcsFileStatuses`, `vcsDiffsByMode`, `selectedVCSMode`, `selectedVCSFile`, `projectFilesMode`, file tree nodes/children, selected file, file contents, and loading/error flags.
  - Target owner: `ProjectFilesStore` or `VCSStore`, scoped by project/directory/workspace.
  - Files/Git is a separate product surface from chat and should have its own loading lifecycle and cache.

- **MCP state**
  - Current state includes `mcpStatuses`, `isMCPReady`, `isLoadingMCP`, `togglingMCPServerNames`, and `mcpErrorMessage`.
  - Target owner: `MCPStore`, scoped by active directory.
  - MCP status should be loaded and toggled independently of chat/session selection.

### Lower-priority or side-effect surfaces

- **Live Activities**
  - Target owner: `LiveActivityStore`.
  - ActivityKit should consume session/chat snapshots from sync stores and manage ActivityKit tasks/state separately.

- **Widgets**
  - Target owner: `WidgetSnapshotPublisher`.
  - Widget publishing should be a side-effect of project/session/preview changes, not a responsibility of the main coordinator.

- **Commerce and paywall**
  - Target owner: `CommerceStore`.
  - Entitlements, usage metering, and paywall presentation are app-global business state. Session creation and send-message paths should query this store.

- **Apple Intelligence local workspace mode**
  - Target owner: `AppleIntelligenceWorkspaceStore`.
  - Treat this as a second backend that implements the same project/session/chat facade shape where practical.

- **Debug probe and streaming diagnostics**
  - Target owner: `DiagnosticsStore`.
  - Diagnostics should observe the event pipeline and transcript buffering without owning canonical chat state.

- **Fun and Games**
  - Target owner: `FunAndGamesStore`.
  - Feature-specific game state can annotate sessions, but should not live in the core app coordinator.

### Extraction order

1. Wrap the existing `OpenCodeDirectoryState` in a `DirectoryStore` without changing behavior.
2. Split session-list and chat-session state out of that wrapper once callers route through the store.
3. Move composer drafts and model/agent selections into dedicated stores.
4. Move VCS/files and MCP into separate directory-scoped stores.
5. Move Live Activities, Widgets, Commerce, Diagnostics, Apple Intelligence, and Fun/Games into side-effect or feature stores.

### Local cache direction

- A local database should be introduced as a read-through cache behind the sync stores, not as a replacement source of truth.
- Good cache candidates are projects, sessions, messages, message parts, todos, and pending permissions/questions.
- The OpenCode server remains canonical. Bootstrap reconciles cache state, SSE events update memory and cache, and full server responses win over stale local data.
- Persist reducer-applied state transitions where possible. Avoid adding database writes as another ad hoc mutation path inside `AppViewModel`.

## Feedback Workflow

This project is being shaped iteratively from hands-on device feedback.

The working pattern so far:

1. Implement the smallest real version of a feature
2. Install on-device and test in the real app, not just simulator
3. Use your feedback as product direction, not just bug reports
4. When behavior is ambiguous, inspect the upstream OpenCode implementation first
5. When server behavior is ambiguous, verify against the live API before guessing

### How to Interpret Feedback

Feedback should be treated in these buckets:

- **Architecture**
  Example: one shared SSE manager, reducer-driven state, bootstrap before live events

- **Product semantics**
  Example: projects are a navigation layer, not a filter

- **Interaction model**
  Example: permissions replace the composer area, todos stay visible, sessions use Messages-style rows

- **Visual polish**
  Example: glass treatments, spacing, send-button size, list density

- **Reality check**
  Example: “this worked in another client”, “this session still has a pending permission”, “the todo list feels stale”

When possible, prefer adapting implementation to match:

1. live server behavior
2. upstream OpenCode client behavior
3. your product intent for the native app

### Debugging Approach

Preferred order of operations:

1. Reproduce on device
2. Verify server/API truth directly
3. Compare with upstream `~/opencode` behavior
4. Add minimal instrumentation only when needed
5. Remove or hide debug UI once the feature is understood

## Device Install Workflow

This project is meant to be tested frequently on your iPhone.

### Requirements

- Xcode installed on this Mac
- your Apple team/signing available in Xcode
- iPhone visible to Xcode by USB or network debugging
- Developer Mode enabled on device if required

### Common Commands

Build for simulator:

```bash
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -sdk iphonesimulator build
```

Build for device:

```bash
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -sdk iphoneos build
```

Install on device:

```bash
xcrun devicectl device install app --device "<device-udid>" \
  "<derived-data>/Build/Products/Debug-iphoneos/OpenClient.app"
```

Important:

- do not install from a stale repo-local `DerivedData/Build/Products/...` path unless that folder was the explicit `-derivedDataPath` for the build you just ran
- a stale `DerivedData/Build/Products/Debug-iphoneos/OpenCodeIOSClient.app` can still exist from pre-rename builds and will carry the wrong bundle identifier
- prefer either the real `TARGET_BUILD_DIR` from `xcodebuild -showBuildSettings` or the repo-controlled `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app`

Launch on device:

```bash
xcrun devicectl device process launch --device "<device-udid>" com.ntoporcov.openclient
```

Regenerate the Xcode project after adding/removing source files:

```bash
xcodegen generate
```

Use the local signing override on this machine:

```bash
INCLUDE_PROJECT_LOCAL_YAML=1 xcodegen generate
```

### Practical Notes

- Device availability can drop in and out; always verify with:

```bash
xcrun xcdevice list
```

- If the phone is visible but unavailable, common fixes are:
  - unlock the device
  - reconnect USB once
  - ensure same LAN for wireless debugging
  - verify `Connect via network` in Xcode Devices and Simulators

- Some installs succeed even if launch fails because the phone was locked; in that case, open the app manually on the device

## Signing And IDs

Validated current IDs:

- main app: `com.ntoporcov.openclient`
- Live Activity extension: `com.ntoporcov.openclient.liveactivity`

Local signing setup now uses:

- shared repo spec: `project.yml`
- ignored local team override: `project.local.yml`

Current local include pattern:

```bash
cp project.local.example.yml project.local.yml
INCLUDE_PROJECT_LOCAL_YAML=1 xcodegen generate
```

Current entitlements/capabilities in use:

- `OpenCodeIOSClient/OpenCodeIOSClient.entitlements`
- `OpenCodeChatActivityExtension/OpenCodeChatActivityExtension.entitlements`
- shared keychain access group: `$(AppIdentifierPrefix)com.ntoporcov.openclient.shared`

Important App ID guidance:

- use explicit App IDs, not wildcard IDs
- create separate explicit IDs for app and extension targets
- extension IDs are not separate App Store apps

## Secrets And Local Storage

Current release/security posture:

- server passwords are stored in Keychain via `OpenCodeShared/OpenCodeServerPasswordStore.swift`
- recent server metadata is stored separately from secrets
- `fastlane/.env` is ignored by git and is the local place for App Store Connect credentials
- `project.local.yml` is ignored by git and is the local place for personal signing overrides

Current ASC env vars used locally:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- one of:
  - `APP_STORE_CONNECT_API_KEY_CONTENT`
  - `APP_STORE_CONNECT_API_KEY_PATH`

Fastlane was made tolerant of both being set locally, but it prefers `APP_STORE_CONNECT_API_KEY_CONTENT` if both exist.

## Screenshots

Validated screenshot pipeline:

- screenshot mode is seeded in-app, not backend-driven
- launch scene env var: `OPENCLIENT_SCREENSHOT_SCENE`
- screenshot UI test: `OpenCodeIOSClientUITests.testAppStoreScreenshots()`
- screenshot-only scheme: `OpenCodeIOSClientScreenshots`
- screenshot output folder: `fastlane/screenshots/en_US/`

Current screenshot scenes:

- `connection`
- `recent-servers`
- `projects`
- `sessions`
- `chat`
- `permission`
- `question`

Current validated capture devices:

- `iPhone 17 Pro`
- `iPhone 17 Pro Max`
- `iPad Pro 13-inch (M5)`

Current one-command screenshot flow:

```bash
fastlane ios screenshots
```

Important note:

- the repo no longer depends on `fastlane snapshot`'s helper flow for screenshots
- the `screenshots` lane runs deterministic `xcodebuild test` per simulator and writes PNGs directly into `fastlane/screenshots/`

## Fastlane And ASC

Validated lanes:

- `fastlane ios build`
- `fastlane ios archive`
- `fastlane ios metadata_check`
- `fastlane ios metadata`
- `fastlane ios beta`
- `fastlane ios screenshots`

Important fastlane/version quirks discovered:

- this installed fastlane version does not support `deliver(download_metadata: true)` through the action API
- to pull live metadata, use the CLI subcommand pattern instead:

```bash
fastlane deliver download_metadata ...
```

- `precheck` with API keys must disable IAP checks for this app:
  - `include_in_app_purchases: false`

Current metadata/ASC validation status:

- `fastlane ios metadata_check` passes
- `fastlane ios beta` successfully uploaded the first TestFlight build

Current App Store metadata lives in:

- `fastlane/metadata/`

Current marketing/privacy site lives in:

- `docs/index.html`
- `docs/privacy/index.html`

## TestFlight Notes

Validated first-TestFlight blockers and fixes:

- preview-only Swift files must be fully wrapped in `#if DEBUG` or Release archive builds fail
- automatic provisioning updates were needed during export for app + Live Activity extension
- App Store upload rejected the app until `UISupportedInterfaceOrientations` and `UISupportedInterfaceOrientations~ipad` were added to the generated plist

Current upload/export behavior in fastlane:

- archive/export uses automatic signing
- export allows provisioning updates
- TestFlight upload uses `uses_non_exempt_encryption: false`

Current binary compliance posture:

- `ITSAppUsesNonExemptEncryption: false` is set in the generated app plist

## App Store Connect Reality

What is now automated well:

- metadata validation via `fastlane ios metadata_check`
- metadata upload via `fastlane ios metadata`
- TestFlight upload via `fastlane ios beta`
- deterministic screenshot generation in-repo

What still remains manual in ASC:

- App Privacy answers
- age rating
- some reviewer notes / review info
- any first-time store UI fields Apple does not expose cleanly via fastlane

Important nuance:

- installed app name can remain `OpenClient`
- App Store listing name must still be unique across App Store Connect

### Release Mindset

Treat on-device testing as the real source of truth for:

- streaming feel
- keyboard behavior
- split navigation behavior on compact layouts
- permission/question/todo presentation
- glass styling and motion

## Next Recommended Refactor Steps

The refactor is underway but not complete. Remaining priorities:

1. Continue moving event mutation out of `AppViewModel` into reducer/store helpers
2. Reduce or remove remaining fallback/live-refresh polling logic where upstream event flow is sufficient
3. Make state ownership more explicit by directory/session, closer to upstream `global-sync` + `sync`
4. Keep UI polish secondary to architectural consistency with upstream behavior
