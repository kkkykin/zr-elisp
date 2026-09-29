;;; zr-viper.el --- Independent Viper commands -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-viper.el (selected functionality).
;;; Commentary:
;; Loading does not load or enable Viper.  Bind the commands in personal init.el.
;;; Code:
(require 'cl-lib)
(require 'display-line-numbers)
(defvar ex-token-alist)
(declare-function viper-ex "viper-ex")
(declare-function ex-write "viper-ex")
(declare-function viper-exec-key-in-emacs "viper-cmd")
(declare-function org-table-fedit-finish "org-table")
(autoload 'zr-org-babel-save-source "zr-org-babel")
(defgroup zr-viper nil "Viper helper commands." :group 'emulations)
(defcustom zr-viper-ex-commands nil
  "Additional Ex tokens, as (NAME FORM) entries." :type '(repeat (list string sexp)))
(defun zr-viper-ex (&optional argument)
  "Read an Ex command with temporary line numbers and extra tokens.
ARGUMENT is passed to Viper."
  (interactive "P")
  (require 'viper-ex)
  (let ((ex-token-alist (append zr-viper-ex-commands ex-token-alist))
        (buffer (current-buffer)) (enabled display-line-numbers-mode))
    (unwind-protect
        (progn (display-line-numbers-mode 1) (viper-ex argument))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (display-line-numbers-mode (if enabled 1 -1)))))))
(defun zr-viper-dired-ex (&optional argument)
  "Use normal Emacs input in Wdired, otherwise read Ex with ARGUMENT."
  (interactive "P")
  (if (derived-mode-p 'wdired-mode)
      (progn (require 'viper-cmd) (viper-exec-key-in-emacs argument))
    (zr-viper-ex argument)))
(defun zr-viper-save (&optional argument)
  "Save Org source/formula edits appropriately, otherwise perform Ex write."
  (interactive "P")
  (cond ((bound-and-true-p org-src-mode) (zr-org-babel-save-source))
        ((equal (buffer-name) "*Edit Formulas*")
         (require 'org-table) (org-table-fedit-finish argument))
        (t (require 'viper-ex) (ex-write nil))))
(provide 'zr-viper)
;;; zr-viper.el ends here
