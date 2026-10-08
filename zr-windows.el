;;; zr-windows.el --- Windows shell, archive and IME helpers -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-winnt.el (selected functionality).

;;; Commentary:

;; Platform commands and opt-in encoding/IME modes.  No terminal focusing,
;; OneDrive, elevation scripts or environment changes are performed here.
;; For "moyu", enable `zr-windows-ime-mode' in selected buffers and use
;; `zr-windows-quit-ime-buffers' to hide their windows without killing them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'comint)

(defgroup zr-windows nil
  "Windows helpers."
  :group 'environment)

(defcustom zr-windows-alternate-shell "C:/Windows/System32/bash.exe"
  "Alternate shell used by the shell switching commands."
  :type 'file)

(defcustom zr-windows-terminal-shell nil
  "Normal shell to switch back to; nil captures the current setting on first use."
  :type '(choice (const nil) file))

(defvar eshell-in-pipeline-p)

(defvar explicit-shell-file-name)

(defvar ls-lisp-use-insert-directory-program)

(defvar zr-windows-encoding-mode)

(defvar zr-windows-ime-mode)
(declare-function w32-set-ime-open-status "w32-ime")

(defun zr-windows--require ()
  "Signal a useful error off Windows."
  (unless (eq system-type 'windows-nt)
    (user-error "This command requires Windows")))

(defun zr-windows-allow-loopback (package)
  "Allow the UWP PACKAGE to connect to localhost."
  (interactive
   (progn
     (zr-windows--require)
     (list (completing-read "UWP package: "
                            (directory-files
                             (expand-file-name "AppData/Local/Packages"
                                               (getenv "USERPROFILE"))
                             nil "^[^.]")))))
  (zr-windows--require)
  (unless (eq 0
              (call-process "CheckNetIsolation" nil nil nil "LoopbackExempt" "-a"
                            (concat "-n=" package)))
    (error "Could not grant loopback access")))

(defun zr-windows-shell ()
  "Start the configured alternate shell in its own buffer."
  (interactive)
  (zr-windows--require)
  (let ((explicit-shell-file-name zr-windows-alternate-shell))
    (shell "*Windows alternate shell*")))

(defun zr-windows-toggle-shell ()
  "Switch `shell-file-name' between the configured normal and alternate shells."
  (interactive)
  (zr-windows--require)
  (unless zr-windows-terminal-shell
    (setq zr-windows-terminal-shell shell-file-name))
  (setq shell-file-name (if (equal shell-file-name zr-windows-alternate-shell)
                            zr-windows-terminal-shell
                          zr-windows-alternate-shell)))

(defun zr-windows-command-program (command)
  "Extract the executable from COMMAND, skipping cmd start options."
  (when (stringp command)
    (let ((words (split-string-shell-command command)))
      (when (equal (downcase (or (car words) "")) "start")
        (pop words)
        (while (and words (or (equal (car words) "") (string-prefix-p "/" (car words))))
          (pop words)))
      (car words))))

(defun zr-windows-command-coding (command)
  "Return the process coding pair appropriate to COMMAND."
  (when-let* ((program (zr-windows-command-program command)))
    (or (find-operation-coding-system 'call-process program)
        default-process-coding-system)))

(defun zr-windows-process-coding (&optional process command)
  "Set local PROCESS coding according to COMMAND or its program."
  (when (and zr-windows-encoding-mode (not (file-remote-p default-directory)))
    (when-let* ((process (or process (get-buffer-process (current-buffer))))
                (arguments (process-command process))
                (program (or command (if (string-match-p "cmdproxy" (car arguments))
                                         (nth 2 arguments)
                                       (car arguments))))
                (coding (zr-windows-command-coding program)))
      (set-process-coding-system process (car coding) (cdr coding)))))

(defun zr-windows--shell-command (original &rest arguments)
  "Apply command-specific coding around shell-command-on-region ORIGINAL."
  (if (file-remote-p default-directory)
      (apply original arguments)
    (let ((coding (zr-windows-command-coding (nth 2 arguments))))
      (let ((coding-system-for-read (car coding))
            (coding-system-for-write (cdr coding)))
        (apply original arguments)))))

(defun zr-windows--babel-command (original &rest arguments)
  "Apply command-specific coding around Babel shell ORIGINAL."
  (if (file-remote-p default-directory)
      (apply original arguments)
    (let ((coding (zr-windows-command-coding (car arguments))))
      (let ((coding-system-for-read (car coding))
            (coding-system-for-write (cdr coding)))
        (apply original arguments)))))

(defun zr-windows--insert-directory (original &rest arguments)
  "Read directory output as UTF-8, falling back to ls-lisp on local errors."
  (if (file-remote-p (car arguments))
      (apply original arguments)
    (condition-case nil
        (let ((coding-system-for-read 'utf-8))
          (apply original arguments))
      (file-error
       (let ((ls-lisp-use-insert-directory-program nil))
         (apply original arguments))))))

(defun zr-windows--dired-command (arguments)
  "Translate a trailing Dired sequencing marker for Windows start /wait."
  (if (file-remote-p default-directory)
      arguments
    (cons (replace-regexp-in-string ";[ \t]*\\(&?[ \t]*\\)\\'" "\\1"
                                    (if (string-match-p ";[ \t]*&?[ \t]*\\'"
                                                        (car arguments))
                                        (concat "/wait " (car arguments))
                                      (car arguments)))
          (cdr arguments))))

(defun zr-windows--armor (text)
  "Normalize armored GPG line endings without changing binary ciphertext."
  (if (string-prefix-p "-----BEGIN PGP" text)
      (string-replace "\r\n" "\n" text)
    text))

(defun zr-windows--git-help (arguments)
  "Use git subcommand -h instead of its GUI help viewer."
  (let ((command (car arguments)))
    (if (and (listp command) (equal (file-name-base (car command)) "git")
             (equal (cadr command) "help") (nth 2 command)
             (not (string-prefix-p "-" (nth 2 command))))
        (cons (list (car command) (nth 2 command) "-h") (cdr arguments))
      arguments)))

(defconst zr-windows--advices
  '((shell-command-on-region :around zr-windows--shell-command)
    (org-babel--shell-command-on-region :around zr-windows--babel-command)
    (insert-directory :around zr-windows--insert-directory)
    (dired-shell-stuff-it :filter-args zr-windows--dired-command)
    (epg-encrypt-string :filter-return zr-windows--armor)
    (pcomplete-from-help :filter-args zr-windows--git-help)))

(define-minor-mode zr-windows-encoding-mode
  "Enable Windows command coding and narrowly scoped tool adaptations."
  :global t
  (when zr-windows-encoding-mode
    (unless (eq system-type 'windows-nt)
      (setq zr-windows-encoding-mode nil)
      (user-error "Requires Windows")))
  (dolist (entry zr-windows--advices)
    (if zr-windows-encoding-mode
        (advice-add (car entry) (cadr entry) (nth 2 entry))
      (advice-remove (car entry) (nth 2 entry))))
  (dolist (hook '(compilation-start-hook eshell-exec-hook))
    (if zr-windows-encoding-mode
        (add-hook hook #'zr-windows-process-coding)
      (remove-hook hook #'zr-windows-process-coding))))

(defun zr-windows-shell-setup ()
  "Use command-specific input coding in a local cmdproxy Shell buffer."
  (when (and zr-windows-encoding-mode (not (file-remote-p default-directory))
             (string-match-p "cmdproxy" (or explicit-shell-file-name shell-file-name)))
    (setq-local comint-process-echoes t
                comint-input-sender (lambda (process input)
                                      (zr-windows-process-coding process input)
                                      (comint-simple-send process input)))))

(defun zr-windows-ime-close (&optional window)
  "Close the IME for focused windows using `zr-windows-ime-mode'.
When WINDOW is supplied by a buffer-local window hook, act only if it
is its frame's selected window.  Otherwise inspect all frames, since
focus notifications can run with an unrelated current buffer or frame."
  (when (and (eq system-type 'windows-nt)
             (fboundp 'w32-set-ime-open-status)
             (or (null window) (window-live-p window)))
    (dolist (frame (if window (list (window-frame window)) (frame-list)))
      (let ((selected (frame-selected-window frame)))
        (when (and (or (null window) (eq window selected))
                   (eq (frame-focus-state frame) t)
                   (buffer-local-value 'zr-windows-ime-mode (window-buffer selected)))
          (with-selected-window selected
            (w32-set-ime-open-status nil)))))))

(defun zr-windows--ime-cleanup ()
  "Remove the shared focus callback after its last buffer is gone."
  (unless (cl-some (lambda (buffer)
                     (and (not (eq buffer (current-buffer)))
                          (buffer-local-value 'zr-windows-ime-mode buffer)))
                   (buffer-list))
    (remove-function after-focus-change-function #'zr-windows-ime-close)))

(defun zr-windows--ime-disable ()
  "Remove IME callbacks before changing major modes."
  (zr-windows-ime-mode -1))

(define-minor-mode zr-windows-ime-mode
  "Keep the Windows IME closed while this buffer's window has focus.
Only the selected window of a frame known to have focus is affected.
Requires Windows with `w32-set-ime-open-status' support.
Use `zr-windows-quit-ime-buffers' to hide all buffers using this mode."
  :lighter " IME-"
  (if zr-windows-ime-mode
      (progn
        (unless (and (eq system-type 'windows-nt) (fboundp 'w32-set-ime-open-status))
          (setq zr-windows-ime-mode nil)
          (user-error "Requires Windows with IME support"))
        (add-function :after after-focus-change-function #'zr-windows-ime-close)
        (add-hook 'window-selection-change-functions #'zr-windows-ime-close nil t)
        (add-hook 'window-buffer-change-functions #'zr-windows-ime-close nil t)
        (add-hook 'kill-buffer-hook #'zr-windows--ime-cleanup nil t)
        (add-hook 'change-major-mode-hook #'zr-windows--ime-disable nil t)
        (zr-windows-ime-close))
    (remove-hook 'window-selection-change-functions #'zr-windows-ime-close t)
    (remove-hook 'window-buffer-change-functions #'zr-windows-ime-close t)
    (remove-hook 'kill-buffer-hook #'zr-windows--ime-cleanup t)
    (remove-hook 'change-major-mode-hook #'zr-windows--ime-disable t)
    (zr-windows--ime-cleanup)))

(defun zr-windows-quit-ime-buffers ()
  "Quit windows on all frames displaying buffers with `zr-windows-ime-mode'.
The buffers remain alive with the mode enabled."
  (interactive)
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'zr-windows-ime-mode buffer)
      (quit-windows-on buffer))))

(defun zr-windows-self-extract (file output)
  "Package FILE into a self-extracting cabinet executable OUTPUT."
  (interactive "fInput file: \nFSelf-extracting executable: ")
  (zr-windows--require)
  (let ((stub (or (executable-find "extrac32") (user-error "extrac32 is unavailable")))
        (cabinet (make-temp-file "zr-cab-" nil ".cab")))
    (unwind-protect
        (progn
          (unless (eq 0 (call-process "makecab" nil nil nil (expand-file-name file) cabinet))
            (error "makecab failed"))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally stub)
            (goto-char (point-max))
            (insert-file-contents-literally cabinet)
            (let ((coding-system-for-write 'no-conversion))
              (write-region (point-min) (point-max) output))))
      (when (file-exists-p cabinet)
        (delete-file cabinet)))))

(provide 'zr-windows)
;;; zr-windows.el ends here
