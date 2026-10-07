# Harness and variant design

- **A harness describes detection only** — how to recognize
  working/blocked/idle from the screen. It never describes how to
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
- **Every harness is detected by screen-scraping; corral installs no
  hooks and edits no tool config files.** Claude Code was hook-based
  once and that was the source of a real bug: no hook fires when a turn
  is interrupted with Esc, and an API-error turn ends without `Stop`,
  so sessions stayed `working` forever. The screen cannot go stale that
  way. A new harness should not reintroduce a callback channel just
  because the tool has one -- see `docs/inspiration.md` (herdr does the
  same for Claude Code).
- **Screen-scraping tail extraction is a character budget, not a line
  count** (`corral-vterm-tail-chars`). A fixed line-count tail can miss
  real content entirely on a tall terminal window if a full-screen TUI
  pads unused rows with blank lines below its actual status — observed
  directly during the original PoC, not theorized.
- **Screen-scraping rules must be evidence-based**: capture real
  screen/tail text from the actual running tool and write rules
  against that, never against another tool's manifest or a guess. A
  borrowed manifest rule (braille spinner glyph, lowercase
  permission-request phrasing) matched nothing in the
  actually-installed Antigravity CLI version during the PoC.
