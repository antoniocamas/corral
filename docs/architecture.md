# Architecture

Per-file responsibilities. Flat `.el` files at repo root, organized by
filename prefix, not subdirectories — see `../SKELETON.md` in the
sibling `emacs-herd` checkout for why (MELPA's default file-globbing
and `load-path` not recursing both argue against a `harnesses/`-style
subdirectory). Package name == file name == `provide` symbol, per file.

- `corral.el` — entry point: package headers, requires everything.
- `corral-core.el` — session registry (`corral--sessions`), state
  model (working/blocked/idle), `corral-session-change-hook` (the
  panel and other observers hook in here instead of being called
  directly, so this file stays independent of any UI).
- `corral-panel.el` — hand-rendered side panel (deliberately not
  `tabulated-list-mode`, which forces a header row and fixed-width
  columns that don't fit a narrow, discreet window): two compact
  lines per session, abbreviated label + colored state, elapsed time
  underneath. `corral-show-panel`, `corral-rename-session`,
  `corral-switch-to-session`.
- `corral-vterm.el` — vterm glue: `corral--vterm-spawn`,
  `corral--vterm-send-command`, `corral--buffer-tail` (character-budget
  tail extraction for screen-scraping harnesses).
- `corral-harness.el` — the `corral-harness` struct, the variant table
  (`corral-harness-add-variant`), `corral--do-launch`,
  `corral--project-root-name`.
- `corral-hook.el` — generic hook-strategy plumbing shared by every
  hook-capable harness: `corral-report` (the entry point a hook script
  calls back into via `emacsclient`), `corral-hook-confirm-and-write`,
  `corral-hook-json-pretty` (indented JSON for human-readable
  settings-file diffs -- never `json-serialize` directly, which is
  always compact/single-line).
- `corral-claude.el` — the Claude Code harness (hooks strategy):
  `corral-claude-install-hooks`, the settings.json merge logic
  (`corral-claude--merge-hooks`), the default `claude` launch variant.
- `corral-hook.sh` — one generic hook script, shared by every
  hook-capable harness; a settings-file installer only needs to point
  at it, never write its own copy.
- `test/` — ERT tests, kept out of MELPA's default glob on purpose.
- `examples/setup-corral.el.example` — template user config
  (installation, registering launch variants), kept out of the
  installed package the same way `test/` is. The author's own real
  config living outside this repo (`~/.emacs.d/setup-files/setup-corral.el`)
  follows this same pattern.
