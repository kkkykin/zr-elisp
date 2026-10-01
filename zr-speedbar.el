;;; zr-speedbar.el --- Speedbar file commands -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).

;;; Commentary:

;; Bind these commands in `speedbar-file-key-map' in personal configuration.

;;; Code:

(require 'speedbar)

(defun zr-speedbar-show-all ()
  "Refresh Speedbar temporarily including unknown file types."
  (interactive)
  (let ((speedbar-show-unknown-files t))
    (speedbar-refresh)))

(defun zr-speedbar-diff ()
  "Compare the file at point with the last selected Speedbar file."
  (interactive)
  (let ((file (speedbar-line-file)))
    (unless (and file (file-regular-p file)
                 speedbar-last-selected-file
                 (file-regular-p speedbar-last-selected-file))
      (user-error "Select two regular files first"))
    (diff file speedbar-last-selected-file)))

(provide 'zr-speedbar)
;;; zr-speedbar.el ends here
