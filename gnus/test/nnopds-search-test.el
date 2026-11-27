;;; nnopds-search-test.el --- Cached EPUB search tests -*- lexical-binding: t; -*-

;;; Code:

(require 'nnopds-test-helpers
         (expand-file-name "nnopds-test-helpers.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'nnopds-search)

(defun nnopds-search-test--specs (query &optional groups options)
  "Build Gnus search specs for QUERY in fixture GROUPS with OPTIONS."
  (list (cons 'search-query-spec (cons (cons 'query query) options))
        (cons 'search-group-spec (list (cons "nnopds:library" groups)))))

(defun nnopds-search-test--query (query &optional groups options)
  "Search the fixture with QUERY, GROUPS and OPTIONS through Gnus."
  (gnus-search-run-query (nnopds-search-test--specs query groups options)))

(ert-deftest nnopds-search-test-cached-books-scope-and-limits ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (let* ((gnus-search-use-parsed-queries nil)
             (gnus-search-engine-instance-alist nil)
             (publication (nnopds-test--publication connection))
             (group (nnopds--publication-group publication))
             (full-group (gnus-group-full-name group '(nnopds "library")))
             (book (nnopds--publication-data publication)))
        (nnopds--catalog-page connection (nnopds--url "/books?page=2" opds-url))
        (let* ((other (cadr (nnopds--connection-catalog connection)))
               (requests (nnopds-test--requests opds-root)))
          (cl-letf (((symbol-function 'nnopds--request)
                     (lambda (&rest _args) (ert-fail "Search attempted HTTP"))))
            (should (object-of-class-p (gnus-search-server-to-engine "nnopds:library") 'gnus-search-nnopds))
            (should (equal (nnopds-search-test--query "中文内容 α") (vector (vector full-group 1 0))))
            (should (equal (nnopds-search-test--query "脚注目标" (list group full-group))
                           (vector (vector full-group 2 0))))
            (should (equal (nnopds-search-test--query "中文内容 α" (list other)) []))
            (should (equal (nnopds-search-test--query "absent") []))
            (should (equal (nnopds-search-test--query "正文" nil '((limit . 1)))
                           (vector (vector full-group 1 0))))
            (should (equal (nnopds-search-test--query "正文" nil '((limit . 0))) []))
            (let ((gnus-search-ignored-newsgroups (regexp-quote group)))
              (should (equal (nnopds-search-test--query "中文内容 α") []))
              (should (= 1 (length (nnopds-search-test--query "中文内容 α" (list full-group)))))))
          (should (equal requests (nnopds-test--requests opds-root)))
          (should-not (nnopds--publication-data (gethash other (nnopds--connection-publications connection))))
          (should (eq book (nnopds--publication-data publication)))
          (should (file-directory-p (zr-epub-book-root book)))
          (should-not (nnopds--connection-readers connection)))))))

(ert-deftest nnopds-search-test-reopened-cache-and-temporary-extraction-cleanup ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (let* ((gnus-search-use-parsed-queries nil)
             (gnus-search-engine-instance-alist nil)
             (publication (nnopds-test--publication connection))
             (group (nnopds--publication-group publication))
             (full-group (gnus-group-full-name group '(nnopds "library"))) other other-full-group)
        (nnopds--catalog-page connection (nnopds--url "/books?page=2" opds-url))
        (setq other (cadr (nnopds--connection-catalog connection))
              other-full-group (gnus-group-full-name other '(nnopds "library")))
        (nnopds--get-publication other "library" t)
        (nnopds-close-server "library")
        (should (nnopds-open-server "library" (cddr (car gnus-secondary-select-methods))))
        (setq connection nnopds--connection)
        (let ((open-book (symbol-function 'zr-epub-open))
              (requests (nnopds-test--requests opds-root)) roots)
          (cl-letf (((symbol-function 'nnopds--request)
                     (lambda (&rest _args) (ert-fail "Offline search attempted HTTP")))
                    ((symbol-function 'zr-epub-open)
                     (lambda (file)
                       (let ((book (funcall open-book file)))
                         (push (zr-epub-book-root book) roots)
                         book))))
            (let ((results (nnopds-search-test--query "脚注目标")))
              (should (= 2 (length results)))
              (should (seq-contains-p results (vector full-group 2 0) #'equal))
              (should (seq-contains-p results (vector other-full-group 2 0) #'equal)))
            (should (equal (nnopds-search-test--query "脚注目标" (list other))
                           (vector (vector other-full-group 2 0))))
            (should roots)
            (should (cl-every (lambda (root) (not (file-exists-p root))) roots))
            (setq roots nil)
            (should (equal (nnopds-search-test--query "正文" nil '((limit . 0))) []))
            (should-not roots)
            (should (= 1 (length (nnopds-search-test--query "正文" nil '((limit . 1))))))
            (should (cl-every (lambda (root) (not (file-exists-p root))) roots))
            (setq roots nil)
            (cl-letf (((symbol-function 'nnopds-search--chapter-text)
                       (lambda (_chapter) (error "Chapter read failed"))))
              (should-error (nnopds-search-test--query "正文")))
            (should roots)
            (should (cl-every (lambda (root) (not (file-exists-p root))) roots))
            (setq roots nil)
            (cl-letf (((symbol-function 'nnopds-search--chapter-text)
                       (lambda (_chapter) (signal 'quit nil))))
              (should (eq (condition-case nil (nnopds-search-test--query "正文") (quit 'quit)) 'quit)))
            (should roots)
            (should (cl-every (lambda (root) (not (file-exists-p root))) roots)))
          (should (equal requests (nnopds-test--requests opds-root)))
          (should-not (nnopds--publication-data (gethash group (nnopds--connection-publications connection))))
          (should-not (nnopds--publication-data (gethash other (nnopds--connection-publications connection))))
          (should-not (nnopds--connection-readers connection)))))))

(ert-deftest nnopds-search-test-text-rendering-and-parsed-queries ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (let* ((gnus-search-use-parsed-queries t)
             (gnus-search-engine-instance-alist nil)
             (publication (nnopds-test--publication connection))
             (group (nnopds--publication-group publication))
             (book (nnopds--publication-data publication))
             (chapter (zr-epub-chapter book 1)))
        (with-temp-file (plist-get chapter :path)
          (insert "<html><head><title>HiddenTitle</title><style>HiddenCSS</style></head><body>"
                  "<h1>第一章正文</h1><p>中<span>文</span>内容&nbsp;α &amp; β</p>"
                  "<p>EnglishMiXeD [brackets]</p><script>HiddenScript</script>"
                  "<a href='https://example.invalid/HiddenAttribute'>下一章</a>"
                  "<img src='https://example.invalid/photo.png' alt='图示'/></body></html>"))
        (cl-letf (((symbol-function 'nnopds--request)
                   (lambda (&rest _args) (ert-fail "Search attempted HTTP")))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _args) (ert-fail "Search fetched an HTML resource")))
                  ((symbol-function 'url-queue-retrieve)
                   (lambda (&rest _args) (ert-fail "Search queued an HTML resource"))))
          (dolist (case '(("body:中文 subject:第一章" 1)
                          ("body:\"中文内容 α & β\"" 1)
                          ("body:/中.*α/" 1)
                          ("englishmixed" 1)
                          ("subject:第二章 or body:附录正文" 2 3)
                          ("(subject:第一章 or subject:第二章) not body:中文" 2)
                          ("from:作者甲 body:脚注目标" 2)
                          ("sender:作者乙 body:附录正文" 3)
                          ("-body:中文" 2 3 4)))
            (should (equal (seq-map (lambda (result) (aref result 1))
                                   (nnopds-search-test--query (car case) (list group)))
                           (cdr case))))
          (let ((id (mail-header-id (nnopds--header 'epub book (zr-epub-chapter book 2) group))))
            (should (= 2 (aref (aref (nnopds-search-test--query (concat "id:\"" id "\"")) 0) 1))))
          (dolist (term '("HiddenTitle" "HiddenCSS" "HiddenScript" "HiddenAttribute"))
            (should (equal (nnopds-search-test--query term) [])))
          (let ((gnus-search-use-parsed-queries nil))
            (should (= 1 (length (nnopds-search-test--query "中文内容 α & β"))))
            (should (= 1 (length (nnopds-search-test--query "[brackets]"))))
            (should (equal (nnopds-search-test--query "body:中文") [])))
          (should (equal (nnopds-search-test--query "body:中文" nil '((raw . t))) []))
          (should (file-directory-p (zr-epub-book-root book))))))))

(ert-deftest nnopds-search-test-invalid-queries-fail-before-reading-books ()
  (let ((gnus-search-use-parsed-queries t))
    (cl-letf (((symbol-function 'nnopds-search--cached-book)
               (lambda (&rest _args) (ert-fail "Invalid query opened a book")))
              ((symbol-function 'gnus-check-server)
               (lambda (&rest _args) (ert-fail "Invalid query checked a server"))))
      (dolist (query '("" " \t " "to:someone" "mark:read" "body:/[/" "中文 or to:someone" "grep:正文"))
        (should-error (gnus-search-run-search
                       (gnus-search-nnopds) "nnopds:library"
                       (gnus-search-prepare-query (list (cons 'query query))) nil)
                      :type 'user-error)))))

(ert-deftest nnopds-search-test-rejects-changed-cached-edition ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (let* ((gnus-search-use-parsed-queries nil)
             (publication (nnopds-test--publication connection))
             (group (nnopds--publication-group publication))
             (file (zr-epub-book-file (nnopds--publication-data publication))))
        (nnopds-close-server "library")
        (should (nnopds-open-server "library" (cddr (car gnus-secondary-select-methods))))
        (setq connection nnopds--connection)
        (let ((coding-system-for-write 'no-conversion))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            (goto-char (point-max)) (insert "changed")
            (write-region (point-min) (point-max) file nil 'silent)))
        (cl-letf (((symbol-function 'nnopds--request)
                   (lambda (&rest _args) (ert-fail "Changed cache attempted HTTP"))))
          (should (string-match-p "EPUB content changed"
                                   (error-message-string
                                    (should-error (nnopds-search-test--query "正文" (list group)))))))))))

(ert-deftest nnopds-search-test-skips-pdf-and-comic-publications ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (nnopds-test--write opds-root "comic-catalog.txt" "komga")
      (nnopds-refresh-catalog "library")
      (nnopds-test--write opds-root "pdf-catalog.txt" "enabled")
      (nnopds-refresh-catalog "library")
      (let ((gnus-search-use-parsed-queries nil))
        (cl-letf (((symbol-function 'nnopds--request)
                   (lambda (&rest _args) (ert-fail "Search attempted a publication download")))
                  ((symbol-function 'nnopds--load-publication)
                   (lambda (&rest _args) (ert-fail "Search loaded a reading format"))))
          (should (equal (nnopds-search-test--query "正文") [])))))))

(ert-deftest nnopds-search-test-nnselect-result-opens-and-warps-to-original-chapter ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (let* ((gnus-search-use-parsed-queries nil)
             (gnus-search-engine-instance-alist nil)
             (publication (nnopds-test--publication connection))
             (group (nnopds--publication-group publication))
             (full-group (gnus-group-full-name group '(nnopds "library")))
             (requests (nnopds-test--requests opds-root)) search-buffer)
        (unwind-protect
            (progn
              (should (gnus-group-read-ephemeral-search-group
                       nil (nnopds-search-test--specs "脚注目标" (list full-group))))
              (setq search-buffer (get-buffer gnus-summary-buffer))
              (with-current-buffer search-buffer
                (should (gnus-nnselect-group-p gnus-newsgroup-name))
                (should (equal (mapcar #'mail-header-subject gnus-newsgroup-headers) '("第二章")))
                (should (= 2 (nnselect-article-number 1)))
                (gnus-summary-display-article 1)
                (with-current-buffer gnus-article-buffer
                  (should (string-search "脚注目标" (buffer-string))))
                (gnus-warp-to-article))
              (with-current-buffer gnus-summary-buffer
                (should (equal gnus-newsgroup-name full-group))
                (should (= 2 (gnus-summary-article-number)))
                (gnus-summary-exit))
              (should (equal requests (nnopds-test--requests opds-root))))
          (when (buffer-live-p search-buffer)
            (with-current-buffer search-buffer (gnus-summary-exit))))))))

(provide 'nnopds-search-test)
;;; nnopds-search-test.el ends here
