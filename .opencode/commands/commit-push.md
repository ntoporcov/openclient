---
description: Commit current changes and push the current branch
---

Commit the current work and push it to the remote.

Follow the repository git safety rules from `AGENTS.md`:

- Inspect `git status`, `git diff` for staged and unstaged changes, and recent `git log` messages before committing.
- Stage only relevant files for the requested change.
- Do not commit secrets or local-only config such as `.env`, credentials, or `project.local.yml`.
- Create a concise commit message that matches the repository style and accurately describes the change.
- If there are no changes to commit, say so and stop.
- After a successful commit, push the current branch to its upstream remote.
- If the branch has no upstream, push with `git push -u origin <current-branch>`.
- Never force push, amend, reset, or skip hooks unless I explicitly ask.
