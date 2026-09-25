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
;;   g - Re-run the duplicate scan.
;;   d / u / x - Standard Dired flagging, unmarking, and deletion.
;;   $ - Collapse or expand a duplicate group.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dired-x)
(require 'ediff)
(require 'ls-lisp)
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

(defvar zr-czkawka-search-method-history nil
  "History of chosen search methods.")

(defvar zr-czkawka-raw-args-history nil
  "History of raw command arguments entered via prefix argument.")

(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (dolist (var '(zr-czkawka-directory-history
                 zr-czkawka-search-method-history
                 zr-czkawka-raw-args-history))
    (add-to-list 'savehist-additional-variables var)))

(defvar zr-czkawka-process-buffer-name "*zr-czkawka-process*"
  "Name of the buffer holding czkawka process output.")

(defvar-local zr-czkawka-dup--params nil
  "Parameters used to generate current duplicate results.")

(defvar-local zr-czkawka-dup--groups nil
  "Parsed duplicate groups currently shown in buffer.")

;;; Process execution

(defun zr-czkawka-run (args callback &optional error-callback)
  "Execute `zr-czkawka-program' with ARGS asynchronously.
Ensure JSON output is captured in a temporary file and parsed.
On success, invoke CALLBACK with the parsed JSON data.
On failure, invoke ERROR-CALLBACK or display the process buffer."
  (unless (executable-find zr-czkawka-program)
    (unless (file-executable-p zr-czkawka-program)
      (user-error "Czkawka executable not found: %s" zr-czkawka-program)))
  (let* ((temp-file (make-temp-file "zr-czkawka-" nil ".json"))
         (proc-buf (get-buffer-create zr-czkawka-process-buffer-name))
         (full-args (append args (list "-N" "-M" "-W" "-C" temp-file)))
         (cmd (cons zr-czkawka-program full-args)))
    (with-current-buffer proc-buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "Scanning with czkawka...")
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
         (let ((exit-code (process-exit-status proc)))
           (if (zerop exit-code)
               (let ((parsed-data
                      (condition-case err
                          (when (file-exists-p temp-file)
                            (with-temp-buffer
                              (insert-file-contents temp-file)
                              (if (> (buffer-size) 0)
                                  (json-parse-buffer :object-type 'alist :array-type 'list)
                                '())))
                        (error
                         (message "Failed to parse czkawka JSON: %s" (error-message-string err))
                         nil))))
                 (when (file-exists-p temp-file)
                   (ignore-errors (delete-file temp-file)))
                 (funcall callback parsed-data))
             (when (file-exists-p temp-file)
               (ignore-errors (delete-file temp-file)))
             (if error-callback
                 (funcall error-callback exit-code proc-buf)
               (display-buffer proc-buf)
               (message "czkawka failed with exit code %s; see %s"
                        exit-code (buffer-name proc-buf))))))))))

;;; JSON parsing

(defun zr-czkawka-dup--parse-json (data)
  "Parse DATA (an alist from `json-parse-buffer') into duplicate groups.
Return a list of group alists, each containing:
  - id: 1-based integer
  - key: string (size or filename)
  - size: integer size in bytes
  - hash: string hash or nil
  - files: list of file alists with path, size, modified_date, hash."
  (let ((raw-groups nil)
        (group-id 0))
    (pcase-dolist (`(,key . ,val) data)
      (let ((key-str (if (symbolp key) (symbol-name key) (format "%s" key))))
        (if (and (consp val) (assq 'path (car val)))
            ;; SIZE or NAME mode: val is a list of file alists
            (push (cons key-str val) raw-groups)
          ;; HASH mode: val is a list of lists of file alists
          (dolist (grp val)
            (when (and (consp grp) (assq 'path (car grp)))
              (push (cons key-str grp) raw-groups))))))
    (setq raw-groups (nreverse raw-groups))
    (mapcar
     (lambda (item)
       (setq group-id (1+ group-id))
       (let* ((key-str (car item))
              (files (cdr item))
              (first-file (car files))
              (size (or (alist-get 'size first-file)
                        (string-to-number key-str)))
              (hash (alist-get 'hash first-file)))
         `((id . ,group-id)
           (key . ,key-str)
           (size . ,size)
           (hash . ,(and (not (string-empty-p (or hash ""))) hash))
           (files . ,files))))
     raw-groups)))

;;; Virtual Dired Buffer Rendering

(defvar zr-czkawka-dup-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "% n") #'zr-czkawka-dup-flag-all-except-newest)
    (define-key map (kbd "% o") #'zr-czkawka-dup-flag-all-except-oldest)
    (define-key map (kbd "% f") #'zr-czkawka-dup-flag-all-except-first)
    ;; (define-key map (kbd "=") #'zr-czkawka-dup-diff)
    map)
  "Keymap for `zr-czkawka-dup-mode'.")

(define-minor-mode zr-czkawka-dup-mode
  "Minor mode for managing duplicate files in a Virtual Dired buffer.
\\{zr-czkawka-dup-mode-map}"
  :lighter " Czkawka-Dup"
  :keymap zr-czkawka-dup-mode-map)

(defun zr-czkawka-dup--render-buffer (groups params)
  "Render duplicate GROUPS in a Virtual Dired buffer using PARAMS."
  (let* ((buf-name (or (plist-get params :buffer-name) zr-czkawka-dup-buffer-name))
         (buf (get-buffer-create buf-name))
         (dirs (plist-get params :directories))
         (top-dir (if dirs (car dirs) default-directory)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (grp groups)
          (let* ((id (alist-get 'id grp))
                 (files (alist-get 'files grp))
                 (file-count (length files))
                 (size (alist-get 'size grp))
                 (hash (alist-get 'hash grp))
                 (size-str (if (and size (> size 0))
                               (format ", Size: %s" (file-size-human-readable size 'iec))
                             ""))
                 (hash-str (if hash
                               (format ", Hash: %s" (truncate-string-to-width hash 8))
                             ""))
                 (header (format "  // Group %d [%d files%s%s]:\n" id file-count size-str hash-str)))
            (insert header)
            (dolist (f files)
              (let* ((path (alist-get 'path f))
                     (attrs (file-attributes path 'string)))
                (if attrs
                    (let* ((fsize (file-attribute-size attrs))
                           (line (ls-lisp-format path attrs fsize '(?l) nil)))
                      (insert "  " line))
                  (insert (format "  -rw-r--r-- 1 unknown unknown 0 01-01 00:00 %s\n" path)))))
            (insert "\n")))
        (dired-virtual top-dir)
        (zr-czkawka-dup-mode 1)
        (setq-local zr-czkawka-dup--params params)
        (setq-local zr-czkawka-dup--groups groups)
        (setq-local revert-buffer-function #'zr-czkawka-dup--revert)
        (let* ((total-groups (length groups))
               (total-files (apply #'+ (mapcar (lambda (g) (length (alist-get 'files g))) groups)))
               (total-waste (apply #'+ (mapcar (lambda (g)
                                                 (let ((files (alist-get 'files g)))
                                                   (if (> (length files) 1)
                                                       (* (1- (length files)) (or (alist-get 'size g) 0))
                                                     0)))
                                               groups))))
          (setq-local header-line-format
                      (format " Czkawka Dup: %d groups, %d files (%s wasted) | [d] Flag [x] Delete [%% n] Keep newest [%% o] Keep oldest [%% f] Keep first [g] Refresh"
                              total-groups total-files (file-size-human-readable total-waste 'iec))))
        (goto-char (point-min))
        (dired-next-line 1)))
    (pop-to-buffer buf)))

(defun zr-czkawka-dup--revert (&rest _)
  "Re-run duplicate search for current buffer."
  (interactive)
  (when-let* ((params zr-czkawka-dup--params))
    (message "Refreshing duplicate files scan...")
    (if-let* ((raw (plist-get params :raw-args)))
        (let ((args (split-string-and-unquote raw)))
          (zr-czkawka-run
           (cons "dup" args)
           (lambda (data)
             (let ((groups (zr-czkawka-dup--parse-json data)))
               (zr-czkawka-dup--render-buffer groups params)
               (message "Refreshed: %d duplicate groups found." (length groups))))))
      (let* ((dirs (plist-get params :directories))
             (method (or (plist-get params :search-method) zr-czkawka-dup-search-method))
             (args (zr-czkawka-dup--build-args dirs method)))
        (zr-czkawka-run
         (cons "dup" args)
         (lambda (data)
           (let ((groups (zr-czkawka-dup--parse-json data)))
             (zr-czkawka-dup--render-buffer groups params)
             (message "Refreshed: %d duplicate groups found." (length groups)))))))))

;;; Duplicate file management actions

(defun zr-czkawka-dup--current-group ()
  "Return the duplicate group containing the file at point, or nil."
  (when-let* ((file (dired-get-filename nil t)))
    (cl-find-if (lambda (grp)
                  (cl-find file (alist-get 'files grp)
                           :key (lambda (f) (expand-file-name (alist-get 'path f)))
                           :test #'equal))
                zr-czkawka-dup--groups)))

(defun zr-czkawka-dup-flag-all-except-newest (&optional current-group-only)
  "Flag all duplicate files for deletion except the newest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka-dup--flag-duplicates
   (lambda (files)
     (let ((sorted (sort (copy-sequence files)
                         (lambda (a b)
                           (let ((m1 (or (alist-get 'modified_date a) 0))
                                 (m2 (or (alist-get 'modified_date b) 0)))
                             (if (= m1 m2)
                                 (string< (alist-get 'path a) (alist-get 'path b))
                               (> m1 m2)))))))
       (cdr sorted)))
   current-group-only
   "newest"))

(defun zr-czkawka-dup-flag-all-except-oldest (&optional current-group-only)
  "Flag all duplicate files for deletion except the oldest in each group.
With prefix argument CURRENT-GROUP-ONLY, operate only on the group at point."
  (interactive "P")
  (zr-czkawka-dup--flag-duplicates
   (lambda (files)
     (let ((sorted (sort (copy-sequence files)
                         (lambda (a b)
                           (let ((m1 (or (alist-get 'modified_date a) 0))
                                 (m2 (or (alist-get 'modified_date b) 0)))
                             (if (= m1 m2)
                                 (string< (alist-get 'path a) (alist-get 'path b))
                               (< m1 m2)))))))
       (cdr sorted)))
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

(defun zr-czkawka-dup--flag-duplicates (select-candidates-fn current-group-only keep-label)
  "Internal helper to flag duplicates for deletion.
SELECT-CANDIDATES-FN takes a group's files and returns the files to flag.
If CURRENT-GROUP-ONLY is non-nil, only flag within the group at point.
KEEP-LABEL is a description of the kept file (e.g. \"newest\")."
  (let* ((target-groups (if current-group-only
                            (let ((grp (zr-czkawka-dup--current-group)))
                              (unless grp
                                (user-error "No duplicate group at point"))
                              (list grp))
                          zr-czkawka-dup--groups))
         (to-flag-paths nil))
    (dolist (grp target-groups)
      (let* ((files (alist-get 'files grp)))
        (when (> (length files) 1)
          (let ((candidates (funcall select-candidates-fn files)))
            (dolist (f candidates)
              (push (expand-file-name (alist-get 'path f)) to-flag-paths))))))
    (if (null to-flag-paths)
        (message "No duplicate files to flag.")
      (let ((to-flag-set (make-hash-table :test 'equal))
            (dired-marker-char dired-del-marker))
        (dolist (p to-flag-paths)
          (puthash p t to-flag-set))
        (ignore
         (dired-mark-if
          (let ((fn (dired-get-filename nil t)))
            (and fn (gethash (expand-file-name fn) to-flag-set)))
          "duplicate file"))
        (message "Flagged %d duplicate file(s) for deletion (kept %s)."
                 (length to-flag-paths) keep-label)))))

(defun zr-czkawka-dup-diff ()
  "Diff the file at point against another file in the same duplicate group."
  (interactive)
  (let* ((current-file (dired-get-filename nil t)))
    (unless current-file
      (user-error "No file at point"))
    (let* ((grp (zr-czkawka-dup--current-group)))
      (unless grp
        (user-error "Current file is not part of a duplicate group"))
      (let* ((files (mapcar (lambda (f) (expand-file-name (alist-get 'path f)))
                            (alist-get 'files grp)))
             (other-files (cl-remove (expand-file-name current-file) files :test #'equal)))
        (unless other-files
          (user-error "No duplicate counterpart to compare with"))
        (let ((target-file (if (= (length other-files) 1)
                               (car other-files)
                             (completing-read
                              (format "Diff %s with: " (file-name-nondirectory current-file))
                              other-files nil t))))
          (if (and (display-graphic-p) (fboundp 'ediff-files))
              (ediff-files current-file target-file)
            (diff current-file target-file)))))))

;;; Interactive commands

(defun zr-czkawka--read-directories ()
  "Prompt the user for one or more directories to scan."
  (let* ((marked-dirs (when (derived-mode-p 'dired-mode)
                        (delq nil (mapcar (lambda (f)
                                            (when (file-directory-p f)
                                              (expand-file-name f)))
                                          (dired-get-marked-files nil nil nil t))))))
    (if (and marked-dirs (> (length marked-dirs) 1))
        (if (y-or-n-p (format "Scan %d marked directories in Dired? " (length marked-dirs)))
            marked-dirs
          (zr-czkawka--read-directories-interactive))
      (zr-czkawka--read-directories-interactive))))

(defun zr-czkawka--read-directories-interactive ()
  "Interactively prompt for directories one by one."
  (let* ((default (if (derived-mode-p 'dired-mode)
                      (dired-current-directory)
                    default-directory))
         (first-dir (read-directory-name "Directory to scan: " default default t))
         (dirs (list (expand-file-name first-dir)))
         (continue t))
    (add-to-history 'zr-czkawka-directory-history first-dir)
    (while continue
      (let ((next-dir (read-directory-name "Add another directory (RET to start scan): " nil "" t)))
        (if (or (null next-dir) (string-empty-p (string-trim next-dir)))
            (setq continue nil)
          (let ((expanded (expand-file-name next-dir)))
            (unless (member expanded dirs)
              (setq dirs (append dirs (list expanded)))
              (add-to-history 'zr-czkawka-directory-history next-dir))))))
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
  (let* ((dir (if (derived-mode-p 'dired-mode)
                  (dired-current-directory)
                default-directory)))
    (format "-d %s -s %s"
            (shell-quote-argument (expand-file-name dir))
            (downcase zr-czkawka-dup-search-method))))

;;;###autoload
(defun zr-czkawka-dup (&optional arg)
  "Scan directories for duplicate files using czkawka_cli.
When called with prefix argument ARG, prompt for raw CLI arguments.
Otherwise, prompt for directory(ies) and search method."
  (interactive "P")
  (if arg
      (let* ((default-args (zr-czkawka-dup--default-raw-args))
             (raw (read-string "czkawka dup arguments: " default-args 'zr-czkawka-raw-args-history))
             (args (split-string-and-unquote raw)))
        (zr-czkawka-run
         (cons "dup" args)
         (lambda (data)
           (let ((groups (zr-czkawka-dup--parse-json data)))
             (if groups
                 (zr-czkawka-dup--render-buffer groups (list :raw-args raw))
               (message "No duplicate files found."))))))
    (let* ((dirs (zr-czkawka--read-directories))
           (method (completing-read
                    (format "Search method (default %s): " zr-czkawka-dup-search-method)
                    '("HASH" "SIZE" "NAME")
                    nil t nil 'zr-czkawka-search-method-history
                    zr-czkawka-dup-search-method))
           (args (zr-czkawka-dup--build-args dirs method)))
      (zr-czkawka-run
       (cons "dup" args)
       (lambda (data)
         (let ((groups (zr-czkawka-dup--parse-json data)))
           (if groups
               (zr-czkawka-dup--render-buffer groups (list :directories dirs :search-method method))
             (message "No duplicate files found in %s."
                      (string-join dirs ", ")))))))))

(provide 'zr-czkawka)

;;; zr-czkawka.el ends here
