# Inspiration

corral is inspired by [herdr](https://github.com/herdrdev/herdr) —
specifically its detection architecture (a priority-ordered set of
rules matched against a session's rendered terminal text, used for
every agent, Claude Code included) and its regex patterns for
identifying agent state from that text.

This file is the only place in this repository that couples to
herdr. Paths below are relative to the root of the herdr repository
itself, not to any local copy.

```
src/detect/mod.rs
```
The generic screen-scraping detection engine: reads a pane's
rendered tail text and matches it against a per-agent set of rules,
highest priority first.

```
src/detect/manifests/*.toml
```
Per-agent pattern manifests consumed by the engine above — e.g.
`antigravity.toml`, `claude.toml` — each a priority-ordered list of
regex/contains rules mapping matched text to a state.

```
src/integration/claude_settings.rs
```
Claude Code settings installation. Informative by what it removes:
herdr's `HOOK_REMOVALS` strips the working/blocked/idle hooks and
keeps only a `SessionStart` hook for session identity, so Claude
Code's state comes from screen detection (`claude.toml`), not hooks.
corral followed this after a hook-based Claude harness got stuck on
`working` (no hook fires on an Esc interrupt or an API-error turn),
and went further: it has no use for session identity, so it installs
no hooks at all.

The same manifest's `osc_title_working` / `osc_title_idle` rules
(terminal title with a busy-spinner glyph vs `✳`) are carried over:
screen text alone stopped showing a running turn in Claude Code
2.1.296. corral gets the title from vterm (`corral-vterm-title`)
rather than from the escape stream. Its `osc_progress_idle` rule and
the kiro title rules remain unported.

```
CLAUDE.md
```
herdr's own project principles, including that screen-detection
rules must be evidence-based -- captured from the real running tool,
not assumed from a manifest or a guess.
