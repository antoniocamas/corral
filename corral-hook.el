;;; corral-hook.el --- generic hook-strategy plumbing -*- lexical-binding: t; -*-

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

;; Everything shared by every hook-capable harness: the entry point a
;; hook script calls back into (`corral-report'), and a confirm-diff
;; helper for the harness-specific config-file installers to use
;; instead of writing silently.

;;; Code:

(require 'diff)
(require 'corral-core)

;;;###autoload
(defun corral-report (pane-id state)
  "Report STATE (a string: \"working\"/\"waiting\"/\"idle\") for
PANE-ID. Called via `emacsclient --eval' from a hook script (see
corral-hook.sh) -- this is the one thing every hook-capable harness's
hook script needs to know how to call."
  (let ((sym (pcase state
               ("working" 'working)
               ("waiting" 'waiting)
               ("idle" 'idle)
               (_ 'unknown))))
    (corral--set-state pane-id sym)
    (when (eq sym 'waiting)
      (corral--notify-attention pane-id)))
  nil)

(defun corral-hook-confirm-and-write (path new-content)
  "Show a diff between PATH's current contents and NEW-CONTENT, and
ask for confirmation before overwriting PATH with NEW-CONTENT.

Always makes a timestamped backup of the existing file first if it
already exists -- even though confirmation already happened, this
edits a real, hand-maintained config file, so belt and suspenders.

Everything here runs with `coding-system-for-write'/`coding-system-for-read'
forced to UTF-8, since we already know settings.json content is valid
UTF-8 (it round-tripped through `json-serialize'). Left to negotiate
automatically, Emacs can decide it isn't sure a coding system safely
represents every character (this actually happened: an emoji already
present in an unrelated existing hook command triggered it) and pop
an *interactive* coding-system prompt -- which hangs forever when
nothing is present to answer it. That happens not just for our own
final write but also inside `diff-no-select', which writes its two
buffers out to its own temp files to hand to the external `diff'
binary -- so the binding has to cover the whole function, not just
our own explicit write at the end."
  (let ((coding-system-for-write 'utf-8)
        (coding-system-for-read 'utf-8))
    (let ((old-content (if (file-exists-p path)
                           (with-temp-buffer
                             (insert-file-contents path)
                             (buffer-string))
                         "")))
      (if (equal old-content new-content)
          (message "corral: %s already up to date, nothing to do" path)
        (let ((old-buf (generate-new-buffer " *corral-hook-old*"))
              (new-buf (generate-new-buffer " *corral-hook-new*")))
          (unwind-protect
              (progn
                (with-current-buffer old-buf (insert old-content))
                (with-current-buffer new-buf (insert new-content))
                (let ((diff-buf (diff-no-select old-buf new-buf nil 'noasync)))
                  (display-buffer diff-buf)
                  (if (yes-or-no-p (format "Write these hook changes to %s? " path))
                      (progn
                        (when (file-exists-p path)
                          (copy-file path
                                     (concat path ".corral-backup-"
                                             (format-time-string "%Y%m%d%H%M%S"))
                                     nil))
                        (with-temp-file path (insert new-content))
                        (message "corral: updated %s" path))
                    (message "corral: left %s unchanged" path))))
            (kill-buffer old-buf)
            (kill-buffer new-buf)))))))

(provide 'corral-hook)
;;; corral-hook.el ends here
