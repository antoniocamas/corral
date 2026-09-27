# AGENTS.md — corral

**corral** is an Emacs package that tracks coding-agent sessions
(Claude Code today, other harnesses later) running in `vterm` buffers,
and shows them in a side panel color-coded by state: working, waiting
for input, or idle. Inspired by studying
[herdr](https://herdr.dev) — a similar tool built as its own standalone
terminal multiplexer — but corral lives inside Emacs and relies on
`vterm` already owning the underlying processes, so it never needs to
be one itself.

### Project Profile

- **Scale:** small. One Emacs Lisp package, 8 files at repo root (no
  sub-packages), roughly 700–900 lines of Elisp, tree two levels deep
  (`test/`, `.agents/rules/`, `docs/`).
- **Conventionality:** bespoke. The flat-file layout and ERT usage are
  standard Elisp package convention, but two invented, non-obvious
  structures govern real work here and are not inferable from general
  Elisp knowledge: the harness/variant separation (detection is never
  coupled to launch) and `json-serialize`/`json-parse-string`'s
  plist+vector requirement with raw-byte output needing explicit
  decoding.
- **Context budget:** small. All source and tests fit comfortably in a
  single context window.

## Repository Structure

- `*.el` (root) — the package itself; flat, one file per
  responsibility. See `docs/architecture.md`.
- `docs/` — system documents indexed below.
- `.agents/rules/` — rules indexed below.
- `test/` — ERT tests.

## Constraints (bind every task, including read-only ones)

- Never run anything against the author's live, actively-used Emacs
  session beyond a trivial read-only check without the author present
  — see `.agents/rules/live-session-safety.md`. Validate in an
  isolated throwaway daemon first, always.
- Do not commit unless explicitly asked — see
  `.agents/rules/git-workflow.md`.
- Treat every already-made decision (installation method, license,
  file layout, a design tradeoff) as settled. If a better approach
  occurs to you, propose it and ask — never substitute your own
  judgment and disclose the substitution after the fact.

## System Documents

- `docs/architecture.md` — Read when navigating unfamiliar code, adding a new file, or before touching the settings.json merge logic

## Rules

- `.agents/rules/json-encoding.md` — Read before touching any JSON parse/merge/serialize code path
- `.agents/rules/harness-design.md` — Read before adding or modifying a harness or its launch variants
- `.agents/rules/live-session-safety.md` — Read before validating any change against a real Emacs session
- `.agents/rules/testing.md` — Read when writing or running tests
- `.agents/rules/git-workflow.md`

## Packages

None — single flat package, no child AGENTS.md.
