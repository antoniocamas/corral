# JSON encoding in Elisp — a hard-won invariant

`json-serialize`/`json-parse-string` do not behave the way you'd guess
from other Lisps' JSON libraries. Confirmed empirically during
development, not from memory or docs alone — verify again if this ever
seems wrong.

- `json-serialize` requires **plists or hash-tables** for objects and
  **vectors** for arrays. Alists and plain lists work for neither and
  fail with a `wrong-type-argument symbolp` error that names the wrong
  culprit (the error points at a value near the mistake, not at the
  actual list-vs-vector type error).
- `json-parse-string`'s `:array-type` only accepts `'array` (vector,
  the default) or `'list` — never a literal `'vector` symbol.
- **`json-serialize`'s return value is already-encoded raw UTF-8
  bytes, not a normal decoded Emacs string.** Comparing it, diffing it,
  or writing it to a file without `(decode-coding-string result
  'utf-8)` first silently double-encodes any non-ASCII content — no
  error, just corrupted output on write, or a value that never
  compares `equal` to properly-decoded text.

This surfaced via an emoji already present in an existing, unrelated
Claude Code hook command in a real `settings.json` — every ASCII-only
test passed throughout development; only real, non-ASCII content
exposed it. Regression test: `corral-claude-test-json-emoji-roundtrip`
in `test/corral-claude-tests.el`.

If you touch any JSON parse/merge/serialize code path, run
`test/corral-claude-tests.el` before considering it done.
