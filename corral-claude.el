;;; corral-claude.el --- Claude Code harness (hook strategy) -*- lexical-binding: t; -*-

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

;; Claude Code's own hooks (SessionStart, UserPromptSubmit,
;; PreToolUse, PostToolUse, PermissionRequest, Stop, SessionEnd) map
;; onto working/blocked/idle. `corral-claude-install-hooks' merges
;; corral's own entries into settings.json, touching only the events
;; it manages and only the entries whose command points at corral's
;; own hook script -- any other hooks already in those events (or any
;; other settings key) are left alone.
;;
;; This file only defines the vanilla "claude" launch variant.
;; Personal wrapper variants (an API-key wrapper, --dangerously-skip-permissions,
;; whatever else) belong in your own config, e.g.:
;;
;;   (corral-harness-add-variant 'claude "orig" "claude-orig --dangerously-skip-permissions")

;;; Code:

(require 'corral-core)
(require 'corral-harness)
(require 'corral-hook)

(defconst corral-claude--hook-script
  (expand-file-name "corral-hook.sh"
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory)))
  "Path to the generic hook script, resolved relative to this file's
own location so it works regardless of where corral is installed.")

(defcustom corral-claude-settings-path (expand-file-name "~/.claude/settings.json")
  "Path to the Claude Code settings.json to install corral's hooks
into. Point this at a project's .claude/settings.json instead if you
want corral's hooks scoped to one project rather than installed
globally."
  :type 'file
  :group 'corral)

(defconst corral-claude--event-states
  '(("SessionStart" . "idle")
    ("UserPromptSubmit" . "working")
    ("PreToolUse" . "working")
    ("PostToolUse" . "working")
    ("PermissionRequest" . "blocked")
    ("Stop" . "idle")
    ("SessionEnd" . "idle"))
  "Claude Code hook event name -> corral state it should report.

SessionStart maps to `idle', not `working': right after a session
starts, Claude Code is sitting at its empty prompt waiting for the
first message, not doing anything yet. Confirmed against herdr's own
real mapping (herdr/src/integration/claude_settings.rs's
HOOK_REMOVALS) after a real bug report: an earlier version of this
table had it wrong as `working', which made every fresh session
appear permanently busy until the first tool use, never showing as
idle while actually just sitting at that initial prompt.")

(defun corral-claude--command-for (state)
  (format "%s %s" corral-claude--hook-script state))

;; JSON objects here are PLISTS (keyword keys) and JSON arrays are
;; VECTORS -- both required by `json-serialize', which (verified
;; directly, not assumed) rejects alists and plain lists for either
;; role. Parsing therefore uses matching :object-type/:array-type
;; options so structures round-trip symmetrically.

(defun corral-claude--entry-is-ours-p (entry)
  "ENTRY is one element of an event's hook array: a plist with a
:hooks key holding a vector of {:type, :command} plists. True if any
of its commands invokes corral's own hook script, regardless of
which state it was reporting -- that's how a previous install of
corral's own entry for this event is recognized and replaced.

Matches on the script's basename, not its full path: corral might be
reinstalled to a different directory between installs (package-vc
relocation, moving the checkout, etc.), and a full-path match would
then fail to recognize a previous install's own entries, leaving them
as orphaned stale entries instead of being replaced."
  (let ((hooks (plist-get entry :hooks))
        (script-name (file-name-nondirectory corral-claude--hook-script)))
    (seq-some (lambda (h)
                (let ((cmd (plist-get h :command)))
                  (and (stringp cmd) (string-match-p (regexp-quote script-name) cmd))))
              hooks)))

(defun corral-claude--desired-entry (state)
  (list :matcher "*"
        :hooks (vector (list :type "command"
                              :command (corral-claude--command-for state)))))

(defun corral--plist-set (plist key value)
  "New plist like PLIST but with KEY set to VALUE, preserving existing
key order (KEY appended at the end if not already present) -- so a
settings.json diff only shows what corral actually changed, not a
reordering of unrelated keys."
  (if (plist-member plist key)
      (let ((copy (copy-sequence plist)))
        (plist-put copy key value)
        copy)
    (append plist (list key value))))

(defun corral-claude--merge-hooks (existing-hooks)
  "EXISTING-HOOKS is the parsed plist value of settings.json's
\"hooks\" key (or nil if there wasn't one), each event's value a
vector of entry-plists. Returns a new plist: for each event corral
manages, any previous corral-owned entry is dropped and corral's
current desired entry is appended -- any other, non-corral entries
already on that event (or any other event entirely) are left
untouched."
  (let ((hooks existing-hooks))
    (dolist (pair corral-claude--event-states)
      (let* ((event (intern (concat ":" (car pair))))
             (state (cdr pair))
             (current (append (plist-get hooks event) nil)) ; vector -> list, for seq-remove
             (kept (seq-remove #'corral-claude--entry-is-ours-p current))
             (updated (vconcat kept (vector (corral-claude--desired-entry state)))))
        (setq hooks (corral--plist-set hooks event updated))))
    hooks))

;;;###autoload
(defun corral-claude-install-hooks ()
  "Check/install corral's hooks into `corral-claude-settings-path'.
Shows a diff and asks for confirmation before writing anything (see
`corral-hook-confirm-and-write')."
  (interactive)
  (let* ((path corral-claude-settings-path)
         (existing (if (file-exists-p path)
                       (json-parse-string
                        (with-temp-buffer
                          (insert-file-contents path)
                          (buffer-string))
                        :object-type 'plist :array-type 'array :null-object nil)
                     nil))
         (merged-hooks (corral-claude--merge-hooks (plist-get existing :hooks)))
         (new-settings (corral--plist-set existing :hooks merged-hooks))
         ;; Pretty-printed, not `json-serialize' -- that always produces
         ;; compact, single-line JSON, which makes the confirmation
         ;; diff unreadable against a normally-indented, hand-maintained
         ;; settings file. See `corral-hook-json-pretty'.
         (new-content (corral-hook-json-pretty new-settings)))
    (corral-hook-confirm-and-write path new-content)))

(corral-harness-register
 (make-corral-harness :id 'claude
                       :abbrev "cl"
                       :strategy 'hooks
                       :installer #'corral-claude-install-hooks))

(corral-harness-add-variant 'claude nil "claude")

(provide 'corral-claude)
;;; corral-claude.el ends here
