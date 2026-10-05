;;; corral-panel-tests.el --- ERT tests for corral-panel.el -*- lexical-binding: t; -*-

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

;; Covers the panel's visible-marker gutter and focused-session
;; highlight (`corral--panel-render'). These need real windows actually
;; displaying the tracked buffers -- `get-buffer-window' and
;; `selected-window' are what the render reads -- so the tests build
;; genuine windows with `set-window-buffer' rather than stubbing. A
;; buffer with no window gets a blank gutter; one shown in any window
;; gets the marker; the buffer of the selected window additionally gets
;; the `corral-panel-focused' face on its label.

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".."
                               (file-name-directory
                                (or load-file-name buffer-file-name default-directory)))))
  (add-to-list 'load-path root))

(require 'corral-core)
(require 'corral-panel)

(defmacro corral-panel-test--with-sessions (&rest body)
  "Run BODY against an empty registry; `mk' makes a tracked,
subprocess-backed session buffer. Cleans up buffers/processes and
restores a single-window layout afterward."
  (declare (indent 0))
  `(let ((bufs nil) (procs nil))
     (clrhash corral--sessions)
     (unwind-protect
         (cl-flet ((mk (pane-id state)
                     (let* ((b (generate-new-buffer (format " *corral-panel-%s*" pane-id)))
                            (p (start-process (format "corral-panel-%s" pane-id) b "sleep" "30")))
                       (set-process-query-on-exit-flag p nil)
                       (push b bufs) (push p procs)
                       (corral--register pane-id b 'claude nil pane-id)
                       (corral--set-state pane-id state)
                       b)))
           ,@body)
       (delete-other-windows)
       (dolist (p procs) (when (process-live-p p) (delete-process p)))
       (dolist (b bufs) (when (buffer-live-p b) (kill-buffer b))))))

(defun corral-panel-test--render-string ()
  "Render the panel into a temporary buffer and return its text."
  (with-temp-buffer
    (corral-panel-mode)
    (corral--panel-render)
    (buffer-string)))

(defun corral-panel-test--line-for (text label)
  "Return the rendered line containing LABEL, from TEXT."
  (seq-find (lambda (l) (string-match-p (regexp-quote label) l))
            (split-string text "\n")))

(ert-deftest corral-panel-test-invisible-session-has-blank-gutter ()
  "A session whose buffer is in no window renders with a blank gutter,
not the visible marker."
  (corral-panel-test--with-sessions
    (let ((corral-panel-visible-marker ">"))
      (mk "p1" 'idle)
      ;; p1's buffer is not shown in any window.
      (let* ((text (corral-panel-test--render-string))
             (line (corral-panel-test--line-for text "claude-p1")))
        (should line)
        ;; Gutter is a space, not ">".
        (should (string-prefix-p "  " line))
        (should-not (string-prefix-p "> " line))))))

(ert-deftest corral-panel-test-visible-session-has-marker ()
  "A session whose buffer is shown in some window renders with the
visible marker in the gutter."
  (corral-panel-test--with-sessions
    (let ((corral-panel-visible-marker ">"))
      (let ((b (mk "p1" 'idle)))
        ;; Actually display it in a window.
        (set-window-buffer (selected-window) b)
        (let* ((text (corral-panel-test--render-string))
               (line (corral-panel-test--line-for text "claude-p1")))
          (should line)
          (should (string-prefix-p "> " line)))))))

(ert-deftest corral-panel-test-focused-session-label-has-face ()
  "The buffer in the SELECTED window gets the `corral-panel-focused'
face on its label; a merely-visible one does not."
  (corral-panel-test--with-sessions
    (let ((focused (mk "pf" 'working))
          (other (mk "po" 'idle)))
      ;; Two windows: `focused' in the selected one, `other' visible
      ;; but not selected.
      (delete-other-windows)
      (set-window-buffer (selected-window) focused)
      (let ((w2 (split-window)))
        (set-window-buffer w2 other)
        ;; selected-window still shows `focused'.
        (with-temp-buffer
          (corral-panel-mode)
          ;; Render reads `selected-window' -- which is NOT this temp
          ;; buffer's (temp buffers have no window), so compute focus
          ;; against the real selected window by rendering in place.
          (corral--panel-render)
          (let* ((text (buffer-string))
                 (fpos (string-match (regexp-quote "claude-pf") text))
                 (opos (string-match (regexp-quote "claude-po") text)))
            (should fpos)
            (should opos)
            ;; Focused label carries the face; the other does not.
            (should (eq (get-text-property fpos 'face text)
                        'corral-panel-focused))
            (should-not (eq (get-text-property opos 'face text)
                            'corral-panel-focused))))))))

(ert-deftest corral-panel-test-marker-is-configurable ()
  "`corral-panel-visible-marker' controls the gutter string."
  (corral-panel-test--with-sessions
    (let ((corral-panel-visible-marker "*"))
      (let ((b (mk "p1" 'idle)))
        (set-window-buffer (selected-window) b)
        (let* ((text (corral-panel-test--render-string))
               (line (corral-panel-test--line-for text "claude-p1")))
          (should (string-prefix-p "* " line)))))))

(ert-deftest corral-panel-test-state-on-second-row-not-label-row ()
  "The state renders on the second row (with the elapsed time), not on
the label row -- so a long label can never push the state off the
narrow panel."
  (corral-panel-test--with-sessions
    (let ((b (mk "p1" 'blocked)))
      (set-window-buffer (selected-window) b)
      (let* ((text (corral-panel-test--render-string))
             (lines (split-string text "\n"))
             (label-line (seq-find (lambda (l) (string-match-p "claude-p1" l)) lines))
             (label-idx (seq-position lines label-line))
             (second-row (nth (1+ label-idx) lines)))
        ;; State is NOT on the label row ...
        (should-not (string-match-p "blocked" label-line))
        ;; ... it is on the row below, alongside the elapsed time.
        (should (string-match-p "blocked" second-row))
        (should (string-match-p "[0-9]+s" second-row))))))

(ert-deftest corral-panel-test-show-panel-toggles ()
  "`corral-show-panel' opens the panel when hidden and closes it when
already shown -- the same command both directions."
  (corral-panel-test--with-sessions
    (unwind-protect
        (progn
          (delete-other-windows)
          ;; Not shown yet.
          (should-not (corral--panel-window))
          ;; First call opens it.
          (corral-show-panel)
          (should (corral--panel-window))
          ;; Second call closes it.
          (corral-show-panel)
          (should-not (corral--panel-window)))
      (when (corral--panel-window)
        (delete-window (corral--panel-window)))
      (when (get-buffer corral-panel-buffer-name)
        (kill-buffer corral-panel-buffer-name))
      (delete-other-windows))))

(ert-deftest corral-panel-test-refresh-does-not-close ()
  "`corral-refresh-panel' (the panel's `g') redraws without closing the
window -- it is not the toggle."
  (corral-panel-test--with-sessions
    (unwind-protect
        (progn
          (delete-other-windows)
          (corral-show-panel)
          (should (corral--panel-window))
          (corral-refresh-panel)
          (should (corral--panel-window)))
      (when (corral--panel-window)
        (delete-window (corral--panel-window)))
      (when (get-buffer corral-panel-buffer-name)
        (kill-buffer corral-panel-buffer-name))
      (delete-other-windows))))

(provide 'corral-panel-tests)
;;; corral-panel-tests.el ends here
