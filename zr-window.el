;;; zr-window.el --- Follow columns and tab groups -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).

;;; Commentary:

;; Set `tab-line-tabs-buffer-group-function' to `zr-window-tab-group' as desired.

;;; Code:

(require 'cl-lib)
(require 'follow)
(require 'tab-line)

(defgroup zr-window nil
  "Window and tab helpers."
  :group 'windows)

(defcustom zr-window-excluded-buffers nil
  "Buffer matching conditions omitted from tab groups."
  :type '(repeat sexp))

(defun zr-window-tab-group (&optional buffer)
  "Group BUFFER by mode unless excluded by `zr-window-excluded-buffers'."
  (let ((buffer (or buffer (current-buffer))))
    (unless (cl-some (lambda (condition)
                       (buffer-match-p condition buffer))
                     zr-window-excluded-buffers)
      (tab-line-tabs-buffer-group-by-mode buffer))))

(defun zr-window-follow-columns (&optional only)
  "Split into columns of at least `fill-column' characters and enable Follow.
With ONLY, first delete other windows."
  (interactive "P")
  (when only
    (delete-other-windows))
  (unless (> fill-column 0)
    (user-error "fill-column must be positive"))
  (let* ((width (window-total-width))
         (count (max 1 (/ width (max fill-column window-min-width))))
         (column (/ width count))
         (window (selected-window)))
    (dotimes (_ (1- count))
      (setq window (split-window window column 'right))))
  (follow-mode 1))

(provide 'zr-window)
;;; zr-window.el ends here
