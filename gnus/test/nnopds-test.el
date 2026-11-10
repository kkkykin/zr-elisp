;;; nnopds-test.el --- OPDS catalogs and reading position tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nnopds)
(require 'nnopds-progress)
(require 'nnopds-koreader)
(require 'nnopds-browse)
(require 'gnus-cache)
(require 'zr-test-helpers)

(defconst nnopds-test--directory (file-name-directory (or load-file-name buffer-file-name)))
(defconst nnopds-test--load-path (file-name-directory (directory-file-name nnopds-test--directory)))

(defun nnopds-test--wait (predicate)
  "Wait up to ten seconds for PREDICATE, yielding process output."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro nnopds-test--with-server (&rest body)
  "Run BODY with a local OPDS server, connection and isolated cache."
  (declare (indent 0) (debug t))
  `(progn
     (unless (and (executable-find "python3") (executable-find "curl"))
       (ert-skip "Requires Python and curl"))
     (zr-test-with-temp-directory
       (let* ((opds-root default-directory)
              (output (generate-new-buffer " *opds-test-http*"))
              (process (make-process :name "opds-test-server" :buffer output :noquery t
                                     :command (list "python3" (expand-file-name "opds-server.py" nnopds-test--directory)
                                                    opds-root)))
              (nnoo-state-alist (copy-tree nnoo-state-alist))
              (nnoo-definition-alist (copy-tree nnoo-definition-alist))
              (nnopds-url nil) (nnopds-address nil) (nnopds-user nil) (nnopds-password nil) (nnopds-headers nil)
              (nnopds-auth-method 'basic)
              (nnopds-progress-protocol 'koreader)
              (nnopds-koreader-url nil) (nnopds-koreader-user nil) (nnopds-koreader-password nil)
              (nnopds--connection nil) (nnopds--group nil)
              (gnus-cache-directory (expand-file-name "cache" opds-root))
              (nnopds-request-timeout 2)
              (nnopds-catalog-cache-ttl nil)
              (nnopds-progress-sync-delay 60)
              (nntp-server-buffer (generate-new-buffer " *opds-test-server*")))
         (unwind-protect
             (progn
               (nnopds-test--wait (lambda () (file-readable-p (expand-file-name "port.txt" opds-root))))
               (let* ((opds-url (format "http://127.0.0.1:%s/catalog"
                                        (nnopds--read-bytes (expand-file-name "port.txt" opds-root))))
                      (connection (progn
                                    (should (nnopds-open-server "library"
                                                               `((nnopds-url ,opds-url)
                                                                 (nnopds-headers (("X-API-Key" . "test-key"))))))
                                    nnopds--connection)))
                 ,@body))
           (nnopds-request-close)
           (when (process-live-p process) (delete-process process))
           (kill-buffer output)
           (kill-buffer nntp-server-buffer))))))

(defun nnopds-test--requests (root &optional method)
  "Return recorded HTTP requests from ROOT, optionally filtering METHOD."
  (let ((file (expand-file-name "requests.jsonl" root)))
    (when (file-readable-p file)
      (cl-remove-if-not
       (lambda (request) (or (null method) (equal (plist-get request :method) method)))
       (mapcar (lambda (line) (json-parse-string line :object-type 'plist :array-type 'list
                                                :null-object nil :false-object nil))
               (split-string (nnopds--read-bytes file) "\n" t))))))

(defun nnopds-test--write (root name text)
  "Write fixture control TEXT to NAME in ROOT."
  (with-temp-file (expand-file-name name root) (insert text)))

(defun nnopds-test--publication (connection &optional number)
  "Load publication NUMBER from CONNECTION through the Gnus interface."
  (unless (and (or (executable-find "7zz") (executable-find "7z")) (libxml-available-p))
    (ert-skip "Requires 7-Zip and libxml"))
  (let* ((page (nnopds--catalog-page connection (nnopds--connection-url connection)))
         (entries (plist-get page :entries))
         (publications (delq nil (seq-mapcat
                                  (lambda (collection)
                                    (seq-map (lambda (document) (gethash document entries))
                                             (plist-get collection :publications)))
                                  (nnopds--collections (plist-get page :feed)))))
         (group (nnopds--publication-group (nth (or number 0) publications))))
    (should (nnopds-request-group group (nnopds--connection-name connection)))
    (gethash group (nnopds--connection-publications connection))))

(defmacro nnopds-test--with-browser (&rest body)
  "Run BODY in a Gnus OPDS browser using the enclosing fixture server."
  (declare (indent 0) (debug t))
  `(let ((gnus-directory (expand-file-name "News" opds-root))
         (gnus-home-directory opds-root) (gnus-startup-file (expand-file-name ".newsrc" opds-root))
         (gnus-init-file nil) (gnus-site-init-file nil) (gnus-use-dribble-file nil)
         (gnus-select-method '(nnnil "")) (gnus-save-newsrc-file nil) (gnus-check-new-newsgroups nil)
         (shr-use-fonts nil)
         (gnus-opened-servers nil) (gnus-server-alist nil) (gnus-server-method-cache nil)
         (gnus-ephemeral-servers nil)
         (gnus-newsrc-alist nil) (gnus-newsrc-hashtb nil)
         (gnus-cache-active-file (expand-file-name "active" gnus-cache-directory))
         (gnus-cache-active-hashtb nil) (gnus-cache-total-fetched-hashtb nil)
         (gnus-cache-active-altered nil)
         (gnus-group-buffer (generate-new-buffer-name " *opds-group*"))
         (gnus-browse-buffer (generate-new-buffer-name " *opds-browser*"))
         (gnus-browse-current-method nil) (gnus-browse-return-buffer nil)
         (gnus-secondary-select-methods
          (list (list 'nnopds "library" (list 'nnopds-url opds-url)
                      '(nnopds-headers (("X-API-Key" . "test-key")))))))
     (save-window-excursion
       (unwind-protect
           (progn
             (gnus)
             (should-not (nnopds-test--requests opds-root))
             (should (gnus-group-browse-foreign-server (car gnus-secondary-select-methods)))
             (setq connection nnopds--connection)
             ,@body)
         (gnus-close-backends)
         (when (get-buffer gnus-browse-buffer) (kill-buffer gnus-browse-buffer))
         (when (get-buffer gnus-group-buffer) (kill-buffer gnus-group-buffer))))))

(defun nnopds-test--at-link (url)
  "Move to the browser row linking to URL."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal url (get-text-property (point) 'nnopds-browse-link))))
    (forward-line 1))
  (should-not (eobp)))

(defun nnopds-test--at-book ()
  "Move to the first book row in the browser."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (get-text-property (point) 'nnopds-browse-book))) (forward-line 1))
  (should-not (eobp)))

(defmacro nnopds-test--with-reader (&rest body)
  "Run BODY with a loaded publication and a position state in BUFFER."
  (declare (indent 0) (debug t))
  `(let* ((publication (nnopds-test--publication connection))
          (buffer (generate-new-buffer " *opds-test-reader*"))
          (state (nnopds-progress--make-state :connection connection :publication publication
                                             :buffer buffer :verified t)))
     (push (cons (nnopds--publication-group publication) state) (nnopds--connection-readers connection))
     (unwind-protect
         (with-current-buffer buffer
           (gnus-summary-mode)
           (setq-local nnopds-progress--state state)
           ,@body)
       (nnopds-progress-close state)
       (kill-buffer buffer))))

(defmacro nnopds-test--with-koreader (kind &rest body)
  "Run BODY with explicitly configured KIND's OPDS and KOReader routes."
  (declare (indent 1) (debug t))
  `(nnopds-test--with-server
     (nnopds-close-server "library")
     (let* ((kind ,kind)
            (sync-url (nnopds--url (if (eq kind 'komga) "/komga/koreader" "/calibre/kosync") opds-url))
            (opds-url (nnopds--url (if (eq kind 'komga) "/komga/opds/v2/catalog" "/calibre/opds") opds-url))
            (connection
             (progn
               (when (eq kind 'calibre) (nnopds-test--write opds-root "digest-auth.txt" "enabled"))
               (should (nnopds-open-server
                        "library" `((nnopds-url ,opds-url)
                                    ,@(if (eq kind 'komga)
                                          '((nnopds-headers (("X-API-Key" . "komga-key"))))
                                        '((nnopds-user "reader") (nnopds-password "test-password") (nnopds-auth-method digest)))
                                    (nnopds-progress-protocol koreader)
                                    (nnopds-koreader-url ,sync-url)
                                    (nnopds-koreader-user ,(if (eq kind 'komga) "komga-key" "reader"))
                                    (nnopds-koreader-password ,(unless (eq kind 'komga) "test-password")))))
               nnopds--connection)))
       ,@body)))

(defun nnopds-test--select (number)
  "Simulate the article selection hook for NUMBER in the current summary."
  (setq-local gnus-current-article number)
  (nnopds-progress--selected))

(ert-deftest nnopds-test-catalog-navigation-pagination-and-lazy-download ()
  (nnopds-test--with-server
    (should (nnopds-request-scan nil "library"))
    (should (nnopds-request-list "library"))
    (should-not (nnopds-test--requests opds-root))
    (nnopds-test--with-browser
      (should (derived-mode-p 'nnopds-browse-mode))
      (should (= 1 (length (nnopds-test--requests opds-root))))
      (should (string-match-p "Recommended" (buffer-string)))
      (should (string-match-p "测试书籍 one" (buffer-string)))
      (nnopds-test--at-link (nnopds--url "/books" opds-url))
      (should-not (gnus-browse-group-name))
      (should-error (nnopds-browse-subscribe) :type 'user-error)
      (nnopds-browse-select)
      (should (= 2 (length (nnopds-test--requests opds-root))))
      (nnopds-test--at-link (nnopds--url "/books?page=2" opds-url))
      (nnopds-browse-select)
      (should (string-match-p "测试书籍 two" (buffer-string)))
      (should (= 2 (length (nnopds--connection-catalog connection))))
      (should (equal (mapcar (lambda (request) (plist-get request :path)) (nnopds-test--requests opds-root))
                     '("/catalog" "/books" "/books?page=2")))
      (should (cl-every (lambda (request) (equal (plist-get request :accept) "application/opds+json"))
                        (nnopds-test--requests opds-root)))
      (nnopds-browse-up)
      (nnopds-browse-up)
      (should (= 3 (length (nnopds-test--requests opds-root))))
      (nnopds-test--at-book)
      (let ((name (gnus-browse-group-name)))
        (nnopds-browse-subscribe)
        (should (equal name (gnus-browse-group-name)))
        (should (<= (gnus-group-level name) gnus-level-subscribed)))
      (should (= 3 (length (nnopds-test--requests opds-root))))
      (nnopds-close-server "library")
      (should (gnus-group-browse-foreign-server (car gnus-secondary-select-methods)))
      (nnopds-test--at-link (nnopds--url "/books" opds-url))
      (nnopds-browse-select)
      (nnopds-test--at-link (nnopds--url "/books?page=2" opds-url))
      (nnopds-browse-select)
      (should (= 3 (length (nnopds-test--requests opds-root)))))))

(ert-deftest nnopds-test-browser-reads-the-whole-book-without-chapter-limits ()
  (dolist (subscribe '(nil t))
    (nnopds-test--with-server
      (skip-unless (and (or (executable-find "7zz") (executable-find "7z")) (libxml-available-p)))
      (nnopds-test--with-browser
        (nnopds-test--at-book)
        (when subscribe (nnopds-browse-subscribe))
        (let ((gnus-large-newsgroup 1) (gnus-large-ephemeral-newsgroup 1))
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _args) (ert-fail "Reading a book prompted for a chapter limit"))))
            (nnopds-browse-read)
            (with-current-buffer gnus-summary-buffer
              (should (equal (mapcar #'mail-header-number gnus-newsgroup-headers) '(1 2 3 4)))
              (should (= gnus-current-article 1))
              (with-current-buffer gnus-article-buffer
                (should (string-match-p "中文内容 α" (buffer-string))))
              (gnus-summary-exit))))
        (should (equal (mapcar (lambda (request) (plist-get request :path)) (nnopds-test--requests opds-root))
                       '("/catalog" "/content/one.epub")))))))

(ert-deftest nnopds-test-directory-only-catalog-is-browsed-one-level-at-a-time ()
  (nnopds-test--with-server
    (nnopds-test--write opds-root "directory-only.txt" "enabled")
    (nnopds-test--with-browser
      (should (= 1 (length (nnopds-test--requests opds-root))))
      (should-not (nnopds--connection-catalog connection))
      (goto-char (point-min))
      (should-not (gnus-browse-group-name))
      (dolist (path '("/libraries" "/libraries/one" "/series/one"))
        (nnopds-test--at-link (nnopds--url path opds-url))
        (nnopds-browse-select))
      (should (string-match-p "Library: Root / Libraries / Library one / Series one" (buffer-string)))
      (nnopds-test--at-book)
      (should (gnus-browse-group-name))
      (should (= 1 (length (nnopds--connection-catalog connection))))
      (should (equal (mapcar (lambda (request) (plist-get request :path)) (nnopds-test--requests opds-root))
                     '("/catalog" "/libraries" "/libraries/one" "/series/one")))
      (dotimes (_ 3) (nnopds-browse-up))
      (should (= 4 (length (nnopds-test--requests opds-root)))))))

(ert-deftest nnopds-test-failed-navigation-and-refresh-keep-current-directory ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (nnopds-test--at-link (nnopds--url "/books" opds-url))
      (nnopds-browse-select)
      (nnopds-test--write opds-root "feed-failure-path.txt" "/books?page=2")
      (nnopds-test--at-link (nnopds--url "/books?page=2" opds-url))
      (let ((text (buffer-string)) (url nnopds-browse--url) (history nnopds-browse--history))
        (should-error (nnopds-browse-select))
        (should (equal text (buffer-string)))
        (should (equal url nnopds-browse--url))
        (should (equal history nnopds-browse--history))
        (nnopds-test--write opds-root "feed-failure-path.txt" "/books")
        (should-error (nnopds-browse-refresh))
        (should (equal text (buffer-string))))
      (delete-file (expand-file-name "feed-failure-path.txt" opds-root))
      (nnopds-close-server "library")
      (should (gnus-group-browse-foreign-server (car gnus-secondary-select-methods)))
      (nnopds-test--at-link (nnopds--url "/books" opds-url))
      (nnopds-browse-select)
      (nnopds-test--at-link (nnopds--url "/books?page=2" opds-url))
      (nnopds-browse-select)
      (let ((paths (mapcar (lambda (request) (plist-get request :path)) (nnopds-test--requests opds-root))))
        (should (= 1 (cl-count "/catalog" paths :test #'equal)))
        (should (= 2 (cl-count "/books" paths :test #'equal)))
        (should (= 2 (cl-count "/books?page=2" paths :test #'equal)))))))

(ert-deftest nnopds-test-epub-mime-locators-and-cache-reopen ()
  (nnopds-test--with-server
    (let* ((publication (nnopds-test--publication connection))
           (group (nnopds--publication-group publication))
           (book (nnopds--publication-data publication))
           (root (nnepub--book-root book))
           (chapters (nnopds--chapters 'epub book)))
      (should (= 4 (length chapters)))
      (should (equal (nnopds--publication-author publication) "作者甲, 作者乙"))
      (should (eq 'nov (nnopds-retrieve-headers '(1 . 2) group "library")))
      (should (eq 'nov (nnopds-retrieve-headers '(3 . 4) group "library" t)))
      (with-current-buffer nntp-server-buffer (should (= 2 (count-lines (point-min) (point-max)))))
      (should (nnopds-request-article 1 group "library"))
      (with-current-buffer nntp-server-buffer
        (should (string-match-p "multipart/related" (buffer-string)))
        (should (string-match-p "Content-ID:" (buffer-string))))
      (should (equal (plist-get (nnopds--locator 'epub book (car chapters)) :href) "OEBPS/Text/a.xhtml"))
      (should-not (nnopds--locator 'epub book (nth 2 chapters)))
      (should (equal (nnopds--locate 'epub book '(:href "OEBPS/Text/b.xhtml#note")) '(2 . "note")))
      (should-error (nnopds--locate 'epub book '(:href "../../outside.xhtml")))
      (nnopds-close-server "library")
      (should-not (file-exists-p root))
      (should (nnopds-open-server "library" `((nnopds-url ,opds-url) (nnopds-headers (("X-API-Key" . "test-key"))))))
      (should (nnopds-request-list "library"))
      (with-current-buffer nntp-server-buffer
        (should (string-match-p (concat (regexp-quote group) " 4 1 n") (buffer-string))))
      (should (nnopds-request-group group "library"))
      (should (= 1 (cl-count "/content/one.epub" (nnopds-test--requests opds-root)
                              :key (lambda (request) (plist-get request :path)) :test #'equal)))
      (should-not (nnopds-test--requests opds-root "PUT")))))

(ert-deftest nnopds-test-versioning-and-account-isolation ()
  (nnopds-test--with-server
    (let* ((publication (nnopds-test--publication connection))
           (old-group (nnopds--publication-group publication))
           (directory (nnopds--connection-directory connection)))
      (nnopds-test--write opds-root "revision.txt" "2026-02-01T00:00:00Z")
      (should (nnopds-refresh-catalog "library"))
      (should (= 2 (length (nnopds--connection-catalog connection))))
      (should (member old-group (nnopds--connection-catalog connection)))
      (let* ((page (nnopds--catalog-page connection opds-url))
             (entries (plist-get page :entries)))
        (maphash (lambda (_document entry) (should-not (equal old-group (nnopds--publication-group entry)))) entries))
      (should (gethash old-group (nnopds--connection-publications connection)))
      (should (nnopds-open-server "second" `((nnopds-url ,opds-url)
                                             (nnopds-user "reader") (nnopds-password "test-password"))))
      (should-not (equal directory (nnopds--connection-directory nnopds--connection)))
      (should (nnopds-request-list "second"))
      (should (nnopds-request-group old-group "library"))
      (nnopds-close-server "second")
      (should (nnopds-request-group old-group "library")))))

(ert-deftest nnopds-test-offline-catalog-and-invalid-response ()
  (nnopds-test--with-server
    (nnopds--catalog-page connection opds-url)
    (nnopds--catalog-page connection (nnopds--url "/books?page=2" opds-url))
    (let ((nnopds-catalog-cache-ttl 0)
          (url (nnopds--connection-url connection)))
      (setf (nnopds--connection-url connection) (nnopds--url "/failure" url))
      (should (nnopds-request-list "library"))
      (should (nnopds-request-scan nil "library"))
      (should (= 2 (length (nnopds-test--requests opds-root))))
      (should-error (nnopds-refresh-catalog "library"))
      (setf (nnopds--connection-url connection) (nnopds--url "/malformed" url))
      (should (nnopds-request-scan nil "library"))
      (should-error (nnopds-refresh-catalog "library")))
    (should (= 2 (length (nnopds--connection-catalog connection))))))

(ert-deftest nnopds-test-gnus-startup-reuses-expired-catalog-without-network ()
  (nnopds-test--with-server
    (nnopds--catalog-page connection opds-url)
    (nnopds--catalog-page connection (nnopds--url "/books?page=2" opds-url))
    (let ((file (nnopds--cache-file connection "catalog.json")))
      (let ((cached (nnopds--read-json file)))
        (setf (plist-get cached :fetched) 0)
        (nnopds--write-json file cached)))
    (nnopds-close-server "library")
    (nnopds-test--write opds-root "feed-delay.txt" "2")
    (let ((reads nil)
          (read-json (symbol-function 'nnopds--read-json)))
      (cl-letf (((symbol-function 'nnopds--read-json)
                 (lambda (file &optional object-type)
                   (push (file-name-nondirectory file) reads)
                   (funcall read-json file object-type)))
                ((symbol-function 'nnopds--normalize)
                 (lambda (&rest _args) (ert-fail "Cached publication URLs were normalized again"))))
        (should (nnopds-open-server "library" `((nnopds-url ,opds-url) (nnopds-headers (("X-API-Key" . "test-key")))))))
      (should (equal (sort reads #'string<) '("catalog.json" "counts.json"))))
    (let* ((method `(nnopds "library" (nnopds-url ,opds-url) (nnopds-headers (("X-API-Key" . "test-key")))))
           (gnus-agent nil) (gnus-opened-servers nil) (gnus-server-alist nil)
           (nnopds-catalog-cache-ttl 0)
           (gnus-server-method-cache nil) (gnus-have-read-active-file nil)
           (gnus-active-hashtb (gnus-make-hashtable)))
      (with-current-buffer nntp-server-buffer
        (gnus-read-active-file-1 method nil)
        (gnus-read-active-file-1 method nil))
      (should (= 2 (hash-table-count gnus-active-hashtb))))
    (should (= 2 (length (nnopds-test--requests opds-root))))))

(ert-deftest nnopds-test-empty-catalog-is-reused ()
  (nnopds-test--with-server
    (cl-letf (((symbol-function 'nnopds--request)
               (lambda (_connection _method url &rest _args)
                 (list :status 200 :url url :body "{\"metadata\":{\"title\":\"Empty\"},\"publications\":[]}"))))
      (nnopds--catalog-page connection opds-url))
    (cl-letf (((symbol-function 'nnopds--request)
               (lambda (&rest _args) (ert-fail "Empty cached catalog triggered an HTTP request"))))
      (should (nnopds-request-scan nil "library"))
      (should (nnopds-request-list "library")))
    (should-not (nnopds--connection-catalog connection))))

(ert-deftest nnopds-test-expired-page-falls-back-to-cache-on-network-failure ()
  (nnopds-test--with-server
    (nnopds-test--with-browser
      (let ((text (buffer-string))
            (nnopds-catalog-cache-ttl 0))
        (nnopds-test--write opds-root "feed-failure-path.txt" "/catalog")
        (nnopds-browse--show opds-url nil)
        (should (equal text (buffer-string)))
        (should (= 2 (length (nnopds-test--requests opds-root))))
        (should-error (nnopds-browse-refresh))
        (should (equal text (buffer-string)))
        (should (= 3 (length (nnopds-test--requests opds-root))))))))

(ert-deftest nnopds-test-conditional-refresh-and-changed-publications ()
  (dolist (validator '("etag" "last-modified"))
    (nnopds-test--with-server
      (nnopds-test--write opds-root "feed-validator.txt" validator)
      (nnopds--catalog-page connection opds-url)
      (let ((catalog (copy-sequence (nnopds--connection-catalog connection)))
            (request (symbol-function 'nnopds--request)) statuses)
        (cl-letf (((symbol-function 'nnopds--request)
                   (lambda (&rest args)
                     (let ((response (apply request args)))
                       (push (plist-get response :status) statuses)
                       response))))
          (should (nnopds-refresh-catalog "library"))
          (should (equal statuses '(304)))
          (should (equal catalog (nnopds--connection-catalog connection)))
          (nnopds-test--write opds-root "revision.txt" "2026-02-01T00:00:00Z")
          (setq statuses nil)
          (should (nnopds-refresh-catalog "library"))
          (should (equal statuses '(200)))
          (should (= 2 (length (nnopds--connection-catalog connection))))
          (should (cl-subsetp catalog (nnopds--connection-catalog connection) :test #'equal))
          (let ((entries (plist-get (nnopds--catalog-page connection opds-url) :entries)))
            (maphash (lambda (_document entry)
                       (should-not (member (nnopds--publication-group entry) catalog)))
                     entries)))))))

(ert-deftest nnopds-test-failed-refresh-keeps-installed-and-persistent-catalog ()
  (nnopds-test--with-server
    (nnopds--catalog-page connection opds-url)
    (let ((catalog (copy-sequence (nnopds--connection-catalog connection)))
          (snapshot (nnopds--read-json (nnopds--cache-file connection "catalog.json"))))
      (nnopds-test--write opds-root "revision.txt" "2026-02-01T00:00:00Z")
      (nnopds-test--write opds-root "feed-failure-path.txt" "/catalog")
      (should-error (nnopds-refresh-catalog "library"))
      (should (equal catalog (nnopds--connection-catalog connection)))
      (should (equal snapshot (nnopds--read-json (nnopds--cache-file connection "catalog.json"))))
      (nnopds-close-server "library")
      (should (nnopds-open-server "library" `((nnopds-url ,opds-url) (nnopds-headers (("X-API-Key" . "test-key"))))))
      (should (nnopds-request-list "library"))
      (should (equal catalog (nnopds--connection-catalog nnopds--connection)))
      (should (= 2 (length (nnopds-test--requests opds-root)))))))

(ert-deftest nnopds-test-precompiled-koreader-keeps-server-open-across-sessions ()
  (nnopds-test--with-server
    (let ((adapter (expand-file-name "nnopds-koreader.el" opds-root)))
      (copy-file (expand-file-name "nnopds-koreader.el" nnopds-test--load-path) adapter)
      ;; Reproduce a separately compiled adapter from before counts were added.
      ;; Struct accessors inline their field offsets into the adapter bytecode.
      (with-temp-buffer
        (let* ((form `(progn
                       (require 'nnopds)
                       (cl-defstruct (nnopds--connection (:constructor nnopds--make-connection))
                         name url headers directory catalog publications processes readers fetched
                         closed progress auth-method)
                       (unless (byte-compile-file ,adapter) (error "Could not compile adapter"))))
               (status (call-process invocation-name nil t nil "--batch" "-Q" "-L" nnopds-test--load-path
                                     "--eval" (prin1-to-string form))))
          (ert-info ((buffer-string)) (should (= status 0)))))
      (dotimes (session 2)
        (with-temp-buffer
          (let* ((form
                  `(progn
                     (require 'gnus) (require 'gnus-group) (require 'nnopds)
                     (load ,(concat adapter "c") nil t)
                     (setq gnus-directory ,(expand-file-name "News" opds-root)
                           gnus-home-directory ,opds-root gnus-startup-file ,(expand-file-name ".newsrc" opds-root)
                           gnus-init-file nil gnus-site-init-file nil gnus-use-dribble-file nil
                           gnus-select-method '(nnnil "") gnus-cache-directory ,gnus-cache-directory
                           gnus-check-new-newsgroups nil gnus-save-newsrc-file nil
                           gnus-secondary-select-methods
                           '((nnopds "komga" (nnopds-url ,(nnopds--url "/komga/opds/v2/catalog" opds-url))
                                    (nnopds-headers (("X-API-Key" . "komga-key")))
                                    (nnopds-koreader-url ,(nnopds--url "/komga/koreader" opds-url))
                                    (nnopds-koreader-user "komga-key")
                                    (nnopds-koreader-password "test-password"))))
                     (gnus)
                     (unless (gnus-group-browse-foreign-server (car gnus-secondary-select-methods))
                       (error "Could not browse Komga"))
                     (when (nnopds--connection-closed nnopds--connection) (error "Komga connection is closed"))
                     (unless (eq (plist-get (nnopds--connection-progress nnopds--connection) :protocol) 'koreader)
                       (error "KOReader settings were lost"))
                     (unless (= 1 (length (nnopds--connection-catalog nnopds--connection)))
                       (error "Book missing"))
                     (nnopds-refresh-catalog "komga")
                     (nnopds-request-close)))
                 (status (call-process invocation-name nil t nil "--batch" "-Q" "-L" nnopds-test--load-path
                                       "--eval" (prin1-to-string form))))
            (ert-info ((format "Session %d: %s" session (buffer-string))) (should (= status 0)))))
        ;; First browsing fetches once; startup and later browsing use cache.
        ;; The explicit refresh in each session still makes one HTTP request.
        (should (= (+ 2 session) (length (nnopds-test--requests opds-root))))))))

(ert-deftest nnopds-test-http-binary-redirect-and-credential-scope ()
  (nnopds-test--with-server
    (let ((response (nnopds--request connection "GET" (nnopds--url "/redirect" opds-url))))
      (should (= 200 (plist-get response :status)))
      (should (plist-get (nnopds--json response) :navigation)))
    (let ((response (nnopds--request connection "GET" (nnopds--url "/content/one.epub" opds-url))))
      (should-not (multibyte-string-p (plist-get response :body)))
      (should (equal (plist-get response :body) (nnopds--read-bytes (expand-file-name "one.epub" opds-root)))))
    ;; localhost and 127.0.0.1 are distinct origins, even on the same port.
    (let* ((target (replace-regexp-in-string "127.0.0.1" "localhost" (nnopds--url "/echo" opds-url)))
           (redirect (concat (nnopds--url "/redirect" opds-url) "?target=" (url-hexify-string target)))
           (response (nnopds--json (nnopds--request connection "GET" redirect))))
      (should-not (plist-get response :X-API-Key))
      (should-not (plist-get response :Authorization)))))

(ert-deftest nnopds-test-http-timeout-releases-callback-and-resources ()
  (nnopds-test--with-server
    (let ((nnopds-request-timeout 1) (calls 0) failure)
      (nnopds--request connection "GET" (nnopds--url "/slow" opds-url) nil
                       (lambda (_response error) (cl-incf calls) (setq failure error)))
      (nnopds-test--wait (lambda () failure))
      (should (= calls 1))
      (should-not (nnopds--connection-processes connection)))))

(ert-deftest nnopds-test-json-arrays-and-booleans-survive-cache-round-trip ()
  (zr-test-with-temp-directory
    (let* ((json "{\"links\":[{\"rel\":[\"self\"],\"templated\":false}],\"empty\":[],\"null\":null,\"yes\":true}")
           (value (nnopds--json (list :status 200 :body json)))
           (file (expand-file-name "catalog.json")))
      (should (vectorp (plist-get value :links)))
      (should (equal (plist-get value :empty) []))
      (should (eq (plist-get (aref (plist-get value :links) 0) :templated) :false))
      (nnopds--write-json file value)
      (should (equal value (nnopds--read-json file))))))

(ert-deftest nnopds-test-progress-return-to-saved-chapter-cancels-newer-queue ()
  (nnopds-test--with-koreader 'komga
    (nnopds-test--with-reader
      (nnopds-test--select 1)
      (nnopds-progress--flush state)
      (nnopds-test--wait (lambda () (not (nnopds-progress--state-in-flight state))))
      (nnopds-test--select 2)
      (should (nnopds-progress--state-pending state))
      (nnopds-test--select 1)
      (should-not (nnopds-progress--state-pending state))
      (nnopds-progress-close state)
      (should (= 1 (length (nnopds-test--requests opds-root "PUT")))))))

(ert-deftest nnopds-test-koreader-default-requires-an-explicit-url ()
  (should (eq (default-value 'nnopds-progress-protocol) 'koreader))
  (dolist (kind '(komga calibre))
    (nnopds-test--with-server
      (nnopds-close-server "library")
      (let* ((url (nnopds--url (if (eq kind 'komga) "/komga/opds/v2/catalog" "/calibre/opds") opds-url))
             (connection
              (progn
                (should (nnopds-open-server "library" `((nnopds-url ,url)
                                                       (nnopds-headers (("X-API-Key" . "test-key")))
                                                       (nnopds-progress-protocol koreader))))
                nnopds--connection)))
        (should-not (nnopds--connection-progress connection))
        (should-not (nnopds--publication-progress (nnopds-test--publication connection)))
        (should-not (cl-some (lambda (request) (plist-get request :sync_user)) (nnopds-test--requests opds-root)))))))

(ert-deftest nnopds-test-koreader-partial-md5-reference-values ()
  ;; Values computed independently with calibre's explicit sampling offsets.
  (zr-test-with-temp-directory
    (dolist (example '((0 . "d41d8cd98f00b204e9800998ecf8427e")
                       (1 . "93b885adfe0da089cdf634904fd59f71")
                       (1024 . "37a6b4a1a03e1005cffec568bf934e9e")
                       (1025 . "59056ef6104076ab18933edeaf7409a6")
                       (4096 . "ca45fe967440f7d3039b483b51e7b1d4")
                       (4097 . "7ab0411b4a7df0f8ceb16ad034be22d9")
                       (17000 . "dfb08563c9f98b17c981f5b9161c5d7a")
                       (70000 . "449c840b35da4cf4a8323cac73085ab0")))
      (let ((file (expand-file-name "sample")) (coding-system-for-write 'binary))
        (with-temp-file file
          (set-buffer-multibyte nil)
          (dotimes (i (car example)) (insert-char (% (+ (* i 17) (/ i 251)) 256))))
        (should (equal (nnopds-koreader--digest file) (cdr example)))))))

(ert-deftest nnopds-test-koreader-epub-xpointer-forms ()
  (nnopds-test--with-koreader 'komga
    (let* ((publication (nnopds-test--publication connection))
           (data (nnopds--publication-data publication)))
      (dolist (example '(("/body/DocFragment[2].0" . 2)
                         ("/body/DocFragment[2]/body/div/p[1]/text().17" . 2)
                         ("/body/DocFragment/body/p[1]/text().0" . 1)
                         ("#_doc_fragment_1_c37" . 2)))
        (should (= (car (nnopds--locate 'epub data (nnopds-koreader--decode 'epub data (car example) 0.7)))
                   (cdr example))))
      (dolist (progress '("/body/DocFragment[0].0" "/body/DocFragment[3].0" "unrecognized"))
        (should-error (nnopds-koreader--decode 'epub data progress 0.5))))))

(ert-deftest nnopds-test-koreader-komga-and-calibre-round-trip ()
  (dolist (kind '(komga calibre))
    (nnopds-test--with-koreader kind
      (nnopds-test--with-reader
        (when (eq kind 'komga)
          (nnopds-test--write opds-root "ko-get-body.txt" "")
          (should-not (nnopds-progress--read-now state))
          (delete-file (expand-file-name "ko-get-body.txt" opds-root)))
        (nnopds-test--select 1)
        (nnopds-test--select 2)
        (should (nnopds-request-article 1 (nnopds--publication-group publication) "library"))
        (nnopds-test--select 3)  ; An out-of-spine footnote must not be synchronized.
        (should-not (nnopds-test--requests opds-root "PUT"))
        (nnopds-progress-close state)
        (let* ((writes (nnopds-test--requests opds-root "PUT"))
               (request (car writes))
               (body (plist-get request :body))
               (progression (nnopds-progress--read-now state)))
          (should (= (length writes) 1))
          (should (equal (plist-get body :progress) "/body/DocFragment[2].0"))
          (should (= (plist-get body :percentage) 0.5))
          (should (equal (plist-get body :device_id) nnopds-progress-device-id))
          (should (equal (plist-get request :sync_user) (if (eq kind 'komga) "komga-key" "reader")))
          (should (equal (plist-get request :sync_key) (unless (eq kind 'komga) (secure-hash 'md5 "test-password"))))
          (should (equal (plist-get request :accept) "application/vnd.koreader.v1+json"))
          (should (equal (plist-get request :content_type) "application/json"))
          (should-not (plist-get request :key))
          (should-not (plist-get request :authorization))
          (should (= (car (nnopds-progress--location state progression)) 2))
          (should (eq (not (null (plist-get progression :timestamp))) (eq kind 'calibre))))
        (when (eq kind 'calibre)
          (should (file-readable-p (expand-file-name "kosync-registered.txt" opds-root))))))))

(ert-deftest nnopds-test-koreader-failures-and-finer-remote-position ()
  (nnopds-test--with-koreader 'komga
    (nnopds-test--with-reader
      (let ((document (plist-get (nnopds--publication-progress publication) :document)))
        (nnopds-test--write opds-root "koreader-progress.json"
                             (json-serialize (list :document document :progress "/body/DocFragment[2]/body/p[1]/text().20"
                                                   :percentage 0.7 :device "Kobo" :device_id "phone")))
        (nnopds-test--select 2)
        (nnopds-progress--flush state)
        (nnopds-test--wait (lambda () (not (nnopds-progress--state-in-flight state))))
        (should-not (nnopds-test--requests opds-root "PUT"))
        (delete-file (expand-file-name "koreader-progress.json" opds-root))
        (dolist (body '("null" "broken" "{\"progress\":\"bad\"}"))
          (nnopds-test--write opds-root "ko-get-body.txt" body)
          (nnopds-test--select 1)
          (nnopds-progress--flush state)
          (nnopds-test--wait (lambda () (not (nnopds-progress--state-in-flight state)))))
        (should-not (nnopds-test--requests opds-root "PUT"))
        (delete-file (expand-file-name "ko-get-body.txt" opds-root))
        (nnopds-test--write opds-root "ko-get-status.txt" "404")
        (should-error (nnopds-progress--read-now state))
        (delete-file (expand-file-name "ko-get-status.txt" opds-root))
        (nnopds-test--write opds-root "ko-put-status.txt" "409")
        (nnopds-test--select 2)
        (nnopds-progress-close state)
        (should (= (length (nnopds-test--requests opds-root "PUT")) 1))
        (should-not (nnopds-progress--state-sent state))
        (should-not (file-exists-p (expand-file-name "koreader-progress.json" opds-root)))))))

(ert-deftest nnopds-test-koreader-authentication-failure-keeps-epub-readable ()
  (nnopds-test--with-koreader 'komga
    (setf (plist-get (nnopds--connection-progress connection) :headers) '(("X-Auth-User" . "wrong-key")))
    (let ((publication (nnopds-test--publication connection)))
      (should (nnopds--publication-data publication))
      (should-not (nnopds--publication-progress publication))
      (should-not (nnopds-test--requests opds-root "PUT")))))

(ert-deftest nnopds-test-koreader-credentials-have-a-separate-origin ()
  (nnopds-test--with-koreader 'calibre
    (let* ((endpoint (nnopds--connection-progress connection))
           (sync-origin (replace-regexp-in-string "127.0.0.1" "localhost" (plist-get endpoint :url)))
           (echo (nnopds--url "/echo" sync-origin)))
      (setf (plist-get endpoint :url) sync-origin)
      (let ((response (nnopds--json (nnopds--request connection "GET" echo nil nil nil endpoint))))
        (should (equal (plist-get response :X-Auth-User) "reader"))
        (should-not (plist-get response :X-API-Key))
        (should-not (plist-get response :Authorization)))
      (let* ((target (nnopds--url "/echo" opds-url))
             (redirect (concat (nnopds--url "/redirect" sync-origin) "?target=" (url-hexify-string target)))
             (response (nnopds--json (nnopds--request connection "GET" redirect nil nil nil endpoint))))
        (should-not (plist-get response :X-Auth-User))
        (should-not (plist-get response :X-Auth-Key))
        (should-not (plist-get response :X-API-Key))
        (should-not (plist-get response :Authorization))))))

(ert-deftest nnopds-test-koreader-serialized-writes-drain-newest ()
  (nnopds-test--with-koreader 'calibre
    (nnopds-test--with-reader
      (nnopds-test--write opds-root "ko-put-delay.txt" "0.15")
      (nnopds-test--write opds-root "ko-time-offset.txt" "10")
      (nnopds-test--select 1)
      (nnopds-progress--flush state)
      (nnopds-test--wait (lambda () (nnopds-test--requests opds-root "PUT")))
      (nnopds-test--select 2)
      (nnopds-progress-close state)
      (should (= (length (nnopds-test--requests opds-root "PUT")) 2))
      (should (equal (plist-get (nnopds--read-json (expand-file-name "koreader-progress.json" opds-root)) :progress)
                     "/body/DocFragment[2].0")))))

(ert-deftest nnopds-test-koreader-gnus-komga-and-calibre-resume-across-sessions ()
  (dolist (kind '(komga calibre))
    (nnopds-test--with-koreader kind
      (skip-unless (and (or (executable-find "7zz") (executable-find "7z")) (libxml-available-p)))
      (nnopds-test--write opds-root "koreader-progress.json"
                           (json-serialize (list :document (nnopds-koreader--digest (expand-file-name "one.epub" opds-root))
                                                 :progress "/body/DocFragment[1]/body/p[1]/text().20" :percentage 0.1
                                                 :device "Kobo" :device_id "phone")))
      (dolist (session '(first second))
        (let ((form
               `(progn
                  (require 'gnus) (require 'gnus-group) (require 'gnus-sum) (require 'nnopds)
                  (unless (eq nnopds-progress-protocol 'koreader) (error "KOReader must be the default"))
                  (setq gnus-directory ,(expand-file-name "News" opds-root)
                        gnus-home-directory ,opds-root gnus-startup-file ,(expand-file-name ".newsrc" opds-root)
                        gnus-init-file nil gnus-site-init-file nil gnus-use-dribble-file nil
                        gnus-select-method '(nnnil "") gnus-cache-directory ,gnus-cache-directory
                        shr-use-fonts nil gnus-save-newsrc-file t
                        gnus-secondary-select-methods
                        '((nnopds "books" (nnopds-url ,opds-url)
                                  ,@(if (eq kind 'komga)
                                        '((nnopds-headers (("X-API-Key" . "komga-key"))))
                                      '((nnopds-user "reader") (nnopds-password "test-password") (nnopds-auth-method digest)))
                                  (nnopds-koreader-url ,sync-url)
                                  (nnopds-koreader-user ,(if (eq kind 'komga) "komga-key" "reader"))
                                  (nnopds-koreader-password ,(unless (eq kind 'komga) "test-password")))))
                  (gnus-no-server)
                  (gnus-group-browse-foreign-server (car gnus-secondary-select-methods))
                  (goto-char (point-min))
                  (while (and (not (eobp)) (not (gnus-browse-group-name))) (forward-line 1))
                  (let ((group (gnus-browse-group-name)))
                    (unless group (error "Book missing"))
                    (when (> (gnus-group-level group) gnus-level-subscribed)
                      (nnopds-browse-subscribe))
                    (goto-char (point-min))
                    (while (and (not (eobp)) (not (equal group (gnus-browse-group-name)))) (forward-line 1))
                    (nnopds-browse-read)
                    (with-current-buffer gnus-summary-buffer
                      (unless (and nnopds-progress--state (= gnus-current-article ,(if (eq session 'first) 1 2)))
                        (error "KOReader position was not resumed"))
                      ,(if (eq session 'first)
                           '(progn
                              (with-current-buffer gnus-article-buffer
                                (goto-char (point-min))
                                (unless (search-forward "中文内容 α" nil t) (error "EPUB text missing"))
                                (goto-char (point-min))
                                (search-forward "下一章") (backward-char) (nnepub-follow-link))
                              (unless (= gnus-current-article 2) (error "Chapter link did not select article 2"))
                              (with-current-buffer gnus-article-buffer
                                (unless (looking-at "脚注目标") (error "Chapter anchor missing"))))
                         '(unless (memq 2 (range-uncompress (gnus-info-read (gnus-get-info group))))
                            (error "Read mark was not restored: %S" (gnus-get-info group))))
                      (gnus-summary-exit))
                    (gnus-save-newsrc-file)
                    (nnopds-request-close)
                    (princ "koreader-integration-ok")))))
          (with-temp-buffer
            (let ((status (call-process invocation-name nil t nil "--batch" "-Q" "-L" nnopds-test--load-path
                                        "--eval" (prin1-to-string form))))
              (ert-info ((buffer-string))
                (should (= status 0))
                (should (string-match-p "koreader-integration-ok" (buffer-string))))))))
      (should (= (length (nnopds-test--requests opds-root "PUT")) 1)))))

(provide 'nnopds-test)
;;; nnopds-test.el ends here
