;;; zr-org-protocol.el --- Explicit protocol and cookie integration -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).
;;; Commentary:
;; Enable cookie import with `zr-org-protocol-mode'.  Windows registration is
;; a separate command and is never performed during loading or startup.
;;; Code:
(require 'org-protocol)
(require 'url)
(require 'url-cookie)
(require 'subr-x)
(defgroup zr-org-protocol nil "Org protocol helpers." :group 'org)
(defcustom zr-org-protocol-cookie-directory (expand-file-name "netscape" url-configuration-directory)
  "Directory for imported Netscape cookie files." :type 'directory)
(defvar zr-org-protocol--entry nil)
(defun zr-org-protocol-import-cookies (info)
  "Import Netscape cookies from protocol INFO containing :host and :cookies."
  (let* ((parameters (org-protocol-parse-parameters info t))
         (host (plist-get parameters :host)) (cookies (plist-get parameters :cookies)))
    (unless (and (stringp host) (string-match-p "\\`[[:alnum:]][[:alnum:]._-]*\\'" host)
                 (stringp cookies) (not (string-empty-p cookies)))
      (user-error "Invalid cookie import host or contents"))
    (setq cookies (string-replace "\r\n" "\n" cookies))
    (unless (string-prefix-p "# Netscape HTTP Cookie File\n" cookies)
      (user-error "Expected Netscape cookie contents"))
    ;; url-cookie's Netscape reader treats HttpOnly lines as comments.
    (setq cookies (replace-regexp-in-string "^#HttpOnly_" "" cookies))
    (make-directory zr-org-protocol-cookie-directory t)
    (let ((file (expand-file-name host zr-org-protocol-cookie-directory))
          (url-cookie-file (or url-cookie-file (expand-file-name "cookies" url-configuration-directory)))
          (coding-system-for-write 'utf-8-unix))
      (when (file-symlink-p file) (user-error "Cookie destination is a symbolic link"))
      (make-directory (file-name-directory (expand-file-name url-cookie-file)) t)
      ;; The native writer only logs access failures.  Check before importing.
      (url-make-private-file url-cookie-file)
      (let ((temporary (make-temp-file (expand-file-name ".cookies-" zr-org-protocol-cookie-directory))))
        (unwind-protect
            (progn
              (with-temp-file temporary (insert cookies))
              (rename-file temporary file t))
          (when (file-exists-p temporary) (delete-file temporary))))
      (url-cookie-parse-file-netscape file t)
      (url-cookie-write-file))
    nil))
(defun zr-org-protocol-register-windows ()
  "Register org-protocol for the current Windows user."
  (interactive)
  (unless (eq system-type 'windows-nt) (user-error "This command requires Windows"))
  (let ((client (or (executable-find "emacsclientw") (user-error "emacsclientw is unavailable")))
        (key "HKCU\\Software\\Classes\\org-protocol"))
    (dolist (arguments (list (list "add" key "/ve" "/d" "URL:Org Protocol" "/f")
                            (list "add" key "/v" "URL Protocol" "/d" "" "/f")
                            (list "add" (concat key "\\shell\\open\\command") "/ve" "/d"
                                  (format "\"%s\" \"%%1\"" (subst-char-in-string ?/ ?\\ client)) "/f")))
      (unless (eq 0 (apply #'call-process "reg" nil nil nil arguments))
        (error "Registry update failed")))))
(define-minor-mode zr-org-protocol-mode
  "Register the cookies-dumper Org protocol handler."
  :global t
  (if zr-org-protocol-mode
      (unless zr-org-protocol--entry
        (setq zr-org-protocol--entry '("zr cookies" :protocol "cookies-dumper"
                                                 :function zr-org-protocol-import-cookies :kill-client t))
        (push zr-org-protocol--entry org-protocol-protocol-alist))
    (setq org-protocol-protocol-alist (delq zr-org-protocol--entry org-protocol-protocol-alist)
          zr-org-protocol--entry nil)))
(provide 'zr-org-protocol)
;;; zr-org-protocol.el ends here
