;;; corral-claude-tests.el --- ERT tests for corral-claude.el -*- lexical-binding: t; -*-

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

;; Run from the repo root:
;;   emacs -batch -L . -l test/corral-claude-tests.el -f ert-run-tests-batch-and-exit
;;
;; Tests `corral-claude--classify' against screens captured from a real
;; Claude Code v2.1.292 in a vterm buffer (80 columns), not invented
;; text -- see `.agents/rules/harness-design.md'.

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-claude)

(defconst corral-claude-test--rule
  "────────────────────────────────────────────────────────────────────────────────")

(defconst corral-claude-test--footer-idle
  "  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · r…\n  ⏸ manual mode on · ? for shortcuts")

(defun corral-claude-test--screen (&rest lines)
  "LINES joined with newlines, plus trailing blank padding like a tall
vterm window."
  (concat (mapconcat #'identity lines "\n") "\n\n\n\n"))

(defun corral-claude-test--prompt-box (footer &optional prompt)
  (concat corral-claude-test--rule "\n❯ " (or prompt "") "\n"
          corral-claude-test--rule "\n" footer))

;;; idle

(ert-deftest corral-claude-test-fresh-session-is-idle ()
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                " ▐▛███▛█   Claude Code v2.1.292"
                "                                                            ◐ medium · /effort"
                (corral-claude-test--prompt-box
                 corral-claude-test--footer-idle "Try \"write a test for <filepath>\"")))
              'idle)))

(ert-deftest corral-claude-test-finished-turn-is-idle ()
  "\"✻ Cooked for 7s\" shares the spinner glyph but has no ellipsis."
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                "● The sleep is running in the background."
                "✻ Cooked for 7s · done 22:17 · 1 shell still running"
                (corral-claude-test--prompt-box
                 "  ⏵⏵ auto mode on · 1 shell · ↓ to manage")))
              'idle)))

(ert-deftest corral-claude-test-interrupted-turn-is-idle ()
  "The reported bug: after an Esc interrupt no Stop hook fires, but the
screen shows no working marker."
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                "  The most "
                "  ⎿  Interrupted · What should Claude do instead? "
                (corral-claude-test--prompt-box
                 "  ⏵⏵ auto mode on · 1 shell · ↓ to manage")))
              'idle)))

(ert-deftest corral-claude-test-bare-shell-and-empty-tail-are-idle ()
  (should (eq (corral-claude--classify "antonio@host:~/work$ ") 'idle))
  (should (eq (corral-claude--classify "") 'idle)))

;;; working

(ert-deftest corral-claude-test-spinner-and-footer-is-working ()
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                "● Running sleep 40"
                "  ⎿  $ sleep 40"
                "✶ Shimmying… (3s · ↓ 62 tokens)"
                (corral-claude-test--prompt-box
                 "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt")))
              'working)))

(ert-deftest corral-claude-test-footer-alone-is-working ()
  "While a reply streams the spinner scrolls away; the footer stays."
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                "● Guardians of the Shore"
                "  Lighthouses are among the most enduring structures humans have built."
                (corral-claude-test--prompt-box
                 "  ⏵⏵ auto mode on · 1 shell · esc to interrupt · ↓ to manage")))
              'working)))

(ert-deftest corral-claude-test-spinner-alone-is-working ()
  "Bare \"· Forging… \" at the very start of a turn, manual-mode footer."
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                "· Forging… "
                "  ⎿  Tip: Create skills by adding .md files to .claude/skills/ in your project "
                (corral-claude-test--prompt-box
                 "  ⏸ manual mode on · esc to interrupt")))
              'working)))

(ert-deftest corral-claude-test-typed-text-cannot-fake-working ()
  "\"esc to interrupt\" typed in the prompt box is not the footer."
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                (corral-claude-test--prompt-box
                 corral-claude-test--footer-idle "what does esc to interrupt do")))
              'idle)))

;;; blocked

(defconst corral-claude-test--permission-dialog
  (corral-claude-test--screen
   "● Creating empty file zz.txt"
   "  ⎿  $ touch zz.txt"
   corral-claude-test--rule
   " Bash command"
   " Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" "
   " below"
   " Create empty file zz.txt"
   "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
   " touch zz.txt"
   "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
   " Do you want to proceed?"
   " ❯ 1. Yes"
   "   2. Yes, and always allow access to /tmp/scratchpad/work"
   "      from this project"
   "   3. Yes, and switch to auto mode · auto mode handles these prompts for you"
   "   4. No"
   " Esc to cancel · Tab to amend"))

(ert-deftest corral-claude-test-permission-dialog-is-blocked ()
  (should (eq (corral-claude--classify corral-claude-test--permission-dialog)
              'blocked)))

(ert-deftest corral-claude-test-folder-trust-dialog-is-blocked ()
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                corral-claude-test--rule
                " Accessing workspace:"
                " Quick safety check: Is this a project you created or one you trust?"
                " Security guide"
                " ❯ No, exit"
                "   Yes, I trust this folder"
                " Enter to confirm · Esc to cancel"))
              'blocked)))

(ert-deftest corral-claude-test-dismissed-dialog-in-scrollback-is-not-blocked ()
  "After the dialog is denied its text stays in scrollback; only the
live screen counts."
  (should (eq (corral-claude--classify
               (concat corral-claude-test--permission-dialog
                       (corral-claude-test--screen
                        "❯ Use the Bash tool to run: touch zz.txt"
                        "  Ran 1 shell command "
                        "  ⎿  Interrupted · What should Claude do instead?"
                        "✻ Crunched for 2s · done 22:18"
                        (corral-claude-test--prompt-box
                         corral-claude-test--footer-idle))))
              'idle)))

(ert-deftest corral-claude-test-question-text-alone-is-not-blocked ()
  "A reply that merely mentions the phrase has no Yes/No options."
  (should (eq (corral-claude--classify
               (corral-claude-test--screen
                "● Do you want to proceed? That is up to you."
                (corral-claude-test--prompt-box corral-claude-test--footer-idle)))
              'idle)))

(provide 'corral-claude-tests)
;;; corral-claude-tests.el ends here

;; Captured from Claude Code v2.1.296: mid-stream the screen is just
;; output, a rule, an empty prompt box, and a footer without "esc to
;; interrupt" -- indistinguishable from idle. Only the title differs.
(defconst corral-claude-test--streaming-screen
  (concat "  382\n  383\n  384\n" corral-claude-test--rule "\n❯ \n"
          corral-claude-test--rule "\n  Sonnet 5.5  ctx: 4.0%\n  ⏸ manual mode on\n"))

(ert-deftest corral-claude-test-streaming-screen-is-idle-without-title ()
  (let ((corral-scrape-title nil))
    (should (eq 'idle (corral-claude--classify corral-claude-test--streaming-screen)))))

(ert-deftest corral-claude-test-spinning-title-is-working ()
  (dolist (title '("◐ Story about a cat" "◑ Story about a cat" "⠂ Story"))
    (let ((corral-scrape-title title))
      (should (eq 'working (corral-claude--classify
                            corral-claude-test--streaming-screen))))))

(ert-deftest corral-claude-test-idle-title-is-idle ()
  (let ((corral-scrape-title "✳ Story about a cat"))
    (should (eq 'idle (corral-claude--classify
                       corral-claude-test--streaming-screen)))))
