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

### Streaming

Important streaming findings:

- The client now receives raw SSE payloads correctly
- On-device event framing required parser adjustments beyond naive blank-line assumptions
- Upstream reducer behavior for `message.part.delta` is simple append-to-field
- iOS client keeps two practical guards on top:
  - create placeholder assistant message if deltas arrive before shell objects exist
  - preserve text when later empty `part.updated` would otherwise wipe it

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
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Build for device:

```bash
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -destination 'id=00008150-001A43A80207801C' build
```

Install on device:

```bash
xcrun devicectl device install app --device "00008150-001A43A80207801C" \
  "/Users/mininic/Library/Developer/Xcode/DerivedData/OpenCodeIOSClient-fslbxknxbnqdqydrtpagkazgjnfk/Build/Products/Debug-iphoneos/OpenCodeIOSClient.app"
```

Launch on device:

```bash
xcrun devicectl device process launch --device "00008150-001A43A80207801C" com.ntoporcov.opencode-client
```

Regenerate the Xcode project after adding/removing source files:

```bash
/Users/mininic/.local/bin/xcodegen generate
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
