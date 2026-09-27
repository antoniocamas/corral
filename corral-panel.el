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

;; A tabulated-list-mode buffer listing every tracked session, kept
;; in sync purely by observing `corral-session-change-hook' -- this
;; file never needs to know why a state changed, only that it did.

;;; Code:

(require 'tabulated-list)
(require 'corral-core)

(defvar corral-panel-buffer-name "*corral*")

(define-derived-mode corral-panel-mode tabulated-list-mode "Corral"
  "Major mode for the corral session panel."
  (setq tabulated-list-format
        [("Session" 26 t) ("Harness" 12 t) ("State" 10 t) ("Since" 8 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun corral--state-face (state)
  (pcase state
    ('working 'corral-state-working)
    ('waiting 'corral-state-waiting)
    ('idle 'corral-state-idle)
    (_ 'default)))

(defun corral--format-elapsed (time)
  (let ((secs (float-time (time-subtract (current-time) time))))
    (cond
     ((< secs 60) (format "%ds" (truncate secs)))
     ((< secs 3600) (format "%dm" (truncate (/ secs 60))))
     (t (format "%dh" (truncate (/ secs 3600)))))))

(defun corral--panel-entries ()
  (let (entries)
    (maphash
     (lambda (pane-id session)
       (let* ((buffer (plist-get session :buffer))
              (harness (plist-get session :harness))
              (variant (plist-get session :variant))
              (state (plist-get session :state))
              (name (if (buffer-live-p buffer) (buffer-name buffer) "<dead>"))
              (harness-label (if variant (format "%s/%s" harness variant) (symbol-name harness))))
         (push (list pane-id
                     (vector name
                             harness-label
                             (propertize (symbol-name state)
                                         'face (corral--state-face state))
                             (corral--format-elapsed (plist-get session :updated-at))))
               entries)))
     corral--sessions)
    (nreverse entries)))

(defun corral--get-panel-buffer ()
  (or (get-buffer corral-panel-buffer-name)
      (with-current-buffer (get-buffer-create corral-panel-buffer-name)
        (corral-panel-mode)
        (current-buffer))))

(defun corral--refresh-panel ()
  (let ((buf (get-buffer corral-panel-buffer-name)))
    (when buf
      (with-current-buffer buf
        (setq tabulated-list-entries (corral--panel-entries))
        (tabulated-list-print t)))))

(add-hook 'corral-session-change-hook #'corral--refresh-panel)

;;;###autoload
(defun corral-show-panel ()
  "Show the corral session panel in a right side window."
  (interactive)
  (let ((buf (corral--get-panel-buffer)))
    (with-current-buffer buf
      (setq tabulated-list-entries (corral--panel-entries))
      (tabulated-list-print t))
    (display-buffer-in-side-window
     buf
     '((side . right) (slot . 0) (window-width . 40)))))

;;;###autoload
(defun corral-rename-session ()
  "Rename the tracked buffer at point in the corral panel.
Thin wrapper around `rename-buffer' so the panel (which just shows
each buffer's real name) reflects the new name."
  (interactive)
  (let ((pane-id (tabulated-list-get-id)))
    (unless pane-id
      (user-error "No session at point"))
    (let* ((session (gethash pane-id corral--sessions))
           (buffer (and session (plist-get session :buffer))))
      (unless (buffer-live-p buffer)
        (user-error "That session's buffer is gone"))
      (let ((new-name (read-string "Rename session buffer to: " (buffer-name buffer))))
        (with-current-buffer buffer
          (rename-buffer new-name t)))
      (run-hooks 'corral-session-change-hook))))

(define-key corral-panel-mode-map (kbd "r") #'corral-rename-session)

(provide 'corral-panel)
;;; corral-panel.el ends here
