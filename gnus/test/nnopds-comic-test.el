;;; nnopds-comic-test.el --- Streaming comic reader tests -*- lexical-binding: t; -*-

;;; Code:

(require 'nnopds-test-helpers
         (expand-file-name "nnopds-test-helpers.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'nnopds-comic)

(defmacro nnopds-comic-test--with-server (kind &rest body)
  "Run BODY with KIND's comic feed and an isolated real HTTP server."
  (declare (indent 1) (debug t))
  `(nnopds-test--with-server
     (let* ((kind ,kind)
            (opds-url (nnopds--url (if (eq kind 'komga) "/komga/opds/v2/catalog" "/calibre/opds") opds-url))
            (nnopds-test--server-definitions
             (append (list (list 'nnopds-url opds-url))
                     (if (eq kind 'komga)
                         '((nnopds-headers (("X-API-Key" . "test-key"))))
                       '((nnopds-user "reader") (nnopds-password "test-password") (nnopds-auth-method digest)))))
            (nnopds-comic-layout 'single) (nnopds-comic-cover-single t) (nnopds-comic-direction 'auto)
            (nnopds-comic-max-requests 2) (nnopds-comic-prefetch-pages 0))
       (nnopds-test--write opds-root "comic-catalog.txt" (symbol-name kind))
       (when (eq kind 'calibre) (nnopds-test--write opds-root "digest-auth.txt" "enabled"))
       (nnopds-close-server "library")
       (should (nnopds-open-server "library" nnopds-test--server-definitions))
       (setq connection nnopds--connection)
       ,@body)))

(defun nnopds-comic-test--book (connection)
  "Open the fixture comic through the real backend interfaces."
  (nnopds--catalog-page connection (nnopds--connection-url connection))
  (let* ((group (car (nnopds--connection-catalog connection)))
         (publication (gethash group (nnopds--connection-publications connection))))
    (should (nnopds-request-group group "library"))
    (should (eq (nnopds--publication-format publication) 'comic))
    (nnopds--publication-data publication)))

(defmacro nnopds-comic-test--with-images (&rest body)
  "Run BODY with image display operations emulated on nox Emacs.
Only the native decoder and frame capabilities are substituted.  Images
are real PNGs downloaded over HTTP, and insert-image, Gnus, the request
queue, cache files, properties and reading events remain real."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'display-images-p) (lambda (&rest _args) t))
             ((symbol-function 'image-type-available-p) (lambda (type) (memq type '(png jpeg gif))))
             ((symbol-function 'create-image)
              (lambda (file &optional type _data-p &rest properties)
                (unless (file-readable-p file) (error "Image file is missing"))
                (append (list 'image :type type :file file) properties)))
             ((symbol-function 'image-size)
              (lambda (image &rest _args)
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally (plist-get (cdr image) :file) nil 0 24)
                  (let ((bytes (buffer-string)))
                    (unless (string-prefix-p "\211PNG\r\n\032\n" bytes) (error "Not a PNG"))
                    (cl-flet ((uint (offset)
                                (+ (ash (aref bytes offset) 24) (ash (aref bytes (+ offset 1)) 16)
                                   (ash (aref bytes (+ offset 2)) 8) (aref bytes (+ offset 3)))))
                      (cons (uint 16) (uint 20)))))))
             ((symbol-function 'image-flush) (lambda (&rest _args)))
             ((symbol-function 'nnopds-comic--viewport) (lambda () '(600 . 800))))
     ,@body))

(defun nnopds-comic-test--shown ()
  "Return the original page numbers in on-screen image order."
  (with-current-buffer gnus-article-buffer
    (let ((position (point-min)) pages)
      (while (< position (point-max))
        (when-let* ((number (get-text-property position 'nnopds-comic-page))) (push number pages))
        (setq position (next-single-property-change position 'nnopds-comic-page nil (point-max))))
      (nreverse pages))))

(defun nnopds-comic-test--settled (reader &optional position)
  "Wait for READER's image queue, optionally requiring committed POSITION."
  (let ((book (nnopds-comic--reader-book reader)))
    (condition-case nil
        (nnopds-test--wait
         (lambda ()
           (and (zerop (hash-table-count (nnopds-comic--book-active book)))
                (null (nnopds-comic--book-queue book))
                (or (null position) (eq position (nnopds-comic--book-position book))))))
      (error (ert-fail (format "Reader did not settle: page=%S queue=%S errors=%S live=%S"
                              (nnopds-comic--book-position book) (nnopds-comic--book-queue book)
                              (nnopds-comic--book-errors book) (nnopds-comic--live-p reader)))))))

(ert-deftest nnopds-comic-test-both-manifests-are-lazy-and-preferred ()
  (dolist (kind '(komga calibre))
    (nnopds-comic-test--with-server kind
      (let* ((book (nnopds-comic-test--book connection))
             (publication (nnopds-comic--book-publication book))
             (group (nnopds--publication-group publication))
             (page (nnopds-comic--page book 2)))
        (should (= 7 (nnopds--publication-count publication)))
        (should (eq 'rtl (nnopds-comic--direction book)))
        (should (equal (plist-get page :type) "image/png"))
        (should (string-match-p "format=png" (plist-get page :href)))
        (when (eq kind 'calibre)
          (should (string-match-p (regexp-quote "/calibre/comic-page/2/1?library_id=main&v=edition-1&format=png")
                                  (plist-get page :href)))
          (should-not (plist-get page :width)))
        (should (eq 'nov (nnopds-retrieve-headers '(1 2 3 4 5 6 7) group "library")))
        (should (nnopds-request-article 2 group "library"))
        (should (nnopds-request-article (mail-header-id (nnopds--header 'comic book page)) group "library"))
        (should (equal (nnopds--locate 'comic book (nnopds--locator 'comic book page)) '(2)))
        (should (= 1.0 (plist-get (plist-get (nnopds--locator 'comic book (nnopds-comic--page book 7)) :locations)
                                  :totalProgression)))
        (should-not (cl-some (lambda (request)
                              (string-match-p (rx (or "/pages/" "/comic-page/" ".epub" ".cbz"))
                                              (plist-get request :path))) (nnopds-test--requests opds-root)))
        (should (cl-every (lambda (request)
                           (or (string-suffix-p "/catalog" (plist-get request :path))
                               (string-suffix-p "/opds" (plist-get request :path))
                               (string-match-p (regexp-quote "application/divina+json") (plist-get request :accept))))
                         (nnopds-test--requests opds-root)))
        (should-not (nnopds--publication-progress publication))))))

(ert-deftest nnopds-comic-test-cover-pairing-landscape-and-last-page ()
  (let* ((pages (vconcat (cl-loop for number from 1 to 7 collect (list :number number :width 20 :height 30))))
         (book (nnopds-comic--make-book :pages pages :layout 'single :cover t :direction 'auto :progression 'rtl)))
    (should (equal (nnopds-comic--spreads book) '((1) (2) (3) (4) (5) (6) (7))))
    (setf (nnopds-comic--book-layout book) 'double)
    (should (equal (nnopds-comic--spreads book) '((1) (2 3) (4 5) (6 7))))
    (setf (nnopds-comic--book-cover book) nil)
    (should (equal (nnopds-comic--spreads book) '((1 2) (3 4) (5 6) (7))))
    (setf (nnopds-comic--book-cover book) t (plist-get (aref pages 3) :width) 40
          (plist-get (aref pages 3) :height) 20)
    (should (equal (nnopds-comic--spreads book) '((1) (2 3) (4) (5 6) (7))))
    (setf (nnopds-comic--book-direction book) 'ltr)
    (should (equal (nnopds-comic--spreads book) '((1) (2 3) (4) (5 6) (7))))))

(ert-deftest nnopds-comic-test-fit-keeps-aspect-and-common-height ()
  (let ((pages '((:width 20 :height 30) (:width 30 :height 40))) (nnopds-comic-gap 12))
    (should (equal (nnopds-comic--sizes pages '(500 . 300)) '((200 . 300) (225 . 300))))
    (should (equal (nnopds-comic--sizes pages '(210 . 300)) '((92 . 139) (104 . 139))))
    (should (equal (nnopds-comic--sizes '((:width 40 :height 20)) '(600 . 200)) '((400 . 200))))))

(ert-deftest nnopds-comic-test-prefetch-is-bounded-and-does-not-read-ahead ()
  (nnopds-comic-test--with-server 'komga
    (let ((nnopds-comic-prefetch-pages 4))
      (nnopds-test--write opds-root "comic-page-delay.txt" "0.15")
      (nnopds-comic-test--with-images
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let* ((reader nnopds-comic--reader) (book (nnopds-comic--reader-book reader)))
              (should (= 2 (hash-table-count (nnopds-comic--book-active book))))
              (should-not (nnopds-comic--book-position book))
              (should (memq 1 gnus-newsgroup-unreads))
              (nnopds-comic-test--settled reader 1)
              (should (equal (nnopds-comic-test--shown) '(1)))
              (should-not (memq 1 gnus-newsgroup-unreads))
              (should (cl-every (lambda (number) (memq number gnus-newsgroup-unreads)) '(2 3 4 5 6 7)))
              (dolist (number '(1 2 3 4 5))
                (should (file-readable-p (nnopds-comic--file book (nnopds-comic--page book number)))))
              (should-not (file-exists-p (nnopds-comic--file book (nnopds-comic--page book 6))))
              (with-current-buffer gnus-article-buffer
                (should nnopds-comic-mode)
                (goto-char (text-property-any (point-min) (point-max) 'nnopds-comic-page 1))
                (should (eq (get-text-property (point) 'keymap) nnopds-comic-mode-map)))
              (gnus-summary-exit))))))))

(ert-deftest nnopds-comic-test-article-page-turns-preserve-window-layout ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-comic-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (let* ((summary (get-buffer gnus-summary-buffer))
               (article (get-buffer gnus-article-buffer))
               (reader (buffer-local-value 'nnopds-comic--reader summary)))
          (nnopds-comic-test--settled reader 1)
          (select-window (get-buffer-window article))
          ;; Keep focus in the article when both reader windows are visible.
          (nnopds-comic-next)
          (should (eq (window-buffer (selected-window)) article))
          (should (get-buffer-window summary))
          (nnopds-comic-test--settled reader 2)
          ;; Gnus's article-only layout must survive an uncached page turn.
          (with-current-buffer summary
            (let ((gnus-widen-article-window t)) (gnus-summary-select-article-buffer)))
          (should-not (get-buffer-window summary))
          (nnopds-comic-next)
          (should (one-window-p))
          (should (eq (window-buffer (selected-window)) article))
          (nnopds-comic-test--settled reader 3)
          (should (equal (nnopds-comic-test--shown) '(3)))
          ;; Also preserve a manually enlarged article and an unrelated window.
          (gnus-article-show-summary)
          (select-window (get-buffer-window article))
          (delete-other-windows)
          (with-temp-buffer
            (let ((other (split-window-right))
                  (other-buffer (current-buffer))
                  (article-window (selected-window)))
              (set-window-buffer other other-buffer)
              (with-current-buffer article
                (nnopds-comic-previous)
                (should (eq (selected-window) article-window))
                (should-not (get-buffer-window summary))
                (should (eq (window-buffer other) other-buffer))
                (nnopds-comic-test--settled reader 2)
                (nnopds-comic-double-page)
                (nnopds-comic-goto-page 5)
                (should-not (get-buffer-window summary))
                (should (window-live-p other))
                (nnopds-comic-test--settled reader 5)
                (should (equal (nnopds-comic-test--shown) '(5 4)))))
            (delete-other-windows))
          (gnus-article-show-summary)
          (with-current-buffer summary (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-live-switches-preserve-original-page-and-marks ()
  (nnopds-comic-test--with-server 'calibre
    (nnopds-comic-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let* ((reader nnopds-comic--reader) (book (nnopds-comic--reader-book reader)))
            (nnopds-comic-test--settled reader 1)
            (nnopds-comic-goto-page 3)
            (nnopds-comic-test--settled reader 3)
            (gnus-summary-mark-article 4 gnus-ticked-mark t)
            (nnopds-comic-double-page)
            (nnopds-comic-test--settled reader 3)
            (should (equal (nnopds-comic-test--shown) '(3 2)))
            (should-not (memq 2 gnus-newsgroup-unreads))
            (nnopds-comic-toggle-cover)
            (nnopds-comic-test--settled reader 3)
            (should (equal (nnopds-comic-test--shown) '(4 3)))
            (should (= (gnus-summary-article-mark 4) gnus-ticked-mark))
            (nnopds-comic-toggle-direction)
            (should (equal (nnopds-comic-test--shown) '(3 4)))
            (should (= gnus-current-article 3))
            (should (= (nnopds-comic--book-position book) 3))
            (nnopds-comic-next)
            (nnopds-comic-test--settled reader 5)
            (should (equal (nnopds-comic-test--shown) '(5 6)))
            (nnopds-comic-right)
            (nnopds-comic-test--settled reader 7)
            (should (equal (nnopds-comic-test--shown) '(7)))
            (should-error (nnopds-comic-right) :type 'user-error)
            (nnopds-comic-set-direction 'rtl)
            (nnopds-comic-right)
            (nnopds-comic-test--settled reader 5)
            (should (equal (nnopds-comic-test--shown) '(6 5)))
            (nnopds-comic-left)
            (nnopds-comic-test--settled reader 7)
            (nnopds-comic-previous)
            (nnopds-comic-test--settled reader 5)
            (nnopds-comic-goto-page 3)
            (nnopds-comic-test--settled reader 3)
            (with-current-buffer gnus-article-buffer
              (nnopds-comic-single-page)
              (should (equal (nnopds-comic-test--shown) '(3))))
            (should (= (nnopds-comic--reader-anchor reader) 3))
            (should-error (nnopds-comic-goto-page 0) :type 'user-error)
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-lazy-landscape-keeps-its-own-spread ()
  (nnopds-comic-test--with-server 'calibre
    (nnopds-test--write opds-root "comic-landscape.txt" "enabled")
    (nnopds-comic-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let ((reader nnopds-comic--reader))
            (nnopds-comic-test--settled reader 1)
            (nnopds-comic-double-page)
            (nnopds-comic-goto-page 4)
            (nnopds-comic-test--settled reader 4)
            (should (equal (nnopds-comic-test--shown) '(4)))
            (should (memq 5 gnus-newsgroup-unreads))
            (nnopds-comic-next)
            (nnopds-comic-test--settled reader 5)
            (should (equal (nnopds-comic-test--shown) '(6 5)))
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-late-old-page-does-not-overwrite-reader ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-test--write opds-root "comic-page-delay.txt" "0.3")
    (nnopds-test--write opds-root "comic-delay-page.txt" "1")
    (nnopds-comic-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let ((reader nnopds-comic--reader))
            (nnopds-comic-goto-page 3)
            (nnopds-comic-test--settled reader 3)
            (should (equal (nnopds-comic-test--shown) '(3)))
            (should (memq 1 gnus-newsgroup-unreads))
            (should (= gnus-current-article 3))
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-failed-images-do-not-commit-and-can-retry ()
  (dolist (control '("comic-failure-page.txt" "comic-invalid-page.txt"))
    (nnopds-comic-test--with-server 'komga
      (nnopds-test--write opds-root control "1")
      (nnopds-comic-test--with-images
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let* ((reader nnopds-comic--reader) (book (nnopds-comic--reader-book reader)))
              (nnopds-comic-test--settled reader)
              (should (gethash 1 (nnopds-comic--book-errors book)))
              (should (memq 1 gnus-newsgroup-unreads))
              (should-not (nnopds-comic--book-position book))
              (should-not (file-exists-p (nnopds-comic--file book (nnopds-comic--page book 1))))
              (should-not (directory-files (nnopds-comic--book-directory book) nil "\\`\\.nnopds-"))
              (delete-file (expand-file-name control opds-root))
              (with-current-buffer gnus-article-buffer (nnopds-comic-retry))
              (nnopds-comic-test--settled reader 1)
              (should (equal (nnopds-comic-test--shown) '(1)))
              (should-not (gethash 1 (nnopds-comic--book-errors book)))
              (gnus-summary-exit))))))))

(ert-deftest nnopds-comic-test-closing-a-loading-group-cancels-and-restores-mode ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-test--write opds-root "comic-page-delay.txt" "0.5")
    (nnopds-comic-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let* ((reader nnopds-comic--reader) (book (nnopds-comic--reader-book reader))
                 (article-buffer (get-buffer gnus-article-buffer)))
            (should (= 1 (hash-table-count (nnopds-comic--book-active book))))
            (gnus-summary-exit)
            (should (nnopds-comic--reader-closed reader))
            (should-not (nnopds-comic--book-readers book))
            (should-not (nnopds-comic--book-position book))
            (should (zerop (hash-table-count (nnopds-comic--book-active book))))
            (should-not (nnopds-comic--book-queue book))
            (should-not (directory-files (nnopds-comic--book-directory book) nil "\\`\\.nnopds-"))
            (when (buffer-live-p article-buffer)
              (with-current-buffer article-buffer
                (should-not nnopds-comic-mode)
                (should-not nnopds-comic--reader)))))))))

(ert-deftest nnopds-comic-test-reopen-restores-page-settings-and-cached-images ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-comic-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let ((reader nnopds-comic--reader))
            (nnopds-comic-test--settled reader 1)
            (nnopds-comic-goto-page 3)
            (nnopds-comic-test--settled reader 3)
            (nnopds-comic-double-page)
            (nnopds-comic-toggle-cover)
            (nnopds-comic-set-direction 'ltr)
            (nnopds-comic-test--settled reader 3)
            (gnus-summary-exit))))
      (nnopds-test--write opds-root "requests.jsonl" "")
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let* ((reader nnopds-comic--reader) (book (nnopds-comic--reader-book reader)))
            (nnopds-comic-test--settled reader 3)
            (should (= gnus-current-article 3))
            (should (eq (nnopds-comic--book-layout book) 'double))
            (should-not (nnopds-comic--book-cover book))
            (should (eq (nnopds-comic--book-direction book) 'ltr))
            (should (equal (nnopds-comic-test--shown) '(3 4)))
            (should-not (nnopds-test--requests opds-root))
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-calibre-resume-keeps-landscape-pairing ()
  (nnopds-comic-test--with-server 'calibre
    (nnopds-test--write opds-root "comic-landscape.txt" "enabled")
    (let ((nnopds-comic-layout 'double) (nnopds-comic-prefetch-pages 4))
      (nnopds-comic-test--with-images
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let ((reader nnopds-comic--reader))
              (nnopds-comic-test--settled reader 1)
              ;; Page 4 is already cached but its dimensions are still unknown.
              (nnopds-comic-goto-page 5)
              (nnopds-comic-test--settled reader 5)
              (should (equal (nnopds-comic-test--shown) '(6 5)))
              (gnus-summary-exit))))
        (nnopds-test--write opds-root "requests.jsonl" "")
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let ((reader nnopds-comic--reader))
              (nnopds-comic-test--settled reader 5)
              (should (equal (nnopds-comic-test--shown) '(6 5)))
              (should-not (nnopds-test--requests opds-root))
              (gnus-summary-exit))))))))

(ert-deftest nnopds-comic-test-comic-mode-does-not-leak-into-epub ()
  (nnopds-comic-test--with-server 'komga
    (skip-unless (and (or (executable-find "7zz") (executable-find "7z")) (libxml-available-p)))
    (nnopds-test--with-browser
      (nnopds-test--at-book)
      (nnopds-comic-test--with-images
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (nnopds-comic-test--settled nnopds-comic--reader 1)
          (gnus-summary-exit)))
      (with-current-buffer gnus-browse-buffer
        (nnopds-test--at-book)
        (forward-line 1)
        (nnopds-browse-read))
      (with-current-buffer gnus-summary-buffer
        (should-not nnopds-comic-mode)
        (should-not gnus-summary-display-article-function)
        (with-current-buffer gnus-article-buffer
          (should-not nnopds-comic-mode)
          (should (string-match-p "中文内容 α" (buffer-string))))
        (gnus-summary-exit)))))

(provide 'nnopds-comic-test)
;;; nnopds-comic-test.el ends here
