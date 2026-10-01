;;; zr-org-link.el --- Dictionary and terminal links -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).

;;; Commentary:

;; Enable dictionary links explicitly.  WezTerm opening is an independent command.

;;; Code:

(require 'org)
(require 'org-element)
(require 'url-util)
(require 'subr-x)
(autoload 'zr-wezterm-send-json "zr-wezterm")
(declare-function dictionary-search "dictionary")
(declare-function org-html-encode-plain-text "ox-html")
(declare-function org-latex-plain-text "ox-latex")
(declare-function org-texinfo-plain-text "ox-texinfo")

(defvar dictionary-current-data)

(defgroup zr-org-link nil
  "Additional Org links."
  :group 'org-link)

(defcustom zr-org-link-translation-language "zh-CN"
  "Translation target language."
  :type 'string)

(defvar zr-org-link--saved nil)

(defun zr-org-link-open-wezterm (url)
  "Open URL through the configured WezTerm transport."
  (interactive "sURL: ")
  (zr-wezterm-send-json `((type . "open_uri") (uri . ,url))))

(defun zr-org-link-open-at-point ()
  "Open an HTTP link through WezTerm in an SSH frame.
Suitable for `org-open-at-point-functions'; return nil for other links."
  (when (getenv "SSH_CONNECTION" (selected-frame))
    (let* ((element (org-element-context))
           (type (org-element-property :type element)))
      (when (and (eq (org-element-type element) 'link) (member type '("http" "https")))
        (zr-org-link-open-wezterm (org-element-property :raw-link element))
        t))))

(defun zr-org-link--follow (word _argument)
  "Look up WORD in Dictionary."
  (require 'dictionary)
  (dictionary-search word))

(defun zr-org-link--translation-url (word)
  "Return a translation URL for WORD."
  (concat "https://translate.google.com/?sl=auto&tl="
          (url-hexify-string zr-org-link-translation-language) "&text="
          (url-hexify-string word) "&op=translate"))

(defun zr-org-link--export (word description backend _info)
  "Export WORD and DESCRIPTION using BACKEND."
  (let ((url (zr-org-link--translation-url word))
        (description (or description word)))
    (pcase backend
      ('html
       (require 'ox-html)
       (format "<a href=\"%s\">%s</a>" (org-html-encode-plain-text url)
               (org-html-encode-plain-text description)))
      ('latex
       (require 'ox-latex)
       (format "\\href{%s}{%s}" (org-latex-plain-text url nil)
               (org-latex-plain-text description nil)))
      ('texinfo
       (require 'ox-texinfo)
       (format "@uref{%s,%s}" (org-texinfo-plain-text url nil)
               (org-texinfo-plain-text description nil)))
      ('ascii
       (format "%s (%s)" description url))
      (_
       url))))

(defun zr-org-link--store (&optional _interactive)
  "Store the current Dictionary query as an Org link."
  (when (and (derived-mode-p 'dictionary-mode) (boundp 'dictionary-current-data)
             (eq (car-safe dictionary-current-data) 'dictionary-new-search-internal)
             (stringp (cadr dictionary-current-data)))
    (let* ((word (cadr dictionary-current-data))
           (link (concat "dict:" word)))
      (org-link-store-props :type "dict" :link link :description word)
      link)))

(define-minor-mode zr-org-link-mode
  "Register dict: links, restoring earlier handlers on disable."
  :global t
  (if zr-org-link-mode
      (unless zr-org-link--saved
        (setq zr-org-link--saved (list (copy-tree (assoc "dict" org-link-parameters))))
        (org-link-set-parameters "dict" :follow #'zr-org-link--follow :export
                                 #'zr-org-link--export :store #'zr-org-link--store))
    (when zr-org-link--saved
      (setq org-link-parameters (assoc-delete-all "dict" org-link-parameters))
      (when (car zr-org-link--saved)
        (push (car zr-org-link--saved) org-link-parameters))
      (setq zr-org-link--saved nil))))

(provide 'zr-org-link)
;;; zr-org-link.el ends here
