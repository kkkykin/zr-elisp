;;; zr-notify.el --- System notifications and appointments -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).

;;; Commentary:

;; Set appt-disp-window-function to `zr-notify-appointment' to opt in.
;; Reminder schedules remain personal configuration.
;; Set `zr-notify-function' to `zr-notify-terminal' for OSC 777 notifications.
;; Enable `zr-notify-mode' to route `notifications-notify' through this library.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(autoload 'zr-termux-notify "zr-termux")
(autoload 'zr-terminal-notify "zr-terminal")
(declare-function notifications-notify "notifications")
(declare-function android-notifications-notify "androidselect.c")
(declare-function w32-notification-notify "w32fns.c")
(declare-function w32-notification-close "w32fns.c")
(declare-function appt-add "appt")

(defgroup zr-notify nil
  "System notification adapters."
  :group 'applications)

(defcustom zr-notify-function nil
  "Optional notification function accepting TITLE, BODY and keyword arguments.
Use `zr-notify-terminal' to send OSC 777 notifications to a terminal frame."
  :type '(choice (const :tag "Platform default" nil)
                 (const :tag "Terminal (OSC 777)" zr-notify-terminal)
                 function))

(defvar zr-notify--windows-timers (make-hash-table :test #'equal))
(defvar zr-notify--terminal-warning-issued-p nil)

;;;###autoload
(defun zr-notify-terminal (title body &rest options)
  "Send TITLE and BODY through the OSC 777 terminal notification backend.
The :frame option selects a terminal frame, defaulting to the selected
frame.  Other OPTIONS are ignored; OSC 777 has no notification IDs,
timeouts, urgency levels or actions.  Return t after sending, or nil
when the target is not a live terminal frame.  Warn once per Emacs
session when skipping an unusable frame."
  (if-let* ((frame (or (plist-get options :frame) (selected-frame)))
            ((frame-live-p frame))
            ((not (display-graphic-p frame))))
      (zr-terminal-notify title body frame)
    (unless zr-notify--terminal-warning-issued-p
      (setq zr-notify--terminal-warning-issued-p t)
      (display-warning
       'zr-notify
       (concat "Skipping OSC notification: the target is not a live terminal frame. "
               "Set `zr-notify-function' to nil for platform notifications, "
               "or supply a terminal frame with :frame.")
       :warning))
    nil))

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
       ;; The native API requires closing the active notification first.
       (when-let* ((id (plist-get options :replaces-id)))
         (when-let* ((timer (gethash id zr-notify--windows-timers)))
           (cancel-timer timer))
         (remhash id zr-notify--windows-timers)
         (w32-notification-close id))
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

(defun zr-notify--notifications-notify (original &rest options)
  "Route notification OPTIONS to the configured backend or ORIGINAL."
  ;; Calling `zr-notify-send' for its D-Bus fallback would recurse here.
  (if (and (null zr-notify-function)
           (not (memq system-type '(android windows-nt))))
      (apply original options)
    (let* ((title (or (plist-get options :title) ""))
           (body (or (plist-get options :body) ""))
           (excluded '(:title :body :bus)))
      ;; Termux actions are shell commands, not the notification API's
      ;; action keys and Lisp callbacks.  Never reinterpret them as commands.
      (when (or (eq zr-notify-function #'zr-termux-notify)
                (and (null zr-notify-function)
                     (eq system-type 'android)
                     (not (fboundp 'android-notifications-notify))))
        (setq excluded (append excluded '(:actions :on-action :on-close))))
      (apply #'zr-notify-send title body
             (cl-loop for (key value) on options by #'cddr
                      unless (memq key excluded)
                      append (list key value))))))

;;;###autoload
(define-minor-mode zr-notify-mode
  "Route `notifications-notify' through `zr-notify-send' globally.
Use `zr-notify-function' when configured, or the native Android or Windows
backend.  Other systems retain the original D-Bus implementation by default.
Only options supported by the selected backend take effect.  Termux drops
notification actions and Lisp callbacks because its API uses shell commands.
This mode can be enabled before the notifications library is loaded."
  :global t
  :group 'zr-notify
  (if zr-notify-mode
      (advice-add 'notifications-notify :around #'zr-notify--notifications-notify)
    (advice-remove 'notifications-notify #'zr-notify--notifications-notify)))

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
