;;; zr-czkawka.el --- Czkawka CLI integration with Dired -*- lexical-binding: t; -*-

;; Author: kkkykin
;; Keywords: files, tools
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Integration with `czkawka_cli' to find and manage files using Dired
;; and `dired-virtual-mode'.
;;
;; Results are presented as virtual subdirectories inside a Dired
;; buffer, one per group of similar files, or a single one listing the
;; files found, enabling standard Dired navigation, marking, and
;; deletion.
;;
;; Commands:
;;   `zr-czkawka-dup' - Find duplicate files.
;;   `zr-czkawka-big' - List the biggest or smallest files.
;;   `zr-czkawka-image' - Find similar images.
;;   `zr-czkawka-music' - Find the same music by tags or content.
;;   `zr-czkawka-video' - Find similar videos.
;;
;; With a prefix argument, each command reads raw czkawka arguments
;; instead of prompting for directories and options.
;;
;; Keys in result buffers:
;;   g - Re-run the scan; with prefix argument, edit arguments.
;;   s - Sort each group by name or date; with prefix argument, edit
;;       the `ls' switches.  This redisplays without re-running the scan.
;;   d / u / x - Standard Dired flagging, unmarking, and deletion.
;;   $ - Collapse or expand a group.
;;
;; Keys in buffers showing groups of similar files:
;;   % n - Flag all files except the newest in each group.
;;   % o - Flag all files except the oldest in each group.
;;   % f - Flag all files except the first in each group.
;;   % b - Flag all files except the biggest in each group.
;;   % p - Flag all files except the one with the highest resolution
;;         in each group, for images and videos.
;;
;; Files are listed with `insert-directory' (`ls' or `ls-lisp') using
;; the Dired listing switches, and each group is sorted as `ls' would
;; sort it with those switches, reference files first.  Details found
;; by czkawka, such as image sizes or music tags, are shown after the
;; file names.
;;
;; The flagging commands only consider files still listed in the buffer
;; and present on disk, clear existing flags in the affected groups
;; first, and never flag reference files (from `-r'), so each group
;; always keeps at least one file.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dired-x)
(require 'subr-x)

(defgroup zr-czkawka nil
  "Czkawka CLI integration with Dired."
  :group 'files)

(defcustom zr-czkawka-program "czkawka_cli"
  "Path to the czkawka_cli executable."
  :type 'file)

(defcustom zr-czkawka-buffer-name-format "*zr-czkawka-%s*"
  "Format of result buffer names; %s is replaced by the czkawka tool name."
  :type 'string)

(defface zr-czkawka-annotation '((t :inherit shadow))
  "Face for file details shown after file names.")

(defcustom zr-czkawka-dup-search-method "HASH"
  "Default search method for duplicate files.
Choices are \"HASH\", \"SIZE\", or \"NAME\"."
  :type '(choice (const "HASH")
                 (const "SIZE")
                 (const "NAME")))

(defcustom zr-czkawka-dup-min-file-size 1
  "Minimum file size in bytes for duplicate search, or nil for CLI default."
  :type '(choice (const :tag "Default (8192)" nil)
                 (integer :tag "Bytes")))

(defcustom zr-czkawka-dup-hash-type "BLAKE3"
  "Hash algorithm used when search method is HASH.
Supported values include \"BLAKE3\", \"CRC32\", \"XXH3\"."
  :type '(choice (const "BLAKE3")
                 (const "CRC32")
                 (const "XXH3")))

(defvar zr-czkawka-directory-history nil
  "History of scanned directories.")

(defvar zr-czkawka-raw-args-history nil
  "History of raw command arguments entered via prefix argument.")

(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (dolist (var '(zr-czkawka-directory-history
                 zr-czkawka-raw-args-history))
    (add-to-list 'savehist-additional-variables var)))

(defvar zr-czkawka-process-buffer-name "*zr-czkawka-process*"
  "Name of the buffer holding czkawka process output.")

(cl-defstruct (zr-czkawka-tool (:constructor zr-czkawka-tool-create)
                               (:copier nil))
  "A czkawka tool and how its results are displayed."
  (name nil :documentation "The czkawka_cli subcommand.")
  (title nil :documentation "Title of the result buffer.")
  (parse nil :documentation "Function turning the JSON output into groups.
Each group is an alist with its 1-based `id' and its `files', each an
alist with at least `path', `size' and `modified_date'.")
  (grouped t :documentation "Non-nil if results are groups of similar files.
Otherwise they are a single group listing the files found.")
  (group-info nil :documentation "Function returning extra text for the
heading of a group, or nil.")
  (annotate nil :documentation "Function returning the details shown after
a file, or nil.")
  (extra-switches nil :documentation "Switches appended to
`dired-listing-switches' in new result buffers, or nil.")
  (keymap nil :documentation "Keymap of the result buffer.")
  (keys nil :documentation "Key hints shown in the header line.")
  (fix nil :documentation "Confirmation prompt of `zr-czkawka-fix' with
%d for the number of files, or nil if the tool cannot fix files."))

(defvar-local zr-czkawka--tool nil
  "The `zr-czkawka-tool' of the current results.")

(defvar-local zr-czkawka--params nil
  "Plist of parameters used to generate the current results.
:args is the list of czkawka arguments after the tool name and
:directory is the top directory of the Virtual Dired buffer.")

(defvar-local zr-czkawka--groups nil
  "Groups of the current results, as returned by the tool's parser.")

;;; Process execution

(defun zr-czkawka--read-json (file)
  "Parse czkawka JSON output in FILE, or return nil if FILE is empty."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (unless (zerop (buffer-size))
      (json-parse-buffer :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil))))

(defun zr-czkawka--output-matches-p (buffer string)
  "Return non-nil if czkawka output in BUFFER contains STRING."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (search-forward string nil t))))

(defun zr-czkawka-run (args callback &optional error-callback)
  "Execute `zr-czkawka-program' with ARGS asynchronously.
ARGS starts with the tool name.  Ensure JSON output is captured in a
temporary file and parsed.  On success, invoke CALLBACK with the
parsed JSON data.  On failure, invoke ERROR-CALLBACK with the exit
code and process buffer, or display the process buffer.  czkawka
exits with code 0 even when it cannot start a scan, so a critical
error in its output is a failure too."
  (unless (executable-find zr-czkawka-program)
    (unless (file-executable-p zr-czkawka-program)
      (user-error "Czkawka executable not found: %s" zr-czkawka-program)))
  (let* ((temp-file (make-temp-file "zr-czkawka-" nil ".json"))
         (proc-buf (get-buffer-create zr-czkawka-process-buffer-name))
         ;; Right after the tool name, before any subcommand of the tool.
         (full-args (append (list (car args) "-N" "-W" "-C" temp-file)
                            (cdr args)))
         (cmd (cons zr-czkawka-program full-args)))
    (with-current-buffer proc-buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "Running czkawka %s..." (car args))
    (condition-case err
        (make-process
         :name "zr-czkawka"
         :buffer proc-buf
         :command cmd
         :connection-type 'pipe
         :coding 'utf-8-unix
         :noquery t
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let* ((exit-code (process-exit-status proc))
                    (result
                     (when (and (zerop exit-code)
                                (not (zr-czkawka--output-matches-p
                                      proc-buf "CRITICAL ERROR")))
                       (condition-case err
                           (list (zr-czkawka--read-json temp-file))
                         (error
                          (with-current-buffer proc-buf
                            (let ((inhibit-read-only t))
                              (goto-char (point-max))
                              (insert (format "\nFailed to parse czkawka JSON: %s\n"
                                              (error-message-string err)))))
                          nil)))))
               (ignore-errors (delete-file temp-file))
               (cond
                (result (funcall callback (car result)))
                (error-callback (funcall error-callback exit-code proc-buf))
                (t
                 (display-buffer proc-buf)
                 (message "czkawka failed (exit code %s); see %s"
                          exit-code (buffer-name proc-buf))))))))
      (error
       (ignore-errors (delete-file temp-file))
       (signal (car err) (cdr err))))))

;;; JSON parsing

(defun zr-czkawka--file-p (obj)
  "Return non-nil if OBJ is a czkawka file entry alist."
  (and (consp obj) (consp (car obj)) (assq 'path obj)))

(defun zr-czkawka--collect (val)
  "Collect groups of similar files from JSON value VAL.
Return a list of (REFERENCE . FILES), where REFERENCE is the
reference file entry (from `-r') or nil.  VAL is a plain group (a
list of file entries), a reference entry (a file entry followed by
a list of file entries), or a list of those."
  (cond
   ((not (zr-czkawka--file-p (car val)))
    (mapcan #'zr-czkawka--collect val))
   ((and (cdr val) (not (zr-czkawka--file-p (cadr val))))
    (list (cons (car val) (cadr val))))
   (t (list (cons nil val)))))

(defun zr-czkawka--make-groups (groups)
  "Number GROUPS as returned by `zr-czkawka--collect'.
Return a list of group alists with the 1-based `id' and the `files'.
A reference file is listed first with an additional (reference . t)."
  (let ((id 0))
    (mapcar (lambda (grp)
              `((id . ,(cl-incf id))
                (files . ,(if (car grp)
                              (cons (cons '(reference . t) (car grp)) (cdr grp))
                            (cdr grp)))))
            groups)))

(defun zr-czkawka--parse-groups (data)
  "Parse DATA, a JSON list of groups of similar files, into groups."
  (zr-czkawka--make-groups (zr-czkawka--collect data)))

(defun zr-czkawka--remove-keys (groups &rest keys)
  "Remove KEYS from the files of GROUPS, to save memory.
Return GROUPS."
  (dolist (grp groups groups)
    (setf (alist-get 'files grp)
          (mapcar (lambda (f) (cl-remove-if (lambda (e) (memq (car e) keys)) f))
                  (alist-get 'files grp)))))

(defun zr-czkawka--nonempty (value)
  "Return VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun zr-czkawka--format-duration (seconds)
  "Return SECONDS formatted as [H:]MM:SS, or nil if it is not positive."
  (when (and (numberp seconds) (> seconds 0))
    (let ((s (truncate seconds)))
      (if (>= s 3600)
          (format "%d:%02d:%02d" (/ s 3600) (% (/ s 60) 60) (% s 60))
        (format "%d:%02d" (/ s 60) (% s 60))))))

(defun zr-czkawka--parse-files (data)
  "Parse DATA, a JSON list of files, into a single group."
  (and data `(((id . 1) (files . ,data)))))

;;; Virtual Dired Buffer Rendering

(defvar zr-czkawka-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap revert-buffer] #'zr-czkawka-rescan)
    map)
  "Keymap for `zr-czkawka-mode'.")

(defvar zr-czkawka-group-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map zr-czkawka-mode-map)
    (define-key map (kbd "% n") #'zr-czkawka-flag-all-except-newest)
    (define-key map (kbd "% o") #'zr-czkawka-flag-all-except-oldest)
    (define-key map (kbd "% f") #'zr-czkawka-flag-all-except-first)
    (define-key map (kbd "% b") #'zr-czkawka-flag-all-except-biggest)
    map)
  "Keymap of result buffers showing groups of similar files.")

(defconst zr-czkawka--group-keys
  "[d] Flag [x] Delete [%% n] Keep newest [%% o] Keep oldest [%% f] Keep first [%% b] Keep biggest [g] Refresh"
  "Header line key hints of result buffers showing groups.")

(defvar zr-czkawka-media-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map zr-czkawka-group-map)
    (define-key map (kbd "% p") #'zr-czkawka-flag-all-except-highest-resolution)
    map)
  "Keymap of result buffers showing groups of similar images or videos.")

(defconst zr-czkawka--media-keys
  (concat zr-czkawka--group-keys " [%% p] Keep highest resolution")
  "Header line key hints of result buffers showing images or videos.")

(define-minor-mode zr-czkawka-mode
  "Minor mode for czkawka results in a Virtual Dired buffer.
The keymap depends on the czkawka tool of the results.
\\{zr-czkawka-mode-map}"
  :lighter " Czkawka"
  :keymap zr-czkawka-mode-map)

(defun zr-czkawka--sort-files (files switches)
  "Return FILES still on disk, sorted as `ls' sorts them with SWITCHES.
Recognize the sort switches -t, -S, -X, -v, -U and -r, their long
forms, and -c, -u and --time selecting the time to sort by.  Keep
reference files first."
  (let ((key "name") (time "mtime") reverse)
    (dolist (switch (split-string-and-unquote switches))
      (cond
       ((string-prefix-p "--sort=" switch) (setq key (substring switch 7)))
       ((string-prefix-p "--time=" switch) (setq time (substring switch 7)))
       ((equal switch "--reverse") (setq reverse t))
       ((string-match-p "\\`-[^-]" switch)
        (dolist (char (string-to-list (substring switch 1)))
          (pcase char
            (?t (setq key "time"))
            (?S (setq key "size"))
            (?X (setq key "extension"))
            (?v (setq key "version"))
            (?U (setq key "none"))
            (?c (setq time "ctime"))
            (?u (setq time "atime"))
            (?r (setq reverse t)))))))
    ;; Each entry is (PATH ATTRIBUTES FILE).
    (let ((entries (cl-loop for file in files
                            for path = (alist-get 'path file)
                            for attrs = (file-attributes path)
                            when attrs collect (list path attrs file))))
      (unless (equal key "none")
        ;; `sort' is stable, so sorting by name first breaks ties as `ls' does.
        (setq entries (sort entries
                            (lambda (a b)
                              (funcall (if (equal key "version")
                                           #'string-version-lessp
                                         #'string-collate-lessp)
                                       (car a) (car b)))))
        (when-let* ((lessp
                     (pcase key
                       ("time"
                        (let ((file-time
                               (pcase time
                                 ((or "atime" "access" "use") #'file-attribute-access-time)
                                 ((or "ctime" "status") #'file-attribute-status-change-time)
                                 (_ #'file-attribute-modification-time))))
                          (lambda (a b)
                            (time-less-p (funcall file-time (nth 1 b))
                                         (funcall file-time (nth 1 a))))))
                       ("size"
                        (lambda (a b)
                          (> (file-attribute-size (nth 1 a))
                             (file-attribute-size (nth 1 b)))))
                       ("extension"
                        (lambda (a b)
                          (string< (or (file-name-extension (car a)) "")
                                   (or (file-name-extension (car b)) "")))))))
          (setq entries (sort entries lessp)))
        (when reverse
          (setq entries (nreverse entries))))
      (sort (mapcar #'caddr entries)
            (lambda (a b)
              (and (alist-get 'reference a) (not (alist-get 'reference b))))))))

(defun zr-czkawka--tag-line (beg group-id &optional file)
  "Tag the line from BEG to point with GROUP-ID and FILE text properties.
The properties skip the first column, which Dired rewrites when marking."
  (add-text-properties (1+ beg) (1- (point))
                       (list 'zr-czkawka-group group-id
                             'zr-czkawka-file file)))

(defun zr-czkawka--insert-file (file group-id directory)
  "Insert the listing line of FILE in GROUP-ID.
List it with `dired-actual-switches' as Dired lists an explicit file
list, through `insert-directory'.  DIRECTORY is the top directory.
Show the details of FILE given by the tool after its name."
  (let ((beg (point)))
    (save-restriction
      ;; Hide the preceding lines from `dired-insert-directory', so that
      ;; the line is aligned only below, once it is indented.
      (narrow-to-region beg beg)
      (dired-insert-directory directory dired-actual-switches
                              (list (alist-get 'path file))))
    ;; Columns must include the details `dired-hide-details-mode' hides.
    (let ((buffer-invisibility-spec nil))
      (dired-align-file beg (point)))
    (zr-czkawka--tag-line beg group-id file)
    (when-let* ((annotate (zr-czkawka-tool-annotate zr-czkawka--tool))
                (text (funcall annotate file))
                ((not (string-empty-p text)))
                (start (save-excursion
                         (goto-char beg)
                         (dired-move-to-filename))))
      ;; An overlay leaves the line as Dired parses it, and evaporates
      ;; with the line, e.g. when the file is deleted.
      (let ((ov (make-overlay start (1- (point)))))
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'after-string
                     (propertize (concat "  " text)
                                 'face 'zr-czkawka-annotation))))))

(defun zr-czkawka--files-size (files)
  "Return the total size in bytes of FILES."
  (apply #'+ (mapcar (lambda (f) (or (alist-get 'size f) 0)) files)))

(defun zr-czkawka--wasted-size (files)
  "Return the size in bytes that deleting all but one of FILES saves.
The reference file is kept if any, and otherwise the biggest file."
  (let ((sizes (mapcar (lambda (f) (or (alist-get 'size f) 0))
                       (cl-remove-if (lambda (f) (alist-get 'reference f))
                                     files))))
    (if (alist-get 'reference (car files))
        (apply #'+ sizes)
      (- (apply #'+ sizes) (apply #'max sizes)))))

(defun zr-czkawka--insert-groups ()
  "Replace the buffer contents with the groups of the current results.
List files with `dired-actual-switches', skipping files no longer on
disk and groups left without files, and update the header line."
  (let* ((tool zr-czkawka--tool)
         (grouped (zr-czkawka-tool-grouped tool))
         (directory (plist-get zr-czkawka--params :directory))
         (inhibit-read-only t)
         (total-groups 0)
         (total-files 0)
         (total-size 0))
    (when (consp buffer-undo-list)
      (setq buffer-undo-list nil))
    (let ((buffer-undo-list t))
      (erase-buffer)
      (dolist (grp zr-czkawka--groups)
        (when-let* ((files (zr-czkawka--sort-files (alist-get 'files grp)
                                                   dired-actual-switches)))
          (let* ((id (alist-get 'id grp))
                 (size (zr-czkawka--files-size files))
                 (info (or (when-let* ((fn (zr-czkawka-tool-group-info tool)))
                             (funcall fn grp))
                           ""))
                 (beg (point)))
            (insert
             (if grouped
                 (format "  // Group %d [%d files%s%s]:\n"
                         id (length files)
                         (if (alist-get 'reference (car files)) ", 1 reference" "")
                         info)
               (format "  // %s [%d files, %s%s]:\n"
                       (zr-czkawka-tool-title tool) (length files)
                       (file-size-human-readable size 'iec) info)))
            (zr-czkawka--tag-line beg id)
            (dolist (f files)
              (zr-czkawka--insert-file f id directory))
            (insert "\n")
            (cl-incf total-groups)
            (cl-incf total-files (length files))
            (cl-incf total-size
                     (if grouped (zr-czkawka--wasted-size files) size))))))
    (dired-build-subdir-alist)
    (set-buffer-modified-p nil)
    ;; `%%%%' survives both `format' and mode line %-construct expansion,
    ;; and so does `%%' in the key hints, as they are not formatted.
    (setq header-line-format
          (concat
           (if grouped
               (format " Czkawka %s: %d groups, %d files (%s wasted)"
                       (zr-czkawka-tool-title tool) total-groups total-files
                       (file-size-human-readable total-size 'iec))
             (format " Czkawka %s: %d files (%s)"
                     (zr-czkawka-tool-title tool) total-files
                     (file-size-human-readable total-size 'iec)))
           (when-let* ((keys (zr-czkawka-tool-keys tool)))
             (concat " | " keys))))))

(defun zr-czkawka--render-buffer (tool groups params buffer)
  "Render GROUPS of TOOL results in Virtual Dired BUFFER using PARAMS.
Keep the listing switches of BUFFER if it already shows results."
  (with-current-buffer (get-buffer-create buffer)
    (let ((switches (if zr-czkawka-mode
                        dired-actual-switches
                      (concat dired-listing-switches
                              (zr-czkawka-tool-extra-switches tool))))
          (inhibit-read-only t))
      ;; Set up Dired first, as the groups are listed with its switches.
      (erase-buffer)
      (dired-virtual (plist-get params :directory) switches))
    (zr-czkawka-mode 1)
    (setq-local zr-czkawka--tool tool)
    (setq-local zr-czkawka--params params)
    (setq-local zr-czkawka--groups groups)
    (setq-local minor-mode-overriding-map-alist
                (list (cons 'zr-czkawka-mode
                            (or (zr-czkawka-tool-keymap tool)
                                zr-czkawka-mode-map))))
    (setq-local revert-buffer-function #'zr-czkawka--revert)
    (zr-czkawka--insert-groups)
    (run-hooks 'dired-after-readin-hook)
    (goto-char (point-min))
    (dired-next-line 1)
    (pop-to-buffer (current-buffer))))

(defun zr-czkawka--revert (&rest _)
  "Redisplay the current results without re-running the scan.
List files with the current `dired-actual-switches', e.g. as set by
\\[dired-sort-toggle-or-edit], and keep marks, point and hidden groups
like `dired-revert'."
  (widen)
  (let* ((inhibit-read-only t)
         (modified (buffer-modified-p))
         (positions (dired-save-positions))
         (hidden (save-excursion
                   (mapcar (lambda (dir)
                             (dired-goto-subdir dir)
                             (zr-czkawka--line-property 'zr-czkawka-group))
                           (dired-remember-hidden))))
         ;; Only after `dired-remember-hidden', since this unhides all.
         (marks (dired-remember-marks (point-min) (point-max))))
    (zr-czkawka--insert-groups)
    (dired-mark-remembered marks)
    (run-hooks 'dired-after-readin-hook)
    (dired-restore-positions positions)
    (save-excursion
      (dolist (elt dired-subdir-alist)
        (goto-char (cdr elt))
        (when (memq (zr-czkawka--line-property 'zr-czkawka-group) hidden)
          (dired-hide-subdir 1))))
    (unless modified (restore-buffer-modified-p nil))))

(defun zr-czkawka--scan (tool args directory &optional buffer)
  "Run TOOL with czkawka ARGS and display the results.
DIRECTORY is the top directory of the result buffer.  BUFFER is the
buffer to render into; if nil, render into the buffer of TOOL only
when something is found."
  (let ((name (zr-czkawka-tool-name tool)))
    (zr-czkawka-run
     (cons name args)
     (lambda (data)
       (let ((groups (funcall (zr-czkawka-tool-parse tool) data)))
         (if (and (null groups) (not (buffer-live-p buffer)))
             (message "czkawka %s found nothing." name)
           (zr-czkawka--render-buffer
            tool groups (list :args args :directory directory)
            (if (buffer-live-p buffer)
                buffer
              (format zr-czkawka-buffer-name-format name)))
           (if (zr-czkawka-tool-grouped tool)
               (message "Found %d group(s)." (length groups))
             (message "Found %d file(s)."
                      (length (alist-get 'files (car groups)))))))))))

(defun zr-czkawka--read-args (tool initial)
  "Read czkawka TOOL arguments with INITIAL input and return them as a list.
INITIAL is a list of arguments."
  (split-string-and-unquote
   (read-string (format "czkawka %s arguments: " (zr-czkawka-tool-name tool))
                (combine-and-quote-strings initial)
                'zr-czkawka-raw-args-history)))

(defun zr-czkawka-rescan (&optional edit-args)
  "Re-run the scan of the current results.
With prefix argument EDIT-ARGS, edit the czkawka arguments first."
  (interactive "P")
  (let ((args (plist-get zr-czkawka--params :args)))
    (when edit-args
      (setq args (zr-czkawka--read-args zr-czkawka--tool args)))
    (message "Refreshing czkawka scan...")
    (zr-czkawka--scan zr-czkawka--tool args
                      (plist-get zr-czkawka--params :directory)
                      (current-buffer))))

;;; Group management actions

(defun zr-czkawka--line-property (prop)
  "Return text property PROP of the current line, skipping the mark column."
  (let ((pos (1+ (line-beginning-position))))
    (and (< pos (line-end-position))
         (get-text-property pos prop))))

(defun zr-czkawka--buffer-groups (&optional group-id)
  "Return groups as currently listed in the buffer.
The value is an alist of (ID . ENTRIES) in buffer order, where each
entry is (POS . FILE) with POS the beginning of the file line and
FILE its file alist.  Files no longer on disk are skipped.  If
GROUP-ID is non-nil, only collect that group."
  (let ((groups nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((file (zr-czkawka--line-property 'zr-czkawka-file))
                    (id (zr-czkawka--line-property 'zr-czkawka-group))
                    ((or (null group-id) (eql id group-id)))
                    ((file-exists-p (alist-get 'path file))))
          (let ((cell (or (assq id groups)
                          (car (push (list id) groups)))))
            (push (cons (line-beginning-position) file) (cdr cell))))
        (forward-line 1)))
    (nreverse (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
                      groups))))

(defun zr-czkawka--current-group-id ()
  "Return the id of the group at point, or signal an error."
  (or (zr-czkawka--line-property 'zr-czkawka-group)
      (user-error "No group at point")))

(defun zr-czkawka--all-except-best (score)
  "Return a function selecting all files except the best by SCORE.
SCORE is called with a file alist and returns a number; the file
with the highest score is kept, ties being broken by path."
  (lambda (files)
    (let ((best (car (sort (copy-sequence files)
                           (lambda (a b)
                             (let ((sa (funcall score a))
                                   (sb (funcall score b)))
                               (if (= sa sb)
                                   (string< (alist-get 'path a) (alist-get 'path b))
                                 (> sa sb))))))))
      (remq best files))))

(defun zr-czkawka--mtime (file)
  "Return the modification date of FILE as czkawka reported it."
  (or (alist-get 'modified_date file) 0))

(defun zr-czkawka-flag-all-except-newest (&optional current-group-only)
  "Flag all files for deletion except the newest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka--flag (zr-czkawka--all-except-best #'zr-czkawka--mtime)
                    current-group-only "newest"))

(defun zr-czkawka-flag-all-except-oldest (&optional current-group-only)
  "Flag all files for deletion except the oldest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka--flag (zr-czkawka--all-except-best
                     (lambda (f) (- (zr-czkawka--mtime f))))
                    current-group-only "oldest"))

(defun zr-czkawka-flag-all-except-first (&optional current-group-only)
  "Flag all files for deletion except the first in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka--flag #'cdr current-group-only "first"))

(defun zr-czkawka-flag-all-except-biggest (&optional current-group-only)
  "Flag all files for deletion except the biggest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka--flag (zr-czkawka--all-except-best
                     (lambda (f) (or (alist-get 'size f) 0)))
                    current-group-only "biggest"))

(defun zr-czkawka--resolution (file)
  "Return the number of pixels of FILE as czkawka reported it."
  (* (or (alist-get 'width file) 0) (or (alist-get 'height file) 0)))

(defun zr-czkawka-flag-all-except-highest-resolution (&optional current-group-only)
  "Flag all files for deletion except the highest resolution in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka--flag (zr-czkawka--all-except-best #'zr-czkawka--resolution)
                    current-group-only "highest resolution"))

(defun zr-czkawka--set-mark (pos from to)
  "Replace mark FROM with TO at POS; return non-nil if replaced."
  (when (eq (char-after pos) from)
    (goto-char pos)
    (delete-char 1)
    (insert to)
    t))

(defun zr-czkawka--flag (select-candidates-fn current-group-only keep-label)
  "Internal helper to flag files of each group for deletion.
SELECT-CANDIDATES-FN takes a group's files in buffer order and returns
the files to flag.  Only files still listed and present on disk are
considered, reference files are never flagged, and existing flags in
the affected groups are cleared first.
If CURRENT-GROUP-ONLY is non-nil, only flag within the group at point.
KEEP-LABEL is a description of the kept file (e.g. \"newest\")."
  (let ((groups (zr-czkawka--buffer-groups
                 (and current-group-only (zr-czkawka--current-group-id))))
        (inhibit-read-only t)
        (count 0))
    (save-excursion
      (pcase-dolist (`(,_ . ,entries) groups)
        (dolist (e entries)
          (zr-czkawka--set-mark (car e) dired-del-marker ?\s))
        (let ((pool (cl-remove-if (lambda (f) (alist-get 'reference f))
                                  (mapcar #'cdr entries))))
          (when (cdr pool)
            (dolist (f (funcall select-candidates-fn pool))
              (when (zr-czkawka--set-mark (car (rassq f entries))
                                          ?\s dired-del-marker)
                (cl-incf count)))))))
    (if (zerop count)
        (message "No files to flag.")
      (message "Flagged %d file(s) for deletion (kept %s)."
               count keep-label))))

(defun zr-czkawka-diff ()
  "Diff the file at point against another file in the same group."
  (interactive)
  (let* ((current-file (dired-get-filename nil t)))
    (unless current-file
      (user-error "No file at point"))
    (let* ((files (mapcar (lambda (e) (expand-file-name (alist-get 'path (cdr e))))
                          (cdar (zr-czkawka--buffer-groups
                                 (zr-czkawka--current-group-id)))))
           (other-files (cl-remove (expand-file-name current-file) files :test #'equal)))
      (unless other-files
        (user-error "No counterpart to compare with"))
      (let ((target-file (if (= (length other-files) 1)
                             (car other-files)
                           (completing-read
                            (format "Diff %s with: " (file-name-nondirectory current-file))
                            other-files nil t))))
        (if (display-graphic-p)
            (ediff-files current-file target-file)
          (diff current-file target-file))))))

;;; Interactive commands

(defun zr-czkawka--read-directory (prompt &optional dir default)
  "Read a directory name with PROMPT, starting in DIR, defaulting to DEFAULT.
Use `zr-czkawka-directory-history' as the minibuffer history."
  (let ((file-name-history zr-czkawka-directory-history))
    (prog1 (read-directory-name prompt dir default t)
      (setq zr-czkawka-directory-history (delete "" file-name-history)))))

(defun zr-czkawka--read-directories ()
  "Prompt the user for one or more directories to scan."
  (let* ((marked-dirs (when (derived-mode-p 'dired-mode)
                        (delq nil (mapcar (lambda (f)
                                            (when (file-directory-p f)
                                              (expand-file-name f)))
                                          (dired-get-marked-files))))))
    (if (and marked-dirs (> (length marked-dirs) 1))
        (if (y-or-n-p (format "Scan %d marked directories in Dired? " (length marked-dirs)))
            marked-dirs
          (zr-czkawka--read-directories-interactive))
      (zr-czkawka--read-directories-interactive))))

(defun zr-czkawka--default-directory ()
  "Return the default directory to scan."
  (if (derived-mode-p 'dired-mode)
      (dired-current-directory)
    default-directory))

(defun zr-czkawka--read-directories-interactive ()
  "Interactively prompt for directories one by one."
  (let* ((default (zr-czkawka--default-directory))
         (first-dir (zr-czkawka--read-directory
                     "Directory to scan: " default default))
         (dirs (list (expand-file-name first-dir)))
         (continue t))
    (while continue
      (let ((next-dir (zr-czkawka--read-directory
                       "Add another directory (RET to start scan): " nil "")))
        (if (string-empty-p (string-trim next-dir))
            (setq continue nil)
          (let ((expanded (expand-file-name next-dir)))
            (unless (member expanded dirs)
              (setq dirs (append dirs (list expanded))))))))
    dirs))

(defun zr-czkawka--directory-args (dirs)
  "Return czkawka arguments scanning DIRS."
  (mapcan (lambda (d) (list "-d" (expand-file-name d))) dirs))

(defun zr-czkawka--start (tool raw build-args &rest read-options)
  "Start a TOOL scan.
BUILD-ARGS is called with the directories to scan and the options,
and returns the czkawka arguments.  If RAW is non-nil, edit the
arguments for the default directory and default options, which are
the defaults of READ-OPTIONS.  Otherwise, read the directories, and
call each of READ-OPTIONS to read an option."
  (if raw
      (zr-czkawka--scan
       tool
       (zr-czkawka--read-args
        tool (apply build-args (list (zr-czkawka--default-directory))
                    (mapcar (lambda (read) (funcall read t)) read-options)))
       (expand-file-name (zr-czkawka--default-directory)))
    (let ((dirs (zr-czkawka--read-directories)))
      (zr-czkawka--scan
       tool
       (apply build-args dirs (mapcar (lambda (read) (funcall read nil))
                                      read-options))
       (car dirs)))))

(defun zr-czkawka--option-reader (prompt choices default)
  "Return a function reading an option with PROMPT among CHOICES.
DEFAULT is a symbol whose value is the default choice.  The function
returns the default without reading if its argument is non-nil."
  (lambda (use-default)
    (let ((value (symbol-value default)))
      (if use-default
          value
        (completing-read (format-prompt prompt value)
                         choices nil t nil nil value)))))

(defun zr-czkawka--number-reader (prompt default)
  "Return a function reading a number with PROMPT.
DEFAULT is a symbol whose value is the default number.  The function
returns the default without reading if its argument is non-nil."
  (lambda (use-default)
    (let ((value (symbol-value default)))
      (if use-default
          value
        (read-number (format-prompt prompt value) value)))))

;;;; Duplicate files

(defun zr-czkawka-dup--parse-json (data)
  "Parse DATA, the JSON output of czkawka dup, into groups.
The output is an object with groups of duplicates per size or name."
  (zr-czkawka--make-groups
   (mapcan (lambda (item) (zr-czkawka--collect (cdr item))) data)))

(defun zr-czkawka-dup--group-info (group)
  "Return the size and hash of the duplicates in GROUP."
  (let* ((file (car (alist-get 'files group)))
         (size (alist-get 'size file))
         (hash (alist-get 'hash file)))
    (concat (and size (> size 0)
                 (format ", Size: %s" (file-size-human-readable size 'iec)))
            (and hash (not (string-empty-p hash))
                 (format ", Hash: %s" (truncate-string-to-width hash 8))))))

(defconst zr-czkawka-dup-tool
  (zr-czkawka-tool-create
   :name "dup"
   :title "Dup"
   :parse #'zr-czkawka-dup--parse-json
   :group-info #'zr-czkawka-dup--group-info
   :keymap zr-czkawka-group-map
   :keys zr-czkawka--group-keys)
  "The czkawka tool finding duplicate files.")

(defun zr-czkawka-dup--build-args (dirs search-method)
  "Build CLI arguments for duplicate scan with DIRS and SEARCH-METHOD."
  (append (zr-czkawka--directory-args dirs)
          (and search-method (list "-s" (downcase search-method)))
          (and zr-czkawka-dup-min-file-size
               (list "-m" (number-to-string zr-czkawka-dup-min-file-size)))
          (and search-method (string-equal-ignore-case search-method "HASH")
               zr-czkawka-dup-hash-type
               (list "-t" (downcase zr-czkawka-dup-hash-type)))))

;;;###autoload
(defun zr-czkawka-dup (&optional raw)
  "Scan directories for duplicate files using czkawka_cli.
When called with prefix argument RAW, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies) and search method."
  (interactive "P")
  (zr-czkawka--start zr-czkawka-dup-tool raw #'zr-czkawka-dup--build-args
                     (zr-czkawka--option-reader
                      "Search method" '("HASH" "SIZE" "NAME")
                      'zr-czkawka-dup-search-method)))

;;;; Big files

(defcustom zr-czkawka-big-mode "biggest"
  "Default kind of files listed by `zr-czkawka-big'."
  :type '(choice (const "biggest")
                 (const "smallest")))

(defcustom zr-czkawka-big-number-of-files 50
  "Default number of files listed by `zr-czkawka-big'."
  :type 'natnum)

(defconst zr-czkawka-big-tool
  (zr-czkawka-tool-create
   :name "big"
   :title "Big files"
   :parse #'zr-czkawka--parse-files
   :grouped nil
   ;; Keep the order of czkawka, biggest or smallest first.
   :extra-switches " -U"
   :keymap zr-czkawka-mode-map
   :keys "[d] Flag [x] Delete [s] Sort [g] Refresh")
  "The czkawka tool finding the biggest or smallest files.")

(defun zr-czkawka-big--build-args (dirs mode number)
  "Build CLI arguments listing NUMBER files of MODE in DIRS.
MODE is \"biggest\" or \"smallest\"."
  (append (zr-czkawka--directory-args dirs)
          (list "-n" (number-to-string number))
          (and (equal mode "smallest") (list "-J"))))

;;;###autoload
(defun zr-czkawka-big (&optional raw)
  "List the biggest or smallest files of directories using czkawka_cli.
When called with prefix argument RAW, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies), the kind and number of files."
  (interactive "P")
  (zr-czkawka--start zr-czkawka-big-tool raw #'zr-czkawka-big--build-args
                     (zr-czkawka--option-reader
                      "Find" '("biggest" "smallest") 'zr-czkawka-big-mode)
                     (zr-czkawka--number-reader
                      "Number of files" 'zr-czkawka-big-number-of-files)))

;;;; Similar images

(defcustom zr-czkawka-image-max-difference 5
  "Default maximum difference between similar images, from 0 to 40.
Values up to 10 suit a hash size of 8, and up to 20 a hash size of 16."
  :type 'natnum)

(defcustom zr-czkawka-image-hash-size 16
  "Size of the perceptual hash of images, or nil for the CLI default."
  :type '(choice (const :tag "Default" nil)
                 (const 8) (const 16) (const 32) (const 64)))

(defcustom zr-czkawka-image-hash-alg nil
  "Perceptual hash algorithm of images, or nil for the CLI default."
  :type '(choice (const :tag "Default" nil)
                 (const "Mean") (const "Gradient") (const "Blockhash")
                 (const "VertGradient") (const "DoubleGradient")
                 (const "Median")))

(defcustom zr-czkawka-image-min-file-size nil
  "Minimum size in bytes of images to compare, or nil for the CLI default."
  :type '(choice (const :tag "Default (16384)" nil)
                 (integer :tag "Bytes")))

(defun zr-czkawka-image--annotate (file)
  "Return the dimensions and difference of image FILE."
  (format "%sx%s, difference %s"
          (alist-get 'width file) (alist-get 'height file)
          (alist-get 'difference file)))

(defconst zr-czkawka-image-tool
  (zr-czkawka-tool-create
   :name "image"
   :title "Similar images"
   :parse #'zr-czkawka--parse-groups
   :annotate #'zr-czkawka-image--annotate
   :keymap zr-czkawka-media-map
   :keys zr-czkawka--media-keys)
  "The czkawka tool finding similar images.")

(defun zr-czkawka-image--build-args (dirs max-difference)
  "Build CLI arguments finding images in DIRS within MAX-DIFFERENCE."
  (append (zr-czkawka--directory-args dirs)
          (list "-s" (number-to-string max-difference))
          (and zr-czkawka-image-hash-size
               (list "-c" (number-to-string zr-czkawka-image-hash-size)))
          (and zr-czkawka-image-hash-alg
               (list "-g" zr-czkawka-image-hash-alg))
          (and zr-czkawka-image-min-file-size
               (list "-m" (number-to-string zr-czkawka-image-min-file-size)))))

;;;###autoload
(defun zr-czkawka-image (&optional raw)
  "Scan directories for similar images using czkawka_cli.
When called with prefix argument RAW, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies) and the maximum difference."
  (interactive "P")
  (zr-czkawka--start zr-czkawka-image-tool raw #'zr-czkawka-image--build-args
                     (zr-czkawka--number-reader
                      "Maximum difference (0-40)"
                      'zr-czkawka-image-max-difference)))

;;;; Same music

(defcustom zr-czkawka-music-search-method "TAGS"
  "Default search method for the same music.
\"TAGS\" compares tags, and \"CONTENT\" compares audio content."
  :type '(choice (const "TAGS")
                 (const "CONTENT")))

(defcustom zr-czkawka-music-similarity nil
  "Tags that must be equal for music to be the same, or nil for the CLI
default, the title and artist."
  :type '(choice (const :tag "Default" nil)
                 (set (const "track_title") (const "track_artist")
                      (const "year") (const "bitrate") (const "genre")
                      (const "length"))))

(defcustom zr-czkawka-music-approximate nil
  "Non-nil means tags are compared approximately."
  :type 'boolean)

(defcustom zr-czkawka-music-min-file-size nil
  "Minimum size in bytes of music files, or nil for the CLI default."
  :type '(choice (const :tag "Default (8192)" nil)
                 (integer :tag "Bytes")))

(defun zr-czkawka-music--parse-json (data)
  "Parse DATA, the JSON output of czkawka music, into groups."
  (zr-czkawka--remove-keys (zr-czkawka--parse-groups data) 'fingerprint))

(defun zr-czkawka-music--annotate (file)
  "Return the tags, length and bitrate of music FILE."
  (let ((title (zr-czkawka--nonempty (alist-get 'track_title file)))
        (artist (zr-czkawka--nonempty (alist-get 'track_artist file)))
        (bitrate (alist-get 'bitrate file)))
    (string-join
     (delq nil
           (list (and (or title artist)
                      (concat (or title "?") (and artist (concat " - " artist))))
                 (zr-czkawka--nonempty (alist-get 'year file))
                 (zr-czkawka--nonempty (alist-get 'genre file))
                 (zr-czkawka--format-duration (alist-get 'length file))
                 (and (numberp bitrate) (> bitrate 0)
                      (format "%d kbps" bitrate))))
     ", ")))

(defconst zr-czkawka-music-tool
  (zr-czkawka-tool-create
   :name "music"
   :title "Same music"
   :parse #'zr-czkawka-music--parse-json
   :annotate #'zr-czkawka-music--annotate
   :keymap zr-czkawka-group-map
   :keys zr-czkawka--group-keys)
  "The czkawka tool finding the same music.")

(defun zr-czkawka-music--build-args (dirs search-method)
  "Build CLI arguments finding the same music in DIRS with SEARCH-METHOD."
  (append (zr-czkawka--directory-args dirs)
          (list "-s" search-method)
          (and zr-czkawka-music-similarity
               (list "-z" (string-join zr-czkawka-music-similarity ",")))
          (and zr-czkawka-music-approximate (list "-a"))
          (and zr-czkawka-music-min-file-size
               (list "-m" (number-to-string zr-czkawka-music-min-file-size)))))

;;;###autoload
(defun zr-czkawka-music (&optional raw)
  "Scan directories for the same music using czkawka_cli.
When called with prefix argument RAW, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies) and search method."
  (interactive "P")
  (zr-czkawka--start zr-czkawka-music-tool raw #'zr-czkawka-music--build-args
                     (zr-czkawka--option-reader
                      "Search method" '("TAGS" "CONTENT")
                      'zr-czkawka-music-search-method)))

;;;; Similar videos

(defcustom zr-czkawka-video-tolerance 10
  "Default maximum difference between similar videos, from 0 to 20."
  :type 'natnum)

(defcustom zr-czkawka-video-skip-forward nil
  "Seconds skipped at the start of videos, or nil for the CLI default."
  :type '(choice (const :tag "Default (15)" nil)
                 (natnum :tag "Seconds")))

(defcustom zr-czkawka-video-min-file-size nil
  "Minimum size in bytes of videos, or nil for the CLI default."
  :type '(choice (const :tag "Default (8192)" nil)
                 (integer :tag "Bytes")))

(defun zr-czkawka-video--parse-json (data)
  "Parse DATA, the JSON output of czkawka video, into groups."
  (zr-czkawka--remove-keys (zr-czkawka--parse-groups data) 'vhash))

(defun zr-czkawka-video--annotate (file)
  "Return the dimensions, codec, duration, bitrate and frame rate of video FILE.
Return the error of czkawka instead if it could not read FILE."
  (or (zr-czkawka--nonempty (alist-get 'error file))
      (let ((width (alist-get 'width file))
            (bitrate (alist-get 'bitrate file))
            (fps (alist-get 'fps file)))
        (string-join
         (delq nil
               (list (and width (format "%sx%s" width (alist-get 'height file)))
                     (zr-czkawka--nonempty (alist-get 'codec file))
                     (zr-czkawka--format-duration (alist-get 'duration file))
                     (and (numberp bitrate) (> bitrate 0)
                          (format "%d kbps" (round bitrate 1000)))
                     (and (numberp fps) (> fps 0)
                          (format "%s fps" (string-trim-right
                                            (format "%.2f" fps) "\\.?0+")))))
         ", "))))

(defconst zr-czkawka-video-tool
  (zr-czkawka-tool-create
   :name "video"
   :title "Similar videos"
   :parse #'zr-czkawka-video--parse-json
   :annotate #'zr-czkawka-video--annotate
   :keymap zr-czkawka-media-map
   :keys zr-czkawka--media-keys)
  "The czkawka tool finding similar videos.")

(defun zr-czkawka-video--build-args (dirs tolerance)
  "Build CLI arguments finding videos in DIRS within TOLERANCE."
  (append (zr-czkawka--directory-args dirs)
          (list "-t" (number-to-string tolerance))
          (and zr-czkawka-video-skip-forward
               (list "-U" (number-to-string zr-czkawka-video-skip-forward)))
          (and zr-czkawka-video-min-file-size
               (list "-m" (number-to-string zr-czkawka-video-min-file-size)))))

;;;###autoload
(defun zr-czkawka-video (&optional raw)
  "Scan directories for similar videos using czkawka_cli.
When called with prefix argument RAW, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies) and the tolerance."
  (interactive "P")
  (zr-czkawka--start zr-czkawka-video-tool raw #'zr-czkawka-video--build-args
                     (zr-czkawka--number-reader
                      "Tolerance (0-20)" 'zr-czkawka-video-tolerance)))

(provide 'zr-czkawka)

;;; zr-czkawka.el ends here
