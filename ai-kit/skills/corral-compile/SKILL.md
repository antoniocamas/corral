---
name: corral-compile
description: Use when byte-compiling corral or checking it compiles clean — before considering any change done. Trigger on "compile", "byte-compile", "compile-clean", "does it compile", "compiler warnings". Exclude running tests (that is corral-test).
---

CODENAME: SKILL-CORRAL-COMPILE-201

# Corral Compile-Clean Check

Byte-compile every `corral*.el` and fail on any warning or error. This
is a separate, mandatory gate from ERT, and why is in the reference
below — run it before a change is done.

Run from the repo root:

```sh
rm -f *.elc && emacs -Q --batch -L . -l ai-kit/scripts/compile-check.el ; rm -f *.elc
```

Exit non-zero, or any `Warning:`/`Error:` line, means a missing
`require`/`declare-function` for something that only works by
load-order accident. Fix it before proceeding.

Why a committed script and not an inline `--eval`, and the real bug
that motivates the gate: [references/compile-clean.md](references/compile-clean.md).
