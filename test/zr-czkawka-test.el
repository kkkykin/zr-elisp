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
      (should (equal (zr-czkawka-dup--group-info g1) ", Size: 42B, Hash: hash1"))
      (should (= (length (alist-get 'files g1)) 2))
      (should (= (alist-get 'id g2) 2))
      (should (equal (zr-czkawka-dup--group-info g2) ", Size: 46B, Hash: hash2")))))

(ert-deftest zr-czkawka-test-parse-json-size-and-name ()
  "Test parsing czkawka SIZE and NAME mode JSON output."
  ;; SIZE mode
  (let* ((size-json "{\"100\":[{\"path\":\"/tmp/f1\",\"size\":100,\"modified_date\":1,\"hash\":\"\"},{\"path\":\"/tmp/f2\",\"size\":100,\"modified_date\":2,\"hash\":\"\"}]}")
         (parsed (json-parse-string size-json :object-type 'alist :array-type 'list))
         (groups (zr-czkawka-dup--parse-json parsed)))
    (should (= (length groups) 1))
    (let ((g (car groups)))
      (should (equal (zr-czkawka-dup--group-info g) ", Size: 100B"))
      (should (= (length (alist-get 'files g)) 2))))
  ;; NAME mode
  (let* ((name-json "{\"dup.txt\":[{\"path\":\"/tmp/dir1/dup.txt\",\"size\":50,\"modified_date\":1,\"hash\":\"\"},{\"path\":\"/tmp/dir2/dup.txt\",\"size\":80,\"modified_date\":2,\"hash\":\"\"}]}")
         (parsed (json-parse-string name-json :object-type 'alist :array-type 'list))
         (groups (zr-czkawka-dup--parse-json parsed)))
    (should (= (length groups) 1))
    (let ((g (car groups)))
      (should (equal (mapcar (lambda (f) (alist-get 'path f)) (alist-get 'files g))
                     '("/tmp/dir1/dup.txt" "/tmp/dir2/dup.txt"))))))

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
          (zr-czkawka--render-buffer zr-czkawka-dup-tool groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            (should zr-czkawka-mode)
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
          (zr-czkawka--render-buffer zr-czkawka-dup-tool groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            ;; Test keep newest: f2 is newest (mtime 300), f1 and f3 should be flagged
            (zr-czkawka-flag-all-except-newest)
            (let ((dired-marker-char dired-del-marker))
              (should (equal (sort (dired-get-marked-files) #'string<)
                             (sort (list f1 f3) #'string<))))
            ;; Unmark all
            (dired-unmark-all-marks)
            ;; Test keep oldest: f1 is oldest (mtime 100), f2 and f3 should be flagged
            (zr-czkawka-flag-all-except-oldest)
            (let ((dired-marker-char dired-del-marker))
              (should (equal (sort (dired-get-marked-files) #'string<)
                             (sort (list f2 f3) #'string<))))
            ;; Unmark all
            (dired-unmark-all-marks)
            ;; Test keep first: f1 is first, f2 and f3 should be flagged
            (zr-czkawka-flag-all-except-first)
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
             (zr-czkawka--render-buffer zr-czkawka-dup-tool result-groups
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
          (zr-czkawka--render-buffer zr-czkawka-dup-tool groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            ;; Point is on f1 (Group 1)
            (goto-char (point-min))
            (dired-next-line 1)
            (should (string= (dired-get-filename) f1))
            ;; Flag current group only (prefix arg = t)
            (zr-czkawka-flag-all-except-newest t)
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
          (zr-czkawka--render-buffer zr-czkawka-dup-tool groups params buf-name)
          (with-current-buffer (get-buffer buf-name)
            (goto-char (point-min))
            (dired-next-line 1)
            (cl-letf (((symbol-function 'diff)
                       (lambda (file-a file-b &rest _)
                         (setq diff-called (list file-a file-b))))
                      ((symbol-function 'display-graphic-p) (lambda () nil)))
              (zr-czkawka-diff)
              (should (equal diff-called (list f1 f2))))))
      (when (get-buffer buf-name)
        (kill-buffer buf-name))
      (delete-directory tmp-dir t))))

(ert-deftest zr-czkawka-test-keymap ()
  "Test key bindings in `zr-czkawka-group-map'."
  (should (eq (lookup-key zr-czkawka-group-map (kbd "% n")) #'zr-czkawka-flag-all-except-newest))
  (should (eq (lookup-key zr-czkawka-group-map (kbd "% o")) #'zr-czkawka-flag-all-except-oldest))
  (should (eq (lookup-key zr-czkawka-group-map (kbd "% f")) #'zr-czkawka-flag-all-except-first))
  (should (eq (lookup-key zr-czkawka-group-map (kbd "% b")) #'zr-czkawka-flag-all-except-biggest))
  (should (eq (lookup-key zr-czkawka-group-map [remap revert-buffer]) #'zr-czkawka-rescan)))

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
             (zr-czkawka--render-buffer zr-czkawka-dup-tool ,(cadr spec)
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
          (should (equal (alist-get 'path (zr-czkawka--line-property
                                           'zr-czkawka-file))
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
                                  (zr-czkawka--line-property
                                   'zr-czkawka-group)))
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
    (zr-czkawka-flag-all-except-newest)
    (should-not (zr-czkawka-test--flagged))))

(ert-deftest zr-czkawka-test-flag-skips-removed-lines ()
  "Files removed from the buffer are no longer part of their group."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 100)
                                          (list (nth 1 fs) 200)
                                          (list (nth 2 fs) 300))))
    (dired-goto-file (nth 0 fs))
    (dired-kill-line)
    (zr-czkawka-flag-all-except-first)
    (should (equal (zr-czkawka-test--flagged) (list (nth 2 fs))))))

(ert-deftest zr-czkawka-test-flag-replaces-previous-flags ()
  "Flagging again resets the group's flags so one copy is always kept."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 100) (list (nth 1 fs) 200))
                (zr-czkawka-test--group 2 (list (nth 2 fs) 100) (list (nth 3 fs) 200))))
    (zr-czkawka-flag-all-except-newest)
    (zr-czkawka-flag-all-except-oldest)
    (should (equal (zr-czkawka-test--flagged) (list (nth 1 fs) (nth 3 fs))))
    ;; Current-group-only leaves other groups' flags alone.
    (dired-goto-file (nth 0 fs))
    (zr-czkawka-flag-all-except-newest t)
    (should (equal (zr-czkawka-test--flagged) (list (nth 0 fs) (nth 3 fs))))))

(ert-deftest zr-czkawka-test-flag-never-flags-reference ()
  "Reference files are protected and do not replace the kept copy."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 999 t)
                                          (list (nth 1 fs) 100)
                                          (list (nth 2 fs) 200))))
    (zr-czkawka-flag-all-except-newest)
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
        (let ((default-directory dir)
              scanned)
          (cl-letf (((symbol-function 'read-string)
                     (lambda (_prompt initial &rest _) initial))
                    ((symbol-function 'zr-czkawka--scan)
                     (lambda (_tool args dir &rest _) (setq scanned (list args dir)))))
            (zr-czkawka-dup t))
          (should (equal (cadr (car scanned)) dir))
          (should (equal (cadr scanned) dir)))
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
    (should (eq (key-binding (kbd "g")) #'zr-czkawka-rescan))
    (let (scanned initial)
      (cl-letf (((symbol-function 'zr-czkawka--scan)
                 (lambda (_tool args dir buf) (setq scanned (list args dir buf))))
                ((symbol-function 'read-string)
                 (lambda (_prompt init &rest _)
                   (setq initial init)
                   "-d \"/a b\" -s size")))
        (zr-czkawka-rescan)
        (should (equal (car scanned) '("-d" "/tmp")))
        (zr-czkawka-rescan '(4))
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
                           (zr-czkawka--sort-files (or fs files) switches)))))
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
      (cl-letf (((symbol-function 'zr-czkawka--scan)
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
        (zr-czkawka--render-buffer zr-czkawka-dup-tool zr-czkawka--groups zr-czkawka--params
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
            (zr-czkawka-flag-all-except-first)
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

;;; Other tools

(defmacro zr-czkawka-test--skip-unless-cli ()
  "Skip the current test unless czkawka_cli is available."
  '(skip-unless (or (executable-find zr-czkawka-program)
                    (file-executable-p zr-czkawka-program))))

(defun zr-czkawka-test--run (tool args)
  "Run TOOL with czkawka ARGS synchronously and return its groups."
  (let (done groups)
    (zr-czkawka-run (cons (zr-czkawka-tool-name tool) args)
                    (lambda (data)
                      (setq groups (funcall (zr-czkawka-tool-parse tool) data)
                            done t))
                    (lambda (code buf)
                      (error "czkawka failed (%s): %s" code
                             (with-current-buffer buf (buffer-string)))))
    (with-timeout (120 (error "Timed out"))
      (while (not done) (accept-process-output nil 0.1)))
    groups))

(defun zr-czkawka-test--paths (group)
  "Return the paths of the files of GROUP."
  (mapcar (lambda (f) (alist-get 'path f)) (alist-get 'files group)))

(defmacro zr-czkawka-test--with-tool-buffer (spec &rest body)
  "Render results of a tool in a temporary Virtual Dired buffer.
SPEC is (TOOL GROUPS-FORM DIRECTORY).  Run BODY in the buffer."
  (declare (indent 1))
  `(let ((buf-name "*test-zr-czkawka-tool*"))
     (unwind-protect
         (progn
           (zr-czkawka--render-buffer ,(nth 0 spec) ,(nth 1 spec)
                                      (list :directory ,(nth 2 spec) :args nil)
                                      buf-name)
           (with-current-buffer buf-name ,@body))
       (when (get-buffer buf-name) (kill-buffer buf-name)))))

(defun zr-czkawka-test--annotations ()
  "Return the file details shown in the buffer, in buffer order."
  (let (texts)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when-let* ((text (overlay-get ov 'after-string)))
        (push (cons (overlay-start ov) (string-trim text)) texts)))
    (mapcar #'cdr (sort texts (lambda (a b) (< (car a) (car b)))))))

(ert-deftest zr-czkawka-test-big-build-args ()
  "Test CLI arguments of czkawka big."
  (should (equal (zr-czkawka-big--build-args '("/tmp/a") "biggest" 10)
                 (list "-d" (expand-file-name "/tmp/a") "-n" "10")))
  (should (equal (zr-czkawka-big--build-args '("/tmp/a") "smallest" 5)
                 (list "-d" (expand-file-name "/tmp/a") "-n" "5" "-J"))))

(ert-deftest zr-czkawka-test-big ()
  "Big files are listed in czkawka order, as a single group."
  (zr-czkawka-test--skip-unless-cli)
  (let ((dir (make-temp-file "zr-czkawka-test-big" t)))
    (unwind-protect
        (let ((files (mapcar (lambda (n) (expand-file-name n dir)) '("a" "b" "c"))))
          (cl-mapc (lambda (f size)
                     (with-temp-file f (insert (make-string size ?x))))
                   files '(200 300 100))
          (let ((groups (zr-czkawka-test--run
                         zr-czkawka-big-tool
                         (zr-czkawka-big--build-args (list dir) "biggest" 2))))
            (should (= (length groups) 1))
            (should (equal (zr-czkawka-test--paths (car groups))
                           (list (nth 1 files) (nth 0 files))))
            (zr-czkawka-test--with-tool-buffer (zr-czkawka-big-tool groups dir)
              (should (equal (zr-czkawka-test--listed)
                             (list (nth 1 files) (nth 0 files))))
              (should (string-prefix-p " Czkawka Big files: 2 files (500B)"
                                       header-line-format))
              (should-not (key-binding (kbd "% n")))
              (should (eq (key-binding (kbd "g")) #'zr-czkawka-rescan))
              ;; Sorting by name overrides the order of czkawka.
              (dired-sort-other "-al")
              (should (equal (zr-czkawka-test--listed)
                             (list (nth 0 files) (nth 1 files))))))
          (should (equal (zr-czkawka-test--paths
                          (car (zr-czkawka-test--run
                                zr-czkawka-big-tool
                                (zr-czkawka-big--build-args (list dir) "smallest" 1))))
                         (list (nth 2 files)))))
      (delete-directory dir t))))

(defun zr-czkawka-test--ffmpeg (&rest args)
  "Run ffmpeg with ARGS, signaling an error on failure."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "ffmpeg" nil t nil
                          "-loglevel" "error" "-y" args))
      (error "ffmpeg failed: %s" (buffer-string)))))

(defun zr-czkawka-test--json-files (dir &rest files)
  "Return a JSON array of czkawka FILES entries in DIR.
Each of FILES is a list (NAME . PROPS), where PROPS is a plist of
JSON properties; the files are created with their `size'."
  (concat "["
          (mapconcat
           (lambda (f)
             (let ((path (expand-file-name (car f) dir)))
               (with-temp-file path
                 (insert (make-string (or (plist-get (cdr f) :size) 1) ?x)))
               (json-serialize
                (append (list :path path :modified_date 1) (cdr f)))))
           files ",")
          "]"))

(ert-deftest zr-czkawka-test-image-render-and-flag ()
  "Similar images show their details and keep the highest resolution."
  (let* ((dir (make-temp-file "zr-czkawka-test-image" t))
         (json (format "[%s,[%s,%s]]"
                       (zr-czkawka-test--json-files
                        dir '("a.png" :size 3 :width 640 :height 480 :difference 0)
                        '("b.jpg" :size 5 :width 320 :height 240 :difference 4))
                       ;; A reference file is followed by its similar files.
                       (substring
                        (zr-czkawka-test--json-files
                         dir '("ref.png" :size 2 :width 100 :height 100 :difference 0))
                        1 -1)
                       (zr-czkawka-test--json-files
                        dir '("c.png" :size 9 :width 10 :height 10 :difference 2))))
         (groups (zr-czkawka--parse-groups
                  (json-parse-string json :object-type 'alist :array-type 'list))))
    (unwind-protect
        (zr-czkawka-test--with-tool-buffer (zr-czkawka-image-tool groups dir)
          (should (equal (mapcar #'zr-czkawka-test--paths groups)
                         (list (list (expand-file-name "a.png" dir)
                                     (expand-file-name "b.jpg" dir))
                               (list (expand-file-name "ref.png" dir)
                                     (expand-file-name "c.png" dir)))))
          (should (equal (zr-czkawka-test--annotations)
                         '("640x480, difference 0" "320x240, difference 4"
                           "100x100, difference 0" "10x10, difference 2")))
          (should (string-prefix-p " Czkawka Similar images: 2 groups, 4 files (12B wasted)"
                                   header-line-format))
          (should (eq (key-binding (kbd "% p"))
                      #'zr-czkawka-flag-all-except-highest-resolution))
          (should (eq (key-binding (kbd "% n")) #'zr-czkawka-flag-all-except-newest))
          (zr-czkawka-flag-all-except-highest-resolution)
          (should (equal (zr-czkawka-test--flagged)
                         (list (expand-file-name "b.jpg" dir))))
          ;; Details go away with their line.
          (dired-goto-file (expand-file-name "b.jpg" dir))
          (dired-kill-line)
          (should (equal (length (zr-czkawka-test--annotations)) 3)))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-image-build-args ()
  "Test CLI arguments of czkawka image."
  (let ((zr-czkawka-image-hash-size 8)
        (zr-czkawka-image-hash-alg "Mean")
        (zr-czkawka-image-min-file-size 1))
    (should (equal (zr-czkawka-image--build-args '("/tmp/a") 3)
                   (list "-d" (expand-file-name "/tmp/a") "-s" "3"
                         "-c" "8" "-g" "Mean" "-m" "1")))))

(ert-deftest zr-czkawka-test-image-cli ()
  "czkawka image finds a resized copy of an image."
  (zr-czkawka-test--skip-unless-cli)
  (skip-unless (executable-find "ffmpeg"))
  (let ((dir (make-temp-file "zr-czkawka-test-image" t)))
    (unwind-protect
        (let ((a (expand-file-name "a.png" dir))
              (b (expand-file-name "b.jpg" dir)))
          (zr-czkawka-test--ffmpeg "-f" "lavfi" "-i" "testsrc=size=640x480"
                                   "-frames:v" "1" a)
          (zr-czkawka-test--ffmpeg "-i" a "-q:v" "5" b)
          (let* ((zr-czkawka-image-min-file-size 1)
                 (groups (zr-czkawka-test--run
                          zr-czkawka-image-tool
                          (zr-czkawka-image--build-args (list dir) 5))))
            (should (= (length groups) 1))
            (should (equal (sort (zr-czkawka-test--paths (car groups)) #'string<)
                           (list a b)))
            (should (member "640x480"
                            (mapcar (lambda (f) (car (split-string
                                                      (zr-czkawka-image--annotate f)
                                                      ",")))
                                    (alist-get 'files (car groups)))))))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-music-annotate ()
  "Music details skip empty tags."
  (should (equal (zr-czkawka-music--annotate
                  '((track_title . "Song") (track_artist . "Me") (year . "2020")
                    (genre . "") (length . 200) (bitrate . 320)))
                 "Song - Me, 2020, 3:20, 320 kbps"))
  (should (equal (zr-czkawka-music--annotate
                  '((track_title . "") (track_artist . "Me") (length . 0)))
                 "? - Me"))
  (should (equal (zr-czkawka-music--annotate '((track_title . "") (bitrate . 0)))
                 "")))

(ert-deftest zr-czkawka-test-music-parse-drops-fingerprints ()
  "Audio fingerprints are not kept in the results."
  (let ((groups (zr-czkawka-music--parse-json
                 (json-parse-string
                  "[[{\"path\":\"/a\",\"fingerprint\":[1,2]},{\"path\":\"/b\",\"fingerprint\":[3]}]]"
                  :object-type 'alist :array-type 'list))))
    (should (equal groups '(((id . 1) (files ((path . "/a")) ((path . "/b")))))))))

(ert-deftest zr-czkawka-test-music-build-args ()
  "Test CLI arguments of czkawka music."
  (let ((zr-czkawka-music-similarity '("track_title" "year"))
        (zr-czkawka-music-approximate t)
        (zr-czkawka-music-min-file-size 1))
    (should (equal (zr-czkawka-music--build-args '("/tmp/a") "TAGS")
                   (list "-d" (expand-file-name "/tmp/a") "-s" "TAGS"
                         "-z" "track_title,year" "-a" "-m" "1")))))

(ert-deftest zr-czkawka-test-music-cli ()
  "czkawka music finds files with the same title and artist."
  (zr-czkawka-test--skip-unless-cli)
  (skip-unless (executable-find "ffmpeg"))
  (let ((dir (make-temp-file "zr-czkawka-test-music" t)))
    (unwind-protect
        (let ((files (mapcar (lambda (n) (expand-file-name n dir))
                             '("a.mp3" "b.mp3" "c.mp3"))))
          (cl-mapc (lambda (file title)
                     (zr-czkawka-test--ffmpeg
                      "-f" "lavfi" "-i" "sine=frequency=440:duration=20"
                      "-b:a" "64k" "-metadata" (concat "title=" title)
                      "-metadata" "artist=Me" file))
                   files '("Song" "Song" "Other"))
          (let* ((zr-czkawka-music-min-file-size 1)
                 (groups (zr-czkawka-test--run
                          zr-czkawka-music-tool
                          (zr-czkawka-music--build-args (list dir) "TAGS"))))
            (should (= (length groups) 1))
            (should (equal (sort (zr-czkawka-test--paths (car groups)) #'string<)
                           (list (nth 0 files) (nth 1 files))))
            (zr-czkawka-test--with-tool-buffer (zr-czkawka-music-tool groups dir)
              (should (equal (zr-czkawka-test--annotations)
                             (make-list 2 "Song - Me, 0:20, 64 kbps")))
              (should (string-prefix-p " Czkawka Same music: 1 groups, 2 files"
                                       header-line-format)))))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-video-annotate ()
  "Video details, or the error of czkawka."
  (should (equal (zr-czkawka-video--annotate
                  '((width . 1920) (height . 1080) (codec . "h264") (duration . 3725.4)
                    (bitrate . 26282) (fps . 29.97) (error . "")))
                 "1920x1080, h264, 1:02:05, 26 kbps, 29.97 fps"))
  (should (equal (zr-czkawka-video--annotate
                  '((width . 320) (height . 240) (codec . "") (duration . 40.0)
                    (bitrate . 0) (fps . 10.0)))
                 "320x240, 0:40, 10 fps"))
  (should (equal (zr-czkawka-video--annotate '((error . "Broken file")))
                 "Broken file")))

(ert-deftest zr-czkawka-test-video-build-args ()
  "Test CLI arguments of czkawka video."
  (let ((zr-czkawka-video-skip-forward 0)
        (zr-czkawka-video-min-file-size 1))
    (should (equal (zr-czkawka-video--build-args '("/tmp/a") 5)
                   (list "-d" (expand-file-name "/tmp/a") "-t" "5"
                         "-U" "0" "-m" "1")))))

(ert-deftest zr-czkawka-test-video-cli ()
  "czkawka video finds a resized copy of a video."
  (zr-czkawka-test--skip-unless-cli)
  (skip-unless (executable-find "ffmpeg"))
  (let ((dir (make-temp-file "zr-czkawka-test-video" t)))
    (unwind-protect
        (let ((a (expand-file-name "a.mp4" dir))
              (b (expand-file-name "b.mp4" dir)))
          (zr-czkawka-test--ffmpeg "-f" "lavfi" "-i" "testsrc=size=320x240:duration=30:rate=10"
                                   "-pix_fmt" "yuv420p" a)
          (zr-czkawka-test--ffmpeg "-i" a "-vf" "scale=160:120" b)
          (let* ((zr-czkawka-video-skip-forward 0)
                 (zr-czkawka-video-min-file-size 1)
                 (groups (zr-czkawka-test--run
                          zr-czkawka-video-tool
                          (zr-czkawka-video--build-args (list dir) 10))))
            (should (= (length groups) 1))
            (should (equal (sort (zr-czkawka-test--paths (car groups)) #'string<)
                           (list a b)))
            (should-not (assq 'vhash (car (alist-get 'files (car groups)))))
            (zr-czkawka-test--with-tool-buffer (zr-czkawka-video-tool groups dir)
              (should (equal (mapcar (lambda (s) (car (split-string s ",")))
                                     (zr-czkawka-test--annotations))
                             '("320x240" "160x120")))
              (zr-czkawka-flag-all-except-highest-resolution)
              (should (equal (zr-czkawka-test--flagged) (list b))))))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-replace-directories ()
  "Fixing scans the marked files instead of the directories."
  (should (equal (zr-czkawka--replace-directories
                  '("-d" "/a" "-e" "/x" "--directories" "/b" "--directories=/c"
                    "transcode" "-c" "h265")
                  '("/f/1.mp4" "/f/2.mp4"))
                 '("-d" "/f/1.mp4" "-d" "/f/2.mp4" "-e" "/x" "transcode" "-c" "h265"))))

(ert-deftest zr-czkawka-test-video-optimizer-annotate ()
  "Videos to crop show the area they are cropped to."
  (should (equal (zr-czkawka-video-optimizer--annotate
                  '((width . 320) (height . 400) (codec . "h264") (duration . 5.0)
                    (new_image_dimensions 21 80 320 320) (error)))
                 "320x400, h264, 0:05, crop to 299x240+21+80"))
  (should (equal (zr-czkawka-video-optimizer--annotate
                  '((width . 320) (height . 240) (codec . "h264") (duration . 40.0)))
                 "320x240, h264, 0:40")))

(ert-deftest zr-czkawka-test-video-optimizer-build-args ()
  "Test CLI arguments of czkawka video-optimizer."
  (let ((zr-czkawka-video-optimizer-excluded-codecs '("h265" "av1"))
        (zr-czkawka-video-optimizer-target-codec "av1")
        (zr-czkawka-video-optimizer-quality 30)
        (zr-czkawka-video-optimizer-fail-if-not-smaller t)
        (zr-czkawka-video-optimizer-overwrite-original t)
        (dir (expand-file-name "/tmp/a")))
    (should (equal (zr-czkawka-video-optimizer--build-args '("/tmp/a") "transcode")
                   (list "-d" dir "transcode" "-c" "h265,av1" "--target-codec" "av1"
                         "--quality" "30" "--fail-if-not-smaller"
                         "--overwrite-original")))
    (should (equal (zr-czkawka-video-optimizer--build-args '("/tmp/a") "crop")
                   (list "-d" dir "crop" "--target-codec" "av1" "--quality" "30"
                         "--overwrite-original")))))

(ert-deftest zr-czkawka-test-video-optimizer-crop-and-fix ()
  "Videos with black bars are listed, and fixing crops the marked ones."
  (zr-czkawka-test--skip-unless-cli)
  (skip-unless (executable-find "ffmpeg"))
  (let ((dir (make-temp-file "zr-czkawka-test-vo" t)))
    (unwind-protect
        (let ((a (expand-file-name "a.mp4" dir))
              (b (expand-file-name "b.mp4" dir))
              (zr-czkawka-video-optimizer-overwrite-original nil))
          (zr-czkawka-test--ffmpeg "-f" "lavfi" "-i" "testsrc=size=320x240:duration=5:rate=10"
                                   "-vf" "pad=320:400:0:80" "-pix_fmt" "yuv420p" a)
          (zr-czkawka-test--ffmpeg "-f" "lavfi" "-i" "testsrc=size=320x240:duration=5:rate=10"
                                   "-pix_fmt" "yuv420p" b)
          (let* ((args (zr-czkawka-video-optimizer--build-args (list dir) "crop"))
                 (groups (zr-czkawka-test--run zr-czkawka-video-optimizer-tool args))
                 rescanned)
            (should (equal (zr-czkawka-test--paths (car groups)) (list a)))
            (should (string-match-p "\\`320x400, h264, 0:05, crop to [0-9]+x240\\+[0-9]+\\+80\\'"
                                    (zr-czkawka-video-optimizer--annotate
                                     (car (alist-get 'files (car groups))))))
            (zr-czkawka-test--with-tool-buffer (zr-czkawka-video-optimizer-tool groups dir)
              (setq zr-czkawka--params (list :directory dir :args args))
              (should (eq (key-binding (kbd "C-c C-c")) #'zr-czkawka-fix))
              (should-not (key-binding (kbd "% n")))
              (dired-goto-file a)
              (cl-letf (((symbol-function 'y-or-n-p) #'always)
                        ((symbol-function 'zr-czkawka--scan)
                         (lambda (_tool scan-args &rest _) (setq rescanned scan-args))))
                (zr-czkawka-fix)
                (with-timeout (120 (error "Timed out"))
                  (while (not rescanned) (accept-process-output nil 0.1))))
              (should (equal rescanned args))
              (should (directory-files dir nil "\\`a\\..*crop.*\\.mp4\\'")))))
      (delete-directory dir t))))

(ert-deftest zr-czkawka-test-fix-unsupported ()
  "Tools that cannot fix files say so."
  (zr-czkawka-test--with-dup-buffer
      (fs (list (zr-czkawka-test--group 1 (list (nth 0 fs) 1) (list (nth 1 fs) 2))))
    (should-error (zr-czkawka-fix) :type 'user-error)))

(defun zr-czkawka-test--bytes (n count &optional big-endian)
  "Return integer N as a unibyte string of COUNT bytes.
Bytes are little-endian unless BIG-ENDIAN is non-nil."
  (let ((bytes (cl-loop for i below count
                        collect (logand (ash n (* -8 i)) 255))))
    (apply #'unibyte-string (if big-endian (nreverse bytes) bytes))))

(defun zr-czkawka-test--add-exif (jpeg)
  "Insert an EXIF segment with the Make and Software tags into JPEG."
  (let* ((make "TestCam\0")
         (software "zr-test\0")
         ;; Header, entry count, 2 entries and the next IFD offset.
         (data-offset (+ 8 2 (* 2 12) 4))
         (tiff (concat "II*\0" (zr-czkawka-test--bytes 8 4)
                       (zr-czkawka-test--bytes 2 2)
                       (zr-czkawka-test--bytes #x010f 2) (zr-czkawka-test--bytes 2 2)
                       (zr-czkawka-test--bytes (length make) 4)
                       (zr-czkawka-test--bytes data-offset 4)
                       (zr-czkawka-test--bytes #x0131 2) (zr-czkawka-test--bytes 2 2)
                       (zr-czkawka-test--bytes (length software) 4)
                       (zr-czkawka-test--bytes (+ data-offset (length make)) 4)
                       (zr-czkawka-test--bytes 0 4)
                       make software))
         (app1 (concat "Exif\0\0" tiff)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally jpeg)
      ;; Right after the start of image marker.
      (goto-char 3)
      (insert (unibyte-string #xff #xe1)
              (zr-czkawka-test--bytes (+ 2 (length app1)) 2 t)
              app1)
      (let ((coding-system-for-write 'no-conversion))
        (write-region nil nil jpeg nil 'silent)))))

(ert-deftest zr-czkawka-test-exif-remover-annotate ()
  "Images show their EXIF tags, or the error of czkawka."
  (should (equal (zr-czkawka-exif-remover--annotate
                  '((exif_tags ((name . "Make") (code . 271))
                               ((name . "Software") (code . 305)))
                    (error)))
                 "2 tag(s): Make, Software"))
  (should (equal (zr-czkawka-exif-remover--annotate '((error . "Bad image")))
                 "Bad image")))

(ert-deftest zr-czkawka-test-exif-remover-build-args ()
  "Test CLI arguments of czkawka exif-remover."
  (let ((zr-czkawka-exif-remover-ignored-tags '("Orientation" "DateTime"))
        (zr-czkawka-exif-remover-override t))
    (should (equal (zr-czkawka-exif-remover--build-args '("/tmp/a"))
                   (list "-d" (expand-file-name "/tmp/a")
                         "-i" "Orientation,DateTime" "-o")))))

(ert-deftest zr-czkawka-test-exif-remover-cli ()
  "Images with EXIF tags are listed, and fixing removes their tags."
  (zr-czkawka-test--skip-unless-cli)
  (skip-unless (executable-find "ffmpeg"))
  (let ((dir (make-temp-file "zr-czkawka-test-exif" t)))
    (unwind-protect
        (let ((a (expand-file-name "a.jpg" dir))
              (b (expand-file-name "b.jpg" dir))
              (c (expand-file-name "c.jpg" dir))
              (zr-czkawka-exif-remover-override t))
          (zr-czkawka-test--ffmpeg "-f" "lavfi" "-i" "testsrc=size=64x64"
                                   "-frames:v" "1" a)
          (copy-file a b)
          (copy-file a c)
          (zr-czkawka-test--add-exif a)
          (zr-czkawka-test--add-exif b)
          (let* ((args (zr-czkawka-exif-remover--build-args (list dir)))
                 (groups (zr-czkawka-test--run zr-czkawka-exif-remover-tool args))
                 rescanned)
            (should (equal (sort (zr-czkawka-test--paths (car groups)) #'string<)
                           (list a b)))
            (zr-czkawka-test--with-tool-buffer (zr-czkawka-exif-remover-tool groups dir)
              (setq zr-czkawka--params (list :directory dir :args args))
              (should (equal (zr-czkawka-test--annotations)
                             (make-list 2 "2 tag(s): Make, Software")))
              (should (string-prefix-p " Czkawka Images with EXIF: 2 files"
                                       header-line-format))
              (dired-goto-file a)
              (cl-letf (((symbol-function 'y-or-n-p) #'always)
                        ((symbol-function 'zr-czkawka--scan)
                         (lambda (&rest _) (setq rescanned t))))
                (zr-czkawka-fix)
                (with-timeout (120 (error "Timed out"))
                  (while (not rescanned) (accept-process-output nil 0.1)))))
            ;; Only the marked image was cleaned, in place.
            (should (equal (zr-czkawka-test--paths
                            (car (zr-czkawka-test--run zr-czkawka-exif-remover-tool args)))
                           (list b)))
            (should (equal (directory-files dir nil "\\.jpg\\'")
                           '("a.jpg" "b.jpg" "c.jpg")))))
      (delete-directory dir t))))

(provide 'zr-czkawka-test)

;;; zr-czkawka-test.el ends here
