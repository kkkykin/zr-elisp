;;; zr-process-menu.el --- Process list filtering and grouping -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).
;;; Commentary:
;; Enable `zr-process-menu-mode' from `process-menu-mode-hook' if desired.
;;; Code:
(require 'cl-lib)
(require 'simple)
(require 'tabulated-list)
(defgroup zr-process-menu nil "Process listing helpers." :group 'processes)
(defcustom zr-process-menu-omit-regexp nil
  "Process names to omit; nil displays all processes."
  :type '(choice (const nil) regexp))
(make-variable-buffer-local 'zr-process-menu-omit-regexp)
(defvar-local zr-process-menu-group-column nil)
(defvar zr-process-menu-mode)
(defun zr-process-menu--after-refresh (&rest _)
  "Filter both initial listings and subsequent refreshes in enabled buffers."
  (when zr-process-menu-mode (zr-process-menu--refresh)))
(defun zr-process-menu--cleanup ()
  "Remove advice when the last enabled process buffer goes away."
  (unless (cl-some (lambda (buffer)
                    (and (not (eq buffer (current-buffer)))
                         (buffer-local-value 'zr-process-menu-mode buffer)))
                  (buffer-list))
    (advice-remove 'list-processes--refresh #'zr-process-menu--after-refresh)))
(defun zr-process-menu--refresh ()
  "Filter and group the current process entries."
  (when zr-process-menu-omit-regexp
    (setq tabulated-list-entries
          (cl-remove-if
           (lambda (entry)
             (string-match-p zr-process-menu-omit-regexp
                             (let ((name (aref (cadr entry) 0)))
                               (if (stringp name) name (car name)))))
           tabulated-list-entries)))
  (setq-local tabulated-list-groups
              (when zr-process-menu-group-column
                (seq-group-by
                 (lambda (entry)
                   (let ((value (aref (cadr entry) zr-process-menu-group-column)))
                     (concat "* " (if (stringp value) value (car value)))))
                 tabulated-list-entries))))
(defun zr-process-menu-filter (regexp)
  "Omit process names matching REGEXP; empty shows everything."
  (interactive (list (read-regexp "Omit names: ")))
  (setq zr-process-menu-omit-regexp (unless (equal regexp "") regexp))
  (zr-process-menu-mode 1)
  (revert-buffer))
(defun zr-process-menu-group (column)
  "Group by COLUMN, numbered from one; zero disables grouping."
  (interactive "nColumn (0 for none): ")
  (unless (<= 0 column (length tabulated-list-format)) (user-error "Invalid column"))
  (setq zr-process-menu-group-column (unless (zerop column) (1- column)))
  (zr-process-menu-mode 1)
  (revert-buffer))
(defun zr-process-menu-hide (count)
  "Remove COUNT rows from this display without terminating processes."
  (interactive "p")
  (dotimes (_ count)
    (when-let* ((id (tabulated-list-get-id)))
      (setq tabulated-list-entries (assq-delete-all id tabulated-list-entries))
      (tabulated-list-delete-entry))))
(defun zr-process-menu-delete (count)
  "Terminate the processes in the next COUNT rows."
  (interactive "p")
  (let (processes)
    (save-excursion
      (dotimes (_ count)
        (when-let* ((id (tabulated-list-get-id))) (push id processes))
        (forward-line)))
    (dolist (process processes)
      (when (processp process) (delete-process process)))
    (revert-buffer)))
(define-minor-mode zr-process-menu-mode
  "Apply local filtering and grouping when the process list refreshes."
  :lighter " ZProc"
  (if zr-process-menu-mode
      (progn
        (advice-add 'list-processes--refresh :after #'zr-process-menu--after-refresh)
        (add-hook 'kill-buffer-hook #'zr-process-menu--cleanup nil t)
        (add-hook 'change-major-mode-hook #'zr-process-menu--cleanup nil t))
    (remove-hook 'kill-buffer-hook #'zr-process-menu--cleanup t)
    (remove-hook 'change-major-mode-hook #'zr-process-menu--cleanup t)
    (setq-local tabulated-list-groups nil)
    (zr-process-menu--cleanup))
  (when (derived-mode-p 'process-menu-mode)
    (revert-buffer)))
(provide 'zr-process-menu)
;;; zr-process-menu.el ends here
