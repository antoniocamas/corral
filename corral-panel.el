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
;; session gets two compact lines instead: the label on the first
;; (given the whole width, so a long one never crowds anything out),
;; its colored state and the elapsed time together on the second.

;;; Code:

(require 'corral-core)
(require 'corral-harness)

(defvar corral-panel-buffer-name "*corral*")

(defvar corral-panel-window-width 30
  "Width of the side window `corral-show-panel' opens. Sized for the
compact two-line entries this buffer renders, not a table.")

(defcustom corral-panel-visible-marker ">"
  "String shown in the panel's left gutter for a session whose buffer
is currently visible in some window (on any visible frame). A session
whose buffer is not on screen gets a blank gutter of the same width,
so labels stay aligned. Keep it one character wide for that alignment."
  :type 'string
  :group 'corral)

(defface corral-panel-focused '((t :inherit ansi-color-inverse))
  "Face for the label of the session whose buffer is in the selected
window -- the one you are focused on right now, as opposed to merely
visible (which the gutter marker shows). Orthogonal to the
working/blocked/idle state colour, which stays on the state word."
  :group 'corral)

(define-derived-mode corral-panel-mode special-mode "Corral"
  "Major mode for the corral session panel."
  ;; Also turn on the session minor mode here so `C-h m' in the panel
  ;; documents corral and its keys, the same as in a session buffer.
  (corral-session-mode 1))

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
at `point-min'.

Each row's left gutter shows `corral-panel-visible-marker' when the
session's buffer is visible in some window (any visible frame), a
blank of the same width otherwise, so labels stay aligned. The one
session whose buffer is in the selected window -- the one you are
actually focused on -- additionally gets its label in
`corral-panel-focused'. Visibility/focus are read fresh here from the
window state, so a bare window rearrangement (which never touches
`corral--sessions') still updates the panel once `corral--refresh-panel'
is re-run from a window-change hook."
  (let* ((inhibit-read-only t)
         (gutter-width (max 1 (string-width corral-panel-visible-marker)))
         (blank-gutter (make-string gutter-width ?\s))
         ;; The buffer of the selected window is the focused one -- nil
         ;; when the panel itself or the minibuffer is selected, which
         ;; correctly leaves no row highlighted.
         (focused-buffer (window-buffer (selected-window)))
         pane-ids)
    (maphash (lambda (id _) (push id pane-ids)) corral--sessions)
    (setq pane-ids (nreverse pane-ids))
    (erase-buffer)
    (dolist (pane-id pane-ids)
      (let* ((session (gethash pane-id corral--sessions))
             (state (plist-get session :state))
             (buffer (plist-get session :buffer))
             (label (corral--panel-label session))
             (elapsed (corral--format-elapsed (plist-get session :updated-at)))
             ;; `get-buffer-window' with ALL-FRAMES t spans every live
             ;; frame; a buffer shown anywhere on screen counts.
             (visible (and (buffer-live-p buffer)
                           (get-buffer-window buffer t)))
             (focused (and (buffer-live-p buffer) (eq buffer focused-buffer)))
             (gutter (if visible corral-panel-visible-marker blank-gutter))
             (start (point)))
        ;; Line 1: gutter + label (the label gets the whole width, so a
        ;; long one never pushes the state off the narrow panel).
        (insert gutter " "
                (if focused (propertize label 'face 'corral-panel-focused) label)
                "\n")
        ;; Line 2: state (colored) then elapsed (dim), under the label.
        (insert blank-gutter " "
                (propertize (symbol-name state) 'face (corral--state-face state))
                "  " (propertize elapsed 'face 'shadow) "\n\n")
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

;; Visibility and focus can change with no session-state change at all
;; -- splitting a window, switching a buffer, selecting another window.
;; None of those run `corral-session-change-hook', so without this the
;; gutter marker and focus highlight would go stale until the next real
;; state change. `window-selection-change-functions' (Emacs 27+) covers
;; a plain focus move between existing windows, which
;; `window-configuration-change-hook' alone does not; both just re-run
;; the cheap, panel-only refresh (it early-returns when no panel exists
;; and never touches window configuration, so there is no feedback
;; loop). The functions take an argument; `corral--refresh-panel' does
;; not, so wrap it.
(defun corral--refresh-panel-on-window-change (&rest _)
  "Window-change-hook adapter for `corral--refresh-panel'."
  (corral--refresh-panel))

(add-hook 'window-configuration-change-hook #'corral--refresh-panel-on-window-change)
(when (boundp 'window-selection-change-functions)
  (add-hook 'window-selection-change-functions #'corral--refresh-panel-on-window-change))

(defun corral--panel-window ()
  "Return the live window currently showing the panel buffer, or nil.
Spans every live frame, matching how the panel's visible-marker logic
treats visibility, so toggling and gutter marking agree on what
\"shown\" means."
  (let ((buf (get-buffer corral-panel-buffer-name)))
    (and buf (get-buffer-window buf t))))

;;;###autoload
(defun corral-show-panel ()
  "Toggle the corral session panel in a right side window.

If the panel is already showing in some window, delete that window
and return -- so the same command (and the same key) both opens and
dismisses it. Otherwise display it.

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
  (let ((window (corral--panel-window)))
    (if window
        (delete-window window)
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
          (set-window-dedicated-p window t))))))

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

(defun corral-refresh-panel ()
  "Redraw the corral panel from current session state.
Bound to `g' in the panel -- the usual Emacs refresh key. Separate
from `corral-show-panel', which now toggles the window open/closed, so
pressing `g' inside the panel redraws it instead of dismissing it."
  (interactive)
  (corral--refresh-panel))

(define-key corral-panel-mode-map (kbd "g") #'corral-refresh-panel)
(define-key corral-panel-mode-map (kbd "r") #'corral-rename-session)
(define-key corral-panel-mode-map (kbd "RET") #'corral-switch-to-session)

(provide 'corral-panel)
;;; corral-panel.el ends here
