# Compile-clean check — why it exists

## Why ERT is not enough

ERT only loads files as interpreted source (`require`/`load`); it never
surfaces compiler-only diagnostics. Real bug this missed:
`corral-core.el` used `face-remap-add-relative`/`face-remap-remove-relative`
without `(require 'face-remap)`. It worked at runtime (the function was
already loaded via normal Emacs startup) and every ERT run stayed
silent — it surfaced only once the file was *compiled*, which is exactly
what `package-vc-install` does on install.

## Why a committed script, not an inline `--eval`

The file list must be iterated *inside* the loaded elisp, never via a
shell-side loop. Shell word-splitting mangles the `` `corral.*\.el' ``
regex once any argument needs its own quoting, and silently drops
`corral.el` itself if the glob requires a hyphen. Both mistakes were
made and caught writing the original check — hence
`ai-kit/scripts/compile-check.el` as a committed file.

## What the script does

`ai-kit/scripts/compile-check.el` sets `byte-compile-error-on-warn`,
compiles every `corral*.el`, and `kill-emacs 1` if any file warns or
errors — so it doubles as a CI / pre-done gate. The `rm -f *.elc`
before and after keeps no `.elc` artifacts in the tree.
