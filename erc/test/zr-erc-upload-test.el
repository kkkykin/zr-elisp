;;; zr-erc-upload-test.el --- Tests for ERC uploads -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(eval-and-compile
  (load (expand-file-name "../zr-erc-upload.el"
                          (file-name-directory
                           (or load-file-name
                               (bound-and-true-p byte-compile-current-file)
                               buffer-file-name)))
        nil 'nomessage))

(defmacro zr-erc-upload-test--conversation (&rest body)
  "Run BODY in a connected conversation without contacting an IRC server."
  (declare (indent 0) (debug t))
  (let ((buffer (make-symbol "conversation")))
    `(let ((,buffer (generate-new-buffer " *erc-upload-test*")))
       (unwind-protect
           (with-current-buffer ,buffer
             (setq major-mode 'erc-mode)
             (setq-local erc-default-recipients '("#uploads")
                         erc-server-process 'test-connection)
             (cl-letf (((symbol-function 'erc-server-process-alive) (lambda () t)))
               ,@body))
         (when (buffer-live-p ,buffer) (kill-buffer ,buffer))))))

(defun zr-erc-upload-test--read (file)
  "Read FILE as bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun zr-erc-upload-test--wait (predicate)
  "Wait up to five seconds for PREDICATE."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun zr-erc-upload-test--buffers ()
  "Return buffers owned by the curl backend."
  (cl-remove-if-not (lambda (buffer)
                      (string-match-p "\\` \\*erc-upload-\\(?:response\\|errors\\)"
                                      (buffer-name buffer)))
                    (buffer-list)))

(defun zr-erc-upload-test--server (function)
  "Call FUNCTION with a local HTTP endpoint and a request-list getter."
  (let (server clients requests)
    (unwind-protect
        (progn
          (setq server
                (make-network-process
                 :name "erc-upload-test-http" :server t :host "127.0.0.1"
                 :service t :family 'ipv4 :coding 'binary :noquery t
                 :log
                 (lambda (_server client _event)
                   (push client clients)
                   (set-process-filter
                    client
                    (lambda (proc chunk)
                      (let* ((data (concat (process-get proc 'request) chunk))
                             (end (string-match "\r\n\r\n" data)))
                        (process-put proc 'request data)
                        (when (and end (not (process-get proc 'responded))
                                   (string-match "Content-Length: \\([0-9]+\\)" data)
                                   (>= (- (string-bytes data) end 4)
                                       (string-to-number (match-string 1 data))))
                          (process-put proc 'responded t)
                          (push data requests)
                          (unless (string-prefix-p "POST /hang " data)
                            (let* ((bad (string-prefix-p "POST /error " data))
                                   (body (cond (bad "Rejected")
                                               ((string-prefix-p "POST /bad " data)
                                                "Not a URL")
                                               (t "https://example.test/cutie.png\n"))))
                              (process-send-string
                               proc (format "HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                                            (if bad "500 Error" "200 OK")
                                            (string-bytes body) body))
                              (process-send-eof proc))))))))))
          (funcall function
                   (format "http://127.0.0.1:%d" (process-contact server :service))
                   (lambda () requests)))
      (dolist (process (cons server clients))
        (when (and process (process-live-p process))
          (delete-process process))))))

(ert-deftest zr-erc-upload-link-formats ()
  (let ((url "https://example.test/a?x=1&y=2") (file "/tmp/猫.png"))
    (should (equal (zr-erc-upload--message url file "[%f](%u) %%")
                   "[猫.png](https://example.test/a?x=1&y=2) %"))
    (should (equal (zr-erc-upload--message
                    url file (lambda (link name) (concat name ": " link)))
                   (concat file ": " url)))
    (dolist (bad '(nil "" "Error" "https://" "file:///tmp/a"
                  "https://example.test/a\nJOIN #other"))
      (should-error (zr-erc-upload--message bad file "%u")))
    (dolist (bad '("" " \t " "%u\nother" "%u\r" "%u\0" "%z"))
      (should-error (zr-erc-upload--message url file bad)))))

(ert-deftest zr-erc-upload-custom-backend-origin-and-draft ()
  (let ((file (make-temp-file "erc-upload-source-")) callback origin sent
        (cancellations 0))
    (unwind-protect
        (zr-erc-upload-test--conversation
          (setq origin (current-buffer))
          (insert "draft text")
          (goto-char 4)
          (setq buffer-read-only t)
          (let* ((zr-erc-upload-backend 'custom)
                 (zr-erc-upload-link-format "/say %f %u")
                 (zr-erc-upload-backends
                  `((custom . ,(lambda (path done)
                                 (should (eq (current-buffer) origin))
                                 (should (equal path file))
                                 (setq callback done)
                                 (lambda () (cl-incf cancellations))))))
                 (job (zr-erc-upload-file file)))
            (setq zr-erc-upload-link-format "changed")
            (cl-letf (((symbol-function 'erc-send-input)
                       (lambda (text &rest _)
                         (should (eq (current-buffer) origin))
                         (should-not (string-match-p erc-command-regexp text))
                         (push text sent)
                         (goto-char (point-max))
                         t)))
              (with-temp-buffer (funcall callback "https://example.test/a" nil))
              (funcall callback "https://example.test/duplicate" nil))
            (should (equal sent (list (concat "/say " (file-name-nondirectory file)
                                              " https://example.test/a"))))
            (should (= (point) 4))
            (should (equal (buffer-string) "draft text"))
            (should buffer-read-only)
            (should (zr-erc-upload--job-done job))
            (should-not zr-erc-upload--jobs)
            (should-not (memq #'zr-erc-upload-cancel kill-buffer-hook))
            (should (= cancellations 1))
            (should (file-exists-p file))))
      (delete-file file))))

(ert-deftest zr-erc-upload-synchronous-and-startup-failures ()
  (zr-erc-upload-test--conversation
    (let ((cancellations 0) sent
          (zr-erc-upload-backend 'custom))
      (cl-letf (((symbol-function 'erc-send-input)
                 (lambda (text &rest _) (push text sent) t)))
        (let* ((file (make-temp-file "erc-upload-owned-"))
               (zr-erc-upload-backends
                `((custom . ,(lambda (_file done)
                               (funcall done "https://example.test/a" nil)
                               (lambda () (cl-incf cancellations)))))))
          (zr-erc-upload--start file nil t)
          (should-not (file-exists-p file))
          (should (= cancellations 1))
          (should (equal sent '("https://example.test/a"))))))
    (dolist (backend '(missing failure))
      (let ((file (make-temp-file "erc-upload-owned-"))
            (zr-erc-upload-backend backend)
            (zr-erc-upload-backends '((failure . (lambda (&rest _) (error "Start failed"))))))
        (should-error (zr-erc-upload--start file nil t))
        (should-not (file-exists-p file))
        (should-not zr-erc-upload--jobs)))))

(ert-deftest zr-erc-upload-yank-media-binary-and-cancellation ()
  (let ((bytes (unibyte-string 137 80 78 71 0 255 13 10))
        file callback sent (cancellations 0))
    (zr-erc-upload-test--conversation
      (zr-erc-upload--install)
      (let ((zr-erc-upload-backend 'custom)
            (zr-erc-upload-backends
             `((custom . ,(lambda (path done)
                            (setq file path callback done)
                            (lambda () (cl-incf cancellations)))))))
        (cl-letf (((symbol-function 'gui-get-selection)
                   (lambda (_selection type)
                     (if (eq type 'TARGETS) [image/png] bytes)))
                  ((symbol-function 'image-type-available-p) (lambda (_) t))
                  ((symbol-function 'erc-send-input) (lambda (&rest _) (setq sent t))))
          (yank-media)
          (should (string-suffix-p ".png" file))
          (should (equal (zr-erc-upload-test--read file) bytes))
          (zr-erc-upload-cancel)
          (zr-erc-upload-cancel)
          (funcall callback "https://example.test/late" nil)
          (should-not sent)
          (should-not (file-exists-p file))
          (should (= cancellations 1))
          ;; Killing the originating buffer also cancels and deletes the image.
          (yank-media))))
    (should-not (file-exists-p file))
    (should (= cancellations 2))))

(ert-deftest zr-erc-upload-copied-files-and-uri-list ()
  (let* ((directory (make-temp-file "erc-upload-files-" t))
         (file (expand-file-name "a b.txt" directory))
         (uri (concat "file://" (string-replace " " "%20" file)))
         uploaded)
    (unwind-protect
        (progn
          (write-region "source" nil file nil 'silent)
          (zr-erc-upload-test--conversation
            (zr-erc-upload--install)
            (let ((zr-erc-upload-backend 'custom)
                  (zr-erc-upload-backends
                   `((custom . ,(lambda (path done)
                                  (push path uploaded)
                                  (funcall done "https://example.test/a" nil)
                                  #'ignore)))))
              (cl-letf (((symbol-function 'erc-send-input) (lambda (&rest _) t)))
                (dolist (type zr-erc-upload--file-types)
                  (let ((data (concat (if (eq type 'text/uri-list) "# comment\r\n" "cut\n")
                                      uri "\n" uri "\0")))
                    (cl-letf (((symbol-function 'gui-get-selection)
                               (lambda (_selection requested)
                                 (if (eq requested 'TARGETS) (vector type) data))))
                      (yank-media))))
                (should (= (length uploaded) 4))
                (should (cl-every (lambda (path) (equal path file)) uploaded))
                (should (equal (zr-erc-upload-test--read file) "source"))
                (setq uploaded nil)
                (dolist (data (list (concat uri "\nhttps://example.test/a")
                                   "file://otherhost/tmp/a" "copy\n"))
                  (should-error (zr-erc-upload--yank 'text/uri-list data) :type 'user-error))
                (should-not uploaded)))))
      (delete-directory directory t))))

(ert-deftest zr-erc-upload-changed-conversation-does-not-send ()
  (dolist (change '(target connection disconnected))
    (zr-erc-upload-test--conversation
      (let* ((file (make-temp-file "erc-upload-owned-")) callback sent
             (zr-erc-upload-backend 'custom)
             (zr-erc-upload-backends
              `((custom . ,(lambda (_file done) (setq callback done) #'ignore)))))
        (zr-erc-upload--start file nil t)
        (pcase change
          ('target (setq erc-default-recipients '("#other")))
          ('connection (setq erc-server-process 'another-connection)))
        (cl-letf (((symbol-function 'erc-server-process-alive)
                   (lambda () (not (eq change 'disconnected))))
                  ((symbol-function 'erc-send-input) (lambda (&rest _) (setq sent t))))
          (funcall callback "https://example.test/a" nil))
        (should-not sent)
        (should-not (file-exists-p file))
        (should-not zr-erc-upload--jobs)))))

(ert-deftest zr-erc-upload-module-lifecycle ()
  (let ((erc-zr-upload-mode nil) (erc-modules nil)
        (handlers yank-media--registered-handlers)
        (preferred yank-media-preferred-types))
    (unwind-protect
        (zr-erc-upload-test--conversation
          (setq-local yank-media--registered-handlers '((text/html . ignore)))
          (erc-zr-upload-mode 1)
          (erc-zr-upload-mode 1)
          (should (eq (alist-get 'text/uri-list yank-media--registered-handlers)
                      #'zr-erc-upload--yank))
          (with-temp-buffer
            (erc-mode)
            (should zr-erc-upload--yank-state))
          (with-temp-buffer (should-not zr-erc-upload--yank-state))
          (erc-zr-upload-mode -1)
          (erc-zr-upload-mode -1)
          (should (equal yank-media--registered-handlers '((text/html . ignore))))
          (should (local-variable-p 'yank-media--registered-handlers))
          (should-not (local-variable-p 'yank-media-preferred-types))
          (should-not (memq #'zr-erc-upload--install erc-mode-hook)))
      (erc-zr-upload-mode -1))
    (should (equal handlers yank-media--registered-handlers))
    (should (equal preferred yank-media-preferred-types))))

(ert-deftest zr-erc-upload-real-curl-multipart ()
  (skip-unless (executable-find "curl"))
  (let* ((directory (make-temp-file "erc-upload-http-" t))
         (file (expand-file-name "cutie,semi;quote\"slash\\猫.png" directory))
         (bytes (unibyte-string 0 1 137 255 10)) sent)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil file nil 'silent))
          (zr-erc-upload-test--server
           (lambda (base requests)
             (zr-erc-upload-test--conversation
               (let ((zr-erc-upload-litterbox-url (concat base "/upload"))
                     (zr-erc-upload-curl-arguments '("--header" "X-Test: erc-upload"))
                     (zr-erc-upload-litterbox-time "12h"))
                 (cl-letf (((symbol-function 'erc-send-input)
                            (lambda (text &rest _) (push text sent) t)))
                   (let ((job (zr-erc-upload-file file)))
                     (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job))))
                   (should (equal sent '("https://example.test/cutie.png")))
                   (should-not zr-erc-upload--jobs)
                   (should-not (zr-erc-upload-test--buffers))
                   (let ((request (car (funcall requests))))
                     (should (string-match-p "X-Test: erc-upload" request))
                     (should (string-match-p "name=\"reqtype\"\r\n\r\nfileupload\r\n" request))
                     (should (string-match-p "name=\"time\"\r\n\r\n12h\r\n" request))
                     (should (string-match-p "name=\"fileToUpload\"; filename=" request))
                     (should (string-search bytes request)))
                   (should (equal (zr-erc-upload-test--read file) bytes))))))))
      (delete-directory directory t))))

(ert-deftest zr-erc-upload-real-curl-failures-and-cancel ()
  (skip-unless (executable-find "curl"))
  (zr-erc-upload-test--server
   (lambda (base requests)
     (dolist (path '("/error" "/bad" "/hang" "/cancel"))
       (zr-erc-upload-test--conversation
         (let ((zr-erc-upload-litterbox-url
                (concat base (if (equal path "/cancel") "/hang" path)))
               (zr-erc-upload-timeout 1) sent
               (file (make-temp-file "erc-upload-owned-")))
           (cl-letf (((symbol-function 'erc-send-input) (lambda (&rest _) (setq sent t))))
             (let ((job (zr-erc-upload--start file nil t)))
               (when (equal path "/cancel")
                 (zr-erc-upload-test--wait
                  (lambda () (>= (length (funcall requests)) 4)))
                 (zr-erc-upload-cancel))
               (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job))))
             (should-not sent)
             (should-not (file-exists-p file))
             (should-not zr-erc-upload--jobs)
             (should-not (zr-erc-upload-test--buffers)))))))))

(provide 'zr-erc-upload-test)
;;; zr-erc-upload-test.el ends here
