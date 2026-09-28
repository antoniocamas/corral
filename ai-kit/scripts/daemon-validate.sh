#!/usr/bin/env bash
# Run corral through an isolated, throwaway Emacs daemon and evaluate a
# validation form against it -- never against the author's live Emacs
# (see .agents/rules/live-session-safety.md for why that matters).
#
# Usage, from the repo root:
#   ai-kit/scripts/daemon-validate.sh '(corral-harness-get (quote kiro))'
#   ai-kit/scripts/daemon-validate.sh path/to/checks.el     # a file of forms
#
# The form's *return value* comes back on stdout. `princ`/`message`
# output does NOT survive `emacsclient --eval` (the daemon writes it to
# its own stdout), so a validation form must RETURN what it wants seen
# -- accumulate into a string and end with it, rather than printing.
#
# The daemon is started fresh, confirmed reachable (a fresh --daemon
# often races and no-ops on the first try, so we retry), used, then
# force-killed. It is disposable.

set -u
repo="$(pwd)"
name="corral-validate-$$"
arg="${1:?usage: daemon-validate.sh FORM|FILE.el}"

cleanup() { pkill -9 -f "daemon=$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Start the daemon, retrying: the first attempt frequently no-ops.
started=""
for _ in 1 2 3; do
  emacs -Q --daemon="$name" \
    --eval "(progn (add-to-list 'load-path \"$repo\") (require 'corral))" \
    >/dev/null 2>&1
  sleep 1
  if [ "$(emacsclient -s "$name" --eval '(+ 1 1)' 2>/dev/null)" = "2" ]; then
    started=1
    break
  fi
done
if [ -z "$started" ]; then
  echo "daemon-validate: daemon $name failed to start" >&2
  exit 1
fi

# A file of forms is loaded and must set `corral-validate-result`;
# a bare form is evaluated and its value returned directly.
if [ -f "$arg" ]; then
  emacsclient -s "$name" --eval "(progn (load \"$arg\") corral-validate-result)"
else
  emacsclient -s "$name" --eval "$arg"
fi
