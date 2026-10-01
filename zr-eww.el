;;; zr-eww.el --- Optional EWW URL and rendering rules -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-net.el (selected functionality).

;;; Commentary:

;; Rules are empty by default; configure them before enabling `zr-eww-mode'.

;;; Code:

(require 'eww)
(require 'auth-source)
(require 'url-parse)

(defgroup zr-eww nil
  "EWW rules."
  :group 'eww)

(defcustom zr-eww-url-rules nil
  "Regexp replacement pairs applied to visited URLs."
  :type '(alist :key-type regexp :value-type string))

(defcustom zr-eww-auth-patterns nil
  "URL regexps allowed to use auth-source credentials."
  :type '(repeat regexp))

(defcustom zr-eww-readable-patterns nil
  "URL regexps requesting readable rendering."
  :type '(repeat regexp))

(defcustom zr-eww-content-modes nil
  "URL regexp to major-mode mappings."
  :type '(alist :key-type regexp :value-type function))

(defvar zr-eww--installed nil)

(defun zr-eww-transform-url (url)
  "Apply configured rewrite and authentication rules to URL."
  (dolist (rule zr-eww-url-rules)
    (setq url (replace-regexp-in-string (car rule) (cdr rule) url)))
  (when (cl-some (lambda (regexp)
                   (string-match-p regexp url))
                 zr-eww-auth-patterns)
    (let* ((parsed (url-generic-parse-url url))
           (entry (car (auth-source-search :host (url-host parsed) :port
                                           (url-port parsed)
                                           :require '(:user :secret) :max 1))))
      (when entry
        (setf (url-user parsed) (url-hexify-string (plist-get entry :user))
              (url-password parsed) (url-hexify-string (auth-info-password entry)))
        (setq url (url-recreate-url parsed)))))
  url)

(defvar-local zr-eww--rendering nil)

(defun zr-eww-render ()
  "Apply the configured reading or major-mode rule to the current page."
  (unless zr-eww--rendering
    (let ((zr-eww--rendering t)
          (url (plist-get eww-data :url)))
      (when url
        (when (cl-some (lambda (regexp)
                         (string-match-p regexp url))
                       zr-eww-readable-patterns)
          (eww-readable))
        (when-let* ((mode (cdr (cl-find-if (lambda (rule)
                                             (string-match-p (car rule) url))
                                           zr-eww-content-modes)))
                    ((fboundp mode)))
          (funcall mode)
          (read-only-mode 1))))))

(define-minor-mode zr-eww-mode
  "Enable EWW URL transformations and rendering rules."
  :global t
  (if zr-eww-mode
      (progn
        (unless (memq #'zr-eww-transform-url eww-url-transformers)
          (setq zr-eww--installed t)
          (add-to-list 'eww-url-transformers #'zr-eww-transform-url))
        (add-hook 'eww-after-render-hook #'zr-eww-render))
    (when zr-eww--installed
      (setq eww-url-transformers (delq #'zr-eww-transform-url eww-url-transformers)
            zr-eww--installed nil))
    (remove-hook 'eww-after-render-hook #'zr-eww-render)))

(provide 'zr-eww)
;;; zr-eww.el ends here
