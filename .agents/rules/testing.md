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

## Compile-clean check (separate from ERT)

ERT only ever loads files as interpreted source (`require`/`load`) — it
never surfaces compiler-only diagnostics like an unknown-function
warning. That's a real gap, not theoretical: `corral-core.el` used
`face-remap-add-relative`/`face-remap-remove-relative` without
`(require 'face-remap)`, worked fine at runtime (the function happened
to already be loaded via normal Emacs startup), and every ERT run
stayed silent about it. It only surfaced once the file was actually
*compiled* — which is exactly what `package-vc-install` does on
install. Run this after any change, before considering it done:

```sh
rm -f *.elc
emacs -Q --batch --eval '
(progn
  (add-to-list (quote load-path) ".")
  (dolist (f (directory-files "." nil "\\`corral.*\\.el\\'"'"'"))
    (byte-compile-file f)))
'
rm -f *.elc
```

(Iterate the file list *inside* the single `--eval` form, not via
shell-side `$(for f in ...; do echo --eval ...; done)` — the latter
breaks under normal shell word-splitting once any argument needs its
own quoting, and silently drops `corral.el` itself if the glob
requires a hyphen. Both mistakes were made and caught while writing
this very check.)

Any `Warning:`/`Error:` line means a missing `require`/`declare-function`
for something that only happens to work by load-order accident.
