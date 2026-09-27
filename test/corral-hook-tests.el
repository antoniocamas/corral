;;; corral-hook-tests.el --- ERT tests for corral-hook.el -*- lexical-binding: t; -*-

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
;;   emacs -batch -L .. -l corral-hook-tests.el -f ert-run-tests-batch-and-exit
;;
;; Covers `corral-hook-json-pretty', added after a real complaint: the
;; original `json-serialize'-based output was always compact,
;; single-line JSON, making the confirmation diff unreadable against a
;; normally-indented, hand-maintained settings file.

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-hook)

(ert-deftest corral-hook-test-json-pretty-is-indented ()
  "Nested objects/arrays produce one entry per line, 2-space indented
per level -- not `json-serialize''s compact single-line output."
  (let* ((value (list :a 1 :b (vector (list :c "x"))))
         (pretty (corral-hook-json-pretty value)))
    (should (string-match-p "\n" pretty))
    (should (string-match-p "^{\n  \"a\": 1,\n  \"b\": \\[\n    {\n      \"c\": \"x\"\n    }\n  \\]\n}\n\\'" pretty))))

(ert-deftest corral-hook-test-json-pretty-preserves-key-order ()
  (let* ((value (list :z 1 :a 2 :m 3))
         (pretty (corral-hook-json-pretty value)))
    (should (< (string-match "\"z\"" pretty) (string-match "\"a\"" pretty)))
    (should (< (string-match "\"a\"" pretty) (string-match "\"m\"" pretty)))))

(ert-deftest corral-hook-test-json-pretty-empty-containers ()
  (should (equal (corral-hook-json-pretty (list :a (vector))) "{\n  \"a\": []\n}\n"))
  (should (equal (corral-hook--json-pretty-object nil 0) "{}")))

(ert-deftest corral-hook-test-json-pretty-booleans-and-null ()
  (let ((pretty (corral-hook-json-pretty (list :yes t :no :false :nothing nil))))
    (should (string-match-p "\"yes\": true" pretty))
    (should (string-match-p "\"no\": false" pretty))
    (should (string-match-p "\"nothing\": null" pretty))))

(ert-deftest corral-hook-test-json-pretty-escapes-control-chars-not-unicode ()
  "Control characters, quotes, and backslashes are escaped; anything
else -- including a non-ASCII emoji -- is emitted literally, not as a
\\uXXXX escape, since this output is meant to stay readable to a
human, matching how such characters already look in a hand-edited
settings.json."
  (let ((pretty (corral-hook-json-pretty (list :msg "line1\nline2\t\"quoted\"\\backslash 🤖"))))
    (should (string-match-p "\\\\n" pretty))
    (should (string-match-p "\\\\t" pretty))
    (should (string-match-p "\\\\\"quoted\\\\\"" pretty))
    (should (string-match-p "\\\\\\\\backslash" pretty))
    (should (string-match-p "🤖" pretty))
    (should-not (string-match-p "\\\\u" pretty))))

(ert-deftest corral-hook-test-json-pretty-roundtrip-is-stable ()
  "Parsing pretty-printed output and pretty-printing it again produces
byte-identical text -- the fixed point a confirmed install should
settle into, so a second run is a true no-op."
  (let* ((original (list :hooks (list :Notification
                                      (vector (list :matcher ""
                                                    :hooks (vector (list :type "command"
                                                                         :command "notify-send '🤖'")))))
                        :model "sonnet"))
         (once (corral-hook-json-pretty original))
         (reparsed (json-parse-string once :object-type 'plist :array-type 'array))
         (twice (corral-hook-json-pretty reparsed)))
    (should (equal once twice))))

(provide 'corral-hook-tests)
;;; corral-hook-tests.el ends here
