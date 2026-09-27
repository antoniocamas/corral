# Inspiration

corral is inspired by [herdr](https://github.com/herdrdev/herdr) —
specifically its detection architecture (a priority-ordered set of
rules matched against a session's rendered terminal text, used for
any agent with no hook system to call back into) and its regex
patterns for identifying agent state from that text.

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
Claude Code hook installation: which hook events are installed, and
the mapping from each hook event to a state.

```
CLAUDE.md
```
herdr's own project principles, including that screen-detection
rules must be evidence-based -- captured from the real running tool,
not assumed from a manifest or a guess.
