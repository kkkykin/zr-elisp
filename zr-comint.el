;;; zr-comint.el --- Comint history and shell tracking -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-comint.el (selected functionality).
;;; Commentary:
;; Add `zr-comint-history-mode' to comint-mode-hook, and optionally
;; `zr-comint-shell-setup' to shell-mode-hook.  No hooks are installed on load.
;;; Code:
(require 'cl-lib)
(require 'comint)
(require 'shell)
(require 'dirtrack)
(defgroup zr-comint nil "Comint persistence." :group 'comint)
(defcustom zr-comint-history-directory (locate-user-emacs-file "comint/")
  "Directory for programs without an existing history file setting." :type 'directory)
(defcustom zr-comint-kill-buffer-on-exit nil
  "Whether to kill buffers after successful process exit." :type 'boolean)
(defvar-local zr-comint--process nil)
(defvar-local zr-comint--loaded-file nil)
(defvar zr-comint-history-mode)
(defun zr-comint--disable ()
  "Detach before changing this buffer's major mode."
  (zr-comint-save-history)
  (zr-comint-history-mode -1))
(defun zr-comint--save-all ()
  "Save enabled buffers when Emacs exits, even if their processes are live."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (condition-case err (zr-comint-save-history)
        (error (message "History save failed in %s: %s"
                        (buffer-name) (error-message-string err)))))))
(defun zr-comint--cleanup ()
  "Remove the exit hook when the last enabled buffer is disabled or killed."
  (unless (cl-some (lambda (buffer)
                    (and (not (eq buffer (current-buffer)))
                         (buffer-local-value 'zr-comint-history-mode buffer)))
                  (buffer-list))
    (remove-hook 'kill-emacs-hook #'zr-comint--save-all)))
(defun zr-comint-save-history ()
  "Save this buffer's history when persistence is enabled."
  (when (and zr-comint-history-mode comint-input-ring-file-name
             (not (equal comint-input-ring-file-name "")) comint-input-ring)
    (make-directory (file-name-directory (expand-file-name comint-input-ring-file-name)) t)
    (comint-write-input-ring)))
(defun zr-comint--sentinel (original process event)
  "Save history before ORIGINAL can dispose of PROCESS's buffer."
  (let ((buffer (process-buffer process))
        (finished (memq (process-status process) '(exit signal))))
    (when (and finished (buffer-live-p buffer))
      (with-current-buffer buffer
        (condition-case err (zr-comint-save-history)
          (file-error (message "History save failed: %s" (error-message-string err))))))
    (when original (funcall original process event))
    (when (and finished (eq (process-exit-status process) 0) (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (and zr-comint-history-mode zr-comint-kill-buffer-on-exit)
          (kill-buffer buffer))))))
(defun zr-comint--attach ()
  "Attach history persistence to the current process once."
  (when-let* ((process (get-buffer-process (current-buffer)))
              (program (car (process-command process))))
    (unless comint-input-ring-file-name
      (setq-local comint-input-ring-file-name
                  (expand-file-name (file-name-base program) zr-comint-history-directory)))
    (unless (equal zr-comint--loaded-file comint-input-ring-file-name)
      (comint-read-input-ring t)
      (setq zr-comint--loaded-file comint-input-ring-file-name))
    (when (and zr-comint--process (not (eq zr-comint--process process)))
      (remove-function (process-sentinel zr-comint--process) #'zr-comint--sentinel))
    (setq zr-comint--process process)
    (add-function :around (process-sentinel process) #'zr-comint--sentinel)))
(define-minor-mode zr-comint-history-mode
  "Persist Comint history, preserving preconfigured history filenames."
  :lighter nil
  (if zr-comint-history-mode
      (progn
        (add-hook 'kill-emacs-hook #'zr-comint--save-all)
        (add-hook 'kill-buffer-hook #'zr-comint-save-history nil t)
        (add-hook 'kill-buffer-hook #'zr-comint--cleanup t t)
        (add-hook 'change-major-mode-hook #'zr-comint--disable nil t)
        (add-hook 'comint-exec-hook #'zr-comint--attach nil t)
        (zr-comint--attach))
    (remove-hook 'kill-buffer-hook #'zr-comint-save-history t)
    (remove-hook 'kill-buffer-hook #'zr-comint--cleanup t)
    (remove-hook 'change-major-mode-hook #'zr-comint--disable t)
    (remove-hook 'comint-exec-hook #'zr-comint--attach t)
    (when zr-comint--process
      (remove-function (process-sentinel zr-comint--process) #'zr-comint--sentinel))
    (setq zr-comint--process nil)
    (zr-comint--cleanup)))
(defun zr-comint-shell-setup ()
  "Configure directory tracking for Bash or cmdproxy in the current buffer."
  (pcase (file-name-base (or explicit-shell-file-name shell-file-name))
    ("bash" (shell-dirtrack-mode -1))
    ("cmdproxy"
     (shell-dirtrack-mode -1)
     (setq-local dirtrack-list '("^\\([a-zA-Z]:.*\\)>" 1))
     (dirtrack-mode 1))))
(provide 'zr-comint)
;;; zr-comint.el ends here
