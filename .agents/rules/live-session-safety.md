# Validating against the author's live Emacs

**Never run anything that writes to a real config file, or anything
that isn't proven quick and side-effect-free, against a live,
actively-used Emacs session** (the author's daily-driver Emacs, not a
throwaway instance) without the author present and explicitly aware a
confirmation prompt is coming.

Anything that opens an interactive prompt (`yes-or-no-p`, a
`read-string`, a coding-system query) wedges the whole single-threaded
Emacs process indefinitely if nothing is present to answer it -- every
other pending and future request queues up behind it, including
completely unrelated ones. `timeout` on an `emacsclient` invocation
only kills the *client*, not the still-running server-side evaluation;
recovery needs a `C-g` (or a force-kill of the process) at the actual
Emacs, not a client-side timeout.

Validate in isolation first, via the skill `corral-test`Only touch the
real session for the step that genuinely needs the author's live
confirmation, and only once the change is already verified in isolation.
