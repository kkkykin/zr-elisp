;;; zr-http-test.el --- Shared HTTP transport tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'zr-http)
(require 'zr-test-helpers)

(defconst zr-http-test--server-file
  (expand-file-name "http-server.py" (file-name-directory (or load-file-name buffer-file-name))))

(defmacro zr-http-test--server (&rest body)
  "Run BODY against a fresh local HTTP fixture, with URL bound."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (and (executable-find "curl") (executable-find "python3")))
     (let* ((buffer (generate-new-buffer " *zr-http-test-server*"))
            (process (make-process :name "zr-http-test-server" :buffer buffer :noquery t
                                   :command (list "python3" "-u" zr-http-test--server-file)
                                   :connection-type 'pipe :coding 'utf-8-unix))
            (zr-http-default-options '(:proxy nil :timeout 3))
            (deadline (+ (float-time) 3)) url)
       (unwind-protect
           (progn
             (while (and (not url) (< (float-time) deadline))
               (accept-process-output process 0.05)
               (with-current-buffer buffer
                 (when (string-match "PORT \\([0-9]+\\)" (buffer-string))
                   (setq url (concat "http://127.0.0.1:" (match-string 1 (buffer-string)))))))
             (unless url (error "HTTP fixture failed to start"))
             ,@body)
         (when (process-live-p process) (delete-process process))
         (kill-buffer buffer)))))

(defun zr-http-test--wait (request)
  "Wait for REQUEST, bounding fixture failures."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (zr-http-request-done request)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (zr-http-request-done request))))

(ert-deftest zr-http-options-precedence-and-header-deletion ()
  (let* ((defaults '(:timeout 30 :proxy "localhost:8080" :curl-arguments ("--ipv4")
                    :headers (("Accept" . "text/plain") ("X-Delete" . "secret"))))
         (package '(:timeout 10 :headers (("accept" . "application/json"))))
         (options (zr-http-options defaults package '(:proxy nil :curl-arguments nil
                                                     :headers (("x-delete" . nil))))))
    (should (= 10 (plist-get options :timeout)))
    (should (plist-member options :proxy))
    (should-not (plist-get options :proxy))
    (should-not (plist-get options :curl-arguments))
    (should (equal (zr-http--check-headers (plist-get options :headers))
                   '(("accept" . "application/json"))))
    (should (equal (plist-get defaults :headers)
                   '(("Accept" . "text/plain") ("X-Delete" . "secret"))))
    (should-not (plist-get (zr-http-options defaults '(:headers nil)) :headers))))

(ert-deftest zr-http-curl-arguments-case-sensitive ()
  (dolist (case-fold-search '(t nil))
    (dolist (arguments '(("-k" "-x" "http://127.0.0.1:8080")
                        ("-kx" "http://127.0.0.1:8080")
                        ("--insecure")
                        ("--cacert" "/tmp/mitmproxy-ca-cert.pem")))
      (should (equal arguments (zr-http--extra-arguments arguments))))
    (dolist (argument '("-K" "-K/tmp/curl.conf" "-X" "-XPOST" "-I" "-T"
                        "-d" "-o" "--config" "--output=/tmp/output"))
      (should-error (zr-http--extra-arguments (list argument))))))

(ert-deftest zr-http-real-methods-binary-and-http-errors ()
  (zr-http-test--server
    (let ((bytes (apply #'unibyte-string (number-sequence 0 255))))
      (should (equal bytes (plist-get (zr-http-request-sync (concat url "/bytes")) :body)))
      (dolist (method '("POST" "PUT" "PROPFIND" "COPY" "MOVE" "DELETE"))
        (let* ((response (zr-http-request-sync (concat url "/inspect") :method method :body bytes))
               (data (json-parse-string (decode-coding-string (plist-get response :body) 'utf-8)
                                        :object-type 'plist)))
          (should (equal method (plist-get data :method)))
          (should (equal bytes (base64-decode-string (plist-get data :body))))))
      (should (equal "" (plist-get (zr-http-request-sync (concat url "/bytes") :method "HEAD") :body)))
      (let ((response (zr-http-request-sync (concat url "/error"))))
        (should (= 404 (plist-get response :status)))
        (should (equal "{\"error\":\"missing\"}" (plist-get response :body))))
      (let ((response (zr-http-request-sync (concat url "/redirect")
                                           :curl-arguments '("--location-trusted"))))
        (should (= 302 (plist-get response :status)))
        (should (equal (concat url "/redirect") (plist-get response :url)))))))

(ert-deftest zr-http-final-headers-and-repeated-fields ()
  (zr-http-test--server
    (let ((response (zr-http-request-sync (concat url "/headers"))))
      (should (= 200 (plist-get response :status)))
      (should-not (assoc "link" (plist-get response :headers)))
      (should (equal (cl-remove-if-not (lambda (h) (equal (car h) "set-cookie"))
                                      (plist-get response :headers))
                     '(("set-cookie" . "a=1") ("set-cookie" . "b=2")))))))

(ert-deftest zr-http-captures-options-and-merges-request-headers ()
  (zr-http-test--server
    (let ((source (generate-new-buffer " *zr-http-test-source*")) request)
      (unwind-protect
          (progn
            (with-current-buffer source
              (setq-local zr-http-default-options
                          '(:proxy nil :timeout 3
                            :headers (("X-Global" . "global") ("X-Delete" . "secret"))))
              (setq request
                    (zr-http-request
                     (concat url "/inspect")
                     :options '(:headers (("X-Package" . "package") ("X-Global" . "package")))
                     :headers '(("X-Global" . "request") ("x-delete" . nil))))
              (setq-local zr-http-default-options '(:proxy "127.0.0.1:9")))
            (kill-buffer source)
            (zr-http-test--wait request)
            (should-not (zr-http-request-error request))
            (let* ((data (json-parse-string
                          (decode-coding-string (plist-get (zr-http-request-response request) :body) 'utf-8)
                          :object-type 'alist))
                   (headers (alist-get 'headers data)))
              (should (equal "request" (alist-get 'X-Global headers)))
              (should (equal "package" (alist-get 'X-Package headers)))
              (should-not (alist-get 'X-Delete headers))))
        (when (buffer-live-p source) (kill-buffer source))
        (when request (zr-http-cancel request))))))

(ert-deftest zr-http-staged-downloads-and-streaming-limits ()
  (zr-http-test--server
    (zr-test-with-temp-directory
      (let* ((temporary-file-directory default-directory)
             (target (expand-file-name "download"))
             (bytes (apply #'unibyte-string (number-sequence 0 255))))
        (write-region "original" nil target nil 'silent)
        (dolist (path '("/partial" "/slow"))
          (should-error (zr-http-request-sync (concat url path) :timeout 0.1 :output-file target)
                        :type 'zr-http-error)
          (should (equal "original" (with-temp-buffer (insert-file-contents target) (buffer-string)))))
        (dolist (path '("/bytes" "/chunked"))
          (should-error (zr-http-request-sync (concat url path) :max-bytes 100 :output-file target)
                        :type 'zr-http-error)
          (should (equal "original" (with-temp-buffer (insert-file-contents target) (buffer-string)))))
        (let ((response (zr-http-request-sync (concat url "/chunked") :output-file target :max-bytes 256)))
          (should (equal target (plist-get response :file)))
          (should-not (plist-member response :body))
          (should (equal bytes (with-temp-buffer (set-buffer-multibyte nil)
                                                (insert-file-contents-literally target) (buffer-string)))))
        (should (equal '("download") (directory-files default-directory nil "\\`[^.]")))
        (should-not (directory-files default-directory nil "\\`\\.zr-http-"))))))

(ert-deftest zr-http-upload-files-forms-and-private-auth ()
  (zr-http-test--server
    (zr-test-with-temp-directory
      (let* ((file (expand-file-name "quote\"comma,semi;slash\\猫.bin"))
             (bytes (unibyte-string 0 1 255 10))
             (user "a\"b\\c") (password "d\"e\\f"))
        (zr-http--write-bytes bytes file)
        (should (equal bytes (plist-get (zr-http-request-sync (concat url "/echo") :upload-file file) :body)))
        (let* ((response (zr-http-request-sync
                          (concat url "/inspect")
                          :auth (list :scheme 'basic :user user :password password)))
               (data (json-parse-string (decode-coding-string (plist-get response :body) 'utf-8) :object-type 'alist))
               (headers (alist-get 'headers data)))
          (should (equal (concat "Basic " (base64-encode-string (concat user ":" password) t))
                         (alist-get 'Authorization headers))))
        (let ((response (zr-http-request-sync (concat url "/echo")
                                              :form (list '("literal" . "@a;b,c")
                                                          (cons "file" (list :file file :filename "猫;,.bin"))))))
          (should (string-search "@a;b,c" (plist-get response :body)))
          (should (string-search bytes (plist-get response :body)))
          (should (string-search "filename*=utf-8''%E7%8C%AB%3B%2C.bin" (plist-get response :body))))))))

(ert-deftest zr-http-cancel-and-timeout-call-back-once ()
  (zr-http-test--server
    (dolist (cancel '(nil t))
      (let* ((calls 0) failure
             (request (zr-http-request (concat url "/slow") :timeout 0.05
                                       :callback (lambda (_response error) (cl-incf calls) (setq failure error)))))
        (when cancel (zr-http-cancel request))
        (zr-http-test--wait request)
        (zr-http-cancel request)
        (should (= calls 1))
        (should failure)
        (should-not (process-live-p (zr-http-request-process request)))
        (should-not (cl-some #'buffer-live-p (zr-http-request-buffers request)))
        (should-not (cl-some #'file-exists-p (zr-http-request-files request)))))))

(ert-deftest zr-http-publish-failure-returns-only-an-error ()
  (zr-http-test--server
    (zr-test-with-temp-directory
      (let* ((target (expand-file-name "directory"))
             response failure
             (_directory (make-directory target))
             (request (zr-http-request (concat url "/bytes") :output-file target
                                       :callback (lambda (value error) (setq response value failure error)))))
        (zr-http-test--wait request)
        (should failure)
        (should-not response)
        (should (file-directory-p target))
        (should-not (directory-files default-directory nil "\\`\\.zr-http-"))))))

(ert-deftest zr-http-validation-startup-and-quit-clean-up ()
  (zr-test-with-temp-directory
    (let ((temporary-file-directory default-directory))
      (dolist (options '((:curl-program "/no-such-curl") (:body "猫") (:max-bytes -1)
                        (:headers (("X" . "a\nb"))) (:curl-arguments ("--next"))
                        (:curl-arguments ("--output=/tmp/output")) (:timeout 0)))
        (should-error (apply #'zr-http-request "http://127.0.0.1/" options))
        (should-not (directory-files default-directory nil "\\`[^.]")))
      (zr-http-test--server
        (let ((original (symbol-function 'accept-process-output)))
          (cl-letf (((symbol-function 'accept-process-output)
                     (lambda (&rest args)
                       (apply original args)
                       (signal 'quit nil))))
            (should (eq 'quit (condition-case nil
                                 (zr-http-request-sync (concat url "/slow"))
                               (quit 'quit)))))
          (should-not (directory-files default-directory nil "\\`[^.]")))))))

(ert-deftest zr-http-sync-preserves-point-through-timers ()
  (zr-http-test--server
    (with-temp-buffer
      (insert "caller")
      (let ((timer (run-at-time 0 nil (lambda () (goto-char (point-min))))))
        (unwind-protect
            (progn (zr-http-request-sync (concat url "/slow"))
                   (should (= (point) (point-max))))
          (cancel-timer timer))))))

(provide 'zr-http-test)
