;;; zr-czkawka-test.el --- Tests for zr-czkawka -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT test suite for zr-czkawka: CLI runner, JSON parser, Virtual Dired
;; rendering, duplicate flagging, and integration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dired)
(require 'dired-x)
(require 'subr-x)

(load (expand-file-name
       "../zr-czkawka.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(ert-deftest zr-czkawka-test-parse-json-hash ()
  "Test parsing czkawka HASH mode JSON output."
  (let* ((json-str "{\"42\":[[{\"path\":\"/tmp/dir1/c.txt\",\"modified_date\":100,\"size\":42,\"hash\":\"hash1\"},{\"path\":\"/tmp/dir2/d.txt\",\"modified_date\":200,\"size\":42,\"hash\":\"hash1\"}]],\"46\":[[{\"path\":\"/tmp/dir1/a.txt\",\"modified_date\":150,\"size\":46,\"hash\":\"hash2\"},{\"path\":\"/tmp/dir2/b.txt\",\"modified_date\":250,\"size\":46,\"hash\":\"hash2\"}]]}")
         (parsed (json-parse-string json-str :object-type 'alist :array-type 'list))
         (groups (zr-czkawka-dup--parse-json parsed)))
    (should (= (length groups) 2))
    (let ((g1 (nth 0 groups))
          (g2 (nth 1 groups)))
      (should (= (alist-get 'id g1) 1))
      (should (= (alist-get 'size g1) 42))
      (should (string= (alist-get 'hash g1) "hash1"))
      (should (= (length (alist-get 'files g1)) 2))
      (should (= (alist-get 'id g2) 2))
      (should (= (alist-get 'size g2) 46))
      (should (string= (alist-get 'hash g2) "hash2")))))

(ert-deftest zr-czkawka-test-parse-json-size-and-name ()
  "Test parsing czkawka SIZE and NAME mode JSON output."
  ;; SIZE mode
  (let* ((size-json "{\"100\":[{\"path\":\"/tmp/f1\",\"size\":100,\"modified_date\":1,\"hash\":\"\"},{\"path\":\"/tmp/f2\",\"size\":100,\"modified_date\":2,\"hash\":\"\"}]}")
         (parsed (json-parse-string size-json :object-type 'alist :array-type 'list))
         (groups (zr-czkawka-dup--parse-json parsed)))
    (should (= (length groups) 1))
    (let ((g (car groups)))
      (should (= (alist-get 'size g) 100))
      (should (null (alist-get 'hash g)))
      (should (= (length (alist-get 'files g)) 2))))
  ;; NAME mode
  (let* ((name-json "{\"dup.txt\":[{\"path\":\"/tmp/dir1/dup.txt\",\"size\":50,\"modified_date\":1,\"hash\":\"\"},{\"path\":\"/tmp/dir2/dup.txt\",\"size\":80,\"modified_date\":2,\"hash\":\"\"}]}")
         (parsed (json-parse-string name-json :object-type 'alist :array-type 'list))
         (groups (zr-czkawka-dup--parse-json parsed)))
    (should (= (length groups) 1))
    (let ((g (car groups)))
      (should (string= (alist-get 'key g) "dup.txt"))
      (should (= (length (alist-get 'files g)) 2)))))

(ert-deftest zr-czkawka-test-build-args ()
  "Test CLI arguments builder for czkawka dup."
  (let* ((zr-czkawka-dup-min-file-size 1024)
         (zr-czkawka-dup-hash-type "BLAKE3")
         (args (zr-czkawka-dup--build-args '("/tmp/dir1" "/tmp/dir2") "HASH")))
    (should (equal args (list "-d" (expand-file-name "/tmp/dir1")
                              "-d" (expand-file-name "/tmp/dir2")
                              "-s" "hash"
                              "-m" "1024"
                              "-t" "blake3")))))

(ert-deftest zr-czkawka-test-render-buffer-and-navigation ()
  "Test buffer rendering, dired-subdir-alist, and navigation."
  (let* ((tmp-dir (make-temp-file "zr-czkawka-test-render" t))
         (sub1 (expand-file-name "sub1" tmp-dir))
         (sub2 (expand-file-name "sub2" tmp-dir))
         (f1 (expand-file-name "a.txt" sub1))
         (f2 (expand-file-name "b.txt" sub2))
         (f3 (expand-file-name "c.txt" sub1))
         (f4 (expand-file-name "d.txt" sub2))
         (buf-name "*test-zr-czkawka-render*"))
    (make-directory sub1 t)
    (make-directory sub2 t)
    (with-temp-file f1 (insert "group 1 content"))
    (with-temp-file f2 (insert "group 1 content"))
    (with-temp-file f3 (insert "group 2 content here"))
    (with-temp-file f4 (insert "group 2 content here"))
    (unwind-protect
        (let* ((groups `(((id . 1)
                          (key . "15")
                          (size . 15)
                          (hash . "hash12345678")
                          (files . (((path . ,f1) (modified_date . 100))
                                    ((path . ,f2) (modified_date . 200)))))
                         ((id . 2)
                          (key . "20")
                          (size . 20)
                          (hash . "hash87654321")
                          (files . (((path . ,f3) (modified_date . 300))
                                    ((path . ,f4) (modified_date . 150)))))))
               (params (list :directory tmp-dir)))
          (zr-czkawka-dup--render-buffer groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            (should zr-czkawka-dup-mode)
            (should (= (length dired-subdir-alist) 2))
            (should (string-prefix-p " Czkawka Dup: 2 groups" header-line-format))
            (goto-char (point-min))
            (dired-next-line 1)
            (should (string= (dired-get-filename) f1))
            (dired-next-subdir 1)
            (dired-next-line 1)
            (should (string= (dired-get-filename) f3))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name))
      (delete-directory tmp-dir t))))

(ert-deftest zr-czkawka-test-flag-duplicates ()
  "Test flagging duplicates: keep newest, keep oldest, and keep first."
  (let* ((tmp-dir (make-temp-file "zr-czkawka-test-flag" t))
         (f1 (expand-file-name "1.txt" tmp-dir))
         (f2 (expand-file-name "2.txt" tmp-dir))
         (f3 (expand-file-name "3.txt" tmp-dir))
         (buf-name "*test-zr-czkawka-flag*"))
    (with-temp-file f1 (insert "dup"))
    (with-temp-file f2 (insert "dup"))
    (with-temp-file f3 (insert "dup"))
    (unwind-protect
        (let* ((groups `(((id . 1)
                          (size . 3)
                          (hash . "h")
                          (files . (((path . ,f1) (modified_date . 100))
                                    ((path . ,f2) (modified_date . 300))
                                    ((path . ,f3) (modified_date . 200)))))))
               (params (list :directory tmp-dir)))
          (zr-czkawka-dup--render-buffer groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            ;; Test keep newest: f2 is newest (mtime 300), f1 and f3 should be flagged
            (zr-czkawka-dup-flag-all-except-newest)
            (let ((dired-marker-char dired-del-marker))
              (should (equal (sort (dired-get-marked-files) #'string<)
                             (sort (list f1 f3) #'string<))))
            ;; Unmark all
            (dired-unmark-all-marks)
            ;; Test keep oldest: f1 is oldest (mtime 100), f2 and f3 should be flagged
            (zr-czkawka-dup-flag-all-except-oldest)
            (let ((dired-marker-char dired-del-marker))
              (should (equal (sort (dired-get-marked-files) #'string<)
                             (sort (list f2 f3) #'string<))))
            ;; Unmark all
            (dired-unmark-all-marks)
            ;; Test keep first: f1 is first, f2 and f3 should be flagged
            (zr-czkawka-dup-flag-all-except-first)
            (let ((dired-marker-char dired-del-marker))
              (should (equal (sort (dired-get-marked-files) #'string<)
                             (sort (list f2 f3) #'string<))))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name))
      (delete-directory tmp-dir t))))

(ert-deftest zr-czkawka-test-cli-integration ()
  "Integration test running czkawka_cli binary on test files."
  (skip-unless (or (executable-find zr-czkawka-program)
                   (file-executable-p zr-czkawka-program)))
  (let* ((tmp-dir (make-temp-file "zr-czkawka-integ" t))
         (d1 (expand-file-name "dir1" tmp-dir))
         (d2 (expand-file-name "dir2" tmp-dir))
         (f1 (expand-file-name "file1.txt" d1))
         (f2 (expand-file-name "file2.txt" d2))
         (content "unique content for integration testing duplicate files 1234567890")
         (buf-name "*test-zr-czkawka-integ*")
         (done nil)
         (result-groups nil))
    (make-directory d1 t)
    (make-directory d2 t)
    (with-temp-file f1 (insert content))
    (with-temp-file f2 (insert content))
    (unwind-protect
        (let ((args (list "dup" "-d" tmp-dir "-m" "1" "-s" "hash")))
          (zr-czkawka-run
           args
           (lambda (data)
             (setq result-groups (zr-czkawka-dup--parse-json data))
             (zr-czkawka-dup--render-buffer result-groups
                                            (list :directory tmp-dir)
                                            buf-name)
             (setq done t)))
          (while (not done)
            (accept-process-output nil 0.1))
          (should (= (length result-groups) 1))
          (let ((grp (car result-groups)))
            (should (= (length (alist-get 'files grp)) 2)))
          (with-current-buffer (get-buffer buf-name)
            (should (= (length dired-subdir-alist) 1))
            (goto-char (point-min))
            (dired-next-line 1)
            (should (member (dired-get-filename) (list f1 f2)))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name))
      (delete-directory tmp-dir t))))

(ert-deftest zr-czkawka-test-flag-current-group-only ()
  "Test flagging duplicates only within the current group."
  (let* ((tmp-dir (make-temp-file "zr-czkawka-test-grp" t))
         (f1 (expand-file-name "1.txt" tmp-dir))
         (f2 (expand-file-name "2.txt" tmp-dir))
         (f3 (expand-file-name "3.txt" tmp-dir))
         (f4 (expand-file-name "4.txt" tmp-dir))
         (buf-name "*test-zr-czkawka-grp*"))
    (with-temp-file f1 (insert "dup1"))
    (with-temp-file f2 (insert "dup1"))
    (with-temp-file f3 (insert "dup2"))
    (with-temp-file f4 (insert "dup2"))
    (unwind-protect
        (let* ((groups `(((id . 1)
                          (size . 4)
                          (files . (((path . ,f1) (modified_date . 200))
                                    ((path . ,f2) (modified_date . 100)))))
                         ((id . 2)
                          (size . 4)
                          (files . (((path . ,f3) (modified_date . 200))
                                    ((path . ,f4) (modified_date . 100)))))))
               (params (list :directory tmp-dir)))
          (zr-czkawka-dup--render-buffer groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            ;; Point is on f1 (Group 1)
            (goto-char (point-min))
            (dired-next-line 1)
            (should (string= (dired-get-filename) f1))
            ;; Flag current group only (prefix arg = t)
            (zr-czkawka-dup-flag-all-except-newest t)
            (let ((dired-marker-char dired-del-marker))
              ;; Only f2 should be flagged; f4 in group 2 should NOT be flagged
              (should (equal (dired-get-marked-files) (list f2))))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name))
      (delete-directory tmp-dir t))))

(ert-deftest zr-czkawka-test-diff ()
  "Test diff command invoking diff on counterpart file."
  (let* ((tmp-dir (make-temp-file "zr-czkawka-test-diff" t))
         (f1 (expand-file-name "a.txt" tmp-dir))
         (f2 (expand-file-name "b.txt" tmp-dir))
         (buf-name "*test-zr-czkawka-diff*")
         (diff-called nil))
    (with-temp-file f1 (insert "diff test"))
    (with-temp-file f2 (insert "diff test"))
    (unwind-protect
        (let* ((groups `(((id . 1)
                          (size . 9)
                          (files . (((path . ,f1) (modified_date . 100))
                                    ((path . ,f2) (modified_date . 200)))))))
               (params (list :directory tmp-dir)))
          (zr-czkawka-dup--render-buffer groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            (goto-char (point-min))
            (dired-next-line 1)
            (cl-letf (((symbol-function 'diff)
                       (lambda (file-a file-b &rest _)
                         (setq diff-called (list file-a file-b))))
                      ((symbol-function 'display-graphic-p) (lambda () nil)))
              (zr-czkawka-dup-diff)
              (should (equal diff-called (list f1 f2))))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name))
      (delete-directory tmp-dir t))))

(ert-deftest zr-czkawka-test-keymap ()
  "Test key bindings in `zr-czkawka-dup-mode-map'."
  (should (eq (lookup-key zr-czkawka-dup-mode-map (kbd "% n")) #'zr-czkawka-dup-flag-all-except-newest))
  (should (eq (lookup-key zr-czkawka-dup-mode-map (kbd "% o")) #'zr-czkawka-dup-flag-all-except-oldest))
  (should (eq (lookup-key zr-czkawka-dup-mode-map (kbd "% f")) #'zr-czkawka-dup-flag-all-except-first))
  (should (eq (lookup-key zr-czkawka-dup-mode-map [remap revert-buffer]) #'zr-czkawka-dup-rescan)))

;;; Regression tests

(defmacro zr-czkawka-test--with-dup-buffer (spec &rest body)
  "Render duplicate groups in a temporary Virtual Dired buffer.
SPEC is (FILES-VAR GROUPS-FORM), where FILES-VAR is bound to a list of
four fresh files before GROUPS-FORM is evaluated.  Run BODY in the
buffer and clean up afterwards."
  (declare (indent 1))
  (let ((files-var (car spec)))
    `(let* ((tmp-dir (make-temp-file "zr-czkawka-test" t))
            (,files-var (mapcar (lambda (n) (expand-file-name n tmp-dir))
                                '("1.txt" "2.txt" "3.txt" "4.txt")))
            (buf-name "*test-zr-czkawka*"))
       (dolist (f ,files-var) (with-temp-file f (insert "dup")))
       (unwind-protect
           (progn
             (zr-czkawka-dup--render-buffer ,(cadr spec)
                                            (list :directory tmp-dir
                                                  :args '("-d" "/tmp"))
                                            buf-name)
             (with-current-buffer buf-name ,@body))
         (when (get-buffer buf-name) (kill-buffer buf-name))
         (delete-directory tmp-dir t)))))

(defun zr-czkawka-test--flagged ()
  "Return the sorted list of files flagged for deletion."
  (let (files)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (eq (char-after) dired-del-marker)
          (push (dired-get-filename) files))
        (forward-line 1)))
    (sort files #'string<)))

(defun zr-czkawka-test--listed ()
  "Return the listed files in buffer order.
Also check that each line is tagged with its own file."
  (let (files)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        ;; `save-excursion': this moves point in hidden groups.
        (when-let* ((file (save-excursion (dired-get-filename nil t))))
          (should (equal (alist-get 'path (zr-czkawka-dup--line-property
                                           'zr-czkawka-dup-file))
                         file))
          (push file files))
        (forward-line 1)))
    (nreverse files)))

(defun zr-czkawka-test--hidden-groups ()
  "Return the sorted ids of the hidden duplicate groups."
  (save-excursion
    (sort (cl-loop for (dir . pos) in dired-subdir-alist
                   when (dired-subdir-hidden-p dir)
                   collect (progn (goto-char pos)
                                  (zr-czkawka-dup--line-property
                                   'zr-czkawka-dup-group)))
          #'<)))

(defun zr-czkawka-test--shows-inode-p (file)
  "Return non-nil if the listing line of FILE shows its inode number."
  (save-excursion
    (dired-goto-file file)
    (string-search (number-to-string
                    (file-attribute-inode-number (file-attributes file)))
                   (buffer-substring (line-beginning-position)
                                     (line-end-position)))))

(defun zr-czkawka-test--group (id &rest files)
  "Build group ID of FILES, each a (PATH MTIME [REFERENCE])."
  `((id . ,id) (size . 3)
    (files . ,(mapcar (lambda (f)
                        `(,@(and (nth 2 f) '((reference . t)))
                          (path . ,(car f)) (modified_date . ,(cadr f))))
                      files))))

(ert-deftest zr-czkawka-test-flag-skips-deleted-files ()
  "Files deleted after the scan must not count as the kept copy."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 300) (list (nth 1 fs) 100))))
    ;; The newest copy disappears from disk: the last one must survive.
    (delete-file (nth 0 fs))
    (zr-czkawka-dup-flag-all-except-newest)
    (should-not (zr-czkawka-test--flagged))))

(ert-deftest zr-czkawka-test-flag-skips-removed-lines ()
  "Files removed from the buffer are no longer part of their group."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 100)
                                          (list (nth 1 fs) 200)
                                          (list (nth 2 fs) 300))))
    (dired-goto-file (nth 0 fs))
    (dired-kill-line)
    (zr-czkawka-dup-flag-all-except-first)
    (should (equal (zr-czkawka-test--flagged) (list (nth 2 fs))))))

(ert-deftest zr-czkawka-test-flag-replaces-previous-flags ()
  "Flagging again resets the group's flags so one copy is always kept."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 100) (list (nth 1 fs) 200))
                (zr-czkawka-test--group 2 (list (nth 2 fs) 100) (list (nth 3 fs) 200))))
    (zr-czkawka-dup-flag-all-except-newest)
    (zr-czkawka-dup-flag-all-except-oldest)
    (should (equal (zr-czkawka-test--flagged) (list (nth 1 fs) (nth 3 fs))))
    ;; Current-group-only leaves other groups' flags alone.
    (dired-goto-file (nth 0 fs))
    (zr-czkawka-dup-flag-all-except-newest t)
    (should (equal (zr-czkawka-test--flagged) (list (nth 0 fs) (nth 3 fs))))))

(ert-deftest zr-czkawka-test-flag-never-flags-reference ()
  "Reference files are protected and do not replace the kept copy."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 999 t)
                                          (list (nth 1 fs) 100)
                                          (list (nth 2 fs) 200))))
    (zr-czkawka-dup-flag-all-except-newest)
    (should (equal (zr-czkawka-test--flagged) (list (nth 1 fs))))))

(ert-deftest zr-czkawka-test-parse-json-reference ()
  "Parse the reference-directory JSON shapes of each search method."
  (dolist (json '(;; HASH: list of [ref, [files]] per size
                  "{\"6\":[[{\"path\":\"/r/a\",\"size\":6,\"hash\":\"h\"},[{\"path\":\"/x/a\",\"size\":6,\"hash\":\"h\"},{\"path\":\"/y/a\",\"size\":6,\"hash\":\"h\"}]]]}"
                  ;; SIZE: a single [ref, [files]] per size
                  "{\"6\":[{\"path\":\"/r/a\",\"size\":6,\"hash\":\"\"},[{\"path\":\"/x/a\",\"size\":6,\"hash\":\"\"},{\"path\":\"/y/a\",\"size\":6,\"hash\":\"\"}]]}"
                  ;; NAME: keyed by reference path
                  "{\"/r/a\":[{\"path\":\"/r/a\",\"size\":6,\"hash\":\"\"},[{\"path\":\"/x/a\",\"size\":6,\"hash\":\"\"},{\"path\":\"/y/a\",\"size\":6,\"hash\":\"\"}]]}"))
    (let* ((groups (zr-czkawka-dup--parse-json
                    (json-parse-string json :object-type 'alist :array-type 'list)))
           (files (alist-get 'files (car groups))))
      (should (= (length groups) 1))
      (should (equal (mapcar (lambda (f) (alist-get 'path f)) files)
                     '("/r/a" "/x/a" "/y/a")))
      (should (equal (mapcar (lambda (f) (alist-get 'reference f)) files)
                     '(t nil nil))))))

(ert-deftest zr-czkawka-test-header-line-escapes-percent ()
  "The `%' key hints must survive mode line %-construct expansion."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 1) (list (nth 1 fs) 2))))
    (should (string-search "[%% n] Keep newest" header-line-format))))

(ert-deftest zr-czkawka-test-default-raw-args-round-trip ()
  "Default raw arguments must split back into the original directory."
  (dolist (dir (list (file-name-as-directory (make-temp-file "zr czkawka 中文" t))))
    (unwind-protect
        (let ((default-directory dir))
          (should (equal (cadr (split-string-and-unquote
                                (zr-czkawka-dup--default-raw-args)))
                         dir)))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-read-directories-single-mark ()
  "A single explicitly marked file in Dired must not signal an error."
  (let ((dir (make-temp-file "zr-czkawka-test-marks" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "a" dir))
          (make-directory (expand-file-name "b" dir))
          (with-current-buffer (dired-noselect dir)
            (unwind-protect
                (cl-letf (((symbol-function 'zr-czkawka--read-directories-interactive)
                           (lambda () 'interactive))
                          ((symbol-function 'y-or-n-p) #'always))
                  (dired-goto-file (expand-file-name "a" dir))
                  (dired-mark 1)
                  (should (eq (zr-czkawka--read-directories) 'interactive))
                  (dired-goto-file (expand-file-name "b" dir))
                  (dired-mark 1)
                  (should (equal (zr-czkawka--read-directories)
                                 (list (expand-file-name "a" dir)
                                       (expand-file-name "b" dir)))))
              (kill-buffer))))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-rescan-prefix-edits-args ()
  "Rescanning with a prefix argument edits the stored arguments."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 1) (list (nth 1 fs) 2))))
    (should (eq (key-binding (kbd "g")) #'zr-czkawka-dup-rescan))
    (let (scanned initial)
      (cl-letf (((symbol-function 'zr-czkawka-dup--scan)
                 (lambda (args dir buf) (setq scanned (list args dir buf))))
                ((symbol-function 'read-string)
                 (lambda (_prompt init &rest _)
                   (setq initial init)
                   "-d \"/a b\" -s size")))
        (zr-czkawka-dup-rescan)
        (should (equal (car scanned) '("-d" "/tmp")))
        (zr-czkawka-dup-rescan '(4))
        (should (equal initial "-d /tmp"))
        (should (equal (car scanned) '("-d" "/a b" "-s" "size")))
        (should (equal (cadr scanned) tmp-dir))
        (should (eq (nth 2 scanned) (current-buffer)))))))

(ert-deftest zr-czkawka-test-sort-files ()
  "Files of a group are sorted as `ls' sorts them with the switches."
  (let* ((dir (make-temp-file "zr-czkawka-test-sort" t))
         (files (mapcar (lambda (name) `((path . ,(expand-file-name name dir))))
                        '("b.txt" "a.el" "c.txt")))
         (sorted (lambda (switches &optional fs)
                   (mapcar (lambda (f) (file-name-nondirectory (alist-get 'path f)))
                           (zr-czkawka-dup--sort-files (or fs files) switches)))))
    (unwind-protect
        (progn
          (cl-mapc (lambda (f size mtime)
                     (with-temp-file (alist-get 'path f)
                       (insert (make-string size ?x)))
                     (set-file-times (alist-get 'path f) mtime))
                   files '(1 3 2) '(200 100 300))
          (should (equal (funcall sorted "-al") '("a.el" "b.txt" "c.txt")))
          (should (equal (funcall sorted "-alt") '("c.txt" "b.txt" "a.el")))
          (should (equal (funcall sorted "-al --sort=time --reverse")
                         '("a.el" "b.txt" "c.txt")))
          (should (equal (funcall sorted "-alS") '("a.el" "c.txt" "b.txt")))
          (should (equal (funcall sorted "-alXr") '("c.txt" "b.txt" "a.el")))
          (should (equal (funcall sorted "-alU") '("b.txt" "a.el" "c.txt")))
          ;; Reference files stay first; files no longer on disk are dropped.
          (delete-file (alist-get 'path (nth 1 files)))
          (should (equal (funcall sorted "-al"
                                  (list (nth 0 files) (nth 1 files)
                                        (cons '(reference . t) (nth 2 files))))
                         '("c.txt" "b.txt"))))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-sort-switches-redisplay ()
  "Sorting relists files with the new switches without rescanning.
Flags, point and hidden groups are kept, and so are the switches when
new scan results are rendered."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 1) (list (nth 1 fs) 2))
                (zr-czkawka-test--group 2 (list (nth 2 fs) 1) (list (nth 3 fs) 2))))
    (cl-mapc #'set-file-times fs '(100 200 300 300))
    (let ((prompts 0))
      (cl-letf (((symbol-function 'zr-czkawka-dup--scan)
                 (lambda (&rest _) (error "Unexpected rescan")))
                ((symbol-function 'read-string)
                 (lambda (&rest _) (cl-incf prompts) "-ali")))
        (dired-goto-file (nth 0 fs))
        (dired-flag-file-deletion 1)
        (dired-goto-file (nth 2 fs))
        (dired-hide-subdir 1)
        (dired-goto-file (nth 0 fs))
        ;; `s' sorts each group by date, newest first, ties by name.
        (dired-sort-toggle-or-edit)
        (should (equal (zr-czkawka-test--listed)
                       (list (nth 1 fs) (nth 0 fs) (nth 2 fs) (nth 3 fs))))
        (should (equal (dired-get-filename) (nth 0 fs)))
        (should (equal (zr-czkawka-test--flagged) (list (nth 0 fs))))
        (should (equal (zr-czkawka-test--hidden-groups) '(2)))
        ;; `C-u s' only prompts for the `ls' switches.
        (let ((current-prefix-arg '(4)))
          (call-interactively #'dired-sort-toggle-or-edit))
        (should (= prompts 1))
        (should (equal dired-actual-switches "-ali"))
        (should (equal (zr-czkawka-test--listed) fs))
        (should (zr-czkawka-test--shows-inode-p (nth 0 fs)))
        (should (equal (dired-get-filename) (nth 0 fs)))
        (should (equal (zr-czkawka-test--flagged) (list (nth 0 fs))))
        (should (equal (zr-czkawka-test--hidden-groups) '(2)))
        ;; New scan results keep the switches.
        (zr-czkawka-dup--render-buffer zr-czkawka-dup--groups zr-czkawka-dup--params
                                       (current-buffer))
        (should (equal dired-actual-switches "-ali"))
        (should (zr-czkawka-test--shows-inode-p (nth 1 fs)))))))

(ert-deftest zr-czkawka-test-render-with-ls-lisp ()
  "Files are listed through `insert-directory', so `ls-lisp' works too."
  (let ((loaded (featurep 'ls-lisp)))
    (require 'ls-lisp)
    (unwind-protect
        (let ((ls-lisp-use-insert-directory-program nil))
          (zr-czkawka-test--with-dup-buffer
              (fs (list (zr-czkawka-test--group 1 (list (nth 1 fs) 1) (list (nth 0 fs) 2))))
            (should (equal (zr-czkawka-test--listed) (list (nth 0 fs) (nth 1 fs))))
            (dired-sort-other "-ali")
            (should (zr-czkawka-test--shows-inode-p (nth 0 fs)))
            (zr-czkawka-dup-flag-all-except-first)
            (should (equal (zr-czkawka-test--flagged) (list (nth 1 fs))))))
      (unless loaded
        (unload-feature 'ls-lisp)))))

(ert-deftest zr-czkawka-test-run-critical-error ()
  "A czkawka critical error with exit code 0 must go to the error callback."
  (skip-unless (or (executable-find zr-czkawka-program)
                   (file-executable-p zr-czkawka-program)))
  (let (done result)
    (zr-czkawka-run (list "dup" "-d" "/nonexistent/zr-czkawka-test")
                    (lambda (_) (setq done t result 'success))
                    (lambda (_code _buf) (setq done t result 'error)))
    (with-timeout (30 (error "Timed out"))
      (while (not done) (accept-process-output nil 0.1)))
    (should (eq result 'error))))

(provide 'zr-czkawka-test)

;;; zr-czkawka-test.el ends here
