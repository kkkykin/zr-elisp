;;; zr-android.el --- Android application and display commands -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-android.el (selected functionality).
;;; Commentary:
;; GUI changes are opt-in.  ADB works from any host; there is no Rish dependency.
;;; Code:
(require 'cl-lib)
(defgroup zr-android nil "Android helpers." :group 'environment)
(defcustom zr-android-adb-program "adb" "ADB executable on the host." :type 'string)
(defcustom zr-android-small-screen-height 260 "Height at which to prefer a menu bar." :type 'natnum)
(defvar touch-screen-display-keyboard)
(defvar modifier-bar-mode)
(defvar secondary-tool-bar-map)
(declare-function modifier-bar-mode "tool-bar")
(declare-function frame-toggle-on-screen-keyboard "frame")
(defvar zr-android--saved-toolbar nil)
(defun zr-android--gui ()
  "Require an Android graphical display."
  (unless (and (eq system-type 'android) (display-graphic-p))
    (user-error "This command requires Android graphical Emacs")))
(defun zr-android-adb-activity (action target)
  "Use ADB to apply AM ACTION to an explicit activity or package TARGET."
  (interactive (list (completing-read "Action: " '("start-activity" "force-stop") nil t)
                     (read-string "Activity or package: ")))
  (unless (executable-find zr-android-adb-program) (user-error "ADB is unavailable"))
  (unless (member action '("start-activity" "force-stop")) (user-error "Unsupported AM action"))
  ;; ADB invokes the device shell even when the host is Windows.
  (unless (eq 0 (call-process zr-android-adb-program nil nil nil "shell" "am" action
                             (concat "'" (string-replace "'" "'\\''" target) "'")))
    (error "ADB activity command failed")))
(defun zr-android-activity (&rest arguments)
  "Run Android's am with ARGUMENTS."
  (unless (eq system-type 'android) (user-error "Requires Android"))
  (unless (eq 0 (apply #'call-process "am" nil nil nil arguments)) (error "Activity command failed")))
(defun zr-android-fooview (workflow)
  "Run the named FooView WORKFLOW."
  (interactive "sWorkflow: ")
  (zr-android-activity "start" "-a" "com.fooview.android.intent.RUN_WORKFLOW"
                       "com.fooview.android.fooview/.ShortcutProxyActivity" "-e" "action" workflow))
(defun zr-android-small-screen-setup (&rest _)
  "Adapt the menu and modifier bars to the focused frame's height."
  (zr-android--gui)
  (when (frame-focus-state)
    (let ((small (<= (display-pixel-height) zr-android-small-screen-height)))
      (menu-bar-mode (if small 1 -1))
      (modifier-bar-mode (if small -1 1)))))
(defun zr-android-toggle-keyboard ()
  "Toggle the Android on-screen keyboard."
  (interactive)
  (zr-android--gui)
  (setq touch-screen-display-keyboard (not touch-screen-display-keyboard))
  (frame-toggle-on-screen-keyboard nil touch-screen-display-keyboard))
(defun zr-android--prefix (key)
  "Return a toolbar translation function for KEY."
  (lambda (_event)
    (unless (equal key "C-g") (frame-toggle-on-screen-keyboard nil nil))
    (vconcat (kbd key))))
(defun zr-android--toolbar ()
  "Install this module's toolbar entries once per modifier bar rebuild."
  (when modifier-bar-mode
    (dolist (entry '((zr-quit "C-g" "C-g") (zr-meta "Meta" "ESC") (zr-cx "C-x" "C-x")
                     (zr-cc "C-c" "C-c") (zr-help "Help" "C-h") (zr-cu "C-u" "C-u")))
      (define-key secondary-tool-bar-map (vector (car entry))
                  `(menu-item ,(cadr entry) ignore :help ,(cadr entry)))
      (define-key input-decode-map (vector 'tool-bar (car entry)) (zr-android--prefix (nth 2 entry))))
    (define-key secondary-tool-bar-map [zr-keyboard] '(menu-item "Keyboard" zr-android-toggle-keyboard))
    (define-key secondary-tool-bar-map [zr-repeat] '(menu-item "Repeat" repeat))
    (define-key secondary-tool-bar-map [zr-read-only] '(menu-item "Read only" read-only-mode))))
(define-minor-mode zr-android-toolbar-mode
  "Extend the Android modifier bar.  Existing maps are restored on disable."
  :global t
  (if zr-android-toolbar-mode
      (progn
        (condition-case err (zr-android--gui)
          (error (setq zr-android-toolbar-mode nil) (signal (car err) (cdr err))))
        (unless zr-android--saved-toolbar
          (setq zr-android--saved-toolbar (list secondary-tool-bar-map input-decode-map))
          (setq secondary-tool-bar-map (copy-keymap secondary-tool-bar-map)
                input-decode-map (copy-keymap input-decode-map)))
        (add-hook 'modifier-bar-mode-hook #'zr-android--toolbar)
        (zr-android--toolbar))
    (remove-hook 'modifier-bar-mode-hook #'zr-android--toolbar)
    (when zr-android--saved-toolbar
      (setq secondary-tool-bar-map (car zr-android--saved-toolbar)
            input-decode-map (cadr zr-android--saved-toolbar)
            zr-android--saved-toolbar nil))))
(provide 'zr-android)
;;; zr-android.el ends here
