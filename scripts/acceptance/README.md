# Isolated next-17155 Acceptance Fixture

Experimental-release acceptance infrastructure, **not a full-parity claim**.
Everything in this directory is fixture-owned. No app, UI test, Xcode, build,
parity document, user plugin, or persistent server change is needed.

## Requirements

- macOS with `/usr/bin/sandbox-exec` and Python 3.10 or later; standard library only.
- Already-installed `0.0.0-next-17155` executable at the path in `inspect_runtime.py`.
- Free loopback TCP ports **14097** (real OpenCode v2) and **14098** (scripted model and control).
- Approved temporary parent: `/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode`.

The binary is neither downloaded nor vendored. Starting always creates a fresh
`acceptance-next17155-*` subdirectory with a private ownership marker. It never
reuses or edits `pass2-VwCj6l`, and never invokes the old `isolated-v2.py` helper
(which reads personal credentials). A listener on either fixture port causes
startup to refuse, not to shut down that listener. No Git initialization occurs.

## Run

### Native Connection Policy

September 9, 2026: public connections use **automatic detection by default and
only**, with no Legacy/Experimental API picker. For simulator UI acceptance, use
the normal connection flow with this run's verified manifest credentials. Do not
force v2 through an internal override: verify automatic resolution, wait for
successful bootstrap, verify the experimental notice, then dismiss it through
the native UI. Explicit internal/test overrides remain factory-captured for
targeted tests, not the public acceptance path.

Valid authenticated `GET /api/health` (`healthy: true`, string `version`, integer
`pid >= 0`) binds v2 for the connection lifetime. Only unavailable 404/405,
successful HTML or recognized minimal legacy `{"healthy":true}` permits
`/global/health` fallback. 401/403, timeout/network/TLS, other errors and other
malformed/unhealthy responses fail, never silently fall back. Bootstrap/operation
failures do not switch the bound API or retry mutations.

The notice belongs to the actual bound backend UUID after bootstrap, hides
during loading/overlays or inactive connection state, and dismisses only for that
connection lifetime. SSE reconnect does not reset it; no persistent acknowledgement
is added. Global Forms take priority, and the banner never gates chat. Report a
Bug and Help share the canonical bare Support URL
`https://github.com/ntoporcov/openclient/issues`, without query or prefilled data.
Notice and secure-storage error source keys/translations are included. Main
confirmed current lint passed for 1,492 entries across seven catalogs. The
cold-position fix adds no copy; this documentation pass did not rerun lint.

Public saved loading in both the main app and headless Shortcuts migrates saved
`legacy`/`v2`/missing preferences to `automatic`. Historical widget, Live Activity,
window and cache profile IDs are unchanged; absent profiles remain legacy, with
no migrated-record type/schema. Raw `serverID` and Keychain identity stay unchanged.
Plaintext credential migration requires verified Keychain readback; existing
values, including blank, win. Deferred failure preserves original raw bytes and
blocks metadata/save/edit/delete/remember writes until the user retries the new
secure-storage error successfully. Do not clear storage to hide a migration failure.

Experimental automatic read-through/offline behavior remains unvalidated. Without
network/probe success the API profile is unknown, so no v1-cache read is allowed
as a substitute. This intentional known-profile boundary is not legacy fallback;
historical live-discovery/503-transcript tests do not prove cold offline bootstrap.
The remote rollout flag remains Track Later, independently of the user-approved
default policy. OUR v2 plugin/native bridge/browser automation remain deferred
until OpenCode v2 release and settled contracts.

### Fixture Commands

Run these commands from the repository root. `start` prints only the manifest
path and returns successfully only after identity and the one-model catalog
have been checked. The printed path contains no credentials.

```bash
python3 -B -m unittest discover -s scripts/acceptance -p 'test_*.py' -v
MANIFEST="$(python3 -B scripts/acceptance/fixture.py start)"
python3 -B scripts/acceptance/fixture.py status "$MANIFEST"
python3 -B scripts/acceptance/network_probe.py "$MANIFEST"
python3 -B scripts/acceptance/smoke.py "$MANIFEST"
python3 -B scripts/acceptance/fixture.py stop "$MANIFEST"
```

Check `start`'s exit status before continuing. On startup failure, its printed
root retains private diagnostic logs. Do not substitute a persistent server's
URL or credentials. Do not run the legacy UI helper that hard-asserts
`pass2-VwCj6l/workspace`. Core UI acceptance now exists in
`OpenCodeIOSClientUITests/AcceptanceUITests.swift`; fixture consumers must load
this run's manifest and call `load_manifest()` and `verify()` before configuring
UI acceptance, never substitute an old workspace or personal server.

`stop` checks the marker, authenticated runtime version/PID/location, and
authenticated supervisor run ID/PID. It sends an authenticated control request;
the supervisor terminates only its own `Popen` child. There is no `killall`,
process discovery shutdown, PID-file kill, or force-kill fallback. Runtime data
is retained for inspection. Start again for fresh credentials, database, and
scenario counters. A crashed runtime makes `status`/`stop` fail closed; the
supervisor detects its child's exit and tears down its own endpoint.

## Isolation

- The supervisor, scripted provider, runtime, and runtime descendants inherit a kernel network sandbox. Outbound connections are denied except loopback ports 14097/14098. macOS disallows applying a second sandbox inside it, so the child inherits the supervisor policy rather than applying another one.
- `network_probe.py` checks the exact manifest policy: the provider port connects, and a numeric TEST-NET-1 address returns `EPERM`. It does not contact a real external service. The denial happens at the kernel `connect` boundary, not after a timeout or provider response.
- Ports **4096 and 4097 are never contacted** by these scripts. Neither is allowed by the sandbox. The HTTP client rejects any base other than the fixed isolated base before constructing a request, disables inherited proxies, and refuses redirects.
- `HOME`, test home, every XDG directory, temporary directory, config directory, and SQLite path point into the fresh root. Child environments are constructed from scratch, not copied from the caller. No personal credential file, Keychain, LaunchAgent, provider environment variable, or user configuration is read.
- A fresh empty `models.json` plus `OPENCODE_DISABLE_MODELS_FETCH=1` prevents bundled/free catalog fallback and catalog network refresh. The native provider-use policy denies `*` and allows only `scripted`. Startup verifies singleton provider, model, and `acceptance` command catalogs.
- The model and built-in agent model selections are explicitly `scripted/test-model`. Title generation is disabled. Warming, sharing, autoupdate, compaction, snapshots, formatters, and LSP are disabled. Tool permissions deny everything. There are no external plugin declarations or discovered personal plugin directories.
- Provider configuration uses only a loopback `baseURL`. Its API key is a generated per-run fixture token, not a paid-provider credential. Unknown/unmarked prompts fail locally except the exact verified English/Swift game setup described below; there is no fallback model or external forwarding path.
- Roots/directories are mode 0700, and manifests/configs/logs are private. The manifest contains secrets: never commit it or print it wholesale. HTTP request bodies and authorization headers are not logged by the provider. Media logs contain only MIME, decoded byte count, and SHA-256, plus media/message counts and scenario identity. The real runtime may store attachments in its private database; redaction applies to fixture request logging, not canonical session storage.

The network sandbox is an egress boundary, not a filesystem sandbox. Isolation
from personal files relies on the generated environment/configuration and the
absence of external plugins/tool execution. This is a local acceptance fixture,
not a service for untrusted users. Do not change providers/config through the UI
while using it. The loopback bind is for host/simulator tests, not direct
physical-iPhone connectivity. There is deliberately no LAN or proxy mode.

## Manifest

`manifest.json` is mode 0600 and lives beside `.acceptance-root`.

| Field | Meaning |
| --- | --- |
| `run_id` | Random identity matching the ownership marker and control endpoint |
| `version`, `binary` | Pinned runtime identity and installed executable path |
| `root`, `workspace` | Fresh private root and empty non-Git workspace |
| `base_url` | Exactly `http://127.0.0.1:14097` |
| `provider_url` | Exactly `http://127.0.0.1:14098`; model base adds `/v1` |
| `model` | Exactly `scripted/test-model` |
| `output_schema_version` | `2`: marker-specific expected output; additive manifest field |
| `acceptance_command` | `acceptance`: the only registered command; additive manifest field |
| `username`, `password` | Own runtime Basic authentication; username is `opencode` |
| `control_token` | Own Bearer authentication for model and control endpoints |
| `server_pid`, `supervisor_pid` | Checked live process identities, not arbitrary kill targets |
| `network_policy` | Exact inherited sandbox profile |

Consumers should compare workspace paths using `Path.resolve()`: macOS maps
`/var` to `/private/var`, and v2 can report the canonical spelling. Do not assert
the old workspace path. Do not dump the manifest into CI logs or shell tracing.

## Prompt Protocol

All scenario prompts use a unique marker in the **last user message**:

```text
[[acceptance:stream:unique-run-and-turn-id]]
[[acceptance:reasoning:unique-run-and-turn-id]]
[[acceptance:attachment:unique-run-and-turn-id]]
[[acceptance:interrupt:unique-run-and-turn-id]]
```

The suffix accepts 1-80 ASCII letters, numbers, underscores, or hyphens. Never
reuse a marker within a run. Additional ordinary user text is allowed. Earlier
history markers do not choose the next scenario. The endpoint accepts only
`model: "test-model"`, `stream: true`, and `/v1/chat/completions`.

Create a session using the real v2 API, without specifying a model, then prompt:

```json
POST /api/session
{"title":"Owned acceptance","location":{"directory":"<manifest.workspace>"}}

POST /api/session/<owned-session-id>/prompt
{"text":"[[acceptance:stream:unique-id]]","resume":true}
```

The smoke runner uses this exact durable admission flow. It does not replace
OpenCode responses or inject app events. Every assistant event and canonical
message comes from the installed runtime consuming the scripted model stream.

Each stream sends a role chunk and its marker-specific first text chunk, then
holds. `advance` releases the second text chunk and holds again. `finish`
releases the last text chunk, a `stop` finish chunk, and `[DONE]`. Calling
`finish` at the first hold releases both remaining chunks.
These are OpenAI `chat.completion.chunk` SSE records, with separate HTTP writes
and flushes. Incoming Content-Length and chunked HTTP request bodies are both
supported. Responses use HTTP/1.0 connection-close framing and standard SSE.

The delays are **runner-controlled gates**, not sleeps. Each hold has a 110-second
safety deadline; release/interrupt within that deadline. HTTP control long-polls
use condition notifications and return when a matching event exists. Startup
and process-exit checks have bounded polling, separate from streaming proofs.

```bash
MARKER='[[acceptance:stream:unique-id]]'
python3 -B scripts/acceptance/fixture.py wait "$MANIFEST" --marker "$MARKER" --kind held
python3 -B scripts/acceptance/fixture.py advance "$MANIFEST" --marker "$MARKER"
python3 -B scripts/acceptance/fixture.py finish "$MANIFEST" --marker "$MARKER"
```

Wait for the app/runtime SSE text delta **before** releasing the next gate.
`wait` alone confirms provider output, not UI rendering. Use `--after <seq>` to
avoid matching an earlier hold/chunk. Raw control API, all Bearer-authenticated:

| Route | Input / result |
| --- | --- |
| `GET /control/status` | Run identity, request count, ordered redacted events |
| `POST /control/wait` | `{marker, kind, after: 0, timeout: 20}`; matching `events`, empty on deadline, maximum timeout 60 seconds |
| `POST /control/advance` | `{marker}`; release second text chunk |
| `POST /control/finish` | `{marker}`; release remaining output and clean completion |
| `POST /control/stop` | Stop supervisor and its child; prefer the verified CLI |

Event kinds: `ready`, `request`, `chunk`, `held`, `finished`, `disconnected`,
`rejected`, `hold_timeout`, `stopped`. `seq` is monotonic per run. Connection EOF
and reset are observed while a stream is held, not inferred from an interrupt
button or session flag. An interrupted stream does not emit `finished` or
`[DONE]`. The model endpoint never cancels the OpenCode session itself.

## Supported Scenarios

| Scenario | Verified behavior |
| --- | --- |
| Text | Two independently observable, marker-specific text deltas before final completion |
| Reasoning | `reasoning_content` produces `session.reasoning.delta` and a separate canonical reasoning part, not answer text |
| Image attachment | Native v2 `files: [{uri: "data:image/png;base64,...", name: "pixel.png"}]`; generated valid PNG arrives as an OpenAI `image_url` with exact MIME/byte/hash match |
| Interrupt | Native `/interrupt` while held; actual provider transport closure, canonical partial `expected.first` with `aborted` error, no provider completion |
| Follow-up | New marker on the same interrupted session with `resume: true`; second assistant completes normally with preserved history |
| Safari share | Public memory-only HTML with an encoded attachment marker in its URL path; sharing the URL as the last user message selects that marker |
| Large image | Public 1024 x 768 RGB four-color PNG, downloadable from the page; decoded bytes/MIME/hash verified through a real v2 attachment prompt |
| Widget command | Only `acceptance` is registered; native command evaluation and session execution use the scripted model, with normal gated completion |
| Find the Bug | Exact English/Swift hidden setup; one buggy Swift fence; verified-history test-marked answer returns the exact app solved marker |

Actual tool calls, other commands, other game languages/localizations, hints,
free-form game answers, Find the Place, Anthropic streaming, PDF/audio/video,
and text-file attachment transformations are **not implemented or claimed**.
There are no user plugins or paid calls. These are service/payload proofs, not
claims that Safari, widgets, the share extension, or game UI have been tested.

## UI Output Contract

**Intentional output change:** the old shared `Scripted progress complete.`
reply is gone. Existing control routes, request schemas, marker semantics for
the original four scenarios, and event sequence fields are unchanged. Request
events add `session_id` and `expected`. Manifest additions are optional metadata
for consumers of older manifests; restart into a fresh root to get this version.

Import `expected_output(marker)` from `scenarios.py` (also exposed by
`fixture.py`), or get JSON without starting a server:

```bash
python3 -B scripts/acceptance/scenarios.py '[[acceptance:stream:ui_turn_001]]'
```

For that marker the deterministic output is:

```json
{
  "schema_version": 2,
  "marker": "[[acceptance:stream:ui_turn_001]]",
  "output_prefix": "Acceptance stream/ui_turn_001",
  "chunks": [
    "Acceptance stream/ui_turn_001: first. ",
    "Acceptance stream/ui_turn_001: progress. ",
    "Acceptance stream/ui_turn_001: complete."
  ],
  "first": "Acceptance stream/ui_turn_001: first. ",
  "progress": "Acceptance stream/ui_turn_001: first. Acceptance stream/ui_turn_001: progress. ",
  "final": "Acceptance stream/ui_turn_001: first. Acceptance stream/ui_turn_001: progress. Acceptance stream/ui_turn_001: complete.",
  "reasoning": "Acceptance stream/ui_turn_001: reasoning, not answer text."
}
```

`first`, `progress`, and `final` are **cumulative visible answer strings**.
`chunks` contains the three individual deltas. Reasoning is sent only for the
reasoning scenario. Use a fresh suffix per UI turn so the expected first text
cannot match an earlier assistant response or the lowercase user marker.
The CLI additionally returns `prompt`; attachment markers also return
`page_url`, `image_url`, and `image` with dimensions/MIME/size/SHA-256.

The **only fixed-output exception** is the game solved marker. Its exact value
is required by the app; do not assert game success globally across sessions.
Scope that assertion to the newly created game session and turn. The game setup
reply is unique by session ID and the provider request event identifies the
answer's unique test marker even though the solved text is fixed.

## Safari Fixtures

```bash
python3 -B scripts/acceptance/scenarios.py '[[acceptance:attachment:safari_001]]'
```

Public URLs require **no token or Authorization header**:

```text
http://127.0.0.1:14098/fixtures/%5B%5Bacceptance%3Aattachment%3Asafari_001%5D%5D/page
http://127.0.0.1:14098/fixtures/%5B%5Bacceptance%3Aattachment%3Asafari_001%5D%5D/color.png
```

The HTML displays the image and a same-origin download link. It uses no scripts,
external resources, or secrets. Assets are generated constants in memory, not
paths read from disk. Unknown paths, traversal, queries, and double encoding are
rejected. CSP limits resources to the page's own image and inline style; caching
is disabled and no referrer is sent. Control/model routes still require Bearer
authentication. Serving a public asset does not create a model request.

`marker_in_text` decodes a shared URL **once, only for exact origin
`http://127.0.0.1:14098` and one of those allowlisted paths**. It does not decode
query strings, fragments, arbitrary prompt text, other ports, `localhost`
aliases, HTTPS, userinfo, or foreign hosts. URL tokens are removed before
literal marker scanning so a marker in a foreign URL/query cannot opt in.
Use the bare generated URL, optionally preceded by a title on another line.
The provider does not fetch the page; it selects the scenario from the URL in
the last user message. Downloading and attaching the PNG is a separate native
`files` flow, exercised by `color-image` in the smoke runner.

## Acceptance Command

17155 source verification: `schema/src/config/command.ts` supports native
`commands.<name>.template`, and `core/src/command.ts` expands `$ARGUMENTS`.
`config/plugin/source.ts` parses `-<id>` as a removal directive. The generated
configuration disables only built-in `opencode.command` (`init`/`review`) and
defines the one `acceptance` command with template:

```text
[[acceptance:stream:$ARGUMENTS]]
```

The real route sequence is **`GET /api/command`**, then
**`POST /api/session/<owned-session-id>/command`**, not `/api/command/runcommand`
(that is not a 17155 route). The smoke runner verifies the singleton catalog
and submits:

```json
{"command":"acceptance","arguments":"widget_turn_001","resume":true}
```

The selected command evaluates to `[[acceptance:stream:widget_turn_001]]`.
Control it with that full marker and use its version-2 expected output. Only
pass a fresh 1-80 character `[A-Za-z0-9_-]` suffix as `arguments`. The template
contains no shell interpolation and all model tools remain denied. The real
runtime can evaluate shell syntax in arbitrary command arguments before model
execution, so this fixture is not a validator for untrusted command arguments;
do not pass shell snippets, backticks, whitespace, or arbitrary user text.

## Find the Bug

Read-only product references are `Models/FindBugGame.swift`,
`Coordinators/FunAndGamesCoordinator.swift`, and `Stores/FunAndGamesStore.swift`.
The coordinator creates a titled session with agent `plan`, then sends the
hidden starter. The store recognizes setup/language metadata; ChatView detects
the solved marker. The fixture supports the exact current English/Swift
starter, not a substring match on a generic game mention. `BUG_PROMPT` in
`scenarios.py` contains that starter; a regression test reconstructs it from
the current Swift source to detect drift without compiling or modifying it.

For a game session `ses_<id>`, the runtime supplies its verified-source
`X-Session-Id` provider header. The setup request's control key is:

```text
[[acceptance:bug-setup:ses_<id>]]
```

Wait on that marker, then release its gates normally. The final setup reply has
a unique session-specific introduction and exactly one `swift` fence containing
`BUG_CODE`: a sum loop with an inclusive upper bound (`0...numbers.count`). No
fix, hint, or solved marker is included in the puzzle.

For the supported answer, type/send exactly:

```text
The loop includes numbers.count; use 0..<numbers.count.
[[acceptance:bug-answer:game_answer_001]]
```

The last user message must have that exact answer plus a fresh test marker,
and request history must include the exact starter and the fixture's completed
puzzle for the **same session**. Otherwise the prompt is rejected locally.
Control the answer stream by its `bug-answer` marker. Its three gated chunks
join to exactly `[[OPENCLIENT_FIND_BUG_SOLVED]]`, with no other text, preserving
the app's actual win format. A marker alone, unmarked answer, unrelated history,
changed setup, or ordinary stream marker used to bypass game validation fails.
No tools, code execution, weather/location requests, or paid calls are involved.

## Evidence

### Current Handoff: September 9, 2026

Main reports final source units in `cold-scroll-unit-final.xcresult` at **1,383
passed, 13 skipped, zero failed per device**. The known unrelated failure
`ResponseTurnCaptionTests/testCaptionOccupiesSpaceOnlyWhileRevealed` is explicitly
excluded, not passing. Accounting is **1,396 reported outcomes plus one excluded
= 1,397 including the exclusion**; skipped tests were not executed. This
supersedes `auto-detection-final-unit-1` (1,382 passed, 13 skipped, one excluded)
and the earlier 1,372-pass handoff. `auto-detection-final-ui-1` passed **three
automatic-connection UI tests per device**. No unqualified all-green suite claim.

The real-app cold-position bug consumed the initial-bottom token before the
collection had usable bounds. `ChatView` now retains the pending request, retries
after layout, marks the token handled only on success, and cancels on user drag.
`cold-scroll-before` failed at **-54 versus expected 200**; `cold-scroll-after`
passed **13 tests on each simulator**.

Full five-native-composer-turn core acceptance passed on the **iPhone simulator**
in `acceptance-next17155-gjs5t1i_/acceptance-ui.xcresult` and **iPad simulator** in
`acceptance-next17155-rxm_tpkk/acceptance-ui.xcresult`, in separate runs. Normal
cold relaunch after the fix shows the latest canonical content among five user
and five assistant messages, without test scrolling or refresh. The **final
combined-run iPhone failed in Photo Picker: no selected item and Done disabled**.
Preserve that failure; these separate passes are not a new clean combined matrix.

All fixture processes are reported stopped, with no personal-server or
paid-provider calls. Manual widget execution, actual Share-host invocation and
Shortcuts remain untested; the user will check Shortcuts. Main confirmed current
lint **passed for 1,492 entries across seven catalogs**; the cold-position fix
adds no copy, and this documentation update does not rerun lint.

Main confirmed a fresh `iphoneos` build in `.derived-data-device` succeeded,
strict code-sign verification passed, and `devicectl` installation of
`com.ntoporcov.openclient` on Nic iPhone **SUCCEEDED**. The log is
`auto-detection-device-build.log` under the approved temporary opencode directory.
The automatic-detection/cold-position build is **now installed**, superseding
Thinking-sequence. **Launch FAILED because the phone was locked**; unlock and
open OpenClient manually. Prior positive feedback applies to the previous build,
not hands-on validation of this one. This handoff changes only the four requested
Markdown files, not script/source code, and runs no builds, tests or server calls.
No commit/push was requested; obtain current user approval before committing.

### Historical Core UI Acceptance: September 8, 2026

Main reported the final normal-mode core test passing on each **fresh owned
iPhone 17 Pro Max and iPad Pro 13-inch (M5), stable Xcode 26.3, iOS 26.3.1**:
`acceptance-next17155-binfvy2o/acceptance-ui.xcresult`, **one passed, zero failures,
zero skips per device**. Artifacts are in that run's `acceptance-ui-attachments`
directory under the approved temporary parent. The UI agent's core work is
complete; these instructions are not a request to edit app/UI-test code.

The five native composer turns verify first/progress text visible **before**
provider finish, reasoning separate from answer, native Stop closing provider
HTTP with canonical `aborted` and successful follow-up, and a native Photos PNG
with matching canonical/provider fingerprint and **6,247 decoded bytes**.
Background completion catches up on foreground without pull; cold normal
relaunch uses saved credentials and restores five user/five assistant messages
with unique IDs. Provider `held` alone is not UI evidence: visible first/progress
must be asserted before releasing finish. This is actual-runtime scripted-model
acceptance, not paid inference or injected assistant messages.

Historical final units: `acceptance-part-end-unit-final.xcresult`, **1,290 passed, 13 skipped,
1,303 total per device**. These include production fixes for New Session returning
after admission rather than hiding streaming while awaiting execution, and
matching unfinished live-owned part preservation against empty HTTP bodies.
Completed canonical parts win even inside an ongoing message.

General recovery's real-adapter mocked-408 and seeded root/dedicated-window UI
coverage for Legacy and v2 is separate from this next-17155 core test. Cold
transcript relaunch does not establish uncertain-payload persistence across app
kill; recovery remains process-memory only. No personal-server restart evidence
is claimed.

Earlier backend smoke passed ten actual-server scenarios, including command/game
flows. **Safari Share from the actual host and native widget/game execution UI
remain untested.** Native Photos composer coverage is not Share-extension
invocation. The user will check Shortcuts manually. Live Activity cold-process
OS restoration, Lock Screen/Dynamic Island and physical background behavior are
also unverified. No paid-provider fallback, user plugin, personal 4096/4097
mutation, or physical-phone launch success is implied by these results.

### Backend Smoke

`smoke.py` waits for `/api/event`'s `server.connected`, admits prompts with
`resume: true`, observes `session.text.delta` while the provider has not finished
and `/api/session/active` says running, releases the next gate, then uses native
`/wait` and `/context`. It checks exactly one model request per turn, exact
canonical text/reasoning, image fingerprints, canonical interruption, and a
successful follow-up on the interrupted session. It additionally checks public
page/download bytes, URL-share routing, native command evaluation, and game
setup/answer formats through real sessions. It uses no sleep-based timing
or test-side cancellation to manufacture a successful streaming result.

Private evidence files are `smoke-evidence.json`, `network-evidence.json`, and
`provider-events.jsonl`. Diagnostics are `server.log` and `supervisor.log`.
Run evidence is intentionally outside the repository. The smoke test creates
eight owned sessions and ten prompts, retaining them for later inspection.
The fixture regression suite now has 16 tests, including strict URL-origin
decoding, PNG dimensions/CRC/pixels, static-route traversal rejection, unique
output identity, and product-source game-prompt/format validation.

## Source Verification

The installed **17155 source maps**, not the current web config schema, are the
authority for this pinned fixture. Reproduce the important inspections:

```bash
python3 -B scripts/acceptance/inspect_runtime.py /schema/src/config/provider.ts --full
python3 -B scripts/acceptance/inspect_runtime.py /core/src/provider.ts --lines isAISDK
python3 -B scripts/acceptance/inspect_runtime.py /core/src/model-resolver.ts --full
python3 -B scripts/acceptance/inspect_runtime.py /core/src/config/plugin/policy.ts --full
python3 -B scripts/acceptance/inspect_runtime.py /schema/src/prompt-input.ts --full
python3 -B scripts/acceptance/inspect_runtime.py /ai/src/protocols/openai-chat.ts --lines reasoning_content
python3 -B scripts/acceptance/inspect_runtime.py src/server-process.ts --lines OPENCODE
python3 -B scripts/acceptance/inspect_runtime.py /protocol/src/groups/session.ts --full
```

Native JSON configuration supports `providers.<id>.package`, `settings.baseURL`,
`models`, model `capabilities`, and `experimental.policies`. Crucially, native
package identity is **`aisdk:@ai-sdk/openai-compatible`**. An unprefixed SDK
package takes the external package-loading path and is not equivalent.
`ModelResolver.fromCatalogModel` maps the prefixed compatible package straight
to `OpenAICompatibleChat.route`; prefixed `@ai-sdk/anthropic` maps to Anthropic
Messages, but this fixture intentionally implements only Chat Completions.

`Config.discover` loads `opencode.json`/`opencode.jsonc` from the isolated global
config directory, and project discovery is disabled via the verified environment
option. `OPENCODE_MODELS_PATH` points to a valid empty catalog and the fetch flag
is off. Catalog routes can briefly return an empty startup snapshot before
plugin settlement; the supervisor waits for the singleton scripted catalog.
This configuration is generated only in the marked runtime root, never into
the application's repository or personal OpenCode configuration.
