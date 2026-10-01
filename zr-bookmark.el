;;; zr-bookmark.el --- Separate shared bookmarks -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).

;;; Commentary:

;; Enable `zr-bookmark-shared-mode' explicitly to split bookmark persistence.

;;; Code:

(require 'bookmark)
(require 'cl-lib)

(defgroup zr-bookmark nil
  "Shared bookmarks."
  :group 'bookmark)

(defcustom zr-bookmark-shared-prefix "s/"
  "Prefix of shared bookmark names."
  :type 'string)

(defcustom zr-bookmark-shared-file (locate-user-emacs-file "bookmark-share")
  "File holding shared bookmarks."
  :type 'file)

(defvar zr-bookmark--installed nil)

(defvar zr-bookmark--loaded-file nil)

(defun zr-bookmark--check-files ()
  "Reject shared and local paths referring to the same file."
  (when (equal (file-truename zr-bookmark-shared-file)
               (file-truename
                (or (car bookmark-bookmarks-timestamp) bookmark-default-file)))
    (user-error "Shared and local bookmark files must differ")))

(defun zr-bookmark-load-shared ()
  "Reload shared bookmarks without duplicating names or replacing local ones."
  (interactive)
  (zr-bookmark--check-files)
  (when (file-readable-p zr-bookmark-shared-file)
    (let ((shared (with-temp-buffer
                    (insert-file-contents zr-bookmark-shared-file)
                    (bookmark-alist-from-buffer))))
      (setq bookmark-alist
            (append (cl-remove-if-not #'zr-bookmark--shared-p shared)
                    (cl-remove-if #'zr-bookmark--shared-p bookmark-alist)))
      (bookmark-bmenu-surreptitiously-rebuild-list)))
  (setq zr-bookmark--loaded-file (expand-file-name zr-bookmark-shared-file)))

(defun zr-bookmark--shared-p (entry)
  "Return non-nil when ENTRY belongs in the shared file."
  (string-prefix-p zr-bookmark-shared-prefix (car entry)))

(defun zr-bookmark--after-load (file &optional overwrite _no-msg _default)
  "Restore shared entries after a local FILE reload with OVERWRITE."
  (when (and overwrite
             (equal (expand-file-name file)
                    (expand-file-name
                     (or (car bookmark-bookmarks-timestamp) bookmark-default-file))))
    (zr-bookmark-load-shared)))

(defun zr-bookmark--save (original &optional prefix file make-default)
  "Split normal saves through ORIGINAL; honor explicit alternate FILE saves."
  (if (or prefix (and file (not (equal (expand-file-name file)
                                       (expand-file-name bookmark-default-file)))))
      (funcall original prefix file make-default)
    (bookmark-maybe-load-default-file)
    (zr-bookmark--check-files)
    (let (shared local)
      (dolist (entry bookmark-alist)
        (if (string-prefix-p zr-bookmark-shared-prefix (car entry))
            (push entry shared)
          (push entry local)))
      (make-directory (file-name-directory (expand-file-name zr-bookmark-shared-file)) t)
      ;; Always write the shared list, including an empty list after deletions.
      (let ((bookmark-alist (nreverse shared)))
        (zr-bookmark--write-file zr-bookmark-shared-file))
      (let ((destination (expand-file-name
                          (or file (car bookmark-bookmarks-timestamp)
                              bookmark-default-file)))
            (bookmark-alist (nreverse local)))
        (make-directory (file-name-directory destination) t)
        (zr-bookmark--write-file destination)
        (setq bookmark-bookmarks-timestamp
              (cons destination
                    (file-attribute-modification-time (file-attributes destination)))))
      (setq bookmark-alist-modification-count 0))))

(defun zr-bookmark--write-file (file)
  "Write the current bookmark list to FILE, propagating write errors.
Unlike `bookmark-write-file', a failed write must not mark a split save clean."
  (with-temp-buffer
    (let ((print-length nil)
          (print-level nil)
          (print-circle t)
          (coding-system-for-write (or bookmark-file-coding-system 'utf-8-emacs))
          (version-control (pcase bookmark-version-control
                             ('never
                              'never)
                             ('nospecial
                              version-control)
                             (_
                              bookmark-version-control))))
      (insert (prin1-to-string bookmark-alist) "\n")
      (goto-char (point-min))
      (bookmark-insert-file-format-version-stamp coding-system-for-write)
      (write-file file))))

(define-minor-mode zr-bookmark-shared-mode
  "Split normal bookmark saves between shared and local files."
  :global t
  :group 'zr-bookmark
  (if zr-bookmark-shared-mode
      (unless zr-bookmark--installed
        (condition-case err
            (progn
              (zr-bookmark--check-files)
              (bookmark-maybe-load-default-file)
              (unless (equal zr-bookmark--loaded-file
                             (expand-file-name zr-bookmark-shared-file))
                (zr-bookmark-load-shared))
              (advice-add 'bookmark-load :after #'zr-bookmark--after-load)
              (advice-add 'bookmark-save :around #'zr-bookmark--save)
              (setq zr-bookmark--installed t))
          (error
           (setq zr-bookmark-shared-mode nil)
           (signal (car err) (cdr err)))))
    (advice-remove 'bookmark-save #'zr-bookmark--save)
    (advice-remove 'bookmark-load #'zr-bookmark--after-load)
    (setq zr-bookmark--installed nil)))

(provide 'zr-bookmark)
;;; zr-bookmark.el ends here
