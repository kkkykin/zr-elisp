;;; nnopds-comic-test.el --- Streaming comic reader tests -*- lexical-binding: t; -*-

;;; Code:

(require 'nnopds-test-helpers
         (expand-file-name "nnopds-test-helpers.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'nnopds-comic)
(require 'nnopds-paged-test-helpers
         (expand-file-name "nnopds-paged-test-helpers.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

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
            (nnopds-paged-visible-pages 1) (nnopds-paged-cover-single t)
            (nnopds-paged-landscape-single t) (nnopds-paged-direction 'auto)
            (nnopds-paged-max-requests 2) (nnopds-paged-prefetch-pages 0))
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

(ert-deftest nnopds-comic-test-both-manifests-are-lazy-and-preferred ()
  (dolist (kind '(komga calibre))
    (nnopds-comic-test--with-server kind
      (let* ((book (nnopds-comic-test--book connection))
             (publication (nnopds-paged--book-publication book))
             (group (nnopds--publication-group publication))
             (page (nnopds-paged--page book 2)))
        (should (= 7 (nnopds--publication-count publication)))
        (should (eq 'rtl (nnopds-paged--direction book)))
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
        (should (= 1.0 (plist-get (plist-get (nnopds--locator 'comic book (nnopds-paged--page book 7)) :locations)
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

(defun nnopds-comic-test--file (book page)
  "Return the comic PAGE's cache file."
  (nnopds-paged--file 'comic book page 1))

(ert-deftest nnopds-comic-test-sliding-window-cover-landscape-and-tail ()
  (let* ((pages (vconcat (cl-loop for number from 1 to 7 collect
                                 (list :number number :width 20 :height 30))))
         (book (nnopds-paged--make-book :pages pages :visible-pages 3
                                        :cover t :landscape t :direction 'auto :progression 'rtl))
         (reader (nnopds-paged--make-reader :book book :anchor 1)))
    (should (equal (nnopds-paged--visible reader) '(1)))
    (setf (nnopds-paged--reader-anchor reader) 2)
    (should (equal (nnopds-paged--visible reader) '(2 3 4)))
    (setf (nnopds-paged--reader-anchor reader) 3)
    (should (equal (nnopds-paged--visible reader) '(3 4 5)))
    (setf (plist-get (aref pages 3) :width) 40 (plist-get (aref pages 3) :height) 20)
    (should (equal (nnopds-paged--visible reader) '(3)))
    (setf (nnopds-paged--reader-anchor reader) 4)
    (should (equal (nnopds-paged--visible reader) '(4)))
    (setf (nnopds-paged--reader-anchor reader) 6)
    (should (equal (nnopds-paged--visible reader) '(6 7)))
    (setf (nnopds-paged--reader-anchor reader) 1
          (nnopds-paged--book-cover book) nil (nnopds-paged--book-landscape book) nil)
    (should (equal (nnopds-paged--visible reader) '(1 2 3)))
    (setf (nnopds-paged--book-visible-pages book) 1)
    (should (equal (nnopds-paged--visible reader) '(1)))))

(ert-deftest nnopds-comic-test-screen-turns-stop-at-cover-and-landscape ()
  (let* ((pages (vconcat (cl-loop for number from 1 to 7 collect
                                 (list :number number :width (if (= number 4) 40 20) :height 30))))
         (book (nnopds-paged--make-book :pages pages :visible-pages 3 :cover t :landscape t)))
    (should (= (nnopds-paged--screen-target book 1 1) 2))
    (should (= (nnopds-paged--screen-target book 2 1) 4))
    (should (= (nnopds-paged--screen-target book 4 1) 5))
    (should (= (nnopds-paged--screen-target book 5 -1) 4))
    (should (= (nnopds-paged--screen-target book 4 -1) 2))
    (should (= (nnopds-paged--screen-target book 2 -1) 1))
    (should-error (nnopds-paged--screen-target book 1 -1) :type 'user-error)
    (should-error (nnopds-paged--screen-target book 5 1) :type 'user-error)))

(ert-deftest nnopds-comic-test-fit-keeps-aspect-and-common-height ()
  (let ((pages '((:width 20 :height 30) (:width 30 :height 40))) (nnopds-paged-gap 12))
    (should (equal (nnopds-paged--sizes pages '(500 . 300)) '((200 . 300) (225 . 300))))
    (should (equal (nnopds-paged--sizes pages '(210 . 300)) '((92 . 139) (104 . 139))))
    (should (equal (nnopds-paged--sizes '((:width 40 :height 20)) '(600 . 200)) '((400 . 200))))))

(ert-deftest nnopds-comic-test-prefetch-is-bounded-and-does-not-read-ahead ()
  (nnopds-comic-test--with-server 'komga
    (let ((nnopds-paged-prefetch-pages 4))
      (nnopds-test--write opds-root "comic-page-delay.txt" "0.15")
      (nnopds-paged-test--with-images
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader)))
              (should (= 2 (hash-table-count (nnopds-paged--book-active book))))
              (should-not (nnopds-paged--book-position book))
              (should (memq 1 gnus-newsgroup-unreads))
              (nnopds-paged-test--settled reader 1)
              (should (equal (nnopds-paged-test--shown) '(1)))
              (should-not (memq 1 gnus-newsgroup-unreads))
              (should (cl-every (lambda (number) (memq number gnus-newsgroup-unreads)) '(2 3 4 5 6 7)))
              (dolist (number '(1 2 3 4 5))
                (should (file-readable-p (nnopds-comic-test--file book (nnopds-paged--page book number)))))
              (should-not (file-exists-p (nnopds-comic-test--file book (nnopds-paged--page book 6))))
              (with-current-buffer gnus-article-buffer
                (should nnopds-paged-mode)
                (goto-char (text-property-any (point-min) (point-max) 'nnopds-paged-page 1))
                (should (eq (get-text-property (point) 'keymap) nnopds-paged-mode-map)))
              (gnus-summary-exit))))))))

(ert-deftest nnopds-comic-test-article-page-turns-preserve-window-layout ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-paged-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (let* ((summary (get-buffer gnus-summary-buffer))
               (article (get-buffer gnus-article-buffer))
               (reader (buffer-local-value 'nnopds-paged--reader summary)))
          (nnopds-paged-test--settled reader 1)
          (select-window (get-buffer-window article))
          ;; Keep focus in the article when both reader windows are visible.
          (nnopds-paged-next)
          (should (eq (window-buffer (selected-window)) article))
          (should (get-buffer-window summary))
          (nnopds-paged-test--settled reader 2)
          ;; Gnus's article-only layout must survive an uncached page turn.
          (with-current-buffer summary
            (let ((gnus-widen-article-window t)) (gnus-summary-select-article-buffer)))
          (should-not (get-buffer-window summary))
          (nnopds-paged-next)
          (should (one-window-p))
          (should (eq (window-buffer (selected-window)) article))
          (nnopds-paged-test--settled reader 3)
          (should (equal (nnopds-paged-test--shown) '(3)))
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
                (nnopds-paged-previous)
                (should (eq (selected-window) article-window))
                (should-not (get-buffer-window summary))
                (should (eq (window-buffer other) other-buffer))
                (nnopds-paged-test--settled reader 2)
                (nnopds-paged-double-page)
                (nnopds-paged-goto-page 5)
                (should-not (get-buffer-window summary))
                (should (window-live-p other))
                (nnopds-paged-test--settled reader 5)
                (should (equal (nnopds-paged-test--shown) '(6 5)))))
            (delete-other-windows))
          (gnus-article-show-summary)
          (with-current-buffer summary (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-screen-and-arrow-turns-preserve-page-and-marks ()
  (nnopds-comic-test--with-server 'calibre
    (nnopds-paged-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader)))
            (nnopds-paged-test--settled reader 1)
            (nnopds-paged-goto-page 3)
            (nnopds-paged-test--settled reader 3)
            (gnus-summary-mark-article 4 gnus-ticked-mark t)
            (nnopds-paged-double-page)
            (nnopds-paged-test--settled reader 3)
            (should (equal (nnopds-paged-test--shown) '(4 3)))
            (should (memq 2 gnus-newsgroup-unreads))
            (should (= (gnus-summary-article-mark 4) gnus-ticked-mark))
            (nnopds-paged-set-visible-pages 3)
            (nnopds-paged-test--settled reader 3)
            (should (equal (nnopds-paged-test--shown) '(5 4 3)))
            (nnopds-paged-toggle-direction)
            (should (equal (nnopds-paged-test--shown) '(3 4 5)))
            (should (= gnus-current-article 3))
            (should (= (nnopds-paged--book-position book) 3))
            ;; SPC/n advances a screen; arrows advance one original page.
            (should (eq (lookup-key nnopds-paged-mode-map (kbd "SPC")) #'nnopds-paged-next))
            (should (eq (lookup-key nnopds-paged-mode-map (kbd "DEL")) #'nnopds-paged-previous))
            (nnopds-paged-next)
            (nnopds-paged-test--settled reader 6)
            (should (equal (nnopds-paged-test--shown) '(6 7)))
            (nnopds-paged-right)
            (nnopds-paged-test--settled reader 7)
            (should (equal (nnopds-paged-test--shown) '(7)))
            (should-error (nnopds-paged-right) :type 'user-error)
            (nnopds-paged-set-direction 'rtl)
            (nnopds-paged-right)
            (nnopds-paged-test--settled reader 6)
            (should (equal (nnopds-paged-test--shown) '(7 6)))
            (nnopds-paged-left)
            (nnopds-paged-test--settled reader 7)
            (nnopds-paged-previous)
            (nnopds-paged-test--settled reader 4)
            (should (equal (nnopds-paged-test--shown) '(6 5 4)))
            (nnopds-paged-goto-page 3)
            (nnopds-paged-test--settled reader 3)
            (with-current-buffer gnus-article-buffer
              (nnopds-paged-single-page)
              (should (equal (nnopds-paged-test--shown) '(3))))
            (should (= (nnopds-paged--reader-anchor reader) 3))
            (should-error (nnopds-paged-set-visible-pages 0) :type 'user-error)
            (should-error (nnopds-paged-goto-page 0) :type 'user-error)
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-lazy-landscape-remains-alone ()
  (nnopds-comic-test--with-server 'calibre
    (nnopds-test--write opds-root "comic-landscape.txt" "enabled")
    (nnopds-paged-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let ((reader nnopds-paged--reader))
            (nnopds-paged-test--settled reader 1)
            (nnopds-paged-double-page)
            (nnopds-paged-goto-page 4)
            (nnopds-paged-test--settled reader 4)
            (should (equal (nnopds-paged-test--shown) '(4)))
            (should (memq 5 gnus-newsgroup-unreads))
            (nnopds-paged-next)
            (nnopds-paged-test--settled reader 5)
            (should (equal (nnopds-paged-test--shown) '(6 5)))
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-late-old-page-does-not-overwrite-reader ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-test--write opds-root "comic-page-delay.txt" "0.3")
    (nnopds-test--write opds-root "comic-delay-page.txt" "1")
    (nnopds-paged-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let ((reader nnopds-paged--reader))
            (nnopds-paged-goto-page 3)
            (nnopds-paged-test--settled reader 3)
            (should (equal (nnopds-paged-test--shown) '(3)))
            (should (memq 1 gnus-newsgroup-unreads))
            (should (= gnus-current-article 3))
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-failed-images-do-not-commit-and-can-retry ()
  (dolist (control '("comic-failure-page.txt" "comic-invalid-page.txt"))
    (nnopds-comic-test--with-server 'komga
      (nnopds-test--write opds-root control "1")
      (nnopds-paged-test--with-images
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader)))
              (nnopds-paged-test--settled reader)
              (should (gethash 1 (nnopds-paged--book-errors book)))
              (should (memq 1 gnus-newsgroup-unreads))
              (should-not (nnopds-paged--book-position book))
              (should-not (file-exists-p (nnopds-comic-test--file book (nnopds-paged--page book 1))))
              (should-not (directory-files (nnopds-paged--book-directory book) nil "\\`\\.nnopds-"))
              (delete-file (expand-file-name control opds-root))
              (with-current-buffer gnus-article-buffer (nnopds-paged-retry))
              (nnopds-paged-test--settled reader 1)
              (should (equal (nnopds-paged-test--shown) '(1)))
              (should-not (gethash 1 (nnopds-paged--book-errors book)))
              (gnus-summary-exit))))))))

(ert-deftest nnopds-comic-test-closing-a-loading-group-cancels-and-restores-mode ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-test--write opds-root "comic-page-delay.txt" "0.5")
    (nnopds-paged-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader))
                 (article-buffer (get-buffer gnus-article-buffer)))
            (should (= 1 (hash-table-count (nnopds-paged--book-active book))))
            (gnus-summary-exit)
            (should (nnopds-paged--reader-closed reader))
            (should-not (nnopds-paged--book-readers book))
            (should-not (nnopds-paged--book-position book))
            (should (zerop (hash-table-count (nnopds-paged--book-active book))))
            (should-not (nnopds-paged--book-queue book))
            (should-not (directory-files (nnopds-paged--book-directory book) nil "\\`\\.nnopds-"))
            (when (buffer-live-p article-buffer)
              (with-current-buffer article-buffer
                (should-not nnopds-paged-mode)
                (should-not nnopds-paged--reader)))))))))

(ert-deftest nnopds-comic-test-reopen-restores-page-settings-and-cached-images ()
  (nnopds-comic-test--with-server 'komga
    (nnopds-paged-test--with-images
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let ((reader nnopds-paged--reader))
            (nnopds-paged-test--settled reader 1)
            (nnopds-paged-goto-page 3)
            (nnopds-paged-test--settled reader 3)
            (nnopds-paged-double-page)
            (nnopds-paged-toggle-cover)
            (nnopds-paged-set-direction 'ltr)
            (nnopds-paged-test--settled reader 3)
            (gnus-summary-exit))))
      (nnopds-test--write opds-root "requests.jsonl" "")
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (let* ((reader nnopds-paged--reader) (book (nnopds-paged--reader-book reader)))
            (nnopds-paged-test--settled reader 3)
            (should (= gnus-current-article 3))
            (should (= (nnopds-paged--book-visible-pages book) 2))
            (should-not (nnopds-paged--book-cover book))
            (should (eq (nnopds-paged--book-direction book) 'ltr))
            (should (equal (nnopds-paged-test--shown) '(3 4)))
            (should-not (nnopds-test--requests opds-root))
            (gnus-summary-exit)))))))

(ert-deftest nnopds-comic-test-calibre-resume-keeps-sliding-window ()
  (nnopds-comic-test--with-server 'calibre
    (nnopds-test--write opds-root "comic-landscape.txt" "enabled")
    (let ((nnopds-paged-visible-pages 2) (nnopds-paged-prefetch-pages 4))
      (nnopds-paged-test--with-images
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let ((reader nnopds-paged--reader))
              (nnopds-paged-test--settled reader 1)
              ;; Earlier unknown landscape dimensions do not shift the anchor.
              (nnopds-paged-goto-page 5)
              (nnopds-paged-test--settled reader 5)
              (should (equal (nnopds-paged-test--shown) '(6 5)))
              (gnus-summary-exit))))
        (nnopds-test--write opds-root "requests.jsonl" "")
        (nnopds-test--with-browser
          (nnopds-test--at-book)
          (nnopds-browse-read)
          (with-current-buffer gnus-summary-buffer
            (let ((reader nnopds-paged--reader))
              (nnopds-paged-test--settled reader 5)
              (should (equal (nnopds-paged-test--shown) '(6 5)))
              (should-not (nnopds-test--requests opds-root))
              (gnus-summary-exit))))))))

(ert-deftest nnopds-comic-test-comic-mode-does-not-leak-into-epub ()
  (nnopds-comic-test--with-server 'komga
    (skip-unless (and (or (executable-find "7zz") (executable-find "7z")) (libxml-available-p)))
    (nnopds-test--with-browser
      (nnopds-test--at-book)
      (nnopds-paged-test--with-images
        (nnopds-browse-read)
        (with-current-buffer gnus-summary-buffer
          (nnopds-paged-test--settled nnopds-paged--reader 1)
          (gnus-summary-exit)))
      (with-current-buffer gnus-browse-buffer
        (nnopds-test--at-book)
        (forward-line 1)
        (nnopds-browse-read))
      (with-current-buffer gnus-summary-buffer
        (should-not nnopds-paged-mode)
        (should-not gnus-summary-display-article-function)
        (with-current-buffer gnus-article-buffer
          (should-not nnopds-paged-mode)
          (should (string-match-p "中文内容 α" (buffer-string))))
        (gnus-summary-exit)))))

(provide 'nnopds-comic-test)
;;; nnopds-comic-test.el ends here
