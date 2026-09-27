;;; corral-harness.el --- harness/variant registry and launch commands -*- lexical-binding: t; -*-

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

;; A harness describes DETECTION for one coding-agent tool (hooks vs.
;; screen-scraping) and nothing about how it's launched. A variant
;; describes one way to launch it: a plain command string, registered
;; separately (typically from the user's own config, e.g.
;; setup-corral.el) so personal wrapper scripts never need to touch
;; this package's own files. Each registered variant auto-generates
;; its own `corral-launch-<harness>[-<variant>]' command.
;;
;; Buffer naming always prompts for a suffix, pre-filled with a
;; computed default (the current project's root name via `project.el',
;; or the directory's basename otherwise) rather than fully
;; automating it -- a workspace root holding several sibling
;; repositories is a real, common case where automatic project
;; detection has nothing useful to suggest beyond that default, and
;; the user may want to override it either way.

;;; Code:

(require 'cl-lib)
(require 'corral-core)
(require 'corral-vterm)

(cl-defstruct corral-harness
  id            ; symbol, e.g. 'claude, 'antigravity
  abbrev        ; short display prefix for the panel, e.g. "cl" for claude
  strategy      ; 'hooks or 'scrape
  installer     ; hooks strategy: function to check/install hook config
  classifier    ; scrape strategy: function (tail-string -> state symbol)
  tail-chars)   ; scrape strategy: override `corral-vterm-tail-chars' if needed

(defvar corral--harnesses (make-hash-table :test 'eq)
  "Harness id -> `corral-harness' struct.")

(defvar corral--variants (make-hash-table :test 'equal)
  "(harness-id . variant-name) -> command string. VARIANT-NAME is nil
for a harness's default/unnamed variant.")

(defun corral-harness-register (harness)
  "Register HARNESS (a `corral-harness'), keyed by its `id'."
  (puthash (corral-harness-id harness) harness corral--harnesses))

(defun corral-harness-get (harness-id)
  (gethash harness-id corral--harnesses))

(defun corral--project-root-name (directory)
  "Suggested name for DIRECTORY: the current project's root directory
name via `project.el' if DIRECTORY is inside one, else DIRECTORY's
own basename."
  (require 'project nil t)
  (let* ((default-directory directory)
         (proj (and (fboundp 'project-current) (project-current))))
    (if proj
        (file-name-nondirectory
         (directory-file-name
          (cond
           ((fboundp 'project-root) (project-root proj))
           ((fboundp 'project-roots) (car (project-roots proj)))
           (t directory))))
      (file-name-nondirectory (directory-file-name directory)))))

(defun corral--launcher-name (harness-id variant-name)
  (intern (if variant-name
              (format "corral-launch-%s-%s" harness-id variant-name)
            (format "corral-launch-%s" harness-id))))

(defun corral--do-launch (harness-id variant-name command)
  "Prompt for a directory and a session name, then spawn and track a
new vterm session for HARNESS-ID/VARIANT-NAME, typing COMMAND into it."
  (let ((harness (corral-harness-get harness-id)))
    (unless harness
      (user-error "No harness registered for `%s'" harness-id))
    (let* ((dir (read-directory-name (format "Start %s in directory: " harness-id)
                                      default-directory))
           (suggestion (corral--project-root-name dir))
           (suffix (read-string (format "Session name suffix (default %s): " suggestion)
                                 nil nil suggestion))
           (base (if variant-name
                     (format "%s-%s-%s" harness-id variant-name suffix)
                   (format "%s-%s" harness-id suffix)))
           (buffer-name (generate-new-buffer-name (format "*%s*" base)))
           (pane-id (corral--new-pane-id))
           (server-name (corral--server-socket-name))
           (extra-env (list (cons "CORRAL_PANE_ID" pane-id)
                             (cons "CORRAL_SERVER_NAME" server-name)))
           (buffer (corral--vterm-spawn buffer-name dir extra-env)))
      (corral--register pane-id buffer harness-id variant-name suffix)
      ;; Genuinely idle at this instant: the shell just started, and
      ;; `command' hasn't even been typed into it yet (that happens
      ;; after a short deferred delay, in `corral--vterm-send-command')
      ;; -- setting `working' here would claim something is happening
      ;; before it actually is. The real SessionStart hook flips this
      ;; to `working' once the harness itself actually starts.
      (corral--set-state pane-id 'idle)
      (corral--vterm-send-command buffer command))))

(defun corral-harness-add-variant (harness-id variant-name command)
  "Register COMMAND (a plain shell command string, may include flags)
as a launchable variant of HARNESS-ID, and define the interactive
command `corral-launch-<harness-id>[-<variant-name>]' for it.

Call this from your own configuration (e.g. a setup-corral.el you
load from init), not from a harness's own defining file -- which
wrapper scripts/flags you personally use is not this package's
concern."
  (puthash (cons harness-id variant-name) command corral--variants)
  (let ((name (corral--launcher-name harness-id variant-name)))
    (defalias name
      (lambda ()
        (interactive)
        (corral--do-launch harness-id variant-name command))
      (format "Launch a %s session%s, tracked in the corral panel.
Prompts for a directory and a session name (see `corral--do-launch')."
              harness-id (if variant-name (format " (variant %s)" variant-name) "")))))

(provide 'corral-harness)
;;; corral-harness.el ends here
