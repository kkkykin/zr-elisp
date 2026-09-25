;;; zr-tramp-rcrc-test.el --- TRAMP through rclone rc tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Name mapping tests always run.  Integration tests use isolated local
;; rcd processes when rclone is available, or RCLONE_TEST_PROGRAM names
;; its executable.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../zr-tramp-rcrc.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(ert-deftest zr-tramp-rcrc-rclone-paths-map-to-file-names ()
  (let ((url "http://127.0.0.1:5572/"))
    (dolist (case '(("fx:a/中 文 %?#.txt" "/rcrc:127.0.0.1#5572:/fx:/a/中 文 %?#.txt"
                     "fx:a/中 文 %?#.txt")
                    ("fx:" "/rcrc:127.0.0.1#5572:/fx:/" "fx:")
                    ("fx:dir/" "/rcrc:127.0.0.1#5572:/fx:/dir/" "fx:dir/")
                    ;; Remote-rooted paths share the name of NAME:path.
                    ("fx:/abs" "/rcrc:127.0.0.1#5572:/fx:/abs" "fx:abs")
                    ("/srv/media" "/rcrc:127.0.0.1#5572:/srv/media" "/srv/media")
                    ("C:\\Music\\a" "/rcrc:127.0.0.1#5572:/C:/Music/a" "C:/Music/a")
                    (nil "/rcrc:127.0.0.1#5572:/" nil)))
      (ert-info ((format "%S" (car case)))
        (let ((name (zr-tramp-rcrc-file-name url (car case))))
          (should (equal name (cadr case)))
          (should (zr-tramp-rcrc-file-name-p name))
          (should (equal (zr-tramp-rcrc-rclone-path name) (caddr case)))))))
  (dolist (path '("//host/share/x" ":webdav,url='https://h/':x" "remote,opt='a:b':x" "relative"))
    (should-error (zr-tramp-rcrc-file-name "http://h:1/" path) :type 'user-error))
  (should (equal (zr-tramp-rcrc-file-name "https://[::1]/rc/" "fx:a")
                 "/rcrc:[::1]#443:/fx:/a")))

(ert-deftest zr-tramp-rcrc-local-names-survive-emacs-file-functions ()
  (let ((file "/rcrc:host#5572:/fx:/a/b.txt"))
    (should (equal (file-name-directory file) "/rcrc:host#5572:/fx:/a/"))
    (should (equal (file-name-nondirectory file) "b.txt"))
    (should (equal (expand-file-name "../../.." file) "/rcrc:host#5572:/"))
    (should (equal (expand-file-name "../c" "/rcrc:host#5572:/fx:/a/") "/rcrc:host#5572:/fx:/c"))
    (should (equal (substitute-in-file-name file) file))
    (should (equal (directory-file-name "/rcrc:host#5572:/fx:/") "/rcrc:host#5572:/fx:"))
    (should (equal (file-remote-p file) "/rcrc:host#5572:"))
    (let ((vec (tramp-dissect-file-name file)))
      (should (equal (tramp-file-name-localname vec) "/fx:/a/b.txt"))
      (should (equal (tramp-file-name-port vec) "5572")))
    (dolist (case '(("/" . nil) ("/fx:" "fx:" . "") ("/fx:/a/b" "fx:" . "a/b")
                    ("/c:/x" "c:/" . "x") ("/srv/x" "/" . "srv/x")))
      (should (equal (zr-tramp-rcrc--fs (car case)) (cdr case))))))

(ert-deftest zr-tramp-rcrc-endpoints-and-credentials ()
  (let ((zr-tramp-rcrc--endpoints (make-hash-table :test #'equal))
        (zr-tramp-rcrc--connected (make-hash-table :test #'equal))
        (auth-sources nil))
    (should (equal (plist-get (zr-tramp-rcrc--endpoint
                               (tramp-dissect-file-name "/rcrc:Host#1234:/fx:/"))
                              :url)
                   "http://Host:1234/"))
    (zr-tramp-rcrc-register-endpoint "https://Proxy.example/rc" "alice" "secret")
    (let ((vec (tramp-dissect-file-name "/rcrc:proxy.example#443:/fx:/")))
      (should (equal (zr-tramp-rcrc--endpoint vec)
                     '(:url "https://Proxy.example/rc/" :user "alice" :password "secret"))))
    (should (equal (zr-tramp-rcrc-credentials "http://h:1/" "u" "p") '("u" . "p")))
    (should-not (zr-tramp-rcrc-credentials "http://h:1/"))
    (should (equal (zr-tramp-rcrc-basic-header '("ü" . "p")) "Basic w7w6cA==")))
  (should (equal (zr-tramp-rcrc-object-url "http://h:1/" "fx:" "a b/%?#.mkv")
                 "http://h:1/%5Bfx%3A%5D/a%20b/%25%3F%23.mkv")))

(ert-deftest zr-tramp-rcrc-background-requests-need-a-connected-rcd ()
  (let ((zr-tramp-rcrc--endpoints (make-hash-table :test #'equal))
        (zr-tramp-rcrc--connected (make-hash-table :test #'equal))
        (auth-sources nil)
        (tramp-verbose 0)
        (requests 0))
    (cl-letf (((symbol-function 'url-retrieve) (lambda (&rest _) (cl-incf requests) nil)))
      (cl-flet ((complete ()
                  ;; fido and icomplete complete with `non-essential' bound.
                  (let ((non-essential t))
                    (file-name-all-completions "" "/rcrc:127.0.0.1#9:/"))))
        (should-not (complete))
        (should (= requests 0))
        (zr-tramp-rcrc-register-endpoint "http://127.0.0.1:9/" "u" "p")
        (should-error (complete) :type 'file-error)
        ;; An rcd that cannot be reached is no longer contacted.
        (should-not (complete))
        (should (= requests 1))))))

(ert-deftest zr-tramp-rcrc-requests-keep-the-callers-point ()
  (let ((zr-tramp-rcrc--endpoints (make-hash-table :test #'equal))
        (zr-tramp-rcrc--connected (make-hash-table :test #'equal))
        (auth-sources nil)
        (vec (tramp-dissect-file-name "/rcrc:127.0.0.1#9:/fx:/")))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _)
                 (let ((response (generate-new-buffer " *zr-tramp-rcrc-test*")))
                   (with-current-buffer response
                     (setq-local url-http-response-status 200)
                     (insert "HTTP/1.1 200 OK\r\n\r\n{\"ok\":1}"))
                   ;; Timers run while the request waits, in the caller's buffer.
                   (run-at-time 0 nil (lambda ()
                                        (goto-char (point-min))
                                        (with-current-buffer response
                                          (funcall callback nil))))
                   response))))
      (with-temp-buffer
        (insert "Current path: /rcrc:127.0.0.1#9:/fx:/")
        (should (equal (zr-tramp-rcrc--call vec "rc/noop") '((ok . 1))))
        (should (= (point) (point-max)))))))

;;; Integration

(defvar zr-tramp-rcrc-test--servers nil
  "Running fixture daemons: (SERVE-P PROCESS ROOT PREFIX).")

(defun zr-tramp-rcrc-test--stop ()
  "Stop the fixture daemons and remove their directories."
  (dolist (server zr-tramp-rcrc-test--servers)
    (when (process-live-p (nth 1 server)) (delete-process (nth 1 server)))
    (when (file-directory-p (nth 2 server)) (delete-directory (nth 2 server) t)))
  (setq zr-tramp-rcrc-test--servers nil))

(add-hook 'kill-emacs-hook #'zr-tramp-rcrc-test--stop)

(defun zr-tramp-rcrc-test--start (serve)
  "Return (ROOT . PREFIX) of a running fixture rcd, with --rc-serve if SERVE."
  (let ((program (or (getenv "RCLONE_TEST_PROGRAM") (executable-find "rclone")))
        (server (assq serve zr-tramp-rcrc-test--servers)))
    (unless program (ert-skip "Set RCLONE_TEST_PROGRAM or install rclone"))
    (unless (and server (process-live-p (nth 1 server)))
      (let* ((root (make-temp-file "zr-tramp-rcrc-test-" t))
             (socket (make-network-process :name "zr-tramp-rcrc-test-port" :server t
                                           :host "127.0.0.1" :family 'ipv4
                                           :service t :noquery t))
             (port (process-contact socket :service))
             (url (format "http://127.0.0.1:%s/" port))
             (config (expand-file-name "rclone.conf" root))
             (process-environment (append '("RCLONE_RC_USER=test" "RCLONE_RC_PASS=secret")
                                          process-environment))
             (default-directory root)
             process)
        (delete-process socket)
        (make-directory (expand-file-name "data" root))
        (with-temp-file config
          (insert "[fixture]\ntype = alias\nremote = " (expand-file-name "data" root) "\n"))
        (setq process
              (make-process
               :name "zr-tramp-rcrc-test-rcd" :buffer nil :noquery t
               :command (append (list program "rcd" "--rc-addr" (format "127.0.0.1:%s" port)
                                      "--config" config
                                      "--cache-dir" (expand-file-name "cache" root))
                                (when serve '("--rc-serve")))))
        (zr-tramp-rcrc-register-endpoint url "test" "secret")
        (let ((vec (tramp-dissect-file-name (zr-tramp-rcrc-file-name url nil)))
              (deadline (+ (float-time) 10)) ready)
          (while (and (not ready) (< (float-time) deadline))
            (let ((zr-tramp-rcrc-timeout 0.5))
              (setq ready (ignore-errors (zr-tramp-rcrc--call vec "rc/noop") t)))
            (unless ready (accept-process-output nil 0.1)))
          (unless ready (error "Fixture rcd did not start")))
        (setq server (list serve process root (zr-tramp-rcrc-file-name url nil)))
        (push server zr-tramp-rcrc-test--servers)))
    (cons (nth 2 server) (nth 3 server))))

(defvar zr-tramp-rcrc-test--serial 0)

(defmacro zr-tramp-rcrc-test--with-server (&rest body)
  "Run BODY with LOCAL and REMOTE naming a fresh fixture directory."
  (declare (indent 0) (debug body))
  `(let* ((url-proxy-services '(("no_proxy" . ".*")))
          (auth-sources nil)
          (zr-tramp-rcrc-timeout 10)
          (tramp-verbose 0)
          (server (zr-tramp-rcrc-test--start t))
          (name (format "case-%d" (cl-incf zr-tramp-rcrc-test--serial)))
          (local (file-name-as-directory
                  (expand-file-name name (expand-file-name "data" (car server)))))
          (remote (concat (cdr server) "fixture:/" name "/")))
     (make-directory local)
     (zr-tramp-rcrc-clear-cache)
     ,@body))

(defun zr-tramp-rcrc-test--contents (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest zr-tramp-rcrc-real-listing-attributes-and-completion ()
  (zr-tramp-rcrc-test--with-server
    (let ((name "中 文 %?#.txt"))
      (make-directory (expand-file-name "dir" local))
      (write-region "0123456789" nil (expand-file-name name local) nil 'silent)
      (should (member "fixture:" (directory-files (cdr server))))
      (should (file-directory-p (concat (cdr server) "fixture:")))
      (should (equal (directory-files remote nil directory-files-no-dot-files-regexp)
                     (list "dir" name)))
      (should (file-directory-p (concat remote "dir")))
      (should (file-regular-p (concat remote name)))
      (should (= (file-attribute-size (file-attributes (concat remote name))) 10))
      (should-not (file-exists-p (concat remote "missing")))
      (should (equal (file-name-all-completions "d" remote) '("dir/")))
      ;; The minibuffer's own file completion table.
      (should (member "fixture:/" (all-completions (concat (cdr server) "fix")
                                                   #'read-file-name-internal)))
      (should (equal (completion-boundaries (concat remote "di") #'read-file-name-internal
                                            nil "")
                     (cons (length remote) 0)))
      (should (member "dir/" (all-completions (concat remote "di") #'read-file-name-internal)))
      (let ((buffer (dired-noselect remote)))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-search name (buffer-string))))
          (kill-buffer buffer))))))

(ert-deftest zr-tramp-rcrc-real-background-completion-reuses-connected-rcds ()
  (zr-tramp-rcrc-test--with-server
    (make-directory (expand-file-name "dir" local))
    (cl-flet ((complete ()
                (let ((non-essential t)) (file-name-all-completions "d" remote))))
      ;; The fixture rcd is registered.
      (should (equal (complete) '("dir/")))
      (zr-tramp-rcrc-clear-cache)
      ;; Otherwise it first has to answer an essential request.
      (let ((zr-tramp-rcrc--connected (make-hash-table :test #'equal)))
        (should-not (complete))
        (should (file-directory-p remote))
        (should (equal (complete) '("dir/")))))))

(ert-deftest zr-tramp-rcrc-real-visit-save-and-append ()
  (zr-tramp-rcrc-test--with-server
    (let ((file (concat remote "notes 中.txt")))
      (write-region "第一行\n" nil file nil 'silent)
      (should (equal (zr-tramp-rcrc-test--contents (expand-file-name "notes 中.txt" local))
                     "第一行\n"))
      (write-region "second\n" nil file t 'silent)
      (should (equal (zr-tramp-rcrc-test--contents file) "第一行\nsecond\n"))
      (let ((buffer (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (buffer-string) "第一行\nsecond\n"))
              (should (verify-visited-file-modtime buffer))
              (goto-char (point-max))
              (insert "third\n")
              (save-buffer)
              (should-not (buffer-modified-p))
              (should (verify-visited-file-modtime buffer))
              ;; Another writer changes the file.
              (sleep-for 1.1)
              (write-region "other\n" nil (expand-file-name "notes 中.txt" local) nil 'silent)
              (should-not (verify-visited-file-modtime buffer)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (let ((missing (concat remote "missing.txt")))
        (should-error (zr-tramp-rcrc-test--contents missing) :type 'file-missing)
        (let ((buffer (find-file-noselect missing)))
          (unwind-protect
              (with-current-buffer buffer
                (insert "created")
                (save-buffer))
            (kill-buffer buffer)))
        (should (equal (zr-tramp-rcrc-test--contents missing) "created\n"))))))

(ert-deftest zr-tramp-rcrc-real-copy-rename-and-delete ()
  (zr-tramp-rcrc-test--with-server
    (let ((temp (make-temp-file "zr-tramp-rcrc-local-")))
      (unwind-protect
          (progn
            (write-region "local bytes \377" nil temp nil 'silent)
            ;; Local to rcd, into a directory name.
            (make-directory (concat remote "a/b") t)
            (should-error (make-directory (concat remote "x/y")) :type 'file-missing)
            (should-error (make-directory (concat remote "a")) :type 'file-already-exists)
            (copy-file temp (concat remote "a/"))
            (let ((uploaded (concat remote "a/" (file-name-nondirectory temp))))
              (should (file-exists-p uploaded))
              (should-error (copy-file temp uploaded) :type 'file-already-exists)
              ;; Server-side copy and rename.
              (copy-file uploaded (concat remote "copy.bin"))
              (rename-file (concat remote "copy.bin") (concat remote "a/b/moved.bin"))
              (should-not (file-exists-p (concat remote "copy.bin")))
              ;; Back to the local file system, with bytes intact.
              (copy-file (concat remote "a/b/moved.bin") temp t)
              (should (equal (with-temp-buffer
                               (set-buffer-multibyte nil)
                               (insert-file-contents-literally temp)
                               (buffer-string))
                             "local bytes \377")))
            ;; Directory rename on the server.
            (rename-file (concat remote "a") (concat remote "renamed"))
            (should-not (file-exists-p (expand-file-name "a" local)))
            (should (file-exists-p (expand-file-name "renamed/b/moved.bin" local)))
            (should-error (delete-directory (concat remote "renamed")))
            (delete-file (concat remote "renamed/b/moved.bin"))
            (delete-directory (concat remote "renamed/b"))
            (delete-directory (concat remote "renamed") t)
            (should-not (directory-files local nil directory-files-no-dot-files-regexp))
            (should-error (delete-directory (concat (cdr server) "fixture:") t)))
        (delete-file temp)))))

(ert-deftest zr-tramp-rcrc-real-reading-requires-rc-serve ()
  (let ((url-proxy-services '(("no_proxy" . ".*")))
        (auth-sources nil)
        (tramp-verbose 0))
    (let* ((server (zr-tramp-rcrc-test--start nil))
           (file (concat (cdr server) "fixture:/unserved.txt")))
      (write-region "x" nil (expand-file-name "data/unserved.txt" (car server)) nil 'silent)
      (zr-tramp-rcrc-clear-cache)
      (should (file-exists-p file))
      (should (string-match-p "--rc-serve"
                              (error-message-string
                               (should-error (zr-tramp-rcrc-test--contents file))))))))

(provide 'zr-tramp-rcrc-test)
;;; zr-tramp-rcrc-test.el ends here
