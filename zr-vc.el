;;; zr-vc.el --- VC filenames and commit editing -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-prog.el (selected functionality).

;;; Commentary:

;; Commands and optional hook functions; loading installs no hooks or bindings.

;;; Code:

(require 'vc-dir)
(require 'subr-x)
(declare-function server-edit "server")

(defgroup zr-vc nil
  "VC helpers."
  :group 'vc)

(defcustom zr-vc-commit-types
  '("fix" "feat" "build" "chore" "ci" "docs" "style" "refactor" "perf" "test")
  "Conventional commit types."
  :type '(repeat string))

(defun zr-vc-copy-filenames (&optional style)
  "Copy selected VC filenames.  STYLE zero means absolute, C-u means basename."
  (interactive "P")
  (let* ((entries (or (vc-dir-marked-only-files-and-states)
                      (list (cons (vc-dir-current-file) nil))))
         (files (mapcar
                 (lambda (entry)
                   (let ((file (car entry)))
                     (unless file
                       (user-error "No file selected"))
                     (cond
                      ((consp style)
                       (file-name-nondirectory file))
                      ((eq style 0)
                       (expand-file-name file))
                      (t
                       (file-relative-name file)))))
                 entries)))
    (unless (car files)
      (user-error "No file selected"))
    (kill-new (mapconcat #'shell-quote-argument files " "))))

(defun zr-vc-insert-commit-template (type &optional scope)
  "Insert a TYPE commit heading, optionally with SCOPE.
Special types paste, empty and merge retain the interactive helper actions."
  (interactive
   (let ((type
          (completing-read "Type: "
                           (append zr-vc-commit-types '("paste" "empty" "merge")) nil t)))
     (list type (unless (member type '("paste" "empty" "merge"))
                  (read-string "Scope: ")))))
  (insert
   (pcase type
     ("paste"
      (current-kill 0))
     ("empty"
      "")
     ("merge"
      (format "Merge branch '%s' into '%s'"
              (read-string "Source branch: ") (read-string "Target branch: ")))
     (_
      (concat type (unless (string-empty-p (or scope ""))
                     (format "(%s)" scope))
              ": ")))))

(defun zr-vc-commit-setup ()
  "Insert a commit heading when no message has been entered yet."
  (when (save-excursion
          (goto-char (point-min))
          (not (re-search-forward "^[^#\n[:space:]]" nil t)))
    (goto-char (point-min))
    (call-interactively #'zr-vc-insert-commit-template)))

(defun zr-vc-abort-server-edit ()
  "Discard the commit message and finish the server edit."
  (interactive)
  (erase-buffer)
  (server-edit))

(defun zr-vc-server-commit-setup ()
  "Set up an emacsclient Git commit message buffer."
  (when (and buffer-file-name
             (equal (file-name-nondirectory buffer-file-name) "COMMIT_EDITMSG"))
    (zr-vc-commit-setup)))

(provide 'zr-vc)
;;; zr-vc.el ends here
