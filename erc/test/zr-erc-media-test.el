;;; zr-erc-media-test.el --- Media retrieval tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-media)

(defconst zr-erc-media-test--server-file
  (expand-file-name "media-server.py"
                    (file-name-directory (or load-file-name
                                             (bound-and-true-p byte-compile-current-file)
                                             buffer-file-name))))

(defun zr-erc-media-test--wait (predicate)
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun zr-erc-media-test--server (function)
  "Run FUNCTION with the URL and directory of an isolated HTTP fixture."
  (unless (executable-find "python3") (ert-skip "python3 is unavailable"))
  (let* ((buffer (generate-new-buffer " *erc-media-http-test*"))
         (process (make-process :name "erc-media-http-test" :buffer buffer :noquery t
                                 :command (list "python3" zr-erc-media-test--server-file)))
         (directory (make-temp-file "erc-media-test-" t))
         (url-proxy-services '(("no_proxy" . "127.0.0.1"))))
    (unwind-protect
        (progn
          (zr-erc-media-test--wait
           (lambda () (with-current-buffer buffer (string-match-p "^[0-9]+\n" (buffer-string)))))
          (funcall function
                   (with-current-buffer buffer (format "http://127.0.0.1:%d" (string-to-number (buffer-string))))
                   directory))
      (delete-process process)
      (kill-buffer buffer)
      (delete-directory directory t))))

(defun zr-erc-media-test--read (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(ert-deftest zr-erc-media-regex-rewrite-and-tag-button ()
  (let ((zr-erc-media-rules
         '((:regexp "https://cdn.test/\\(.+\\)" :replace "https://proxy.test/\\1"
            :type image :match (:tags (("+bridge" . "^onebot$")))))))
    (should-not (zr-erc-media--item "https://cdn.test/a" nil))
    (should (equal (plist-get (zr-erc-media--item "https://cdn.test/a"
                                                '(:tags (("+bridge" . "onebot")))) :url)
                   "https://proxy.test/a")))
  (with-temp-buffer
    (let ((zr-erc-media-rules '((:regexp "." :url-tag "+image" :type image)))
          (erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "hello"
                              :unparsed "@+image=https://example.test/photo :bot PRIVMSG #c :hello")))
      (insert "<bot> hello\n")
      (zr-erc-media--insert)
      (goto-char (point-min))
      (search-forward "[image]")
      (should (button-at (1- (point))))
      (should-not zr-erc-media--jobs))))

(ert-deftest zr-erc-media-auto-show-is-opt-in-and-overridable ()
  (with-temp-buffer
    (let ((erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "url"
                              :unparsed ":bot PRIVMSG #c :url")) fetched)
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'zr-erc-media--fetch)
                 (lambda (&rest _) (setq fetched t))))
        (insert "<bot> https://example.test/a.png\n")
        (zr-erc-media--insert)
        (should-not fetched)
        (erase-buffer)
        (insert "<bot> https://example.test/a.png\n")
        (let ((zr-erc-media-rules '((:regexp "png$" :type image :auto-show t))))
          (zr-erc-media--insert))
        (should fetched)))))

(ert-deftest zr-erc-media-http-auth-source-download-and-failures ()
  (zr-erc-media-test--server
   (lambda (base directory)
     (with-temp-buffer
       (let* ((auth-file (expand-file-name "authinfo" directory))
              (auth-sources (list auth-file)) (auth-source-do-cache nil)
              (destination (expand-file-name "download" directory))
              (port (url-port (url-generic-parse-url base)))
              (rule '(:type file :auth-source (:user "bridge") :auth-scheme bearer
                      :headers (("X-Bridge" . "onebot")))))
         (write-region (format "machine 127.0.0.1 port %d login bridge password media-secret\n" port)
                       nil auth-file nil 'silent)
         (set-file-modes auth-file #o600)
         (let ((job (zr-erc-media--fetch (list :url (concat base "/file") :rule rule)
                                         (point) destination)))
           (zr-erc-media-test--wait (lambda () (zr-erc-media--job-done job)))
           (should-not (zr-erc-media--job-error job))
           (should (equal (zr-erc-media-test--read destination) (unibyte-string 98 105 110 97 114 121 0 102 105 108 101 255 10)))
           (should-not (file-exists-p (zr-erc-media--job-raw job))))
         ;; Failures never overwrite an existing destination.
         (dolist (path '("/redirect" "/error"))
           (let ((job (zr-erc-media--fetch (list :url (concat base path) :rule rule)
                                           (point) destination t)))
             (zr-erc-media-test--wait (lambda () (zr-erc-media--job-done job)))
             (should (zr-erc-media--job-error job))
             (should (= 13 (length (zr-erc-media-test--read destination))))))
         (let ((job (zr-erc-media--fetch (list :url (concat base "/leak-count"))
                                         (point) destination t)))
           (zr-erc-media-test--wait (lambda () (zr-erc-media--job-done job)))
           (should (equal (zr-erc-media-test--read destination) "0")))
         (let* ((zr-erc-media-timeout 0.05)
                (job (zr-erc-media--fetch (list :url (concat base "/slow")) (point) destination t)))
           (zr-erc-media-test--wait (lambda () (zr-erc-media--job-done job)))
           (should (zr-erc-media--job-error job))
           (should-not (buffer-live-p (zr-erc-media--job-request job)))))))))

(ert-deftest zr-erc-media-real-ffmpeg-preview-and-cleanup ()
  (skip-unless (and (executable-find "ffmpeg") (executable-find "ffprobe")))
  (zr-erc-media-test--server
   (lambda (base _directory)
     (with-temp-buffer
       (insert "image link\n")
       (let ((zr-erc-media-use-ffmpeg t)
             (zr-erc-media-max-width 160) (zr-erc-media-max-height 100)
             job)
         ;; This terminal build has no image support.  The actual HTTP and
         ;; FFmpeg pipeline still runs; inspect the output and display property.
         (cl-letf (((symbol-function 'create-image)
                    (lambda (file &rest _) (list 'image :type 'png :file file))))
           (setq job (zr-erc-media--fetch (list :url (concat base "/image.png") :type 'image) 1))
           (zr-erc-media-test--wait (lambda () (zr-erc-media--job-done job))))
         (should-not (zr-erc-media--job-error job))
         (let ((file (zr-erc-media--job-preview job)))
           (with-temp-buffer
             (should (= 0 (call-process "ffprobe" nil t nil "-v" "error" "-select_streams" "v:0"
                                        "-show_entries" "stream=width,height" "-of" "csv=s=x:p=0" file)))
             (should (equal (string-trim (buffer-string)) "160x90")))
           (should (get-text-property 1 'display
                                      (overlay-get (zr-erc-media--job-overlay job) 'after-string)))
           (zr-erc-media--cleanup-buffer)
           (should-not (file-exists-p file))
           (should-not (file-exists-p (zr-erc-media--job-raw job)))))))))

(provide 'zr-erc-media-test)
;;; zr-erc-media-test.el ends here
