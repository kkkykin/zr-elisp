;;; zr-org-link.el --- Dictionary and terminal links -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).

;;; Commentary:

;; Enable dictionary links explicitly.  WezTerm opening is an independent helper.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'url-util)
(require 'subr-x)
(require 'zr-dictionary)
(autoload 'zr-wezterm-send-json "zr-wezterm")
(declare-function org-html-encode-plain-text "ox-html")
(declare-function org-latex-plain-text "ox-latex")
(declare-function org-texinfo-plain-text "ox-texinfo")

(defgroup zr-org-link nil
  "Additional Org links."
  :group 'org-link)

(defcustom zr-org-link-translation-language "zh-CN"
  "Translation target language."
  :type 'string)

(defvar zr-org-link--saved nil)

(defcustom zr-org-link-dict-include-server nil
  "Whether generated dict links include resolved server addresses and ports.
Nil keeps links compact and uses the defaults when a link is followed.
Non-nil preserves the original endpoints, including cross-server groups."
  :type 'boolean
  :group 'zr-org-link)

(defun zr-org-link-open-wezterm (url)
  "Open URL through the configured WezTerm transport."
  (interactive "sURL: ")
  (zr-wezterm-send-json `((type . "open_uri") (uri . ,url))))

(defun zr-org-link-open-at-point ()
  "Open an HTTP link at point through WezTerm in an SSH session.
Check both frame and process environments.  Also recognize Org links
outside Org mode.
Suitable for `org-open-at-point-functions'; return nil for other links."
  (when (or (getenv "SSH_CONNECTION" (selected-frame))
            (getenv "SSH_CLIENT" (selected-frame))
            (getenv "SSH_CONNECTION")
            (getenv "SSH_CLIENT"))
    (let* ((element
            (if (derived-mode-p 'org-mode)
                (org-element-context)
              (when (org-in-regexp org-link-any-re)
                (let ((link (match-string-no-properties 0)))
                  (with-temp-buffer
                    (insert link)
                    (delay-mode-hooks (org-mode))
                    (goto-char (point-min))
                    (org-element-link-parser))))))
           (type (org-element-property :type element)))
      (when (and (eq (org-element-type element) 'link) (member type '("http" "https")))
        (zr-org-link-open-wezterm (org-element-property :raw-link element))
        t))))

(defun zr-org-link--dict-with-proxy (dictionaries proxy)
  "Copy DICTIONARIES, overriding every target's proxy with PROXY."
  (unless (zr-dictionary-dictionaries-p dictionaries)
    (user-error "Invalid dictionary stages: %S" dictionaries))
  (unless (zr-dictionary-dictionaries-p (list (list :dictionary t :proxy proxy)))
    (user-error "Invalid dictionary proxy: %S" proxy))
  (let ((override (lambda (target) (plist-put (copy-sequence target) :proxy proxy))))
    (mapcar (lambda (stage)
              (cond ((eq stage 'similar) stage)
                    ((keywordp (car stage)) (funcall override stage))
                    (t (mapcar override stage)))) dictionaries)))

(cl-defun zr-org-link--dict-path (word dictionaries strategy &optional (proxy nil proxy-p))
  "Return a dict path for WORD, DICTIONARIES and STRATEGY.
Include a separate proxy parameter only when PROXY is explicitly supplied."
  (let* ((resolved (zr-dictionary-resolve-dictionaries
                    (zr-org-link--dict-with-proxy dictionaries (if proxy-p proxy nil))))
         (stages (mapcar
                  (lambda (stage)
                    (if (eq stage 'similar) stage
                      (mapcar (lambda (target)
                                (append (when zr-org-link-dict-include-server
                                          (list :server (plist-get target :server)
                                                :port (plist-get target :port)))
                                        (list :dictionary (plist-get target :dictionary)))) stage))) resolved)))
    (concat "dict:" (url-hexify-string word)
            "?dictionaries=" (url-hexify-string (prin1-to-string stages))
            "&strategy=" (url-hexify-string strategy)
            (when proxy-p
              (concat "&proxy=" (url-hexify-string (if (stringp proxy) proxy (symbol-name proxy))))))))

(cl-defun zr-org-link-dict-link
    (word &optional (dictionaries zr-dictionary-dictionaries)
          (strategy zr-dictionary-strategy) (proxy nil proxy-p))
  "Return a dict link for WORD with DICTIONARIES and matching STRATEGY.
Encode stages as a Lisp list in the dictionaries query parameter.
An explicit PROXY adds a separate proxy parameter overriding every target:
a HOST:PORT string, nil for direct connections, or t for global proxy settings.
Omitting PROXY leaves proxy configuration out of the generated link."
  (org-link-make-string (if proxy-p
                           (zr-org-link--dict-path word dictionaries strategy proxy)
                         (zr-org-link--dict-path word dictionaries strategy)) word))

(defun zr-org-link--dict-query (path)
  "Parse dict link PATH as (WORD DICTIONARIES STRATEGY).
Missing query parameters use the current buffer's dictionary configuration.
A proxy parameter overrides all targets after dictionaries have been parsed."
  (let* ((parts (split-string path "?"))
         (word (decode-coding-string (url-unhex-string (car parts)) 'utf-8))
         (dictionaries zr-dictionary-dictionaries)
         (strategy zr-dictionary-strategy)
         proxy proxy-p)
    (unless (<= (length parts) 2)
      (user-error "Invalid dict link: %s" path))
    (dolist (parameter (split-string (or (cadr parts) "") "&" t))
      (unless (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" parameter)
        (user-error "Invalid dict link parameter: %s" parameter))
      (let ((key (match-string 1 parameter))
            (value (decode-coding-string (url-unhex-string (match-string 2 parameter)) 'utf-8)))
        (pcase key
          ("dictionaries"
           (let ((parsed (read-from-string value)))
             (unless (string-blank-p (substring value (cdr parsed)))
               (user-error "Invalid dictionary stages: %s" value))
             (setq dictionaries (car parsed))))
          ("strategy" (setq strategy value))
          ("proxy" (setq proxy (pcase value ("nil" nil) ("t" t) (_ value)) proxy-p t))
          (_ (user-error "Unknown dict link parameter: %s" key)))))
    (list word (if proxy-p (zr-org-link--dict-with-proxy dictionaries proxy) dictionaries) strategy)))

(defun zr-org-link--follow (path _argument)
  "Look up the word and configuration in dict link PATH."
  (apply #'zr-dictionary-search (zr-org-link--dict-query path)))

(defun zr-org-link--translation-url (word)
  "Return a translation URL for WORD."
  (concat "https://translate.google.com/?sl=auto&tl="
          (url-hexify-string zr-org-link-translation-language) "&text="
          (url-hexify-string word) "&op=translate"))

(defun zr-org-link--export (path description backend _info)
  "Export dict link PATH and DESCRIPTION using BACKEND."
  (let* ((word (car (zr-org-link--dict-query path)))
         (url (zr-org-link--translation-url word))
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
  (when (and (derived-mode-p 'dictionary-mode) zr-dictionary-word)
    (let* ((word zr-dictionary-word)
           (link (zr-org-link--dict-path word zr-dictionary-dictionaries zr-dictionary-strategy)))
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
