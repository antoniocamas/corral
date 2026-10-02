;;; corral-core.el --- session registry and state model -*- lexical-binding: t; -*-

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

;; Harness-agnostic session registry.  A "session" is one tracked
;; buffer running one coding-agent harness (Claude Code, Antigravity,
;; ...), identified by a pane-id.  This file knows nothing about any
;; particular harness, how it's launched, or how its state is
;; detected (hooks vs. screen-scraping) -- it only stores
;; working/blocked/idle and notifies interested parties (the panel,
;; the attention nudge) when that changes.

;;; Code:

(require 'cl-lib)
(require 'server)
(require 'face-remap)

(defgroup corral nil
  "Side panel tracking coding-agent sessions running in vterm buffers."
  :group 'tools)

(defface corral-state-working '((t :inherit success))
  "Face for sessions actively working.")

(defface corral-state-blocked '((t :inherit error))
  "Face for sessions blocked on user input -- can't proceed without a
decision from you (e.g. a tool-permission prompt). Red, not just
orange/warning-colored: this is the state that most needs your
attention, more urgent than a generic warning.")

(defface corral-state-idle '((t :inherit shadow))
  "Face for idle/done sessions.")

(defvar corral--sessions (make-hash-table :test 'equal)
  "Pane-id -> plist (:buffer :harness :variant :state :updated-at).")

(defvar corral--pane-counter 0)

(defvar corral-session-change-hook nil
  "Run after any registry mutation: registration, state change, or
removal.  The panel and other observers hook in here instead of
being called directly, so this file stays independent of any UI.")

;;; Session minor mode (help / discoverability)

;; A buffer-local minor mode turned on in every corral buffer -- each
;; tracked session (see `corral--register') and the panel (see
;; `corral-panel-mode'). Its real job is discoverability: with it
;; active, `C-h m' (`describe-mode') in a session buffer lists a
;; "Corral" section documenting what corral is and the keys available,
;; the same way any major/minor mode documents itself. vterm already
;; passes `C-h' through to Emacs (it is in the default
;; `vterm-keymap-exceptions'), so this works from inside a running
;; session, not just the panel.
;;
;; It binds the two commands that make sense from inside a session;
;; `corral-switch-to-attention' is ALSO bound globally by the user (see
;; the example config), since its primary use is jumping INTO a session
;; from an unrelated buffer, where this buffer-local map is not active.
;; Having it here too simply means `C-h m' documents it in context.

(declare-function corral-show-panel "corral-panel")

(defvar corral-session-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-SPC") #'corral-switch-to-attention)
    (define-key map (kbd "C-c p") #'corral-show-panel)
    map)
  "Keymap active in corral buffers under `corral-session-mode'.")

(define-minor-mode corral-session-mode
  "Corral: track coding-agent sessions in vterm and act on them.

This is the manual.  corral runs coding agents (Claude Code,
Antigravity, Kiro CLI, and any you register) in vterm buffers, tracks
each as a session, and shows them in a side panel colour-coded by
state.  This minor mode is on in every corral buffer, so \\[describe-mode]
shows this text from inside a session or the panel.

QUICK START
  1. Open the panel:            \\[corral-show-panel]
  2. Launch a session:          \\[corral-launch-kiro] (Kiro CLI),
                                \\[corral-launch-claude] (Claude Code),
                                \\[corral-launch-antigravity] (Antigravity).
     Each asks for a directory and a session-name suffix.  Or use
     \\[corral-launch] to pick any registered variant by completion.
  3. Switch between sessions:   \\[corral-switch-to-attention]
     -- jumps to whichever most wants you (see CONCEPTS).

KEYS
  Active in any corral buffer (a session or the panel):
\\{corral-session-mode-map}
  Under the launch prefix (bind `corral-launch-map' to a prefix of your
  choice; one key per harness, plus the `corral-launch' chooser):
\\{corral-launch-map}
  In the panel only:
\\{corral-panel-mode-map}

CONCEPTS
  State.  Each session is one of:
    working  -- the agent is doing something.
    blocked  -- it needs your input (a permission prompt, a question).
    idle     -- done, or waiting with nothing pending.
  blocked is the one that wants you; the panel colours it most
  urgently.  Fresh or just-recovered sessions show as `unknown' until
  their first real report, and count as idle for ordering.

  Attention order.  \\[corral-switch-to-attention] offers sessions
  blocked first, then idle, then working; most recently changed first
  within a group, so a bare RET at its prompt goes to the one most
  likely to want you.  The current session is excluded.  Re-tier via
  `corral-attention-order'.

  Variants.  A harness is a tool corral knows how to detect (Claude
  Code, Antigravity, Kiro CLI).  A variant is one way to launch it: the
  plain command, or a named variant you register (a wrapper script,
  extra flags) with `corral-harness-add-variant'.  Every variant gets
  its own `corral-launch-<harness>[-<variant>]' command and appears in
  the `corral-launch' chooser.

  Panel.  \\[corral-show-panel] opens a side window, two lines per
  session: label and colour-coded state, then elapsed time.  A
  left-gutter marker flags every session whose buffer is visible on
  screen; the one in the selected window is highlighted."
  :init-value nil
  :lighter nil
  :keymap corral-session-mode-map)

(defun corral--new-pane-id ()
  "A pane-id not currently in `corral--sessions'.

Advances `corral--pane-counter' until the formatted id is free, rather
than trusting the counter to be monotonic across the life of the
registry. `corral-reload-from-source' re-initialises this `defvar' to
0 (`unload-feature' then reload), while `corral-recover-sessions'
re-registers the surviving sessions under their original,
higher-numbered ids -- so a bare increment would re-mint an id an
existing session still holds, and `corral--register's `puthash' would
silently overwrite that session instead of adding a new one (observed:
a freshly launched session replacing an earlier one in the panel).
Checking the registry closes that gap whatever reset the counter."
  (let (id)
    (while (progn
             (setq corral--pane-counter (1+ corral--pane-counter))
             (setq id (format "corral-%d-%d" (emacs-pid) corral--pane-counter))
             (gethash id corral--sessions)))
    id))

(defun corral--register (pane-id buffer harness-id variant-name &optional suffix)
  "Track BUFFER under PANE-ID for HARNESS-ID/VARIANT-NAME.
Initial state is `unknown' until the harness's detection strategy
reports something real. SUFFIX, when given, is the session-name
suffix chosen at launch time (see `corral--do-launch') -- stored
separately so the panel can build a short label directly instead of
parsing it back out of the buffer's real name.

Also stashes PANE-ID/HARNESS-ID/VARIANT-NAME/SUFFIX as properties on
BUFFER's process, not just in `corral--sessions' or a buffer-local
variable -- a process's property list is untouched by `unload-feature'
\(verified directly: a buffer-local variable's value is NOT, it gets
cleared the moment its defining file is unloaded\), so this is what
lets `corral-recover-sessions' reconstruct a session that
`corral-reload-from-source' wiped out from under a still-running vterm
buffer."
  (puthash pane-id
           (list :buffer buffer :harness harness-id :variant variant-name
                 :suffix suffix :state 'unknown :updated-at (current-time))
           corral--sessions)
  (with-current-buffer buffer
    (setq-local corral--pane-id pane-id)
    (corral-session-mode 1)
    (add-hook 'kill-buffer-hook #'corral--unregister-current-buffer nil t)
    (let ((proc (get-buffer-process buffer)))
      (when proc
        (process-put proc 'corral-pane-id pane-id)
        (process-put proc 'corral-harness harness-id)
        (process-put proc 'corral-variant variant-name)
        (process-put proc 'corral-suffix suffix))))
  (run-hooks 'corral-session-change-hook))

(defvar-local corral--pane-id nil
  "Pane-id of the corral session tracked in this buffer, if any.")

(defun corral--unregister-current-buffer ()
  (when corral--pane-id
    (remhash corral--pane-id corral--sessions)
    (run-hooks 'corral-session-change-hook)))

;;;###autoload
(defun corral-recover-sessions ()
  "Re-register any live vterm session whose process still carries
corral's identity properties (see `corral--register') but whose entry
in `corral--sessions' is gone -- the situation `corral-reload-from-source'
leaves behind, since `unload-feature' wipes that hash table (and every
buffer-local variable, including the pane-id one) but has no effect on
already-running processes or their property lists.

Call this once, right after re-`require'ing corral from source. Each
recovered session starts back at state `unknown' -- exactly like a
freshly launched one -- since there is no way to recover the last
known state, only its identity; a hook-capable harness resyncs on its
next hook event, a scrape-capable one on its next tick once
`corral-scrape--sync-timer' notices it and restarts the shared timer.

Renumbers a stashed pane-id that collides with a DIFFERENT live
session's: before the collision-safe `corral--new-pane-id', a launch
after a counter reset could stamp duplicate CORRAL_PANE_IDs into two
different shells' environments and process properties, where they are
now baked in for the life of those shells -- the counter fix stops new
duplicates but cannot un-bake existing ones. Recovering both under the
one shared id would silently drop or overwrite a session (observed: a
session vanishing from the panel). So a stashed id already held by
another live buffer is replaced with a fresh one via
`corral--new-pane-id', which is also restashed on the process. A hook
harness inside that process still reports under its OLD env
CORRAL_PANE_ID, which no longer matches -- a known limitation of
recovering a mis-stamped process; the scrape harnesses corral uses
today don't depend on it, and the alternative is losing the session
entirely."
  (interactive)
  (dolist (proc (process-list))
    (let ((pane-id (process-get proc 'corral-pane-id))
          (buffer (process-buffer proc)))
      (when (and pane-id (buffer-live-p buffer)
                 (not (gethash pane-id corral--sessions)))
        (corral--register pane-id buffer
                           (process-get proc 'corral-harness)
                           (process-get proc 'corral-variant)
                           (process-get proc 'corral-suffix)))
      ;; Stashed id is already taken by a DIFFERENT live buffer: a
      ;; baked-in duplicate. Give this one a fresh, free id so both
      ;; survive instead of one clobbering the other.
      (when (and pane-id (buffer-live-p buffer)
                 (let ((existing (gethash pane-id corral--sessions)))
                   (and existing (not (eq (plist-get existing :buffer) buffer)))))
        (let ((fresh (corral--new-pane-id)))
          (process-put proc 'corral-pane-id fresh)
          (corral--register fresh buffer
                             (process-get proc 'corral-harness)
                             (process-get proc 'corral-variant)
                             (process-get proc 'corral-suffix)))))))

(defun corral--process-environ-value (pid var)
  "Return VAR's value from PID's environment via /proc/PID/environ, or
nil if unreadable or VAR isn't set.

Linux-only -- /proc doesn't exist elsewhere -- but that's the only
platform corral has ever run on (see AGENTS.md's Environment). Used to
recover a session's real pane-id straight from an already-running
process's environment (see `corral-adopt-buffer' in
`corral-harness.el'): the pane-id was set once, as CORRAL_PANE_ID, when
the process was originally spawned by `corral--do-launch', and never
changes for the life of that process -- so this is authoritative,
unlike guessing from a buffer name."
  (let ((file (format "/proc/%d/environ" pid)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents-literally file)
        (let ((prefix (concat var "=")))
          (cl-some (lambda (entry) (and (string-prefix-p prefix entry)
                                        (substring entry (length prefix))))
                   (split-string (buffer-string) "\0" t)))))))

(defun corral--set-state (pane-id state)
  "Set PANE-ID's state to STATE (a symbol: working/blocked/idle).
A no-op if PANE-ID isn't registered (e.g. its buffer was already
killed) -- callers don't need to guard against that themselves."
  (let ((session (gethash pane-id corral--sessions)))
    (when session
      (plist-put session :state state)
      (plist-put session :updated-at (current-time))
      (puthash pane-id session corral--sessions)
      (run-hooks 'corral-session-change-hook))))

(defun corral--session-label (pane-id)
  "Human-readable label for PANE-ID, for messages -- the tracked
buffer's real name if it's still live, else the pane-id itself."
  (let* ((session (gethash pane-id corral--sessions))
         (buffer (and session (plist-get session :buffer))))
    (if (buffer-live-p buffer) (buffer-name buffer) pane-id)))

(defun corral--flash-mode-line ()
  (let ((cookie (face-remap-add-relative 'mode-line 'corral-state-blocked)))
    (force-mode-line-update)
    (run-at-time 0.2 nil
                 (lambda ()
                   (face-remap-remove-relative cookie)
                   (force-mode-line-update)))))

(defun corral--notify-attention (pane-id)
  (message "corral: %s needs input" (corral--session-label pane-id))
  (corral--flash-mode-line))

(defun corral--server-socket-name ()
  "Value to hand `emacsclient -s' so it reaches THIS Emacs.

Needed at two points: when a launched session's environment is set
up (so a hook script or scraped process knows where to report back),
and when resolving that value back into an actual connection.

`server-name' is sometimes set to a path containing a literal `~',
which Emacs itself expands internally but which `emacsclient -s'
does not (that only happens via shell expansion, and this value
never passes through a shell) -- discovered the hard way in the
corral PoC. Resolve it here instead."
  (unless (server-running-p)
    (user-error "Emacs server is not running here (M-x server-start first) \
-- a hook-based or scrape-based harness won't be able to correlate \
back to this Emacs"))
  (let ((name (or server-name "server")))
    (if (string-match-p "/" name)
        (expand-file-name name)
      name)))

;;; Attention-ordered session switching

;; Switch to a tracked session chosen from a `completing-read' prompt,
;; candidates ordered by attention -- blocked first (needs your
;; input), then idle/unknown, then working; newest within a tier, its
;; context freshest in your mind. The current session is excluded and
;; the most-urgent remaining one is the default, so a bare RET jumps
;; straight there.
;;
;; Deliberately plain `completing-read', NOT any specific framework:
;; the type-to-filter / cycle-to-select feel is whatever the user's
;; own completion setup (ido, fido, vertico, ...) already gives every
;; other `completing-read', so corral stays framework-agnostic. (The
;; author's own init routes it through ido via `ido-completing-read+';
;; nothing here depends on that.)

(defcustom corral-attention-order '(blocked idle working)
  "Priority tiers for `corral-switch-to-attention', highest attention first.
A session's state is ranked by its position in this list. `unknown'
\(a freshly launched or just-recovered session that hasn't reported a
real state yet\) is treated the same as `idle'. Any state not present
here sorts after every listed one."
  :type '(repeat symbol)
  :group 'corral)

(defun corral--attention-rank (state)
  "Numeric priority for STATE per `corral-attention-order' (lower is
higher attention). `unknown' ranks as `idle'; an unlisted state sorts
after every listed one."
  (let* ((s (if (eq state 'unknown) 'idle state))
         (pos (cl-position s corral-attention-order)))
    (or pos (length corral-attention-order))))

(defun corral--attention-live-sessions ()
  "Alist of (PANE-ID . SESSION) for every tracked session whose buffer
is still live."
  (let (out)
    (maphash (lambda (id session)
               (when (buffer-live-p (plist-get session :buffer))
                 (push (cons id session) out)))
             corral--sessions)
    out))

(defun corral--attention-sorted-pane-ids ()
  "Live tracked pane-ids in attention order.

Sort key: primary by `corral--attention-rank' (blocked, then
idle/unknown, then working); secondary by `:updated-at' NEWEST first
within a tier -- the session that most recently entered that state,
whose context is freshest in your mind, comes up first."
  (mapcar
   #'car
   (sort (corral--attention-live-sessions)
         (lambda (a b)
           (let ((ra (corral--attention-rank (plist-get (cdr a) :state)))
                 (rb (corral--attention-rank (plist-get (cdr b) :state))))
             (if (/= ra rb)
                 (< ra rb)
               ;; Same tier: newest :updated-at first.
               (time-less-p (plist-get (cdr b) :updated-at)
                            (plist-get (cdr a) :updated-at))))))))

(defun corral--attention-focus (pane-id)
  "Switch to the buffer of session PANE-ID, in place, and return PANE-ID.
Reuses the currently selected window rather than splitting or popping
a new one -- like `switch-to-buffer', not `display-buffer' (whose
default pops a second window and mangles the layout). Deliberately NOT
the panel's `display-buffer'-based `corral-switch-to-session': that
opens a session FROM the dedicated side window, where reusing the
window is neither possible nor wanted."
  (let* ((session (gethash pane-id corral--sessions))
         (buffer (and session (plist-get session :buffer))))
    (when (buffer-live-p buffer)
      (pop-to-buffer-same-window buffer)
      pane-id)))

(defun corral--attention-candidates ()
  "Alist of (BUFFER-NAME . PANE-ID) for every live tracked session, in
attention order (see `corral--attention-sorted-pane-ids'). Buffer name
is the key because it is what the user types to filter; a duplicate
name is disambiguated with the pane-id so no candidate is ever lost to
a name collision."
  (let (seen out)
    (dolist (pane-id (corral--attention-sorted-pane-ids))
      (let* ((session (gethash pane-id corral--sessions))
             (buffer (plist-get session :buffer))
             (name (buffer-name buffer)))
        (when (member name seen)
          (setq name (format "%s [%s]" name pane-id)))
        (push name seen)
        (push (cons name pane-id) out)))
    (nreverse out)))

;;;###autoload
(defun corral-switch-to-attention ()
  "Switch to a tracked session chosen from a completion prompt.
Candidates are ordered by attention -- blocked first, then
idle/unknown, then working; newest within a tier -- and annotated with
their state. The session you are currently in is excluded, and the
most-urgent remaining one is the default, so pressing RET with no
input jumps straight there. Switches in place (reuses the current
window).

Uses plain `completing-read': the type-to-filter and cycle keys are
whatever your own completion UI provides, exactly as for `C-x b'."
  (interactive)
  (let* ((all (corral--attention-candidates))
         ;; Drop the current buffer's session so we always move.
         (candidates (seq-remove (lambda (c) (equal (cdr c) corral--pane-id)) all)))
    (unless candidates
      (user-error "No other corral session to switch to"))
    (let* ((names (mapcar #'car candidates))
           (completion-extra-properties
            (list :annotation-function
                  (lambda (name)
                    (let* ((pane-id (cdr (assoc name candidates)))
                           (session (and pane-id (gethash pane-id corral--sessions)))
                           (state (and session (plist-get session :state))))
                      (if state (format "  %s" state) "")))))
           (choice (completing-read
                    (format "Switch to session (default %s): " (car names))
                    names nil t nil nil (car names)))
           (pane-id (cdr (assoc choice candidates))))
      (when pane-id
        (corral--attention-focus pane-id)))))

(provide 'corral-core)
;;; corral-core.el ends here
