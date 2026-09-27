;;; corral-vterm.el --- vterm integration glue -*- lexical-binding: t; -*-

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

;; Everything that actually touches a vterm buffer: spawning one with
;; a given name/directory/environment, sending a command into it, and
;; reading its tail for screen-scraping detection.  Kept separate so
;; neither the harness/launch logic nor any scrape-strategy harness
;; needs to know vterm's API directly.

;;; Code:

(require 'corral-core)
(require 'vterm nil t)
(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm-send-string "vterm" (string &optional paste-p))

(defcustom corral-vterm-tail-chars 20000
  "How many trailing characters of a tracked buffer to scan for
screen-scraping detection.

Deliberately a character budget, not a line count: a full-screen TUI
agent can pad unused rows below its real content with blank lines,
and on a tall vterm window there can be far more of those than a
fixed line-count tail would cover -- observed directly during the
corral PoC, where a 40-line tail missed a status-bar line sitting
above 80 lines of blank padding. Blank lines cost about 1 byte each,
so a generous character budget still reaches back through a lot of
padding to the real content."
  :type 'integer
  :group 'corral)

(defun corral-vterm-available-p ()
  (featurep 'vterm))

(defun corral--vterm-spawn (buffer-name directory extra-env)
  "Create a new vterm buffer named BUFFER-NAME in DIRECTORY.
EXTRA-ENV is an alist of (NAME . VALUE) strings added to
`process-environment' for the spawned shell, in addition to
whatever's already inherited. Returns the new buffer."
  (unless (corral-vterm-available-p)
    (user-error "vterm is not available"))
  (let* ((default-directory directory)
         (process-environment
          (append (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair))) extra-env)
                  process-environment)))
    (vterm buffer-name)
    (current-buffer)))

(defun corral--vterm-send-command (buffer command)
  "Type COMMAND followed by RET into BUFFER, once it exists.
Deferred slightly so the shell has started before we type into it."
  (run-at-time
   0.3 nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (vterm-send-string command)
         (vterm-send-string "\n"))))))

(defun corral--buffer-tail (buffer &optional chars)
  "Return the last CHARS characters (default `corral-vterm-tail-chars')
of BUFFER's text, or nil if BUFFER isn't live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((end (point-max))
             (start (max (point-min) (- end (or chars corral-vterm-tail-chars)))))
        (buffer-substring-no-properties start end)))))

(provide 'corral-vterm)
;;; corral-vterm.el ends here
