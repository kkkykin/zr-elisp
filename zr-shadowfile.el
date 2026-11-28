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
;; Copies are synchronous by default.  A rule's `:async t' enables background
;; WebDAV transfers; a nonnegative number also copies automatically that many
;; seconds after the last successful save.  Zero schedules an immediate copy.
;; Use `zr-shadowfile-wait' to wait for a batch; exiting flushes delayed copies
;; with a time limit and asks before leaving unsuccessful copies pending.
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

(declare-function zr-tramp-webdav-copy-file-async "zr-tramp-webdav")

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

:async nil (the default) copies synchronously on explicit requests.
:async t uses background local/WebDAV copies on explicit requests.
:async SECONDS, a nonnegative number, also copies automatically after a
successful save, restarting the delay after each save; zero starts without
delay.  Automatic copies need no per-file confirmation.  Explicit copying
and exit copying bypass the delay.  Other transports remain synchronous.
Manually queuing existing files does not start automatic copies.

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

Pending tasks retain their paths and :async setting until queued again.
Another save or queue request uses the matching rule's current :async setting."
  :type '(repeat (plist :options
                       ((:source file) (:destination file)
                        (:async (choice (const nil) (const t) number))
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
  "Whether to offer and wait for pending copies when exiting Emacs.
If copies remain, ask before exiting.  When nil, stop any active batch and
preserve its pending tasks without starting new copies."
  :type 'boolean
  :group 'zr-shadowfile)

(defcustom zr-shadowfile-exit-timeout 60
  "Maximum seconds spent waiting for background copies before an exit query.
Unfinished copies remain pending.  This does not limit time spent answering
questions.  HTTP requests also honor the WebDAV transport's own timeout."
  :type 'number
  :group 'zr-shadowfile)

(defvar zr-shadowfile-mode)
(defvar zr-shadowfile--active nil)
(defvar zr-shadowfile--state-file nil)
(defvar zr-shadowfile--pending (make-hash-table :test #'equal)
  "Pending task records, keyed by (SOURCE . DESTINATION).")
(defvar zr-shadowfile--pending-dirty nil)
(defvar zr-shadowfile--revision 0)
(defvar zr-shadowfile--batch nil)
(defvar zr-shadowfile--inhibit-automatic nil)

(cl-defstruct (zr-shadowfile--task (:constructor zr-shadowfile--make-task))
  revision async deadline timer timer-token ready buffer)

(cl-defstruct (zr-shadowfile--batch (:constructor zr-shadowfile--make-batch))
  copies tasks buffer job cancel timer failed (copied 0) done)

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

(defun zr-shadowfile--async-value-p (value)
  "Whether VALUE is nil, t, or a finite nonnegative delay in seconds."
  (or (memq value '(nil t))
      (and (numberp value) (>= value 0) (<= value most-positive-fixnum))))

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
                (unless (and (memq key '(:source :destination :async :vc-only :include :exclude))
                             (not (memq key keys)))
                  (user-error "Invalid or repeated copy rule option: %S" key))
                (push key keys)
                (cond
                 ((eq key :async)
                  (unless (zr-shadowfile--async-value-p value)
                    (user-error "Copy rule :async must be nil, t, or nonnegative seconds")))
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
             :async (plist-get rule :async)
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

(defun zr-shadowfile--pending-records ()
  "Return pending paths, :async settings, and automatic copy deadlines."
  (let (records)
    (maphash (lambda (pair task)
               (push (list (car pair) (cdr pair) (zr-shadowfile--task-async task)
                           (zr-shadowfile--task-deadline task)) records))
             zr-shadowfile--pending)
    records))

(defun zr-shadowfile--read-pending ()
  "Read and merge pending copies from the active state file."
  (when (and zr-shadowfile--state-file (file-exists-p zr-shadowfile--state-file))
    (let ((copies (with-temp-buffer
                    (insert-file-contents zr-shadowfile--state-file)
                    (let ((data (read (current-buffer))))
                      (skip-chars-forward " \t\r\n")
                      (unless (eobp) (user-error "Trailing data in pending-copy file"))
                      data)))
          imported)
      ;; Path-only pending data has no asynchronous opt-in.  Preserve its
      ;; resolved paths using the default policy, then write complete records.
      (when (and copies (proper-list-p copies)
                 (cl-every (lambda (pair)
                             (and (consp pair) (stringp (car pair)) (stringp (cdr pair))))
                           copies))
        (setq copies (mapcar (lambda (pair) (list (car pair) (cdr pair) nil nil)) copies)
              imported t))
      (unless (and (proper-list-p copies)
                   (cl-every (lambda (record)
                               (and (proper-list-p record) (= (length record) 4)
                                    (stringp (nth 0 record)) (stringp (nth 1 record))
                                    (file-name-absolute-p (nth 0 record))
                                    (file-name-absolute-p (nth 1 record))
                                    (zr-shadowfile--async-value-p (nth 2 record))
                                    (or (null (nth 3 record))
                                        (and (numberp (nth 2 record))
                                             (numberp (nth 3 record))
                                             (zr-shadowfile--async-value-p (nth 3 record))))))
                             copies))
        (user-error "Invalid pending-copy file: %s" zr-shadowfile--state-file))
      (dolist (record copies)
        (pcase-let ((`(,source ,destination ,async ,deadline) record))
          (let ((pair (cons source destination)))
            (unless (gethash pair zr-shadowfile--pending)
              (puthash pair (zr-shadowfile--make-task
                             :revision (cl-incf zr-shadowfile--revision)
                             :async async :deadline deadline)
                       zr-shadowfile--pending)))))
      (when imported (zr-shadowfile--write-pending)))))

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
              (prin1 (zr-shadowfile--pending-records) (current-buffer))
              (insert "\n"))
            (rename-file temporary zr-shadowfile--state-file t))
        (when (file-exists-p temporary) (delete-file temporary)))))
  (setq zr-shadowfile--pending-dirty nil)
  (zr-shadowfile--schedule-pending))

(defun zr-shadowfile--cancel-task-timer (task)
  "Cancel TASK's automatic copy timer without changing its deadline."
  (when-let* ((timer (zr-shadowfile--task-timer task))) (cancel-timer timer))
  (setf (zr-shadowfile--task-timer task) nil
        (zr-shadowfile--task-timer-token task) nil))

(defun zr-shadowfile--cancel-timers ()
  "Cancel all pending automatic timers, retaining their deadlines."
  (maphash (lambda (_pair task)
             (zr-shadowfile--cancel-task-timer task)
             (setf (zr-shadowfile--task-ready task) nil))
           zr-shadowfile--pending))

(defun zr-shadowfile--schedule-pending ()
  "Arm timers for saved tasks that still have an automatic copy deadline."
  (when (and zr-shadowfile--active zr-shadowfile-mode
             (not zr-shadowfile--inhibit-automatic))
    (maphash
     (lambda (pair task)
       (when (and (zr-shadowfile--task-deadline task)
                  (not (zr-shadowfile--task-ready task))
                  (not (zr-shadowfile--task-timer task)))
         (setf (zr-shadowfile--task-timer-token task) (list nil)
               (zr-shadowfile--task-timer task)
               (run-at-time (max 0 (- (zr-shadowfile--task-deadline task) (float-time)))
                            nil #'zr-shadowfile--automatic-copy pair task
                            (zr-shadowfile--task-revision task)
                            (zr-shadowfile--task-timer-token task)))))
     zr-shadowfile--pending)))

(defun zr-shadowfile--automatic-copy (pair task revision token)
  "Copy PAIR once TASK's saved REVISION has remained unchanged until its deadline."
  (when (and zr-shadowfile--active zr-shadowfile-mode
             (eq task (gethash pair zr-shadowfile--pending))
             (eq token (zr-shadowfile--task-timer-token task))
             (eql revision (zr-shadowfile--task-revision task))
             (zr-shadowfile--task-deadline task))
    (setf (zr-shadowfile--task-timer task) nil
          (zr-shadowfile--task-timer-token task) nil)
    (unless zr-shadowfile--inhibit-automatic
      (if (> (zr-shadowfile--task-deadline task) (float-time))
          (zr-shadowfile--schedule-pending)
        (setf (zr-shadowfile--task-ready task) t)
        (condition-case err
            (with-current-buffer
                (if (buffer-live-p (zr-shadowfile--task-buffer task))
                    (zr-shadowfile--task-buffer task) (current-buffer))
              (zr-shadowfile--start-batch (list pair) t t))
          (error (message "Cannot start automatic copy: %s" (error-message-string err))))))))

(defun zr-shadowfile--enqueue (file destination &optional async changed)
  "Queue FILE to DESTINATION, returning 1 for a new task or 0 for a duplicate.
ASYNC sets the new revision's copy policy.  CHANGED resets its save delay."
  (let* ((pair (cons file destination))
         (existing (gethash pair zr-shadowfile--pending))
         (task (or existing (zr-shadowfile--make-task :async async)))
         (ready (zr-shadowfile--task-ready task)))
    (zr-shadowfile--cancel-task-timer task)
    (unless (equal async (zr-shadowfile--task-async task))
      (setf (zr-shadowfile--task-async task) async
            (zr-shadowfile--task-deadline task) nil
            (zr-shadowfile--task-ready task) nil)
      (setq zr-shadowfile--pending-dirty t)
      (when (and ready (not (numberp async)) zr-shadowfile--batch)
        (setf (zr-shadowfile--batch-tasks zr-shadowfile--batch)
              (cl-remove pair (zr-shadowfile--batch-tasks zr-shadowfile--batch) :test #'equal))))
    (setf (zr-shadowfile--task-revision task) (cl-incf zr-shadowfile--revision)
          (zr-shadowfile--task-buffer task) (current-buffer))
    (when (and changed (numberp (zr-shadowfile--task-async task)))
      (setf (zr-shadowfile--task-deadline task)
            (+ (float-time) (zr-shadowfile--task-async task))
            (zr-shadowfile--task-ready task) nil)
      (setq zr-shadowfile--pending-dirty t))
    (puthash pair task zr-shadowfile--pending)
    (unless existing (setq zr-shadowfile--pending-dirty t))
    (if existing 0 1)))

(defun zr-shadowfile--queue-file (file rules &optional changed)
  "Queue FILE under RULES and return the number of new copies.
CHANGED indicates a successful save, enabling automatic copy delays."
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
                  (expand-file-name relative (plist-get rule :destination)))
           (plist-get rule :async) changed))))
    (- (hash-table-count zr-shadowfile--pending) before)))

(defun zr-shadowfile--after-save ()
  "Queue a successfully saved file and persist its new copy tasks."
  (when (buffer-file-name)
    (condition-case err
        (let* ((file (zr-shadowfile--expand-path (buffer-file-name)))
               (count (zr-shadowfile--queue-file file (zr-shadowfile--rules) t)))
          (when zr-shadowfile--pending-dirty (zr-shadowfile--write-pending))
          (when (> count 0)
            (if (cl-some (lambda (pair)
                           (and (equal (car pair) file)
                                (zr-shadowfile--task-deadline
                                 (gethash pair zr-shadowfile--pending))))
                         (zr-shadowfile--pending-copies))
                (message "Automatic copy scheduled after saving %s" file)
              (message "%s" (substitute-command-keys
                             "Use \\[zr-shadowfile-copy-files] to copy pending files.")))))
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

(defun zr-shadowfile--discard (pair revision)
  "Discard PAIR only if its pending revision still equals REVISION."
  (when-let* ((task (gethash pair zr-shadowfile--pending))
              ((eql revision (zr-shadowfile--task-revision task))))
    (zr-shadowfile--cancel-task-timer task)
    (remhash pair zr-shadowfile--pending)
    (setq zr-shadowfile--pending-dirty t)))

(defun zr-shadowfile--source-exists-p (pair)
  "Return whether PAIR's source exists, discarding the task if missing.
If checking fails, report the error and retain the task for a later retry."
  (let* ((task (gethash pair zr-shadowfile--pending))
         (revision (when task (zr-shadowfile--task-revision task))))
    (condition-case err
        (if (file-exists-p (car pair)) t
          (zr-shadowfile--discard pair revision)
          nil)
      (error (message "Cannot check source %s: %s" (car pair) (error-message-string err)) nil))))

(defun zr-shadowfile--webdav-copy-p (pair)
  "Whether PAIR can use the asynchronous local/WebDAV copier."
  (let ((source (file-remote-p (car pair) 'method))
        (target (file-remote-p (cdr pair) 'method)))
    (and (or (member source '("webdav" "webdavs"))
             (member target '("webdav" "webdavs")))
         (or (null source) (member source '("webdav" "webdavs")))
         (or (null target) (member target '("webdav" "webdavs"))))))

(defun zr-shadowfile--async-copy-p (pair)
  "Whether PAIR requests and supports background copying."
  (when-let* ((task (gethash pair zr-shadowfile--pending)))
    (and (zr-shadowfile--task-async task) (zr-shadowfile--webdav-copy-p pair))))

(defun zr-shadowfile--queue-copy (batch pair)
  "Add PAIR to BATCH unless its current revision is already requested."
  (when-let* ((task (gethash pair zr-shadowfile--pending)))
    (unless (member pair (zr-shadowfile--batch-copies batch))
      (setf (zr-shadowfile--batch-copies batch)
            (append (zr-shadowfile--batch-copies batch) (list pair))))
    (unless (or (member pair (zr-shadowfile--batch-tasks batch))
                (and (equal pair (car (zr-shadowfile--batch-job batch)))
                     (eql (zr-shadowfile--task-revision task)
                          (cdr (zr-shadowfile--batch-job batch)))))
      (setf (zr-shadowfile--batch-tasks batch)
            (append (zr-shadowfile--batch-tasks batch) (list pair))))))

(defun zr-shadowfile--copy-file (pair)
  "Synchronously copy PAIR's saved bytes through the ordinary file APIs."
  (make-directory (file-name-directory (cdr pair)) t)
  (copy-file (car pair) (cdr pair) t))

(defun zr-shadowfile--complete-copy (batch job success error &optional automatic)
  "Record JOB's SUCCESS or ERROR only while it belongs to active BATCH."
  (when (and (eq batch zr-shadowfile--batch)
             (eq job (zr-shadowfile--batch-job batch)))
    (setf (zr-shadowfile--batch-job batch) nil
          (zr-shadowfile--batch-cancel batch) nil)
    (let* ((pair (car job))
           (revision (cdr job))
           (missing
            (and (eq (car-safe error) 'file-missing)
                 (or (member (car pair) (cdr error))
                     (and (not (file-remote-p (car pair)))
                          (condition-case nil (not (file-exists-p (car pair)))
                            (error nil)))))))
      (when success (cl-incf (zr-shadowfile--batch-copied batch)))
      (cond
       ((or success missing)
        (zr-shadowfile--discard pair revision)
        ;; An approved target saved again during copying needs another pass.
        (when-let* ((task (gethash pair zr-shadowfile--pending))
                    ((or (not automatic)
                         (and (numberp (zr-shadowfile--task-async task))
                              (zr-shadowfile--task-deadline task))))
                    ((or (not (zr-shadowfile--task-deadline task))
                         (<= (zr-shadowfile--task-deadline task) (float-time)))))
          (zr-shadowfile--queue-copy batch pair)))
       (error
        (push job (zr-shadowfile--batch-failed batch))
        (message "Cannot copy %s: %s" (cdr pair) (error-message-string error))))
      (when zr-shadowfile--pending-dirty
        (condition-case err (zr-shadowfile--write-pending)
          (error (message "Cannot save pending copies: %s" (error-message-string err))))))))

(defun zr-shadowfile--schedule-next (batch)
  "Continue BATCH from the event loop after a completed transfer."
  (when (and (eq batch zr-shadowfile--batch)
             (not (zr-shadowfile--batch-done batch))
             (not (zr-shadowfile--batch-job batch))
             (not (zr-shadowfile--batch-timer batch)))
    (setf (zr-shadowfile--batch-timer batch)
          (run-at-time 0 nil #'zr-shadowfile--next-copy batch))))

(defun zr-shadowfile--next-copy (batch)
  "Run synchronous tasks in BATCH until an asynchronous task starts."
  (when (eq batch zr-shadowfile--batch)
    (when-let* ((timer (zr-shadowfile--batch-timer batch))) (cancel-timer timer))
    (setf (zr-shadowfile--batch-timer batch) nil)
    (condition-case err
        (while (and (eq batch zr-shadowfile--batch)
                    (zr-shadowfile--batch-tasks batch)
                    (not (zr-shadowfile--batch-job batch))
                    (not (zr-shadowfile--batch-timer batch)))
          (let* ((pair (pop (zr-shadowfile--batch-tasks batch)))
                 (task (gethash pair zr-shadowfile--pending)))
            (when (and task
                       (or (not (zr-shadowfile--task-deadline task))
                           (<= (zr-shadowfile--task-deadline task) (float-time))))
              (let ((job (cons pair (zr-shadowfile--task-revision task)))
                    (automatic (not (null (zr-shadowfile--task-deadline task)))))
                (setf (zr-shadowfile--batch-job batch) job)
                (condition-case err
                    (progn
                      (zr-shadowfile--cancel-task-timer task)
                      (when (zr-shadowfile--task-deadline task)
                        (setf (zr-shadowfile--task-deadline task) nil
                              (zr-shadowfile--task-ready task) nil)
                        (setq zr-shadowfile--pending-dirty t))
                      (when zr-shadowfile--pending-dirty (zr-shadowfile--write-pending))
                      (if (zr-shadowfile--async-copy-p pair)
                          (progn
                            (require 'zr-tramp-webdav)
                            (let ((cancel
                                   (with-current-buffer
                                       (cond ((buffer-live-p (zr-shadowfile--task-buffer task))
                                              (zr-shadowfile--task-buffer task))
                                             ((buffer-live-p (zr-shadowfile--batch-buffer batch))
                                              (zr-shadowfile--batch-buffer batch))
                                             (t (current-buffer)))
                                     (zr-tramp-webdav-copy-file-async
                                      (car pair) (cdr pair)
                                      (lambda (success error)
                                        (zr-shadowfile--complete-copy batch job success error automatic)
                                        (zr-shadowfile--schedule-next batch))))))
                              (when (eq job (zr-shadowfile--batch-job batch))
                                (setf (zr-shadowfile--batch-cancel batch) cancel))))
                        (zr-shadowfile--copy-file pair)
                        (zr-shadowfile--complete-copy batch job t nil automatic)))
                  (error (zr-shadowfile--complete-copy batch job nil err automatic)))))))
      (quit (zr-shadowfile--stop-batch) (signal (car err) (cdr err))))
    (when (and (eq batch zr-shadowfile--batch)
               (not (zr-shadowfile--batch-tasks batch))
               (not (zr-shadowfile--batch-job batch)))
      (when-let* ((timer (zr-shadowfile--batch-timer batch))) (cancel-timer timer))
      (setf (zr-shadowfile--batch-timer batch) nil
            (zr-shadowfile--batch-done batch) t)
      (setq zr-shadowfile--batch nil)
      (message "Copied %d files; %d copies pending"
               (zr-shadowfile--batch-copied batch) (hash-table-count zr-shadowfile--pending)))))

(defun zr-shadowfile--stop-batch ()
  "Stop the current batch, retaining all unconfirmed pending copies."
  (when-let* ((batch zr-shadowfile--batch))
    ;; Invalidate callbacks before cancelling the transport.
    (setq zr-shadowfile--batch nil)
    (setf (zr-shadowfile--batch-done batch) t
          (zr-shadowfile--batch-job batch) nil)
    (when-let* ((timer (zr-shadowfile--batch-timer batch))) (cancel-timer timer))
    (when-let* ((cancel (zr-shadowfile--batch-cancel batch))) (funcall cancel))
    (setf (zr-shadowfile--batch-timer batch) nil
          (zr-shadowfile--batch-cancel batch) nil)))

(defun zr-shadowfile--start-batch (copies noquery &optional automatic)
  "Ask about COPIES and add them to a serial batch, honoring NOQUERY.
AUTOMATIC accepts only tasks whose saved deadlines have elapsed."
  (let (selected)
    (unwind-protect
        (map-y-or-n-p
         (lambda (pair)
           (when-let* ((task (gethash pair zr-shadowfile--pending))
                       ((or (not automatic)
                            (and (numberp (zr-shadowfile--task-async task))
                                 (zr-shadowfile--task-deadline task)
                                 (<= (zr-shadowfile--task-deadline task) (float-time))))))
             (and (or (and (zr-shadowfile--async-copy-p pair) (file-remote-p (car pair)))
                      (zr-shadowfile--source-exists-p pair))
                  (or noquery zr-shadowfile-noquery
                      (zr-shadowfile--task-deadline task)
                      (and zr-shadowfile--batch
                           (or (member pair (zr-shadowfile--batch-tasks zr-shadowfile--batch))
                               (equal pair (car (zr-shadowfile--batch-job zr-shadowfile--batch)))))
                      (format "Copy %s to %s? " (car pair) (cdr pair))))))
         (lambda (pair)
           (push pair selected)
           (unless automatic
             (let ((task (gethash pair zr-shadowfile--pending)))
               (zr-shadowfile--cancel-task-timer task)
               (when (zr-shadowfile--task-deadline task)
                 (setf (zr-shadowfile--task-deadline task) nil
                       (zr-shadowfile--task-ready task) nil)
                 (setq zr-shadowfile--pending-dirty t))
               (setf (zr-shadowfile--task-buffer task) (current-buffer))))
           t)
         copies '("file" "files" "copy"))
      (zr-shadowfile--write-pending))
    (let ((batch (or zr-shadowfile--batch
                     (zr-shadowfile--make-batch :buffer (current-buffer)))))
      (dolist (pair (nreverse selected)) (zr-shadowfile--queue-copy batch pair))
      (setq zr-shadowfile--batch batch)
      (unless (zr-shadowfile--batch-job batch) (zr-shadowfile--next-copy batch))
      (unless (zr-shadowfile--batch-done batch)
        (message "Copying %d files in background" (length (zr-shadowfile--batch-copies batch))))
      batch)))

;;;###autoload
(defun zr-shadowfile-copy-files (&optional noquery)
  "Copy pending files, asking unless NOQUERY or `zr-shadowfile-noquery' is set.
With a prefix argument, copy without asking.  Copy the saved disk bytes,
create destination parent directories, and retain failed or skipped tasks.
Copies are synchronous unless their rule's :async requests background
local/WebDAV copying.  Explicit copying bypasses automatic save delays.
Return a batch for `zr-shadowfile-wait', adding tasks to any active batch
without duplicating in-flight copies.  Sources are checked asynchronously
only when their tasks request and support background copies."
  (interactive "P")
  (unless zr-shadowfile-mode (zr-shadowfile-mode 1))
  (zr-shadowfile--start-batch (zr-shadowfile--pending-copies) noquery))

;;;###autoload
(defun zr-shadowfile-wait (&optional batch timeout)
  "Wait for BATCH or the active batch, returning its successful copy count.
With TIMEOUT, stop unfinished work after that many seconds, keeping tasks
pending.  Quitting also stops the batch and preserves unconfirmed copies."
  (interactive)
  (let ((batch (or batch zr-shadowfile--batch))
        (deadline (when timeout (+ (float-time) timeout))))
    (if (not batch) 0
      (save-excursion
        (unwind-protect
            (progn
              (while (and (not (zr-shadowfile--batch-done batch))
                          (or (not deadline) (< (float-time) deadline)))
                (accept-process-output nil 0.05))
              (unless (zr-shadowfile--batch-done batch)
                (message "Copy wait timed out; unfinished copies remain pending"))
              (zr-shadowfile--batch-copied batch))
          (unless (zr-shadowfile--batch-done batch) (zr-shadowfile--stop-batch)))))))

;;;###autoload
(defun zr-shadowfile-cancel (&optional all)
  "Cancel selected pending copies and their active transfers.
With a prefix argument ALL, cancel every pending copy."
  (interactive "P")
  (unless zr-shadowfile-mode (zr-shadowfile-mode 1))
  (let ((cancelled 0))
    (unwind-protect
        (map-y-or-n-p
         (lambda (pair) (or all (format "Cancel copying %s to %s? " (car pair) (cdr pair))))
         (lambda (pair)
           (when-let* ((task (gethash pair zr-shadowfile--pending)))
             (zr-shadowfile--cancel-task-timer task))
           (remhash pair zr-shadowfile--pending)
           (setq zr-shadowfile--pending-dirty t)
           (when-let* ((batch zr-shadowfile--batch))
             (setf (zr-shadowfile--batch-tasks batch)
                   (cl-remove pair (zr-shadowfile--batch-tasks batch) :test #'equal))
             (when (equal pair (car (zr-shadowfile--batch-job batch)))
               (let ((cancel (zr-shadowfile--batch-cancel batch)))
                 (setf (zr-shadowfile--batch-job batch) nil
                       (zr-shadowfile--batch-cancel batch) nil)
                 (when cancel (funcall cancel))))
             (zr-shadowfile--schedule-next batch))
           (cl-incf cancelled) t)
         (zr-shadowfile--pending-copies) '("copy" "copies" "cancel"))
      (zr-shadowfile--write-pending))
    (when (and zr-shadowfile--batch
               (not (zr-shadowfile--batch-tasks zr-shadowfile--batch))
               (not (zr-shadowfile--batch-job zr-shadowfile--batch)))
      (zr-shadowfile--next-copy zr-shadowfile--batch))
    cancelled))

(defun zr-shadowfile--query-exit ()
  "Wait for offered copies, asking before exiting with remaining tasks."
  (let (proceed)
    (unwind-protect
        (let ((zr-shadowfile--inhibit-automatic t))
          (zr-shadowfile--cancel-timers)
          (setq proceed
                (if (not zr-shadowfile-copy-on-exit)
                    (progn (zr-shadowfile--stop-batch) (zr-shadowfile--write-pending) t)
                  (unless (and (numberp zr-shadowfile-exit-timeout)
                               (> zr-shadowfile-exit-timeout 0))
                    (user-error "Exit copy timeout must be positive"))
                  (let ((batch zr-shadowfile--batch)
                        (timeout zr-shadowfile-exit-timeout))
                    (when batch
                      (let ((started (float-time)))
                        (zr-shadowfile-wait batch timeout)
                        (setq timeout (- timeout (- (float-time) started)))))
                    ;; Skip failed revisions we just waited for, but offer
                    ;; later saves, including files copied earlier in the batch.
                    (let ((failed (when batch (zr-shadowfile--batch-failed batch))))
                      (when-let* ((copies (cl-remove-if
                                           (lambda (pair)
                                             (eql (zr-shadowfile--task-revision
                                                   (gethash pair zr-shadowfile--pending))
                                                  (cdr (assoc pair failed))))
                                           (zr-shadowfile--pending-copies)))
                                  ((> timeout 0)))
                        (zr-shadowfile-wait (zr-shadowfile--start-batch copies nil) timeout)))
                    (zr-shadowfile--write-pending)
                    (or (zerop (hash-table-count zr-shadowfile--pending))
                        (yes-or-no-p
                         (format "%d copies remain pending.  Exit Emacs anyway? "
                                 (hash-table-count zr-shadowfile--pending))))))))
      (unless proceed (zr-shadowfile--schedule-pending)))))

(defun zr-shadowfile--kill-emacs ()
  "Stop background work and persist tasks without network requests or queries."
  (let ((inhibit-quit t)
        (zr-shadowfile--inhibit-automatic t))
    (zr-shadowfile--cancel-timers)
    (zr-shadowfile--stop-batch)
    (zr-shadowfile--write-pending)))

(defun zr-shadowfile--disable ()
  "Remove this mode's hooks and release its local state file."
  (zr-shadowfile--cancel-timers)
  (zr-shadowfile--stop-batch)
  (remove-hook 'after-save-hook #'zr-shadowfile--after-save)
  (remove-hook 'kill-emacs-query-functions #'zr-shadowfile--query-exit)
  (remove-hook 'kill-emacs-hook #'zr-shadowfile--kill-emacs)
  (when (and zr-shadowfile--state-file (not (file-remote-p zr-shadowfile--state-file))
             (eq t (file-locked-p zr-shadowfile--state-file)))
    (unlock-file zr-shadowfile--state-file))
  (setq zr-shadowfile--active nil zr-shadowfile--state-file nil))

;;;###autoload
(define-minor-mode zr-shadowfile-mode
  "Queue file and directory copies globally according to `zr-shadowfile-rules'.
Successful saves queue and persist tasks.  C-x 4 s copies their saved disk
bytes synchronously unless :async opts into background local/WebDAV copying.
Numeric :async settings automatically copy after the last save's delay.
Exiting offers and waits for copies when `zr-shadowfile-copy-on-exit' is set,
asking if any remain pending.  Disabling stops copies and timers,
retaining pending tasks."
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
              (add-hook 'kill-emacs-hook #'zr-shadowfile--kill-emacs)
              (setq zr-shadowfile--active t)
              (zr-shadowfile--schedule-pending))
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
