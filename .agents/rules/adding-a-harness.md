# Adding a new harness: step-by-step recipe

Shipping the `antigravity` harness got several of these steps skipped
or done out of order, each causing a real bug or a confusing support
session afterward (see the git history and the fixes that followed).
Follow this checklist top to bottom for the next one instead of
re-discovering the same gaps piece by piece. Design principles (what a
harness *is*, what it isn't) are in `.agents/rules/harness-design.md`
— read that first; this file is the sequencing, not the design.

1. **Strategy is `scrape`** (periodic tail-of-buffer text matching) --
   corral has no other. See `harness-design.md` for why hooks were
   dropped.

2. **Write `corral-<name>.el`:**
   - `(make-corral-harness :id '<name> :abbrev "<short>" :strategy
     'scrape :classifier #'corral-<name>--classify)` (+ optional
     `:tail-chars`).
   - `(corral-harness-register ...)` plus the harness's own **default**
     variant only: `(corral-harness-add-variant '<name> nil "<command>")`.
     Personal wrapper variants belong in the user's own config, not
     here (`harness-design.md`).
   - Base every rule on real captured screen
     text via `corral-scrape-debug-log` against the actual running
     tool — never a borrowed manifest (herdr's own antigravity.toml
     didn't match reality) and never a guess.

3. **Require the new file from `corral.el`.** Easy to forget since
   nothing fails loudly if you don't — the harness just silently never
   registers.

4. **Add `test/corral-<name>-tests.el`** — pure classifier tests, no live tool or real vterm buffer needed (see the
   `corral-test` skill, `references/writing-tests.md`, for the pattern).

5. **Update the docs that list files/tests by name** — both of these
   were missed for `antigravity` until asked for separately:
   - `docs/architecture.md` — one bullet describing the new file.
   - `ai-kit/skills/corral-test/SKILL.md` — add the new test file to
     the batch `-l` command.

6. **Re-verify scrape rules against the live tool before trusting
   them**, per `harness-design.md`'s evidence-based-detection
   principle — and don't assume a version match from whenever the
   rules were first captured still holds: `agy` moved from v1.2.2 to
   v1.2.12 mid-project. Check the installed version, and re-capture
   with `corral-scrape-debug-log` if it's moved since the rules were
   written.

7. **Nothing to touch for reload/unload lists.** `corral-reload-from-source`
   (in both `examples/setup-corral-devel.el.example` and the real
   `~/.emacs.d/setup-files/setup-corral.el`) discovers loaded
   `corral-*` features by name from Emacs's own `features` list, not a
   hardcoded list — this used to require a manual edit per new harness
   and was itself a repeated source of bugs (a harness silently
   dropped from the registry on reload because it wasn't in the list),
   fixed by removing the hardcoded list entirely. If you ever find
   yourself editing that dolist again, something has regressed.

8. **When testing changes to a *user config file* itself** (not
   corral's own package files) **against a running Emacs**: editing
   the file on disk has no effect on that Emacs process until the file
   is actually re-evaluated. `M-x corral-reload-from-source` only
   reloads corral's own package files — it does NOT re-read the config
   file that *defines* `corral-reload-from-source`. Concretely, this
   caused the `antigravity` harness to silently vanish from
   `corral--harnesses` (while `claude` survived) after a reload: an
   in-memory, stale copy of `corral-reload-from-source` unloaded
   `corral-harness` (which resets the registry hash table) without
   also unloading `corral-antigravity` (whose one-time top-level
   registration call was the only thing that had ever populated that
   entry), so it never got a chance to re-register.

   Fix in the moment: `(load "/absolute/path/to/setup-corral.el")` —
   the absolute path, not `M-x load-file`'s interactive file prompt,
   removes any doubt about which file actually got read. **Then
   verify it actually changed before touching anything else**: `M-x
   describe-function RET corral-reload-from-source RET` and check the
   docstring shown really is the current one. Do not just assume the
   `load` took effect and move on -- that assumption is exactly what
   cost the most debugging time here. Only once that's confirmed, run
   `corral-reload-from-source` and retry whatever you were testing.

   Fix for good: step 7 above already removed the hardcoded list this
   *particular* bug depended on, so a fresh reload picks up any new
   harness automatically -- but the general lesson (redefine the
   reloader before trusting what it does, and verify the redefinition
   landed) still applies to any future change to
   `corral-reload-from-source`'s own logic, or to any other function
   defined in a user config file rather than in corral's own package.

9. **Any global, non-Lisp-variable resource a harness or its plumbing
   registers must be torn down explicitly before `unload-feature`,
   not left to it.** `unload-feature` only unbinds Lisp
   symbols (functions, variables) that its file's `load-history`
   recorded -- it has no idea a `defvar` happened to be holding a
   handle to something living outside the Lisp heap. Concretely:
   `corral-scrape--timer` is a real, running Emacs timer registered
   globally via `run-with-timer`; unloading `corral-scrape` unbinds the
   *variable* but the timer keeps firing regardless, and its next tick
   calls the now-undefined `corral-scrape--tick` and errors.
   `corral-reload-from-source` now cancels it explicitly first (see
   both config files) -- if a future harness or plumbing file
   registers something similar (a timer, a filter/sentinel on a
   process, a global hook it added itself), add the matching teardown
   to the reloader at the same time, don't assume unloading is enough.

10. **Compile-clean check + full ERT run** (skills `corral-compile`
    and `corral-test`) before considering it done.

11. **Live validation only in an isolated throwaway daemon**
    (`.agents/rules/live-session-safety.md`) — never directly against
    the author's daily-driver Emacs.

## If a reload doesn't seem to be working

Don't cycle theories against a black box -- introspect the actual
live state directly, in one shot, rather than guessing and asking the
user to retry blind. This is what actually found the real bug above,
after two rounds of guessing didn't:

```elisp
(progn
  (message "BEFORE unload, corral features: %S"
           (seq-filter (lambda (f) (string-prefix-p "corral" (symbol-name f))) features))
  (dolist (feature (copy-sequence features))
    (let ((name (symbol-name feature)))
      (when (or (equal name "corral") (string-prefix-p "corral-" name))
        (condition-case err
            (unload-feature feature t)
          (error (message "UNLOAD ERROR on %s: %S" feature err))))))
  (message "AFTER unload, remaining corral features: %S"
           (seq-filter (lambda (f) (string-prefix-p "corral" (symbol-name f))) features))
  (let ((load-path (cons "/path/to/checkout" load-path)))
    (condition-case err
        (require 'corral)
      (error (message "REQUIRE ERROR: %S" err)))
    (message "locate-library corral-<name>: %S" (locate-library "corral-<name>")))
  (message "AFTER require, corral features: %S"
           (seq-filter (lambda (f) (string-prefix-p "corral" (symbol-name f))) features))
  (message "<name> harness: %S" (corral-harness-get '<name>)))
```

This surfaces, in order: what was actually loaded beforehand (not what
you assume was loaded), any error a specific `unload-feature` call
swallows by default, whether the file is even findable on `load-path`
at all, and the final registration state -- each a distinct failure
mode that "it doesn't work" collapses into one confusing symptom.
Also: if this diagnostic block itself succeeds, it just performed the
fix for real in that live session -- the next thing to do is retry
the original failing command immediately, not report back that it's
"still broken" from before the diagnostic ran.

Not part of adding a harness, but related: an already-running session
of an *existing* harness that predates some later fix (e.g. one
launched before `corral--register` started stashing process
properties) can be recovered by hand with `corral-adopt-buffer`, which
infers harness/variant/suffix from the buffer's own name. A harness
added via this recipe from day one shouldn't ever need that -- its
sessions get the current `corral--register` behavior from their first
launch.
