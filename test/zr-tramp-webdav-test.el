;;; zr-tramp-webdav-test.el --- WebDAV integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise public Emacs file operations with both HTTP transports against
;; a local, in-memory WebDAV server.  No external Python packages are needed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dired)

(load (expand-file-name "../zr-tramp-webdav.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defconst zr-tramp-webdav-test--server-file
  (expand-file-name "webdav-server.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defvar zr-tramp-webdav-test--process nil)
(defvar zr-tramp-webdav-test--port nil)
(defvar zr-tramp-webdav-test--serial 0)

(defun zr-tramp-webdav-test--stop ()
  "Stop the local test server."
  (when (process-live-p zr-tramp-webdav-test--process)
    (delete-process zr-tramp-webdav-test--process)))

(add-hook 'kill-emacs-hook #'zr-tramp-webdav-test--stop)

(defun zr-tramp-webdav-test--start ()
  "Start the HTTP fixture if needed, and return its port."
  (unless (executable-find "python3") (ert-skip "Python 3 is required"))
  (unless (process-live-p zr-tramp-webdav-test--process)
    (let ((buffer (get-buffer-create " *zr-webdav-test-server*"))
          (deadline (+ (float-time) 5)))
      (with-current-buffer buffer (erase-buffer))
      (setq zr-tramp-webdav-test--port nil
            zr-tramp-webdav-test--process
            (make-process :name "zr-webdav-test-server" :buffer buffer
                          :command (list "python3" "-u" zr-tramp-webdav-test--server-file)
                          :connection-type 'pipe :coding 'utf-8-unix :noquery t))
      (while (and (not zr-tramp-webdav-test--port) (< (float-time) deadline))
        (accept-process-output zr-tramp-webdav-test--process 0.05)
        (with-current-buffer buffer
          (goto-char (point-min))
          (when (re-search-forward "PORT \\([0-9]+\\)" nil t)
            (setq zr-tramp-webdav-test--port (match-string 1)))))
      (unless zr-tramp-webdav-test--port
        (error "WebDAV fixture did not start: %s" (with-current-buffer buffer (buffer-string))))))
  zr-tramp-webdav-test--port)

(defmacro zr-tramp-webdav-test--with-backends (&rest body)
  "Run BODY for each transport, binding `root' to a fresh collection."
  (declare (indent 0) (debug body))
  `(let ((port (zr-tramp-webdav-test--start))
         (auth-sources nil)
         (auth-source-do-cache nil)
         (url-proxy-services '(("no_proxy" . ".*")))
         (process-environment (copy-sequence process-environment))
         (tramp-cache-data (make-hash-table :test #'equal))
         (tramp-verbose 0)
         (zr-tramp-webdav--passwords (make-hash-table :test #'equal))
         (zr-tramp-webdav-timeout 3)
         (zr-tramp-webdav-extra-headers nil))
     (setenv "NO_PROXY" "*")
     (setenv "no_proxy" "*")
     (dolist (zr-tramp-webdav-backend '(url curl))
       (ert-info ((format "Transport: %S" zr-tramp-webdav-backend))
         (when (eq zr-tramp-webdav-backend 'curl)
           (unless (executable-find zr-tramp-webdav-curl-program)
             (ert-skip "curl is required")))
         (let ((root (format "/webdav:127.0.0.1#%s:/dav/test-%d/"
                             port (cl-incf zr-tramp-webdav-test--serial))))
           (zr-tramp-webdav-clear-cache)
           (unwind-protect
               (progn (make-directory root) ,@body)
             (ignore-errors (delete-directory root t))))))))

(defun zr-tramp-webdav-test--contents (file)
  "Read FILE as text."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest zr-tramp-webdav-paths-and-registration ()
  (let* ((name "/webdavs:alice@example.org#8443:/dav/中文 %?#&+.txt")
         (vec (tramp-dissect-file-name name)))
    (should (eq (tramp-find-foreign-file-name-handler vec)
                #'zr-tramp-webdav-file-name-handler))
    (should (equal (zr-tramp-webdav--url vec)
                   "https://example.org:8443/dav/%E4%B8%AD%E6%96%87%20%25%3F%23%26%2B.txt"))
    (should (equal (file-remote-p name 'method) "webdavs"))
    (should (equal (expand-file-name "../other.txt" name)
                   "/webdavs:alice@example.org#8443:/dav/other.txt"))
    (should-error (expand-file-name "/ssh:jump|webdavs:host:/dav/"))))

(ert-deftest zr-tramp-webdav-xml-namespaces-and-status ()
  (let* ((response
          '(:url "http://example.org:80/dav/"
            :body "<multistatus xmlns='DAV:' xmlns:x='urn:unrelated'><response><href>/dav/%E4%B8%AD%25.txt</href><propstat><prop><resourcetype/><getcontentlength>5</getcontentlength><x:getetag>wrong</x:getetag><getetag>&quot;right&quot;</getetag></prop><status>HTTP/1.1 200 OK</status></propstat><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 404 Not Found</status></propstat></response><response><href>http://elsewhere.invalid/dav/foreign</href><status>HTTP/1.1 200 OK</status></response></multistatus>"))
         (entries (zr-tramp-webdav--entries response)))
    (should (= (length entries) 1))
    (should (equal (plist-get (car entries) :path) "/dav/中%.txt"))
    (should (equal (plist-get (car entries) :etag) "\"right\""))
    (should (= (plist-get (car entries) :size) 5))
    (should-not (plist-get (car entries) :directory))
    (should-not (zr-tramp-webdav--href-path "/dav/a%2fb" "http://example.org/dav/"))))

(ert-deftest zr-tramp-webdav-text-and-binary-roundtrip ()
  (zr-tramp-webdav-test--with-backends
    (let ((file (concat root "中文 %?#&+[].txt"))
          (binary (concat root "raw.bin"))
          (bytes (unibyte-string 0 255 128 13 10 1 254)))
      (let ((coding-system-for-write 'utf-8-dos))
        (write-region "第一行\nsecond\n" nil file nil 'silent))
      (should (equal (zr-tramp-webdav-test--contents file) "第一行\nsecond\n"))
      (with-temp-buffer
        (insert "old contents")
        (let ((result (insert-file-contents file nil nil nil t)))
          (should (equal (car result) file))
          (should (= (cadr result) (length "第一行\nsecond\n"))))
        (should (equal (buffer-string) "第一行\nsecond\n")))
      (let ((coding-system-for-write 'no-conversion))
        (write-region bytes nil binary nil 'silent))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally binary)
        (should (equal (buffer-string) bytes)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally binary nil 1 4)
        (should (equal (buffer-string) (substring bytes 1 4))))
      (let ((copy (file-local-copy binary)))
        (unwind-protect
            (should (equal (zr-tramp-webdav--read-bytes copy) bytes))
          (delete-file copy))))))

(ert-deftest zr-tramp-webdav-listing-completion-and-dired ()
  (zr-tramp-webdav-test--with-backends
    (let ((file (concat root "中文 note.txt"))
          (directory (concat root "folder/")))
      (write-region "hello" nil file nil 'silent)
      (make-directory directory)
      (should (equal (directory-files root) '("." ".." "folder" "中文 note.txt")))
      (should-not (directory-files root nil nil nil 0))
      (should (equal (directory-files root t "txt$") (list file)))
      (should (equal (file-name-all-completions "f" root) '("folder/")))
      (should (equal (file-name-completion "中文" root) "中文 note.txt"))
      (should (file-directory-p directory))
      (should (file-directory-p (directory-file-name directory)))
      (should (file-equal-p directory (directory-file-name directory)))
      (should (file-regular-p file))
      (should (= (file-attribute-size (file-attributes file)) 5))
      (should (equal (file-attribute-user-id (file-attributes file 'string)) "unknown"))
      (let ((buffer (dired-noselect root)))
        (unwind-protect
            (with-current-buffer buffer
              (should (dired-goto-file file))
              (should (equal (dired-get-filename) file)))
          (kill-buffer buffer)))
      ;; The listing was cached before deletion; mutations must invalidate it.
      (delete-file file)
      (should (equal (directory-files root) '("." ".." "folder")))
      (should-not (file-exists-p file)))))

(ert-deftest zr-tramp-webdav-visiting-saving-and-backups ()
  (zr-tramp-webdav-test--with-backends
    (let* ((file (concat root "visited.txt"))
           (buffer (find-file-noselect file)))
      (unwind-protect
          (with-current-buffer buffer
            (insert "first version\n")
            (save-buffer)
            (should-not (buffer-modified-p))
            (should (equal buffer-file-name file))
            (should (verify-visited-file-modtime buffer))
            (insert "second version\n")
            (save-buffer)
            (should-not (buffer-modified-p))
            (should (equal (zr-tramp-webdav-test--contents file)
                           "first version\nsecond version\n")))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    ;; Visiting an already existing file exercises backup creation on save.
    (let* ((file (concat root "backup.txt")) buffer)
      (write-region "old\n" nil file nil 'silent)
      (setq buffer (find-file-noselect file))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "new\n")
            (save-buffer)
            (should (equal (zr-tramp-webdav-test--contents file) "old\nnew\n")))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest zr-tramp-webdav-conflict-preserves-buffer-and-server ()
  (zr-tramp-webdav-test--with-backends
    (let ((file (concat root "conflict.txt")) buffer)
      (write-region "original" nil file nil 'silent)
      (setq buffer (find-file-noselect file))
      (unwind-protect
          (with-current-buffer buffer
            (text-mode)
            (should backup-by-copying)
            (erase-buffer)
            (insert "unsaved edits")
            (let ((zr-tramp-webdav--visited nil))
              (write-region "external version" nil file nil 'silent))
            (should-not (verify-visited-file-modtime (current-buffer)))
            (should-error (write-region (point-min) (point-max) file nil t) :type 'file-error)
            (should (buffer-modified-p))
            (should (equal (buffer-string) "unsaved edits"))
            (should (equal (zr-tramp-webdav-test--contents file) "external version")))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest zr-tramp-webdav-compressed-file-handlers ()
  (unless (executable-find "gzip") (ert-skip "gzip is required"))
  (zr-tramp-webdav-test--with-backends
    (let ((file (concat root "compressed.txt.gz")) buffer)
      (write-region "compressed text\n" nil file nil 'silent)
      (should (equal (zr-tramp-webdav-test--contents file) "compressed text\n"))
      (let ((raw (plist-get (zr-tramp-webdav--get file) :body)))
        (should (equal (substring raw 0 2) (unibyte-string 31 139)))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (should (equal (buffer-string) raw))))
      (setq buffer (find-file-noselect file))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "one\n")
            (save-buffer)
            (insert "two\n")
            (save-buffer)
            (should (equal (zr-tramp-webdav-test--contents file)
                           "compressed text\none\ntwo\n")))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest zr-tramp-webdav-append-offset-and-exclusive-create ()
  (zr-tramp-webdav-test--with-backends
    (let ((file (concat root "append.txt")))
      (write-region "abc" nil file nil 'silent nil 'excl)
      (should-error (write-region "wrong" nil file nil 'silent nil 'excl)
                    :type 'file-already-exists)
      (write-region "de" nil file t 'silent)
      (should (equal (zr-tramp-webdav-test--contents file) "abcde"))
      (write-region "XY" nil file 1 'silent)
      (should (equal (zr-tramp-webdav-test--contents file) "aXYde"))
      (write-region "new" nil (concat root "new.txt") t 'silent)
      (should (equal (zr-tramp-webdav-test--contents (concat root "new.txt")) "new")))))

(ert-deftest zr-tramp-webdav-copy-move-and-local-transfers ()
  (zr-tramp-webdav-test--with-backends
    (let ((file (concat root "original.txt"))
          (copy (concat root "copy.txt"))
          (moved (concat root "moved.txt"))
          (local (make-temp-file "zr-webdav-test-")))
      (unwind-protect
          (progn
            (write-region "content" nil file nil 'silent)
            (copy-file file copy)
            (should (equal (zr-tramp-webdav-test--contents copy) "content"))
            (should-error (copy-file file copy) :type 'file-already-exists)
            (rename-file copy moved)
            (should-not (file-exists-p copy))
            (should (equal (zr-tramp-webdav-test--contents moved) "content"))
            (copy-file moved local t t)
            (should (equal (zr-tramp-webdav-test--contents local) "content"))
            (write-region "local bytes" nil local nil 'silent)
            (copy-file local moved t)
            (should (equal (zr-tramp-webdav-test--contents moved) "local bytes"))
            (rename-file moved local t)
            (should-not (file-exists-p moved))
            (should (equal (zr-tramp-webdav-test--contents local) "local bytes"))
            (rename-file local moved)
            (should-not (file-exists-p local))
            (should (equal (zr-tramp-webdav-test--contents moved) "local bytes")))
        (when (file-exists-p local) (delete-file local))))))

(ert-deftest zr-tramp-webdav-directory-operations ()
  (zr-tramp-webdav-test--with-backends
    (let ((nested (concat root "a/b/")))
      (make-directory nested t)
      (make-directory nested t)
      (should-error (make-directory nested) :type 'file-already-exists)
      (write-region "child" nil (concat nested "child.txt") nil 'silent)
      (should-error (delete-directory nested) :type 'file-error)
      (should-error (delete-file nested) :type 'file-error)
      (copy-directory (concat root "a") (concat root "copied"))
      (should (equal (zr-tramp-webdav-test--contents (concat root "copied/b/child.txt")) "child"))
      (rename-file (concat root "a") (concat root "renamed"))
      (should-not (file-exists-p (concat root "a")))
      (should (file-exists-p (concat root "renamed/b/child.txt")))
      (delete-directory (concat root "renamed") t)
      (should-not (file-exists-p (concat root "renamed")))
      (make-directory (concat root "empty"))
      (delete-directory (concat root "empty"))
      (should-not (file-exists-p (concat root "empty"))))))

(ert-deftest zr-tramp-webdav-auth-source-and-custom-headers ()
  (zr-tramp-webdav-test--with-backends
    (let ((file (format "/webdav:alice@127.0.0.1#%s:/auth/secret.txt" port))
          (auth (make-temp-file "zr-webdav-test-auth-")))
      (unwind-protect
          (progn
            (write-region (format "machine 127.0.0.1 port %s login alice password app-password\n" port)
                          nil auth nil 'silent)
            (let ((auth-sources (list auth)))
              (should (equal (zr-tramp-webdav-test--contents file) "authenticated")))
            (zr-tramp-webdav-clear-cache)
            (let ((zr-tramp-webdav-extra-headers
                   (lambda (name)
                     (should (equal name file))
                     (list (cons "authorization"
                                 (concat "Basic " (base64-encode-string "alice:app-password" t)))))))
              (should (equal (zr-tramp-webdav-test--contents file) "authenticated")))
            (zr-tramp-webdav-clear-cache)
            (should-error (zr-tramp-webdav-test--contents file) :type 'file-error))
        (delete-file auth)))))

(ert-deftest zr-tramp-webdav-redirects-and-http-errors ()
  (zr-tramp-webdav-test--with-backends
    (let ((base (format "/webdav:127.0.0.1#%s:" port)))
      (should-not (file-exists-p (concat root "missing")))
      (should-not (file-exists-p (concat base "/__test__/missing-multistatus")))
      (should-error (zr-tramp-webdav-test--contents (concat root "missing")) :type 'file-missing)
      (should-error (file-attributes (concat base "/__test__/forbidden")) :type 'file-error)
      (should-error (file-attributes (concat base "/__test__/broken-xml")) :type 'file-error)
      (should-error (file-attributes (concat base "/__test__/cross-origin")) :type 'file-error)
      (should-error (file-attributes (concat base "/__test__/loop")) :type 'file-error)
      (write-region "redirected body" nil (concat root "redirect-source") nil 'silent)
      (should (equal (zr-tramp-webdav-test--contents (concat root "redirect-target")) "redirected body"))
      (write-region "retained" nil (concat root "partial-delete") nil 'silent)
      (should-error (delete-file (concat root "partial-delete")) :type 'file-error)
      (should (file-exists-p (concat root "partial-delete"))))))

(ert-deftest zr-tramp-webdav-transport-timeouts-and-truncated-data ()
  (zr-tramp-webdav-test--with-backends
    (let ((base (format "/webdav:127.0.0.1#%s:" port))
          (zr-tramp-webdav-timeout 0.2))
      (should-error (zr-tramp-webdav--get (concat base "/__test__/slow")) :type 'file-error)
      (should-error (zr-tramp-webdav--get (concat base "/__test__/truncated")) :type 'file-error))))

(ert-deftest zr-tramp-webdav-unsupported-operations-and-invalid-headers ()
  (let ((default-directory "/webdav:example.invalid:/dav/"))
    (should-error (process-file "echo" nil nil nil "test") :type 'file-error)
    (should-error (make-symbolic-link "a" (concat default-directory "b")) :type 'file-error))
  (should-error (zr-tramp-webdav--check-headers '(("Authorization" . "token\r\nX-Injected: yes")))
                :type 'file-error))

(ert-deftest zr-tramp-webdav-precious-save-and-conflict ()
  (zr-tramp-webdav-test--with-backends
    (dolist (name '("precious.txt" "precious-race.txt"))
      (let* ((file (concat root name)) buffer)
        (write-region "original\n" nil file nil 'silent)
        (setq buffer (find-file-noselect file))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (car zr-tramp-webdav--visited) file))
              (setq-local file-precious-flag t)
              (goto-char (point-max))
              (insert "edited\n")
              (if (equal name "precious-race.txt")
                  (progn
                    (should-error (save-buffer) :type 'file-error)
                    (should (buffer-modified-p))
                    (should (equal (buffer-string) "original\nedited\n"))
                    (should (equal (zr-tramp-webdav-test--contents file) "external winner\n")))
                (save-buffer)
                (should-not (buffer-modified-p))
                (should (verify-visited-file-modtime buffer))
                (should (equal (zr-tramp-webdav-test--contents file) "original\nedited\n"))))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(provide 'zr-tramp-webdav-test)
;;; zr-tramp-webdav-test.el ends here
