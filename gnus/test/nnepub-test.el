;;; nnepub-test.el --- Tests for local EPUB groups -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nnepub)
(require 'zr-nndoc-epub)
(require 'gnus-sum)
(require 'zr-test-helpers)

(defconst nnepub-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defconst nnepub-test--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII="))

(defmacro nnepub-test--with-library (&rest body)
  (declare (indent 0) (debug t))
  `(let ((nnepub-7z-program (or (getenv "NNEPUB_TEST_7Z")
                              (executable-find "7zz") (executable-find "7z"))))
     (skip-unless (and nnepub-7z-program (libxml-available-p)))
     (zr-test-with-temp-directory
       (let ((nnoo-state-alist (copy-tree nnoo-state-alist))
             (nnoo-definition-alist (copy-tree nnoo-definition-alist))
             (nnepub-directory nil)
             (nnepub--books nil)
             (nnepub--group nil)
             (nndoc-article-type 'guess)
             (nndoc-address nil)
             (nndoc-current-buffer nil)
             (nndoc-group-alist nil)
             (nndoc-dissection-alist nil)
             (nntp-server-buffer (generate-new-buffer " *nnepub-test-server*")))
         (unwind-protect (progn ,@body)
           (nnepub-request-close)
           (kill-buffer nntp-server-buffer))))))

(defun nnepub-test--write (root path text)
  (let ((file (expand-file-name path root))
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun nnepub-test--book (&optional version name reverse-spine)
  "Create a real zipped EPUB in the current directory and return its path."
  (let* ((version (or version 3))
         (archive (expand-file-name (or name "测试 book.epub")))
         (source (make-temp-file (expand-file-name "source-" default-directory) t))
         (default-directory source)
         (nav (if (= version 3) "nav" "ncx")))
    (nnepub-test--write source "mimetype" "application/epub+zip")
    (nnepub-test--write
     source "META-INF/container.xml"
     "<?xml version='1.0'?><container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile media-type='text/plain' full-path='ignored'/><rootfile full-path='OEBPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>")
    (nnepub-test--write
     source "OEBPS/book.opf"
     (format
      "<?xml version='1.0' encoding='UTF-8'?><package xmlns='http://www.idpf.org/2007/opf' version='%s.0' unique-identifier='id'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:identifier id='id'>urn:uuid:test</dc:identifier><dc:title>测试书籍</dc:title><dc:creator>作者甲</dc:creator><dc:creator>作者乙</dc:creator></metadata><manifest><item id='a' href='Text/a.xhtml' media-type='application/xhtml+xml'/><item id='b' href='Text/b.xhtml' media-type='application/xhtml+xml'/><item id='notes' href='Text/notes.xhtml' media-type='application/xhtml+xml'/><item id='image' href='images/tiny.png' media-type='image/png'/><item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='scripted nav'/><item id='ncx' href='toc.ncx' media-type='application/x-dtbncx+xml'/></manifest><spine toc='%s'><itemref idref='%s'/><itemref idref='%s'/></spine></package>"
      version nav (if reverse-spine "b" "a") (if reverse-spine "a" "b")))
    ;; EPUB 2 has no navigation item in the manifest.
    (when (= version 2)
      (let ((file (expand-file-name "OEBPS/book.opf" source)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (re-search-forward "<item id='nav'[^>]+/>")
          (replace-match "")
          (write-region (point-min) (point-max) file nil 'silent))))
    (nnepub-test--write
     source "OEBPS/nav.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head><title>目录</title></head><body><nav epub:type='page-list'><a href='Text/a.xhtml'>错误标题</a></nav><nav epub:type='toc'><ol><li><a href='Text/a.xhtml#start'>第一章</a><ol><li><a href='Text/a.xhtml#local'>附注</a></li></ol></li><li><a href='Text/b.xhtml#%E6%B3%A8%E9%87%8A'>第二章</a></li></ol></nav></body></html>")
    (nnepub-test--write
     source "OEBPS/toc.ncx"
     "<ncx xmlns='http://www.daisy.org/z3986/2005/ncx/'><navMap><navPoint id='first'><navLabel><text>第一章</text></navLabel><content src='Text/a.xhtml#start'/><navPoint id='child'><navLabel><text>附注</text></navLabel><content src='Text/a.xhtml#local'/></navPoint></navPoint><navPoint id='second'><navLabel><text>第二章</text></navLabel><content src='Text/b.xhtml#%E6%B3%A8%E9%87%8A'/></navPoint></navMap></ncx>")
    (nnepub-test--write
     source "OEBPS/Text/a.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Fallback A</title></head><body><h1 id='start'>第一章正文</h1><p>中文内容 α</p><a href='b.xhtml#%E6%B3%A8%E9%87%8A'>下一章</a><a href='#local'>本章脚注</a><a href='notes.xhtml#note'>附录脚注</a><a href='https://example.com/'>外部链接</a><p id='local'>本地脚注</p><img src='../images/tiny.png' alt='插图'/><img src='../images/tiny.png' alt='重复图片'/><svg xmlns='http://www.w3.org/2000/svg'><image xmlns:xlink='http://www.w3.org/1999/xlink' xlink:href='../images/tiny.png'/></svg></body></html>")
    (nnepub-test--write
     source "OEBPS/Text/b.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Fallback B</title></head><body><h1>第二章正文</h1><p id='注释'>脚注目标</p><a href='a.xhtml#start'>返回第一章</a></body></html>")
    (nnepub-test--write
     source "OEBPS/Text/notes.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>附录</title></head><body><p id='note'>附录正文</p></body></html>")
    (make-directory (expand-file-name "OEBPS/images" source))
    (let ((coding-system-for-write 'binary))
      (with-temp-file (expand-file-name "OEBPS/images/tiny.png" source)
        (set-buffer-multibyte nil)
        (insert nnepub-test--png)))
    (when (file-exists-p archive) (delete-file archive))
    (with-temp-buffer
      (should (eq 0 (call-process nnepub-7z-program nil t nil "a" "-tzip" "-bd" "-bb0"
                                  archive "mimetype" "META-INF" "OEBPS"))))
    (delete-directory source t)
    archive))

(ert-deftest nnepub-test-directory-books-and-spine-order ()
  (nnepub-test--with-library
    (nnepub-test--book 3)
    (nnepub-test--book 2 "second.epub" t)
    (should (nnepub-open-server "library" `((nnepub-directory ,default-directory))))
    (should (= 2 (length nnepub--books)))
    (should (nnepub-request-list "library"))
    (should (= 2 (with-current-buffer nntp-server-buffer (count-lines (point-min) (point-max)))))
    (dolist (book nnepub--books)
      (should (equal (nnepub--book-title book) "测试书籍"))
      (should (equal (nnepub--book-author book) "作者甲, 作者乙"))
      (let* ((chapters (nnepub--book-chapters book))
             (reverse (string-suffix-p "second.epub" (nnepub--book-file book)))
             (group (nnepub--book-group book)))
        (should (equal (mapcar (lambda (item) (plist-get item :title)) (seq-take chapters 2))
                       (if reverse '("第二章" "第一章") '("第一章" "第二章"))))
        (should (equal (mapcar (lambda (item) (plist-get item :number)) chapters)
                       (number-sequence 1 (length chapters))))
        (should (nnepub-request-group group "library"))
        (should (eq 'nov (nnepub-retrieve-headers '(1 . 2) group "library")))
        (with-current-buffer nntp-server-buffer
          (goto-char (point-min))
          (let ((header (nnheader-parse-nov)))
            (should (= 1 (mail-header-number header)))
            (should (equal (mail-header-subject header) (if reverse "第二章" "第一章")))))))))

(ert-deftest nnepub-test-html-links-and-related-images ()
  (nnepub-test--with-library
    (nnepub-test--book)
    (should (nnepub-open-server default-directory))
    (let* ((book (car nnepub--books))
           (chapter (car (nnepub--book-chapters book)))
           (group (nnepub--book-group book))
           (html (nnepub--html book chapter "nnepub+library:book")))
      (should (= 1 (length (cdr html))))
      (should (string-match-p "cid:" (car html)))
      (should-not (string-match-p "<svg" (car html)))
      (should (string-match-p "https://example.com/" (car html)))
      (should (string-match-p (regexp-quote "#%E6%B3%A8%E9%87%8A") (car html)))
      (should (nnepub-request-article 1 group default-directory))
      (let (handles)
        (unwind-protect
            (with-current-buffer nntp-server-buffer
              (setq handles (mm-dissect-buffer t))
              (should (equal (car handles) "multipart/related"))
              (let ((body (decode-coding-string (mm-get-part (cadr handles)) 'utf-8)))
                (should (string-match-p "中文内容 α" body))
                (should (string-match-p "nnepub:" body)))
              (should (equal (mm-get-part (caddr handles)) nnepub-test--png)))
          (when handles (mm-destroy-parts handles))))
      (let ((destination (generate-new-buffer " *nnepub-destination*")))
        (unwind-protect
            (progn
              (should (equal (nnepub-request-article (nnepub--message-id book 2)
                                                     group default-directory destination)
                             (cons group 2)))
              (with-current-buffer destination (should (string-match-p "Message-ID:" (buffer-string)))))
          (kill-buffer destination))))))

(ert-deftest nnepub-test-large-manifest-keeps-spine-order-titles-and-supplements ()
  (nnepub-test--with-library
    (let ((file (nnepub-test--book))
          (extract (symbol-function 'nnepub--extract))
          (count 200)
          book)
      (unwind-protect
          (progn
            ;; Extend the extracted EPUB fixture with many resources in a
            ;; manifest order different from their reading order.
            (cl-letf (((symbol-function 'nnepub--extract)
                       (lambda (file root)
                         (funcall extract file root)
                         (let (items refs links)
                           (dotimes (offset count)
                             (let ((n (1+ offset)))
                               (nnepub-test--write root (format "OEBPS/Text/c%d.xhtml" n)
                                                   (format "<html><head><title>Fallback %d</title></head><body><p>Text</p></body></html>" n))
                               (push (format "<item id='c%d' href='Text/c%d.xhtml' media-type='application/xhtml+xml'/>" n n) items)
                               (push (format "<itemref idref='c%d'/>" n) refs)
                               (when (cl-evenp n)
                                 (push (format "<a href='Text/c%d.xhtml'>TOC %d</a>" n n) links))))
                           (with-temp-buffer
                             (insert-file-contents (expand-file-name "OEBPS/book.opf" root))
                             (goto-char (point-min))
                             (search-forward "</manifest>")
                             (replace-match (concat (apply #'concat (nreverse items)) "</manifest>") t t)
                             (re-search-forward "<spine[^>]*>.*?</spine>")
                             (replace-match (concat "<spine>" (apply #'concat refs)
                                                    "<itemref idref='image'/><itemref idref='c1'/></spine>") t t)
                             (write-region (point-min) (point-max) (expand-file-name "OEBPS/book.opf" root) nil 'silent))
                           (with-temp-buffer
                             (insert-file-contents (expand-file-name "OEBPS/nav.xhtml" root))
                             (goto-char (point-min))
                             (search-forward "<nav epub:type='toc'>")
                             (insert (apply #'concat links))
                             (write-region (point-min) (point-max) (expand-file-name "OEBPS/nav.xhtml" root) nil 'silent))))))
              (setq book (nnepub--load-book file (nnepub--file-signature file))))
            (let ((chapters (nnepub--book-chapters book)))
              (should (equal (mapcar (lambda (item) (plist-get item :id)) chapters)
                             (append (mapcar (lambda (n) (format "c%d" n)) (number-sequence count 1 -1))
                                     '("image" "a" "b" "notes" "nav"))))
              (should (equal (mapcar (lambda (item) (plist-get item :number)) chapters)
                             (number-sequence 1 (+ count 5))))
              (should (equal (mapcar (lambda (item) (plist-get item :title)) (seq-take chapters count))
                             (mapcar (lambda (n) (format (if (cl-evenp n) "TOC %d" "Fallback %d") n))
                                     (number-sequence count 1 -1))))
              (should (equal (mapcar (lambda (item) (plist-get item :title)) (nthcdr count chapters))
                             '("tiny" "第一章" "第二章" "附录" "目录")))
              ;; Repeated spine positions retain their order for progress,
              ;; while the chapter list presents each resource once.
              (should (= (+ count 2) (length (nnepub--book-spine book))))
              (should (equal (car (last (nnepub--book-spine book))) (plist-get (nth (1- count) chapters) :path)))))
        (when book (nnepub--dispose-book book))))))

(ert-deftest nnepub-test-cache-versioning-and-cleanup ()
  (nnepub-test--with-library
    (let ((file (nnepub-test--book)))
      (should (nnepub-open-server default-directory))
      (let* ((old (car nnepub--books))
             (group (nnepub--book-group old))
             (root (nnepub--book-root old)))
        (should (nnepub-request-list default-directory))
        (should (eq old (car nnepub--books)))
        (nnepub-test--book 3 nil t)
        (should (nnepub-request-scan nil default-directory))
        (should-not (equal group (nnepub--book-group (car nnepub--books))))
        (should-not (file-exists-p root))
        (should-not (nnepub-request-article 1 group default-directory))
        (let ((new-root (nnepub--book-root (car nnepub--books))))
          (should (nnepub-close-server default-directory))
          (should-not (file-exists-p new-root)))
        (should (nnepub-open-server default-directory))
        (should (equal (nnepub--book-file (car nnepub--books)) file))))))

(ert-deftest nnepub-test-switch-servers-and-close-all ()
  (nnepub-test--with-library
    (nnepub-test--book)
    (let ((other (expand-file-name "other")))
      (make-directory other)
      (let ((default-directory (file-name-as-directory other))) (nnepub-test--book 2))
      (should (nnepub-open-server "first" `((nnepub-directory ,default-directory))))
      (let* ((first-book (car nnepub--books))
             (first-root (nnepub--book-root first-book)))
        (should (nnepub-open-server "second" `((nnepub-directory ,other))))
        (let ((second-root (nnepub--book-root (car nnepub--books))))
          (should (nnepub-request-list "first"))
          (should (eq first-book (car nnepub--books)))
          (should (nnepub-request-close))
          (should-not (file-exists-p first-root))
          (should-not (file-exists-p second-root)))))))

(ert-deftest nnepub-test-invalid-book-failure-cleans-extraction ()
  (nnepub-test--with-library
    (let ((file (nnepub-test--book)) roots)
      (let ((original (symbol-function 'make-temp-file)))
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (prefix &rest arguments)
                     (let ((path (apply original prefix arguments)))
                       (when (equal prefix "nnepub-") (push path roots))
                       path)))
                  ((symbol-function 'nnepub--navigation)
                   (lambda (&rest _) (error "Broken navigation"))))
          (should-error (nnepub--load-book file (nnepub--file-signature file)))))
      (should (cl-every (lambda (root) (not (file-exists-p root))) roots))
      (should (file-exists-p file)))))

(ert-deftest nnepub-test-corrupt-and-deleted-books-do-not-block-the-library ()
  (nnepub-test--with-library
    (let ((file (nnepub-test--book)))
      (nnepub-test--write default-directory "broken.epub" "Not a ZIP archive")
      (should (nnepub-open-server default-directory))
      (should (= 1 (length nnepub--books)))
      (let ((root (nnepub--book-root (car nnepub--books))))
        (delete-file file)
        (should (nnepub-request-list default-directory))
        (should-not nnepub--books)
        (should-not (file-exists-p root))
        (with-current-buffer nntp-server-buffer (should (= 0 (buffer-size))))))))

(ert-deftest nnepub-test-local-path-and-fragment-handling ()
  (zr-test-with-temp-directory
    (let* ((root default-directory)
           (base (expand-file-name "Text/chapter.xhtml" root)))
      (make-directory (file-name-directory base))
      (should (equal (nnepub--resolve root base "../Text/%E4%B8%AD%E6%96%87.xhtml#%E6%B3%A8%E9%87%8A")
                     (cons (expand-file-name "Text/中文.xhtml" root) "注释")))
      (should (equal (nnepub--resolve root base "#local") (cons base "local")))
      (should-error (nnepub--resolve root base "../../outside.xhtml"))
      (should-error (nnepub--resolve root base "https://example.com/book.xhtml"))
      (with-temp-buffer
        (insert "before target after")
        (put-text-property 8 14 'shr-target-id '("target" "alias"))
        (nnepub--goto-fragment "alias")
        (should (= (point) 8))
        (should-error (nnepub--goto-fragment "missing") :type 'user-error)))))

(ert-deftest nnepub-test-rejects-remote-input-and-posting ()
  (should-not (nnepub-open-server "remote" '((nnepub-directory "/ssh:host:/books/"))))
  (should-not (nnepub-request-post)))

(ert-deftest nnepub-test-path-cache-retains-symlink-and-directory-boundaries ()
  (zr-test-with-temp-directory
    (let* ((root (expand-file-name "book/"))
           (outside (expand-file-name "book-other/"))
           (base (expand-file-name "chapter.xhtml" root)))
      (nnepub-test--write root "Text/inside.xhtml" "inside")
      (nnepub-test--write outside "outside.xhtml" "outside")
      (condition-case nil
          (progn
            (make-symbolic-link outside (expand-file-name "escape" root))
            (make-symbolic-link (expand-file-name "outside.xhtml" outside) (expand-file-name "file-link.xhtml" root))
            (make-symbolic-link (expand-file-name "Text/" root) (expand-file-name "internal" root)))
        (file-error (ert-skip "Symbolic links are unavailable")))
      (dolist (nnepub--path-cache (list nil (make-hash-table :test #'equal)))
        (should (nnepub--resolve root base "Text/inside.xhtml"))
        (should (nnepub--resolve root base "internal/inside.xhtml"))
        (should-error (nnepub--resolve root base "escape/outside.xhtml"))
        (should-error (nnepub--resolve root base "file-link.xhtml"))
        (should-error (nnepub--resolve root base "../book-other/outside.xhtml")))
      ;; No stale validation survives the indexing scope.
      (delete-file (expand-file-name "Text/inside.xhtml" root))
      (make-symbolic-link (expand-file-name "outside.xhtml" outside) (expand-file-name "Text/inside.xhtml" root))
      (should-error (nnepub--resolve root base "Text/inside.xhtml")))))

(ert-deftest nnepub-test-gnus-reading-links-and-persistent-marks ()
  ;; A fresh Gnus session exercises actual NOV parsing, MIME rendering,
  ;; subscriptions, chapter links and saving/reloading marks.
  (nnepub-test--with-library
    (let* ((_file (nnepub-test--book))
           (workspace default-directory)
           (form
            `(progn
               (require 'gnus)
               (require 'gnus-group)
               (require 'gnus-sum)
               (require 'gnus-srvr)
               (require 'nnepub)
               (setq nnepub-7z-program ,nnepub-7z-program
                     gnus-directory ,(expand-file-name "News" workspace)
                     gnus-home-directory ,workspace
                     gnus-startup-file ,(expand-file-name ".newsrc" workspace)
                     gnus-init-file nil gnus-site-init-file nil
                     gnus-select-method '(nnnil "")
                     gnus-secondary-select-methods
                     '((nnepub "library" (nnepub-directory ,workspace)))
                     gnus-use-dribble-file nil
                     shr-use-fonts nil
                     gnus-article-fill-column 72
                     gnus-save-newsrc-file t)
               (gnus-no-server)
               (gnus-group-browse-foreign-server
                '(nnepub "library" (nnepub-directory ,workspace)))
               (let ((group (gnus-browse-group-name)))
                 (unless group (error "The EPUB was not listed by Gnus' server browser"))
                 (when (> (gnus-group-level group) gnus-level-subscribed)
                   (gnus-browse-toggle-subscription-at-point 1)
                   (goto-char (point-min)))
                 (gnus-browse-read-group)
                 (with-current-buffer gnus-summary-buffer
                   (unless (and (derived-mode-p 'gnus-summary-mode)
                                (not gnus-show-threads)
                                (eq mm-text-html-renderer 'nnepub--render-html))
                     (error "EPUB group parameters: mode=%S threads=%S renderer=%S group=%S params=%S"
                            major-mode gnus-show-threads mm-text-html-renderer
                            gnus-newsgroup-name gnus-parameters))
                   (gnus-summary-goto-subject 1 t)
                   (gnus-summary-select-article nil nil nil 1)
                   ;; Exercise Gnus' settings through the actual MIME display
                   ;; pipeline, including a group-dependent blocking function.
                   (let ((render (symbol-function 'shr-insert-document)))
                     (dolist (inhibit '(t nil))
                       (let* ((observed nil)
                              (blocked-group nil)
                              (gnus-inhibit-images inhibit)
                              (gnus-blocked-images
                               (lambda (name)
                                 (setq blocked-group name)
                                 "\\`https://example.com/")))
                         (cl-letf (((symbol-function 'shr-insert-document)
                                    (lambda (document)
                                      (setq observed (list shr-inhibit-images shr-blocked-images))
                                      (funcall render document))))
                           (gnus-summary-select-article nil 'force nil 1))
                         (unless (and (equal observed (list inhibit "\\`https://example.com/"))
                                      (equal blocked-group group))
                           (error "Gnus image settings did not reach shr: %S" observed))))))
                 (with-current-buffer gnus-article-buffer
                   (goto-char (point-min))
                   (unless (search-forward "中文内容 α" nil t)
                     (error "HTML body was not rendered: %S" (buffer-string)))
                   (goto-char (point-min))
                   (unless (search-forward "下一章" nil t) (error "Chapter link was not rendered"))
                   (backward-char)
                   (nnepub-follow-link))
                 (with-current-buffer gnus-article-buffer
                   (unless (looking-at "脚注目标") (error "Did not reach the chapter anchor")))
                 (with-current-buffer gnus-summary-buffer (gnus-summary-exit))
                 (gnus-save-newsrc-file)
                 (unless (memq 1 (range-uncompress (gnus-info-read (gnus-get-info group))))
                   (error "Article read mark was not saved"))
                 (nnepub-request-close)
                 (princ "nnepub-integration-ok")))))
      (dolist (session
               (list form
                     (append
                      (butlast form)
                      (list '(let ((group (gnus-browse-group-name)))
                               (gnus-browse-read-group)
                               (unless (cl-subsetp '(1 2) (range-uncompress
                                                          (gnus-info-read (gnus-get-info group))))
                                 (error "Read marks were not restored after restarting Gnus"))
                               (nnepub-request-close)
                               (princ "nnepub-integration-ok"))))))
        (with-temp-buffer
          (let ((status (call-process invocation-name nil t nil "--batch" "-Q" "-L" nnepub-test--root
                                      "--eval" (prin1-to-string session))))
            (ert-info ((buffer-string))
              (should (eq status 0))
              (should (string-match-p "nnepub-integration-ok" (buffer-string))))))))))

(ert-deftest nnepub-test-nndoc-epub-types-mime-and-cleanup ()
  (nnepub-test--with-library
    (let ((gnus-parameters (copy-tree gnus-parameters)))
      (dolist (version '(2 3))
        (let* ((file (nnepub-test--book version (format "book%d.EPUB" version)))
               (digest (nnepub--fingerprint file))
               document root parameters)
          (unwind-protect
              (progn
                (should (nndoc-open-server file `((nndoc-address ,file))))
                (should (nndoc-request-group "book" file))
                (setq document nndoc-current-buffer
                      root (nnepub--book-root
                            (buffer-local-value 'zr-nndoc-epub--book document))
                      parameters (buffer-local-value 'zr-nndoc-epub--parameters document))
                (should (eq nndoc-article-type 'epub))
                (should (equal (mapcar #'car nndoc-dissection-alist)
                               (if (= version 2) '(1 2 3) '(1 2 3 4))))
                (with-current-buffer document
                  (should (equal (secure-hash 'sha256 (current-buffer)) digest)))
                (should (eq (nndoc-retrieve-headers '(1 2) "book" file) 'headers))
                (with-current-buffer nntp-server-buffer
                  (should (string-match-p "第一章" (rfc2047-decode-string (buffer-string)))))
                (should (nndoc-request-article 1 "book" file))
                (let (handles)
                  (unwind-protect
                      (with-current-buffer nntp-server-buffer
                        (setq handles (mm-dissect-buffer t))
                        (should (equal (car handles) "multipart/related"))
                        (let ((html (decode-coding-string (mm-get-part (cadr handles)) 'utf-8)))
                          (should (string-match-p "中文内容 α" html))
                          (should (string-match-p "/2#%E6%B3%A8%E9%87%8A" html)))
                        (should (equal (mm-get-part (caddr handles)) nnepub-test--png)))
                    (when handles (mm-destroy-parts handles))))
                (should (nndoc-close-group "book" file))
                (should-not (buffer-live-p document))
                (should-not (file-exists-p root))
                (should-not (member parameters gnus-parameters))
                (should (equal digest (nnepub--fingerprint file))))
            (when (buffer-live-p document) (kill-buffer document))
            (nndoc-close-server file)))))))

(ert-deftest nnepub-test-nndoc-preserves-other-document-types ()
  (nnepub-test--with-library
    (let* ((file (expand-file-name "mail.mbox"))
           (parameters (copy-tree gnus-parameters))
           document)
      (nnepub-test--write default-directory "mail.mbox"
                          "From sender@example.com Mon Nov  9 00:00:00 2026\nSubject: Ordinary mail\nFrom: sender@example.com\n\nMail body\n")
      (unwind-protect
          (progn
            (should (nndoc-open-server file `((nndoc-address ,file))))
            (should (nndoc-request-group "mail" file))
            (setq document nndoc-current-buffer)
            (should (eq nndoc-article-type 'mbox))
            (should-not (buffer-local-value 'zr-nndoc-epub--book document))
            (should (equal gnus-parameters parameters))
            (should (nndoc-request-article 1 "mail" file))
            (with-current-buffer nntp-server-buffer
              (should (string-match-p "Mail body" (buffer-string)))))
        (when (buffer-live-p document) (kill-buffer document))
        (nndoc-close-server file)))))

(ert-deftest nnepub-test-nndoc-gnus-single-file-and-ephemeral-reading ()
  (nnepub-test--with-library
    (let* ((file (nnepub-test--book))
           (workspace default-directory)
           (form
            `(progn
               (require 'gnus-group)
               (require 'gnus-sum)
               (require 'zr-nndoc-epub)
               (setq nnepub-7z-program ,nnepub-7z-program
                     gnus-directory ,(expand-file-name "News" workspace)
                     gnus-home-directory ,workspace
                     gnus-startup-file ,(expand-file-name ".newsrc" workspace)
                     gnus-init-file nil gnus-site-init-file nil
                     gnus-select-method '(nnnil "")
                     gnus-secondary-select-methods nil
                     gnus-use-dribble-file nil shr-use-fonts nil
                     gnus-article-fill-column 72)
               (gnus-no-server)
               ;; G f creates a regular nndoc group; the second entry
               ;; uses Gnus' existing ephemeral group mechanism.
               (dolist (ephemeral '(nil t))
                 (let* ((group
                         (if ephemeral
                             (gnus-group-read-ephemeral-group
                              "temporary-epub" '(nndoc ,file) t)
                           (gnus-group-make-doc-group ,file nil)
                           (let ((name (gnus-group-group-name)))
                             (gnus-group-read-group t nil name)
                             name)))
                        (document nndoc-current-buffer)
                        (root (nnepub--book-root
                               (buffer-local-value 'zr-nndoc-epub--book document))))
                   (unless group (error "Could not enter the EPUB document group"))
                   (unless (eq (not (null (gnus-ephemeral-group-p group))) ephemeral)
                     (error "Wrong document group lifetime: %S" group))
                   (with-current-buffer gnus-summary-buffer
                     (unless (and (not gnus-show-threads)
                                  (eq mm-text-html-renderer 'nnepub--render-html)
                                  (equal (mail-header-subject
                                          (cl-find 1 gnus-newsgroup-headers
                                                   :key #'mail-header-number))
                                         "第一章"))
                       (error "nndoc EPUB: threads=%S renderer=%S group=%S parameters=%S headers=%S"
                              gnus-show-threads mm-text-html-renderer group gnus-parameters
                              gnus-newsgroup-headers))
                     (gnus-summary-goto-article 1 nil t)
                     (let ((render (symbol-function 'shr-insert-document)) observed)
                       (let ((gnus-inhibit-images t)
                             (gnus-blocked-images "example.com"))
                         (cl-letf (((symbol-function 'shr-insert-document)
                                    (lambda (document)
                                      (setq observed (list shr-inhibit-images shr-blocked-images))
                                      (funcall render document))))
                           (gnus-summary-select-article nil 'force nil 1)))
                       (unless (equal observed '(t "example.com"))
                         (error "nndoc EPUB did not honor Gnus image settings"))))
                   (with-current-buffer gnus-article-buffer
                     (unless (string-match-p "中文内容 α" (buffer-string))
                       (error "EPUB text was not rendered")))
                   ;; Include a link to an article hidden by a summary limit.
                   (with-current-buffer gnus-summary-buffer
                     (gnus-summary-limit '(1)))
                   (dolist (step '(("本章脚注" "本地脚注")
                                   ("附录脚注" "附录正文")
                                   ("下一章" "脚注目标")))
                     (with-current-buffer gnus-summary-buffer
                       (gnus-summary-goto-article 1 nil t))
                     (with-current-buffer gnus-article-buffer
                       (goto-char (point-min))
                       (unless (search-forward (car step) nil t)
                         (error "Missing EPUB link: %S" step))
                       (backward-char)
                       (nnepub-follow-link))
                     (with-current-buffer gnus-article-buffer
                       (unless (looking-at (concat "[[:space:]]*" (regexp-quote (cadr step))))
                         (error "EPUB link target: step=%S point=%S text=%S id=%S"
                                step (point)
                                (buffer-substring-no-properties
                                 (point) (min (point-max) (+ (point) 80)))
                                (get-text-property (point) 'shr-target-id)))))
                   (with-current-buffer gnus-summary-buffer (gnus-summary-exit))
                   (when (or (buffer-live-p document) (file-exists-p root))
                     (error "nndoc EPUB extraction survived leaving its group"))
                   (when (and ephemeral (assoc group gnus-newsrc-alist))
                     (error "The temporary EPUB group became a persistent subscription"))))
               (princ "nndoc-epub-integration-ok"))))
      (with-temp-buffer
        (let ((status (call-process invocation-name nil t nil "--batch" "-Q" "-L" nnepub-test--root
                                    "--eval" (prin1-to-string form))))
          (ert-info ((buffer-string))
            (should (eq status 0))
            (should (string-match-p "nndoc-epub-integration-ok" (buffer-string)))))))))

(provide 'nnepub-test)
;;; nnepub-test.el ends here
