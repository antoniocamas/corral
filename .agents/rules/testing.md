# Testing

Both gates below are mandatory before a change is done. The procedures
live in skills; this rule only states that they are required and where
they are.

- **Run the ERT suite, and write tests for new behavior** — skill
  `corral-test` . Covers the batch run  command, what to test, and
  validating against a live Emacs.  **Compile-clean check** (separate
  from ERT — ERT never surfaces compiler-only diagnostics) —
  skill `corral-compile`.
