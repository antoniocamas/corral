;;; corral-scrape.el --- generic scrape-strategy plumbing -*- lexical-binding: t; -*-

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

;; Everything shared by every scrape-strategy harness (one with no hook
;; system to lean on, e.g. Antigravity's `agy' CLI): a single shared
;; timer that periodically scans the tail of every tracked session
;; whose harness has `:strategy 'scrape, classifies it, and reports
;; state changes the same way a hook script would via `corral-report'.
;;
;; No manually-tracked list of scrape-tracked pane-ids: the registry in
;; `corral-core.el' already knows every session and its harness, so the
;; timer is started/stopped purely by observing
;; `corral-session-change-hook' (the same pattern `corral-panel.el'
;; already uses) rather than threading extra start/stop calls into
;; `corral--do-launch'.

;;; Code:

(require 'corral-core)
(require 'corral-harness)
(require 'corral-vterm)

(defcustom corral-scrape-interval 1.0
  "Seconds between tail scans for scrape-strategy sessions."
  :type 'number
  :group 'corral)

(defcustom corral-scrape-debug-log "/tmp/corral-scrape.log"
  "If non-nil, every tick appends the classified state and a sample of
the scanned buffer tail here, so real screen text can be inspected
after the fact instead of guessing regexes blind. Set to nil to
disable once detection is trustworthy."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'corral)

(defvar corral-scrape--timer nil)

(defun corral-scrape--log (pane-id state tail)
  (when corral-scrape-debug-log
    (with-temp-buffer
      (insert (format "--- %s pane=%s state=%s\n" (format-time-string "%FT%T") pane-id state))
      (insert (or tail "") "\n")
      (write-region (point-min) (point-max) corral-scrape-debug-log t 'silent))))

(defun corral-scrape--scrape-sessions ()
  "Alist of (pane-id . session) for every registered session whose
harness uses the `scrape' strategy."
  (let (result)
    (maphash (lambda (pane-id session)
               (let* ((harness-id (plist-get session :harness))
                      (harness (corral-harness-get harness-id)))
                 (when (and harness (eq (corral-harness-strategy harness) 'scrape))
                   (push (cons pane-id session) result))))
             corral--sessions)
    result))

(defun corral-scrape--tick ()
  "Scan the tail of every scrape-strategy session and report a state
change the same way a hook script would, via `corral--set-state' plus
`corral--notify-attention' on transition to `blocked' -- mirrors
`corral-report's own logic in `corral-hook.el'."
  (dolist (entry (corral-scrape--scrape-sessions))
    (let* ((pane-id (car entry))
           (session (cdr entry))
           (harness (corral-harness-get (plist-get session :harness)))
           (buffer (plist-get session :buffer))
           (classifier (corral-harness-classifier harness))
           (tail-chars (corral-harness-tail-chars harness)))
      (when (and classifier (buffer-live-p buffer))
        (let* ((tail (corral--buffer-tail buffer tail-chars))
               (state (and tail (funcall classifier tail)))
               (previous (plist-get session :state)))
          (corral-scrape--log pane-id state tail)
          (when (and state (not (eq state previous)))
            (corral--set-state pane-id state)
            (when (eq state 'blocked)
              (corral--notify-attention pane-id))))))))

(defun corral-scrape--sync-timer ()
  "Start the shared scrape timer if any scrape-strategy session is
tracked and it isn't already running; stop it if none are. Called on
every `corral-session-change-hook' run, so no harness or launch code
needs to remember to start/stop this itself."
  (if (corral-scrape--scrape-sessions)
      (unless corral-scrape--timer
        (setq corral-scrape--timer
              (run-with-timer corral-scrape-interval corral-scrape-interval
                               #'corral-scrape--tick)))
    (when corral-scrape--timer
      (cancel-timer corral-scrape--timer)
      (setq corral-scrape--timer nil))))

(add-hook 'corral-session-change-hook #'corral-scrape--sync-timer)

(provide 'corral-scrape)
;;; corral-scrape.el ends here
