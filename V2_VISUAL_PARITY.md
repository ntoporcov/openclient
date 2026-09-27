# V2 visual parity audit

September 27, 2026. Baseline: the native V1 UI in this repository. This is a presentation audit, separate from the transport/capability inventory in `V2_PARITY_CHECKLIST.md`.

## Confirmed gaps and changes

| Surface | V1 baseline | V2 gap | Change |
| --- | --- | --- | --- |
| Chat questions | Individually paged glass cards | One stacked generic form | Typed form fields now use a horizontal carousel with stable field-key identity and bounded vertical scrolling. |
| Question choices | Padded glass rows; radio/check-box distinction | Unpadded rows; circles for both selection types | Share `QuestionOptionButton` between profiles, including selected state, descriptions and accessibility traits. |
| Question hierarchy | Short header above the full question | Field description rendered as secondary caption | Use the field title as the header and its description as the main question, with title fallback. |
| Question navigation | Page indicators and single-choice auto-advance | No question-by-question navigation | Share page indicators; advance through the freshly resolved active field list so conditional questions are not skipped. |
| Custom answers | Visually distinct answer field | Plain text input; selected catalog value echoed into custom input | Glass input treatment, separate custom presentation, and keyboard Done commits a custom multiselect value. |
| Question actions | Separate capsule action bar and prominent Submit | Small inline actions in the same card | Separate glass action bar, full-height actions, and contract-driven Submit availability. |
| Form accessibility | Dedicated question controls | Parent identifier propagated over descendants | Explicit panel containment and stable field/page/choice/action identifiers. Updated existing form UI test selectors. |
| Tool activity | Recognized Shell/Patch labels and icons | V2 `shell`/`patch` names missed legacy-only presentation cases | Recognize both names without changing canonical tool identity or interpreting output. |

The V2 editor continues to submit typed values by field key. Defaults, optional/unset values, conditions, number bounds, custom multiselect values, external acknowledgement, uncertainty recovery and cancellation remain backed by the existing form contract/store/coordinator. Labels are never substituted for wire values. Project requests retain their stacked form layout while sharing the improved action controls.

## Other surfaces reviewed

| Surface | Finding |
| --- | --- |
| Permissions | Both profiles render `PermissionActionStack` / `PermissionCard`; no separate V2 card style found. Permission priority over forms remains in `ChatView`. |
| Transcript, reasoning, composer, attachments | Shared native presentation; V2-specific paths primarily handle admission/recovery and transport. This source audit does not establish live streaming or attachment fidelity. |
| Session list and navigation | Shared presentation, with a V2 connection notice. No separate V2 row layout found. |
| Providers/configuration | Intentionally separate V2 integration/authentication flow; matching legacy credential controls would misrepresent the V2 contract. |
| Todos | V2 todos are explicitly gated in `ChatFacade`. The current published V2 OpenAPI was rechecked in pass 2: no todo paths, schemas or events. Keep canonical todos unavailable until a supported contract is exposed. |
| Project appearance/worktree actions | Stable V2 worktree list/create/remove/refresh are supported. Pass 2 removes the obsolete mandatory destination field. Project appearance writes and destructive reset remain separate contract gaps. |
| Live Activities | V2 forms route to the app for typed editing; legacy inline answer flattening would lose V2 field semantics. |

## Verification

- Deterministic `question` screenshot fixture: set `OPENCLIENT_V2_QUESTION_FIXTURE=1` alongside `OPENCLIENT_SCREENSHOT_SCENE=question`.
- UI regression: `testV2QuestionCarouselPreservesTypedAnswers` exercises choice selection, auto-advance, multiselect/custom input, back-navigation retention, typed result and cancellation.
- Existing `SessionFormTests` cover typed/default/conditional/unsupported forms and coordinator state.
- Initial run: 24 form tests and one UI test passed on **each** iPhone 18 Pro Max and iPad Pro 13-inch (M5), iOS 27.0, Xcode 27.0. Screenshot review found excessive iPad carousel overflow and oversized action buttons; both were corrected before the final run.
- Final run: **25 passed, zero failures/skips on each device** (50 executions). Final screenshot review confirmed both layout issues resolved, with readable active text and correct selection controls. Result bundle: `v2-visual-parity-final.xcresult` under the OpenCode temporary artifact directory.
- Catalog/source localization lint and `fastlane ios lint_localizations` passed. Fixed copy reuses existing translated keys.
- Live-server form delivery, physical-device keyboard behavior, and unrelated V2 capabilities were not exercised by this deterministic fixture.

## Pass 2: todos, worktrees and error states

Contract source: [published V2 OpenAPI](https://opencode.ai/v2/openapi.json), inspected September 27, 2026. The local `opencode` executable exposes the old CLI and does not accept `opencode api`; these findings are published-contract evidence, not a live personal-server verification.

### Todos

The published schema contains no todo endpoint, schema or event (including a recursive search of schema values). The existing V2 gate stays in place. Parsing tool output into a supposedly canonical todo list would violate the app's source-of-truth model. Existing native todo views remain available for V1.

### Worktrees

- Stable `POST /api/worktree` requires only `projectID`; `directory`, `name`, `from`, and `branch` are optional. The server loads canonical configuration and runs its setup script.
- Fixed the client requiring `directory` for all V2 versions. Stable V2 now omits blank destinations and uses the server default. Preview next-17155 still requires an absolute destination parent and retains its original endpoint.
- Optional directory overrides remain editable in workspace creation, session creation, project-chat creation and project settings. All entry points share destination validation and explain the server-default behavior.
- Creation shows progress and disables Cancel while the request is running.
- Workspace-operation failures remain visible beside existing session rows; an error no longer disappears merely because the workspace has sessions.
- Dirty-worktree confirmation includes the server's reason alongside the affected directory and the existing session-history explanation.

### Still open

- `from` and `branch` are present in the current create contract but have no native controls yet. They should no longer be described as absent server capabilities. Server-configured setup runs during creation; editing that setup is a separate configuration feature.
- The published contract still has no destructive worktree reset endpoint. Inventory refresh is not reset.
- Live default-directory creation, setup failures, physical-device error presentation and a current server's todo/plugin behavior remain unverified.

### Pass 2 verification

- Added regression coverage for omitted/blank stable destinations, explicit overrides, preview-required destinations and invalid paths. Existing removal/force/inventory/connection-scope tests remain in `BackendWorktreeTests`.
- Localization catalog/source check passes with the new helper text translated to English, Italian and Brazilian Portuguese.
- Xcode 27.0: **19 worktree tests passed on each** iPhone 18 Pro Max and iPad Pro 13-inch (M5), iOS 27.0; zero failures/skips (38 executions). Bundle: `v2-worktree-pass.xcresult` under the OpenCode temporary artifact directory.
- The full `fastlane ios lint_localizations` build passed.

## V2 send draft retention

The composer previously cleared text and attachments before preflight/submission, then tried to restore them only if the original context, revision and reset token still matched. Early cancellation or a context change could bypass that restoration altogether. V2 now retains the original draft until a successful operation or exact-ID admission evidence, and clears only an unchanged draft belonging to that same chat/context. Rejection leaves the original whitespace, mentions and attachments intact; uncertain admission retains the existing read-only reconciliation path rather than issuing another POST.

`SubmissionRecoveryUITests.testV2DraftClearsOnlyAfterAdmissionInRootAndWindow` uses a held local URLProtocol response to check draft retention during submission, rejection retention, and clearing after acceptance, in root and dedicated chats. This reproduces the unsafe clearing boundary deterministically; it does not establish which server/preflight failure occurred in the reported device incident.

Validation: 55 V2 workflow/transcript unit tests passed on each required simulator in `v2-draft-retention-2.xcresult`. After isolating the fixture's persisted draft between cases, the UI regression passed on each device in `v2-draft-retention-ui-final.xcresult` (four acceptance/rejection × root/window cases per device). Devices: iPhone 18 Pro Max and iPad Pro 13-inch (M5), iOS 27.0, Xcode 27.0. These are separate runs, not a single combined passing bundle. Localization lint also passed.
