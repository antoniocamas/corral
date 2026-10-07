;;; corral-kiro-tests.el --- ERT tests for corral-kiro.el -*- lexical-binding: t; -*-

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

;; Pure-function tests for `corral-kiro--classify'. The fixtures are
;; multi-line, full-screen captures with SCROLLBACK above a live
;; footer -- built from a real `kiro-cli' session capture, not
;; single-line snippets. That shape is the whole point: the classifier
;; must key off the live bottom lines, not stale dialog text left in
;; scrollback. The false-blocked-from-scrollback case
;; (`...working-despite-stale-dialog-scrollback') locks down the exact
;; regression found in the first live test, where a working screen with
;; an earlier dialog's `esc to close'/`esc to cancel' still in
;; scrollback was misclassified `blocked'.
;;
;; Run in batch:
;;   emacs -batch -L .. -l corral-kiro-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-kiro)


;;; Real full-screen fixtures (scrollback + live footer)

(defconst corral-kiro-test--blocked-screen
  "  sleep for 10 seconds and be back asking for feedback

● Shell sleep 10
● 2 MCP failures — see /mcp
────────────────────────────────────────────────────────
 shell requires approval
 ❯ Yes, single permission
   Trust, always allow in this session
   No (Tab to edit)
────────────────────────────────────────────────────────
 esc to close · ↑↓ to navigate · ↵ to select · Tab to edit"
  "A real approval dialog: the `esc to close ... to navigate/to
select/tab to edit' footer plus the `❯ Yes, single permission' option
line.")

(defconst corral-kiro-test--working-screen
  "  sleep for 10 seconds and be back asking for feedback

● Shell sleep 10
  esc to cancel
● 2 MCP failures — see /mcp
────────────────────────────────────────────────────────
kiro_default · auto · ◔ 2%          ~/Workspace/corral · (main)

 Kiro is working · Type to steer · Ctrl+S to queue
▸ Credits: 0.07 • Time: 1m 3s"
  "A real working screen. Note `esc to cancel' sits in the scrollback
above -- the classifier must NOT be tricked into `blocked' by it; the
live footer says `Kiro is working'.")

(defconst corral-kiro-test--idle-screen
  "  sleep for 10 seconds and be back asking for feedback

● Shell sleep 10

  Done — slept for 10 seconds. What would you like feedback on, or what's next?

▸ Credits: 0.10 • Time: 21s
────────────────────────────────────────────────────────
kiro_default · auto · ◔ 2%          ~/Workspace/corral · (main)

 ask a question or describe a task ↵"
  "A real idle screen: the live `ask a question or describe a task ↵'
prompt, with prior working/dialog output above in scrollback.")


;;; blocked

(ert-deftest corral-kiro-test-approval-dialog-is-blocked ()
  (should (eq (corral-kiro--classify corral-kiro-test--blocked-screen) 'blocked)))

(ert-deftest corral-kiro-test-crew-approval-is-blocked ()
  (should (eq (corral-kiro--classify
               "● running subagents\n tool approval\n ❯ approve all pending")
              'blocked)))

(ert-deftest corral-kiro-test-question-panel-is-blocked ()
  "question_panel needs all three cluster phrases together."
  (should (eq (corral-kiro--classify
               "Which option?\n ↑↓ to navigate · ↵ to submit · esc to cancel")
              'blocked)))


;;; working -- including the scrollback regression

(ert-deftest corral-kiro-test-working-footer ()
  (should (eq (corral-kiro--classify corral-kiro-test--working-screen) 'working)))

(ert-deftest corral-kiro-test-working-despite-stale-dialog-scrollback ()
  "THE regression from live testing: a working screen with an earlier
dialog's `esc to cancel' (and, below, an `esc to close' line) still in
scrollback must classify `working', not `blocked' -- because matching
is scoped to the live bottom lines, where the footer is `Kiro is
working'."
  (should (eq (corral-kiro--classify
               (concat "esc to close · ↑↓ to navigate · ↵ to select\n"
                       "● 2 MCP failures — see /mcp\n"
                       "────────────────────────────\n"
                       " Kiro is working · Type to steer · Ctrl+S to queue\n"
                       "▸ Credits: 0.07 • Time: 1m 3s"))
              'working)))


;;; idle -- including scrollback safety

(ert-deftest corral-kiro-test-idle-prompt ()
  (should (eq (corral-kiro--classify corral-kiro-test--idle-screen) 'idle)))

(ert-deftest corral-kiro-test-idle-despite-stale-dialog-scrollback ()
  "An idle screen whose scrollback still holds a dialog footer must
classify `idle' (live footer is the prompt), not `blocked'."
  (should (eq (corral-kiro--classify
               (concat "esc to close · ↑↓ to navigate · ↵ to select · Tab to edit\n"
                       "● done\n"
                       "────────────────────────────\n"
                       " ask a question or describe a task ↵"))
              'idle)))

(ert-deftest corral-kiro-test-idle-prompt-with-fancy-caret ()
  (should (eq (corral-kiro--classify "› ask a question or describe a task")
              'idle)))


;;; matcher tightening -- lone phrases must NOT block

(ert-deftest corral-kiro-test-lone-esc-to-close-is-not-blocked ()
  "A bare `esc to close' with no navigation footer and no option line
must not trip blocked -- the first port over-matched on this."
  (should-not (eq (corral-kiro--classify "some output\n esc to close\n more output")
                  'blocked)))

(ert-deftest corral-kiro-test-navigate-alone-is-not-blocked ()
  "`to navigate' without `to submit' and `esc to cancel' is not the
question_panel cluster."
  (should-not (eq (corral-kiro--classify "use ↑↓ to navigate the list")
                  'blocked)))


;;; fallback

(ert-deftest corral-kiro-test-unmatched-falls-back-to-idle ()
  (should (eq (corral-kiro--classify "just a shell prompt $ ") 'idle)))

(ert-deftest corral-kiro-test-empty-tail-falls-back-to-idle ()
  (should (eq (corral-kiro--classify "") 'idle)))

(provide 'corral-kiro-tests)
;;; corral-kiro-tests.el ends here
