;;; corral-core-tests.el --- ERT tests for corral-core.el -*- lexical-binding: t; -*-

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

;; Covers `corral-recover-sessions': `corral-reload-from-source' wipes
;; `corral--sessions' (an `unload-feature' effect, verified directly --
;; it also clears every buffer-local variable defined by a reloaded
;; file, including the pane-id one) while leaving already-running vterm
;; processes untouched. Recovery therefore has to identify a session
;; from something that survives `unload-feature': a real process's
;; property list, not any Lisp variable. These tests use a real,
;; trivial subprocess (`sleep') as a stand-in for a vterm-backed
;; process, since `process-get'/`process-put' require an actual
;; process object.

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-core)

(defmacro corral-core-test--with-fake-session (buffer-var proc-var &rest body)
  "Bind BUFFER-VAR/PROC-VAR to a fresh buffer and a real, trivial
subprocess attached to it, run BODY, then always kill both."
  (declare (indent 2))
  `(let* ((,buffer-var (generate-new-buffer " *corral-core-test*"))
          (,proc-var (start-process "corral-core-test" ,buffer-var "sleep" "5")))
     ;; Without this, killing a buffer with a live process (the
     ;; dead-buffer test below does exactly that) pops an interactive
     ;; "still running; kill it?" `yes-or-no-p' via
     ;; `process-kill-buffer-query-function' -- fatal in batch ERT,
     ;; where nothing is present to answer it.
     (set-process-query-on-exit-flag ,proc-var nil)
     (unwind-protect
         (progn ,@body)
       (when (process-live-p ,proc-var) (delete-process ,proc-var))
       (when (buffer-live-p ,buffer-var) (kill-buffer ,buffer-var)))))

(ert-deftest corral-core-test-register-stashes-identity-on-process ()
  "`corral--register' stashes pane-id/harness/variant/suffix as
properties on the buffer's process, not just in `corral--sessions'."
  (corral-core-test--with-fake-session buffer proc
    (corral--register "pane-x" buffer 'claude "zai" "myproj")
    (should (equal (process-get proc 'corral-pane-id) "pane-x"))
    (should (eq (process-get proc 'corral-harness) 'claude))
    (should (equal (process-get proc 'corral-variant) "zai"))
    (should (equal (process-get proc 'corral-suffix) "myproj"))))

(ert-deftest corral-core-test-recover-sessions-restores-wiped-entry ()
  "A session whose `corral--sessions' entry is gone (simulating what
`unload-feature' does) but whose process still carries corral's
identity properties is reconstructed by `corral-recover-sessions',
with the same pane-id, harness, variant and suffix."
  (corral-core-test--with-fake-session buffer proc
    (corral--register "pane-y" buffer 'claude "orig" "widgets")
    ;; Simulate the reload wipe: the registry entry and the buffer-local
    ;; pane-id are gone, but the process (and its properties) survive.
    (remhash "pane-y" corral--sessions)
    (with-current-buffer buffer (kill-local-variable 'corral--pane-id))
    (corral-recover-sessions)
    (let ((session (gethash "pane-y" corral--sessions)))
      (should session)
      (should (eq (plist-get session :buffer) buffer))
      (should (eq (plist-get session :harness) 'claude))
      (should (equal (plist-get session :variant) "orig"))
      (should (equal (plist-get session :suffix) "widgets"))
      (should (eq (plist-get session :state) 'unknown)))))

(ert-deftest corral-core-test-recover-sessions-skips-already-tracked ()
  "A session still present in `corral--sessions' is left alone --
recovery doesn't clobber its current state back to `unknown'."
  (corral-core-test--with-fake-session buffer proc
    (corral--register "pane-z" buffer 'claude nil "already-tracked")
    (corral--set-state "pane-z" 'working)
    (corral-recover-sessions)
    (should (eq (plist-get (gethash "pane-z" corral--sessions) :state) 'working))))

(ert-deftest corral-core-test-recover-sessions-ignores-processes-without-identity ()
  "A live process with no corral properties at all (never registered)
is not mistaken for a corral session."
  (corral-core-test--with-fake-session buffer proc
    (let ((before (hash-table-count corral--sessions)))
      (corral-recover-sessions)
      (should (= (hash-table-count corral--sessions) before)))))

(ert-deftest corral-core-test-recover-sessions-ignores-dead-buffer ()
  "A process whose buffer was killed (the underlying session is really
gone, not just untracked) is not resurrected into a phantom entry."
  (corral-core-test--with-fake-session buffer proc
    (corral--register "pane-dead" buffer 'claude nil "gone")
    (remhash "pane-dead" corral--sessions)
    (kill-buffer buffer)
    (corral-recover-sessions)
    (should-not (gethash "pane-dead" corral--sessions))))

(ert-deftest corral-core-test-new-pane-id-is-unique-per-call ()
  "`corral--new-pane-id' hands out a different id each call."
  (let ((corral--pane-counter 0))
    (let ((a (corral--new-pane-id))
          (b (corral--new-pane-id)))
      (should-not (equal a b)))))

(ert-deftest corral-core-test-new-pane-id-skips-registered-ids ()
  "`corral--new-pane-id' never returns an id already in
`corral--sessions', even when the counter has been reset back under
live sessions -- the `corral-reload-from-source' case, where the
counter re-initialises to 0 while `corral-recover-sessions' has
re-registered survivors under their original higher-numbered ids. A
bare increment would re-mint a live id and `corral--register' would
silently overwrite that session (a freshly launched session replacing
an earlier one in the panel)."
  (corral-core-test--with-fake-session buffer _proc
    (clrhash corral--sessions)
    (setq corral--pane-counter 0)
    ;; Three pre-existing sessions holding ids ...-1, ...-2, ...-3.
    (let ((id1 (corral--new-pane-id)))
      (corral--register id1 buffer 'kiro nil "s1"))
    (let ((id2 (corral--new-pane-id)))
      (corral--register id2 buffer 'kiro nil "s2"))
    (let ((id3 (corral--new-pane-id)))
      (corral--register id3 buffer 'kiro nil "s3"))
    (should (= (hash-table-count corral--sessions) 3))
    ;; Reload resets the counter while the three survive.
    (setq corral--pane-counter 0)
    ;; The next id must dodge all three, not collide with them.
    (let ((id4 (corral--new-pane-id)))
      (should-not (gethash id4 corral--sessions))
      (corral--register id4 buffer 'kiro nil "s4")
      (should (= (hash-table-count corral--sessions) 4)))))

(ert-deftest corral-core-test-recover-sessions-renumbers-colliding-stashed-id ()
  "Two live processes carrying the SAME stashed pane-id (a duplicate
baked into two shells by a pre-fix launch after a counter reset) must
recover as TWO sessions, not one clobbering the other. The colliding
process gets a fresh id via `corral--new-pane-id', restashed on it."
  (let ((b1 (generate-new-buffer " *corral-core-test-1*"))
        (b2 (generate-new-buffer " *corral-core-test-2*")))
    (let ((p1 (start-process "corral-core-test-1" b1 "sleep" "5"))
          (p2 (start-process "corral-core-test-2" b2 "sleep" "5")))
      (set-process-query-on-exit-flag p1 nil)
      (set-process-query-on-exit-flag p2 nil)
      (unwind-protect
          (progn
            (clrhash corral--sessions)
            (dolist (p (list p1 p2))
              (process-put p 'corral-pane-id "corral-dup-1")
              (process-put p 'corral-harness 'claude)
              (process-put p 'corral-variant nil))
            (process-put p1 'corral-suffix "first")
            (process-put p2 'corral-suffix "second")
            (corral-recover-sessions)
            ;; Both survive.
            (should (= (hash-table-count corral--sessions) 2))
            ;; The two buffers now carry DIFFERENT stashed ids.
            (should-not (equal (process-get p1 'corral-pane-id)
                               (process-get p2 'corral-pane-id)))
            ;; Every session points at a distinct live buffer.
            (let (buffers)
              (maphash (lambda (_id s) (push (plist-get s :buffer) buffers)) corral--sessions)
              (should (= (length (delete-dups (copy-sequence buffers))) 2))))
        (dolist (p (list p1 p2)) (when (process-live-p p) (delete-process p)))
        (dolist (b (list b1 b2)) (when (buffer-live-p b) (kill-buffer b)))))))

(provide 'corral-core-tests)
;;; corral-core-tests.el ends here
