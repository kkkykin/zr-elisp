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

(defgroup zr-android nil
  "Android helpers."
  :group 'environment)

(defcustom zr-android-adb-program "adb"
  "ADB executable on the host."
  :type 'string)

(defcustom zr-android-small-screen-height 260
  "Height at which to prefer a menu bar."
  :type 'natnum)

(defvar touch-screen-display-keyboard)

(defvar modifier-bar-mode)

(defvar secondary-tool-bar-map)
(declare-function modifier-bar-mode "tool-bar")
(declare-function tool-bar--flush-cache "tool-bar")
(declare-function tool-bar--image-expression "tool-bar")
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
  (unless (executable-find zr-android-adb-program)
    (user-error "ADB is unavailable"))
  (unless (member action '("start-activity" "force-stop"))
    (user-error "Unsupported AM action"))
  ;; ADB invokes the device shell even when the host is Windows.
  (unless (eq 0 (call-process zr-android-adb-program nil nil nil "shell" "am" action
                              (concat "'" (string-replace "'" "'\\''" target) "'")))
    (error "ADB activity command failed")))

(defun zr-android-activity (&rest arguments)
  "Run Android's am with ARGUMENTS."
  (unless (eq system-type 'android)
    (user-error "Requires Android"))
  (unless (eq 0 (apply #'call-process "am" nil nil nil arguments))
    (error "Activity command failed")))

(defun zr-android-fooview (workflow)
  "Run the named FooView WORKFLOW."
  (interactive "sWorkflow: ")
  (zr-android-activity "start" "-a" "com.fooview.android.intent.RUN_WORKFLOW"
                       "com.fooview.android.fooview/.ShortcutProxyActivity" "-e"
                       "action" workflow))

(defun zr-android-small-screen-setup (&rest _)
  "Adapt the menu and modifier bars to the focused frame's height."
  (zr-android--gui)
  (when (frame-focus-state)
    (let ((small (<= (display-pixel-height) zr-android-small-screen-height)))
      (menu-bar-mode (if small
                         1
                       -1))
      (modifier-bar-mode (if small
                             -1
                           1)))))

(defun zr-android-toggle-keyboard ()
  "Toggle the Android on-screen keyboard."
  (interactive)
  (zr-android--gui)
  (setq touch-screen-display-keyboard (not touch-screen-display-keyboard))
  (frame-toggle-on-screen-keyboard nil touch-screen-display-keyboard))

(defun zr-android--prefix (key)
  "Return a toolbar translation function for KEY."
  (lambda (_event)
    (unless (equal key "C-g")
      (frame-toggle-on-screen-keyboard nil nil))
    (vconcat (kbd key))))

(defun zr-android--toolbar ()
  "Install this module's toolbar entries once per modifier bar rebuild."
  (when (and modifier-bar-mode secondary-tool-bar-map)
    (let ((prefix-entries '((zr-quit "C-g" "C-g" "symbols/cross_16")
                            (zr-meta "Meta" "ESC" "meta")
                            (zr-cx "C-x" "C-x" "symbols/plus_16")
                            (zr-cc "C-c" "C-c" "symbols/menu_16")
                            (zr-help "Help" "C-h" "symbols/heart_16")
                            (zr-cu "C-u" "C-u" "symbols/star_16")))
          (command-entries '((zr-keyboard "Keyboard" zr-android-toggle-keyboard "conceal")
                             (zr-repeat "Repeat" repeat "symbols/dot_small_16")
                             (zr-read-only "Read only" read-only-mode "reveal"))))
      (dolist (entry prefix-entries)
        (define-key input-decode-map (vector 'tool-bar (car entry))
                    (zr-android--prefix (nth 2 entry))))
      (let* ((items (append
                     (mapcar (lambda (entry)
                               `(,(car entry) menu-item ,(cadr entry) ignore :help ,(cadr entry)
                                 :image ,(tool-bar--image-expression (nth 3 entry))))
                             prefix-entries)
                     (mapcar (lambda (entry)
                               `(,(car entry) menu-item ,(cadr entry) ,(nth 2 entry) :help ,(cadr entry)
                                 :image ,(tool-bar--image-expression (nth 3 entry))))
                             command-entries)))
             (keys (mapcar #'car items)))
        (setcdr secondary-tool-bar-map
                (append (cl-remove-if (lambda (item) (memq (car-safe item) keys))
                                      (cdr secondary-tool-bar-map))
                        items))))
    (tool-bar--flush-cache)
    (force-mode-line-update t)))

(defun zr-android--modifier-bar-changed ()
  "Save the current modifier bar state before extending it."
  (when zr-android--saved-toolbar
    ;; Keep native decoder changes, but remove our translations from the snapshot.
    (dolist (key '(zr-quit zr-meta zr-cx zr-cc zr-help zr-cu))
      (let* ((event (vector 'tool-bar key))
             (binding (lookup-key (cadr zr-android--saved-toolbar) event)))
        (define-key input-decode-map event
                    (unless (numberp binding) binding)))))
  (setq zr-android--saved-toolbar (list secondary-tool-bar-map input-decode-map))
  (setq secondary-tool-bar-map (and secondary-tool-bar-map
                                    (copy-keymap secondary-tool-bar-map))
        input-decode-map (copy-keymap input-decode-map))
  (zr-android--toolbar))

(define-minor-mode zr-android-toolbar-mode
  "Extend the Android modifier bar, preserving its current state on disable."
  :global t
  (if zr-android-toolbar-mode
      (progn
        (condition-case err (zr-android--gui)
          (error
           (setq zr-android-toolbar-mode nil)
           (signal (car err) (cdr err))))
        (require 'tool-bar)
        (add-hook 'modifier-bar-mode-hook #'zr-android--modifier-bar-changed)
        (if zr-android--saved-toolbar
            (zr-android--toolbar)
          (zr-android--modifier-bar-changed)))
    (remove-hook 'modifier-bar-mode-hook #'zr-android--modifier-bar-changed)
    (when zr-android--saved-toolbar
      (tool-bar--flush-cache)
      (setq secondary-tool-bar-map (car zr-android--saved-toolbar)
            input-decode-map (cadr zr-android--saved-toolbar)
            zr-android--saved-toolbar nil)
      (force-mode-line-update t))))

(provide 'zr-android)
;;; zr-android.el ends here
