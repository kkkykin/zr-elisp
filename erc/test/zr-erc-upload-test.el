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

(defconst zr-erc-upload-test--image-bytes
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAIAAADZSiLoAAAAGUlEQVR4nGPQWHAHghgCFtyBIIaKBXcgCADkZhAtDLUN4QAAAABJRU5ErkJggg==")
  "A valid PNG used for binary uploads and image type detection.")

(defmacro zr-erc-upload-test--conversation (&rest body)
  "Run BODY in a connected conversation without contacting an IRC server."
  (declare (indent 0) (debug t))
  (let ((buffer (make-symbol "conversation")))
    `(let ((,buffer (generate-new-buffer " *erc-upload-test*")))
       (unwind-protect
           (with-current-buffer ,buffer
             (setq major-mode 'erc-mode)
             (setq-local erc-default-recipients '("#uploads")
                         erc-server-process 'test-connection
                         erc-input-marker (copy-marker (point)))
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
                      (string-match-p "\\` \\*zr-http-\\(?:body\\|errors\\)"
                                      (buffer-name buffer)))
                    (buffer-list)))

(defmacro zr-erc-upload-test--endpoint (url &rest body)
  "Run BODY redirecting HTTP requests to the local test URL.
URL may be a function mapping each original URL to a local endpoint."
  (declare (indent 1) (debug t))
  (let ((request (make-symbol "request"))
        (endpoint (make-symbol "endpoint")))
    `(let ((,request (symbol-function 'zr-http-request))
           (,endpoint ,url))
       (cl-letf (((symbol-function 'zr-http-request)
                  (lambda (original &rest args)
                    (apply ,request
                           (if (functionp ,endpoint)
                               (funcall ,endpoint original) ,endpoint)
                           args))))
         ,@body))))

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
                                               ((string-prefix-p "POST /tempfile " data)
                                                "{\"success\":true,\"files\":[{\"id\":\"file42\",\"url\":\"https://example.test/file/\"}]}")
                                               ((string-prefix-p "POST /tmp0 " data)
                                                "{\"success\":true,\"fileId\":\"file42\",\"url\":\"/d/file\",\"fullUrl\":\"https://example.test/d/file\",\"directDownloadUrl\":\"https://example.test/api/file/file/download\"}")
                                               ((string-prefix-p "POST /json-error " data)
                                                "{\"success\":false,\"error\":\"File rejected\"}")
                                               ((string-prefix-p "POST /json-bad " data)
                                                "{broken json}")
                                               ((string-prefix-p "POST /json-no-url " data)
                                                "{\"success\":true,\"files\":[]}")
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
    (dolist (bad '(nil "" "Error" "https://" "https:///file"
                  "https://?file" "https://#file" "file:///tmp/a"
                  "https://example.test/a\nJOIN #other"))
      (should-error (zr-erc-upload--message bad file "%u")))
    (dolist (bad '("" " \t " "%u\nother" "%u\r" "%u\0" "%z"))
      (should-error (zr-erc-upload--message url file bad)))))

(ert-deftest zr-erc-upload-inserts-in-origin-input ()
  (let ((file (make-temp-file "erc-upload-source-")) callback sent)
    (unwind-protect
        (zr-erc-upload-test--conversation
          (insert "history\n")
          (erc-display-prompt nil nil "ERC> ")
          (insert "draft")
          (let* ((zr-erc-upload-backend-order '(custom))
                 (zr-erc-upload-backends
                  `((custom . ,(lambda (_path done)
                                 (setq callback done)
                                 #'ignore))))
                 (job (zr-erc-upload-file file)))
            ;; Use the latest draft but the setting from upload startup.
            (setq-local zr-erc-upload-auto-send t)
            (insert " more")
            (goto-char 4)
            (setq buffer-read-only t)
            (save-restriction
              (narrow-to-region (point-min) 5)
              (cl-letf (((symbol-function 'erc-send-input)
                         (lambda (&rest _) (setq sent t))))
                (with-temp-buffer (funcall callback "https://example.test/a" nil))
                (funcall callback "https://example.test/duplicate" nil))
              (should (= (point) 4))
              (should (= (point-max) 5)))
            (should-not sent)
            (should (equal (erc-user-input) "draft more https://example.test/a"))
            (should (equal (buffer-substring-no-properties (point-min) erc-input-marker)
                           "history\nERC> "))
            (should buffer-read-only)
            (should (zr-erc-upload--job-done job))
            (should-not zr-erc-upload--jobs)
            (should (file-exists-p file))))
      (delete-file file))))

(ert-deftest zr-erc-upload-auto-send-origin-and-draft ()
  (let ((file (make-temp-file "erc-upload-source-")) callback origin sent
        (cancellations 0))
    (unwind-protect
        (zr-erc-upload-test--conversation
          (setq origin (current-buffer))
          (insert "draft text")
          (goto-char 4)
          (setq buffer-read-only t)
          (setq-local zr-erc-upload-auto-send t)
          (let* ((zr-erc-upload-backend-order '(custom))
                 (zr-erc-upload-link-format "/say %f %u")
                 (zr-erc-upload-backends
                  `((custom . ,(lambda (path done)
                                 (should (eq (current-buffer) origin))
                                 (should (equal path file))
                                 (setq callback done)
                                 (lambda () (cl-incf cancellations))))))
                 (job (zr-erc-upload-file file)))
            (setq zr-erc-upload-link-format "changed")
            (setq-local zr-erc-upload-auto-send nil)
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
          (zr-erc-upload-backend-order '(custom)))
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
          (should-not sent)
          (should (equal (erc-user-input) "https://example.test/a")))))
    (dolist (backend '(missing failure))
      (let ((file (make-temp-file "erc-upload-owned-"))
            (zr-erc-upload-backend-order (list backend))
            (zr-erc-upload-backends '((failure . (lambda (&rest _) (error "Start failed"))))))
        (if (eq backend 'missing)
            (should-error (zr-erc-upload--start file nil t))
          (should (zr-erc-upload--job-done (zr-erc-upload--start file nil t))))
        (should-not (file-exists-p file))
        (should-not zr-erc-upload--jobs)))))

(ert-deftest zr-erc-upload-fallback-preserves-origin-file-and-settings ()
  (zr-erc-upload-test--conversation
    (let* ((origin (current-buffer))
           (file (make-temp-file "erc-upload-owned-")) first second calls cancellations
           (zr-erc-upload-backend-order '(first second unused))
           (zr-erc-upload-expiry-hours 6)
           (zr-erc-upload-http-options '(:timeout 10))
           (zr-erc-upload-backends
            `((first . ,(lambda (_path done)
                          (push 'first calls)
                          (setq first done)
                          (lambda ()
                            (push 'first cancellations)
                            (funcall done nil "Cancellation callback"))))
              (second . ,(lambda (path done)
                           (should (eq (current-buffer) origin))
                           (should (equal path file))
                           (should (file-exists-p file))
                           (should (equal cancellations '(first)))
                           (should (= zr-erc-upload-expiry-hours 6))
                           (should (equal zr-erc-upload-http-options '(:timeout 10)))
                           (push 'second calls)
                           (setq second done)
                           (lambda () (push 'second cancellations))))
              (unused . ,(lambda (&rest _) (push 'unused calls))))))
      (let ((job (zr-erc-upload--start file nil t)))
        (setq zr-erc-upload-backend-order '(unused)
              zr-erc-upload-backends nil
              zr-erc-upload-expiry-hours 48
              zr-erc-upload-http-options '(:timeout 90))
        (with-temp-buffer (funcall first nil "Network failed"))
        (should (equal calls '(second first)))
        (should-not (zr-erc-upload--job-done job))
        (funcall first "https://example.test/stale" nil)
        (should (equal (erc-user-input) ""))
        (with-temp-buffer (funcall second "https://example.test/backup" nil))
        (should (equal (erc-user-input) "https://example.test/backup"))
        (should (equal cancellations '(second first)))
        (should (zr-erc-upload--job-done job))
        (should-not (file-exists-p file))
        (should-not zr-erc-upload--jobs)))))

(ert-deftest zr-erc-upload-synchronous-fallback-keeps-current-cancellation ()
  (dolist (finish '(success cancel))
    (zr-erc-upload-test--conversation
      (let* ((file (make-temp-file "erc-upload-owned-")) first second calls cancellations
             (zr-erc-upload-backend-order '(first first second unused))
             (zr-erc-upload-backends
              `((first . ,(lambda (_file done)
                            (push 'first calls)
                            (setq first done)
                            (funcall done "https:///broken" nil)
                            (lambda () (push 'first cancellations))))
                (second . ,(lambda (_file done)
                             (push 'second calls)
                             (setq second done)
                             (lambda ()
                               (push 'second cancellations)
                               (funcall done nil "Cancelled"))))
                (unused . ,(lambda (&rest _) (push 'unused calls))))))
        (let ((job (zr-erc-upload--start file nil t)))
          (should (equal calls '(second first)))
          (should (equal cancellations '(first)))
          (should (file-exists-p file))
          (funcall first "https://example.test/stale" nil)
          (if (eq finish 'success)
              (funcall second "https://example.test/backup" nil)
            (zr-erc-upload-cancel)
            (funcall second nil "Late failure"))
          (zr-erc-upload-cancel)
          (should (equal (erc-user-input)
                         (if (eq finish 'success) "https://example.test/backup" "")))
          (should (equal calls '(second first)))
          (should (equal cancellations '(second first)))
          (should (zr-erc-upload--job-done job))
          (should-not (file-exists-p file))
          (should-not zr-erc-upload--jobs))))))

(ert-deftest zr-erc-upload-all-failures-are-reported ()
  (zr-erc-upload-test--conversation
    (let* ((file (make-temp-file "erc-upload-owned-")) messages
           (zr-erc-upload-backend-order '(first second third))
           (zr-erc-upload-backends
            '((first . (lambda (_file done) (funcall done nil "Timeout") #'ignore))
              (second . (lambda (&rest _) (error "Startup failed")))
              (third . (lambda (_file done) (funcall done nil "Quota exceeded") #'ignore)))))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (should (zr-erc-upload--job-done (zr-erc-upload--start file nil t))))
      (should (equal (car messages)
                     "ERC upload failed: first: Timeout; second: Startup failed; third: Quota exceeded"))
      (should (equal (erc-user-input) ""))
      (should-not (file-exists-p file))
      (should-not zr-erc-upload--jobs))))

(ert-deftest zr-erc-upload-explicit-backend-and-invalid-configuration ()
  (zr-erc-upload-test--conversation
    (let* ((zr-erc-upload-backend-order '(unused)) calls
          (zr-erc-upload-backends
           `((chosen . ,(lambda (_file done)
                          (push 'chosen calls)
                          (funcall done "https://example.test/chosen" nil)
                          #'ignore))
             (unused . ,(lambda (&rest _) (push 'unused calls))))))
      (zr-erc-upload--start (make-temp-file "erc-upload-owned-") 'chosen t)
      (should (equal calls '(chosen)))
      (should (equal (erc-user-input) "https://example.test/chosen")))
    (dolist (order '(nil litterbox (missing) (litterbox . beacon)))
      (let ((zr-erc-upload-backend-order order)
            (file (make-temp-file "erc-upload-owned-")))
        (should-error (zr-erc-upload--start file nil t) :type 'user-error)
        (should-not (file-exists-p file))))
    (dolist (hours '(0 -1 "24"))
      (let ((zr-erc-upload-expiry-hours hours)
            (file (make-temp-file "erc-upload-owned-")))
        (should-error (zr-erc-upload--start file nil t) :type 'user-error)
        (should-not (file-exists-p file))))
    (should-not zr-erc-upload--jobs)))

(ert-deftest zr-erc-upload-yank-media-binary-and-cancellation ()
  (let ((bytes (unibyte-string 137 80 78 71 0 255 13 10))
        file callback sent (cancellations 0))
    (zr-erc-upload-test--conversation
      (zr-erc-upload--install)
      (let ((zr-erc-upload-backend-order '(custom))
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
          (should (equal (erc-user-input) ""))
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
         uploaded sent)
    (unwind-protect
        (progn
          (write-region "source" nil file nil 'silent)
          (zr-erc-upload-test--conversation
            (zr-erc-upload--install)
            (insert "draft ")
            (let ((zr-erc-upload-backend-order '(custom))
                  (zr-erc-upload-backends
                   `((custom . ,(lambda (path done)
                                  (push path uploaded)
                                  (funcall done "https://example.test/a" nil)
                                  #'ignore)))))
              (cl-letf (((symbol-function 'erc-send-input)
                         (lambda (&rest _) (setq sent t))))
                (dolist (type zr-erc-upload--file-types)
                  (let ((data (concat (if (eq type 'text/uri-list) "# comment\r\n" "cut\n")
                                      uri "\n" uri "\0")))
                    (cl-letf (((symbol-function 'gui-get-selection)
                               (lambda (_selection requested)
                                 (if (eq requested 'TARGETS) (vector type) data))))
                      (yank-media))))
                (should (= (length uploaded) 4))
                (should-not sent)
                (should (equal (erc-user-input)
                               (concat "draft "
                                       (string-join (make-list 4 "https://example.test/a") " "))))
                (should (cl-every (lambda (path) (equal path file)) uploaded))
                (should (equal (zr-erc-upload-test--read file) "source"))
                (setq uploaded nil)
                (dolist (data (list (concat uri "\nhttps://example.test/a")
                                   "file://otherhost/tmp/a" "copy\n"))
                  (should-error (zr-erc-upload--yank 'text/uri-list data) :type 'user-error))
                (should-not uploaded)))))
      (delete-directory directory t))))

(ert-deftest zr-erc-upload-changed-conversation-does-not-deliver ()
  (dolist (case '((nil target) (nil connection) (nil disconnected)
                  (t target) (t connection) (t disconnected)))
    (zr-erc-upload-test--conversation
      (let* ((zr-erc-upload-auto-send (car case))
             (change (cadr case))
             (file (make-temp-file "erc-upload-owned-")) callback sent
             (zr-erc-upload-backend-order '(custom))
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
        (should (equal (erc-user-input) ""))
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
         (bytes zr-erc-upload-test--image-bytes) sent)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil file nil 'silent))
          (zr-erc-upload-test--server
           (lambda (base requests)
             (pcase-dolist
                 (`(,backend ,path ,url ,field ,expiry-field ,expiry)
                  '((litterbox "/upload" "https://example.test/cutie.png" "fileToUpload" "time" "12h")
                    (beacon "/beacon" "https://example.test/cutie.png" "file" nil nil)
                    (tempfile "/tempfile" "https://tempfile.org/file42/preview" "files" "expiryHours" "24")
                    (tmp0 "/tmp0" "https://tmp0.cc/api/file/file42/preview" "file" "expires" "12h")))
               (zr-erc-upload-test--conversation
                 (let ((zr-erc-upload-backend-order (list backend))
                       (zr-erc-upload-http-options '(:headers (("X-Test" . "erc-upload")) :proxy nil))
                       (zr-erc-upload-expiry-hours 8))
                   (zr-erc-upload-test--endpoint (concat base path)
                     (cl-letf (((symbol-function 'erc-send-input)
                                (lambda (text &rest _) (push text sent) t)))
                       (let ((job (zr-erc-upload-file file)))
                         (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job))))
                       (should-not sent)
                       (should (equal (erc-user-input) url))
                       (should-not zr-erc-upload--jobs)
                       (should-not (zr-erc-upload-test--buffers))
                       (let ((request (car (funcall requests))))
                         (should (string-match-p "X-Test: erc-upload" request))
                         (when (eq backend 'litterbox)
                           (should (string-match-p "name=\"reqtype\"\r\n\r\nfileupload\r\n" request)))
                         (when expiry-field
                           (should (string-search
                                    (format "name=\"%s\"\r\n\r\n%s\r\n" expiry-field expiry)
                                    request)))
                         (should (string-match-p (format "name=\"%s\"; filename\\*=" field) request))
                         (should (string-search bytes request)))
                       (should (equal (zr-erc-upload-test--read file) bytes))))))))))
      (delete-directory directory t))))

(ert-deftest zr-erc-upload-real-curl-failures-and-cancel ()
  (skip-unless (executable-find "curl"))
  (zr-erc-upload-test--server
   (lambda (base requests)
     (dolist (path '("/error" "/bad" "/hang" "/cancel"))
       (zr-erc-upload-test--conversation
         (let ((zr-erc-upload-backend-order '(litterbox))
               (zr-erc-upload-http-options '(:timeout 1 :proxy nil)) sent
               (file (make-temp-file "erc-upload-owned-")))
           (zr-erc-upload-test--endpoint
               (concat base (if (equal path "/cancel") "/hang" path))
             (cl-letf (((symbol-function 'erc-send-input) (lambda (&rest _) (setq sent t))))
               (let ((job (zr-erc-upload--start file nil t)))
                 (when (equal path "/cancel")
                   (zr-erc-upload-test--wait
                    (lambda () (>= (length (funcall requests)) 4)))
                   (zr-erc-upload-cancel))
                 (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job))))
               (should-not sent)
               (should (equal (erc-user-input) ""))
               (should-not (file-exists-p file))
               (should-not zr-erc-upload--jobs)
               (should-not (zr-erc-upload-test--buffers))))))))))

(ert-deftest zr-erc-upload-real-curl-fallback ()
  (skip-unless (executable-find "curl"))
  (zr-erc-upload-test--server
   (lambda (base requests)
     (dolist (path '("/error" "/bad" "/hang" "/json-error" "/json-bad" "/json-no-url"))
       (zr-erc-upload-test--conversation
         (let* ((file (make-temp-file "erc-upload-owned-"))
                (zr-erc-upload-backend-order '(primary backup))
                (zr-erc-upload-backends
                 `((primary . ,(if (string-prefix-p "/json-" path)
                                   #'zr-erc-upload-tempfile #'zr-erc-upload-litterbox))
                   (backup . zr-erc-upload-beacon)))
                (zr-erc-upload-http-options '(:timeout 1 :proxy nil))
                (before (length (funcall requests))))
           (let ((coding-system-for-write 'no-conversion))
             (write-region zr-erc-upload-test--image-bytes nil file nil 'silent))
           (zr-erc-upload-test--endpoint
               (lambda (url) (concat base (if (string-search "beacon.host" url) "/beacon" path)))
             (let ((job (zr-erc-upload--start file nil t)))
               (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job)))
               (should (= (length (zr-erc-upload--job-errors job)) 1))))
           (should (= (length (funcall requests)) (+ before 2)))
           (should (equal (erc-user-input) "https://example.test/cutie.png"))
           (dolist (request (seq-take (funcall requests) 2))
             (should (string-search zr-erc-upload-test--image-bytes request)))
           (should-not (file-exists-p file))
           (should-not zr-erc-upload--jobs)
           (should-not (zr-erc-upload-test--buffers))))))))

(ert-deftest zr-erc-upload-real-curl-default-fallback ()
  (skip-unless (executable-find "curl"))
  (zr-erc-upload-test--server
   (lambda (base requests)
     (zr-erc-upload-test--conversation
       (let ((file (make-temp-file "erc-upload-owned-"))
             (zr-erc-upload-http-options '(:proxy nil)))
         (let ((coding-system-for-write 'no-conversion))
           (write-region zr-erc-upload-test--image-bytes nil file nil 'silent))
         (zr-erc-upload-test--endpoint
             (lambda (url)
               (concat base
                       (pcase (url-host (url-generic-parse-url url))
                         ("litterbox.catbox.moe" "/error")
                         ("tempfile.org" "/json-error")
                         ("tmp0.cc" "/json-bad")
                         ("beacon.host" "/beacon")
                         (_ (error "Unexpected upload endpoint: %s" url)))))
           (let ((job (zr-erc-upload--start file nil t)))
             (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job)))
             (should (= (length (zr-erc-upload--job-errors job)) 3))))
         (should (equal
                  (mapcar (lambda (request) (cadr (split-string request " ")))
                          (reverse (funcall requests)))
                  '("/error" "/json-error" "/json-bad" "/beacon")))
         (should (equal (erc-user-input) "https://example.test/cutie.png"))
         (should-not (file-exists-p file))
         (should-not zr-erc-upload--jobs)
         (should-not (zr-erc-upload-test--buffers)))))))

(ert-deftest zr-erc-upload-real-curl-expiry-fallback ()
  (skip-unless (executable-find "curl"))
  (zr-erc-upload-test--server
   (lambda (base requests)
     (zr-erc-upload-test--conversation
       (let ((file (make-temp-file "erc-upload-owned-"))
             (zr-erc-upload-backend-order '(beacon tempfile tmp0))
             (zr-erc-upload-expiry-hours 72)
             (zr-erc-upload-http-options '(:proxy nil)))
         (let ((coding-system-for-write 'no-conversion))
           (write-region zr-erc-upload-test--image-bytes nil file nil 'silent))
         (zr-erc-upload-test--endpoint (concat base "/tmp0")
           (let ((job (zr-erc-upload--start file nil t)))
             (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job)))
             (should (= (length (zr-erc-upload--job-errors job)) 2))))
         (should (= (length (funcall requests)) 1))
         (should (string-search "name=\"expires\"\r\n\r\n3d\r\n" (car (funcall requests))))
         (should (equal (erc-user-input) "https://tmp0.cc/api/file/file42/preview"))
         (should-not (file-exists-p file))
         (should-not (zr-erc-upload-test--buffers)))))))

(ert-deftest zr-erc-upload-real-curl-non-image-fallback ()
  (skip-unless (executable-find "curl"))
  (zr-erc-upload-test--server
   (lambda (base requests)
     (zr-erc-upload-test--conversation
       (let ((file (make-temp-file "erc-upload-owned-" nil ".png"))
             (zr-erc-upload-backend-order '(tempfile tmp0 beacon))
             (zr-erc-upload-http-options '(:proxy nil)))
         (write-region "Not an image despite the extension" nil file nil 'silent)
         (zr-erc-upload-test--endpoint (concat base "/beacon")
           (let ((job (zr-erc-upload--start file nil t)))
             (zr-erc-upload-test--wait (lambda () (zr-erc-upload--job-done job)))
             (should (= (length (zr-erc-upload--job-errors job)) 2))))
         (should (= (length (funcall requests)) 1))
         (should (equal (erc-user-input) "https://example.test/cutie.png"))
         (should-not (file-exists-p file))
         (should-not zr-erc-upload--jobs)
         (should-not (zr-erc-upload-test--buffers)))))))

(provide 'zr-erc-upload-test)
;;; zr-erc-upload-test.el ends here
