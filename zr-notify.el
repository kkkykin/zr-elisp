;;; zr-notify.el --- System notifications and appointments -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).

;;; Commentary:

;; Set appt-disp-window-function to `zr-notify-appointment' to opt in.
;; Reminder schedules remain personal configuration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(autoload 'zr-termux-notify "zr-termux")
(declare-function notifications-notify "notifications")
(declare-function android-notifications-notify "androidselect.c")
(declare-function w32-notification-notify "w32fns.c")
(declare-function w32-notification-close "w32fns.c")
(declare-function appt-add "appt")

(defgroup zr-notify nil
  "System notification adapters."
  :group 'applications)

(defcustom zr-notify-function nil
  "Optional notification function accepting TITLE, BODY and keyword arguments."
  :type '(choice (const nil) function))

(defvar zr-notify--windows-timers (make-hash-table :test #'equal))

(defun zr-notify-send (title body &rest options)
  "Send TITLE and BODY with OPTIONS.  Timeout values are milliseconds."
  (if zr-notify-function
      (apply zr-notify-function title body options)
    (pcase system-type
      ('android
       (if (fboundp 'android-notifications-notify)
           (apply #'android-notifications-notify :title title :body body options)
         (apply #'zr-termux-notify title body options)))
      ('windows-nt
       (unless (fboundp 'w32-notification-notify)
         (user-error "This Emacs build has no Windows notification support"))
       (let* ((id (apply #'w32-notification-notify :title title :body body options))
              (timeout (plist-get options :timeout)))
         (when-let* ((timer (gethash id zr-notify--windows-timers)))
           (cancel-timer timer))
         (remhash id zr-notify--windows-timers)
         (when (and (numberp timeout) (> timeout 0))
           (puthash id (run-at-time (/ timeout 1000.0) nil
                                    (lambda ()
                                      (remhash id zr-notify--windows-timers)
                                      (w32-notification-close id)))
                    zr-notify--windows-timers))
         id))
      (_
       (require 'notifications)
       (apply #'notifications-notify :title title :body body options)))))

(defun zr-notify-appointment (minutes _time message)
  "Display appointment MESSAGE due in MINUTES; suitable for appt."
  (zr-notify-send (format "In %s minutes" (if (listp minutes)
                                              (string-join minutes ", ")
                                            minutes))
                  (if (listp message)
                      (string-join message "\n")
                    message)
                  :urgency 'critical :replaces-id 100 :timeout 0))

(defun zr-notify-add-reminders (reminders)
  "Add REMINDERS, a list of (TIME MESSAGE WARNING-MINUTES) entries, to appt."
  (require 'appt)
  (dolist (reminder reminders)
    (apply #'appt-add reminder)))

(provide 'zr-notify)
;;; zr-notify.el ends here
