# Deployment

How to install corral, in either of two ways, and keep it up to date.
See `examples/setup-corral.el.example` (production) and
`examples/setup-corral-devel.el.example` (devel) for the full,
copy-pasteable configs this document explains.

## Production: pushed remote

Point `package-vc-install` at the pushed GitHub remote. package-vc's
URL-sniffing heuristic recognizes it automatically, no explicit VC
backend needed.

## Devel: local checkout

Point `package-vc-install` at your own working copy instead, while
developing corral itself. A bare filesystem path isn't recognized by
package-vc's URL-sniffing heuristic, so the VC backend (`'Git`) must
be given explicitly, or it fails with "Unknown package to fetch".

## Staying up to date

`package-vc-install` only clones what's committed as of whenever it
last ran — it is never live against a working tree or a remote. Both
example configs fast-forward the installed checkout on every startup
(a `corral--sync-upgrade` helper: `git fetch` + `git merge --ff-only
origin/main`), so a fresh pull happens automatically instead of
requiring a manual update after every new commit or release.

They deliberately do **not** use `package-vc-upgrade` for this.
`package-vc-upgrade` drives an *asynchronous* `vc-pull` whose result is
swallowed by `with-demoted-errors`, so the config's own `(require
'corral)` on the next line runs before the pull finishes — loading the
still-old files. On a fresh daemon this left the installed copy
silently stale: new commits, or a just-added harness, never appeared,
with no error to explain why. A synchronous `git` fast-forward
completes before `require`; `--ff-only` refuses rather than clobbering,
so any local edits to the checkout are safe.

This still only picks up *committed* changes. To test uncommitted,
in-progress edits to a local checkout without committing them, use
`M-x corral-reload-from-source` (defined in
`examples/setup-corral-devel.el.example`) instead — it prompts for the
checkout directory (defaulting to the current buffer's directory) and
reloads every `corral-*` feature directly from that working tree for
the current session, bypassing the package-vc-installed copy entirely.
