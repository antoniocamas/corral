;;; corral-harness-tests.el --- ERT tests for corral-harness.el -*- lexical-binding: t; -*-

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

;; Covers the launch dispatcher (`corral-launch') and the
;; auto-generated prefix keymap (`corral-launch-map'): keys are built
;; from the registered harnesses rather than hardcoded, `l' is reserved
;; for the dispatcher, first-letter clashes between harnesses fall back
;; to another free letter, and the dispatcher offers every registered
;; variant (vanilla and named).

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-harness)

(defmacro corral-harness-test--with-clean-registry (&rest body)
  "Run BODY against empty harness/variant registries, restored after.
`reg' registers a bare scrape harness by id; `var' registers a variant
\(nil for vanilla), which also defines its launcher and rebuilds the
launch map, exactly as in production."
  (declare (indent 0))
  `(let ((corral--harnesses (make-hash-table :test 'eq))
         (corral--variants (make-hash-table :test 'equal))
         (corral-launch-map (make-sparse-keymap)))
     (cl-flet ((reg (id)
                 (corral-harness-register
                  (make-corral-harness :id id :abbrev (symbol-name id)
                                       :strategy 'scrape :classifier #'ignore)))
               (var (id name command)
                 (corral-harness-add-variant id name command)))
       ,@body)))

(defun corral-harness-test--map-alist ()
  "Launch map as an alist of (KEY-STRING . COMMAND)."
  (let (out)
    (map-keymap (lambda (ev def) (push (cons (key-description (vector ev)) def) out))
                corral-launch-map)
    out))

(ert-deftest corral-harness-test-launch-map-binds-vanilla-per-harness ()
  "Each harness gets its first letter bound to its vanilla launcher,
and `l' is the dispatcher."
  (corral-harness-test--with-clean-registry
    (reg 'claude) (var 'claude nil "claude")
    (reg 'kiro)   (var 'kiro nil "kiro-cli chat")
    (let ((alist (corral-harness-test--map-alist)))
      (should (eq (cdr (assoc "c" alist)) 'corral-launch-claude))
      (should (eq (cdr (assoc "k" alist)) 'corral-launch-kiro))
      (should (eq (cdr (assoc "l" alist)) 'corral-launch)))))

(ert-deftest corral-harness-test-launch-map-reserves-l-for-dispatcher ()
  "A harness whose name starts with `l' does NOT steal `l' from the
dispatcher -- it falls back to another letter."
  (corral-harness-test--with-clean-registry
    (reg 'llama) (var 'llama nil "llama")
    (let ((alist (corral-harness-test--map-alist)))
      ;; `l' stays the dispatcher.
      (should (eq (cdr (assoc "l" alist)) 'corral-launch))
      ;; llama is bound somewhere else (next free letter of its name: a).
      (should (rassq 'corral-launch-llama alist))
      (should-not (eq (cdr (assoc "l" alist)) 'corral-launch-llama)))))

(ert-deftest corral-harness-test-launch-map-first-letter-collision-fallback ()
  "Two harnesses sharing a first letter both get a key -- the second
falls back to a later letter of its own name, so neither is dropped."
  (corral-harness-test--with-clean-registry
    (reg 'claude) (var 'claude nil "claude")
    (reg 'codex)  (var 'codex nil "codex")
    (let ((alist (corral-harness-test--map-alist)))
      (should (rassq 'corral-launch-claude alist))
      (should (rassq 'corral-launch-codex alist))
      ;; Distinct keys.
      (let ((kc (car (rassq 'corral-launch-claude alist)))
            (kx (car (rassq 'corral-launch-codex alist))))
        (should-not (equal kc kx))))))

(ert-deftest corral-harness-test-launch-candidates-include-vanilla-and-named ()
  "`corral--launch-candidates' offers every registered variant, labeled
`harness' for vanilla and `harness-variant' for named, sorted."
  (corral-harness-test--with-clean-registry
    (reg 'claude) (var 'claude nil "claude")
    (var 'claude "zai" "claude-zai")
    (reg 'kiro) (var 'kiro "mcp" "k-mcp")
    (should (equal (mapcar #'car (corral--launch-candidates))
                   '("claude" "claude-zai" "kiro-mcp")))))

(ert-deftest corral-harness-test-launch-errors-with-no-variants ()
  "`corral-launch' with nothing registered is a `user-error'."
  (corral-harness-test--with-clean-registry
    (should-error (corral-launch) :type 'user-error)))

(provide 'corral-harness-tests)
;;; corral-harness-tests.el ends here
