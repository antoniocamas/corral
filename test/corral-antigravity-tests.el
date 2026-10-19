;;; corral-antigravity-tests.el --- ERT tests for corral-antigravity.el -*- lexical-binding: t; -*-

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

;; Sample strings here are the exact real captures made during the
;; original PoC (`../emacs-herd/herd-scrape.el'), reused verbatim as
;; fixtures rather than invented -- only the `waiting' -> `blocked'
;; expectation changed, to match corral's own state vocabulary. The
;; question-dialog sample is an anonymized live capture from agy 1.4.2
;; (the false `working' that motivated the key-hint-row rules;
;; detection-relevant lines verbatim, project names replaced); the
;; file-edit and slash-menu fixtures are derived from herdr's
;; antigravity.toml evidence, as each docstring records.

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-antigravity)

(defconst corral-antigravity-test--confirmation-sample
  "Requesting permission for:
   sleep 10

Run this command?
> 1. Yes, run command
  2. No, cancel

  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
✦ 3.7 Flash (Medium)  Ctx: 1.9% (20k/1.0M) ...  [WORKING...]"
  "Real captured confirmation-dialog overlay text. Note the status-bar
tag still says [WORKING...] while this is up -- the classifier must
check the confirmation text first, not the tag.")

(ert-deftest corral-antigravity-test-confirmation-dialog-is-blocked ()
  "A tool-confirmation dialog classifies as `blocked', even though the
status-bar tag on the same screen still says [WORKING...]."
  (should (eq (corral-antigravity--classify corral-antigravity-test--confirmation-sample)
              'blocked)))

(ert-deftest corral-antigravity-test-working-tag ()
  (should (eq (corral-antigravity--classify "✦ 3.7 Flash (Medium)  [WORKING...]")
              'working))
  (should (eq (corral-antigravity--classify "✦ 3.7 Flash (Medium)  [USING TOOLS]")
              'working)))

(ert-deftest corral-antigravity-test-idle-tag ()
  (should (eq (corral-antigravity--classify "✦ 3.7 Flash (Medium)  [IDLE]")
              'idle)))

(ert-deftest corral-antigravity-test-unmatched-text-falls-back-to-idle ()
  (should (eq (corral-antigravity--classify "some unrelated screen text")
              'idle)))

(ert-deftest corral-antigravity-test-harness-registered-as-scrape-strategy ()
  (let ((harness (corral-harness-get 'antigravity)))
    (should harness)
    (should (eq (corral-harness-strategy harness) 'scrape))
    (should (eq (corral-harness-classifier harness) #'corral-antigravity--classify))))

(defconst corral-antigravity-test--question-sample
  "Question
───────────────────────────────────────────────────────────────────────────────────────────────────────────
Question 1/1: Which item from the backlog would you like to address?

  1. (Recommended) Option A: Refactor the parser module (app-core, 22
violations)
  2. Option C: Split the configuration module (app-core, 19 violations)
  3. Option D: Update the remaining adapters (app-lib, 5 violations)
> 4. Option B: Fix the debug and query services (app-core, 4+ violations)
  5. Write-in...

  ↑/↓ Navigate · enter Select · esc Skip
✦ 3.8 Flash (High)  Ctx: 5.0% (60k/1.0M)  [USING TOOLS]"
  "Anonymized question-dialog capture from agy 1.4.2 (2026-10-19):
the detection-relevant lines -- the `Question 1/1' header shape, the
numbered-option list, the key-hint row, and the [USING TOOLS] status
line -- are verbatim; the question and option text are generic
replacements, as the real capture named a private project. It remains
the failure that motivated the key-hint-row rules: the status-bar tag
reads [USING TOOLS] while the agent is stopped on the user's choice,
and no permission text is on screen -- the old rules called this
`working'.")

(ert-deftest corral-antigravity-test-question-dialog-is-blocked ()
  "A question dialog classifies as `blocked' even though the
status-bar tag on the same screen still says [USING TOOLS] -- the
agy 1.4.2 false-`working' failure."
  (should (eq (corral-antigravity--classify corral-antigravity-test--question-sample)
              'blocked)))

(ert-deftest corral-antigravity-test-file-edit-confirmation-row-is-blocked ()
  "The file-edit confirmation's key-hint row (`tab Amend · f full
diff' -- herdr's captured variant, the PoC-era \"might use different
wording\" open item) classifies as `blocked', even under a
[WORKING...] tag."
  (should (eq (corral-antigravity--classify
               "  ↑/↓ Navigate · tab Amend · f full diff
✦ 3.8 Flash (High)  Ctx: 5.0% (60k/1.0M)  [WORKING...]")
              'blocked)))

(ert-deftest corral-antigravity-test-stale-question-row-in-scrollback-is-not-blocked ()
  "A question dialog already answered and scrolled off must not keep
the session `blocked': the dialog rules read only the bottom
non-empty lines, so once newer transcript text and a live [WORKING...]
tag sit below the old row, the session classifies as `working'."
  (should (eq (corral-antigravity--classify
               (concat corral-antigravity-test--question-sample "
Option B selected. Continuing with the next task...

✦ 3.8 Flash (High)  Ctx: 5.2% (62k/1.0M)  [WORKING...]"))
              'working)))

(ert-deftest corral-antigravity-test-slash-menu-row-is-not-blocked ()
  "The idle slash-menu's key-hint row shares `navigate' and even
`enter Select' with the question row but has neither `esc Skip' nor
`tab Amend' (herdr's manifest notes it as an idle footer) -- the
two-phrase gate must keep it out of `blocked'."
  (should (eq (corral-antigravity--classify
               "  ↑/↓ Navigate · enter Select · tab Complete
✦ 3.8 Flash (High)  Ctx: 5.0% (60k/1.0M)  [IDLE]")
              'idle)))

(provide 'corral-antigravity-tests)
;;; corral-antigravity-tests.el ends here
