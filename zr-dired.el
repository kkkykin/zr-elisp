;;; zr-dired.el --- File operations for Dired -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).
;;; Commentary:
;; Commands only.  Set `dired-dwim-target' to `zr-dired-targets' if wanted.
;; Refactored from user-lisp; numbered copies inspired by James Dyer.
;;; Code:
(require 'cl-lib)
(require 'dired)
(require 'dired-aux)
(require 'subr-x)
(declare-function shell-command-do-open "dired-aux")

(defgroup zr-dired nil "File operations." :group 'dired)
(defcustom zr-dired-pandoc-program "pandoc"
  "Pandoc executable." :type 'string)
(defvar zr-dired-target-directories nil "Explicit copy and move destinations.")

(defun zr-dired-duplicate (&optional number)
  "Copy the file at point to an unused numbered name, starting at NUMBER."
  (interactive "p")
  (let* ((source (dired-get-file-for-visit))
         (directory (file-directory-p source))
         (stem (if directory source (file-name-sans-extension source)))
         (extension (unless directory (file-name-extension source t)))
         (counter (or number 1)) destination)
    (unless (natnump counter) (user-error "Number must be nonnegative"))
    (while (progn
             (setq destination (format "%s_%03d%s" stem counter (or extension "")))
             (setq counter (1+ counter))
             (or (file-exists-p destination) (file-symlink-p destination))))
    (if directory (copy-directory source destination)
      (copy-file source destination))
    (revert-buffer)
    (dired-goto-file destination)
    destination))

(defun zr-dired-random-file ()
  "Visit a random file entry in the current Dired listing."
  (interactive)
  (let (files)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((file (dired-get-filename nil t))
                    ((not (member (file-name-nondirectory file) '("." "..")))))
          (push file files))
        (forward-line)))
    (unless files (user-error "No file entries"))
    (dired-goto-file (nth (random (length files)) files))))

(defun zr-dired-mark-target (&optional directory)
  "Remember DIRECTORY, or the marked directories, as destinations."
  (interactive (list (when current-prefix-arg (read-directory-name "Target: "))))
  (dolist (file (if directory (list directory) (dired-get-marked-files)))
    (unless (file-directory-p file) (user-error "Not a directory: %s" file))
    (cl-pushnew (file-name-as-directory (expand-file-name file))
                zr-dired-target-directories :test #'equal)))

(defun zr-dired-unmark-target (directory)
  "Forget DIRECTORY; an empty string forgets all destinations."
  (interactive (list (completing-read "Forget target (empty for all): "
                                    zr-dired-target-directories nil t)))
  (setq zr-dired-target-directories
        (unless (string-empty-p directory)
          (delete (file-name-as-directory (expand-file-name directory))
                  zr-dired-target-directories))))

(defun zr-dired-targets ()
  "Return explicit destinations and recent Dired destinations."
  (delete-dups (append (copy-sequence zr-dired-target-directories)
                       (dired-dwim-target-recent))))

(defun zr-dired-pandoc (&optional from to)
  "Preview the selected file converted FROM its format TO Org by default."
  (interactive)
  (unless (executable-find zr-dired-pandoc-program) (user-error "Pandoc is unavailable"))
  (let* ((file (dired-get-file-for-visit))
         (format (or to "org"))
         (buffer (generate-new-buffer (format "*Pandoc: %s*" (file-name-nondirectory file)))))
    (condition-case err
        (progn
          (with-current-buffer buffer
            (let ((status (apply #'process-file zr-dired-pandoc-program nil t nil
                                 file "-t" format (when from (list "-f" from)))))
              (unless (eq status 0) (error "Pandoc failed (%s): %s" status (buffer-string))))
            (let ((buffer-file-name (concat "preview." format))) (set-auto-mode))
            (goto-char (point-min))
            (set-buffer-modified-p nil)
            (read-only-mode 1))
          (pop-to-buffer buffer))
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(defun zr-dired-open-externally (&optional file-itself)
  "Open the current file's directory externally; with FILE-ITSELF, open the file."
  (interactive "P")
  (let ((file (if (derived-mode-p 'dired-mode) (dired-get-file-for-visit)
                (or buffer-file-name (user-error "Buffer has no file")))))
    (shell-command-do-open (list (if file-itself file (file-name-directory file))))))

(provide 'zr-dired)
;;; zr-dired.el ends here
