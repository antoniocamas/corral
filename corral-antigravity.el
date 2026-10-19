;;; corral-antigravity.el --- Antigravity harness (scrape strategy) -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Antonio Camas

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Antigravity's `agy' CLI has no hook system to lean on, so this
;; harness uses corral's scrape strategy (`corral-scrape.el') instead:
;; periodically read the tail of the tracked buffer and classify it
;; against known screen text.
;;
;; The first rules came from the original PoC's `herd-scrape.el'
;; (`herd-scrape--antigravity-state'), captured against real `agy'
;; v1.2.2 screen output -- not re-derived from scratch, and not from
;; herdr's own antigravity.toml manifest, which was tried first during
;; the PoC and matched nothing in this installed version.
;; Re-verified 2026-09-27 against `agy' v1.2.12 (up from v1.2.2): a
;; fresh `herd-scrape-debug-log' capture (`/tmp/herd-scrape.log',
;; ~9000 ticks) showed the exact same literal strings still appearing
;; verbatim, including the `RunCommand'-style confirmation dialog
;; ("Requesting permission for:" / "Run this command?" / "tab Amend")
;; with the status-bar tag still reading `[WORKING...]' underneath it.
;;
;; 2026-10-19, `agy' 1.4.2: a live session sat showing a *question*
;; dialog ("Question 1/1" with a numbered option list) while the
;; status-bar tag still read `[USING TOOLS]' -- no permission text on
;; screen, so those rules called it `working' and the panel never
;; flagged the session as needing input. The fix ports herdr's current
;; `antigravity.toml' (version 2026.10.05.1, shipped in herdr 0.9.4):
;; agy's dialogs are identified by their KEY-HINT FOOTER ROW, matched
;; case-insensitively as a two-phrase cluster within the bottom 2
;; non-empty lines, not by dialog body text ("some captures hold only
;; the two footer rows", per herdr's manifest comment):
;;   permission: "↑/↓ Navigate · tab Amend · ctrl+g edit/expand command"
;;               "↑/↓ Navigate · tab Amend · f full diff"
;;   question:   "↑/↓ Navigate · enter Select · esc Skip"
;;   trust:      "↑/↓ Navigate · enter Confirm"
;;   slash menu: "↑/↓ Navigate · enter Select · tab Complete" (idle!)
;; The two-phrase gate is what tells these apart: the slash menu's row
;; shares "navigate" and even "enter Select" with the question row but
;; has neither "esc Skip" nor "tab Amend". Evidence on this install:
;; the question row was captured live on agy 1.4.2 (the failure
;; above), and the permission row already appeared verbatim in the
;; PoC-era confirmation capture (reused as the
;; `corral-antigravity-test--confirmation-sample' fixture) -- its
;; "f full diff" variant also closes that capture's open item (a
;; file-edit confirmation previously fell through to `working'
;; uncaught).
;;
;; Deliberately NOT ported from herdr's manifest:
;;  - herdr dropped the [WORKING...]/[USING TOOLS] status-bar tags
;;    entirely, detecting working via an "esc to cancel" footer regex
;;    and a braille-spinner line rule. corral keeps its locally
;;    verified tags (`.agents/rules/harness-design.md': the PoC found
;;    herdr's spinner glyph matched nothing in the installed CLI) and
;;    simply checks the dialog rows BEFORE the tags, which is all the
;;    overlay-stuck-on-[WORKING...] problem needs.
;;  - the workspace-trust dialog rule ("Do you trust the contents of
;;    this project?"): herdr-evidenced only, never captured on this
;;    install, so porting it would be the guess the rules forbid.

;;; Code:

(require 'cl-lib)
(require 'corral-core)
(require 'corral-harness)
(require 'corral-scrape)

(defconst corral-antigravity--dialog-region-lines 2
  "How many bottom non-empty lines the dialog-row rules match against
\(`corral-scrape-bottom-non-empty-lines'), mirroring herdr's
`bottom_non_empty_lines(2)': the key-hint row plus the status-bar
line under it -- some real captures hold only those two rows, so the
rules cannot require the dialog's question text. Scoping also keeps an
answered dialog's row still sitting in scrollback from forcing a
stale `blocked', the same live-tested lesson `corral-kiro.el'
records.")

(defconst corral-antigravity--permission-row-contains '("navigate" "tab amend")
  "herdr `permission_prompt' (priority 300): both phrases of a
tool-confirmation dialog's key-hint row, case-insensitive. Covers the
two captured row variants -- `tab Amend · ctrl+g edit/expand command'
\(RunCommand) and `tab Amend · f full diff' (file-edit confirmation).")

(defconst corral-antigravity--question-row-contains '("navigate" "esc skip")
  "herdr `question_prompt' (priority 290): both phrases of a question
dialog's key-hint row, case-insensitive -- `↑/↓ Navigate · enter
Select · esc Skip'. The status-bar tag still reads [USING TOOLS]
under this dialog; that exact false `working' on agy 1.4.2 is what
this rule fixes.")

(defconst corral-antigravity--blocked-contains "Requesting permission for:"
  "Exact, case-sensitive text preceding any agy tool-confirmation
dialog. Checked after the dialog-row rules: the confirmation dialog
is an overlay, so agy's status-bar tag stays [WORKING...]/[USING
TOOLS] even while this is up. herdr's manifest calls this wording
pre-1.1.28 legacy, but corral's own v1.2.12 capture showed it
verbatim, so it stays as a third blocked rule.")

(defconst corral-antigravity--working-tags '("[WORKING...]" "[USING TOOLS]")
  "Literal status-bar tags agy shows while actively doing something.")

(defconst corral-antigravity--idle-tag "[IDLE]"
  "Literal status-bar tag agy shows when it's done and waiting for a
new prompt from the user.")

(defun corral-antigravity--contains-all-p (text needles)
  "Non-nil if every NEEDLE occurs in TEXT, case-insensitively --
herdr's `contains' semantics: a rule's needle list is AND-ed, both
sides compared case-folded (`Navigate' on screen matches \"navigate\")."
  (let ((case-fold-search t))
    (cl-every (lambda (needle) (string-match-p (regexp-quote needle) text))
              needles)))

(defun corral-antigravity--classify (tail)
  "Classify TAIL (a string, the scanned buffer tail) for an antigravity
session into `blocked' (a tool-confirmation or question dialog is up),
`working', or `idle' (also the fallback when none of the known tags
match).

Dialog key-hint rows are matched first, and only within the bottom
non-empty lines of TAIL -- never the whole scrollback -- because the
status-bar tag still reads [WORKING...]/[USING TOOLS] while a dialog
is up (so the tag rules must come after it), and an answered dialog's
row left in scrollback must not keep the session `blocked'."
  (let ((dialog-region (corral-scrape-bottom-non-empty-lines
                        tail corral-antigravity--dialog-region-lines)))
    (cond
     ((corral-antigravity--contains-all-p
       dialog-region corral-antigravity--permission-row-contains)
      'blocked)
     ((corral-antigravity--contains-all-p
       dialog-region corral-antigravity--question-row-contains)
      'blocked)
     ((string-match-p (regexp-quote corral-antigravity--blocked-contains) tail)
      'blocked)
     ((cl-some (lambda (tag) (string-match-p (regexp-quote tag) tail))
               corral-antigravity--working-tags)
      'working)
     ((string-match-p (regexp-quote corral-antigravity--idle-tag) tail)
      'idle)
     (t 'idle))))

(corral-harness-register
 (make-corral-harness :id 'antigravity
                       :abbrev "ag"
                       :strategy 'scrape
                       :classifier #'corral-antigravity--classify))

(corral-harness-add-variant 'antigravity nil "agy")

(provide 'corral-antigravity)
;;; corral-antigravity.el ends here
