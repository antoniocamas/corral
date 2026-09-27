;;; corral.el --- side panel for coding-agent sessions running in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Antonio Camas

;; Author: Antonio Camas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0.0.2"))
;; Keywords: tools, processes
;; URL: https://github.com/antoniocamas/corral

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

;; corral tracks coding-agent sessions (Claude Code, and later other
;; harnesses) running in vterm buffers, and shows them in a side
;; panel color-coded by state: working, blocked on your input, or
;; idle. Inspired by studying herdr (https://herdr.dev), a similar
;; tool built as its own standalone terminal multiplexer -- corral
;; instead lives inside Emacs and relies on vterm already owning the
;; underlying processes, so it never needs to be one itself.
;;
;; Quickstart:
;;
;;   (require 'corral)
;;   M-x corral-claude-install-hooks   ; once, reviews a diff before writing
;;   M-x corral-show-panel
;;   M-x corral-launch-claude
;;
;; See README.md for the full picture, and how to register your own
;; launch variants (wrapper scripts, extra flags) from your own config.

;;; Code:

(require 'corral-core)
(require 'corral-vterm)
(require 'corral-panel)
(require 'corral-harness)
(require 'corral-hook)
(require 'corral-claude)
(require 'corral-scrape)
(require 'corral-antigravity)

(provide 'corral)
;;; corral.el ends here
