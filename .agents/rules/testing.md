# Testing

ERT. Run in batch from the repo root:

```sh
emacs -Q --batch -L . -l test/corral-claude-tests.el -f ert-run-tests-batch-and-exit
```

Prefer testing pure functions directly (`corral-claude--merge-hooks`,
`corral--plist-set`, the encode/decode step) over the interactive
wrapper (`corral-claude-install-hooks`) where possible. Where an
end-to-end test through the real function is valuable, stub
`yes-or-no-p`/`display-buffer` with `cl-letf` and use a real temp file,
cleaned up in `unwind-protect` — see
`corral-claude-test-install-hooks-end-to-end` in
`test/corral-claude-tests.el` for the pattern.

Writing a test is not a formality here: the entry-recognition-by-path
bug (see `harness-design.md`) was found by writing a test for a
scenario manual testing hadn't covered, not by manual testing itself.
