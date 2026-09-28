;;; corral-panel.el --- side panel UI -*- lexical-binding: t; -*-

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

;; A hand-rendered buffer listing every tracked session, kept in sync
;; purely by observing `corral-session-change-hook' -- this file never
;; needs to know why a state changed, only that it did.
;;
;; Deliberately not `tabulated-list-mode': that forces a header row
;; and fixed-width columns, neither of which fit a narrow, discreet
;; side window meant to be glanced at, not read as a table. Each
;; session gets two compact lines instead: an abbreviated label plus
;; its colored state on the first, the elapsed time in a dim face
;; underneath.

;;; Code:

(require 'corral-core)
(require 'corral-harness)

(defvar corral-panel-buffer-name "*corral*")

(defvar corral-panel-window-width 30
  "Width of the side window `corral-show-panel' opens. Sized for the
compact two-line entries this buffer renders, not a table.")

(define-derived-mode corral-panel-mode special-mode "Corral"
  "Major mode for the corral session panel.")

(defun corral--state-face (state)
  (pcase state
    ('working 'corral-state-working)
    ('blocked 'corral-state-blocked)
    ('idle 'corral-state-idle)
    (_ 'default)))

(defun corral--format-elapsed (time)
  (let ((secs (float-time (time-subtract (current-time) time))))
    (cond
     ((< secs 60) (format "%ds" (truncate secs)))
     ((< secs 3600) (format "%dm" (truncate (/ secs 60))))
     (t (format "%dh" (truncate (/ secs 3600)))))))

(defun corral--panel-label (session)
  "Short label for SESSION: <harness-abbrev>[-<variant>]-<suffix>,
e.g. \"cl-zai-myproject\". Falls back to the tracked buffer's real
name when no suffix was recorded (a session registered some way other
than through `corral--do-launch')."
  (let* ((harness-id (plist-get session :harness))
         (variant (plist-get session :variant))
         (suffix (plist-get session :suffix)))
    (if suffix
        (let* ((harness (corral-harness-get harness-id))
               (abbrev (or (and harness (corral-harness-abbrev harness))
                           (symbol-name harness-id))))
          (mapconcat #'identity (delq nil (list abbrev variant suffix)) "-"))
      (let ((buffer (plist-get session :buffer)))
        (if (buffer-live-p buffer) (buffer-name buffer) (symbol-name harness-id))))))

(defun corral--panel-render ()
  "Redraw the whole panel buffer from `corral--sessions'. Callers
handle preserving point/scroll position -- this always starts fresh
at `point-min'."
  (let ((inhibit-read-only t)
        pane-ids)
    (maphash (lambda (id _) (push id pane-ids)) corral--sessions)
    (setq pane-ids (nreverse pane-ids))
    (erase-buffer)
    (dolist (pane-id pane-ids)
      (let* ((session (gethash pane-id corral--sessions))
             (state (plist-get session :state))
             (label (corral--panel-label session))
             (elapsed (corral--format-elapsed (plist-get session :updated-at)))
             (start (point)))
        (insert label "  " (propertize (symbol-name state) 'face (corral--state-face state)) "\n")
        (insert (propertize (concat "  " elapsed) 'face 'shadow) "\n\n")
        (put-text-property start (point) 'corral-pane-id pane-id)))
    (goto-char (point-min))))

(defun corral--get-panel-buffer ()
  (or (get-buffer corral-panel-buffer-name)
      (with-current-buffer (get-buffer-create corral-panel-buffer-name)
        (corral-panel-mode)
        (current-buffer))))

(defun corral--refresh-panel ()
  "Redraw the panel if it exists, preserving which session point/the
window's scroll was on, so a background state change doesn't yank the
view out from under someone reading it."
  (let ((buf (get-buffer corral-panel-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((old-pane-id (get-text-property (point) 'corral-pane-id))
              (win (get-buffer-window buf))
              old-window-start)
          (when win (setq old-window-start (window-start win)))
          (corral--panel-render)
          (when old-pane-id
            (let ((found (text-property-any (point-min) (point-max)
                                             'corral-pane-id old-pane-id)))
              (when found (goto-char found))))
          (when (and win old-window-start)
            (set-window-start win old-window-start t)))))))

(add-hook 'corral-session-change-hook #'corral--refresh-panel)

;;;###autoload
(defun corral-show-panel ()
  "Show the corral session panel in a right side window.

The window is marked dedicated and excluded from `other-window'
cycling -- a plain `display-buffer-in-side-window' call does neither
by default, which in practice meant `other-window' (`C-x o') could
land there by surprise, and a plain `switch-to-buffer' (`C-x b') while
it was selected would happily replace the panel with whatever buffer
you picked, turning the side window into an ordinary one. Both are
standard window parameters (`no-other-window', dedicating via
`set-window-dedicated-p'), not special panel logic -- a dedicated
window makes `switch-to-buffer' find or create another window instead
of clobbering this one."
  (interactive)
  (let* ((buf (corral--get-panel-buffer))
         (window (display-buffer-in-side-window
                  buf
                  `((side . right) (slot . 0)
                    (window-width . ,corral-panel-window-width)
                    (window-parameters . ((no-other-window . t)
                                           (no-delete-other-windows . t)))))))
    (with-current-buffer buf
      (corral--panel-render))
    (when window
      (set-window-dedicated-p window t))))

(defun corral--session-at-point ()
  (let ((pane-id (get-text-property (point) 'corral-pane-id)))
    (unless pane-id
      (user-error "No session at point"))
    (cons pane-id (gethash pane-id corral--sessions))))

;;;###autoload
(defun corral-rename-session ()
  "Rename the tracked buffer at point in the corral panel.
Thin wrapper around `rename-buffer' -- the panel label is derived from
the harness/variant/suffix, not this name, so renaming the underlying
buffer is purely for your own buffer-list convenience and has no
effect on what the panel shows."
  (interactive)
  (let* ((entry (corral--session-at-point))
         (buffer (plist-get (cdr entry) :buffer)))
    (unless (buffer-live-p buffer)
      (user-error "That session's buffer is gone"))
    (let ((new-name (read-string "Rename session buffer to: " (buffer-name buffer))))
      (with-current-buffer buffer
        (rename-buffer new-name t)))
    (run-hooks 'corral-session-change-hook)))

;;;###autoload
(defun corral-switch-to-session ()
  "Switch to the tracked buffer at point in the corral panel."
  (interactive)
  (let* ((entry (corral--session-at-point))
         (buffer (plist-get (cdr entry) :buffer)))
    (unless (buffer-live-p buffer)
      (user-error "That session's buffer is gone"))
    (select-window (display-buffer buffer))))

(define-key corral-panel-mode-map (kbd "g") #'corral-show-panel)
(define-key corral-panel-mode-map (kbd "r") #'corral-rename-session)
(define-key corral-panel-mode-map (kbd "RET") #'corral-switch-to-session)

(provide 'corral-panel)
;;; corral-panel.el ends here
