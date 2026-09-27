# Git workflow

- Do not commit unless explicitly asked, even when it would obviously
  help (e.g. to make `package-vc-install` work, which only clones
  committed content). This mirrors the author's own global Claude Code
  instructions — binding here too, not just a suggestion.
- Never assume a decision already made (installation method, license,
  file layout, a design tradeoff) is up for silent revision. If a
  better approach occurs to you than something already decided,
  propose it and ask — do not substitute your own judgment and
  disclose the substitution after the fact. That already happened once
  in this project's history (an unrequested switch away from the
  decided `package-vc-install` installation method) and was corrected.
- **Never use a git command that changes anything in the workspace
  unless the user has directly approved that specific action** —
  `checkout`, `restore`, `reset`, `clean`, `stash`, `add`, `commit`,
  `apply`, `revert`, `merge`, `rebase`, or anything else that mutates
  tracked files, the index, or history. Read-only commands (`status`,
  `diff`, `log`, `show`) are always fine on their own. Approval must be
  **direct and for that action** — never inferred from "the user seems
  fine with it," from a prior approval of a *different* git action, or
  from the action being a convenient way to undo something you just
  did yourself. This already went wrong once in this project's
  history: `git checkout -- corral-core.el`, run to undo a deliberately
  reintroduced test bug, silently discarded a real, still-uncommitted
  fix in the same file along with it — nobody approved that checkout,
  it was just assumed to be safe cleanup.
