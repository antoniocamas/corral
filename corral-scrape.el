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
;; state changes through `corral--set-state'.
;;
;; No manually-tracked list of scrape-tracked pane-ids: the registry in
;; `corral-core.el' already knows every session and its harness, so the
;; timer is started/stopped purely by observing
;; `corral-session-change-hook' (the same pattern `corral-panel.el'
;; already uses) rather than threading extra start/stop calls into
;; `corral--do-launch'.

;;; Code:

(require 'cl-lib)
(require 'corral-core)
(require 'corral-harness)
(require 'corral-vterm)

(defcustom corral-scrape-interval 1.0
  "Seconds between tail scans for scrape-strategy sessions."
  :type 'number
  :group 'corral)

(defcustom corral-scrape-debug-log nil
  "If non-nil, every tick appends the classified state and a sample of
the scanned buffer tail to this file, so real screen text can be
inspected after the fact instead of guessing regexes blind.

Off by default: this writes on EVERY tick for EVERY scrape session
\(~20 KB of buffer tail each, once a second), which with nothing ever
truncating it grows without bound -- a real session left it at over a
gigabyte. It is a detection-debugging aid to switch on deliberately
while porting or tuning a classifier, not something to leave running.
`corral-scrape-debug-log-max-bytes' caps it even when enabled."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'corral)

(defcustom corral-scrape-debug-log-max-bytes (* 5 1024 1024)
  "Truncate `corral-scrape-debug-log' back to empty once it grows past
this many bytes, so an enabled debug log can't grow without bound (the
earlier behaviour left it at over a gigabyte). nil means never
truncate."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'corral)

(defvar corral-scrape--timer nil)

(defvar corral-scrape-title nil
  "Bound by `corral-scrape--tick' to the terminal title of the buffer
being classified (see `corral-vterm-title'), nil if none. Classifiers
for tools that signal activity through the title read it; the rest
ignore it.")

(defun corral-scrape-bottom-non-empty-lines (tail n)
  "The last N non-empty lines of TAIL, rejoined with newlines --
corral's port of herdr's `bottom_non_empty_lines(N)' region
\(`src/detect/mod.rs'). Trailing blank padding (a full-screen TUI pads
unused rows) is skipped; the slice starts at the Nth-from-last
non-blank line and runs to the end, blank lines in between included,
matching herdr's slice semantics.

Scrape classifiers scope their rules to a region like this rather
than the whole tail: corral hands them a large character tail, so
text from an earlier dialog still in scrollback would otherwise
override the live screen."
  (let* ((lines (split-string tail "\n"))
         (indexed (cl-loop for l in lines for i from 0
                           unless (string-empty-p (string-trim l))
                           collect i))
         (start (nth (max 0 (- (length indexed) n)) indexed)))
    (if start
        (mapconcat #'identity (nthcdr start lines) "\n")
      "")))

(defun corral-scrape--log (pane-id state tail)
  (when corral-scrape-debug-log
    (when (and corral-scrape-debug-log-max-bytes
               (file-exists-p corral-scrape-debug-log)
               (> (file-attribute-size (file-attributes corral-scrape-debug-log))
                  corral-scrape-debug-log-max-bytes))
      ;; Truncate rather than append forever. `write-region' with an
      ;; empty region and no append flag replaces the file's contents.
      (write-region "" nil corral-scrape-debug-log nil 'silent))
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
change via `corral--set-state', plus `corral--notify-attention' on
transition to `blocked'.

Each session is scanned inside `condition-case': this runs on a
shared repeating timer, and an unhandled error escaping the timer
function makes Emacs DISABLE the timer entirely (removing it from
`timer-list' while `corral-scrape--timer' still points at the now-dead
object), which silently stops tracking for EVERY scrape session at
once. One session's transient classifier/buffer error must not take
the whole timer down, so it is caught, logged, and skipped."
  (dolist (entry (corral-scrape--scrape-sessions))
    (condition-case err
        (let* ((pane-id (car entry))
               (session (cdr entry))
               (harness (corral-harness-get (plist-get session :harness)))
               (buffer (plist-get session :buffer))
               (classifier (corral-harness-classifier harness))
               (tail-chars (corral-harness-tail-chars harness)))
          (when (and classifier (buffer-live-p buffer))
            (let* ((tail (corral--buffer-tail buffer tail-chars))
                   (state (and tail
                               (let ((corral-scrape-title
                                      (buffer-local-value
                                       'corral-vterm-title buffer)))
                                 (funcall classifier tail))))
                   (previous (plist-get session :state)))
              (corral-scrape--log pane-id state tail)
              (when (and state (not (eq state previous)))
                (corral--set-state pane-id state)
                (when (eq state 'blocked)
                  (corral--notify-attention pane-id))))))
      (error
       (corral-scrape--log (car entry) (format "tick-error: %S" err) nil)))))

(defun corral-scrape--timer-live-p ()
  "Non-nil only if `corral-scrape--timer' holds a timer that is
actually still scheduled. A cancelled timer -- or one Emacs disabled
after its function signalled -- leaves the variable bound to a now-dead
timer object that is no longer in `timer-list'; treating that as
\"running\" would wedge every scrape session forever (nothing ever
rescans them). Checking membership in `timer-list', not just non-nil,
is what lets `corral-scrape--sync-timer' notice and restart it."
  (and corral-scrape--timer
       (memq corral-scrape--timer timer-list)
       t))

(defun corral-scrape--sync-timer ()
  "Start the shared scrape timer if any scrape-strategy session is
tracked and it isn't already running; stop it if none are. Called on
every `corral-session-change-hook' run, so no harness or launch code
needs to remember to start/stop this itself.

\"Already running\" means a genuinely live timer (see
`corral-scrape--timer-live-p'), not merely a non-nil variable: a dead
timer left in the variable (cancelled, or auto-disabled after its tick
signalled an error) must be replaced, or scrape tracking silently stops
for good -- the panel keeps showing every scrape session frozen at its
last state no matter how many times it is relaunched or re-adopted."
  (if (corral-scrape--scrape-sessions)
      (unless (corral-scrape--timer-live-p)
        (when corral-scrape--timer
          (cancel-timer corral-scrape--timer))
        (setq corral-scrape--timer
              (run-with-timer corral-scrape-interval corral-scrape-interval
                               #'corral-scrape--tick)))
    (when corral-scrape--timer
      (cancel-timer corral-scrape--timer)
      (setq corral-scrape--timer nil))))

(add-hook 'corral-session-change-hook #'corral-scrape--sync-timer)

(provide 'corral-scrape)
;;; corral-scrape.el ends here
