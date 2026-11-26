;;; zr-epub-test.el --- Tests for EPUB parsing and Gnus documents -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-epub)
(require 'zr-nndoc-epub)
(require 'gnus-sum)
(require 'zr-test-helpers)

(defconst zr-epub-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defconst zr-epub-test--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII="))

(defmacro zr-epub-test--with-fixture (&rest body)
  (declare (indent 0) (debug t))
  `(let ((zr-epub-7z-program (or (getenv "ZR_EPUB_TEST_7Z")
                              (executable-find "7zz") (executable-find "7z"))))
     (skip-unless (and zr-epub-7z-program (libxml-available-p)))
     (zr-test-with-temp-directory
       (let ((nnoo-state-alist (copy-tree nnoo-state-alist))
             (nnoo-definition-alist (copy-tree nnoo-definition-alist))
             (nndoc-article-type 'guess)
             (nndoc-address nil)
             (nndoc-current-buffer nil)
             (nndoc-group-alist nil)
             (nndoc-dissection-alist nil)
             (nntp-server-buffer (generate-new-buffer " *zr-epub-test-server*")))
         (unwind-protect (progn ,@body)
           (kill-buffer nntp-server-buffer))))))

(defun zr-epub-test--write (root path text)
  (let ((file (expand-file-name path root))
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun zr-epub-test--book (&optional version name reverse-spine)
  "Create a real zipped EPUB in the current directory and return its path."
  (let* ((version (or version 3))
         (archive (expand-file-name (or name "测试 book.epub")))
         (source (make-temp-file (expand-file-name "source-" default-directory) t))
         (default-directory source)
         (nav (if (= version 3) "nav" "ncx")))
    (zr-epub-test--write source "mimetype" "application/epub+zip")
    (zr-epub-test--write
     source "META-INF/container.xml"
     "<?xml version='1.0'?><container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile media-type='text/plain' full-path='ignored'/><rootfile full-path='OEBPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>")
    (zr-epub-test--write
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
    (zr-epub-test--write
     source "OEBPS/nav.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head><title>目录</title></head><body><nav epub:type='page-list'><a href='Text/a.xhtml'>错误标题</a></nav><nav epub:type='toc'><ol><li><a href='Text/a.xhtml#start'>第一章</a><ol><li><a href='Text/a.xhtml#local'>附注</a></li></ol></li><li><a href='Text/b.xhtml#%E6%B3%A8%E9%87%8A'>第二章</a></li></ol></nav></body></html>")
    (zr-epub-test--write
     source "OEBPS/toc.ncx"
     "<ncx xmlns='http://www.daisy.org/z3986/2005/ncx/'><navMap><navPoint id='first'><navLabel><text>第一章</text></navLabel><content src='Text/a.xhtml#start'/><navPoint id='child'><navLabel><text>附注</text></navLabel><content src='Text/a.xhtml#local'/></navPoint></navPoint><navPoint id='second'><navLabel><text>第二章</text></navLabel><content src='Text/b.xhtml#%E6%B3%A8%E9%87%8A'/></navPoint></navMap></ncx>")
    (zr-epub-test--write
     source "OEBPS/Text/a.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Fallback A</title></head><body><h1 id='start'>第一章正文</h1><p>中文内容 α</p><a href='b.xhtml#%E6%B3%A8%E9%87%8A'>下一章</a><a href='#local'>本章脚注</a><a href='notes.xhtml#note'>附录脚注</a><a href='https://example.com/'>外部链接</a><p id='local'>本地脚注</p><img src='../images/tiny.png' alt='插图'/><img src='../images/tiny.png' alt='重复图片'/><svg xmlns='http://www.w3.org/2000/svg'><image xmlns:xlink='http://www.w3.org/1999/xlink' xlink:href='../images/tiny.png'/></svg></body></html>")
    (zr-epub-test--write
     source "OEBPS/Text/b.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Fallback B</title></head><body><h1>第二章正文</h1><p id='注释'>脚注目标</p><a href='a.xhtml#start'>返回第一章</a></body></html>")
    (zr-epub-test--write
     source "OEBPS/Text/notes.xhtml"
     "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>附录</title></head><body><p id='note'>附录正文</p></body></html>")
    (make-directory (expand-file-name "OEBPS/images" source))
    (let ((coding-system-for-write 'binary))
      (with-temp-file (expand-file-name "OEBPS/images/tiny.png" source)
        (set-buffer-multibyte nil)
        (insert zr-epub-test--png)))
    (when (file-exists-p archive) (delete-file archive))
    (with-temp-buffer
      (should (eq 0 (call-process zr-epub-7z-program nil t nil "a" "-tzip" "-bd" "-bb0"
                                  archive "mimetype" "META-INF" "OEBPS"))))
    (delete-directory source t)
    archive))

(ert-deftest zr-epub-test-open-epub2-and-epub3-without-gnus ()
  (zr-epub-test--with-fixture
    (dolist (version '(2 3))
      (let* ((file (zr-epub-test--book version (format "book%d.epub" version) (= version 2)))
             (form `(progn
                      (require 'zr-epub)
                      (setq zr-epub-7z-program ,zr-epub-7z-program)
                      (let ((book (zr-epub-open ,file)))
                        (unwind-protect
                            (let ((chapter (zr-epub-chapter book 1)))
                              (unless (and (not (featurep 'gnus)) (not (featurep 'nnoo))
                                           (equal (zr-epub-book-title book) "测试书籍")
                                           (equal (zr-epub-book-author book) "作者甲, 作者乙")
                                           (equal (plist-get chapter :title) ,(if (= version 2) "第二章" "第一章"))
                                           (= (length (zr-epub-book-chapters book)) ,(if (= version 2) 3 4))
                                           (string-match-p "<html" (zr-epub-chapter-html book chapter)))
                                (error "EPUB parsing or library isolation failed")))
                          (zr-epub-close book))))))
        (with-temp-buffer
          (let ((status (call-process invocation-name nil t nil "--batch" "-Q"
                                      "-L" (expand-file-name ".." zr-epub-test--root)
                                      "--eval" (prin1-to-string form))))
            (ert-info ((buffer-string)) (should (eq status 0)))))))))

(ert-deftest zr-epub-test-large-manifest-keeps-spine-order-titles-and-supplements ()
  (zr-epub-test--with-fixture
    (let ((file (zr-epub-test--book))
          (extract (symbol-function 'zr-epub--extract))
          (count 200)
          book)
      (unwind-protect
          (progn
            ;; Extend the extracted EPUB fixture with many resources in a
            ;; manifest order different from their reading order.
            (cl-letf (((symbol-function 'zr-epub--extract)
                       (lambda (file root)
                         (funcall extract file root)
                         (let (items refs links)
                           (dotimes (offset count)
                             (let ((n (1+ offset)))
                               (zr-epub-test--write root (format "OEBPS/Text/c%d.xhtml" n)
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
              (setq book (zr-epub-open file)))
            (let ((chapters (zr-epub-book-chapters book)))
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
              (should (= (+ count 2) (length (zr-epub-book-spine book))))
              (should (equal (car (last (zr-epub-book-spine book))) (plist-get (nth (1- count) chapters) :path)))))
        (when book (zr-epub-close book))))))

(ert-deftest zr-epub-test-invalid-book-failure-cleans-extraction ()
  (zr-epub-test--with-fixture
    (let ((file (zr-epub-test--book)) roots)
      (let ((original (symbol-function 'make-temp-file)))
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (prefix &rest arguments)
                     (let ((path (apply original prefix arguments)))
                       (when (equal prefix "zr-epub-") (push path roots))
                       path)))
                  ((symbol-function 'zr-epub--navigation)
                   (lambda (&rest _) (error "Broken navigation"))))
          (should-error (zr-epub-open file))))
      (should (cl-every (lambda (root) (not (file-exists-p root))) roots))
      (should (file-exists-p file)))))

(ert-deftest zr-epub-test-local-path-and-fragment-handling ()
  (zr-test-with-temp-directory
    (let* ((root default-directory)
           (base (expand-file-name "Text/chapter.xhtml" root)))
      (make-directory (file-name-directory base))
      (should (equal (zr-epub-resolve root base "../Text/%E4%B8%AD%E6%96%87.xhtml#%E6%B3%A8%E9%87%8A")
                     (cons (expand-file-name "Text/中文.xhtml" root) "注释")))
      (should (equal (zr-epub-resolve root base "#local") (cons base "local")))
      (should-error (zr-epub-resolve root base "../../outside.xhtml"))
      (should-error (zr-epub-resolve root base "https://example.com/book.xhtml"))
      (with-temp-buffer
        (insert "before target after")
        (put-text-property 8 14 'shr-target-id '("target" "alias"))
        (zr-gnus-epub--goto-fragment "alias")
        (should (= (point) 8))
        (should-error (zr-gnus-epub--goto-fragment "missing") :type 'user-error)))))

(ert-deftest zr-epub-test-shared-article-buffer-restores-renderer ()
  (with-temp-buffer
    (let ((gnus-summary-buffer (current-buffer))
          (mm-text-html-renderer 'shr))
      (dolist (local '(nil t))
        (setq-local zr-gnus-epub--reading t)
        (with-temp-buffer
          (when local (setq-local mm-text-html-renderer 'w3m))
          (zr-gnus-epub--article-renderer)
          (should (eq mm-text-html-renderer #'zr-gnus-epub--render-html))
          (should (eq (default-value 'mm-text-html-renderer) 'shr))
          (with-current-buffer gnus-summary-buffer
            (setq zr-gnus-epub--reading nil))
          (zr-gnus-epub--article-renderer)
          (should (eq (local-variable-p 'mm-text-html-renderer) local))
          (should (eq mm-text-html-renderer (if local 'w3m 'shr))))))))

(ert-deftest zr-epub-test-path-cache-retains-symlink-and-directory-boundaries ()
  (zr-test-with-temp-directory
    (let* ((root (expand-file-name "book/"))
           (outside (expand-file-name "book-other/"))
           (base (expand-file-name "chapter.xhtml" root)))
      (zr-epub-test--write root "Text/inside.xhtml" "inside")
      (zr-epub-test--write outside "outside.xhtml" "outside")
      (condition-case nil
          (progn
            (make-symbolic-link outside (expand-file-name "escape" root))
            (make-symbolic-link (expand-file-name "outside.xhtml" outside) (expand-file-name "file-link.xhtml" root))
            (make-symbolic-link (expand-file-name "Text/" root) (expand-file-name "internal" root)))
        (file-error (ert-skip "Symbolic links are unavailable")))
      (dolist (zr-epub--path-cache (list nil (make-hash-table :test #'equal)))
        (should (zr-epub-resolve root base "Text/inside.xhtml"))
        (should (zr-epub-resolve root base "internal/inside.xhtml"))
        (should-error (zr-epub-resolve root base "escape/outside.xhtml"))
        (should-error (zr-epub-resolve root base "file-link.xhtml"))
        (should-error (zr-epub-resolve root base "../book-other/outside.xhtml")))
      ;; No stale validation survives the indexing scope.
      (delete-file (expand-file-name "Text/inside.xhtml" root))
      (make-symbolic-link (expand-file-name "outside.xhtml" outside) (expand-file-name "Text/inside.xhtml" root))
      (should-error (zr-epub-resolve root base "Text/inside.xhtml")))))

(ert-deftest zr-epub-test-nndoc-epub-types-mime-and-cleanup ()
  (zr-epub-test--with-fixture
    (let* ((parameters '(("^unrelated" (gnus-show-threads t))))
           (gnus-parameters parameters))
      (dolist (version '(2 3))
        (let* ((file (zr-epub-test--book version (format "book%d.EPUB" version)))
               (digest (zr-epub-file-digest file))
               document root)
          (unwind-protect
              (progn
                (should (nndoc-open-server file `((nndoc-address ,file))))
                (should (nndoc-request-group "book" file))
                (setq document nndoc-current-buffer
                      root (zr-epub-book-root
                            (buffer-local-value 'zr-nndoc-epub--book document)))
                (should (eq gnus-parameters parameters))
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
                        (should (equal (mm-get-part (caddr handles)) zr-epub-test--png)))
                    (when handles (mm-destroy-parts handles))))
                (should (nndoc-close-group "book" file))
                (should-not (buffer-live-p document))
                (should-not (file-exists-p root))
                (should (eq gnus-parameters parameters))
                (should (equal digest (zr-epub-file-digest file))))
            (when (buffer-live-p document) (kill-buffer document))
            (nndoc-close-server file)))))))

(ert-deftest zr-epub-test-nndoc-preserves-other-document-types ()
  (zr-epub-test--with-fixture
    (let* ((file (expand-file-name "mail.mbox"))
           (parameters (copy-tree gnus-parameters))
           document)
      (zr-epub-test--write default-directory "mail.mbox"
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

(ert-deftest zr-epub-test-nndoc-gnus-single-file-and-ephemeral-reading ()
  (zr-epub-test--with-fixture
    (let* ((file (zr-epub-test--book))
           (workspace default-directory)
           (form
            `(progn
               (require 'gnus-group)
               (require 'gnus-sum)
               (require 'zr-nndoc-epub)
               (setq zr-epub-7z-program ,zr-epub-7z-program
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
                        (root (zr-epub-book-root
                               (buffer-local-value 'zr-nndoc-epub--book document))))
                   (unless group (error "Could not enter the EPUB document group"))
                   (unless (eq (not (null (gnus-ephemeral-group-p group))) ephemeral)
                     (error "Wrong document group lifetime: %S" group))
                   (with-current-buffer gnus-summary-buffer
                     (unless (and (not gnus-show-threads)
                                  zr-gnus-epub--reading
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
                                      (setq observed (list shr-inhibit-images shr-blocked-images
                                                           (buffer-local-value 'mm-text-html-renderer
                                                                               (get-buffer gnus-article-buffer))
                                                           (default-value 'mm-text-html-renderer)
                                                           shr-map))
                                      (funcall render document))))
                           (gnus-summary-select-article nil 'force nil 1)))
                       (unless (equal observed (list t "example.com" #'zr-gnus-epub--render-html
                                                     mm-text-html-renderer zr-gnus-epub--link-map))
                         (error "Wrong image settings or renderer scope: %S" (butlast observed)))))
                   (with-current-buffer gnus-article-buffer
                     (unless (eq mm-text-html-renderer #'zr-gnus-epub--render-html)
                       (error "EPUB renderer was not local to the article"))
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
                       (unless (eq (key-binding (kbd "RET")) #'zr-gnus-epub-follow-link)
                         (error "Missing EPUB link binding: %S" step))
                       (call-interactively #'zr-gnus-epub-follow-link))
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
        (let ((status (call-process invocation-name nil t nil "--batch" "-Q" "-L" zr-epub-test--root
                                    "-L" (expand-file-name ".." zr-epub-test--root)
                                    "--eval" (prin1-to-string form))))
          (ert-info ((buffer-string))
            (should (eq status 0))
            (should (string-match-p "nndoc-epub-integration-ok" (buffer-string)))))))))

(provide 'zr-epub-test)
