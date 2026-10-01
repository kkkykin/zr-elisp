;;; zr-pcmpl.el --- Optional command completions -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Source: ../emacs.d/user-lisp/init-pcmpl.el (selected functionality).

;;; Commentary:

;; `zr-pcmpl-mode' registers 7z/7zz, adb and fd, restoring previous definitions
;; on disable.  Executables are only queried during completion.

;;; Code:

(require 'cl-lib)
(require 'pcomplete)
(require 'subr-x)

(defgroup zr-pcmpl nil
  "Command completion."
  :group 'pcomplete)

(defcustom zr-pcmpl-archive-program "7z"
  "7z-compatible executable."
  :type 'string)

(defcustom zr-pcmpl-adb-program "adb"
  "ADB executable."
  :type 'string)

(defvar zr-pcmpl--saved nil)

(defun zr-pcmpl--lines (program &rest arguments)
  "Return PROGRAM output lines, or nil when unavailable or unsuccessful."
  (when (executable-find program)
    (with-temp-buffer
      (when (eq 0 (apply #'process-file program nil (list t nil) nil arguments))
        (split-string (buffer-string) "\n" t)))))

(defun zr-pcmpl--help (program &rest options)
  "Read PROGRAM's help using pcomplete's cache and parsing OPTIONS."
  (when (executable-find program)
    (apply #'pcomplete-from-help (list program "--help") options)))

(defun zr-pcmpl--archive-members (archive)
  "List archive members without permitting an interactive password prompt."
  (when (file-regular-p archive)
    (let ((password (or (cl-find-if (lambda (arg)
                                      (string-prefix-p "-p" arg))
                                    pcomplete-args)
                        "-p-"))
          started
          members)
      (dolist (line
               (zr-pcmpl--lines zr-pcmpl-archive-program "l" "-slt" password "--" archive))
        (cond
         ((string-prefix-p "----------" line)
          (setq started t))
         ((and started (string-prefix-p "Path = " line))
          (push (substring line 7) members))))
      (nreverse members))))

(defun zr-pcmpl-7z ()
  "Complete 7z commands, switches, paths and archive members."
  (pcomplete-here*
   (or (zr-pcmpl--help zr-pcmpl-archive-program :argument "[[:alpha:]]+")
       '("a" "b" "d" "e" "h" "i" "l" "rn" "t" "u" "x")))
  (let ((command (pcomplete-arg 1))
        archive
        (switches t))
    (while t
      (let ((argument (pcomplete-arg)))
        (cond
         ((and switches (equal argument "--"))
          (pcomplete-here* '("--"))
          (setq switches nil))
         ((and switches (string-prefix-p "-o" argument))
          (pcomplete-here* (pcomplete-dirs) (substring argument 2)))
         ((and switches (string-prefix-p "-" argument))
          (pcomplete-here*
           (or (zr-pcmpl--help zr-pcmpl-archive-program)
               '("-o" "-p" "-y" "-r" "-t7z" "-tzip" "-mx=9" "-aoa" "-aos" "-so" "-si"))))
         (t
          (pcomplete-here*
           (if (and archive (member command '("d" "e" "rn" "u" "x")))
               (completion-table-merge (pcomplete-entries)
                                       (zr-pcmpl--archive-members archive))
             (pcomplete-entries)))
          (unless archive
            (setq archive argument))))))))

(defun zr-pcmpl--adb-paths (options prefix)
  "List remote paths starting with PREFIX on the device selected by OPTIONS."
  ;; ADB joins these arguments for the Android shell, regardless of host OS.
  (apply #'zr-pcmpl--lines zr-pcmpl-adb-program
         (append options
                 (list "shell" "-nT" "ls" "-d1p" "--"
                       (concat "'" (string-replace "'" "'\\''" prefix) "'*")))))

(defun zr-pcmpl-adb ()
  "Complete ADB device selection, commands, installation and pull paths."
  (let (options)
    (while (string-prefix-p "-" (pcomplete-arg))
      (let ((option (pcomplete-arg)))
        (pcomplete-here* '("-s" "-d" "-e" "-t" "-H" "-P" "-L" "-a"))
        (setq options (append options (list option)))
        (when (member option '("-s" "-t" "-H" "-P" "-L"))
          (let ((value (pcomplete-arg)))
            (pcomplete-here*
             (when (equal option "-s")
               (mapcar (lambda (line)
                         (car (split-string line)))
                       (cdr (zr-pcmpl--lines zr-pcmpl-adb-program "devices")))))
            (setq options (append options (list value)))))))
    (pcomplete-here*
     (or (zr-pcmpl--help zr-pcmpl-adb-program :margin "^\\( \\)[a-z]"
                         :argument "[[:alpha:]-]+")
         '("devices" "shell" "push" "pull" "install" "install-multiple"
           "install-multi-package" "uninstall" "logcat" "connect" "disconnect"
           "start-server" "kill-server" "reboot" "forward" "reverse")))
    (let ((command (pcomplete-arg 1))
          (operand 0))
      (while t
        (let ((argument (pcomplete-arg)))
          (cond
           ((string-prefix-p "-" argument)
            (pcomplete-here*
             (or (zr-pcmpl--help zr-pcmpl-adb-program
                                 :argument "'?\\(--?[[:alpha:]-]+\\)'?[ :]"
                                 :narrow-start (concat "^ " (regexp-quote command) " ")
                                 :narrow-end "^ [[:alpha:]-]+ ")
                 '("-r" "-t" "-d" "-g" "-a" "--no-streaming" "--fastdeploy" "--abi"))))
           (t
            (pcomplete-here*
             (cond
              ((string-prefix-p "install" command)
               (pcomplete-dirs-or-entries "\\.apks?\\'"))
              ((and (equal command "pull") (zerop operand))
               (zr-pcmpl--adb-paths options argument))
              (t
               (pcomplete-entries))))
            (cl-incf operand))))))))

(defun zr-pcmpl-fd ()
  "Complete fd using its help output."
  (when (executable-find "fd")
    (pcomplete-here-using-help '("fd" "--help"))))

(define-minor-mode zr-pcmpl-mode
  "Register the additional pcomplete handlers."
  :global t
  :group 'zr-pcmpl
  (if zr-pcmpl-mode
      (unless zr-pcmpl--saved
        (dolist (entry '((pcomplete/7z . zr-pcmpl-7z) (pcomplete/7zz . zr-pcmpl-7z)
                         (pcomplete/adb . zr-pcmpl-adb) (pcomplete/fd . zr-pcmpl-fd)))
          (push
           (list (car entry) (and (fboundp (car entry)) (symbol-function (car entry)))
                 (cdr entry))
           zr-pcmpl--saved)
          (defalias (car entry) (cdr entry))))
    (dolist (entry zr-pcmpl--saved)
      (when (eq (symbol-function (car entry)) (nth 2 entry))
        (if (cadr entry)
            (fset (car entry) (cadr entry))
          (fmakunbound (car entry)))))
    (setq zr-pcmpl--saved nil)))

(provide 'zr-pcmpl)
;;; zr-pcmpl.el ends here
