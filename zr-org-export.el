;;; zr-org-export.el --- Optional Pandoc and LaTeX export fixes -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).
;;; Commentary:
;; Enable `zr-org-export-mode' to install the narrowly scoped export filters.
;;; Code:
(require 'ox)
(require 'subr-x)
(defgroup zr-org-export nil "Org export filters." :group 'org-export)
(defun zr-org-export-pandoc-options (body backend info)
  "Preserve export OPTIONS from INFO in Pandoc BODY for BACKEND."
  (if (not (eq backend 'pandoc)) body
    (concat "#+OPTIONS: "
            (mapconcat #'identity
                       (cl-loop for option in org-export-options-alist
                                for key = (nth 2 option)
                                when key collect (format "%s:%S" key (plist-get info (car option)))) " ")
            "\n" (let ((case-fold-search t))
                     (replace-regexp-in-string "^#\\+options:.*\n?" "" body)))))
(defun zr-org-export-latex-image-path (text backend info)
  "Make LaTeX image paths in TEXT relative to INFO's output file."
  (if (not (and (eq backend 'latex) (plist-get info :output-file))) text
    (let ((directory (file-name-directory (expand-file-name (plist-get info :output-file)))))
      (replace-regexp-in-string
       "\\\\includegraphics\\(?:\\[[^]]*\\]\\)?{\\([^}]+\\)}"
       (lambda (match)
         (let* ((begin (match-beginning 1)) (end (match-end 1))
                (path (substring match begin end)))
           (concat (substring match 0 begin)
                   (file-relative-name (expand-file-name path) directory)
                   (substring match end) "\u200b"))) text t t))))
(define-minor-mode zr-org-export-mode
  "Install Pandoc metadata and LaTeX image path filters."
  :global t
  (if zr-org-export-mode
      (progn
        (add-hook 'org-export-filter-final-output-functions #'zr-org-export-pandoc-options)
        (add-hook 'org-export-filter-link-functions #'zr-org-export-latex-image-path))
    (remove-hook 'org-export-filter-final-output-functions #'zr-org-export-pandoc-options)
    (remove-hook 'org-export-filter-link-functions #'zr-org-export-latex-image-path)))
(provide 'zr-org-export)
;;; zr-org-export.el ends here
