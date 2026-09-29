;;; zr-elisp.el --- Links to Emacs sources -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).
;;; Commentary:
;; `zr-elisp-source-url' copies the source URL or opens its blame page.
;;; Code:
(require 'subr-x)
(require 'url-util)
(defun zr-elisp-source-url (&optional blame)
  "Copy the current Emacs Lisp source URL; with BLAME, open its blame page."
  (interactive "P")
  (let* ((file (replace-regexp-in-string "\\\\" "/" (or buffer-file-name "")))
         (path (and (string-match "/lisp/\\(.+?\\)\\(?:\\.gz\\)?\\'" file)
                    (match-string 1 file))))
    (unless path (user-error "Not an Emacs source file under lisp/"))
    (let ((url (concat "https://github.com/emacs-mirror/emacs/"
                       (if blame "blame/master/" "raw/refs/heads/master/")
                       "lisp/" (mapconcat #'url-hexify-string (split-string path "/") "/"))))
      (if blame (browse-url url) (kill-new url) (message "Copied: %s" url))
      url)))
(provide 'zr-elisp)
;;; zr-elisp.el ends here
