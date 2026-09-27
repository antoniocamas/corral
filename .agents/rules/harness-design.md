# Harness and variant design

- **A harness describes detection only** — hooks vs. screen-scraping,
  and how to recognize working/waiting/idle. It never describes how to
  launch the tool. `corral-harness` has no command/launch slot.
- **A variant describes one way to launch** a harness: a plain command
  string, registered via `corral-harness-add-variant`, typically from
  the user's own config (e.g. `setup-corral.el`), not hardcoded into
  the harness's own defining file (`corral-claude.el` etc.). Personal
  wrapper scripts and flags are not this package's concern — no env
  slot on a variant either, since a wrapper already manages its own
  environment.
- **corral never fully automates buffer naming.** `corral--do-launch`
  always prompts for a session-name suffix, pre-filled with a computed
  default (`project.el` root name, or directory basename). A workspace
  root holding several sibling repositories is a real, common case
  where automatic project detection has nothing useful to suggest.
- **A hook installer always confirms before writing**, via
  `corral-hook-confirm-and-write` — never a silent auto-install, even
  with a backup made. A new hook-capable harness's installer should go
  through that function, not write settings files directly.
- **Recognize a harness's own previously-installed hook entries by the
  hook script's basename, not its full path** (see
  `corral-claude--entry-is-ours-p`). corral's own install location can
  change between installs (a different checkout, a relocated clone);
  matching on the full path leaves old entries orphaned as
  unrecognized stray hooks instead of being replaced. Regression test:
  `corral-claude-test-merge-replaces-corral-owned-entry-in-place`.
- **Screen-scraping tail extraction is a character budget, not a line
  count** (`corral-vterm-tail-chars`). A fixed line-count tail can miss
  real content entirely on a tall terminal window if a full-screen TUI
  pads unused rows with blank lines below its actual status — observed
  directly during the original PoC, not theorized.
- **Screen-scraping rules must be evidence-based**, same principle as
  herdr's own (`herdr/CLAUDE.md`, sibling checkout under the workspace
  root): capture real screen/tail text from the actual running tool
  and write rules against that, never against another tool's manifest
  or a guess. A borrowed herdr manifest rule (braille spinner glyph,
  lowercase permission-request phrasing) matched nothing in the
  actually-installed Antigravity CLI version during the PoC.
