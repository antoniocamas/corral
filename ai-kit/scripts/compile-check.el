;;; compile-check.el --- byte-compile every corral*.el, fail on any warning -*- lexical-binding: t; -*-

;; Run from the repo root:
;;   rm -f *.elc && emacs -Q --batch -L . -l ai-kit/scripts/compile-check.el ; rm -f *.elc
;;
;; Exits non-zero if byte-compilation of any corral*.el emits a
;; warning or error, so it is usable as a CI / pre-done gate. The file
;; list is iterated INSIDE this loaded script, never via a shell-side
;; loop -- shell word-splitting mangles the `\`corral.*\.el\'' regex
;; and can silently drop corral.el itself (the reason this is a
;; committed file and not an inline --eval).

(add-to-list 'load-path ".")

(setq byte-compile-error-on-warn t)

(let ((failed nil))
  (dolist (f (directory-files "." nil "\\`corral.*\\.el\\'"))
    (unless (ignore-errors (byte-compile-file f))
      (setq failed t)
      (message "compile-check: FAILED on %s" f)))
  (when failed
    (kill-emacs 1)))

(message "compile-check: all corral*.el compiled clean")
;;; compile-check.el ends here
