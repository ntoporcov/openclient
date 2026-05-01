---
description: Commit, push, then upload a TestFlight build
---

Commit the current work, push it to the remote, then send a build to TestFlight.

Follow the repository git safety rules from `AGENTS.md`:

- Inspect `git status`, `git diff` for staged and unstaged changes, and recent `git log` messages before committing.
- Stage only relevant files for the requested change.
- Do not commit secrets or local-only config such as `.env`, credentials, or `project.local.yml`.
- Create a concise commit message that matches the repository style and accurately describes the change.
- If there are no changes to commit, say so before continuing.
- After a successful commit, push the current branch to its upstream remote.
- If the branch has no upstream, push with `git push -u origin <current-branch>`.
- Never force push, amend, reset, or skip hooks unless I explicitly ask.

After the git push succeeds, upload to TestFlight with:

```bash
fastlane ios beta
```

If Fastlane fails because App Store Connect credentials or signing are missing, report the exact blocker and stop.
