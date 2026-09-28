---
name: corral-test
description: Use when running corral's tests, writing a corral test, or validating a change against a live Emacs. Trigger on "run tests", "ERT", "test corral", "write a test", "validate against Emacs", "check it works in a daemon". Exclude byte-compiling (that is corral-compile).
---

CODENAME: SKILL-CORRAL-TEST-202

# Corral Testing

corral uses ERT. Run the full suite in batch from the repo root:

```sh
emacs -Q --batch -L . \
  -l test/corral-core-tests.el -l test/corral-hook-tests.el \
  -l test/corral-claude-tests.el -l test/corral-scrape-tests.el \
  -l test/corral-antigravity-tests.el -l test/corral-kiro-tests.el \
  -f ert-run-tests-batch-and-exit
```

One `-l` per test file; add a line when a new test file is created.

## Intent Routing

| Intent | Reference |
|--------|-----------|
| Write a corral test (what to test, the stub-and-temp-file pattern) | [references/writing-tests.md](references/writing-tests.md) |
| Validate a change against a live Emacs, safely | [references/daemon-validation.md](references/daemon-validation.md) |

The compile-clean gate is a separate skill: `corral-compile`.
