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
;; Rules below are ported from the original PoC's `herd-scrape.el'
;; (`herd-scrape--antigravity-state'), captured against real `agy'
;; v1.2.2 screen output -- not re-derived from scratch, and not from
;; herdr's own antigravity.toml manifest, which was tried first during
;; the PoC and matched nothing in this installed version.
;;
;; Re-verified 2026-09-27 against `agy' v1.2.12 (up from v1.2.2): a
;; fresh `herd-scrape-debug-log' capture (`/tmp/herd-scrape.log',
;; ~9000 ticks) shows the exact same literal strings still appear
;; verbatim, including the `RunCommand'-style confirmation dialog
;; ("Requesting permission for:" / "Run this command?" / "tab Amend")
;; with the status-bar tag still reading `[WORKING...]' underneath it
;; -- so the priority-ordering requirement (check the blocked text
;; first) still holds too. Not yet re-verified: a file-edit
;; confirmation dialog, which might use different wording and would
;; currently fall through to `working' uncaught -- still the one open
;; item from `../emacs-herd/antigravity-plan.md''s "Must re-verify"
;; section.

;;; Code:

(require 'cl-lib)
(require 'corral-core)
(require 'corral-harness)
(require 'corral-scrape)

(defconst corral-antigravity--blocked-contains "Requesting permission for:"
  "Exact, case-sensitive text preceding any agy tool-confirmation
dialog. Checked first (highest priority): the confirmation dialog is
an overlay, so agy's status-bar tag stays [WORKING...]/[USING TOOLS]
even while this is up.")

(defconst corral-antigravity--working-tags '("[WORKING...]" "[USING TOOLS]")
  "Literal status-bar tags agy shows while actively doing something.")

(defconst corral-antigravity--idle-tag "[IDLE]"
  "Literal status-bar tag agy shows when it's done and waiting for a
new prompt from the user.")

(defun corral-antigravity--classify (tail)
  "Classify TAIL (a string, the scanned buffer tail) for an antigravity
session into `blocked' (a tool confirmation is up), `working', or
`idle' (also the fallback when none of the known tags match)."
  (cond
   ((string-match-p (regexp-quote corral-antigravity--blocked-contains) tail)
    'blocked)
   ((cl-some (lambda (tag) (string-match-p (regexp-quote tag) tail))
             corral-antigravity--working-tags)
    'working)
   ((string-match-p (regexp-quote corral-antigravity--idle-tag) tail)
    'idle)
   (t 'idle)))

(corral-harness-register
 (make-corral-harness :id 'antigravity
                       :abbrev "ag"
                       :strategy 'scrape
                       :classifier #'corral-antigravity--classify))

(corral-harness-add-variant 'antigravity nil "agy")

(provide 'corral-antigravity)
;;; corral-antigravity.el ends here
