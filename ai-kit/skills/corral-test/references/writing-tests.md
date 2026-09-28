# Writing a corral test

Prefer testing pure functions directly (`corral-claude--merge-hooks`,
`corral--plist-set`, a harness `--classify`, the encode/decode step)
over the interactive wrapper (`corral-claude-install-hooks`).

Where an end-to-end test through the real function is worth it, stub
`yes-or-no-p`/`display-buffer` with `cl-letf` and use a real temp file
cleaned up in `unwind-protect` — see
`corral-claude-test-install-hooks-end-to-end` in
`test/corral-claude-tests.el` for the pattern.

A test is not a formality here: the hook-entry-recognition bug that
`.agents/rules/harness-design.md` describes (matching on the hook
script's basename, not its full path) was found by writing a test for
a scenario manual testing hadn't covered, not by manual testing.
