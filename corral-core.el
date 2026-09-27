;;; corral-core.el --- session registry and state model -*- lexical-binding: t; -*-

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

;; Harness-agnostic session registry.  A "session" is one tracked
;; buffer running one coding-agent harness (Claude Code, Antigravity,
;; ...), identified by a pane-id.  This file knows nothing about any
;; particular harness, how it's launched, or how its state is
;; detected (hooks vs. screen-scraping) -- it only stores
;; working/blocked/idle and notifies interested parties (the panel,
;; the attention nudge) when that changes.

;;; Code:

(require 'cl-lib)
(require 'server)
(require 'face-remap)

(defgroup corral nil
  "Side panel tracking coding-agent sessions running in vterm buffers."
  :group 'tools)

(defface corral-state-working '((t :inherit success))
  "Face for sessions actively working.")

(defface corral-state-blocked '((t :inherit error))
  "Face for sessions blocked on user input -- can't proceed without a
decision from you (e.g. a tool-permission prompt). Red, not just
orange/warning-colored: this is the state that most needs your
attention, more urgent than a generic warning.")

(defface corral-state-idle '((t :inherit shadow))
  "Face for idle/done sessions.")

(defvar corral--sessions (make-hash-table :test 'equal)
  "Pane-id -> plist (:buffer :harness :variant :state :updated-at).")

(defvar corral--pane-counter 0)

(defvar corral-session-change-hook nil
  "Run after any registry mutation: registration, state change, or
removal.  The panel and other observers hook in here instead of
being called directly, so this file stays independent of any UI.")

(defun corral--new-pane-id ()
  (setq corral--pane-counter (1+ corral--pane-counter))
  (format "corral-%d-%d" (emacs-pid) corral--pane-counter))

(defun corral--register (pane-id buffer harness-id variant-name &optional suffix)
  "Track BUFFER under PANE-ID for HARNESS-ID/VARIANT-NAME.
Initial state is `unknown' until the harness's detection strategy
reports something real. SUFFIX, when given, is the session-name
suffix chosen at launch time (see `corral--do-launch') -- stored
separately so the panel can build a short label directly instead of
parsing it back out of the buffer's real name.

Also stashes PANE-ID/HARNESS-ID/VARIANT-NAME/SUFFIX as properties on
BUFFER's process, not just in `corral--sessions' or a buffer-local
variable -- a process's property list is untouched by `unload-feature'
\(verified directly: a buffer-local variable's value is NOT, it gets
cleared the moment its defining file is unloaded\), so this is what
lets `corral-recover-sessions' reconstruct a session that
`corral-reload-from-source' wiped out from under a still-running vterm
buffer."
  (puthash pane-id
           (list :buffer buffer :harness harness-id :variant variant-name
                 :suffix suffix :state 'unknown :updated-at (current-time))
           corral--sessions)
  (with-current-buffer buffer
    (setq-local corral--pane-id pane-id)
    (add-hook 'kill-buffer-hook #'corral--unregister-current-buffer nil t)
    (let ((proc (get-buffer-process buffer)))
      (when proc
        (process-put proc 'corral-pane-id pane-id)
        (process-put proc 'corral-harness harness-id)
        (process-put proc 'corral-variant variant-name)
        (process-put proc 'corral-suffix suffix))))
  (run-hooks 'corral-session-change-hook))

(defvar-local corral--pane-id nil
  "Pane-id of the corral session tracked in this buffer, if any.")

(defun corral--unregister-current-buffer ()
  (when corral--pane-id
    (remhash corral--pane-id corral--sessions)
    (run-hooks 'corral-session-change-hook)))

;;;###autoload
(defun corral-recover-sessions ()
  "Re-register any live vterm session whose process still carries
corral's identity properties (see `corral--register') but whose entry
in `corral--sessions' is gone -- the situation `corral-reload-from-source'
leaves behind, since `unload-feature' wipes that hash table (and every
buffer-local variable, including the pane-id one) but has no effect on
already-running processes or their property lists.

Call this once, right after re-`require'ing corral from source. Each
recovered session starts back at state `unknown' -- exactly like a
freshly launched one -- since there is no way to recover the last
known state, only its identity; a hook-capable harness resyncs on its
next hook event, a scrape-capable one on its next tick once
`corral-scrape--sync-timer' notices it and restarts the shared timer."
  (interactive)
  (dolist (proc (process-list))
    (let ((pane-id (process-get proc 'corral-pane-id))
          (buffer (process-buffer proc)))
      (when (and pane-id (buffer-live-p buffer)
                 (not (gethash pane-id corral--sessions)))
        (corral--register pane-id buffer
                           (process-get proc 'corral-harness)
                           (process-get proc 'corral-variant)
                           (process-get proc 'corral-suffix))))))

(defun corral--process-environ-value (pid var)
  "Return VAR's value from PID's environment via /proc/PID/environ, or
nil if unreadable or VAR isn't set.

Linux-only -- /proc doesn't exist elsewhere -- but that's the only
platform corral has ever run on (see AGENTS.md's Environment). Used to
recover a session's real pane-id straight from an already-running
process's environment (see `corral-adopt-buffer' in
`corral-harness.el'): the pane-id was set once, as CORRAL_PANE_ID, when
the process was originally spawned by `corral--do-launch', and never
changes for the life of that process -- so this is authoritative,
unlike guessing from a buffer name."
  (let ((file (format "/proc/%d/environ" pid)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents-literally file)
        (let ((prefix (concat var "=")))
          (cl-some (lambda (entry) (and (string-prefix-p prefix entry)
                                        (substring entry (length prefix))))
                   (split-string (buffer-string) "\0" t)))))))

(defun corral--set-state (pane-id state)
  "Set PANE-ID's state to STATE (a symbol: working/blocked/idle).
A no-op if PANE-ID isn't registered (e.g. its buffer was already
killed) -- callers don't need to guard against that themselves."
  (let ((session (gethash pane-id corral--sessions)))
    (when session
      (plist-put session :state state)
      (plist-put session :updated-at (current-time))
      (puthash pane-id session corral--sessions)
      (run-hooks 'corral-session-change-hook))))

(defun corral--session-label (pane-id)
  "Human-readable label for PANE-ID, for messages -- the tracked
buffer's real name if it's still live, else the pane-id itself."
  (let* ((session (gethash pane-id corral--sessions))
         (buffer (and session (plist-get session :buffer))))
    (if (buffer-live-p buffer) (buffer-name buffer) pane-id)))

(defun corral--flash-mode-line ()
  (let ((cookie (face-remap-add-relative 'mode-line 'corral-state-blocked)))
    (force-mode-line-update)
    (run-at-time 0.2 nil
                 (lambda ()
                   (face-remap-remove-relative cookie)
                   (force-mode-line-update)))))

(defun corral--notify-attention (pane-id)
  (message "corral: %s needs input" (corral--session-label pane-id))
  (corral--flash-mode-line))

(defun corral--server-socket-name ()
  "Value to hand `emacsclient -s' so it reaches THIS Emacs.

Needed at two points: when a launched session's environment is set
up (so a hook script or scraped process knows where to report back),
and when resolving that value back into an actual connection.

`server-name' is sometimes set to a path containing a literal `~',
which Emacs itself expands internally but which `emacsclient -s'
does not (that only happens via shell expansion, and this value
never passes through a shell) -- discovered the hard way in the
corral PoC. Resolve it here instead."
  (unless (server-running-p)
    (user-error "Emacs server is not running here (M-x server-start first) \
-- a hook-based or scrape-based harness won't be able to correlate \
back to this Emacs"))
  (let ((name (or server-name "server")))
    (if (string-match-p "/" name)
        (expand-file-name name)
      name)))

(provide 'corral-core)
;;; corral-core.el ends here
