# Architecture

Per-file responsibilities. Flat `.el` files at repo root, organized by
filename prefix, not subdirectories: MELPA's default file-globbing
and `load-path` not recursing both argue against a `harnesses/`-style
subdirectory. Package name == file name == `provide` symbol, per file.

- `corral.el` — entry point: package headers, requires everything.
- `corral-core.el` — session registry (`corral--sessions`), state
  model (working/blocked/idle), `corral-session-change-hook` (the
  panel and other observers hook in here instead of being called
  directly, so this file stays independent of any UI).
  `corral-recover-sessions` reconstructs a session from a still-live
  process's stashed identity properties after something (e.g.
  `corral-reload-from-source`) has wiped `corral--sessions` and every
  buffer-local variable out from under an otherwise-untouched vterm
  buffer -- see the "Reload vs. persistence" note below.
  Also `corral-switch-to-attention`, ordering candidates by attention
  (`corral-attention-order`). Plain `completing-read` on purpose,
  keeping this file UI-agnostic like the rest of core. Lives here, not
  the panel: it reads only the registry and switches in place with
  `pop-to-buffer-same-window`, needing no panel window open.
  `corral-session-mode` is a buffer-local minor mode auto-enabled in
  every tracked session buffer (`corral--register`) and the panel
  (`corral-panel-mode`); its purpose is `C-h m` discoverability -- it
  carries corral's help docstring and a small keymap so `describe-mode`
  in a corral buffer documents the tool and its keys in context. Its
  binding of `corral-switch-to-attention` is for that in-context help;
  the from-anywhere invocation stays a separate global binding, since a
  buffer-local map is not active in the unrelated buffer you jump from.
- `corral-panel.el` — hand-rendered side panel (deliberately not
  `tabulated-list-mode`, which forces a header row and fixed-width
  columns that don't fit a narrow, discreet window): two compact
  lines per session, abbreviated label + colored state, elapsed time
  underneath. A left-gutter marker (`corral-panel-visible-marker`) and
  a focused-label face (`corral-panel-focused`) flag visible and
  selected-window sessions. Because window changes (split, switch,
  select) never run `corral-session-change-hook`, the refresh is also
  driven off `window-configuration-change-hook` and
  `window-selection-change-functions` so those markers stay live; the
  refresh is panel-only and touches no window configuration, so there
  is no feedback loop. `corral-show-panel`, `corral-rename-session`,
  `corral-switch-to-session`.
- `corral-vterm.el` — vterm glue: `corral--vterm-spawn`,
  `corral--vterm-send-command`, `corral--buffer-tail` (character-budget
  tail extraction for screen-scraping harnesses).
- `corral-harness.el` — the `corral-harness` struct, the variant table
  (`corral-harness-add-variant`), `corral--do-launch`,
  `corral--project-root-name`. Also the launch entry points
  `corral-launch` (a completion dispatcher over every variant) and
  `corral-launch-map` (a prefix keymap), whose keys are generated from
  the registered harnesses rather than hardcoded -- rebuilt by
  `corral-harness-add-variant` so a harness added later gets a key with
  nothing to edit, consistent with corral's discover-harnesses-
  dynamically approach elsewhere.
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
- `corral-scrape.el` — generic scrape-strategy plumbing, the
  scrape-strategy counterpart to `corral-hook.el`: a single shared
  timer (`corral-scrape--tick`) that scans every tracked session whose
  harness has `:strategy 'scrape`, started/stopped purely by observing
  `corral-session-change-hook` rather than explicit calls from
  `corral--do-launch` or a kill-buffer hook.
- `corral-antigravity.el` — the Antigravity harness (scrape strategy,
  since `agy` has no hook system): `corral-antigravity--classify`,
  ported from a real captured PoC (see
  `../emacs-herd/antigravity-plan.md`) and pinned to one `agy` version
  -- must be re-verified against a live session before being trusted
  further, per `.agents/rules/harness-design.md`'s evidence-based-
  detection principle.
- `corral-kiro.el` — the Kiro CLI harness (scrape strategy). Kiro
  CLI (`kiro-cli`) does have agent-lifecycle hooks, but they only fire
  for a named agent config file (not the built-in default a plain
  `kiro-cli chat` runs) and none of its triggers maps to
  blocked-on-permission, so this uses screen-scraping like
  antigravity: `corral-kiro--classify`, ported from herdr's
  `kiro.toml` manifest. Same caveat as antigravity -- the rules were
  captured by herdr, not corral, and must be re-verified against a
  live `kiro-cli` before being trusted further. Deliberately omits
  kiro.toml's OSC-title/progress working rules: those match terminal
  escape sequences, not rendered buffer text, and corral's scrape
  strategy only ever sees the buffer tail.
- `test/` — ERT tests, kept out of MELPA's default glob on purpose.
- `examples/setup-corral.el.example` — template user config
  (installation, registering launch variants), kept out of the
  installed package the same way `test/` is. The author's own real
  config living outside this repo (`~/.emacs.d/setup-files/setup-corral.el`)
  follows this same pattern.

## Reload vs. persistence

`corral--sessions` is pure in-memory state, never written to disk --
restarting Emacs loses it along with the actual tracked processes
(vterm's child processes die with the Emacs process itself, so there's
nothing worth persisting across a real restart).

`corral-reload-from-source` (see the devel example above) is a
different case: it calls `unload-feature` on every `corral-*` symbol to
pick up uncommitted source changes mid-session, which leaves the vterm
buffers and their processes running untouched but wipes
`corral--sessions` *and* every buffer-local variable a reloaded file
defined -- verified directly, not assumed: a buffer-local variable's
per-buffer value does NOT survive its defining file being unloaded and
reloaded, even though the buffer itself is never touched. That rules
out recovering a session's identity from anything `defvar`/`defvar-local`
based, including the pane-id variable itself.

What does survive is a live process's own property list -- entirely
outside any file's `load-history`, so `unload-feature` has no way to
touch it. `corral--register` therefore also stashes
pane-id/harness/variant/suffix as process properties (`process-put`),
and `corral-recover-sessions` walks `(process-list)` afterward to
re-`corral--register` any live one whose properties aren't yet back in
`corral--sessions`. Recovered sessions start at state `unknown` -- only
identity survives, not last-known state -- and resync from there via
each harness's own detection strategy (next hook event, or next scrape
tick once `corral-scrape--sync-timer` notices the reconstructed
session and restarts the shared timer).
