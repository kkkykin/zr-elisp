;;; zr-window.el --- Follow columns and tab groups -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).

;;; Commentary:

;; Set `tab-line-tabs-buffer-group-function' to `zr-window-tab-group' as desired.
;; Use `zr-window-follow-columns' to read a buffer in adjacent columns.

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

(defun zr-window--create-follow-columns ()
  "Split the selected window, keeping at least `fill-column' text columns."
  (let* ((width (window-total-width))
         (count (max 1 (min (/ width (window-min-size nil t))
                           (floor (/ (window-max-chars-per-line) fill-column)))))
         (configuration (current-window-configuration))
         (done (= count 1)))
    (while (not done)
      (let ((window (selected-window)))
        (dotimes (i (1- count))
          (setq window
                (split-window window
                              (ceiling (window-total-width window) (- count i))
                              'right))))
      ;; Each new column has its own margins, fringes and divider.  Measure
      ;; the resulting text area rather than guessing their combined cost.
      (if (cl-every (lambda (window)
                      (>= (window-max-chars-per-line window) fill-column))
                    (follow-all-followers))
          (setq done t)
        (set-window-configuration configuration)
        (setq count (1- count)
              done (= count 1))))))

(defun zr-window-arrange-follow-columns (&optional only)
  "Arrange the current buffer's Follow columns and return their windows.
Split a single window into columns with at least `fill-column' visible
text characters each, accounting for window decorations.  Keep a narrow
window as one column.  Preserve existing columns and other buffers' windows.
With ONLY, delete other windows before arranging new columns.
This function leaves `follow-mode' unchanged."
  (unless (and (integerp fill-column) (> fill-column 0))
    (user-error "fill-column must be positive"))
  (let ((configuration (current-window-configuration))
        complete)
    (unwind-protect
        (progn
          (when only
            (delete-other-windows))
          (unless (cdr (follow-all-followers))
            (zr-window--create-follow-columns))
          (setq complete t))
      (unless complete
        (set-window-configuration configuration))))
  (follow-all-followers))

;;;###autoload
(defun zr-window-follow-columns (&optional only)
  "Arrange columns based on `fill-column' and enable Follow.
Preserve existing columns and other buffers' windows.  With ONLY (the
prefix argument), delete other windows and calculate the columns anew.
A narrow window stays as one column."
  (interactive "P")
  (let ((windows (zr-window-arrange-follow-columns only)))
    (unless follow-mode (follow-mode 1))
    (follow-redisplay windows)))

(provide 'zr-window)
;;; zr-window.el ends here
