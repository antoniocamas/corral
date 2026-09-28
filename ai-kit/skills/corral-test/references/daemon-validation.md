# Validating a change against a live Emacs

The safety constraint — never run against the author's daily-driver
Emacs — lives in `.agents/rules/live-session-safety.md`. Read it first;
this is the *how*, that is the *why and the boundary*.

Validate against an isolated throwaway daemon:

```sh
ai-kit/scripts/daemon-validate.sh '(corral-harness-get (quote kiro))'
ai-kit/scripts/daemon-validate.sh path/to/checks.el
```

The script starts a fresh daemon, confirms it is reachable (retrying,
since a fresh `--daemon` often races and no-ops on the first attempt),
evaluates the form, and force-kills the daemon on exit. It is
disposable.

## Return values, not printed output

`princ`/`message` output does NOT come back through `emacsclient
--eval` — the daemon writes it to its own stdout, and you get an empty
string. A validation form must **return** what it wants seen.

- A bare form: its value is returned directly.
- A file of forms: it must set `corral-validate-result` to a string;
  the script returns that. Accumulate check lines into it, e.g.:

```elisp
(setq corral-validate-result
      (concat (format "harness: %S\n" (and (corral-harness-get 'kiro) t))
              (format "classify idle: %S\n"
                      (corral-kiro--classify "> ask a question or describe a task"))))
```

Only touch the real session for a step that genuinely needs the
author's live confirmation, and only after the change is verified in
isolation here.
