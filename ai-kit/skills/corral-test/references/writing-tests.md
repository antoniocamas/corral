# Writing a corral test

Prefer testing pure functions directly (a harness `--classify`,
`corral-scrape-bottom-non-empty-lines`) over anything that needs a real
vterm buffer or timer.

For a scrape harness, build fixtures from screens captured off the real
tool, not invented text: a full screen with scrollback above the live
footer, plus trailing blank padding. The shape is the point -- the
classifier must key off the live bottom lines, and the regressions
worth locking down are stale dialog text in scrollback and
look-alike text (a finished-turn summary resembling a spinner line, a
prompt containing a footer phrase). See `test/corral-claude-tests.el`
and `test/corral-kiro-tests.el`.

To exercise the generic tick/timer logic, call `corral-scrape--tick`
directly against a fake harness and fake buffers (see
`test/corral-scrape-tests.el`) rather than waiting on a real timer.

A test is not a formality here: the false-`blocked`-from-scrollback bug
in the kiro classifier was found by a test for a scenario manual
testing hadn't covered.
