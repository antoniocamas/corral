;;; corral-claude.el --- Claude Code harness (scrape strategy) -*- lexical-binding: t; -*-

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

;; Claude Code is tracked by screen-scraping (`corral-scrape.el'): the
;; shared timer periodically hands the tail of each tracked buffer to
;; `corral-claude--classify', which maps what Claude Code is showing
;; right now to working/blocked/idle.
;;
;; This used to be hook-based (Claude Code's PreToolUse/PostToolUse/
;; Stop/... hooks calling back into Emacs). That left sessions stuck on
;; `working': no hook fires when you interrupt a turn with Esc, and a
;; turn killed by an API error ends without `Stop'. The screen cannot
;; get out of sync that way -- whatever is drawn is the truth -- which
;; is also why herdr (see docs/inspiration.md) detects Claude Code from
;; the screen and keeps hooks only for session identity. corral needs
;; no session identity from Claude, so it installs no hooks at all and
;; touches no settings.json.
;;
;; Rules were captured from a real Claude Code (v2.1.292) running in a
;; vterm buffer, then cross-checked against herdr's `claude.toml'
;; (`src/detect/manifests/claude.toml'), per
;; `.agents/rules/harness-design.md'. What the live screen looks like:
;;
;;   working   a spinner line "✶ Shimmying… (3s · ↓ 62 tokens)" (the
;;             glyph varies, the "…" does not), and a footer
;;             "⏸ manual mode on · esc to interrupt" /
;;             "⏵⏵ auto mode on · esc to interrupt". The footer is the
;;             more robust of the two: while a reply streams, the
;;             spinner line scrolls out of view but the footer stays.
;;   idle      the prompt box ("❯ ...") with neither of the above. A
;;             finished turn leaves "✻ Cooked for 7s · done 22:17" --
;;             same glyph family as the spinner but no "…", which is
;;             what keeps it from reading as working. After an Esc
;;             interrupt the screen shows "Interrupted · What should
;;             Claude do instead?" with no working markers: idle.
;;   blocked   a permission dialog ("Do you want to proceed?" with
;;             "1. Yes" ... "4. No" options), or a form/confirm dialog
;;             whose footer reads "Enter to confirm · Esc to cancel"
;;             (the folder-trust prompt at startup, question forms).
;;
;; Every rule is scoped to the live bottom of the screen, never the
;; whole tail: a dismissed dialog's text is still in scrollback.
;; Working rules look at the bottom non-empty lines
;; (`corral-claude--working-region-lines'); blocked rules look only
;; below the last horizontal rule, where Claude draws its dialogs and
;; footer (`corral-claude--after-last-rule').
;;
;; DELIBERATELY NOT ported from claude.toml: the OSC-title spinner
;; rule (corral only sees rendered buffer text, not escape sequences,
;; same reason as in `corral-kiro.el'), and the "Waiting for N
;; background agents"/"MCP tasks still running" working rules (not yet
;; observed on a real screen; add them with a captured sample).
;;
;; This file also defines the vanilla "claude" launch variant. Personal
;; wrapper variants (an API-key wrapper, --dangerously-skip-permissions,
;; whatever else) belong in your own config, e.g.:
;;
;;   (corral-harness-add-variant 'claude "orig" "claude-orig --dangerously-skip-permissions")

;;; Code:

(require 'cl-lib)
(require 'corral-core)
(require 'corral-harness)
(require 'corral-scrape)

(defconst corral-claude--working-region-lines 12
  "How many bottom non-empty lines the working rules look at -- enough
for the spinner line, a prompt box and the footer, from herdr's
`live_turn_working' (`bottom_non_empty_lines(12)').")

(defconst corral-claude--working-footer-regexp
  "^[ \t]*[⏸⏵].*esc to interrupt\\(?:[ \t·]\\|$\\)"
  "The mode footer while a turn is running. Anchored on the leading
mode glyph so that typed or quoted text containing \"esc to
interrupt\" cannot impersonate it.")

(defconst corral-claude--spinner-regexp
  (concat "^[ \t]*[*·✢✳✶✻✽][ \t]+[^ \t].*…"
          "\\(?:[ \t]*$\\|[ \t]+([0-9]+[smh]\\)")
  "The spinner line: a spinner glyph, a verb, then \"…\" and either end
of line or the elapsed-time parenthesis. The finished-turn summary
\"✻ Cooked for 7s\" shares the glyph but has no \"…\", so it does not
match.")

(defconst corral-claude--rule-regexp "^[ \t]*─\\{10,\\}[ \t]*$"
  "A full-width horizontal rule, as drawn around the prompt box and
above dialogs. Only the solid \"─\"; a dialog's own dashed \"╌\"
separators must not count.")

(defconst corral-claude--dialog-question-regexp
  "^[ \t]*\\(?:do you want to\\|would you like to\\)\\b"
  "Case-insensitive: the question line of a permission dialog.")

(defconst corral-claude--dialog-option-regexp
  "^[ \t]*[❯>]?[ \t]*[1-9]\\.[ \t]*\\(?:yes\\|no\\)\\b"
  "Case-insensitive: a numbered Yes/No option, selected (\"❯\") or not.")

(defun corral-claude--lines-match-p (text regexp)
  "Non-nil if any line of TEXT matches REGEXP, case-insensitively."
  (let ((case-fold-search t))
    (cl-some (lambda (l) (string-match-p regexp l)) (split-string text "\n"))))

(defun corral-claude--after-last-rule (tail)
  "The part of TAIL below the last solid horizontal rule, trailing
blank padding trimmed. Without any rule (Claude not drawn yet), the
bottom `corral-claude--working-region-lines' non-empty lines instead."
  (let* ((live (corral-scrape-bottom-non-empty-lines
                tail (* 2 corral-claude--working-region-lines)))
         (lines (split-string live "\n"))
         (rule (cl-position-if
                (lambda (l) (string-match-p corral-claude--rule-regexp l))
                lines :from-end t)))
    (if rule
        (mapconcat #'identity (nthcdr (1+ rule) lines) "\n")
      (corral-scrape-bottom-non-empty-lines
       tail corral-claude--working-region-lines))))

(defun corral-claude--blocked-p (region)
  "Non-nil if REGION (see `corral-claude--after-last-rule') shows a
dialog waiting on you: a permission question together with a Yes/No
option line, or an \"Esc to cancel\" footer together with an Enter
hint. Each needs two cues, not a lone phrase, so ordinary text that
mentions one of them does not trip it."
  (or (and (corral-claude--lines-match-p
            region corral-claude--dialog-question-regexp)
           (corral-claude--lines-match-p
            region corral-claude--dialog-option-regexp))
      (let ((case-fold-search t))
        (and (string-match-p "esc to cancel" region)
             (string-match-p "enter to \\(?:confirm\\|select\\)" region)))))

(defun corral-claude--working-p (region)
  "Non-nil if REGION (the bottom non-empty lines) shows a running turn."
  (or (corral-claude--lines-match-p
       region corral-claude--working-footer-regexp)
      (let ((case-fold-search nil))
        (cl-some (lambda (l) (string-match-p corral-claude--spinner-regexp l))
                 (split-string region "\n")))))

(defun corral-claude--classify (tail)
  "Classify TAIL for a Claude Code session into `blocked', `working'
or `idle'. blocked wins (it most needs the panel's attention, and a
dialog replaces the live footer on screen), then working; anything
else -- the prompt box, a bare shell before Claude starts, an empty
tail -- is `idle'."
  (cond
   ((corral-claude--blocked-p (corral-claude--after-last-rule tail)) 'blocked)
   ((corral-claude--working-p
     (corral-scrape-bottom-non-empty-lines
      tail corral-claude--working-region-lines))
    'working)
   (t 'idle)))

(corral-harness-register
 (make-corral-harness :id 'claude
                       :abbrev "cl"
                       :strategy 'scrape
                       :classifier #'corral-claude--classify))

(corral-harness-add-variant 'claude nil "claude")

(provide 'corral-claude)
;;; corral-claude.el ends here
