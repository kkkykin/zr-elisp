;;; zr-czkawka.el --- Czkawka CLI integration with Dired -*- lexical-binding: t; -*-

;; Author: kkkykin
;; Keywords: files, tools
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Integration with `czkawka_cli' to find and manage duplicate files using
;; Dired and `dired-virtual-mode'.
;;
;; Duplicate groups are presented as virtual subdirectories inside a Dired
;; buffer, enabling standard Dired navigation, marking, and deletion.
;;
;; Commands:
;;   `zr-czkawka-dup' - Scan directories for duplicate files.
;;
;; Keys in `zr-czkawka-dup-mode':
;;   % n - Flag all duplicates except the newest in each group.
;;   % o - Flag all duplicates except the oldest in each group.
;;   % f - Flag all duplicates except the first in each group.
;;   g - Re-run the duplicate scan; with prefix argument, edit arguments.
;;   s - Sort each group by name or date; with prefix argument, edit
;;       the `ls' switches.  This redisplays without re-running the scan.
;;   d / u / x - Standard Dired flagging, unmarking, and deletion.
;;   $ - Collapse or expand a duplicate group.
;;
;; Files are listed with `insert-directory' (`ls' or `ls-lisp') using
;; the Dired listing switches, and each group is sorted as `ls' would
;; sort it with those switches, reference files first.
;;
;; The flagging commands only consider files still listed in the buffer
;; and present on disk, clear existing flags in the affected groups
;; first, and never flag reference files (from `-r'), so each group
;; always keeps at least one copy.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dired-x)
(require 'subr-x)

(defgroup zr-czkawka nil
  "Czkawka CLI integration for duplicate file management."
  :group 'files)

(defcustom zr-czkawka-program "czkawka_cli"
  "Path to the czkawka_cli executable."
  :type 'file)

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

(defcustom zr-czkawka-dup-buffer-name "*zr-czkawka-dup*"
  "Name of the buffer displaying duplicate file results."
  :type 'string)

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

(defvar-local zr-czkawka-dup--params nil
  "Plist of parameters used to generate current duplicate results.
:args is the list of czkawka dup arguments and :directory is the
top directory of the Virtual Dired buffer.")

(defvar-local zr-czkawka-dup--groups nil
  "Duplicate groups of the current results.
The value is as returned by `zr-czkawka-dup--parse-json'.")

;;; Process execution

(defun zr-czkawka--read-json (file)
  "Parse czkawka JSON output in FILE, or return nil if FILE is empty."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (unless (zerop (buffer-size))
      (json-parse-buffer :object-type 'alist :array-type 'list))))

(defun zr-czkawka--critical-error-p (buffer)
  "Return non-nil if czkawka reported a critical error in BUFFER.
czkawka exits with code 0 even when it cannot start a scan."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (search-forward "CRITICAL ERROR" nil t))))

(defun zr-czkawka-run (args callback &optional error-callback)
  "Execute `zr-czkawka-program' with ARGS asynchronously.
Ensure JSON output is captured in a temporary file and parsed.
On success, invoke CALLBACK with the parsed JSON data.
On failure, invoke ERROR-CALLBACK with the exit code and process
buffer, or display the process buffer."
  (unless (executable-find zr-czkawka-program)
    (unless (file-executable-p zr-czkawka-program)
      (user-error "Czkawka executable not found: %s" zr-czkawka-program)))
  (let* ((temp-file (make-temp-file "zr-czkawka-" nil ".json"))
         (proc-buf (get-buffer-create zr-czkawka-process-buffer-name))
         (full-args (append args (list "-N" "-W" "-C" temp-file)))
         (cmd (cons zr-czkawka-program full-args)))
    (with-current-buffer proc-buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "Scanning with czkawka...")
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
                                (not (zr-czkawka--critical-error-p proc-buf)))
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

(defun zr-czkawka-dup--file-p (obj)
  "Return non-nil if OBJ is a czkawka file entry alist."
  (and (consp obj) (consp (car obj)) (assq 'path obj)))

(defun zr-czkawka-dup--collect (val)
  "Collect duplicate groups from JSON value VAL.
Return a list of (REFERENCE . FILES), where REFERENCE is the
reference file entry (from `-r') or nil.  VAL is a plain group (a
list of file entries), a reference entry (a file entry followed by
a list of file entries), or a list of those."
  (cond
   ((not (zr-czkawka-dup--file-p (car val)))
    (mapcan #'zr-czkawka-dup--collect val))
   ((and (cdr val) (not (zr-czkawka-dup--file-p (cadr val))))
    (list (cons (car val) (cadr val))))
   (t (list (cons nil val)))))

(defun zr-czkawka-dup--parse-json (data)
  "Parse DATA (an alist from `json-parse-buffer') into duplicate groups.
Return a list of group alists, each containing:
  - id: 1-based integer
  - key: string (size or filename)
  - size: integer size in bytes
  - hash: string hash or nil
  - files: list of file alists with path, size, modified_date, hash.
A reference file is listed first with an additional (reference . t)."
  (let ((group-id 0))
    (mapcan
     (lambda (item)
       (let ((key-str (format "%s" (car item))))
         (mapcar
          (lambda (grp)
            (let* ((ref (car grp))
                   (files (if ref
                              (cons (cons '(reference . t) ref) (cdr grp))
                            (cdr grp)))
                   (first-file (car files))
                   (hash (alist-get 'hash first-file)))
              `((id . ,(cl-incf group-id))
                (key . ,key-str)
                (size . ,(or (alist-get 'size first-file)
                             (string-to-number key-str)))
                (hash . ,(and (not (string-empty-p (or hash ""))) hash))
                (files . ,files))))
          (zr-czkawka-dup--collect (cdr item)))))
     data)))

;;; Virtual Dired Buffer Rendering

(defvar zr-czkawka-dup-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "% n") #'zr-czkawka-dup-flag-all-except-newest)
    (define-key map (kbd "% o") #'zr-czkawka-dup-flag-all-except-oldest)
    (define-key map (kbd "% f") #'zr-czkawka-dup-flag-all-except-first)
    (define-key map [remap revert-buffer] #'zr-czkawka-dup-rescan)
    ;; (define-key map (kbd "=") #'zr-czkawka-dup-diff)
    map)
  "Keymap for `zr-czkawka-dup-mode'.")

(define-minor-mode zr-czkawka-dup-mode
  "Minor mode for managing duplicate files in a Virtual Dired buffer.
\\{zr-czkawka-dup-mode-map}"
  :lighter " Czkawka-Dup"
  :keymap zr-czkawka-dup-mode-map)

(defun zr-czkawka-dup--sort-files (files switches)
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

(defun zr-czkawka-dup--tag-line (beg group-id &optional file)
  "Tag the line from BEG to point with GROUP-ID and FILE text properties.
The properties skip the first column, which Dired rewrites when marking."
  (add-text-properties (1+ beg) (1- (point))
                       (list 'zr-czkawka-dup-group group-id
                             'zr-czkawka-dup-file file)))

(defun zr-czkawka-dup--insert-file (file group-id directory)
  "Insert the listing line of FILE in GROUP-ID.
List it with `dired-actual-switches' as Dired lists an explicit file
list, through `insert-directory'.  DIRECTORY is the top directory."
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
    (zr-czkawka-dup--tag-line beg group-id file)))

(defun zr-czkawka-dup--insert-groups ()
  "Replace the buffer contents with the duplicate groups.
List files with `dired-actual-switches', skipping files no longer on
disk and groups left without files, and update the header line."
  (let ((directory (plist-get zr-czkawka-dup--params :directory))
        (inhibit-read-only t)
        (total-groups 0)
        (total-files 0)
        (total-waste 0))
    (when (consp buffer-undo-list)
      (setq buffer-undo-list nil))
    (let ((buffer-undo-list t))
      (erase-buffer)
      (dolist (grp zr-czkawka-dup--groups)
        (when-let* ((files (zr-czkawka-dup--sort-files (alist-get 'files grp)
                                                       dired-actual-switches)))
          (let* ((id (alist-get 'id grp))
                 (size (alist-get 'size grp))
                 (hash (alist-get 'hash grp))
                 (ref-str (if (alist-get 'reference (car files)) ", 1 reference" ""))
                 (size-str (if (and size (> size 0))
                               (format ", Size: %s" (file-size-human-readable size 'iec))
                             ""))
                 (hash-str (if hash
                               (format ", Hash: %s" (truncate-string-to-width hash 8))
                             ""))
                 (beg (point)))
            (insert (format "  // Group %d [%d files%s%s%s]:\n"
                            id (length files) ref-str size-str hash-str))
            (zr-czkawka-dup--tag-line beg id)
            (dolist (f files)
              (zr-czkawka-dup--insert-file f id directory))
            (insert "\n")
            (cl-incf total-groups)
            (cl-incf total-files (length files))
            (cl-incf total-waste (* (1- (length files)) (or size 0)))))))
    (dired-build-subdir-alist)
    (set-buffer-modified-p nil)
    ;; `%%%%' survives both `format' and mode line %-construct expansion.
    (setq header-line-format
          (format " Czkawka Dup: %d groups, %d files (%s wasted) | [d] Flag [x] Delete [%%%% n] Keep newest [%%%% o] Keep oldest [%%%% f] Keep first [g] Refresh"
                  total-groups total-files
                  (file-size-human-readable total-waste 'iec)))))

(defun zr-czkawka-dup--render-buffer (groups params buffer)
  "Render duplicate GROUPS in Virtual Dired BUFFER using PARAMS.
Keep the listing switches of BUFFER if it already shows duplicates."
  (with-current-buffer (get-buffer-create buffer)
    (let ((switches (and zr-czkawka-dup-mode dired-actual-switches))
          (inhibit-read-only t))
      ;; Set up Dired first, as the groups are listed with its switches.
      (erase-buffer)
      (dired-virtual (plist-get params :directory) switches))
    (zr-czkawka-dup-mode 1)
    (setq-local zr-czkawka-dup--params params)
    (setq-local zr-czkawka-dup--groups groups)
    (setq-local revert-buffer-function #'zr-czkawka-dup--revert)
    (zr-czkawka-dup--insert-groups)
    (run-hooks 'dired-after-readin-hook)
    (goto-char (point-min))
    (dired-next-line 1)
    (pop-to-buffer (current-buffer))))

(defun zr-czkawka-dup--revert (&rest _)
  "Redisplay the duplicate groups without re-running the scan.
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
                             (zr-czkawka-dup--line-property 'zr-czkawka-dup-group))
                           (dired-remember-hidden))))
         ;; Only after `dired-remember-hidden', since this unhides all.
         (marks (dired-remember-marks (point-min) (point-max))))
    (zr-czkawka-dup--insert-groups)
    (dired-mark-remembered marks)
    (run-hooks 'dired-after-readin-hook)
    (dired-restore-positions positions)
    (save-excursion
      (dolist (elt dired-subdir-alist)
        (goto-char (cdr elt))
        (when (memq (zr-czkawka-dup--line-property 'zr-czkawka-dup-group) hidden)
          (dired-hide-subdir 1))))
    (unless modified (restore-buffer-modified-p nil))))

(defun zr-czkawka-dup--scan (args directory &optional buffer)
  "Run a duplicate scan with czkawka dup ARGS and display the results.
DIRECTORY is the top directory of the result buffer.  BUFFER is the
buffer to render into; if nil, render into `zr-czkawka-dup-buffer-name'
only when duplicates are found."
  (zr-czkawka-run
   (cons "dup" args)
   (lambda (data)
     (let ((groups (zr-czkawka-dup--parse-json data)))
       (if (and (null groups) (not (buffer-live-p buffer)))
           (message "No duplicate files found.")
         (zr-czkawka-dup--render-buffer
          groups (list :args args :directory directory)
          (if (buffer-live-p buffer) buffer zr-czkawka-dup-buffer-name))
         (message "Found %d duplicate group(s)." (length groups)))))))

(defun zr-czkawka-dup--read-args (initial)
  "Read czkawka dup arguments with INITIAL input and return them as a list."
  (split-string-and-unquote
   (read-string "czkawka dup arguments: " initial 'zr-czkawka-raw-args-history)))

(defun zr-czkawka-dup-rescan (&optional edit-args)
  "Re-run the duplicate scan for the current buffer.
With prefix argument EDIT-ARGS, edit the czkawka dup arguments first."
  (interactive "P")
  (let ((args (plist-get zr-czkawka-dup--params :args)))
    (when edit-args
      (setq args (zr-czkawka-dup--read-args (combine-and-quote-strings args))))
    (message "Refreshing duplicate files scan...")
    (zr-czkawka-dup--scan args (plist-get zr-czkawka-dup--params :directory)
                          (current-buffer))))

;;; Duplicate file management actions

(defun zr-czkawka-dup--line-property (prop)
  "Return text property PROP of the current line, skipping the mark column."
  (let ((pos (1+ (line-beginning-position))))
    (and (< pos (line-end-position))
         (get-text-property pos prop))))

(defun zr-czkawka-dup--buffer-groups (&optional group-id)
  "Return duplicate groups as currently listed in the buffer.
The value is an alist of (ID . ENTRIES) in buffer order, where each
entry is (POS . FILE) with POS the beginning of the file line and
FILE its file alist.  Files no longer on disk are skipped.  If
GROUP-ID is non-nil, only collect that group."
  (let ((groups nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((file (zr-czkawka-dup--line-property 'zr-czkawka-dup-file))
                    (id (zr-czkawka-dup--line-property 'zr-czkawka-dup-group))
                    ((or (null group-id) (eql id group-id)))
                    ((file-exists-p (alist-get 'path file))))
          (let ((cell (or (assq id groups)
                          (car (push (list id) groups)))))
            (push (cons (line-beginning-position) file) (cdr cell))))
        (forward-line 1)))
    (nreverse (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
                      groups))))

(defun zr-czkawka-dup--current-group-id ()
  "Return the id of the duplicate group at point, or signal an error."
  (or (zr-czkawka-dup--line-property 'zr-czkawka-dup-group)
      (user-error "No duplicate group at point")))

(defun zr-czkawka-dup--sort-by-mtime (files newest-first)
  "Return FILES sorted by modification date, NEWEST-FIRST if non-nil.
Ties are broken by path."
  (sort (copy-sequence files)
        (lambda (a b)
          (let ((m1 (or (alist-get 'modified_date a) 0))
                (m2 (or (alist-get 'modified_date b) 0)))
            (if (= m1 m2)
                (string< (alist-get 'path a) (alist-get 'path b))
              (if newest-first (> m1 m2) (< m1 m2)))))))

(defun zr-czkawka-dup-flag-all-except-newest (&optional current-group-only)
  "Flag all duplicate files for deletion except the newest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka-dup--flag-duplicates
   (lambda (files) (cdr (zr-czkawka-dup--sort-by-mtime files t)))
   current-group-only
   "newest"))

(defun zr-czkawka-dup-flag-all-except-oldest (&optional current-group-only)
  "Flag all duplicate files for deletion except the oldest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka-dup--flag-duplicates
   (lambda (files) (cdr (zr-czkawka-dup--sort-by-mtime files nil)))
   current-group-only
   "oldest"))

(defun zr-czkawka-dup-flag-all-except-first (&optional current-group-only)
  "Flag all duplicate files for deletion except the first in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka-dup--flag-duplicates
   #'cdr
   current-group-only
   "first"))

(defun zr-czkawka-dup--set-mark (pos from to)
  "Replace mark FROM with TO at POS; return non-nil if replaced."
  (when (eq (char-after pos) from)
    (goto-char pos)
    (delete-char 1)
    (insert to)
    t))

(defun zr-czkawka-dup--flag-duplicates (select-candidates-fn current-group-only keep-label)
  "Internal helper to flag duplicates for deletion.
SELECT-CANDIDATES-FN takes a group's files in buffer order and returns
the files to flag.  Only files still listed and present on disk are
considered, reference files are never flagged, and existing flags in
the affected groups are cleared first.
If CURRENT-GROUP-ONLY is non-nil, only flag within the group at point.
KEEP-LABEL is a description of the kept file (e.g. \"newest\")."
  (let ((groups (zr-czkawka-dup--buffer-groups
                 (and current-group-only (zr-czkawka-dup--current-group-id))))
        (inhibit-read-only t)
        (count 0))
    (save-excursion
      (pcase-dolist (`(,_ . ,entries) groups)
        (dolist (e entries)
          (zr-czkawka-dup--set-mark (car e) dired-del-marker ?\s))
        (let ((pool (cl-remove-if (lambda (f) (alist-get 'reference f))
                                  (mapcar #'cdr entries))))
          (when (cdr pool)
            (dolist (f (funcall select-candidates-fn pool))
              (when (zr-czkawka-dup--set-mark (car (rassq f entries))
                                              ?\s dired-del-marker)
                (cl-incf count)))))))
    (if (zerop count)
        (message "No duplicate files to flag.")
      (message "Flagged %d duplicate file(s) for deletion (kept %s)."
               count keep-label))))

(defun zr-czkawka-dup-diff ()
  "Diff the file at point against another file in the same duplicate group."
  (interactive)
  (let* ((current-file (dired-get-filename nil t)))
    (unless current-file
      (user-error "No file at point"))
    (let* ((files (mapcar (lambda (e) (expand-file-name (alist-get 'path (cdr e))))
                          (cdar (zr-czkawka-dup--buffer-groups
                                 (zr-czkawka-dup--current-group-id)))))
           (other-files (cl-remove (expand-file-name current-file) files :test #'equal)))
      (unless other-files
        (user-error "No duplicate counterpart to compare with"))
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

(defun zr-czkawka-dup--build-args (dirs search-method)
  "Build CLI arguments for duplicate scan with DIRS and SEARCH-METHOD."
  (let ((args nil))
    (dolist (d dirs)
      (setq args (append args (list "-d" (expand-file-name d)))))
    (when search-method
      (setq args (append args (list "-s" (downcase search-method)))))
    (when zr-czkawka-dup-min-file-size
      (setq args (append args (list "-m" (number-to-string zr-czkawka-dup-min-file-size)))))
    (when (and search-method (string-equal-ignore-case search-method "HASH") zr-czkawka-dup-hash-type)
      (setq args (append args (list "-t" (downcase zr-czkawka-dup-hash-type)))))
    args))

(defun zr-czkawka-dup--default-raw-args ()
  "Construct default raw arguments string for `zr-czkawka-dup'."
  (combine-and-quote-strings
   (zr-czkawka-dup--build-args (list (zr-czkawka--default-directory))
                               zr-czkawka-dup-search-method)))

;;;###autoload
(defun zr-czkawka-dup (&optional arg)
  "Scan directories for duplicate files using czkawka_cli.
When called with prefix argument ARG, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies) and search method."
  (interactive "P")
  (if arg
      (let ((dir (expand-file-name (zr-czkawka--default-directory))))
        (zr-czkawka-dup--scan
         (zr-czkawka-dup--read-args (zr-czkawka-dup--default-raw-args))
         dir))
    (let* ((dirs (zr-czkawka--read-directories))
           (method (completing-read
                    (format-prompt "Search method" zr-czkawka-dup-search-method)
                    '("HASH" "SIZE" "NAME")
                    nil t nil nil zr-czkawka-dup-search-method)))
      (zr-czkawka-dup--scan (zr-czkawka-dup--build-args dirs method) (car dirs)))))

(provide 'zr-czkawka)

;;; zr-czkawka.el ends here
