# Validating against the author's live Emacs

**Never run anything that writes to a real config file, or anything
that isn't proven quick and side-effect-free, against a live,
actively-used Emacs session** (the author's daily-driver Emacs, not a
throwaway instance) without the author present and explicitly aware a
confirmation prompt is coming.

`corral-hook-confirm-and-write` opens an interactive `yes-or-no-p`
prompt. If nothing is present to answer it, the whole single-threaded
Emacs process wedges indefinitely — every other pending and future
request queues up behind it, including completely unrelated ones.
`timeout` on an `emacsclient` invocation only kills the *client*, not
the still-running server-side evaluation; recovery needs a `C-g` (or a
force-kill of the process) at the actual Emacs, not a client-side
timeout.

Validate against an isolated throwaway daemon first:

```sh
emacs -Q --daemon=<name> --eval "(progn (add-to-list 'load-path \"<repo>\") (require 'corral))"
```

A fresh `--daemon=NAME` invocation in a new shell often races something
on its first attempt and silently no-ops without starting — always
confirm it actually started before trusting it:

```sh
emacsclient -s <name> --eval "(+ 1 1)"
```

Force-kill (`pkill -9 -f "daemon=<name>"`) and remove its stale socket
freely afterward — it's disposable. Only touch the real session for
the specific step that genuinely needs the author's live confirmation,
and only once the change is already verified in isolation.
