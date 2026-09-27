;;; corral-antigravity-tests.el --- ERT tests for corral-antigravity.el -*- lexical-binding: t; -*-

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

;; Sample strings here are the exact real captures made during the
;; original PoC (`../emacs-herd/herd-scrape.el'), reused verbatim as
;; fixtures rather than invented -- only the `waiting' -> `blocked'
;; expectation changed, to match corral's own state vocabulary.

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-antigravity)

(defconst corral-antigravity-test--confirmation-sample
  "Requesting permission for:
   sleep 10

Run this command?
> 1. Yes, run command
  2. No, cancel

  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
✦ 3.7 Flash (Medium)  Ctx: 1.9% (20k/1.0M) ...  [WORKING...]"
  "Real captured confirmation-dialog overlay text. Note the status-bar
tag still says [WORKING...] while this is up -- the classifier must
check the confirmation text first, not the tag.")

(ert-deftest corral-antigravity-test-confirmation-dialog-is-blocked ()
  "A tool-confirmation dialog classifies as `blocked', even though the
status-bar tag on the same screen still says [WORKING...]."
  (should (eq (corral-antigravity--classify corral-antigravity-test--confirmation-sample)
              'blocked)))

(ert-deftest corral-antigravity-test-working-tag ()
  (should (eq (corral-antigravity--classify "✦ 3.7 Flash (Medium)  [WORKING...]")
              'working))
  (should (eq (corral-antigravity--classify "✦ 3.7 Flash (Medium)  [USING TOOLS]")
              'working)))

(ert-deftest corral-antigravity-test-idle-tag ()
  (should (eq (corral-antigravity--classify "✦ 3.7 Flash (Medium)  [IDLE]")
              'idle)))

(ert-deftest corral-antigravity-test-unmatched-text-falls-back-to-idle ()
  (should (eq (corral-antigravity--classify "some unrelated screen text")
              'idle)))

(ert-deftest corral-antigravity-test-harness-registered-as-scrape-strategy ()
  (let ((harness (corral-harness-get 'antigravity)))
    (should harness)
    (should (eq (corral-harness-strategy harness) 'scrape))
    (should (eq (corral-harness-classifier harness) #'corral-antigravity--classify))))

(provide 'corral-antigravity-tests)
;;; corral-antigravity-tests.el ends here
