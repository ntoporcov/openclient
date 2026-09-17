# Provider Usage Implementation Plan

Status: implementation and focused signed-simulator verification complete; normal-project resolution and real-account verification remain.
Prepared: 2026-09-12.
Audience: the next implementation agent, including 5.6 Sol.

### Implementation Checkpoint: 2026-09-13

Completed in the production/UI slice:

- Added production `AppViewModel`/`ProviderUsageFacade` composition, exact connection-lifetime and workspace context fencing, private-Keychain fallback behavior, app lifecycle cancellation, and local persisted-account management while disconnected.
- Added a reviewed application-layer encrypted legacy PTY importer. Ephemeral X25519, an operation PSK, HKDF-SHA256, HMAC-authenticated READY, and ChaCha20-Poly1305 START/RESULT frames protect against passive PTY subscribers. The helper transfers only the selected access token or API key and never transfers OAuth refresh tokens.
- Plain HTTP/WS remains rejected by default. The user approved a per-attempt insecure opt-in without a certificate requirement; the UI explicitly warns that an active network attacker can impersonate the server and recover the credential. This is an accepted limitation, not a claim that application-layer encryption makes HTTP safe.
- Importer PTYs remain outside normal terminal inventory/presentation. Exact-PTY cleanup is best-effort and bounded so a nonresponsive delete cannot outlive the primary cancellation/timeout or replace its error.
- Added standalone Configurations > Usage Levels navigation with persisted account status, explicit read approval, metadata-only credential review, explicit Keychain/provider-request save approval, stale-on-open and manual refresh, confirmed removal, and exact-source credential replacement. Its stable catalog always shows OpenAI then OpenRouter independently of OpenCode's configured Providers; discovery supplies optional credential-source suggestions only, and provider detail refresh/setup/remove behavior is scoped to the selected usage provider.
- Claude remains absent from the supported Usage Levels catalog. Anthropic's third-party credential-handling prohibition keeps it policy-gated until an approved provider-authorized design exists.
- Reimporting an exact tracked source replaces rather than duplicates it. If both old and imported credentials identify different provider accounts, the review warns before the explicit replacement action.
- Credential values remain hidden throughout the UI rather than offering token reveal. This intentionally narrows the earlier proposed review surface and avoids screenshot/accessibility disclosure while retaining provider, credential kind, and expiry review.
- Added English, Italian, and Brazilian Portuguese catalog coverage. Localization lint, JSON validation, whitespace validation, Swift parsing, and isolated iOS type-checks pass.
- Verified that legacy provider-definition `source` describes provenance, not credential provenance: exact connected `openai` and `openrouter` IDs are selectable for every legacy source value, while the consented encrypted helper remains authoritative for the exact OpenCode auth entry. The Usage Levels `.codex` presentation is now named OpenAI; the internal enum and Codex usage adapter remain unchanged.
- The five focused XCTest suites pass with normal simulator signing on iOS 26.3.1 for both required destinations: iPhone 17 Pro Max and iPad Pro 13-inch (M5). This covers the live legacy `source: "custom"` shape, stable Usage Levels catalog and provider-scoped refresh behavior, provider adapters and bounded HTTP transport, private persistence, discovery, facade orchestration, and the encrypted credential importer, including CRLF-fragmented framing, forgery/replay rejection, cancellation, timeout, nonresponsive cleanup, and a server that keeps the PTY connection open after a valid result. The current result bundle is `provider-usage-completion-final.xcresult` in the approved temporary OpenCode directory.
- A fresh signed normal-project device build succeeds, installs on Nic iPhone, and launches. Focused simulator verification uses a temporary project backed by local package checkouts because a clean normal-project simulator invocation still stalls at `Resolve Package Graph` while Xcode/SwiftPM waits on macOS Keychain authorization when fetching the public Ghostty binary artifact.
- Real OpenAI subscription import and usage refresh still require hands-on verification against the user's account. Automated tests use synthetic credentials only.
- Fixed the confirmed credential-import completion lifecycle bug: an authenticated `RESULT` now requests immediate receive-loop termination, and the legacy PTY adapter distinguishes that callback-requested disconnect from genuine task cancellation before the importer calls `finish(candidate:)`. A synthetic regression keeps the connection open after READY/RESULT unless the result callback stops it; the full focused dual-simulator matrix passes, while real-account verification remains pending.
- Credential-import failures now preserve only the finite sanitized typed error in `ProviderUsageStore`; setup keeps the broad import-failed status while showing its safe uppercase code and a localized reason bucket. Unknown failures map to `CONNECTION_FAILED`, and cancellation/reset paths clear the diagnostic.
- Pre-handshake failures now distinguish server-side PTY creation (`PTY_CREATE_FAILED`) from WebSocket attachment (`PTY_CONNECT_FAILED`) without exposing request, output, or transport details.
- After live verification identified `PTY_CREATE_FAILED`, helper startup no longer assumes `node` is visible to the OpenCode server process. The request omits `command` so OpenCode selects its preferred shell, starts that shell in login/interactive command mode to resolve the user's Node installation, and keeps the public helper source and all operation material in PTY environment variables excluded from PTY metadata.
- PTY creation now preserves only a bounded HTTP status as `PTY_CREATE_HTTP_<status>` while discarding the response body, separating request compatibility/rejection from transport and decoding failures.
- After live startup reached `INVALID_READY`, the stream parser was hardened to ignore protocol-marker text embedded in login-shell diagnostics or echoed helper source. It accepts only exact READY/RESULT prefixes and whitelisted finite helper ERROR frames; explicit helper failures retain their sanitized typed meaning.
- Helper preflight now distinguishes invalid provider, source, client key, and operation PSK environment using finite value-free codes, so server environment propagation failures remain diagnosable without exposing protocol material.
- The helper now emits LF-only frames and the client strips every trailing carriage return before frame decoding. This handles PTY output processing that expands helper CRLF into CRCRLF; the leftover carriage return previously corrupted the READY authenticator and surfaced as `INVALID_READY` on device.

### Earlier Checkpoint: 2026-09-12

Completed in the first foundation slice:

- Legacy `/provider` and v2 `/api/provider` debug bodies are redacted, with regression coverage.
- Feature-local provider usage snapshot/metric/error models exist under `OpenCodeIOSClient/ProviderUsage/`.
- A separate ephemeral provider HTTP transport enforces HTTPS, an adapter-owned origin, rejected redirects, bounded streamed responses, cancellation, and sanitized errors.
- The OpenRouter `/api/v1/key` adapter maps spend windows, optional BYOK spend, spending caps, expiry, `Retry-After`, and missing/unknown limit semantics without using `/credits`.
- The Codex subscription adapter calls only `https://chatgpt.com/backend-api/wham/usage`, transfers no refresh token, preserves primary/secondary/additional rolling windows and credits, and rejects expired credentials, account mismatches, redirects, malformed responses, and control-character header injection.
- Focused tests pass on iOS 26.3.1 with iPhone 17 Pro Max and iPad Pro 13-inch (M5).

Completed in the second core-state slice:

- Added app-private, non-synchronizing Keychain persistence with an explicit App-ID access group, device-only unlocked accessibility, verified writes, injectable Security calls, and sanitized typed failures.
- Added versioned protected account metadata and safe save/replace/remove transactions. Orphan reconciliation remains an explicit startup TODO limited to this feature's service and private group.
- Added a focused observable store and generation-fenced coordinator for select, read approval, transient redacted review, save/use approval, initial usage fetch, cancellation, and local-only removal.
- Added deterministic fake-based tests for consent gates, stale completions, persistence transactions, separate server accounts, redaction, and Keychain query attributes.
- Persisted credential kind with each account so usage routing remains well-defined after relaunch, and made removal restore the credential if metadata publication fails while reporting rollback failures explicitly.
- Regenerated the project and verified the focused persistence, provider adapter, and redaction suites on signed iOS 26.3.1 hosts for iPhone 17 Pro Max and iPad Pro 13-inch (M5). The hosted Keychain test confirms the private App-ID group resolves and the provider credential is absent from the shared extension group.
- Audited the current OpenCode PTY and OpenClient relay boundaries. Existing PTYs broadcast output to all subscribers, retain a replay buffer, expose lifecycle/inventory metadata, and have no creator-scoped authorization, so real credential import through PTY is a shipping no-go. Synthetic-only importer development may continue, but production import must remain unavailable pending a dedicated private host RPC or an equivalently reviewed end-to-end encrypted channel.
- Added pure read-only discovery over already-hydrated legacy and v2 provider state. It matches only exact supported provider IDs, strips secret-bearing provider fields and arbitrary metadata, distinguishes unhydrated from empty state, preserves stable backend/scope/source identity separately from connection lifetime, and leaves every source unavailable until an approved extraction contract can verify it.
- Added persisted-account refresh through the private Keychain, routed by stored provider/credential metadata and fenced per account plus credential revision. Refreshes deduplicate, preserve last-successful snapshots on failure, release correctly on cancellation, and cannot publish or begin a provider request after replacement/removal invalidates a delayed credential read.

The earlier PTY shipping block was resolved by the explicitly approved encrypted-helper design and documented insecure-transport limitation. Real-account verification remains outstanding.

## 1. Product Goal

Give OpenClient users a native place to see provider usage without configuring a separate monitoring application from scratch. Use the selected OpenCode connection's configured providers to suggest relevant integrations. With explicit permission, read a supported credential source on that remote host, let the user inspect the selected credential, and save an approved local copy in the iOS Keychain. Use that copy for direct, provider-specific usage requests.

This is account or API-key usage, not the current chat's token count, context utilization, or OpenClient's own free-plan meter.

The intended journey is:

1. Open Configurations > Usage Levels and choose a supported usage provider.
2. See tracked accounts and setup candidates from the selected connection.
3. Choose a provider, source connection, and supported credential source.
4. Approve reading that source through the remote terminal transport.
5. Review account information, credential type, and expiry without displaying the credential value.
6. Approve saving the credential and using it with the named provider API.
7. See current usage, relevant reset times, last-updated time, and credential health.
8. Refresh usage, replace credentials, or remove local tracking. For an explicitly approved Codex account, OpenClient may ask the original connected OpenCode source to renew its OAuth credential and update that source's authentication file.

Do not promise that every configured provider has an exportable credential, that inference credentials always authorize usage APIs, or that copied OAuth access tokens remain valid indefinitely.

## 2. Scope And Defaults

### Recommended First Release

| Area | Decision |
| --- | --- |
| First documented API integration | OpenRouter API-key spend/cap information through `/api/v1/key`. |
| First subscription integration | OpenAI Codex quota through a supported OpenCode OAuth entry. The iPhone stores only the access token; approved renewal remains source-owned. |
| Small optional extension | DeepSeek balance, if useful to the audience. Do not let it delay the first two adapters. |
| Initial credential source | Explicitly selected entries from a verified OpenCode auth-file format. |
| Optional next source | Codex CLI auth file, selected and approved separately from OpenCode authentication. |
| Remote platforms | macOS/Linux POSIX hosts with a verified JSON-capable runtime. Report unsupported runtime/platform rather than improvising shell parsing. |
| Server profiles | Read-only provider discovery for legacy and v2. Enable import only for profile/version/source combinations validated with fixtures and an isolated server. |
| Storage | App-only, non-synchronizing iOS Keychain for secrets; separate protected local metadata. |
| Credential renewal | The refresh token remains on the selected OpenCode source. After explicit review consent, OpenClient may invoke a source-side renewal helper, which atomically updates the source auth file and returns only the new access token, account ID, and expiry. |
| Usage networking | Direct iPhone-to-provider HTTPS, independent of OpenCode's API client. |
| Refresh | On opening a stale screen, manual pull-to-refresh, and conservative foreground refresh while visible. |
| Connection security | HTTPS/WSS required by default for credential extraction; no new permissive ATS exceptions. |
| Removal | Deletes OpenClient's local tracking and credential only; never logs the provider out on the remote host. |

These are recommended implementation defaults, not previously approved product requirements. Escalate material conflicts rather than silently widening scope.

### Not In The First Release

- Browser-cookie harvesting, browser database decryption, remote macOS Keychain extraction, or `security` CLI prompts.
- Filesystem crawling, environment dumps, arbitrary user-supplied extraction commands, or LLM-driven credential discovery.
- Copying OAuth refresh tokens to the device, logging in through another app's OAuth client ID, or triggering inference to renew a login.
- Claude subscription-token import pending policy clarification/approval; see Section 4.
- OpenAI/Anthropic organization billing using admin keys, OpenRouter management keys, historical charts, forecasting, alerts, Live Activities, or background refresh promises.
- New AWS/backend storage of provider credentials, a new SSE stream, changes to chat reducers, or a generic plugin execution system.
- Cross-server automatic account merging. Matching email addresses is not sufficient proof of account/workspace equivalence.

## 3. Existing Code To Build On

Paths below are relative to the repository root. Recheck symbols before implementation because the app is being refactored.

| Existing Surface | Relevant Files / Symbols | Implementation Guidance |
| --- | --- | --- |
| Legacy provider catalog | `Stores/ModelConfigurationStore.swift`: `connectedProviderIDs`, `applyProviderState`; `API/OpenCodeAPIClient.swift`: `providerState` | Use connected providers as candidates, not the entire model catalog. |
| Provider configuration facade | `Facades/ConfigurationsFacade.swift`; `ViewModels/AppViewModel/AppViewModel+Providers.swift` | Reuse metadata and lifecycle patterns, not all provider-configuration side effects. |
| V2 integrations | `Stores/V2ProviderStore.swift`, `Models/OpenCodeV2Configuration.swift`, `Coordinators/V2ConfigurationCoordinator.swift`, `API/OpenCodeAPIClient+V2Configuration.swift` | Preserve integration and credential IDs. Catalog availability alone is not credential availability. |
| Settings navigation | `Views/Projects/ConfigurationsSheet.swift`: Providers section, `ConfigurationRoute`; `Views/Projects/V2ProvidersConfigurationView.swift` | Add a separate usage destination. Existing provider login remains server-owned. |
| Connection lifetime | `Backends/BackendConnection.swift`: `BackendDescriptor`, `BackendConnection.id`, `BackendScope`; `Backends/OpenCodeBackend.swift` | Capture a connection lifetime, not just a base URL. Check terminal capability and adapter type. |
| Saved server identity | `Models/OpenCodeServerConfig.swift`: `recentServerID` | Useful source-connection association, not provider-account identity. Includes URL/username; excludes API profile. |
| Terminal transport | `API/OpenCodeAPIClient.swift`: PTY CRUD and `ptyConnectRequest`; `API/OpenCodeAPIClient+V2PTY.swift`; actor `OpenCodePTYConnection` | Reuse raw transport, not the visible terminal's command workflow. |
| Terminal DTO | `Models/OpenCodePTYModels.swift`: `OpenCodePTYCreateRequest` | Already models command/args/env, but current convenience create methods expose only title/location. Add the smallest typed extension needed. |
| Terminal races | `Facades/TerminalFacade.swift`, `Stores/TerminalStore.swift` | Borrow context/epoch fencing. Do not bind credential output to its renderer or reconnect loop. |
| Existing Keychain pattern | `OpenCodeShared/OpenCodeServerPasswordStore.swift`; `Models/OpenCodeSavedServer.swift` | Reuse separate-secret/metadata and verified-save principles, not the server-password service or shared access group. |
| Sanitized mutation errors | `Coordinators/V2ConfigurationCoordinator.swift` | Follow its refusal to expose server-echoed credential bodies. |
| Test patterns | `OpenCodeAPIClientTests.swift`, `V2ConfigurationTests.swift`, `TerminalFeatureTests.swift`, `OpenCodeSavedServerTests.swift` | Inject HTTP, socket runners, persistence, and clocks. Preserve users' existing Keychain/defaults data in hosted tests. |

The app-source paths in this table are under `OpenCodeIOSClient/` unless prefixed with `OpenCodeShared/`. Test files are under `OpenCodeIOSClientTests/`.

### Important Existing Traps

- `loadProvidersForConfiguration` can repair disabled providers, patch global configuration, and dispose the server. A usage-only discovery operation must not invoke this mutation workflow. Prefer a sanitized projection of existing provider state; add a fresh metadata load only after verifying its credential/consent boundary.
- `OpenCodeProvider` decodes `key` and arbitrary `options`. The inspected upstream legacy `/provider` response can contain actual API keys. `OpenCodeAPIClient.debugBodyDescription` currently does not redact plain `/provider`. Fix this before adding discovery/import behavior; do not print real provider responses while debugging.
- Existing provider bootstrap/catalog traffic is distinct from the proposed consented importer: OpenClient may already receive credentials through `/provider`. Redaction does not prevent that transfer. Usage candidate discovery should consume only sanitized existing metadata, never reuse incidental keys as approved usage credentials, and must not add fresh secret-bearing catalog requests before resolving their consent boundary. The selected-fields-only transfer guarantee below applies to the dedicated extraction operation, not all preexisting OpenCode traffic. Verify metadata-only alternatives before claiming discovery is secret-free.
- `/provider/auth` describes authentication methods; it does not export saved OAuth credentials. Do not invent a credential-read REST endpoint.
- Current v2 normalization loses credential identity/type. Join to supported integration metadata explicitly; do not infer stored credentials from model availability.
- Legacy project file reads reject paths escaping the project. V2 filesystem behavior requires separate verification. Do not use project file APIs as an assumed arbitrary home-directory reader.
- Global/project/workspace terminal scope is not interchangeable. Root terminal wiring does not currently pass all possible workspace context, and legacy global mode can lack a usable directory. Preserve the selected workspace or ask the user to select one; never substitute a different workspace silently.
- A provider configured through environment, config, or a plugin may not use the entry found in `auth.json`. A discovered file entry is a candidate account, not proof of the active inference account.

## 4. Provider Support And Research

Research inspected CodexBar commit [`3a7ddffb963424762c16da354bb9e9628e788e1e`](https://github.com/steipete/CodexBar/commit/3a7ddffb963424762c16da354bb9e9628e788e1e). It is a reference, not an iOS-ready dependency or an authorization to use every provider endpoint.

No real credential files were read and no authenticated provider requests were made while preparing this plan. Source inspection establishes candidate contracts, not verified compatibility with the user's accounts.

### OpenRouter: First Vertical Slice

- Map the exact supported OpenCode provider ID to an OpenRouter adapter; do not match arbitrary display names or OpenAI-compatible URLs.
- Credential: selected OpenCode `{type: "api", key: "..."}` entry.
- Baseline request: `GET https://openrouter.ai/api/v1/key`, `Authorization: Bearer <key>`, `Accept: application/json`.
- Model key-level cumulative/daily/weekly/monthly spend, limit, remaining limit, reset-window label, and optional expiry when returned.
- A spending cap is not prepaid account balance. If no limit exists, show spend without an invented percentage meter.
- Prefer server-reported `limit_remaining`. If deriving usage against a cap, account for `limit_reset`, BYOK usage, and `include_byok_in_limit`; never subtract cumulative lifetime spend from a resetting cap.
- Current official docs describe daily/weekly/monthly spend as UTC calendar periods. Preserve this meaning. Do not invent an absolute reset date merely from a label.
- `/api/v1/credits` currently requires a management key according to official documentation. CodexBar's ordinary-key `/credits`-first workflow must not be copied: a 403 there must not prevent `/key` from working.
- No OAuth refresh. Revoked/expired keys require replacement.

### Codex: Subscription Quota

- OpenCode provider ID is normally `openai`, but only a supported subscription OAuth credential qualifies. OpenAI Platform API keys do not imply Codex subscription access.
- Initial source: selected `openai` entry from a verified OpenCode auth file, with `{type: "oauth", access, expires, accountId?}`. `expires` is Unix milliseconds in the inspected schema.
- Do not transfer `refresh`, even though it is present in the source file. Approved renewal executes on that source and returns only refreshed access metadata.
- Optional next source: `$CODEX_HOME/auth.json` or `~/.codex/auth.json`, with nested `tokens.access_token`, optional `account_id`, and available expiry hints. This is a distinct source/account and requires a separate choice. Native Codex can also use an OS keyring; a missing file is not proof that the CLI is signed out.
- Request: `GET https://chatgpt.com/backend-api/wham/usage`, bearer access token, JSON accept header, and `ChatGPT-Account-Id` when available.
- Decode `plan_type`, `rate_limit.primary_window`, `secondary_window`, and optional `additional_rate_limits`. Windows expose `used_percent`, `reset_at` in Unix seconds, and `limit_window_seconds`.
- Preserve returned durations instead of hardcoding every account to five hours/seven days. Preserve unavailable/null windows.
- `credits` can describe a separate balance, with `has_credits`, `unlimited`, and a numeric or string `balance`. Do not label credits as USD without an authoritative unit.
- Treat this as an internal first-party endpoint that can change without notice. Recheck current access requirements and applicable terms before enabling shipping behavior. Do not spoof another product's identity as a shortcut around access restrictions.
- If expiry is known, renew only through the exact approved source/account/scope. JWT claims remain unverified routing hints and must match the persisted provider account identity. Unknown expiry stays unknown; a 401 may use the same approved source-renewal path.
- Imported access tokens work while valid. Monitoring can continue with the remote host disconnected until token expiry/revocation, but renewal or reimport requires reconnecting to the exact owner and scope.

### Copilot: Next Wave, Verification Required

- Candidate endpoint: `GET https://api.github.com/copilot_internal/user` using the GitHub OAuth access token, not a short-lived Copilot service token.
- CodexBar sends `Authorization: token <token>`, GitHub API version, and editor/plugin headers. Verify a permitted OpenClient request contract rather than blindly copying VS Code identity headers.
- In inspected OpenCode code, the field named `refresh` contains a GitHub access token, also stored in `access`, and `expires` is `0`. Do not apply Codex expiry rules or an OAuth refresh grant to this shape.
- Decode premium/chat snapshots, entitlement, remaining, percent remaining, unlimited, credit usage, and optional root `quota_reset_date`.
- Code is more current than CodexBar's prose docs: reset dates are parsed despite the doc claiming they are absent.
- Validate OpenCode-issued token compatibility with this internal endpoint before enabling import. Do not assume PATs, GitHub App tokens, or `gh` login tokens are interchangeable.

### Claude: Explicit Release Gate

CodexBar technically supports `GET https://api.anthropic.com/api/oauth/usage` using a subscription access token, the `anthropic-beta: oauth-2025-04-20` header, and sufficient profile scope. It decodes five-hour/weekly/model-specific percentages, ISO-8601 resets, and extra usage.

However, Anthropic's current [authentication-and-credential-use policy](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use), checked on 2026-09-12, explicitly says third-party developers may not collect, store, or intermediate Claude.ai credentials or session tokens. User approval and CodexBar's MIT license do not override provider restrictions.

Treat Claude subscription import as unavailable in the shipping registry until product/legal clarification or provider approval establishes a permitted implementation. Do not implement a hidden bypass, CLI-identity spoofing, or browser-cookie workaround. Anthropic Admin API usage is a different product with different credentials, not a substitute Pro/Max quota meter.

### Other Candidates

| Provider | Useful Small Capability | Constraints |
| --- | --- | --- |
| DeepSeek | `GET https://api.deepseek.com/user/balance`, bearer API key | Documented balance API; preserve per-currency string-decimal balances. No subscription-window/reset inference. |
| Z.ai | `GET https://api.z.ai/api/monitor/usage/quota/limit` | Quota adapter needs explicit global/CN region and personal/team handling. Never send CN credentials to the global host by heuristic. |
| OpenAI Platform | Organization usage/cost | Usually requires a different administrative credential/permission model. Defer. |
| Custom/local providers | No universal usage contract | Display unsupported/unavailable, not zero usage. OpenAI-compatible inference is not usage-API compatibility. |

## 5. User Experience

### Main Screen

Add Usage Levels as its own Configurations concept, separate from OpenCode's configured Providers, Add Provider, and Disconnect actions. Always list the supported usage-provider catalog even when OpenCode has no matching provider configured. OpenCode discovery may suggest credential sources but must not control catalog visibility. Use the existing native list/detail design, not a new top-level navigation model.

Each provider detail shows tracked accounts and any discovered setup candidates for that provider. A row can show provider/account, source connection, capability type, usage summary, last update, and action/status. Avoid one ambiguous aggregate percentage across unrelated windows or providers.

Useful row states include Ready to Set Up, Source Not Verified, Unsupported Credential, Tracking, Saved / Not Checked, Needs Reimport, Insufficient Permission, Rate Limited, and Temporarily Unavailable. Model semantic states in code; localize presentation separately.

Once a credential is saved, direct usage refresh does not require a connected terminal. Provide a small management entry from root settings so users can inspect/remove local tracking while disconnected. It may reuse the same view with a source-connection filter. No cross-server aggregate charts are needed.

### Setup Flow

1. **Select source.** Show provider, exact connection, directory/workspace, candidate source type, and what can be measured. Do not read credential content when listing rows.
2. **Read approval.** Explain that OpenClient will run a fixed read-only command on that host to retrieve only the selected credential fields. Identify the expected file/location rule. Explain that the token may grant more privileges than reading usage. Require a deliberate Read Credential action.
3. **Extraction.** Show progress and Cancel. Do not open a visible terminal tab or write a chat message. The operation cannot silently retry by rereading credentials.
4. **Review.** Show provider, source, credential kind, optional account/workspace, known expiry, and a masked token. Account identity may be unavailable until the provider is queried; label inferred information accordingly. A deliberate Reveal action satisfies the request to show the token without exposing it by default.
5. **Save approval.** Save and Enable Tracking explicitly authorizes both local Keychain storage and future GET requests to the named provider origins. State that OAuth expiry may require reconnecting to reimport, and that this does not modify remote authentication.
6. **Persist and fetch.** Verify the Keychain write, persist metadata, then fetch usage. A successful save is distinct from a successful usage check. On network failure keep the credential marked Saved / Not Checked or the appropriate error, not falsely Connected.
7. **Recovery.** Offer retry for network failures, replace/reimport for expired credentials, and remove tracking. Never autonomously acquire broader credentials in response to a 403.

Hide the token again when the app becomes inactive. Cancel and clear any unsaved credential when setup is dismissed, the captured connection/scope changes, or the app enters the background. Require a fresh operation after such cancellation. Do not promise secure memory zeroization for Swift strings or protection from a user taking a screenshot after explicitly revealing a token.

Do not add automatic clipboard copy. A later explicit copy feature would need its own warning, expiration/local-only pasteboard policy, and tests. Accessibility should describe masked/revealed state without reading secret contents by default. Screenshot/UI fixtures must use synthetic credentials only.

## 6. Architecture And Ownership

Use the existing store/coordinator/facade architecture. Keep the initial file set small; the following are ownership boundaries, not a mandate to create an abstraction for every method.

| Proposed File | Responsibility |
| --- | --- |
| `OpenCodeIOSClient/ProviderUsage/ProviderUsageModels.swift` | Feature-only account metadata, capabilities, metrics, snapshots, statuses, import context, typed errors. |
| `OpenCodeIOSClient/Stores/ProviderUsageStore.swift` | Observable, sanitized accounts/setup status and last-successful snapshots. No raw networking or stored bearer strings. |
| `OpenCodeIOSClient/Coordinators/ProviderUsageCoordinator.swift` | Discovery, consented import/save workflow, refresh scheduling, cancellation, account revisions, and publishing results. Split setup orchestration only if its complexity warrants it. |
| `OpenCodeIOSClient/Facades/ProviderUsageFacade.swift` | Thin view-facing state and intents if needed by the existing composition pattern. Do not duplicate coordinator state. |
| `OpenCodeIOSClient/API/OpenCodeCredentialImportClient.swift` | Dedicated, bounded PTY import using captured legacy/v2 transport; no UI renderer. |
| `OpenCodeIOSClient/ProviderUsage/ProviderUsageCredentialStore.swift` | Injectable app-only Keychain repository, with explicit error reporting and separate metadata persistence. |
| `OpenCodeIOSClient/ProviderUsage/ProviderUsageClient.swift` | Dedicated provider HTTP transport and minimal adapter interface/registry. No OpenCode headers or base URLs. |
| `OpenCodeIOSClient/ProviderUsage/OpenRouterUsageAdapter.swift` | Exact OpenRouter requests, DTOs, validation, metric mapping. |
| `OpenCodeIOSClient/ProviderUsage/CodexUsageAdapter.swift` | Exact Codex requests, DTOs, validation, metric mapping. |
| `OpenCodeIOSClient/Views/ProviderUsage/ProviderUsageView.swift` | Native tracked-account/candidate list and details. |
| `OpenCodeIOSClient/Views/ProviderUsage/ProviderUsageSetupView.swift` | Read/review/save presentation and transient reveal state. |

Limit `AppViewModel` work to composition/lifecycle wiring. Do not add canonical usage arrays, HTTP handlers, timers, or new feature extensions there. Keep third-party provider networking outside `API/`, whose current responsibility is the OpenCode server boundary.

OpenCode remains canonical for configured providers. Each external provider is canonical for its usage. The local store owns tracking preferences and cached snapshots. This is an intentional app-only feature; it does not belong in OpenCode's session SSE/reducer pipeline.

### Minimum Model Semantics

- A tracking account has an opaque local UUID, provider kind, source connection reference, API profile, source kind, optional integration/credential identifier, optional provider account/workspace identity, and credential revision.
- Separate discovery scope (server/directory/workspace), operation lifetime (connection UUID/generation), and saved account identity. Do not key secrets by provider ID alone or duplicate one global credential for every project.
- A transient credential has an explicitly supported kind, secret payload, known expiry/scopes, and source provenance. Do not make it generally printable, Codable into public metadata, or part of navigation state. Its default/debug description must be redacted.
- A snapshot has account ID, credential revision, fetch time, optional plan, and a list of typed metrics. Use stable adapter-defined metric IDs, not display labels as identity.
- A quota-window metric can carry percent used, used/remaining/limit when authoritative, window duration, reset time, and an explicit unlimited state.
- Monetary or credit metrics preserve unit/currency; prefer decimal values for currency. Balance, spend, quota, and credit counts must remain distinct.
- Support unknown, missing, unlimited, exhausted, and over-limit values. Zero is a valid measurement and must not stand in for missing data. Clamp only the visual bar, not the underlying over-limit number.
- Freshness and refresh error are separate from the last successful snapshot. Do not replace good data with empty arrays on transient failure.

Expose a minimal provider adapter contract for supported credential kinds, allowed origins, request building, response decoding, and metric conversion. Remote source extraction and device credential storage should not be hidden inside provider response parsers. Use an explicit registry, not downloaded executable provider plugins.

## 7. Credential Discovery And Extraction

### Source Resolution

For the inspected legacy OpenCode implementation, authentication lives at `Global.Path.data/auth.json`, normally `$XDG_DATA_HOME/opencode/auth.json` or `~/.local/share/opencode/auth.json`. Resolve paths using the remote execution environment, never the iPhone's home directory.

`OPENCODE_AUTH_CONTENT` can override file authentication. A shell/plugin execution environment can also differ from the server process that resolved provider configuration. For the MVP, identify unsupported/ambiguous override or environment/config-backed cases rather than silently treating a stale file as the active credential. Supporting a named environment source later needs explicit consent and selected-field extraction, not an environment dump.

Do not guess v2 credential-file locations from legacy endpoints. V2 discovery can ship with source import unavailable until its installed server format and integration-to-credential mapping are verified. Record supported server/source versions in fixtures. Only add format compatibility for a concretely supported version, not speculative legacy fallbacks.

If multiple sources/accounts are plausible, ask the user which to import. Do not search another file automatically after malformed/unreadable input. Show a missing source as a recoverable setup error; a different source is a new read authorization.

### Dedicated PTY, Not The User's Terminal

Current OpenCode transport is a PTY API, not a secure command-result RPC. `TerminalFacade.send` is not an awaitable command-completion API. Session shell execution is worse for this purpose because its input/output becomes messages, tool state, SSE, and possible model context. Never use it for secrets.

Build a short-lived importer around raw PTY CRUD and `OpenCodePTYConnection`:

1. Capture and validate connection UUID/generation, original API client/session, profile, directory, workspace, selected source, provider, and operation UUID.
2. Check approved transport policy and capability. No extraction if the backend cannot provide the verified PTY contract.
3. Create a dedicated PTY with a fixed, nonsecret command and title. Do not attach it to the normal renderer or select it as the user's terminal. Existing user PTYs remain untouched.
4. Start a fixed helper that performs no credential read until the WebSocket is attached and the app completes a ready/start handshake. A one-shot command can exit and be removed before attachment, losing its output.
5. After the handshake, read only the approved bounded source, select exactly one entry, and emit only the allowed credential fields and necessary metadata in a versioned framed response. Do not send the entire file to the phone and then filter it there.
6. Accept exactly one response for this operation, handle fragmented frames/CRLF/control messages, reject extra or ambiguous frames, and enforce byte/time limits.
7. Delete only that PTY through the captured original client in every completion, timeout, and cancellation path. Treat an already-removed PTY as cleaned up; surface other cleanup failures without secret details.
8. Clear raw frame buffers and transient extraction references promptly. Do not reconnect/reexecute after a lost secret-read operation; a retry is a fresh explicit action.

Suggested initial bounds to tune with fixtures: 1 MiB source file, 16 KiB selected payload, 64 KiB total received output, 15-second operation timeout, and a helper self-exit deadline no longer than 30 seconds. Enforce source bounds while reading, not merely after an unbounded read or by trusting `stat` against a concurrently modified file.

A practical initial helper may require Node or Bun, selected from a fixed allowlist after capability detection. OpenCode's presence does not guarantee a separate `node` or `bun` executable. If neither supported runtime exists, return Unsupported Runtime; do not install software or fall back to `sed`/regex JSON extraction. Launch without interactive shell startup files where the verified server contract allows it. Keep errors fixed and sanitized, and reject truncated or malformed source data rather than echoing it.

The helper must await an operation-specific start message before reading, and self-expire if the client disappears. A random nonce correlates frames; it is not encryption or access control. Token values must never appear in argv, shell input, env, PTY titles, query strings, filenames, or temporary disk output. Source/provider inputs must be allowlisted structured values, not interpolated shell fragments. JSON escaping or Base64 framing is not encryption.

### PTY Security Limitation: Release Gate

The inspected upstream PTY broadcasts output to subscribers and retains a replay buffer. A disposable PTY is not an exclusive-reader secret channel. Other authorized clients of the same server may observe it, and host/server/relay instrumentation may see its contents. Hiding it from OpenClient's normal terminal renderer does not remove this server-side property.

Before shipping, verify exact behavior for supported server versions, including terminal inventory, lifecycle SSE metadata, replay retention, process-exit removal, logging, and cloud relay routing. Trace any relay's trust boundaries using the `openclient-backend` reference. WSS to a relay does not by itself mean end-to-end encryption to the host.

The initial PTY design is only acceptable for explicitly authorized, trusted single-user hosts where the product accepts that other authorized server clients can read host credentials already. Disclose this limitation accurately. If exclusive transfer or zero replay exposure is required, stop the PTY shipping path and design an authenticated dedicated host-helper/RPC with bounded selected-field output, no transcript/replay, audited relay behavior, and its own threat review. That is additional scope, not an imaginary existing endpoint.

Plain HTTP/WS is blocked for extraction by default, including LAN URLs. Some users rely on encrypted VPN/tunnel links with HTTP inside them; do not claim the app can prove such a tunnel from a private IP or hostname. Any exception requires a separate product/security decision and explicit acknowledgement, not silent local-network exemption. Manual entry later can avoid remote export but does not bypass provider-policy restrictions.

## 8. Keychain And Persistence

Create a dedicated service such as `com.ntoporcov.openclient.provider-usage`. Use a unique opaque credential-reference UUID as the Keychain account and associate it with protected tracking metadata.

- Use generic-password items with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for the foreground-only design.
- Set non-synchronizing behavior explicitly. Do not put these credentials in the extensions' shared access group.
- Explicitly set the signed main app's private App-ID `kSecAttrAccessGroup` on add/read/update/delete/enumeration, including orphan cleanup. The existing entitlement lists the shared group first, so merely omitting an access group can store new items in that shared group; a distinct service name is not access isolation. Resolve the correct AppIdentifierPrefix through signing/project configuration, not a hardcoded team ID. Verify private-group authorization in the built app, adding explicit main-app entitlement/configuration if needed, without changing the shared default or granting the private group to extensions.
- Do not require biometric presence for every refresh unless product explicitly chooses that tradeoff; doing so changes refresh behavior.
- Distinguish item-not-found, temporarily inaccessible/locked, and write/read-back failures. Return typed sanitized errors, never raw payloads.
- Read back a new write before marking it saved. Do not delete a working credential first when replacing it.
- Store only the adapter-required credential plus necessary secret-associated fields. No refresh token for shared OAuth sources.
- Keep account/source metadata separate from the secret. Metadata can be sensitive too; avoid unneeded email/path persistence or diagnostics.

Use a small versioned Codable metadata repository with atomic, file-protected writes, or an existing repository abstraction providing equivalent tested behavior. No database is needed for this MVP. In-memory last-successful snapshots are sufficient initially; if snapshots are persisted, protect them and never persist raw provider responses.

Replacement sequence: encode/validate the proposed record, write a new credential reference, verify it, atomically publish metadata referencing it, then delete the superseded reference. If publishing fails, retain the old record/credential and clean up the new item. A process crash can leave an orphan; reconcile only items in this feature's dedicated namespace against committed metadata, never unrelated Keychain entries.

Removal sequence: invalidate account tasks/revisions immediately and remove only its local tracking/credential. If deletion is blocked, retain a sanitized cleanup-pending record and do not claim that the secret was deleted. Never call OpenCode's `DELETE /auth/:providerID` as part of this operation.

Connection rename should preserve the association. Changing URL/username/profile must not silently attach credentials to a different host identity. When deleting a saved connection, offer an explicit choice about also removing its local provider tracking; leave retained tracking visible in global management. Removing a provider on OpenCode should mark its source relationship as no longer configured, not silently delete or revoke an approved local credential.

If a reimport resolves to a different provider account/workspace, require explicit confirmation to create a separate tracking account or replace the existing association. Never display the old account's snapshot under the new identity.

## 9. Provider HTTP Transport

Use a separate injected transport with an ephemeral `URLSession`, no cookie storage, no disk cache, no shared credential storage, normal TLS trust validation, bounded response reads, request/resource timeouts, and cancellation.

- Permit only adapter-defined HTTPS origins. Never derive credential destinations from arbitrary remote provider options, enterprise URLs, or file contents.
- Reject redirects by default. Do not forward authorization across hosts or retry a request against a different origin after an error.
- Add only the provider's authentication and required account headers. Never include OpenCode Basic Authorization, `x-opencode-directory`, workspace routing, relay tickets, or server credentials.
- Use an honest OpenClient user agent where accepted. Provider-specific required identity/header behavior must be verified; a failing endpoint is not permission to impersonate another client.
- Keep HTTP bodies, bearer values, and account identifiers out of debug/analytics/error descriptions. Map status/parse failures to a small error enum; do not display raw response bodies.
- Do not persist token-bearing `URLRequest`s or include tokens in `URLSessionTask` descriptions, task labels, URLs, or test failure output.
- Validate status/content shape before publishing. Unknown optional fields should not fail an otherwise valid snapshot; missing required measurement structures should be Unavailable, not fabricated zeros.

Suggested limits: 15-second request timeout and 1 MiB response-body cap, enforced during receive rather than only after `data(for:)` has buffered an arbitrary body. Tune against synthetic/provider fixtures.

Error semantics: 401 invalid/expired credential; 403 insufficient permission or unsupported account capability; 429 retry timing; 5xx/network temporary failure; malformed data unsupported response. A 403 does not mean a token is definitely expired, and a 429 does not mean the user's subscription quota is exhausted.

## 10. Refresh And Lifetime Rules

- Refresh on screen entry only when the account's snapshot is stale; use a five-minute default TTL with adapter-specific overrides if justified.
- Support pull-to-refresh, but do not bypass a known provider `Retry-After` cooldown.
- While the screen is visible and app active, allow one conservative timer and bounded concurrency, for example two accounts at once. Deduplicate requests per account/credential revision.
- Honor both delta-seconds and HTTP-date `Retry-After` forms. Use bounded backoff/jitter for temporary failures and a conservative fallback cooldown for 429 responses.
- Stop scheduled work when the screen is hidden/backgrounded. No guaranteed periodic iOS background fetching in this release.
- Never reread the remote credential automatically as part of polling, never invoke a provider CLI automatically to renew it, and never refresh a copied OAuth refresh token.
- When a quota reset countdown reaches zero, refresh when allowed; do not locally reset measured usage to zero.
- Keep last-successful data visible with its timestamp and an explicit stale/error indicator.

Import/discovery requests are fenced by captured backend connection lifetime and scope, including reconnects to the same URL. Cancelling or switching context must prevent later save actions and reject old frames.

Direct provider usage requests are instead fenced by tracking-account ID, credential revision, and current store lifetime. They may work while OpenCode is disconnected. Do not mistakenly require a live terminal for every refresh, or publish another account's result after replacement/removal. The UI's source filter must remain correct across connection switches.

## 11. Security And Privacy Checklist

Treat this as credential handling, not just a new dashboard. Review these boundaries before device testing with real accounts:

- Fix `/provider` response-body logging exposure and add regression coverage. Review request/error/log paths used by extraction and providers for equivalent leaks.
- No importer credential read before explicit read approval; no write before save approval; no provider API use before the save/use approval or another explicit check action. Keep the existing secret-bearing provider-catalog boundary explicit as described in Section 3; do not add unapproved credential-transfer traffic under the label of discovery.
- No complete auth-file export, chat/session tool execution, visible renderer output, clipboard writes, browser harvesting, or unapproved broader-source fallback.
- No modification of server authentication or refresh-token redemption, even after a 401.
- No claim that bearer tokens are read-only just because this feature makes only GET requests.
- No promise that a disposable PTY is private, WSS through a relay is end-to-end, or revealed text is screenshot-proof.
- Abort on unsupported transport/runtime/source rather than silently degrading the security model.
- Synthetic fixtures in tests, previews, screenshots, and documentation; never real tokens in fixtures or bug reports.
- Update `docs/privacy/index.html` and relevant in-app explanations to describe local credential copies, direct provider requests, retention/deletion, and any relay transit accurately.
- Review App Store privacy disclosures and provider terms with the actual implementation. Do not claim a particular disclosure answer without checking what leaves the device and who receives it.
- Retain CodexBar MIT copyright/permission notices for copied or substantially adapted code. Do not import its package wholesale without auditing iOS support and transitive licensing.

## 12. Testing Plan

### Unit And Contract Tests

| Area | Required Cases |
| --- | --- |
| Discovery | Legacy connected-only candidates; v2 available versus configured distinction; multiple integration credentials; unsupported IDs; environment/config ambiguity; no repair/config mutation; sanitized snapshots; no new unapproved secret-bearing catalog requests or reuse of incidental keys. |
| Read consent | No file-content operation before approval; cancellation before/after PTY create; selecting another source requires a new approval. |
| Save consent | No Keychain write or provider request while merely previewing; save failure is not Tracking; post-save HTTP failure is Saved / Not Checked or an accurate credential state. |
| Extraction protocol | Attach-before-read handshake; split frames; CRLF; benign startup text; PTY control frames/UTF-16 cursor handling; invalid framing/nonces; oversized source/output; malformed JSON; missing entry/file; unsupported auth shape; fixed sanitized errors. |
| Isolation/cleanup | Existing terminals untouched; no renderer/transcript output; delete exact captured PTY; process self-timeout; no secret-read replay; cancel/disconnect; cleanup failure; late create response still cleaned up. |
| Scoping | Same provider on two servers; same URL reconnect; profile/directory/workspace switch; late output cannot be reviewed/saved; exact v2 credential mapping; global scope without terminal directory. |
| Secret containment | Provider key/options debug redaction; server-echoed secrets not surfaced; no secret in argv/env/title/URL/errors/metadata/route/log/snapshot; Keychain namespace and access-group assertions. |
| Storage | Read-back verification; signed test verifies actual private access group and no matching shared-group item; locked versus missing; replacement failure preserves prior credential; metadata failure; crash orphan recovery; exact deletion; deletion failure not reported as success; user storage preserved in hosted tests. |
| HTTP | Exact URL/method/auth/account headers; no server auth/headers; HTTPS allowlist; redirects rejected; no cookies; bounded body; 401/403/429/5xx; cancellation; sanitized parse errors. |
| OpenRouter | No limit; zero limit; server remaining; resetting versus cumulative spend; optional fields; BYOK/currency handling; credits permission must not block key usage. |
| Codex | API key rejected for subscription setup; milliseconds credential expiry versus seconds resets; missing account ID; multiple windows; null windows; string/numeric credits; expired/unknown expiry; no refresh token transfer or renewal. |
| Snapshot semantics | Zero/missing/unlimited/over-limit distinction; decimal precision; separate currencies; stable metric IDs; reset reaching zero does not reset usage locally. |
| Scheduling | Injected clock; TTL; deduplication; bounded concurrency; Retry-After formats; backoff; background stop; stale-success retention; old credential/account revisions rejected. |

Use existing `MockURLProtocol`, injected terminal connection runners, deferred-response helpers, and fake persistence. Do not write tests that sleep for real timers or require a developer's logged-in provider account.

### UI And Device Verification

Add deterministic seeded usage/setup scenes with synthetic credentials, fixture metrics, and failure states. Verify:

- Configurations navigation on compact iPhone and split-layout iPad; disconnected management remains available.
- Read approval, masked review, explicit reveal, Save and Enable, cancel, replacement, and local removal.
- No provider secret read aloud by default; clear accessible meter labels, Dynamic Type, VoiceOver, non-color-only error states.
- Token concealment on inactive state and cancellation on background/dismissal/scope switch.
- Expired OAuth explanation, unsupported provider/source, rate limiting, stale data, unlimited and no-limit layouts.
- Required localizations, number/percent/currency/date formatting, and countdowns across time zones.
- A disposable import never changes the user's selected terminal and leaves no app renderer/chat output.

For integration tests, use an isolated host/server with synthetic auth files and controlled provider mocks. Verify legacy and each supported v2 contract independently. Do not repoint tests at the developer's real home auth files or automatically import credentials from the normal local test server.

Follow the `simulator-device-policy` skill before running any simulator commands: select the newest installed stable Xcode using `xcodes`, resolve the latest common stable runtime, and test both the newest available 6.9-inch iPhone Pro Max and 13-inch iPad Pro. Use explicit discovered destinations, not an arbitrary booted simulator or generic destination. Keep normal signing; never pass `CODE_SIGNING_ALLOWED=NO` for hosted Keychain tests.

Use `internationalization`, `swiftui-specialist`, and device/install skills when implementing their respective surfaces. Read current `LOCALIZATION.md` and `REQUIRED_LANGUAGES` from the lint script; do not hardcode an old language list.

After adding source/catalog files, regenerate with:

```bash
INCLUDE_PROJECT_LOCAL_YAML=1 /Users/mininic/.local/bin/xcodegen generate
```

Run unit/UI tests with both resolved simulator destinations and normal signing, then localization validation:

```bash
ruby scripts/lint-localizations.rb
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios lint_localizations
```

Confirm any lane's simulator destination conforms to current policy before running it. Test on a physical iPhone using the existing install workflow after synthetic tests pass. Only test real provider accounts through an explicitly approved in-app flow; report compatibility without recording their credentials.

## 13. Implementation Work Packages

### Phase 0: Contract And Security Gates

1. Read the referenced source surfaces and relevant directory instructions; inspect current worktree without reverting unrelated work.
2. Add `/provider` debug-body redaction and an echoed-secret regression test. Keep the change narrowly scoped.
3. Pin/recheck provider endpoint docs and upstream credential formats. Write synthetic fixture contracts for OpenRouter and Codex.
4. Validate custom-command PTY creation, attach/handshake, cleanup, replay exposure, runtime availability, and effective source context on isolated supported legacy/v2 hosts.
5. Trace local/direct/cloud transport and document the accepted trust boundary. Resolve any insecure-transport or exclusive-transfer requirement before real-secret import.
6. Confirm provider policy/access gates, including Claude disabled and Codex internal endpoint status.

Exit: supported combinations are explicit, no invented endpoints, no real credential reads, and a go/no-go decision for the PTY import security model.

### Phase 1: Core State And Secure Persistence

1. Add minimum feature models, observable store, coordinator, and composition wiring.
2. Implement the dedicated Keychain and metadata repositories with injection and safe replacement/removal.
3. Add account/scoping, credential-revision, consent-state, and persistence failure tests.
4. Use fake sources/providers to exercise the complete state machine without network secrets.

Exit: tests prove no read/save/use before their required approvals and no stale/account-crossed commits.

### Phase 2: Read-Only Discovery And Import

1. Add read-only provider discovery/joining for supported profiles without configuration repair side effects.
2. Extend typed PTY create APIs minimally and implement the dedicated bounded importer/helper protocol.
3. Implement the verified OpenCode source extractor, transferring only selected API keys or supported OAuth access fields.
4. Gate unknown v2 formats, unsupported runtimes, ambiguous sources, and unsafe transport with explicit states.
5. Complete extraction/cleanup/race/logging tests on synthetic isolated hosts.

Exit: an approved fake OpenRouter/Codex entry reaches transient review, no other source entries leave the host, and ordinary terminal/chat state is untouched.

### Phase 3: OpenRouter End To End

1. Implement dedicated HTTP transport and OpenRouter `/key` adapter with fixtures and status handling.
2. Add Usage Levels navigation, setup/review/save screens, provider-specific usage details, and disconnected local management.
3. Wire save verification, first usage fetch, manual refresh, replacement, and local removal.
4. Add all visible/accessibility/error strings to the required catalogs and deterministic UI scenes.

Exit: a complete source selection > read approval > review > save approval > Keychain > real-shaped usage workflow works with mocks and an isolated host, without a management key or account-balance claims.

### Phase 4: Codex And Credential Lifecycle

1. Implement access-only OpenCode Codex source validation, expiry/account handling, and quota adapter.
2. Add multi-window/credit UI and expired/reimport states without OAuth renewal.
3. Add explicitly selected Codex CLI source only if core OpenCode import is already reliable; do not make it an automatic fallback.
4. Add conservative scheduling, stale preservation, rate-limit/backoff, and cancellation across all supported accounts.

Exit: usage remains useful until actual token expiry; reimport is explicit; neither the iPhone nor tests redeem or modify the remote refresh token.

### Phase 5: Release Verification

1. Complete unit, contract, localized UI, both simulator-class, and physical-device verification.
2. Obtain user-approved live compatibility checks for each enabled provider/source/profile combination.
3. Review logs, server PTY behavior, relay transit, cleanup, screenshots, and privacy documentation for secret exposure.
4. Update privacy text, attribution notices, and provider-support documentation.
5. Report supported providers/source versions, endpoint stability, OAuth renewal limitations, test destinations/results, and any disabled capabilities.

Exit: all release gates below are met. Do not label unverified provider/source combinations as supported just because they compile.

### Later Work, Separate Decisions

Copilot, DeepSeek, Z.ai, separate provider-authorized mobile login, a secure host-helper transport, optional usage-only host-side retrieval, notifications/history/widgets, and background opportunities can follow independently. Host-side retrieval could avoid copying subscription secrets, but changes the requested architecture and still needs provider permission; it is not an automatic workaround for a policy restriction.

## 14. Release Acceptance Criteria

- Configured providers are discovered accurately for enabled server profiles without changing server configuration.
- Unsupported providers, credentials, sources, and runtimes have honest, actionable states rather than empty or zero meters.
- User consent precedes every importer credential read and every credential save/use authorization. Discovery adds no unapproved secret-bearing requests and does not repurpose incidental catalog credentials.
- During dedicated extraction, only approved selected credential fields leave the host; refresh tokens and unrelated provider entries do not. Do not misrepresent preexisting `/provider` traffic as secret-free.
- The accepted PTY/relay trust model is verified and disclosed; unsafe paths remain unavailable.
- The token is masked by default, intentionally revealable, absent from normal terminal/chat/log/persistence surfaces, and saved only in the dedicated Keychain service.
- A failed/locked Keychain write is not presented as configured, and replacement does not destroy a working credential first.
- Provider requests use correct fixed HTTPS origins/auth without server credentials or redirect leakage.
- OpenRouter key spending, Codex subscription windows, balances, and chat context are not conflated.
- Missing/unlimited/over-limit/stale/error states and all time units are represented correctly.
- Expired copied OAuth access tokens require explicit reimport; no refresh-token competition or remote auth mutation exists.
- Connection switches, reconnects, cancelled operations, account replacement, and late responses cannot cross-contaminate accounts or save stale imports.
- Removing local tracking does not disconnect the provider on OpenCode, and deletion failures are not concealed.
- Localization, accessibility, unit/contract/UI tests, both required simulator classes, and physical-device checks are complete or clearly reported as release blockers.
- Claude subscription import remains disabled unless the credential-use policy gate has been resolved through an approved implementation.

## 15. Reference Index

Use official provider documentation over CodexBar behavior when they conflict. Recheck live contracts only with explicit account authorization.

### CodexBar, Pinned

- [Codex credentials and OpenCode source parsing](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift)
- [Codex usage HTTP and response models](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift)
- [Codex strategy and shared-refresh ownership guards](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift)
- [OpenRouter actual JavaScript adapter](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Resources/Plugins/openrouter.js)
- [Copilot usage implementation](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift)
- [Copilot response models](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/CopilotUsageModels.swift)
- [Claude usage implementation, technical reference only](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift)
- [Claude credential ownership, technical reference only](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift)
- [DeepSeek adapter](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift)
- [Z.ai adapter](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Sources/CodexBarCore/Resources/Plugins/zai.js)
- [Package manifest](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/Package.swift)
- [MIT license](https://github.com/steipete/CodexBar/blob/3a7ddffb963424762c16da354bb9e9628e788e1e/LICENSE)

CodexBarCore is not demonstrated as a drop-in iOS dependency. Its package includes macOS/browser/CLI infrastructure, and some provider implementations are now JavaScript plugins. Prefer small Swift-native request/DTO/metric ports with attribution over importing the application architecture.

### Official Provider Documentation

- [OpenRouter current-key usage](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)
- [OpenRouter credits and management-key requirement](https://openrouter.ai/docs/api/api-reference/credits/get-credits)
- [Codex credential storage](https://developers.openai.com/codex/auth/#credential-storage)
- [Anthropic authentication and credential-use restrictions](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)
- [DeepSeek balance API](https://api-docs.deepseek.com/api/get-user-balance)

### OpenCode References

Local source inspection used `/Users/mininic/opencode`, reported commit `8cc2c81d5`. Relevant files are `packages/opencode/src/auth/index.ts`, `global/index.ts`, `provider/provider.ts`, `pty/index.ts`, `server/routes/instance/pty.ts`, `server/routes/instance/provider.ts`, `file/index.ts`, `plugin/codex.ts`, and `plugin/github-copilot/copilot.ts`.

Supplemental GitHub source inspection used commit `95daf90670b7c039c436c85537da5fbfe2205b41`:

- [OpenCode auth schema](https://github.com/anomalyco/opencode/blob/95daf90670b7c039c436c85537da5fbfe2205b41/packages/opencode/src/auth/index.ts)
- [OpenCode Copilot token semantics](https://github.com/anomalyco/opencode/blob/95daf90670b7c039c436c85537da5fbfe2205b41/packages/opencode/src/plugin/github-copilot/copilot.ts)

Neither checkout establishes every installed server's behavior. Validate the actual supported legacy/v2 versions, especially custom-command PTY support, source storage, environment overrides, and replay/logging behavior.

## 16. Instructions To The Implementer

Implement this plan in verified vertical slices, starting with Phase 0 and OpenRouter. Preserve existing user/worktree changes and the app's store/facade architecture. Keep helpers and abstractions minimal; do not create an entire plugin framework or a generic remote shell runner for a two-provider MVP.

Do not execute real credential-reading commands through chat tools as part of implementation. Build the consented in-app mechanism against synthetic isolated fixtures first. No real-token fixtures, screenshots, logs, or test output.

If a gate cannot be met, return a precise blocker and leave the affected capability unavailable. In particular, do not silently weaken transport security, redeem shared refresh tokens, assume v2 storage formats, bypass provider restrictions, or describe unverified endpoints as supported.

Final implementation reporting should list shipped provider capabilities and limitations, changed files, test results for exact devices/runtimes, localization/privacy/attribution updates, and any remaining release gates. Do not commit, upload, or release unless requested.
