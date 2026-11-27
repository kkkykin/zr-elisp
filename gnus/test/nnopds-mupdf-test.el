;;; nnopds-mupdf-test.el --- Downloaded PDF reader tests -*- lexical-binding: t; -*-

;;; Code:

(require 'nnopds-paged-test-helpers
         (expand-file-name "nnopds-paged-test-helpers.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'nnopds-mupdf)

(defmacro nnopds-mupdf-test--with-server (&rest body)
  "Run BODY with a real PDF catalog and installed MuPDF."
  (declare (indent 0) (debug t))
  `(nnopds-test--with-server
    (skip-unless (executable-find nnopds-mupdf-program))
    (let ((zr-doc-view-visible-pages 1) (zr-doc-view-direction 'auto)
          (zr-doc-view-landscape-single nil)
          (nnopds-paged-prefetch-pages 0) (nnopds-paged-max-requests 2))
      (nnopds-test--write opds-root "pdf-catalog.txt" "enabled")
      ,@body)))

(defun nnopds-mupdf-test--publication (connection)
  "Return the fixture PDF publication without downloading it."
  (nnopds--catalog-page connection (nnopds--connection-url connection))
  (gethash (car (nnopds--connection-catalog connection))
           (nnopds--connection-publications connection)))

(defun nnopds-mupdf-test--wrapper (root)
  "Create a MuPDF wrapper in ROOT with controllable render errors and delays."
  (let ((program (expand-file-name "mutool-test.py" root))
        (mutool (nnopds-mupdf--program)))
    (nnopds-test--write
     root "mutool-test.py"
     (format "#!/usr/bin/env python3
import os, pathlib, sys, time
root = pathlib.Path(%s)
if sys.argv[1] == 'draw':
    if (root / 'render-failure.txt').exists():
        print('fixture render failure', file=sys.stderr)
        sys.exit(9)
    if (root / 'render-delay.txt').exists():
        time.sleep(float((root / 'render-delay.txt').read_text()))
os.execv(%s, [%s] + sys.argv[1:])
" (json-serialize root) (json-serialize mutool) (json-serialize mutool)))
    (set-file-modes program #o755)
    program))

(ert-deftest nnopds-mupdf-test-missing-mutool-is-reported ()
  (let ((nnopds-mupdf-program "nnopds-missing-mutool"))
    (should-error (nnopds-mupdf--program))))

(ert-deftest nnopds-mupdf-test-catalog-is-lazy-and-effective-bounds-are-correct ()
  (nnopds-mupdf-test--with-server
   (let* ((publication (nnopds-mupdf-test--publication connection))
          (group (nnopds--publication-group publication)))
     (should (eq (nnopds--publication-format publication) 'pdf))
     (should-not (nnopds--publication-data publication))
     (should (= 1 (length (nnopds-test--requests opds-root))))
     (nnopds-test--write opds-root "download-media-type.txt" "application/octet-stream")
     (should (nnopds-request-group group "library"))
     (let* ((book (nnopds--publication-data publication))
            (pages (nnopds--chapters 'pdf book))
            (data (nnopds-paged--book-source-data book))
            (file (plist-get data :file)))
       (should (= 7 (length pages)))
       (should (equal (mapcar (lambda (page) (cons (plist-get page :width) (plist-get page :height)))
                              (seq-take pages 4))
                      '((200 . 300) (260 . 180) (400 . 600) (400 . 200))))
       (should (equal (nnopds--read-bytes file)
                      (nnopds--read-bytes (expand-file-name "book.pdf" opds-root))))
       (should (equal (plist-get data :digest) (nnopds-mupdf--pdf-fingerprint file)))
       (should (= 7 (nnopds--publication-count publication)))
       (should (eq 'nov (nnopds-retrieve-headers '(1 2 3) group "library")))
       (should (nnopds-request-article 3 group "library"))
       (should (equal (nnopds--locate 'pdf book (nnopds--locator 'pdf book (aref pages 2))) '(3)))
       (should (= 1.0 (plist-get (plist-get (nnopds--locator 'pdf book (aref pages 6)) :locations)
                                 :totalProgression)))
       (should-not (nnopds--publication-progress publication))
       (should-not (directory-files (nnopds-paged--book-directory book) nil "\\.png$"))
       (should (zerop (hash-table-count (nnopds-paged--book-active book))))
       (should (= 1 (cl-count "/content/book.pdf" (nnopds-test--requests opds-root)
                              :key (lambda (request) (plist-get request :path)) :test #'equal)))))))

(ert-deftest nnopds-mupdf-test-reader-shares-screen-arrow-and-resolution-behavior ()
  (nnopds-mupdf-test--with-server
   (nnopds-paged-test--with-images
    (nnopds-test--with-browser
     (nnopds-test--at-book)
     (nnopds-browse-select)
     (with-current-buffer gnus-summary-buffer
       (gnus-summary-display-article (gnus-summary-article-number))
       (let* ((reader nnopds-paged--reader)
              (book (nnopds-paged--reader-book reader))
              (directory (nnopds-paged--book-directory book)))
         (nnopds-paged-test--settled reader 1)
         (should (equal (nnopds-paged-test--shown) '(1)))
         (should-not (nnopds-paged--book-cover book))
         (should-not (nnopds-paged--book-landscape book))
         (nnopds-paged-set-visible-pages 3)
         (nnopds-paged-test--settled reader 1)
         (should (equal (nnopds-paged-test--shown) '(1 2 3)))
         (should-not (cl-intersection '(1 2 3) gnus-newsgroup-unreads))
         (should (cl-every (lambda (number) (memq number gnus-newsgroup-unreads)) '(4 5 6 7)))
         (should-not (directory-files directory nil "^4-[0-9]+\\.png$"))
         (nnopds-paged-next)
         (nnopds-paged-test--settled reader 4)
         (should (equal (nnopds-paged-test--shown) '(4 5 6)))
         (nnopds-paged-left)
         (nnopds-paged-test--settled reader 3)
         (should (equal (nnopds-paged-test--shown) '(3 4 5)))
         (nnopds-paged-right)
         (nnopds-paged-test--settled reader 4)
         (nnopds-paged-set-direction 'rtl)
         (should (equal (nnopds-paged-test--shown) '(6 5 4)))
         (nnopds-paged-right)
         (nnopds-paged-test--settled reader 3)
         (should (equal (nnopds-paged-test--shown) '(5 4 3)))
         (nnopds-paged-next)
         (nnopds-paged-test--settled reader 6)
         (should (equal (nnopds-paged-test--shown) '(7 6)))
         (nnopds-paged-previous)
         (nnopds-paged-test--settled reader 3)
         (nnopds-paged-goto-page 7)
         (nnopds-paged-test--settled reader 7)
         (should (equal (nnopds-paged-test--shown) '(7)))
         (let* ((page (nnopds-paged--page book 7))
                (old-width (cdar (nnopds-paged--targets reader)))
                (old-file (nnopds-paged--file 'mupdf book page old-width)))
           (should (file-readable-p old-file))
           (cl-letf (((symbol-function 'nnopds-paged--viewport) (lambda () '(1800 . 2600))))
             (nnopds-paged--update reader)
             (nnopds-paged-test--settled reader 7)
             (let ((new-file (nnopds-paged--file 'mupdf book page (cdar (nnopds-paged--targets reader)))))
               (should-not (equal new-file old-file))
               (should (file-readable-p old-file))
               (should (file-readable-p new-file))
               (should (= 2048 (car (image-size (create-image new-file 'png) t))))
               (should (= (nnopds-paged--book-position book) 7)))))
         (should (= 1 (cl-count "/content/book.pdf" (nnopds-test--requests opds-root)
                                :key (lambda (request) (plist-get request :path)) :test #'equal)))
         (gnus-summary-exit)))))))

(ert-deftest nnopds-mupdf-test-reopen-restores-local-settings-without-http-or-inspection ()
  (nnopds-mupdf-test--with-server
   (nnopds-paged-test--with-images
    (nnopds-test--with-browser
     (nnopds-test--at-book)
     (nnopds-browse-select)
     (with-current-buffer gnus-summary-buffer
       (gnus-summary-display-article (gnus-summary-article-number))
       (let ((reader nnopds-paged--reader))
         (nnopds-paged-test--settled reader 1)
         (nnopds-paged-double-page)
         (nnopds-paged-goto-page 5)
         (nnopds-paged-test--settled reader 5)
         (nnopds-paged-toggle-cover)
         (nnopds-paged-set-direction 'rtl)
         (gnus-summary-exit))))
    (nnopds-test--write opds-root "requests.jsonl" "")
    (cl-letf (((symbol-function 'nnopds-mupdf--inspect)
               (lambda (&rest _args) (ert-fail "Cached PDF should not be inspected again"))))
      (nnopds-test--with-browser
       (nnopds-test--at-book)
       (nnopds-browse-select)
       (with-current-buffer gnus-summary-buffer
         (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader)))
           (should (= (gnus-summary-article-number) 5))
           (should-not gnus-current-article)
           (should-not (nnopds-paged--reader-article reader))
           (call-interactively (key-binding (kbd "SPC")))
           (nnopds-paged-test--settled reader 5)
           (should (= gnus-current-article 5))
           (should (= (nnopds-paged--book-visible-pages book) 2))
           (should (nnopds-paged--book-cover book))
           (should (eq (nnopds-paged--book-direction book) 'rtl))
           (should (equal (nnopds-paged-test--shown) '(6 5)))
           (should-not (nnopds-test--requests opds-root))
           (gnus-summary-exit))))))))

(ert-deftest nnopds-mupdf-test-download-failures-and-edition-changes-are-not-committed ()
  (nnopds-mupdf-test--with-server
   (let* ((publication (nnopds-mupdf-test--publication connection))
          (directory (nnopds--cache-file
                      connection
                      (concat (secure-hash 'sha256 (nnopds--publication-group publication)) ".pdf/")))
          (file (expand-file-name "book.pdf" directory))
          (index (expand-file-name "index.json" directory)))
     (dolist (failure '("503" "truncated"))
       (nnopds-test--write opds-root "download-failure.txt" failure)
       (should-error (nnopds--load-publication 'local connection publication))
       (should-not (file-exists-p file))
       (should-not (file-exists-p index))
       (should-not (directory-files directory nil "^\\.nnopds-")))
     (delete-file (expand-file-name "download-failure.txt" opds-root))
     (nnopds-test--write opds-root "book.pdf" "%PDF-1.7\nInvalid PDF\n%%EOF\n")
     (should-error (nnopds--load-publication 'local connection publication))
     (should-not (file-exists-p file))
     (should-not (file-exists-p index))
     (should-not (directory-files directory nil "^\\.nnopds-"))
     (nnopds--write-json index '(:digest "previous-edition"))
     (should-error (nnopds--load-publication 'local connection publication))
     (should-not (file-exists-p file))
     (should (equal (plist-get (nnopds--read-json index) :digest) "previous-edition"))
     (should-not (directory-files directory nil "^\\.nnopds-")))))

(ert-deftest nnopds-mupdf-test-render-failure-keeps-download-and-can-retry ()
  (nnopds-mupdf-test--with-server
   (let ((nnopds-mupdf-program (nnopds-mupdf-test--wrapper opds-root)))
     (nnopds-test--write opds-root "render-failure.txt" "enabled")
     (nnopds-paged-test--with-images
      (nnopds-test--with-browser
       (nnopds-test--at-book)
       (nnopds-browse-select)
       (with-current-buffer gnus-summary-buffer
         (gnus-summary-display-article (gnus-summary-article-number))
         (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader)))
           (nnopds-paged-test--settled reader)
           (should (string-match-p "fixture render failure" (gethash 1 (nnopds-paged--book-errors book))))
           (should-not (nnopds-paged--book-position book))
           (should (memq 1 gnus-newsgroup-unreads))
           (should (file-readable-p (plist-get (nnopds-paged--book-source-data book) :file)))
           (should-not (directory-files (nnopds-paged--book-directory book) nil "^\\.nnopds-"))
           (delete-file (expand-file-name "render-failure.txt" opds-root))
           (nnopds-paged-retry)
           (nnopds-paged-test--settled reader 1)
           (should (equal (nnopds-paged-test--shown) '(1)))
           (should-not (gethash 1 (nnopds-paged--book-errors book)))
           (gnus-summary-exit))))))))

(ert-deftest nnopds-mupdf-test-closing-reader-cancels-render-and-restores-buffers ()
  (nnopds-mupdf-test--with-server
   (let ((nnopds-mupdf-program (nnopds-mupdf-test--wrapper opds-root)))
     (nnopds-test--write opds-root "render-delay.txt" "2")
     (nnopds-paged-test--with-images
      (nnopds-test--with-browser
       (nnopds-test--at-book)
       (nnopds-browse-select)
       (with-current-buffer gnus-summary-buffer
         (gnus-summary-display-article (gnus-summary-article-number))
         (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader))
                (article (get-buffer gnus-article-buffer))
                (render (cl-find-if (lambda (child)
                                      (string-prefix-p "nnopds-mupdf-render" (process-name child)))
                                    (process-list)))
                (output (and render (process-buffer render))))
           (should render)
           (should (= 1 (hash-table-count (nnopds-paged--book-active book))))
           (gnus-summary-exit)
           (should (nnopds-paged--reader-closed reader))
           (should-not (process-live-p render))
           (nnopds-test--wait (lambda () (not (buffer-live-p output))))
           (should (zerop (hash-table-count (nnopds-paged--book-active book))))
           (should-not (nnopds-paged--book-position book))
           (should-not (directory-files (nnopds-paged--book-directory book) nil "^\\.nnopds-"))
           (when (buffer-live-p article)
             (should-not (buffer-local-value 'nnopds-paged-mode article))))))))))

(ert-deftest nnopds-mupdf-test-browser-opens-downloaded-pdf-in-article-buffer ()
  (nnopds-mupdf-test--with-server
   (nnopds-test--with-browser
     (nnopds-test--at-book)
     (should-error (nnopds-browse-read) :type 'user-error)
     (should (= 1 (length (nnopds-test--requests opds-root))))
     (let ((file (nnopds-browse-download)))
       (should (equal (nnopds--read-bytes file)
                      (nnopds--read-bytes (expand-file-name "book.pdf" opds-root))))
       (nnopds-test--write opds-root "requests.jsonl" "")
       (nnopds-paged-test--with-images
         (nnopds-browse-read)
         (with-current-buffer gnus-summary-buffer
           (nnopds-paged-test--settled nnopds-paged--reader 1)
           (with-current-buffer gnus-article-buffer
             (should (derived-mode-p 'gnus-article-mode))
             (should nnopds-paged-mode))
           (gnus-summary-exit)))
       (should-not (nnopds-test--requests opds-root))))))

(ert-deftest nnopds-mupdf-test-epub-pages-use-a-separate-gnus-group ()
  (nnopds-test--with-server
    (skip-unless (and (executable-find nnopds-mupdf-program)
                      (or (executable-find "7zz") (executable-find "7z"))
                      (libxml-available-p)))
    (nnopds-test--with-browser
      (nnopds-test--at-book)
      (let ((file (nnopds-browse-download)) (chapters (gnus-group-real-name (gnus-browse-group-name))))
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (should (equal (gnus-group-real-name gnus-newsgroup-name) chapters))
          (should-not nnopds-paged-mode)
          (with-current-buffer gnus-article-buffer
            (should (derived-mode-p 'gnus-article-mode))
            (should (string-search "中文内容 α" (buffer-string))))
          (gnus-summary-exit))
        (nnopds-test--write opds-root "requests.jsonl" "")
        (let ((nnopds-book-readers '((epub . zr-doc-view))))
          (nnopds-paged-test--with-images
            (with-current-buffer gnus-browse-buffer
              (nnopds-test--at-book)
              (should (equal (nnopds-browse-download) file))
              (nnopds-browse-read))
            (with-current-buffer gnus-summary-buffer
              (should (equal (gnus-group-real-name gnus-newsgroup-name) (concat chapters ".pages")))
              (nnopds-paged-test--settled nnopds-paged--reader 1)
              (with-current-buffer gnus-article-buffer
                (should (derived-mode-p 'gnus-article-mode))
                (should nnopds-paged-mode))
              (gnus-summary-exit))))
        (should-not (nnopds-test--requests opds-root))))))

(provide 'nnopds-mupdf-test)
;;; nnopds-mupdf-test.el ends here
