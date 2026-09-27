;;; corral-claude-tests.el --- ERT tests for corral-claude.el -*- lexical-binding: t; -*-

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

;; Run interactively with M-x ert, or in batch:
;;   emacs -batch -L .. -l corral-claude-tests.el -f ert-run-tests-batch-and-exit
;;
;; Covers the settings.json merge logic (`corral-claude--merge-hooks')
;; as pure-function tests, plus one end-to-end test through
;; `corral-claude-install-hooks' itself against a real temp file
;; (confirmation/diff display stubbed, since those are interactive).
;;
;; The emoji round-trip test locks down a real regression hit during
;; development: `json-serialize' returns already-encoded raw UTF-8
;; bytes, not a normal decoded Emacs string. Writing that through a
;; coding system without decoding it first double-encodes any
;; non-ASCII content -- silently, with no error, corrupting it. This
;; surfaced via an emoji already present in an unrelated existing
;; hook command.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-claude)


;;; corral-claude--merge-hooks (pure function, no disk I/O)

(ert-deftest corral-claude-test-merge-adds-all-managed-events ()
  "A merge from scratch (no existing hooks) adds all 7 managed events."
  (let ((merged (corral-claude--merge-hooks nil)))
    (dolist (pair corral-claude--event-states)
      (let ((event (intern (concat ":" (car pair)))))
        (should (plist-member merged event))
        (should (= 1 (length (plist-get merged event))))))))

(ert-deftest corral-claude-test-session-start-maps-to-idle ()
  "SessionStart must map to `idle', not `working': right after a
session starts, Claude Code is sitting at its empty prompt waiting
for the first message, nothing is happening yet. A real bug: an
earlier version mapped it to `working', so every fresh session
appeared permanently busy until the first tool use."
  (should (equal (cdr (assoc "SessionStart" corral-claude--event-states)) "idle")))

(ert-deftest corral-claude-test-permission-request-maps-to-blocked ()
  "PermissionRequest reports `blocked', not `waiting': the state name
is specifically for \"blocked on you, can't proceed without your
decision\" -- deliberately not a generic word that could later be
confused with, say, waiting on a pending background task."
  (should (equal (cdr (assoc "PermissionRequest" corral-claude--event-states)) "blocked")))

(ert-deftest corral-claude-test-merge-preserves-unrelated-entries ()
  "Entries on a managed event that aren't corral's own are kept
alongside corral's, not replaced or dropped -- and entries on an
event corral doesn't manage at all (Notification) are untouched."
  (let* ((existing (list :Notification
                         (vector (list :matcher ""
                                       :hooks (vector (list :type "command"
                                                             :command "notify-send hi"))))
                         :PreToolUse
                         (vector (list :matcher "*"
                                       :hooks (vector (list :type "command"
                                                             :command "echo my-own-hook"))))))
         (merged (corral-claude--merge-hooks existing)))
    ;; Notification: corral doesn't manage this event at all.
    (should (equal (plist-get merged :Notification) (plist-get existing :Notification)))
    ;; PreToolUse: corral manages it, so the unrelated entry plus
    ;; corral's own new entry should both be present.
    (let ((entries (append (plist-get merged :PreToolUse) nil)))
      (should (= 2 (length entries)))
      (should (seq-some (lambda (e) (equal (plist-get (car (append (plist-get e :hooks) nil)) :command)
                                           "echo my-own-hook"))
                        entries))
      (should (seq-some #'corral-claude--entry-is-ours-p entries)))))

(ert-deftest corral-claude-test-merge-is-idempotent ()
  "Merging corral's own already-merged output again produces the same
result -- no accumulation of duplicate entries on repeated installs."
  (let* ((once (corral-claude--merge-hooks nil))
         (twice (corral-claude--merge-hooks once)))
    (should (equal once twice))))

(ert-deftest corral-claude-test-merge-replaces-corral-owned-entry-in-place ()
  "If corral's hook script path changes (e.g. reinstalled from a
different location), re-merging replaces the old corral-owned entry
rather than adding a second one alongside it."
  (let* ((first-install (corral-claude--merge-hooks nil))
         (second-install (cl-letf (((symbol-value 'corral-claude--hook-script) "/somewhere/else/corral-hook.sh"))
                            (corral-claude--merge-hooks first-install))))
    (dolist (pair corral-claude--event-states)
      (let* ((event (intern (concat ":" (car pair))))
             (entries (append (plist-get second-install event) nil)))
        (should (= 1 (length entries)))
        (should (string-prefix-p "/somewhere/else/corral-hook.sh"
                                 (plist-get (car (append (plist-get (car entries) :hooks) nil))
                                            :command)))))))


;;; corral--plist-set (pure function)

(ert-deftest corral-claude-test-plist-set-preserves-key-order ()
  "Setting an existing key's value keeps its original position rather
than moving it to the end -- so a settings.json diff only shows what
actually changed."
  (let* ((original (list :a 1 :b 2 :c 3))
         (updated (corral--plist-set original :b 99)))
    (should (equal updated (list :a 1 :b 99 :c 3)))))

(ert-deftest corral-claude-test-plist-set-appends-new-key ()
  (let* ((original (list :a 1))
         (updated (corral--plist-set original :hooks "x")))
    (should (equal updated (list :a 1 :hooks "x")))))


;;; The emoji double-encoding regression

(ert-deftest corral-claude-test-json-emoji-roundtrip ()
  "`json-serialize' returns raw encoded UTF-8 bytes, not a decoded
Emacs string -- `decode-coding-string' must be applied before that
value is compared, diffed, or written anywhere, or non-ASCII content
silently corrupts (each byte gets re-encoded as if it were its own
codepoint)."
  (let* ((emoji "🤖")
         (existing (list :hooks (list :Notification
                                      (vector (list :matcher ""
                                                    :hooks (vector (list :type "command"
                                                                         :command (format "notify-send '%s'" emoji))))))))
         (encoded (json-serialize existing))
         (correctly-decoded (decode-coding-string encoded 'utf-8)))
    ;; The bug: comparing/writing ENCODED directly loses round-trip
    ;; fidelity -- re-parsing it back does NOT reproduce the original
    ;; emoji as one character.
    (let ((reparsed-from-encoded
           (json-parse-string encoded :object-type 'plist :array-type 'array)))
      (should-not
       (equal emoji
              (plist-get (car (append (plist-get
                                        (car (append (plist-get (plist-get reparsed-from-encoded :hooks) :Notification) nil))
                                        :hooks)
                                       nil))
                         :command))))
    ;; The fix: decoding first round-trips correctly.
    (let ((reparsed-from-decoded
           (json-parse-string correctly-decoded :object-type 'plist :array-type 'array)))
      (should
       (string-match-p
        (regexp-quote emoji)
        (plist-get (car (append (plist-get
                                  (car (append (plist-get (plist-get reparsed-from-decoded :hooks) :Notification) nil))
                                  :hooks)
                                 nil))
                   :command))))))


;;; End-to-end: corral-claude-install-hooks against a real temp file

(ert-deftest corral-claude-test-install-hooks-end-to-end ()
  "The full installer, run twice against a real file containing an
emoji in an unrelated existing hook: first run writes correctly
(emoji intact, unrelated hook preserved), second run is idempotent
and doesn't even ask for confirmation."
  (let ((path (make-temp-file "corral-claude-test-" nil ".json"))
        (confirm-calls 0))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "{\"hooks\":{\"Notification\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"notify-send '🤖'\"}]}]},\"model\":\"sonnet\"}"))
          (let ((corral-claude-settings-path path))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) (cl-incf confirm-calls) t))
                      ((symbol-function 'display-buffer) (lambda (&rest _) nil)))
              (corral-claude-install-hooks))
            (let ((written (with-temp-buffer (insert-file-contents path) (buffer-string))))
              (should (string-match-p "🤖" written))
              (should (string-match-p "sonnet" written))
              (dolist (pair corral-claude--event-states)
                (should (string-match-p (car pair) written))))
            (should (= confirm-calls 1))
            ;; Second run: idempotent, must not prompt again.
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) (error "should not be asked when nothing changed"))))
              (corral-claude-install-hooks))))
      (delete-file path)
      (dolist (backup (file-expand-wildcards (concat path ".corral-backup-*")))
        (delete-file backup)))))

(provide 'corral-claude-tests)
;;; corral-claude-tests.el ends here
