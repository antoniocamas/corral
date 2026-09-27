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

**`json-serialize` is not used for corral's own output at all**, for a
separate reason: it always produces compact, single-line JSON, which
makes a confirmation diff unreadable against a normally-indented,
hand-maintained settings file. `corral-hook-json-pretty`
(`corral-hook.el`) pretty-prints directly from the plist/vector
structure instead — every settings-file installer should go through
that, not call `json-serialize` directly. Because its output is a
normal decoded string from the start, the raw-byte/double-encoding
concern above doesn't apply to it; it only applies where
`json-serialize` genuinely is used (nowhere in this codebase's own
output path currently, but potentially a future harness's installer,
or anything else that calls it directly).

If you touch any JSON parse/merge/serialize/pretty-print code path,
run `test/corral-claude-tests.el` and `test/corral-hook-tests.el`
before considering it done.
