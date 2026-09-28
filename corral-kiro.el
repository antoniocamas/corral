;;; corral-kiro.el --- Kiro CLI harness (scrape strategy) -*- lexical-binding: t; -*-

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

;; Kiro CLI (`kiro-cli') does have an agent-lifecycle hook system, but
;; those hooks only fire for a *named agent config file*
;; (~/.kiro/agents/<name>.json), not for the built-in default agent a
;; plain `kiro-cli chat' runs -- and none of its hook triggers
;; (agentSpawn/userPromptSubmit/preToolUse/postToolUse/stop)
;; corresponds to "blocked, waiting on a tool-permission decision", the
;; one state that most needs the panel's attention. So this harness
;; uses corral's scrape strategy (`corral-scrape.el') instead:
;; periodically read the tail of the tracked buffer and classify it
;; against known on-screen text.
;;
;; Rules below are ported from herdr's own `kiro.toml' manifest
;; (`src/detect/manifests/kiro.toml', id "kiro", version 2026.09.19.1,
;; aliases ["kiro-cli"]) -- the same evidence-based, priority-ordered
;; screen-text approach `corral-antigravity.el' took from
;; `antigravity.toml'. All literal matching is case-insensitive, as
;; herdr lowercases both sides before a `contains' test.
;;
;; REGION SCOPING is essential and was the fix after the first live
;; test. Every kiro.toml rule matches only the bottom few NON-EMPTY
;; lines (`bottom_non_empty_lines(4)' for the live idle/working footer,
;; `(8)' for a dialog), never the whole scrollback. corral hands the
;; classifier a ~20000-char tail, so a *previous* dialog's
;; `esc to close'/`esc to cancel' text still in scrollback forced a
;; permanent false `blocked' until this was scoped to the live footer
;; lines the way herdr does. See `corral-kiro--bottom-non-empty-lines'.
;;
;; The blocked rules also gate on a footer AND a body line together,
;; not a lone phrase -- the first port matched `esc to close' or
;; `esc to cancel' alone and over-fired. See `corral-kiro--blocked-p'.
;;
;; Ported rules and the state each yields:
;;   - tool_approval / crew_approval / question_panel (priorities
;;     1050/1040/1030) -> `blocked': a permission/approval/question
;;     dialog is up. (tool_approval_edit, 1045, folds into the same
;;     footer+option gate.)
;;   - live_prompt_idle (1100) -> `idle': the live "ask a question or
;;     describe a task" prompt.
;;   - live_working_footer (950) -> `working': "kiro is working" /
;;     "type to steer" / "ctrl+s to queue".
;;
;; DELIBERATELY NOT ported: kiro.toml's osc_title_working (900) and
;; osc_progress_working (890) rules. Those match against the terminal's
;; OSC title / OSC progress escape sequences (herdr feeds them to its
;; engine as separate `osc_title'/`osc_progress' regions), not against
;; rendered buffer text. corral's scrape strategy only ever sees the
;; rendered buffer tail (`corral--buffer-tail'), so there is no
;; equivalent input to match them against -- porting them would be a
;; guess, which `.agents/rules/harness-design.md' forbids.
;;
;; NOTE on ordering: within the scoped regions the three footers are
;; mutually exclusive on screen (a dialog replaces the live footer), so
;; ordering only decides a rare double-match. blocked is checked first
;; (it most needs the panel's attention); among non-blocked footers
;; idle precedes working, mirroring kiro.toml's 1100 > 950.

;;; Code:

(require 'cl-lib)
(require 'corral-core)
(require 'corral-harness)
(require 'corral-scrape)

;; Region scoping -- the key correction after live testing. kiro.toml
;; matches its blocked/idle/working rules only against the bottom few
;; NON-EMPTY lines (`bottom_non_empty_lines(4)'/`(8)'), never the whole
;; scrollback. corral hands the classifier a large character tail
;; (`corral-vterm-tail-chars', ~20000), so an earlier dialog's
;; `esc to close'/`esc to cancel' text still sitting in scrollback
;; would otherwise force `blocked' forever even after Kiro has moved on
;; to working or idle. Scoping to the live footer lines the way herdr
;; does is what makes the three states mutually exclusive. Ported from
;; herdr's `bottom_non_empty_lines' in `src/detect/mod.rs'.

(defun corral-kiro--bottom-non-empty-lines (tail n)
  "The last N non-empty lines of TAIL, rejoined with newlines --
corral's port of herdr's `bottom_non_empty_lines(N)' region. Trailing
blank padding (a full-screen TUI pads unused rows) is skipped; the
slice starts at the Nth-from-last non-blank line and runs to the end,
blank lines in between included, matching herdr's slice semantics."
  (let* ((lines (split-string tail "\n"))
         (indexed (cl-loop for l in lines for i from 0
                           unless (string-empty-p (string-trim l))
                           collect i))
         (start (nth (max 0 (- (length indexed) n)) indexed)))
    (if start
        (mapconcat #'identity (nthcdr start lines) "\n")
      "")))

;; Blocked: an approval/question dialog is up. kiro.toml gates each
;; blocked rule on BOTH a dialog footer AND a dialog body line -- not a
;; lone footer phrase, which over-matched in the first port. The footer
;; `esc to close ... to navigate/to select/tab to edit' (tool_approval)
;; or the `... to navigate ... to submit ... esc to cancel' cluster
;; (question_panel) is the footer; an option line (`❯ Yes, single
;; permission', `Allow'/`Deny', etc.) or `tool approval'/`approve all
;; pending' (crew_approval) is the body.

(defconst corral-kiro--approval-footer-regexp
  "esc to close\\(?:.*to navigate\\|.*to select\\|.*tab to edit\\)"
  "Case-insensitive: kiro.toml's `tool_approval' footer -- `esc to
close' followed by navigation hints. Requires more than a bare
`esc to close' so a stale close hint alone doesn't trip blocked.")

(defconst corral-kiro--approval-option-line-regexp
  "^[ \t]*[>❯][ \t]*\\(allow\\|always allow\\|deny\\|always deny\\|yes, single permission\\|trust,\\|trust \\|no (tab to edit)\\|entire tool\\)"
  "Case-insensitive: a selected (`>'/`❯') option line inside an approval
dialog, from kiro.toml's `tool_approval' option regexps.")

(defconst corral-kiro--crew-approval-contains
  '("tool approval" "approve all pending"
    "configure individually (agent monitor)" "exit (cancel subagents)")
  "kiro.toml `crew_approval' body phrases (any one).")

(defconst corral-kiro--question-panel-contains
  '("to navigate" "to submit" "esc to cancel")
  "kiro.toml `question_panel' cluster -- all three present together.")

(defconst corral-kiro--idle-line-regexp
  "^[ \t]*[>›][ \t]*ask a question or describe a task"
  "kiro.toml `live_prompt_idle': the live idle prompt line.")

(defconst corral-kiro--working-contains
  '("kiro is working" "type to steer" "ctrl+s to queue")
  "kiro.toml `live_working_footer' phrases (any one).")

(defun corral-kiro--contains-p (text needle)
  (let ((case-fold-search t))
    (and (string-match-p (regexp-quote needle) text) t)))

(defun corral-kiro--line-matches-p (text regexp)
  "Non-nil if any line of TEXT matches REGEXP, case-insensitively --
herdr's `line_regex' semantics (match tested per line)."
  (let ((case-fold-search t))
    (cl-some (lambda (l) (string-match-p regexp l)) (split-string text "\n"))))

(defun corral-kiro--blocked-p (region)
  "Non-nil if REGION (the bottom non-empty lines) shows an approval or
question dialog, per kiro.toml's blocked rules -- each requiring a
footer AND a body line, not a lone phrase."
  (or
   ;; tool_approval: approval footer + a selected option line.
   (and (corral-kiro--line-matches-p region corral-kiro--approval-footer-regexp)
        (corral-kiro--line-matches-p region corral-kiro--approval-option-line-regexp))
   ;; crew_approval: any of its distinctive body phrases.
   (cl-some (lambda (n) (corral-kiro--contains-p region n))
            corral-kiro--crew-approval-contains)
   ;; question_panel: all three cluster phrases present together.
   (cl-every (lambda (n) (corral-kiro--contains-p region n))
             corral-kiro--question-panel-contains)))

(defun corral-kiro--classify (tail)
  "Classify TAIL for a Kiro CLI session into `blocked', `idle', or
`working'. All matching is scoped to the bottom non-empty lines of
TAIL (see `corral-kiro--bottom-non-empty-lines'), not the whole
scrollback -- the correction after live testing, where stale dialog
text in scrollback forced a permanent false `blocked'.

Order mirrors kiro.toml's priorities with one deliberate change:
blocked is checked before idle/working (it most needs the panel's
attention, and a dialog replaces the live footer on screen). Among the
non-blocked footers, idle outranks working, as `live_prompt_idle'
\(1100) outranks `live_working_footer' (950). Unmatched falls back to
idle."
  (let* ((blocked-region (corral-kiro--bottom-non-empty-lines tail 8))
         (live-region (corral-kiro--bottom-non-empty-lines tail 4)))
    (cond
     ((corral-kiro--blocked-p blocked-region) 'blocked)
     ((corral-kiro--line-matches-p live-region corral-kiro--idle-line-regexp) 'idle)
     ((cl-some (lambda (n) (corral-kiro--contains-p live-region n))
               corral-kiro--working-contains)
      'working)
     (t 'idle))))

(corral-harness-register
 (make-corral-harness :id 'kiro
                       :abbrev "kr"
                       :strategy 'scrape
                       :classifier #'corral-kiro--classify))

(corral-harness-add-variant 'kiro nil "kiro-cli chat")

(provide 'corral-kiro)
;;; corral-kiro.el ends here
