# Isolated OpenCode v2 Acceptance Fixture

This harness runs the official OpenCode v2 CLI against a generated local
provider. It is integration infrastructure, not a full-parity claim.

## Pinned Release

- Version: `2.0.16`
- Official npm package: `@opencode/cli@2.0.16`
- Platform package: `@opencode/cli-darwin-arm64@2.0.16`
- CLI npm integrity: `sha512-x8FzHgXduEoFWQsuTZ5K/uyOCCwqa6jDVQt6P0lQkhsYCCQpiwUisjnmdzZlmaJuHwEVUmE4tH9YyW472gTDzQ==`
- Platform npm integrity: `sha512-WlzjaxNb/QY/nJk93AbFNmlxpb5YDdy/2/6FPLbd10QbrkYtfz1TmI6Y0sM3BASDOLG/yJ+0oBfj9OZ5fZ5rfA==`
- Release metadata: `https://opencode.ai/update/api/latest/cli/npm`
- Release ref/SHA: `refs/heads/v2`, `0bc8b8dbeb9540842ae5a69bb5c9af3182999522`
- Installed executable: `~/Library/Application Support/OpenCode-v2/runtime/2.0.16/node_modules/@opencode/cli/bin/opencode.exe`
- Installed executable SHA-256: `27aff98364f326b929a86ebd013c44c9b2ea60bd90e1c2f219e236cd0932e70f`

Both the npm launcher and installed Darwin ARM64 binary have that SHA-256 and
report `opencode v2.0.16`. The package is saved exactly, without a semver range.
The historical `0.0.0-next-17155` and mistakenly investigated `1.18.32`
directories remain unchanged as sibling evidence; this fixture executes neither.

The v2 npm binary does not ship source maps. `inspect_runtime.py` reports the
official v2 source location when no map matches instead of reading preview maps.

## Safety Boundary

Every start creates a private `acceptance-v2_0_16-*` directory below the explicit
host root. It defaults to `opencode` under the host's real temporary directory
(not a simulator's `NSTemporaryDirectory`). On the current host this is:

```text
/var/folders/bx/ws0x9vrd1nz80k39106nn8cw0000gn/T/opencode
```

The run owns all of these paths:

- an empty non-Git `workspace`
- a committed disposable `git-fixture`
- an empty `copies` destination for worktree lifecycle tests
- private HOME, XDG config/data/cache/state/runtime, temporary storage, database,
  model catalog, logs, and generated credentials

The fixture never reuses `pass2-VwCj6l`, a personal server, personal
configuration, Keychain credentials, or provider credentials. Existing listeners
on ports `14097` or `14098` cause startup to fail closed; the fixture never kills
or authenticates to them.

The supervisor, runtime, provider, and descendants inherit a macOS kernel sandbox.
Only loopback ports `14097` and `14098` are allowed. `network_probe.py` verifies an
allowed provider connection and an `EPERM` denial for numeric TEST-NET-1 egress.
Ports `4096` and `4097` are not allowed.

The runtime starts with `serve --hostname 127.0.0.1 --port 14097`, an empty model
catalog, model fetching disabled, only provider `test` enabled, no plugins,
sharing and updates disabled, and a deny-all tool permission. The generated
provider token is accepted only by the loopback scripted server. Unmarked prompts
are rejected locally. v2.0.16 does not support the former `--pure` flag.

## Run

From the repository root:

```bash
RUNTIME_ROOT="$HOME/Library/Application Support/OpenCode-v2/runtime/2.0.16"
mkdir -p "$RUNTIME_ROOT"
npm install --prefix "$RUNTIME_ROOT" --save-exact '@opencode/cli@2.0.16'
python3 -B scripts/acceptance/inspect_runtime.py --verify

export OPENCLIENT_ACCEPTANCE_HOST_ROOT="$(python3 -c 'import tempfile; print(tempfile.gettempdir() + "/opencode")')"
mkdir -p -m 700 "$OPENCLIENT_ACCEPTANCE_HOST_ROOT"
python3 -B -m unittest discover -s scripts/acceptance -p 'test_*.py' -v
MANIFEST="$(python3 -B scripts/acceptance/fixture.py start)"
python3 -B scripts/acceptance/fixture.py status "$MANIFEST"
python3 -B scripts/acceptance/network_probe.py "$MANIFEST"
python3 -B scripts/acceptance/smoke.py "$MANIFEST"
python3 -B scripts/acceptance/fixture.py stop "$MANIFEST"
```

`start` prints only the manifest path. The manifest is mode `0600` and contains
generated secrets, so never print or commit its contents. On failure, private logs
remain beside it. `stop` authenticates the fixture supervisor and terminates only
its recorded child; there is no process-name kill or force-kill fallback.

## v2 API Contracts

The release's own OpenAPI document is available at `GET /openapi.json`. v2.0.16
serves its JSON protocol under `/api/*`; old top-level v1 routes resolve to the web
application rather than acting as compatibility aliases.

| Purpose | v2.0.16 contract |
| --- | --- |
| Identity | `GET /api/info` returns `version`, server `pid`, URLs, and runtime paths |
| Location | `GET /api/location` returns the owned `{directory, project}` |
| Providers/models | `GET /api/provider` and `GET /api/model` return `{location, data}` |
| Commands/agents | `GET /api/command` and `GET /api/agent` return `{location, data}` |
| Sessions | `GET /api/session` returns `{data, cursor}`; `POST /api/session` accepts `location` |
| Active sessions | `GET /api/session/active` returns `{data: {sessionID: {type: "running"}}}` |
| Messages | `GET /api/session/:id/message` returns projected records in `{data, cursor}` |
| Prompt | `POST /api/session/:id/prompt` accepts flat `{text, files, resume}` |
| Interrupt | `POST /api/session/:id/interrupt` reports whether execution was interrupted |
| Delete | `DELETE /api/session/:id` returns `204` |
| SSE | `GET /api/event`; streamed turns use `session.text.delta` and `session.reasoning.delta` |
| Forms | `GET /api/form` is a real v2 JSON endpoint |

`GET /api/health` is absent and returns 404. `GET /global/health` and old
top-level paths such as `/session`, `/provider`, and `/path` return the web app's
HTML, not JSON protocol responses. Clients must validate content type and schema
rather than treating any 2xx response as API support.

The smoke runner exercises `/api/*` session creation, durable flat prompt
admission, first and progress text deltas before provider completion, separate
reasoning SSE/canonical parts, active-to-idle removal, canonical projected message
reads, exact image transfer, interruption, and session deletion. It covers
`stream`, `reasoning`, `attachment`, and `interrupt`; every prompt gets one unique
marker and exactly one scripted provider request.

## Generated Configuration

The live-verified v2.0.16 configuration uses singular keys:

- `provider`, not `providers`
- `agent`, not `agents`
- `command`, not `commands`
- `permission`, not `permissions`
- `plugin`, not `plugins`

The configured model is `test/test-model`. The provider uses
`@ai-sdk/openai-compatible` with base URL `http://127.0.0.1:14098/v1`; the v2 API
projects that implementation as `@opencode/ai/providers/openai-compatible`.
Built-in commands remain present, so readiness requires exactly one configured
`acceptance` command rather than claiming a singleton command catalog.

Each scripted stream writes a role chunk and first text chunk, then holds.
`advance` releases the second chunk and holds again; `finish` releases the final
chunk and `[DONE]`. Control calls are authenticated with the generated Bearer
token. Provider event logs contain marker/scenario identity and media hashes, not
prompt text, authorization headers, URLs, or base64 data.

Private evidence files are:

- `smoke-evidence.json`
- `network-evidence.json`
- `provider-events.jsonl`
- `server.log`
- `supervisor.log`

## Live Swift Tests

Start one fixture, stop it on shell exit, and run all four live classes against
both required simulators with the host root exported above. Resolve the current
required devices with `xcrun simctl list devices available` after selecting stable
Xcode, then export `OPENCLIENT_ACCEPTANCE_IPHONE_UDID` and
`OPENCLIENT_ACCEPTANCE_IPAD_UDID` (the current values appear under UI Runner Policy):

```bash
MANIFEST="$(python3 -B scripts/acceptance/fixture.py start)"
trap 'python3 -B scripts/acceptance/fixture.py stop "$MANIFEST"' EXIT
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
TEST_RUNNER_OPENCODE_V2_TEST_MANIFEST_PATH="$MANIFEST" \
TEST_RUNNER_OPENCODE_V2_TEST_HOST_ROOT="$OPENCLIENT_ACCEPTANCE_HOST_ROOT" \
xcodebuild -quiet \
  -project OpenCodeIOSClient.xcodeproj \
  -scheme OpenCodeIOSClient \
  -destination "platform=iOS Simulator,id=$OPENCLIENT_ACCEPTANCE_IPHONE_UDID" \
  -destination "platform=iOS Simulator,id=$OPENCLIENT_ACCEPTANCE_IPAD_UDID" \
  -disable-concurrent-destination-testing \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:OpenCodeIOSClientTests/OpenCodeV2LiveAPIClientTests \
  -only-testing:OpenCodeIOSClientTests/BackendFeatureLiveTests \
  -only-testing:OpenCodeIOSClientTests/V2LiveFeatureTests \
  -only-testing:OpenCodeIOSClientTests/Pass5LiveIntegrationTests \
  test
```

`OpenCodeV2LiveFixture` validates the private manifest, version, fixed ports,
ownership marker, workspace, Git root, and copy destination before returning any
credentials. Tests no longer trust caller-supplied base URLs, roots, or the stale
`pass2-VwCj6l` path.

### September 24, 2026 release validation

Validated with stable Xcode 27.0 and iOS 27.0 on iPhone 18 Pro Max and
iPad Pro 13-inch (M5):

- Python fixture regression suite: 16 passed.
- Network isolation probe: loopback allowed, external connection denied with EPERM.
- Real 2.0.16 smoke: stream, reasoning, attachment, and interrupt passed.
- Four Swift integration classes: 14 passed, zero skipped or failed on each device
  (`release-live-2.xcresult` under the host acceptance root).
- Five-turn native UI acceptance: one passed, zero skipped or failed on each device
  (`acceptance-v2_0_16-7zrdoqxy/acceptance-ui.xcresult`). This covers visible streaming,
  separate reasoning, Stop/follow-up, Photos attachment, background catch-up, and
  cold relaunch.

The UI run used `test-without-building` with the available compiled binaries after
a new build was blocked by concurrent bridge UI work missing the localization key
`Copy Setup & Open Guide`. It does not certify subsequent source changes. An earlier
UI attempt passed iPhone but lost the iPad XCTest application connection; the fresh
combined rerun passed both devices. All owned fixture processes were stopped.

## Historical Preview Evidence

The following evidence belongs to the former `0.0.0-next-17155` fixture. It is
retained to prevent the v2.0.16 harness upgrade from erasing prior acceptance
history. It is not evidence for the newly pinned release.

### September 9, 2026 Handoff

- Final source units in `cold-scroll-unit-final.xcresult`: 1,383 passed, 13
  skipped, zero failed per device. The unrelated
  `ResponseTurnCaptionTests/testCaptionOccupiesSpaceOnlyWhileRevealed` was
  explicitly excluded, not passing. Accounting was 1,396 reported outcomes plus
  one exclusion.
- `auto-detection-final-ui-1` passed three automatic-connection UI tests per
  device.
- The cold-position regression initially failed at -54 versus expected 200.
  `cold-scroll-after` passed 13 tests on each simulator after `ChatView` retained
  and retried the initial-bottom request until usable collection bounds existed.
- Separate full five-turn core acceptance passed on iPhone in
  `acceptance-next17155-gjs5t1i_/acceptance-ui.xcresult` and iPad in
  `acceptance-next17155-rxm_tpkk/acceptance-ui.xcresult`. The final combined-run
  iPhone attempt failed in Photo Picker because no item was selected and Done was
  disabled; it was never claimed as a clean combined matrix.
- The then-current localization lint passed 1,492 entries across seven catalogs.
- A fresh physical-device build, strict code-sign verification, and installation
  of `com.ntoporcov.openclient` succeeded. Launch failed because the phone was
  locked, so no hands-on validation of that installed build was claimed.

### September 8, 2026 Core UI Acceptance

- Fresh owned iPhone 17 Pro Max and iPad Pro 13-inch (M5) runs on Xcode 26.3 and
  iOS 26.3.1 each reported one passed, zero failures, and zero skips in
  `acceptance-next17155-binfvy2o/acceptance-ui.xcresult`.
- Five native composer turns verified visible first/progress text before provider
  finish, reasoning separate from answer text, native Stop closing provider HTTP
  with canonical `aborted`, successful follow-up after interruption, and a native
  Photos PNG with matching fingerprint and 6,247 decoded bytes.
- Background completion caught up after foregrounding. Cold normal relaunch
  restored five user and five assistant messages with unique IDs, without test
  scrolling or refresh.
- `acceptance-part-end-unit-final.xcresult` reported 1,290 passed and 13 skipped,
  1,303 total per device.

Earlier preview backend smoke covered ten scenarios, including command and game
flows. Safari Share from its actual host, native widget/game execution, Shortcuts,
Live Activity OS restoration, Lock Screen/Dynamic Island behavior, and physical
background behavior remained unverified. No personal-server restart, paid-provider
fallback, user plugin, or physical-phone launch success was implied.

The preview source-map commands and `aisdk:` provider schema documented in the old
README apply only to `0.0.0-next-17155`. They must not be used to infer v2.0.16
configuration or endpoint behavior.

## UI Runner Policy

`run-ui.sh` is optional and follows `.opencode/skills/simulator-device-policy`.
It requires caller-supplied existing simulator UDIDs, verifies their exact model
names and availability on the selected Xcode simulator SDK version, and refuses a
different runtime or substitute device. For the validated Xcode 27.0 setup:

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
OPENCLIENT_ACCEPTANCE_IOS_RUNTIME=27.0 \
OPENCLIENT_ACCEPTANCE_IPHONE_UDID=555B924F-5B94-4070-BDB8-D6BDC700F3F9 \
OPENCLIENT_ACCEPTANCE_IPAD_UDID=C65415E9-FBEF-4B18-AEFC-0A752954360E \
bash scripts/acceptance/run-ui.sh
```

The default action is `test`, which compiles current sources before running. To
reuse existing successfully compiled app and UI-test binaries, explicitly opt in:

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
OPENCLIENT_ACCEPTANCE_TEST_WITHOUT_BUILDING=1 \
OPENCLIENT_ACCEPTANCE_IOS_RUNTIME=27.0 \
OPENCLIENT_ACCEPTANCE_IPHONE_UDID=555B924F-5B94-4070-BDB8-D6BDC700F3F9 \
OPENCLIENT_ACCEPTANCE_IPAD_UDID=C65415E9-FBEF-4B18-AEFC-0A752954360E \
bash scripts/acceptance/run-ui.sh
```

`test-without-building` runs the previously compiled binaries and does not
compile or validate source edits made after those binaries were built.

The runner does not create or delete simulators. It seeds both required devices,
propagates the private manifest through `TEST_RUNNER_*`, runs only
`AcceptanceUITests`, restores devices it booted, and stops its owned fixture.
