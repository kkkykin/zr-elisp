;;; nnopds-test.el --- OPDS catalogs and reading position tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nnopds)
(require 'nnopds-progress)
(require 'nnopds-koreader)
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
              (nnopds-url nil) (nnopds-user nil) (nnopds-password nil) (nnopds-headers nil)
              (nnopds-auth-method 'basic)
              (nnopds-progress-protocol 'koreader)
              (nnopds-koreader-url nil) (nnopds-koreader-user nil) (nnopds-koreader-password nil)
              (nnopds--connection nil) (nnopds--group nil)
              (gnus-cache-directory (expand-file-name "cache" opds-root))
              (nnopds-request-timeout 2)
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
  (should (nnopds-request-list (nnopds--connection-name connection)))
  (let ((group (nth (or number 0) (nnopds--connection-catalog connection))))
    (should (nnopds-request-group group (nnopds--connection-name connection)))
    (gethash group (nnopds--connection-publications connection))))

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
    (should-not (nnopds-test--requests opds-root))
    (should (nnopds-request-list "library"))
    (should (= 2 (length (nnopds--connection-catalog connection))))
    (let ((requests (nnopds-test--requests opds-root)))
      (should (= 3 (length requests)))
      (should (cl-every (lambda (request) (equal (plist-get request :key) "test-key")) requests))
      (should (cl-every (lambda (request) (equal (plist-get request :accept) "application/opds+json")) requests))
      (should (member "/books?page=2" (mapcar (lambda (request) (plist-get request :path)) requests))))
    (with-current-buffer nntp-server-buffer
      (should (= 2 (count-lines (point-min) (point-max)))))
    (should (nnopds-request-list-newsgroups "library"))
    (with-current-buffer nntp-server-buffer (should (string-match-p "测试书籍 one" (buffer-string))))
    (should (nnopds-request-list "library"))
    (should (= 3 (length (nnopds-test--requests opds-root))))))

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
      (with-current-buffer nntp-server-buffer (should (= 4 (count-lines (point-min) (point-max)))))
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
      (should (nnopds-request-scan nil "library"))
      (should-not (member old-group (nnopds--connection-catalog connection)))
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
    (should (nnopds-request-list "library"))
    (let ((nnopds-catalog-cache-ttl 0)
          (url (nnopds--connection-url connection)))
      (setf (nnopds--connection-url connection) (nnopds--url "/failure" url))
      (should (nnopds-request-list "library"))
      (should-not (nnopds-request-scan nil "library"))
      (setf (nnopds--connection-url connection) (nnopds--url "/malformed" url))
      (should-not (nnopds-request-scan nil "library")))
    (should (= 2 (length (nnopds--connection-catalog connection))))))

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
                      (gnus-browse-toggle-subscription-at-point 1))
                    (goto-char (point-min))
                    (while (and (not (eobp)) (not (equal group (gnus-browse-group-name)))) (forward-line 1))
                    (gnus-browse-read-group)
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
                            (error "Read mark was not restored")))
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
