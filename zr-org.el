;;; zr-org.el --- Org editing and tables -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).

;;; Commentary:

;; Editing commands, table lookup and the zr-file-finder dynamic block.
;; Speed commands derive from Sacha Chua's list-item speed commands (2025).

;;; Code:

(require 'org)
(require 'ob-ref)
(require 'org-element)

(defgroup zr-org nil
  "Org editing helpers."
  :group 'org)

(defvar-local zr-org--saved nil)

(defun zr-org-speed-command-p ()
  "Whether point is at the start of an Org heading or list item."
  (or (and (bolp) (looking-at org-outline-regexp))
      (and (looking-at (org-item-re))
           (string-match-p "\\`[ \t]*\\'"
                           (buffer-substring (line-beginning-position) (point))))))

(defun zr-org-cut-entry (&optional count)
  "Cut the current subtree or list item, including nested contents."
  (interactive "p")
  (if (org-at-item-p)
      (let ((begin (save-excursion (org-beginning-of-item))))
        (kill-region begin (save-excursion (org-end-of-item))))
    (org-cut-subtree count)))

(defun org-dblock-write:zr-file-finder (parameters)
  "Insert a file table using PARAMETERS :dir and :re."
  (let ((directory (or (plist-get parameters :dir) default-directory))
        (regexp (or (plist-get parameters :re) ".")))
    (insert "| Path |\n|------+\n")
    (dolist (file (sort (directory-files-recursively directory regexp) #'string<))
      (insert "| " (org-link-make-string (concat "file:" (org-link-escape file))
                                         (replace-regexp-in-string "|" "\\vert{}" file t
                                                                   t))
              " |\n"))))

(defun zr-org-table-select (value-reference table key-reference key)
  "Find KEY in TABLE's KEY-REFERENCE and resolve VALUE-REFERENCE for its row.
VALUE-REFERENCE includes a %d row placeholder, for example %d,1."
  (let ((index
         (cl-position key (org-babel-ref-resolve (format "%s[%s]" table key-reference))
                      :test #'equal)))
    (when index
      (org-babel-ref-resolve (format "%s[%s]" table (format value-reference index))))))

(defun zr-org-insert-noweb (name)
  "Insert a noweb reference to NAME."
  (interactive
   (list (completing-read "Source block: " (org-babel-src-block-names) nil t)))
  (insert (org-babel-noweb-wrap name)))

(defun zr-org-insert-call (name)
  "Insert an Org call to NAME with editable header and argument fields."
  (interactive
   (list (completing-read "Source block: " (org-babel-src-block-names) nil t)))
  (insert "#+call: " name "[]()[]")
  (backward-char 5))

(define-minor-mode zr-org-mode
  "Enable local list speed commands."
  :lighter nil
  (if zr-org-mode
      (unless zr-org--saved
        (setq zr-org--saved
              (mapcar (lambda (symbol)
                        (list symbol (local-variable-p symbol) (symbol-value symbol)))
                      '(org-use-speed-commands org-speed-commands)))
        (setq-local org-use-speed-commands #'zr-org-speed-command-p
                    org-speed-commands (cons '("k" . zr-org-cut-entry)
                                             (assoc-delete-all "k"
                                                               (copy-tree
                                                                org-speed-commands)))))
    (dolist (entry zr-org--saved)
      (if (cadr entry)
          (set (make-local-variable (car entry)) (nth 2 entry))
        (kill-local-variable (car entry))))
    (setq zr-org--saved nil)))

(provide 'zr-org)
;;; zr-org.el ends here
