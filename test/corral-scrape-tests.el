;;; corral-scrape-tests.el --- ERT tests for corral-scrape.el -*- lexical-binding: t; -*-

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

;; Exercises the generic tick/timer logic (state-change detection, the
;; attention notification on transition to `blocked', and starting/
;; stopping the shared timer via `corral-session-change-hook') against
;; a fake scrape-strategy harness and fake buffers -- no real timer
;; ever needs to fire, `corral-scrape--tick' is called directly, same
;; as the hook-strategy tests stub interactive functions rather than
;; waiting on real events.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-scrape)
(require 'corral-harness)

(defun corral-scrape-test--classifier (tail)
  (cond
   ((string-match-p "BLOCKED" tail) 'blocked)
   ((string-match-p "WORKING" tail) 'working)
   (t 'idle)))

(corral-harness-register
 (make-corral-harness :id 'corral-scrape-test-harness
                       :abbrev "cst"
                       :strategy 'scrape
                       :classifier #'corral-scrape-test--classifier))

(defmacro corral-scrape-test--with-clean-state (&rest body)
  "Run BODY with no leftover timer or sessions from a previous test,
and clean both up again afterward regardless of how BODY exits."
  `(progn
     (when corral-scrape--timer (cancel-timer corral-scrape--timer) (setq corral-scrape--timer nil))
     (clrhash corral--sessions)
     (unwind-protect (progn ,@body)
       (when corral-scrape--timer (cancel-timer corral-scrape--timer) (setq corral-scrape--timer nil))
       (clrhash corral--sessions))))

(ert-deftest corral-scrape-test-tick-detects-state-change ()
  "A tick classifies the tracked buffer's tail and updates the
session's state when it differs from what's already recorded."
  (corral-scrape-test--with-clean-state
   (let ((buffer (generate-new-buffer " *corral-scrape-test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer (insert "status: WORKING now"))
           (corral--register "test-pane-1" buffer 'corral-scrape-test-harness nil)
           (corral-scrape--tick)
           (should (eq (plist-get (gethash "test-pane-1" corral--sessions) :state) 'working)))
       (kill-buffer buffer)))))

(ert-deftest corral-scrape-test-tick-notifies-attention-on-blocked ()
  "Transitioning to `blocked' triggers `corral--notify-attention', the
same as a hook script reporting a blocked state would."
  (corral-scrape-test--with-clean-state
   (let ((buffer (generate-new-buffer " *corral-scrape-test*"))
         (notified nil))
     (unwind-protect
         (cl-letf (((symbol-function 'corral--notify-attention)
                    (lambda (pane-id) (setq notified pane-id))))
           (with-current-buffer buffer (insert "status: BLOCKED now"))
           (corral--register "test-pane-2" buffer 'corral-scrape-test-harness nil)
           (corral-scrape--tick)
           (should (equal notified "test-pane-2")))
       (kill-buffer buffer)))))

(ert-deftest corral-scrape-test-tick-does-not-notify-on-non-blocked-transition ()
  "Transitioning to `working' or `idle' must not trigger the attention
notification -- only `blocked' is urgent enough for that."
  (corral-scrape-test--with-clean-state
   (let ((buffer (generate-new-buffer " *corral-scrape-test*"))
         (notified nil))
     (unwind-protect
         (cl-letf (((symbol-function 'corral--notify-attention)
                    (lambda (pane-id) (setq notified pane-id))))
           (with-current-buffer buffer (insert "status: WORKING now"))
           (corral--register "test-pane-3" buffer 'corral-scrape-test-harness nil)
           (corral-scrape--tick)
           (should (null notified)))
       (kill-buffer buffer)))))

(ert-deftest corral-scrape-test-tick-ignores-non-scrape-harnesses ()
  "A registered session whose harness isn't scrape-strategy is left
alone by the tick -- `corral-scrape--scrape-sessions' must filter it
out."
  (corral-scrape-test--with-clean-state
   (corral-harness-register (make-corral-harness :id 'corral-scrape-test-hook-harness
                                                  :abbrev "csh"
                                                  :strategy 'hooks))
   (let ((buffer (generate-new-buffer " *corral-scrape-test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer (insert "status: WORKING now"))
           (corral--register "test-pane-4" buffer 'corral-scrape-test-hook-harness nil)
           (corral-scrape--tick)
           (should (eq (plist-get (gethash "test-pane-4" corral--sessions) :state) 'unknown)))
       (kill-buffer buffer)))))

(ert-deftest corral-scrape-test-sync-timer-starts-and-stops-with-sessions ()
  "The shared timer starts once a scrape-strategy session is registered
and stops again once none remain -- driven purely by
`corral-session-change-hook', not by explicit start/stop calls from
launch or kill-buffer code."
  (corral-scrape-test--with-clean-state
   (let ((buffer (generate-new-buffer " *corral-scrape-test*")))
     (should (null corral-scrape--timer))
     (corral--register "test-pane-5" buffer 'corral-scrape-test-harness nil)
     (should corral-scrape--timer)
     (kill-buffer buffer)
     (should (null corral-scrape--timer)))))

(ert-deftest corral-scrape-test-sync-timer-restarts-dead-timer ()
  "A dead timer left in `corral-scrape--timer' (cancelled, or disabled
by Emacs after its tick signalled) must be replaced by
`corral-scrape--sync-timer', not mistaken for a still-running one. The
old `(unless corral-scrape--timer ...)' guard checked only non-nil, so
a dead-but-non-nil timer wedged every scrape session forever -- the
panel kept showing them frozen no matter how often they were
relaunched or re-adopted."
  (corral-scrape-test--with-clean-state
   (let ((buffer (generate-new-buffer " *corral-scrape-test*")))
     (unwind-protect
         (progn
           (corral--register "test-pane-6" buffer 'corral-scrape-test-harness nil)
           (should (corral-scrape--timer-live-p))
           ;; Simulate the timer dying out from under the variable
           ;; (cancel it, but deliberately DON'T nil the variable --
           ;; exactly the state Emacs leaves after auto-disabling a
           ;; repeating timer whose function errored).
           (cancel-timer corral-scrape--timer)
           (should corral-scrape--timer)            ; variable still non-nil
           (should-not (corral-scrape--timer-live-p)) ; but timer is dead
           ;; A later sync (e.g. another session-change) must restart it.
           (corral-scrape--sync-timer)
           (should (corral-scrape--timer-live-p)))
       (when corral-scrape--timer
         (cancel-timer corral-scrape--timer) (setq corral-scrape--timer nil))
       (kill-buffer buffer)))))

(ert-deftest corral-scrape-test-tick-isolates-per-session-errors ()
  "An error scanning one session must not escape the tick (which would
make Emacs disable the shared timer for every session); the other
sessions in the same tick must still be classified."
  (corral-scrape-test--with-clean-state
   (let ((bad (generate-new-buffer " *corral-scrape-test-bad*"))
         (good (generate-new-buffer " *corral-scrape-test-good*")))
     (unwind-protect
         (cl-letf* ((real-classifier (symbol-function 'corral-scrape-test--classifier))
                    ((symbol-function 'corral-scrape-test--classifier)
                     (lambda (tail)
                       (if (string-match-p "EXPLODE" tail)
                           (error "boom")
                         (funcall real-classifier tail)))))
           (with-current-buffer bad (insert "EXPLODE"))
           (with-current-buffer good (insert "status: WORKING now"))
           (corral--register "test-pane-bad" bad 'corral-scrape-test-harness nil)
           (corral--register "test-pane-good" good 'corral-scrape-test-harness nil)
           ;; Must not signal despite the bad session erroring.
           (corral-scrape--tick)
           ;; The good session was still classified in the same tick.
           (should (eq (plist-get (gethash "test-pane-good" corral--sessions) :state)
                       'working)))
       (kill-buffer bad)
       (kill-buffer good)))))

(ert-deftest corral-scrape-test-wiring-invariants-hold-after-register ()
  "The system-level wiring the live probe checked, asserted here so it
can't silently regress: `corral-scrape--sync-timer' is actually on
`corral-session-change-hook' (the top-level `add-hook' at load time
ran), and registering a scrape session leaves a GENUINELY LIVE timer
\(in `timer-list'), not merely a non-nil variable. These are the
invariants that, when broken in a live session, froze the panel while
every unit test still passed."
  (corral-scrape-test--with-clean-state
   (let ((buffer (generate-new-buffer " *corral-scrape-test*")))
     (unwind-protect
         (progn
           (should (memq 'corral-scrape--sync-timer corral-session-change-hook))
           (corral--register "test-pane-7" buffer 'corral-scrape-test-harness nil)
           ;; A non-nil variable is not enough -- it must be scheduled.
           (should corral-scrape--timer)
           (should (corral-scrape--timer-live-p)))
       (kill-buffer buffer)))))

(provide 'corral-scrape-tests)
;;; corral-scrape-tests.el ends here
