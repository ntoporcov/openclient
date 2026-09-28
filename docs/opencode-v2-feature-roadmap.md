# OpenCode V2 Feature Inheritance Roadmap

Reviewed September 27, 2026 against the current V2 documentation, published API contract, and OpenClient implementation. This is a proposed roadmap, not an implementation commitment. These are inheritance opportunities; not all features originated in V2.

## Highest-value additions

| Feature | OpenClient experience | Existing foundation / work needed |
| --- | --- | --- |
| Steering | Send a correction while the agent works, applied at the next step boundary. | We already admit V2 prompts and track delivery events. Add explicit steering intent and composer UX. |
| Server-backed prompt queue | Queue follow-up work, inspect pending messages, cancel pending work, or promote a queued prompt to steering. | V2 exposes inbox listing, cancellation, and delivery-mode changes. We currently track pending IDs but lack queue management. |
| Side questions (`/btw`) | Ask a contextual question in a sheet without changing the main conversation. | `session.generate` produces contextual text without adding it to session history. |
| Undo / redo | Revert a prompt and subsequent work, restore its text to the composer, then edit or redo. | V2 exposes staged revert, clear, and commit operations, with optional file restoration. Requires coordinated history and file handling. |
| Changes per turn | Show affected files and diffs beneath a response or task. | Existing Git diff UI can provide a foundation. `session.diff` supports turn-specific comparisons rather than whole-workspace changes. |
| Background a blocking tool | Continue in the background when a supported long-running tool blocks progress. | `session.background` supports active backgroundable tools, not arbitrary execution. |
| Move a conversation | Move an existing session to another directory or worktree without starting over. | `session.move` complements existing project, worktree, and session navigation. |

Steering and queueing should ship together: they express different intentions—“change what you are doing” and “do this afterward.”

## Additional opportunities

| Feature | Native app opportunity | Scope |
| --- | --- | --- |
| Shell mode in chat | Run commands such as `!git status` and retain output in the conversation. | Separate from the existing terminal; backed by `session.shell`. |
| Context inspector | Show the model's active context and the boundary after compaction. | `session.context`; manual compaction already has an app API wrapper. |
| Skill picker | Browse available skills and explicitly activate one for the session. | Skill listing exists in V2; direct activation uses an experimental endpoint. |
| Precise file references | Attach a file line range such as `file.swift#20-45`. | Documented TUI behavior; audit the app's attachment/composer representation for parity. |
| Usage dashboard | Show session activity, model/token/cost trends, and tool reliability. | Experimental session statistics API; distinct from existing provider-usage UI. |
| Session import/export | Export through the share sheet, import saved transcripts, optionally sanitize exports. | CLI supports import/export and sanitized export; HTTP import/export endpoints are experimental. Verify request options before implementation. |
| Account switching | Switch between saved provider accounts, such as work and personal. | Existing V2 integration authentication can be extended with credential activation. |
| Saved permission management | Inspect and remove remembered approvals by project. | Saved-permission list/remove APIs complement current approval cards. |
| Plugin management | Inspect plugin status, check for updates, and update plugins. | Plugin listing already exists in the app API layer; update operations need integration. |
| Recent-session switcher / tabs | Quickly switch between concurrent tasks, especially on iPad. | Primarily native UI work over existing session state. |

## Existing foundations

These areas already have substantial app support and should be treated as V2 parity work rather than entirely new features:

- Session forking.
- Model and agent switching.
- Slash commands.
- Manual compaction.
- Permissions, questions, and richer V2 forms.
- Worktrees, filesystem browsing, Git diffs, and terminals.
- Provider authentication and MCP status/connect controls.

## Recommended implementation order

1. **Steering and queue management:** the main V2 interaction upgrade.
2. **Side questions:** a focused feature with a dedicated API.
3. **Per-turn changes:** better supervision from a phone.
4. **Undo/redo:** pairs naturally with reviewing changes.
5. **Background tools and session moves:** stronger control over ongoing work.
6. **Context/skills, usage, and configuration management.**

## Implementation direction

Most execution machinery lives on the server. OpenClient primarily needs typed API support, store/event handling, and native controls.

- Keep transport methods in `API/` and canonical feature state in focused stores.
- Route asynchronous workflows through coordinators.
- Extend the shared event pipeline and reducers for queue and delivery changes.
- Reconcile server state after reconnects; V2's shared event subscription is live-only and does not replay missed events.
- Version-gate experimental endpoints and verify the connected server's contract before implementation.
- Preserve the distinction between server-backed behavior and client-only presentation such as tabs.

Relevant existing implementation surfaces:

- `OpenCodeIOSClient/API/OpenCodeAPIClient.swift`
- `OpenCodeIOSClient/API/OpenCodeAPIClient+V2Configuration.swift`
- `OpenCodeIOSClient/API/OpenCodeEventManager.swift`
- `OpenCodeIOSClient/Stores/ChatStore.swift`
- `OpenCodeIOSClient/Views/Chat/MessageComposer.swift`
- `OpenCodeIOSClient/Views/Git/GitDiffView.swift`

## Sources

- [V2 TUI](https://opencode.ai/v2/docs/cli/tui/)
- [V2 CLI commands](https://opencode.ai/v2/docs/cli/commands/)
- [V2 client guide](https://opencode.ai/v2/docs/build/client/)
- [V2 OpenAPI contract](https://opencode.ai/v2/openapi.json)

API availability and experimental contracts may change after the review date.
