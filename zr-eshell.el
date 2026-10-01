;;; zr-eshell.el --- Eshell output and interpreter helpers -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2025
;; Author:  <kw@comhb>
;; Source: ../emacs.d/user-lisp/init-esh.el (selected functionality).

;;; Commentary:

;; Enable `zr-eshell-mode' in eshell-mode-hook.  Interpreter selection and
;; visual-command lists remain personal configuration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eshell)
(require 'em-hist)
(require 'em-pred)
(require 'bookmark)
(declare-function org-table-convert-region "org-table")
(declare-function org-table-align "org-table")

(defgroup zr-eshell nil
  "Eshell helpers."
  :group 'eshell)

(defcustom zr-eshell-interpreters nil
  "Alist of file extensions and interpreter argument lists."
  :type '(alist :key-type string :value-type (repeat string)))

(defvar-local zr-eshell--interpreters nil)

(defvar-local zr-eshell--history-hook nil)

(defvar zr-eshell-mode)

(defun zr-eshell-import-bookmarks (&optional prefix)
  "Define Eshell variables for file bookmarks, using PREFIX (default BM)."
  (interactive "sVariable prefix: ")
  (bookmark-maybe-load-default-file)
  (dolist (entry bookmark-alist)
    (when-let* ((file (bookmark-get-filename entry))
                ((not (bookmark-get-handler entry))))
      (eshell-set-variable
       (concat (if (string-empty-p (or prefix ""))
                   "BM"
                 prefix)
               "_" (car entry))
       file))))

(defun zr-eshell-set-editor (program)
  "Set Eshell EDITOR to PROGRAM unless with-editor manages it."
  (interactive "sEditor: ")
  (unless (memq 'with-editor-export-editor eshell-mode-hook)
    (eshell-set-variable "EDITOR" program)))

(defun zr-eshell-pop-output (format)
  "Display the previous Eshell output as FORMAT: plain, csv, tsv, json or markdown."
  (interactive
   (list (intern (completing-read "Format: " '(plain csv tsv json markdown) nil t))))
  (let* ((source (current-buffer))
         (start (save-excursion (eshell-beginning-of-output)))
         (end (save-excursion (eshell-end-of-output))))
    (unless (> end start)
      (user-error "No output at point"))
    (let ((buffer (generate-new-buffer "*Eshell Output*")))
      (with-current-buffer buffer
        (insert-buffer-substring source start end)
        (goto-char (point-min))
        (pcase format
          ((or 'csv 'tsv)
           (require 'org-table)
           (org-table-convert-region (point-min) (point-max) (if (eq format 'csv)
                                                                 '(4)
                                                               '(16))))
          ('markdown
           (require 'org-table)
           (org-table-align))
          ('json
           (js-json-mode))))
      (pop-to-buffer buffer))))

(defun zr-eshell-git-handler (&rest arguments)
  "Run Git with color at a terminal-facing end of an Eshell pipeline."
  (throw 'eshell-replace-command
         (eshell-parse-command
          (concat (string eshell-explicit-command-char) (car arguments))
          (append (when (memq eshell-in-pipeline-p '(nil last))
                    '("-c" "color.ui=always"))
                  (cdr arguments)))))

(defun zr-eshell-script-interpreter (&rest arguments)
  "Execute a script using env -S or `zr-eshell-interpreters'."
  (let* ((file (car arguments))
         (interpreter
          (when (file-readable-p file)
            (with-temp-buffer
              (insert-file-contents-literally file nil 0
                                              eshell-command-interpreter-max-length)
              (when (looking-at "#![ \t]*/\\(?:usr/\\)?bin/env[ \t]+-S[ \t]+\\([^\n]+\\)")
                (split-string-shell-command (match-string 1)))))))
    (setq interpreter
          (or interpreter
              (cdr (assoc (file-name-extension file) zr-eshell-interpreters))))
    (unless interpreter
      (user-error "No interpreter configured for %s" file))
    (throw 'eshell-replace-command
           (eshell-parse-command (car interpreter) (append (cdr interpreter) arguments)))))

(defun zr-eshell--word-designator (original history reference)
  "Select history arguments for REFERENCE when `zr-eshell-mode' is enabled.
Numerical range ends are inclusive.  Dollar means the final word."
  (if (not zr-eshell-mode)
      (funcall original history reference)
    (save-match-data
      (if (not
           (string-match
            "\\`:?\\(?:\\([0-9]+\\|[$*^]\\)\\(?:-\\([0-9]+\\|[$]\\)?\\|\\(\\*\\)\\)?\\|-\\([0-9]+\\|[$]\\)\\)"
            reference))
          ;; A modifier without a word selector applies to the whole event.
          ;; Let Eshell handle unsupported selectors.
          (if (string-match-p "\\`:[[:alpha:]&]" reference)
              (cons history 0)
            (with-temp-buffer
              (funcall original history reference)))
        (let* ((end (match-end 0))
               (first (or (match-string 1 reference) "0"))
               (last (or (match-string 2 reference) (match-string 4 reference)))
               (star (match-string 3 reference))
               (range (string-match-p "-" (substring reference 0 end)))
               (words (with-temp-buffer
                        (insert history)
                        (car (eshell-hist-parse-arguments (point-min) (point-max)))))
               (size (length words))
               (begin (cond
                       ((equal first "*")
                        1)
                       ((equal first "^")
                        1)
                       ((equal first "$")
                        (1- size))
                       (t
                        (string-to-number first))))
               (finish (cond
                        ((or (equal first "*") star (equal last "$"))
                         size)
                        (last
                         (1+ (string-to-number last)))
                        (range
                         (1- size))
                        (t
                         (1+ begin)))))
          (unless (<= 0 begin finish size)
            (user-error "History argument out of range"))
          (cons (mapconcat #'identity (seq-subseq words begin finish) " ") end))))))

(defun zr-eshell--modifier (original &rest arguments)
  "Use the correctly named prediction module for enabled Eshell buffers."
  (if zr-eshell-mode
      (let ((eshell-modules-list (cons 'em-pred eshell-modules-list)))
        (apply original arguments))
    (apply original arguments)))

(defun zr-eshell--remove-global-advice ()
  "Remove shared advice when no other enabled buffer remains."
  (unless (cl-some (lambda (buffer)
                     (and (not (eq buffer (current-buffer)))
                          (buffer-local-value 'zr-eshell-mode buffer)))
                   (buffer-list))
    (advice-remove 'eshell-hist-parse-word-designator #'zr-eshell--word-designator)
    (advice-remove 'eshell-hist-parse-modifier #'zr-eshell--modifier)))

(defun zr-eshell--disable ()
  "Remove local and shared state before changing major modes."
  (zr-eshell-mode -1))

(define-minor-mode zr-eshell-mode
  "Enable local Git handling and corrected history expansion."
  :lighter nil
  (if zr-eshell-mode
      (progn
        (unless zr-eshell--interpreters
          (setq zr-eshell--interpreters
                (list (cons "\\`git\\'" #'zr-eshell-git-handler)))
          (setq-local eshell-interpreter-alist
                      (append zr-eshell--interpreters eshell-interpreter-alist)))
        (advice-add 'eshell-hist-parse-word-designator :around
                    #'zr-eshell--word-designator)
        (advice-add 'eshell-hist-parse-modifier :around #'zr-eshell--modifier)
        (unless (memq #'eshell-expand-history-references eshell-expand-input-functions)
          (setq zr-eshell--history-hook t)
          (add-hook 'eshell-expand-input-functions #'eshell-expand-history-references
                    nil t))
        (add-hook 'kill-buffer-hook #'zr-eshell--remove-global-advice nil t)
        (add-hook 'change-major-mode-hook #'zr-eshell--disable nil t))
    (setq eshell-interpreter-alist
          (cl-set-difference eshell-interpreter-alist zr-eshell--interpreters))
    (setq zr-eshell--interpreters nil)
    (when zr-eshell--history-hook
      (remove-hook 'eshell-expand-input-functions #'eshell-expand-history-references t)
      (setq zr-eshell--history-hook nil))
    (remove-hook 'kill-buffer-hook #'zr-eshell--remove-global-advice t)
    (remove-hook 'change-major-mode-hook #'zr-eshell--disable t)
    (zr-eshell--remove-global-advice)))

(provide 'zr-eshell)
;;; zr-eshell.el ends here
