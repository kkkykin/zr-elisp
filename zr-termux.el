;;; zr-termux.el --- Termux API clients and connection profiles -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-android.el (selected functionality).
;;; Commentary:
;; Explicit API calls only.  There is no service or Wi-Fi automation.
;; Notification timeout units match notifications.el: milliseconds.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(defgroup zr-termux nil "Termux integration." :group 'external)
(defcustom zr-termux-root "/data/data/com.termux/files/" "Termux files directory." :type 'directory)
(defvar zr-termux--notification-timers (make-hash-table :test #'equal))
(defvar zr-termux--notification-counter 0)
(defun zr-termux--call (program &rest arguments)
  "Run PROGRAM with stringified ARGUMENTS and return its output."
  (unless (executable-find program) (user-error "%s is unavailable" program))
  (with-temp-buffer
    (let ((status (apply #'process-file program nil (list t nil) nil
                         (mapcar (lambda (arg) (format "%s" arg)) arguments))))
      (unless (eq status 0) (error "%s failed (%s)" program status)))
    (buffer-string)))
(defun zr-termux-battery ()
  "Return battery status as a JSON object."
  (json-parse-string (zr-termux--call "termux-battery-status")))
(defun zr-termux-notifications ()
  "Return current Termux notifications as JSON."
  (json-parse-string (zr-termux--call "termux-notification-list")))
(defun zr-termux-wifi-info (&optional key)
  "Return Wi-Fi connection details, or KEY from the JSON object."
  (let ((data (json-parse-string (zr-termux--call "termux-wifi-connectioninfo"))))
    (if key (gethash key data) data)))
(defun zr-termux-wifi-scan (&optional key)
  "Return nearby Wi-Fi information, or a list of KEY values."
  (let ((data (json-parse-string (zr-termux--call "termux-wifi-scaninfo"))))
    (if key (mapcar (lambda (entry) (gethash key entry)) data) data)))
(defun zr-termux-toast (text &optional background foreground gravity short)
  "Show TEXT with optional BACKGROUND, FOREGROUND, GRAVITY and SHORT duration."
  (interactive "sToast: ")
  (apply #'zr-termux--call "termux-toast" "-b" (or background "gray")
         "-c" (or foreground "white") "-g" (or gravity "middle")
         (append (when short '("-s")) (list text))))
(defun zr-termux--notification-arguments (title body options)
  "Translate notification TITLE, BODY and OPTIONS to CLI arguments."
  (let ((arguments (list "--title" title "--content" body)))
    (dolist (entry '((:replaces-id . "--id") (:app-icon . "--icon") (:image-path . "--image-path")
                     (:category . "--type") (:led-color . "--led-color") (:led-on . "--led-on")
                     (:led-off . "--led-off") (:group . "--group") (:channel . "--channel")
                     (:action . "--action") (:on-close . "--on-delete")))
      (when-let* ((value (plist-get options (car entry))))
        (unless (or (stringp value) (numberp value)) (user-error "%s requires a string or number" (car entry)))
        (setq arguments (append arguments (list (cdr entry) (format "%s" value))))))
    (when-let* ((urgency (plist-get options :urgency)))
      (setq arguments (append arguments (list "--priority"
                                             (pcase urgency ('critical "high") ('low "low") (_ "default"))))))
    (unless (plist-get options :suppress-sound) (setq arguments (append arguments '("--sound"))))
    (dolist (entry '((:ongoing . "--ongoing") (:alert-once . "--alert-once")))
      (when (plist-get options (car entry)) (setq arguments (append arguments (list (cdr entry))))))
    (let ((actions (plist-get options :actions)) (index 1))
      (unless (zerop (% (length actions) 2)) (user-error "Actions must be label/command pairs"))
      (while (and actions (<= index 3))
        (let ((label (pop actions)) (command (pop actions)))
          (unless (and (stringp label) (stringp command)) (user-error "Termux actions require shell command strings"))
          (setq arguments (append arguments (list (format "--button%d" index) label
                                                  (format "--button%d-action" index) command))))
        (setq index (1+ index))))
    arguments))
(defun zr-termux-notify (title body &rest options)
  "Send TITLE and BODY with notification OPTIONS; return the notification ID.
Use :replaces-id for replacement, :timeout in milliseconds, and :actions
as label/shell-command pairs.  Termux cannot run Lisp action callbacks."
  (let* ((id (format "%s" (or (plist-get options :replaces-id)
                              (format "zr-%s-%s" (emacs-pid) (cl-incf zr-termux--notification-counter)))))
         (options (plist-put (copy-sequence options) :replaces-id id))
         (timeout (plist-get options :timeout)))
    (apply #'zr-termux--call "termux-notification" (zr-termux--notification-arguments title body options))
    (when-let* ((timer (gethash id zr-termux--notification-timers))) (cancel-timer timer))
    (remhash id zr-termux--notification-timers)
    (when (and (numberp timeout) (> timeout 0))
      (puthash id (run-at-time (/ timeout 1000.0) nil
                              (lambda ()
                                (remhash id zr-termux--notification-timers)
                                (zr-termux--call "termux-notification-remove" id)))
               zr-termux--notification-timers))
    id))
(defun zr-termux-configure-tramp (criteria)
  "Assign Termux paths to the connection-local CRITERIA plist.
For example (:application tramp :protocol \"sshx\" :machine \"phone\")."
  (require 'tramp)
  (connection-local-set-profile-variables
   'zr-termux
   `((tramp-remote-path . (,(file-name-concat zr-termux-root "usr/bin") tramp-default-remote-path))
     (tramp-remote-shell . ,(file-name-concat zr-termux-root "usr/bin/sh"))
     (tramp-tmpdir . ,(file-name-concat zr-termux-root "usr/tmp"))
     (explicit-shell-file-name . ,(file-name-concat zr-termux-root "usr/bin/bash"))))
  (connection-local-set-profiles criteria 'zr-termux))
(provide 'zr-termux)
;;; zr-termux.el ends here
