;;; zr-shadowfile.el --- Copy files and directory trees through TRAMP -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Configure `zr-shadowfile-rules' and enable `zr-shadowfile-mode'.
;; Source paths ending in a directory separator preserve relative paths.
;; Other sources map one file to a destination filename.  Local paths,
;; including Windows drive letters and UNC paths, use the usual Emacs file
;; APIs; remote paths use TRAMP.
;;
;; `:include' matches relative file paths.  `:exclude' matches relative
;; paths and their ancestor directories, so excluding a directory also
;; excludes files subsequently saved below it.  Scans skip symbolic links.
;; `:vc-only t' additionally requires source files to be registered with an
;; Emacs VC backend, such as Git.  This filter is optional for each rule.
;;
;; `zr-shadowfile-queue-directory' queues existing files; use
;; `zr-shadowfile-queue-file' for one file, optionally with a one-off target.
;; Successful Emacs saves queue new and changed files.
;; `zr-shadowfile-copy-files' (C-x 4 s)
;; copies the saved disk bytes and creates destination parent directories.
;; Failed copies remain pending in `zr-shadowfile-pending-file'.
;; Tasks whose source no longer exists are discarded when copying.
;;
;; Pending copies retain their resolved source and destination even when
;; rules change.  Use `zr-shadowfile-cancel' to discard old tasks.  Copying
;; overwrites destinations, without merging changes or propagating deletions.
;; Loading this library does not enable copying or alter built-in shadowfile.

;;; Code:

(require 'cl-lib)
(require 'vc)

(defgroup zr-shadowfile nil
  "Copy files and directory trees through TRAMP."
  :group 'files)

(defcustom zr-shadowfile-rules nil
  "One-way file and directory copy rules.
Each rule is a plist with :source and :destination paths.  A source ending
in a directory separator denotes a directory, preserving relative paths;
otherwise it maps one source file to an exact destination filename, which
may have a different name.  Sources need not exist when configuring rules.
Relative paths use the local home directory as their base; remote names
use TRAMP syntax.
Matching follows the source filesystem's case rules.

:vc-only t restricts a rule to source files registered with an Emacs VC
backend, such as Git.  Files added to Git's index qualify even before their
first commit; untracked and ignored files do not.  The default nil allows
files without version control.  Registration is checked when queuing.

:include matches a file's relative path.  :exclude matches that path and
each ancestor directory, without trailing slashes.  Excluded directories
are pruned unless another rule needs their contents.  Saving a file below
an excluded directory does not queue a copy under that rule.
For file rules, :include and :exclude match the source basename.
Directory destinations are treated as directories and must be outside
their source; file destinations must be different from their source and
must not end in a directory separator.

Changes affect new tasks; pending tasks retain their source and destination."
  :type '(repeat (plist :options
                       ((:source file) (:destination file)
                        (:vc-only boolean)
                        (:include (choice (const nil) regexp))
                        (:exclude (choice (const nil) regexp)))))
  :group 'zr-shadowfile)

(defcustom zr-shadowfile-pending-file
  (locate-user-emacs-file "zr-shadowfile-pending.eld")
  "Local file storing pending copies as data, or nil to keep them in memory.
This is machine-local state.  Changes take effect when the mode is reenabled."
  :type '(choice (const :tag "Memory only" nil) file)
  :group 'zr-shadowfile)

(defcustom zr-shadowfile-noquery nil
  "Whether to copy pending files without asking."
  :type 'boolean
  :group 'zr-shadowfile)

(defcustom zr-shadowfile-copy-on-exit t
  "Whether to offer pending copies when exiting Emacs."
  :type 'boolean
  :group 'zr-shadowfile)

(defvar zr-shadowfile-mode)
(defvar zr-shadowfile--active nil)
(defvar zr-shadowfile--state-file nil)
(defvar zr-shadowfile--pending (make-hash-table :test #'equal)
  "Pending copies, keyed by (SOURCE . DESTINATION).")
(defvar zr-shadowfile--pending-dirty nil)

(defun zr-shadowfile--expand-path (path)
  "Expand PATH independently of a remote buffer's default directory."
  (expand-file-name path (expand-file-name "~/")))

(defun zr-shadowfile--relative-name (file directory)
  "Return FILE's relative path inside DIRECTORY, or nil if outside."
  (let ((relative (directory-file-name (file-relative-name file directory))))
    (unless (or (file-name-absolute-p relative)
                (equal relative "..") (string-prefix-p "../" relative))
      relative)))

(defun zr-shadowfile--same-file-name-p (file name)
  "Whether FILE names NAME, respecting the source filesystem's case rules."
  (when-let* ((relative (zr-shadowfile--relative-name file (file-name-directory name)))
              (basename (file-name-nondirectory name)))
    (or (string-equal relative basename)
        (and (string-equal-ignore-case relative basename)
             (file-name-case-insensitive-p name)))))

(defun zr-shadowfile--rule-relative-name (file rule)
  "Return FILE's matching relative name under RULE, or nil."
  (let ((source (plist-get rule :source)))
    (if (eq (plist-get rule :type) 'file)
        (when (zr-shadowfile--same-file-name-p file source)
          (file-name-nondirectory file))
      (zr-shadowfile--relative-name file source))))

(defun zr-shadowfile--check-file-target (file destination)
  "Check that DESTINATION names a file other than FILE."
  (when (directory-name-p destination)
    (user-error "File destination requires a filename: %s" destination))
  (when (zr-shadowfile--same-file-name-p destination file)
    (user-error "File destination must differ from its source: %s" destination)))

(defun zr-shadowfile--rules ()
  "Validate and expand the configured file and directory rules."
  (unless (proper-list-p zr-shadowfile-rules)
    (user-error "Copy rules must be a list"))
  (mapcar
   (lambda (rule)
     (unless (and (proper-list-p rule) (cl-evenp (length rule)))
       (user-error "Invalid copy rule: %S" rule))
     (let (keys)
       (cl-loop for (key value) on rule by #'cddr do
                (unless (and (memq key '(:source :destination :vc-only :include :exclude))
                             (not (memq key keys)))
                  (user-error "Invalid or repeated copy rule option: %S" key))
                (push key keys)
                (cond
                 ((eq key :vc-only)
                  (unless (memq value '(nil t))
                    (user-error "Copy rule :vc-only must be nil or t")))
                 ((memq key '(:source :destination))
                  (unless (and (stringp value) (not (string-empty-p value)))
                    (user-error "%S requires a path" key)))
                 (value
                  (unless (stringp value) (user-error "%S requires a regexp" key))
                  (string-match-p value "")))))
     (unless (and (plist-get rule :source) (plist-get rule :destination))
       (user-error "Copy rules require :source and :destination"))
     (let ((type (if (directory-name-p (plist-get rule :source)) 'directory 'file))
           (source (zr-shadowfile--expand-path (plist-get rule :source)))
           (destination (zr-shadowfile--expand-path (plist-get rule :destination))))
       (if (eq type 'file)
           (progn
             (when (directory-name-p source)
               (user-error "File source requires a filename: %s" source))
             (zr-shadowfile--check-file-target source destination))
         (setq source (file-name-as-directory source)
               destination (file-name-as-directory destination))
         (when (zr-shadowfile--relative-name destination source)
           (user-error "Copy destination must be outside its source: %s" destination)))
       (list :type type :source source :destination destination
             :vc-only (plist-get rule :vc-only)
             :include (plist-get rule :include) :exclude (plist-get rule :exclude))))
   zr-shadowfile-rules))

(defun zr-shadowfile--excluded-p (relative regexp)
  "Whether REGEXP excludes RELATIVE or one of its ancestor directories."
  (when regexp
    (let ((path relative) excluded)
      (while (and path (not (equal path ".")) (not excluded))
        (setq excluded (string-match-p regexp path)
              path (when-let* ((parent (file-name-directory path)))
                     (directory-file-name parent))))
      excluded)))

(defun zr-shadowfile--included-p (relative rule)
  "Whether RELATIVE is included by RULE."
  (let ((case-fold-search (file-name-case-insensitive-p (plist-get rule :source))))
    (and (not (zr-shadowfile--excluded-p relative (plist-get rule :exclude)))
         (or (null (plist-get rule :include))
             (string-match-p (plist-get rule :include) relative)))))

(defun zr-shadowfile--directory-allowed-p (directory rules)
  "Whether DIRECTORY can contain included files under RULES."
  (cl-some
   (lambda (rule)
     (let* ((source (plist-get rule :source))
            (relative (and (eq (plist-get rule :type) 'directory)
                           (zr-shadowfile--relative-name directory source))))
       (or (zr-shadowfile--relative-name source (file-name-as-directory directory))
           (and relative
                (let ((case-fold-search (file-name-case-insensitive-p source)))
                  (not (zr-shadowfile--excluded-p relative (plist-get rule :exclude))))))))
   rules))

(defun zr-shadowfile--pending-copies ()
  "Return a snapshot of pending copies."
  (let (copies)
    (maphash (lambda (pair _) (push pair copies)) zr-shadowfile--pending)
    copies))

(defun zr-shadowfile--read-pending ()
  "Read and merge pending copies from the active state file."
  (when (and zr-shadowfile--state-file (file-exists-p zr-shadowfile--state-file))
    (let ((copies (with-temp-buffer
                    (insert-file-contents zr-shadowfile--state-file)
                    (let ((data (read (current-buffer))))
                      (skip-chars-forward " \t\r\n")
                      (unless (eobp) (user-error "Trailing data in pending-copy file"))
                      data))))
      (unless (and (proper-list-p copies)
                   (cl-every (lambda (pair)
                               (and (consp pair) (stringp (car pair)) (stringp (cdr pair))
                                    (file-name-absolute-p (car pair))
                                    (file-name-absolute-p (cdr pair))))
                             copies))
        (user-error "Invalid pending-copy file: %s" zr-shadowfile--state-file))
      (dolist (pair copies) (puthash pair t zr-shadowfile--pending)))))

(defun zr-shadowfile--write-pending ()
  "Atomically save pending copies to the active local state file."
  (when zr-shadowfile--state-file
    (let ((temporary (make-temp-file
                      (expand-file-name ".zr-shadowfile-"
                                        (file-name-directory zr-shadowfile--state-file))))
          (coding-system-for-write 'utf-8-unix)
          (print-length nil) (print-level nil))
      (unwind-protect
          (progn
            (with-temp-file temporary
              (prin1 (zr-shadowfile--pending-copies) (current-buffer))
              (insert "\n"))
            (rename-file temporary zr-shadowfile--state-file t))
        (when (file-exists-p temporary) (delete-file temporary)))))
  (setq zr-shadowfile--pending-dirty nil))

(defun zr-shadowfile--enqueue (file destination)
  "Queue FILE to DESTINATION, returning 1 for a new task or 0 for a duplicate."
  (let ((pair (cons file destination)))
    (if (gethash pair zr-shadowfile--pending)
        0
      (puthash pair t zr-shadowfile--pending)
      (setq zr-shadowfile--pending-dirty t)
      1)))

(defun zr-shadowfile--queue-file (file rules)
  "Queue FILE under RULES and return the number of new copies."
  (let ((before (hash-table-count zr-shadowfile--pending)))
    (unless (or (equal file zr-shadowfile--state-file) (file-symlink-p file))
      (dolist (rule rules)
        (when-let* ((relative (zr-shadowfile--rule-relative-name file rule))
                    ((zr-shadowfile--included-p relative rule))
                    ((file-regular-p file))
                    ((file-in-directory-p
                      file (if (eq (plist-get rule :type) 'file)
                               (file-name-directory (plist-get rule :source))
                             (plist-get rule :source))))
                    ((or (not (plist-get rule :vc-only)) (vc-registered file))))
          (zr-shadowfile--enqueue
           file (if (eq (plist-get rule :type) 'file)
                    (plist-get rule :destination)
                  (expand-file-name relative (plist-get rule :destination)))))))
    (- (hash-table-count zr-shadowfile--pending) before)))

(defun zr-shadowfile--after-save ()
  "Queue a successfully saved file and persist its new copy tasks."
  (when (buffer-file-name)
    (condition-case err
        (let ((count (zr-shadowfile--queue-file
                      (zr-shadowfile--expand-path (buffer-file-name)) (zr-shadowfile--rules))))
          (when zr-shadowfile--pending-dirty (zr-shadowfile--write-pending))
          (when (> count 0)
            (message "%s" (substitute-command-keys
                           "Use \\[zr-shadowfile-copy-files] to copy pending files."))))
      (error (message "Cannot queue saved file: %s" (error-message-string err))))))

;;;###autoload
(defun zr-shadowfile-queue-file (file &optional destination)
  "Queue FILE using the configured rules, or to the one-off DESTINATION.
With a prefix argument, prompt for a destination filename.  A one-off task
is independent of the rules.  Use `zr-shadowfile-copy-files' to copy it."
  (interactive
   (let ((file (read-file-name "Queue copy file: " nil (buffer-file-name) t)))
     (list file (when current-prefix-arg
                  (read-file-name "Destination file: " nil nil nil
                                  (file-name-nondirectory file))))))
  (unless zr-shadowfile-mode (zr-shadowfile-mode 1))
  (let ((file (zr-shadowfile--expand-path file)))
    (unless (and (file-regular-p file) (not (file-symlink-p file))
                 (not (equal file zr-shadowfile--state-file)))
      (user-error "Not a copyable regular file: %s" file))
    (let ((count (if destination
                     (let ((target (zr-shadowfile--expand-path destination)))
                       (zr-shadowfile--check-file-target file target)
                       (zr-shadowfile--enqueue file target))
                   (zr-shadowfile--queue-file file (zr-shadowfile--rules)))))
      (zr-shadowfile--write-pending)
      (message "Queued %d copies; use C-x 4 s to copy" count)
      count)))

;;;###autoload
(defun zr-shadowfile-queue-directory (directory)
  "Queue existing regular files below DIRECTORY using the configured rules.
Preserve relative paths, prune excluded directories and skip symbolic links.
Use `zr-shadowfile-copy-files' or C-x 4 s to perform the queued copies."
  (interactive (list (read-directory-name "Queue copy directory: " (expand-file-name "~/"))))
  (unless zr-shadowfile-mode (zr-shadowfile-mode 1))
  (let ((directory (file-name-as-directory (zr-shadowfile--expand-path directory)))
        (rules (zr-shadowfile--rules))
        (before (hash-table-count zr-shadowfile--pending)))
    (unless (file-directory-p directory) (user-error "Not a directory: %s" directory))
    (unwind-protect
        (when (zr-shadowfile--directory-allowed-p directory rules)
          (dolist (file (directory-files-recursively
                        directory "." nil
                        (lambda (subdirectory)
                          (zr-shadowfile--directory-allowed-p subdirectory rules))))
            (zr-shadowfile--queue-file file rules)))
      (zr-shadowfile--write-pending))
    (let ((count (- (hash-table-count zr-shadowfile--pending) before)))
      (message "Queued %d copies; use C-x 4 s to copy" count)
      count)))

(defun zr-shadowfile--source-exists-p (pair)
  "Return whether PAIR's source exists, discarding the task if missing.
If checking fails, report the error and retain the task for a later retry."
  (condition-case err
      (if (file-exists-p (car pair))
          t
        (remhash pair zr-shadowfile--pending)
        (setq zr-shadowfile--pending-dirty t)
        nil)
    (error (message "Cannot check source %s: %s" (car pair) (error-message-string err)) nil)))

(defun zr-shadowfile--copy-file (pair)
  "Copy PAIR's saved disk bytes, discarding successful or missing tasks."
  (condition-case err
      (when (zr-shadowfile--source-exists-p pair)
        (make-directory (file-name-directory (cdr pair)) t)
        (copy-file (car pair) (cdr pair) t)
        (remhash pair zr-shadowfile--pending)
        (setq zr-shadowfile--pending-dirty t)
        t)
    (file-missing
     (when (zr-shadowfile--source-exists-p pair)
       (message "Cannot copy %s: %s" (cdr pair) (error-message-string err)))
     nil)
    (error (message "Cannot copy %s: %s" (cdr pair) (error-message-string err)) nil)))

;;;###autoload
(defun zr-shadowfile-copy-files (&optional noquery)
  "Copy pending files, asking unless NOQUERY or `zr-shadowfile-noquery' is set.
With a prefix argument, copy without asking.  Copy the saved disk bytes,
create destination parent directories, and retain failed or skipped tasks.
Discard tasks whose source no longer exists without asking."
  (interactive "P")
  (unless zr-shadowfile-mode (zr-shadowfile-mode 1))
  (let ((copied 0))
    (unwind-protect
        (map-y-or-n-p
         (lambda (pair)
           (and (zr-shadowfile--source-exists-p pair)
                (or noquery zr-shadowfile-noquery
                    (format "Copy %s to %s? " (car pair) (cdr pair)))))
         (lambda (pair) (when (zr-shadowfile--copy-file pair) (cl-incf copied) t))
         (zr-shadowfile--pending-copies) '("file" "files" "copy"))
      (zr-shadowfile--write-pending))
    (message "Copied %d files; %d copies pending" copied (hash-table-count zr-shadowfile--pending))
    copied))

;;;###autoload
(defun zr-shadowfile-cancel (&optional all)
  "Cancel selected pending copies, or all copies with a prefix argument ALL."
  (interactive "P")
  (unless zr-shadowfile-mode (zr-shadowfile-mode 1))
  (let ((cancelled 0))
    (unwind-protect
        (map-y-or-n-p
         (lambda (pair) (or all (format "Cancel copying %s to %s? " (car pair) (cdr pair))))
         (lambda (pair)
           (remhash pair zr-shadowfile--pending)
           (setq zr-shadowfile--pending-dirty t)
           (cl-incf cancelled) t)
         (zr-shadowfile--pending-copies) '("copy" "copies" "cancel"))
      (zr-shadowfile--write-pending))
    cancelled))

(defun zr-shadowfile--query-exit ()
  "Offer pending copies before exiting, preserving unsuccessful tasks."
  (if zr-shadowfile-copy-on-exit
      (zr-shadowfile-copy-files)
    (zr-shadowfile--write-pending))
  t)

(defun zr-shadowfile--disable ()
  "Remove this mode's hooks and release its local state file."
  (remove-hook 'after-save-hook #'zr-shadowfile--after-save)
  (remove-hook 'kill-emacs-query-functions #'zr-shadowfile--query-exit)
  (when (and zr-shadowfile--state-file (not (file-remote-p zr-shadowfile--state-file))
             (eq t (file-locked-p zr-shadowfile--state-file)))
    (unlock-file zr-shadowfile--state-file))
  (setq zr-shadowfile--active nil zr-shadowfile--state-file nil))

;;;###autoload
(define-minor-mode zr-shadowfile-mode
  "Queue file and directory copies globally according to `zr-shadowfile-rules'.
Successful saves queue and persist tasks.  C-x 4 s copies their saved disk
bytes; exiting also offers copies when `zr-shadowfile-copy-on-exit' is set.
Disabling removes the hooks and key binding, retaining pending tasks."
  :global t
  :group 'zr-shadowfile
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-x 4 s") #'zr-shadowfile-copy-files)
            map)
  (if zr-shadowfile-mode
      (unless zr-shadowfile--active
        (condition-case err
            (progn
              (zr-shadowfile--rules)
              (setq zr-shadowfile--state-file
                    (and zr-shadowfile-pending-file
                         (zr-shadowfile--expand-path zr-shadowfile-pending-file)))
              (when zr-shadowfile--state-file
                (when (file-remote-p zr-shadowfile--state-file)
                  (user-error "Pending-copy file must be local"))
                (make-directory (file-name-directory zr-shadowfile--state-file) t)
                (when (stringp (file-locked-p zr-shadowfile--state-file))
                  (user-error "Pending-copy file is locked by another Emacs"))
                (lock-file zr-shadowfile--state-file))
              (zr-shadowfile--read-pending)
              (add-hook 'after-save-hook #'zr-shadowfile--after-save)
              (add-hook 'kill-emacs-query-functions #'zr-shadowfile--query-exit)
              (setq zr-shadowfile--active t))
          (error
           (setq zr-shadowfile-mode nil)
           (zr-shadowfile--disable)
           (signal (car err) (cdr err)))))
    (zr-shadowfile--disable)))

(defun zr-shadowfile-unload-function ()
  "Disable directory copying before unloading this library."
  (zr-shadowfile-mode -1)
  nil)

(provide 'zr-shadowfile)
;;; zr-shadowfile.el ends here
