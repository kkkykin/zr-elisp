;;; zr-erc-link-test.el --- Media retrieval tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-link)
(require 'gnutls)
(require 'image-mode)

(ert-deftest zr-erc-link-forward-command-and-org-dispatch ()
  (with-temp-buffer
    (let ((zr-erc-link-rules
           '((:regexp "\\[查看合并转发：ircs?://[^/[:space:]]+/\\(#[^?[:space:]]+\\)\\?\\([^][:space:]]+\\)\\]"
              :replace "/join \\1 \\2" :type command)
             (:regexp "文档(\\([^)]*\\))" :replace "\\1" :type org)))
          (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h"))
          (original org-link-parameters)
          (origin (current-buffer))
          commands links)
      (insert "<xxxx-3334835171/onebot> [合并转发] [查看合并转发："
              "ircs://icu.xxxx.eu.org:6697/#mb-forward-rhqd5kvzjv3oa47e5yugny4d6l"
              "?Q2PY7FCAY7O3P2BZK3O4THGP4A] 文档(https://example.test/help)")
      (cl-letf (((symbol-function 'erc-send-input)
                 (lambda (command) (push (list (current-buffer) command) commands)))
                ((symbol-function 'org-link-open-from-string)
                 (lambda (link arg) (push (list link arg) links))))
        (zr-erc-link--insert)
        (should-not commands)
        (should-not links)
        (let ((current-prefix-arg '(4))
              (first (next-button (point-min) t)))
          (should first)
          (goto-char (1+ (button-start first)))
          (zr-erc-link-open)
          (goto-char (point-max))
          (zr-erc-link-open)))
      (should (equal commands
                     `((,origin "/join #mb-forward-rhqd5kvzjv3oa47e5yugny4d6l Q2PY7FCAY7O3P2BZK3O4THGP4A"))))
      (should (equal links '(("https://example.test/help" (4)))))
      (should (eq original org-link-parameters))
      (should-not (local-variable-p 'org-link-parameters)))))

(ert-deftest zr-erc-link-org-uses-ol-custom-handler ()
  (with-temp-buffer
    (let ((org-link-parameters (copy-tree org-link-parameters))
          (zr-erc-link-rules '((:regexp "project:[[:alnum:]]+" :type org)))
          (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h"))
          calls)
      (org-link-set-parameters "project" :follow
                               (lambda (path arg) (push (list path arg) calls)))
      (insert "project:ABC")
      (zr-erc-link--insert)
      (let ((current-prefix-arg '(4)))
        (button-activate (next-button (point-min) t)))
      (should (equal calls '(("ABC" (4))))))))

(ert-deftest zr-erc-link-rule-order-overlap-and-empty-matches ()
  (with-temp-buffer
    (let ((zr-erc-link-rules
           '((:regexp "" :type org)
             (:regexp "ticket:\\([[:digit:]]+\\)" :replace "project:\\1" :type org)
             (:regexp "before ticket:[[:digit:]]+ after" :replace "/join #wrong" :type command)
             (:regexp "https?://[^[:space:]]+" :type org)))
          (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h")))
      (insert "before ticket:123 after ticket:456 https://[::1]/a(b)]")
      (zr-erc-link--insert)
      (let ((button (next-button (point-min) t)) targets)
        (while button
          (push (plist-get (button-get button 'zr-erc-link-item) :target) targets)
          (setq button (next-button (button-end button) t)))
        (should (equal (nreverse targets)
                       '("project:123" "project:456" "https://[::1]/a(b)]")))))))

(ert-deftest zr-erc-link-nil-rules-and-selectors ()
  (dolist (rules '(nil ((:regexp "https?://[^[:space:]]+" :type org
                        :selector (:sender "^other!")))))
    (with-temp-buffer
      (let ((zr-erc-link-rules rules)
            (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h")))
        (insert "https://example.test/a.png")
        (zr-erc-link--insert)
        (should-not (next-button (point-min) t))))))

(ert-deftest zr-erc-link-type-defaults-and-specific-overrides ()
  (with-temp-buffer
    (let* ((zr-erc-link-rules
            '((:type file :headers (("X-Client" . "erc"))
               :auth-source (:user "bridge") :auth-scheme bearer
               :max-age 60 :max-bytes 1024 :dir "~/downloads/")
              (:type file :selector (:sender "^other$") :max-bytes 999)
              (:type file :selector (:sender "^bot$") :max-bytes 320 :timeout 5)
              (:regexp "https?://[^[:space:]]+png" :type file
               :max-age nil :headers (("X-Image" . "specific")))
              (:regexp "https?://[^[:space:]]+zip" :type file :proxy nil)
              (:regexp "https?://[^[:space:]]+" :type org)
              (:type file :max-bytes 888)))
           (original (copy-tree zr-erc-link-rules))
           (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h")))
      (insert "https://example.test/a.png https://example.test/b.zip https://example.test/c")
      (zr-erc-link--insert)
      (let* ((image (next-button (point-min) t))
             (file (next-button (button-end image) t))
             (org (next-button (button-end file) t))
             (image-rule (plist-get (button-get image 'zr-erc-link-item) :rule))
             (file-rule (plist-get (button-get file 'zr-erc-link-item) :rule))
             (org-rule (plist-get (button-get org 'zr-erc-link-item) :rule)))
        (should (equal (plist-get image-rule :headers) '(("X-Image" . "specific"))))
        (should (equal (plist-get image-rule :auth-source) '(:user "bridge")))
        (should (eq (plist-get image-rule :auth-scheme) 'bearer))
        (should (= (plist-get image-rule :max-bytes) 320))
        (should (= (plist-get image-rule :timeout) 5))
        (should (plist-member image-rule :max-age))
        (should-not (plist-get image-rule :max-age))
        (should (equal (plist-get file-rule :headers) '(("X-Client" . "erc"))))
        (should (equal (plist-get file-rule :dir) "~/downloads/"))
        (should (= (plist-get file-rule :max-age) 60))
        (should (= (plist-get file-rule :max-bytes) 320))
        (should-not (plist-get file-rule :proxy))
        (should-not (plist-member org-rule :auth-source))
        (should-not (next-button (button-end org) t)))
      (should (equal zr-erc-link-rules original)))))

(ert-deftest zr-erc-link-defaults-do-not-recognize-links ()
  (with-temp-buffer
    (let ((zr-erc-link-rules '((:type file :max-age 60) (:type org :selector (:sender "^bot$"))))
          (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h")))
      (insert "https://example.test/a.png")
      (zr-erc-link--insert)
      (should-not (next-button (point-min) t))
      (should-not (zr-erc-link--item (buffer-string) nil)))))

(ert-deftest zr-erc-link-tag-inherits-type-defaults-without-regexp ()
  (with-temp-buffer
    (let ((zr-erc-link-rules
           '((:type file :headers (("X-Client" . "erc")) :max-age 60)
             (:url-tag "+image" :type file :max-age nil)))
          (erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "hello"
                              :unparsed "@+image=https://example.test/photo :bot PRIVMSG #c :hello")))
      (insert "hello\n")
      (zr-erc-link--insert)
      (let* ((button (next-button (point-min) t))
             (item (button-get button 'zr-erc-link-item)))
        (should (equal (button-label button) "[file]"))
        (should (equal (plist-get item :target) "https://example.test/photo"))
        (should (equal (plist-get (plist-get item :rule) :headers) '(("X-Client" . "erc"))))
        (should-not (plist-get (plist-get item :rule) :max-age))
        (should-not (next-button (button-end button) t))))))

(ert-deftest zr-erc-link-download-prompts-in-inherited-directory ()
  (with-temp-buffer
    (let ((zr-erc-link-rules '((:type file :dir "~/downloads/")
                              (:regexp "https?://[^[:space:]]+" :type file)))
          (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h"))
          (destination (make-temp-name (expand-file-name "erc-link-download-" temporary-file-directory)))
          prompted fetched)
      (insert "https://example.test/archive.zip?token=value")
      (zr-erc-link--insert)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (_prompt directory _default _mustmatch initial &rest _)
                   (setq prompted (list directory initial)) destination))
                ((symbol-function 'make-directory) (lambda (&rest _) nil))
                ((symbol-function 'zr-erc-link--fetch)
                 (lambda (_item destination overwrite)
                   (setq fetched (list destination overwrite)))))
        (call-interactively #'zr-erc-link-download))
      (should (equal prompted '("~/downloads/" "archive.zip")))
      (should (equal fetched (list destination nil))))))

(ert-deftest zr-erc-link-command-rejects-noncommands-and-multiple-lines ()
  (dolist (target '("hello" "//hello" "/join #one\n/part #two" "/join #one\r/part #two"))
    (with-temp-buffer
      (insert "action")
      (zr-erc-link--buttonize (point-min) (point-max) (list :type 'command :target target))
      (let (sent)
        (cl-letf (((symbol-function 'erc-send-input) (lambda (&rest _) (setq sent t))))
          (should-error (button-activate (button-at (point-min))) :type 'user-error)
          (should-not sent))))))

(ert-deftest zr-erc-link-default-media-and-org-actions ()
  (with-temp-buffer
    (let ((erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h"))
          types)
      (insert "https://example.test/a.png https://example.test/a.zip https://example.test/page file:/tmp/a")
      (zr-erc-link--insert)
      (let ((button (next-button (point-min) t)))
        (while button
          (push (plist-get (button-get button 'zr-erc-link-item) :type) types)
          (setq button (next-button (button-end button) t))))
      (should (equal (nreverse types) '(file file org org))))))

(defconst zr-erc-link-test--server-file
  (expand-file-name "media-server.py"
                    (file-name-directory (or load-file-name
                                             (bound-and-true-p byte-compile-current-file)
                                             buffer-file-name))))

(defun zr-erc-link-test--wait (predicate)
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun zr-erc-link-test--server (function &optional tls)
  "Run FUNCTION with an isolated HTTP fixture's URL and directory.
TLS, when non-nil, is a list of certificate and key file names."
  (unless (executable-find "python3") (ert-skip "python3 is unavailable"))
  (let* ((buffer (generate-new-buffer " *erc-media-http-test*"))
         (process (make-process :name "erc-media-http-test" :buffer buffer :noquery t
                                 :command (append (list "python3" zr-erc-link-test--server-file) tls)))
         (directory (make-temp-file "erc-media-test-" t))
         (url-proxy-services '(("no_proxy" . "127.0.0.1"))))
    (unwind-protect
        (progn
          (zr-erc-link-test--wait
           (lambda () (with-current-buffer buffer (string-match-p "^[0-9]+\n" (buffer-string)))))
          (funcall function
                   (with-current-buffer buffer
                     (format "%s://127.0.0.1:%d" (if tls "https" "http")
                             (string-to-number (buffer-string))))
                   directory))
      (delete-process process)
      (kill-buffer buffer)
      (delete-directory directory t))))

(defun zr-erc-link-test--proxy (function)
  "Run FUNCTION with a loopback proxy URL and its request log buffer."
  (unless (executable-find "python3") (ert-skip "python3 is unavailable"))
  (let* ((buffer (generate-new-buffer " *erc-media-proxy-test*"))
         (process (make-process
                   :name "erc-media-proxy-test" :buffer buffer :noquery t
                   :command (list "python3" (expand-file-name
                                            "media-proxy.py"
                                            (file-name-directory zr-erc-link-test--server-file))))))
    (unwind-protect
        (progn
          (zr-erc-link-test--wait
           (lambda () (with-current-buffer buffer (string-match-p "^[0-9]+\n" (buffer-string)))))
          (funcall function
                   (with-current-buffer buffer
                     (format "http://127.0.0.1:%d" (string-to-number (buffer-string))))
                   buffer))
      (delete-process process)
      (kill-buffer buffer))))

(defun zr-erc-link-test--read (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(ert-deftest zr-erc-link-regex-rewrite-and-tag-button ()
  (let ((zr-erc-link-rules
         '((:regexp "https://cdn.test/\\(.+\\)" :replace "https://proxy.test/\\1"
            :type file :selector (:tags (("+bridge" . "^onebot$")))))))
    (should-not (zr-erc-link--item "https://cdn.test/a" nil))
    (should (equal (plist-get (zr-erc-link--item "https://cdn.test/a"
                                                '(:tags (("+bridge" . "onebot")))) :target)
                   "https://proxy.test/a")))
  (with-temp-buffer
    (let ((zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :url-tag "+image" :type file)))
          (erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "hello"
                              :unparsed "@+image=https://example.test/photo :bot PRIVMSG #c :hello")))
      (insert "<bot> hello\n")
      (zr-erc-link--insert)
      (goto-char (point-min))
      (search-forward "[file]")
      (should (button-at (1- (point))))
      (should-not zr-erc-link--jobs))))

(ert-deftest zr-erc-link-tag-targets-deduplicate-after-text-rules ()
  (with-temp-buffer
    (let ((zr-erc-link-rules
           '((:url-tag "+link" :regexp "https://cdn\\.test/\\(.+\\)"
              :replace "https://proxy.test/\\1" :type org)
             (:regexp "https://proxy\\.test/[^[:space:]]+" :type org)))
          (erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "url"
                              :unparsed "@+link=https://cdn.test/a :bot PRIVMSG #c :url")))
      (insert "https://proxy.test/a\n")
      (zr-erc-link--insert)
      (let ((button (next-button (point-min) t)))
        (should button)
        (should (equal (button-label button) "https://proxy.test/a"))
        (should-not (next-button (button-end button) t)))
      (should (equal (buffer-string) "https://proxy.test/a\n")))))

(ert-deftest zr-erc-link-recognition-never-fetches ()
  (dolist (tag-url '(nil t))
    (with-temp-buffer
      (let ((zr-erc-link-rules
             (if tag-url '((:url-tag "+image" :type file))
               zr-erc-link-rules))
            (erc-message-parsed
             (make-erc-response
              :command "PRIVMSG" :sender "bot!u@h"
              :unparsed "@+image=https://example.test/photo :bot PRIVMSG #c :image")))
        (cl-letf (((symbol-function 'zr-erc-link--fetch)
                   (lambda (&rest _) (ert-fail "Recognition must not fetch links"))))
          (insert "<bot> https://example.test/a.png https://example.test/b.zip\n")
          (zr-erc-link--insert)
          (should (next-button (point-min) t))
          (should-not zr-erc-link--jobs)
          (should-not (overlays-in (point-min) (point-max))))))))

(defun zr-erc-link-test--button (label &optional type rule)
  "Insert a rule button named LABEL, with TYPE and RULE, then a newline."
  (let ((start (point)))
    (insert label)
    (zr-erc-link--buttonize
     start (point) (list :target (concat "https://example.test/" label)
                        :type (or type 'file) :rule rule :time (current-time)))
    (prog1 (button-at start) (insert "\n"))))

(ert-deftest zr-erc-link-open-at-point-and-nearest-previous-link ()
  (dolist (name '("image.png" "archive.zip"))
    (with-temp-buffer
      (insert "before any link\n")
      (zr-erc-link-test--button "first.png")
      (let* ((button (zr-erc-link-test--button name))
             (plain (insert-text-button "ordinary button"))
             (after (point))
             fetched)
        (insert "\n")
        (zr-erc-link-test--button "future.png")
        (setq buffer-read-only t)
        (cl-letf (((symbol-function 'zr-erc-link--fetch)
                   (lambda (item &optional destination _overwrite)
                     (push (list (plist-get item :target) destination) fetched))))
          (dolist (position (list (1+ (button-start button))
                                  (button-end button)
                                  (1+ (button-start plain)) after))
            (goto-char position)
            (call-interactively #'zr-erc-link-open)
            (should (equal (pop fetched) (list (concat "https://example.test/" name) nil)))
            (should (= (point) position)))
          (goto-char (point-min))
          (should-error (zr-erc-link-open) :type 'user-error)
          (should-not fetched))))))

(ert-deftest zr-erc-link-bulk-open-region-and-visible-window ()
  (dolist (visible '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (zr-erc-link-test--button "outside.png")
        (let* ((first (zr-erc-link-test--button "first.png"))
               (_org (zr-erc-link-test--button "page" 'org))
               (_command (zr-erc-link-test--button "action" 'command))
               (_plain (insert-text-button "ordinary button"))
               (last (zr-erc-link-test--button "archive.zip"))
               (after (zr-erc-link-test--button "after.png"))
               (beg (1+ (button-start first)))
               (end (button-start after))
               (transient-mark-mode t)
               (current-prefix-arg (and visible '(4)))
               requests opened)
          (goto-char beg)
          (set-mark (if visible (point-min) end))
          (setq mark-active t buffer-read-only t)
          (set-window-start (selected-window) beg)
          (cl-letf (((symbol-function 'window-end) (lambda (&rest _) end))
                    ((symbol-function 'zr-erc-link--fetch)
                     (lambda (item _destination _overwrite callback)
                       (push (cons item callback) requests)))
                    ((symbol-function 'zr-erc-link--open-file)
                     (lambda (file item) (push (list file (plist-get item :target)) opened))))
            (call-interactively #'zr-erc-link-open)
            (should (= (length requests) 2))
            (should (= (point) beg))
            (should (= (mark) (if visible (point-min) end)))
            ;; Complete the second file first; display waits for every request.
            (funcall (cdr (car requests)) "/tmp/archive.zip"
                     (button-get last 'zr-erc-link-item))
            (should-not opened)
            (funcall (cdr (cadr requests)) "/tmp/first.png"
                     (button-get first 'zr-erc-link-item))
            (should (equal opened '(("/tmp/first.png" "https://example.test/first.png"))))))))))

(ert-deftest zr-erc-link-button-activation-opens-files ()
  (dolist (name '("image.png" "archive.zip"))
    (with-temp-buffer
      (let* ((transient-mark-mode t)
             (current-prefix-arg '(4))
             (button (zr-erc-link-test--button name))
             fetched)
        (zr-erc-link-test--button "other.png")
        (goto-char (point-min))
        (set-mark (point-max))
        (setq mark-active t buffer-read-only t)
        (cl-letf (((symbol-function 'zr-erc-link--fetch)
                   (lambda (item &optional destination _overwrite)
                     (push (list (plist-get item :target) destination) fetched)))
                  ((symbol-function 'read-file-name)
                   (lambda (&rest _) (ert-fail "Opening must not prompt for a download"))))
          (button-activate button)
          (should (equal fetched (list (list (concat "https://example.test/" name) nil)))))))))

(ert-deftest zr-erc-link-pending-requests-clean-up-and-ignore-late-responses ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _) (generate-new-buffer " *erc-media-request*"))))
      (zr-erc-link-test--button "image.png")
      (goto-char (point-min))
      (zr-erc-link-open)
      (let* ((job (car zr-erc-link--jobs))
             (raw (zr-erc-link--job-raw job)))
        (zr-erc-link--fail job "Test failure")
        (should-not (file-exists-p raw))
        (zr-erc-link-open)
        (let ((next (car zr-erc-link--jobs)))
          (should-not (eq next job))
          (zr-erc-link--cleanup-buffer)
          (should (zr-erc-link--job-done next))
          (should-not (buffer-live-p (zr-erc-link--job-request next)))
          (should-not (file-exists-p (zr-erc-link--job-raw next)))
          (should-not (memq (zr-erc-link--job-timer next) timer-list))
          (should-not zr-erc-link--jobs)
          (cl-letf (((symbol-function 'zr-erc-link--open-file)
                     (lambda (&rest _) (ert-fail "Canceled request opened a buffer"))))
            (with-temp-buffer (zr-erc-link--received nil next))))))))

(ert-deftest zr-erc-link-age-uses-server-time-or-receipt ()
  (let ((now (encode-time '(0 0 12 2 10 2026 nil nil 0)))
        (zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :type file))))
    (cl-letf (((symbol-function 'current-time) (lambda () now)))
      (let ((item (zr-erc-link--item
                   "https://example.test/a"
                   '(:tags (("time" . "2026-10-02T08:00:00.123Z"))))))
        (should (time-equal-p (plist-get item :time)
                             (encode-time (iso8601-parse "2026-10-02T08:00:00.123Z" t)))))
      (dolist (stamp '(nil "" "not-a-time"))
        (let ((item (zr-erc-link--item "https://example.test/a"
                                        (list :tags (list (cons "time" stamp))))))
          (should (time-equal-p (plist-get item :time) now)))))))

(ert-deftest zr-erc-link-age-boundary-and-inherited-overrides ()
  (let ((now 1000)
        (zr-erc-link-rules '((:type file :max-age 60)
                             (:regexp "https?://[^[:space:]]+" :type file))))
    (cl-letf (((symbol-function 'current-time) (lambda () now)))
      (let ((item (zr-erc-link--item "https://example.test/a" nil)))
        (setq now 1060)
        (with-temp-buffer
          (should-not (zr-erc-link--expired-p item))
          (setq now 1061)
          (should (zr-erc-link--expired-p item))
          (with-temp-buffer
            (setq-local zr-erc-link-rules
                        '((:regexp "https?://[^[:space:]]+" :type file)))
            (should-not (zr-erc-link--expired-p (zr-erc-link--item "https://example.test/a" nil))))
          (setf (plist-get (plist-get item :rule) :max-age) nil)
          (should-not (zr-erc-link--expired-p item))
          (setf (plist-get (plist-get item :rule) :max-age) 60)
          (should (zr-erc-link--expired-p item)))))))

(ert-deftest zr-erc-link-expired-history-keeps-buttons ()
  ;; Both visible URLs and URLs supplied only by tags use the message time.
  (dolist (tag-url '(nil t))
    (with-temp-buffer
      (let* ((zr-erc-link-rules
              `((:regexp "https?://[^[:space:]]+" :type file :max-age 60
                 ,@(and tag-url '(:url-tag "+image")))))
             (erc-message-parsed
              (make-erc-response
               :command "PRIVMSG" :sender "bot!u@h" :contents "image"
               :unparsed (concat "@time=2026-10-02T08:00:00.000Z"
                                 (and tag-url ";+image=https://example.test/a.png")
                                 " :bot!u@h PRIVMSG #c :image")))
             (now (encode-time '(0 2 8 2 10 2026 nil nil 0)))
             fetched)
        (cl-letf (((symbol-function 'current-time) (lambda () now))
                  ((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'zr-erc-link--fetch)
                   (lambda (&rest _) (setq fetched t))))
          (insert (if tag-url "<bot> image\n" "<bot> https://example.test/a.png\n"))
          (zr-erc-link--insert)
          (should-not fetched)
          (should-not zr-erc-link--jobs)
          (let ((pos (text-property-not-all (point-min) (point-max) 'zr-erc-link-item nil)))
            (should pos)
            (should (button-at pos))
            (should (zr-erc-link--expired-p (get-text-property pos 'zr-erc-link-item)))))))))

(ert-deftest zr-erc-link-expired-manual-requests-have-no-side-effects ()
  (with-temp-buffer
    (let ((now 1000)
          (zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :type file :max-age 60)))
          side-effects)
      (cl-letf (((symbol-function 'current-time) (lambda () now))
                ((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'url-retrieve) (lambda (&rest _) (push 'request side-effects)))
                ((symbol-function 'auth-source-search) (lambda (&rest _) (push 'auth side-effects)))
                ((symbol-function 'make-temp-file) (lambda (&rest _) (push 'temp side-effects)))
                ((symbol-function 'make-directory) (lambda (&rest _) (push 'directory side-effects)))
                ((symbol-function 'read-file-name) (lambda (&rest _) (push 'prompt side-effects)))
                ((symbol-function 'zr-erc-link--cleanup) (lambda (&rest _) (push 'cleanup side-effects))))
        (let ((item (zr-erc-link--item "https://example.test/a" nil)))
          (insert "image")
          (zr-erc-link--buttonize (point-min) (point-max) item)
          (goto-char (point-min))
          (setq now 1061)
          (should-error (zr-erc-link-open) :type 'user-error)
          (should-error (zr-erc-link-download "/unused/download") :type 'user-error)
          (should-error (call-interactively #'zr-erc-link-download) :type 'user-error)
          (setf (plist-get (plist-get item :rule) :auth-source) t)
          (dolist (destination '(nil "/unused/download"))
            (should-error (zr-erc-link--fetch item destination) :type 'user-error))
          (should-not side-effects)
          (should-not zr-erc-link--jobs))))))

(ert-deftest zr-erc-link-invalid-proxy-does-not-start-request ()
  (with-temp-buffer
    (dolist (proxy '(t "" "localhost" "host:0" "host:65536" "host:bad"
                    "https://host:80" "socks5://host:80" "http://user:secret@host:80"
                    "http://host:80/path" "host:80;DIRECT" "host:80\n"))
      (should-error (zr-erc-link--fetch
                     (list :target "http://127.0.0.1/image" :rule (list :proxy proxy)))
                    :type 'user-error)
      (should-not zr-erc-link--jobs)))
  (dolist (proxy '("[::1]:7890" "http://[::1]:7890/"))
    (let ((url-proxy-locator (zr-erc-link--proxy-locator proxy)))
      (should (equal (url-find-proxy-for-url (url-generic-parse-url "https://example.test")
                                            "example.test")
                     "http://[::1]:7890/")))))

(ert-deftest zr-erc-link-http-proxy-overrides-and-isolation ()
  (zr-erc-link-test--server
   (lambda (base directory)
     (zr-erc-link-test--proxy
      (lambda (proxy log)
        (let* ((url-proxy-locator #'url-default-find-proxy-for-url)
               (url-proxy-services '(("no_proxy" . ".")))
               (services (copy-tree url-proxy-services))
               (connections url-http-open-connections)
               (destination (expand-file-name "download" directory)))
          (with-temp-buffer
            (setq-local zr-erc-link-rules (list (list :type 'file :proxy proxy)))
            ;; Explicit proxy overrides no_proxy; nil forces a direct request.
            (dolist (direct '(nil t))
              (let* ((rule (append '(:type file) (and direct '(:proxy nil))))
                     (item (zr-erc-link--item (concat base "/data") nil rule))
                     (job (zr-erc-link--fetch item destination t)))
                (with-current-buffer (zr-erc-link--job-request job)
                  (should-not (eq url-http-open-connections connections))
                  (should (equal (url-find-proxy-for-url (url-generic-parse-url base) "127.0.0.1")
                                 (unless direct (concat proxy "/")))))
                (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
                (should-not (zr-erc-link--job-error job))))
            (with-current-buffer log
              (should (= 1 (how-many "^GET " (point-min) (point-max)))))
            ;; Another buffer keeps the default (inherited direct connection).
            (with-temp-buffer
              (setq-local zr-erc-link-rules nil)
              (let ((job (zr-erc-link--fetch (list :target (concat base "/data"))
                                              destination t)))
                (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
                (should-not (zr-erc-link--job-error job))))
            ;; A rule can restore an inherited proxy over a local direct setting.
            (setq-local zr-erc-link-rules '((:type file :proxy nil)))
            (let* ((url-proxy-locator (lambda (_url _host) (concat "PROXY " (substring proxy 7))))
                   (item (zr-erc-link--item (concat base "/data") nil '(:type file :proxy inherit)))
                   (job (zr-erc-link--fetch item destination t)))
              (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
              (should-not (zr-erc-link--job-error job))))
          (with-current-buffer log
            (should (= 2 (how-many (concat "^GET " (regexp-quote base) "/data$")
                                  (point-min) (point-max)))))
          (should (= 13 (length (zr-erc-link-test--read destination))))
          (should (equal services url-proxy-services))
          (should (eq connections url-http-open-connections))
          (should (eq url-proxy-locator #'url-default-find-proxy-for-url))))))))

(ert-deftest zr-erc-link-http-proxy-failure-does-not-fall-back-direct ()
  (zr-erc-link-test--server
   (lambda (base directory)
     (zr-erc-link-test--proxy
      (lambda (proxy log)
        (with-temp-buffer
          (let* ((destination (expand-file-name "download" directory))
                 (job (zr-erc-link--fetch
                       (list :target (concat base "/drop") :rule (list :proxy proxy))
                       destination)))
            ;; The origin would serve /drop successfully if requested directly.
            (let ((url-proxy-locator (lambda (&rest _) "DIRECT")))
              (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job))))
            (should (zr-erc-link--job-error job))
            (should-not (file-exists-p destination))
            (with-current-buffer log
              (should (= 1 (how-many "^GET " (point-min) (point-max))))))))))))

(ert-deftest zr-erc-link-https-through-http-proxy ()
  (skip-unless (and (executable-find "openssl") (gnutls-available-p)))
  (let* ((directory (make-temp-file "erc-media-tls-" t))
         (ca (expand-file-name "ca.pem" directory))
         (ca-key (expand-file-name "ca-key.pem" directory))
         (csr (expand-file-name "request.pem" directory))
         (cert (expand-file-name "cert.pem" directory))
         (key (expand-file-name "key.pem" directory)))
    (unwind-protect
        (progn
          (should (= 0 (call-process "openssl" nil nil nil "req" "-x509" "-newkey" "rsa:2048"
                                     "-nodes" "-keyout" ca-key "-out" ca "-days" "1"
                                     "-subj" "/CN=ERC media test CA")))
          (should (= 0 (call-process "openssl" nil nil nil "req" "-new" "-newkey" "rsa:2048"
                                     "-nodes" "-keyout" key "-out" csr
                                     "-subj" "/CN=127.0.0.1" "-addext" "subjectAltName=IP:127.0.0.1")))
          (should (= 0 (call-process "openssl" nil nil nil "x509" "-req" "-in" csr
                                     "-CA" ca "-CAkey" ca-key "-CAcreateserial" "-out" cert
                                     "-days" "1" "-copy_extensions" "copy")))
          (let ((gnutls-trustfiles (list ca)))
            (zr-erc-link-test--server
             (lambda (base downloads)
               (zr-erc-link-test--proxy
                (lambda (proxy log)
                  (with-temp-buffer
                    (let* ((destination (expand-file-name "download" downloads))
                           (job (zr-erc-link--fetch
                                 (list :target (concat base "/data") :rule (list :proxy proxy))
                                 destination)))
                      (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
                      (should-not (zr-erc-link--job-error job))
                      (should (= 13 (length (zr-erc-link-test--read destination))))
                      (with-current-buffer log
                        (should (string-match-p (concat "^CONNECT " (regexp-quote (substring base 8)) "$")
                                                (buffer-string)))))))))
             (list cert key))))
      (delete-directory directory t))))

(ert-deftest zr-erc-link-connect-response-is-not-a-download ()
  (let* ((directory (make-temp-file "erc-media-connect-" t))
         (destination (expand-file-name "download" directory))
         (raw (expand-file-name "raw" directory))
         (job (make-zr-erc-link--job :destination destination :overwrite t
                                     :raw raw :max-bytes 1024
                                     :timer (run-at-time 60 nil #'ignore))))
    (unwind-protect
        (progn
          (write-region "original" nil destination nil 'silent)
          ;; URL can invoke the callback with CONNECT's 200 status after a
          ;; rejected TLS handshake.  Never overwrite a file with that body.
          (with-temp-buffer
            (insert "HTTP/1.1 200 Connection established\r\n\r\n")
            (setq-local url-http-response-status 200
                        url-http-end-of-headers (1- (point-max))
                        url-http-after-change-function #'url-https-proxy-after-change-function)
            (zr-erc-link--received nil job))
          (should (zr-erc-link--job-error job))
          (should-not (file-exists-p raw))
          (should (equal (zr-erc-link-test--read destination) "original")))
      (cancel-timer (zr-erc-link--job-timer job))
      (delete-directory directory t))))

(ert-deftest zr-erc-link-http-auth-source-download-and-failures ()
  (zr-erc-link-test--server
   (lambda (base directory)
     (with-temp-buffer
       (let* ((auth-file (expand-file-name "authinfo" directory))
              (auth-sources (list auth-file)) (auth-source-do-cache nil)
              (destination (expand-file-name "download" directory))
              (port (url-port (url-generic-parse-url base)))
              (rule '(:type file :max-age 60 :auth-source (:user "bridge") :auth-scheme bearer
                      :headers (("X-Bridge" . "onebot")))))
         (write-region (format "machine 127.0.0.1 port %d login bridge password media-secret\n" port)
                       nil auth-file nil 'silent)
         (set-file-modes auth-file #o600)
         (let ((job (zr-erc-link--fetch (zr-erc-link--item (concat base "/file") nil rule)
                                         destination)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should-not (zr-erc-link--job-error job))
           (should (equal (zr-erc-link-test--read destination) (unibyte-string 98 105 110 97 114 121 0 102 105 108 101 255 10)))
           (should-not (file-exists-p (zr-erc-link--job-raw job))))
         ;; Failures never overwrite an existing destination.
         (dolist (path '("/redirect" "/error"))
           (let ((job (zr-erc-link--fetch (list :target (concat base path) :rule rule)
                                           destination t)))
             (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
             (should (zr-erc-link--job-error job))
             (should (= 13 (length (zr-erc-link-test--read destination))))))
         (let ((job (zr-erc-link--fetch (list :target (concat base "/leak-count"))
                                         destination t)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should (equal (zr-erc-link-test--read destination) "0")))
         (let ((job (zr-erc-link--fetch
                     (list :target (concat base "/slow") :rule '(:timeout 0.05))
                     destination t)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should (zr-erc-link--job-error job))
           (should-not (buffer-live-p (zr-erc-link--job-request job)))))))))

(ert-deftest zr-erc-link-http-opens-files-in-one-session-directory ()
  (let ((zr-erc-link--directory nil)
        (kill-emacs-hook nil)
        files)
    (unwind-protect
        (zr-erc-link-test--server
         (lambda (base _directory)
           (dolist (name '("image.png" "data.txt"))
             (let ((source (generate-new-buffer " *erc-link-source*"))
                   viewer file)
               (unwind-protect
                   (with-current-buffer source
                     (insert "media link\n")
                     (let ((before (buffer-string)) job)
                       ;; Exercise real HTTP and native file modes on terminal Emacs.
                       (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil))
                                 ((symbol-function 'pop-to-buffer)
                                  (lambda (buffer &rest _) (setq viewer buffer))))
                         (setq job (zr-erc-link--fetch
                                    (list :target (concat base "/" name) :type 'file))
                               file (zr-erc-link--job-raw job))
                         (push file files)
                         (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job))))
                       (should-not (zr-erc-link--job-error job))
                       (should (buffer-live-p viewer))
                       (should-not (eq source viewer))
                       (should (equal before (buffer-string)))
                       (should-not (overlays-in (point-min) (point-max)))
                       (should-not zr-erc-link--jobs)
                       (should-not (buffer-live-p (zr-erc-link--job-request job)))
                       (should (equal (file-name-directory file)
                                      (file-name-as-directory zr-erc-link--directory)))
                       (with-current-buffer viewer
                         (should (equal buffer-file-name file))
                         (if (string-suffix-p ".png" name)
                             (should (string-prefix-p (unibyte-string 137 80 78 71)
                                                      (zr-erc-link-test--read file)))
                           (should (eq major-mode 'text-mode))
                           (should (equal (zr-erc-link-test--read file)
                                          (unibyte-string 98 105 110 97 114 121 0 102 105 108 101 255 10)))))
                       (kill-buffer source)
                       (kill-buffer viewer)
                       (should (file-exists-p file))))
                 (when (buffer-live-p source) (kill-buffer source))
                 (when (buffer-live-p viewer) (kill-buffer viewer)))))))
      (zr-erc-link--cleanup-directory))
    (dolist (file files) (should-not (file-exists-p file)))))

(ert-deftest zr-erc-link-http-bulk-fetches-all-and-opens-one-after-failures ()
  (let ((zr-erc-link--directory nil)
        (kill-emacs-hook nil)
        viewer)
    (unwind-protect
        (zr-erc-link-test--server
         (lambda (base _directory)
           (with-temp-buffer
             (dolist (path '("error" "data.txt" "image.png"))
               (let ((button (zr-erc-link-test--button path)))
                 (setf (plist-get (button-get button 'zr-erc-link-item) :target)
                       (concat base "/" path))))
             (cl-letf (((symbol-function 'pop-to-buffer)
                        (lambda (buffer &rest _)
                          (should-not viewer)
                          (should-not zr-erc-link--jobs)
                          (setq viewer buffer))))
               (zr-erc-link-open (point-min) (point-max))
               (let ((jobs (copy-sequence zr-erc-link--jobs)))
                 (should (= (length jobs) 3))
                 (zr-erc-link-test--wait
                  (lambda () (cl-every #'zr-erc-link--job-done jobs)))
                 (should (= 1 (cl-count-if #'zr-erc-link--job-error jobs)))))
             (should (buffer-live-p viewer))
             (with-current-buffer viewer
               (should (eq major-mode 'text-mode))
               (should (equal (buffer-name) "*ERC link: data.txt*")))
             (should (= 2 (length (directory-files zr-erc-link--directory nil
                                                   "\\`erc-media-")))))))
      (when (buffer-live-p viewer) (kill-buffer viewer))
      (zr-erc-link--cleanup-directory))))

(ert-deftest zr-erc-link-http-extensionless-images-use-native-navigation ()
  (save-window-excursion
    (let ((zr-erc-link--directory nil)
          (kill-emacs-hook nil)
          (auto-mode-alist nil)
          (magic-mode-alist nil)
          (magic-fallback-mode-alist nil))
      (unwind-protect
          (zr-erc-link-test--server
           (lambda (base _directory)
             (with-temp-buffer
               (dolist (path '("/download?image=one" "/data" "/download?image=two"))
                 (let ((button (zr-erc-link-test--button path)))
                   (setf (plist-get (button-get button 'zr-erc-link-item) :target)
                         (concat base path))))
               (let (viewer)
                 (cl-letf (((symbol-function 'pop-to-buffer)
                            (lambda (buffer &rest _)
                              (should-not viewer)
                              (setq viewer buffer))))
                   (zr-erc-link-open (point-min) (point-max))
                   (let ((jobs (copy-sequence zr-erc-link--jobs)))
                     (zr-erc-link-test--wait
                      (lambda () (cl-every #'zr-erc-link--job-done jobs)))
                     (should-not (cl-some #'zr-erc-link--job-error jobs))))
                 (should (buffer-live-p viewer))
                 (should (string-suffix-p "-download.png"
                                          (buffer-local-value 'buffer-file-name viewer)))
                 (let ((images (directory-files zr-erc-link--directory t "\\.png\\'"))
                       (data (car (directory-files zr-erc-link--directory t "-data\\'"))))
                   (should (= 2 (length images)))
                   (should data)
                   (should-not (directory-files zr-erc-link--directory nil "-download\\'"))
                   (dolist (file images)
                     (should (string-prefix-p (unibyte-string 137 80 78 71)
                                              (zr-erc-link-test--read file))))
                   (should (equal (zr-erc-link-test--read (car images))
                                  (zr-erc-link-test--read (cadr images))))
                   (should (equal (zr-erc-link-test--read data)
                                  (unibyte-string 98 105 110 97 114 121 0 102 105 108 101 255 10)))
                   (switch-to-buffer (find-file-noselect (car images)))
                   ;; Exercise native navigation without rendering in this nox build.
                   (setq major-mode 'image-mode)
                   (image-next-file 1)
                   (should (equal buffer-file-name (cadr images)))
                   (setq major-mode 'image-mode)
                   (image-previous-file 1)
                   (should (equal buffer-file-name (car images)))
                   (dolist (file images) (should (file-exists-p file)))
                   (kill-buffer (current-buffer))
                   (should (file-exists-p (car images))))))))
        (when zr-erc-link--directory
          (dolist (file (directory-files zr-erc-link--directory t "\\`erc-media-"))
            (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer)))
          (when-let* ((buffer (get-buffer (file-name-nondirectory zr-erc-link--directory))))
            (kill-buffer buffer)))
        (zr-erc-link--cleanup-directory)))))

(ert-deftest zr-erc-link-open-failure-cleans-up-file-and-buffer ()
  (with-temp-buffer
    (let* ((file (make-temp-file "erc-link-open-" nil ".txt"))
           (job (make-zr-erc-link--job
                 :buffer (current-buffer) :raw file :max-bytes 1024
                 :item '(:target "https://example.test/file.txt" :type file)
                 :timer (run-at-time 60 nil #'ignore)))
           (find-file-hook (list (lambda () (error "Cannot open this file")))))
      (push job zr-erc-link--jobs)
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert "HTTP/1.1 200 OK\r\n\r\n")
              (setq-local url-http-response-status 200
                          url-http-end-of-headers (1- (point-max)))
              (insert "file contents\n")
              (zr-erc-link--received nil job))
            (should (zr-erc-link--job-error job))
            (should-not (file-exists-p file))
            (should-not (get-file-buffer file))
            (should-not zr-erc-link--jobs))
        (zr-erc-link--cleanup job)))))

(ert-deftest zr-erc-link-download-does-not-open-a-buffer ()
  (zr-erc-link-test--server
   (lambda (base directory)
     (dolist (name '("image.png" "download?image=one" "archive.zip"))
       (with-temp-buffer
         (let* ((destination (expand-file-name "download" directory))
                (job (zr-erc-link--fetch
                      (list :target (concat base "/" name) :type 'file) destination t)))
           (cl-letf (((symbol-function 'zr-erc-link--open-file)
                      (lambda (&rest _) (ert-fail "Download must only save the file"))))
             (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job))))
           (should-not (zr-erc-link--job-error job))
           (should (file-exists-p destination))
           (should-not (file-exists-p (zr-erc-link--job-raw job)))
           (should-not zr-erc-link--jobs)))))))

(ert-deftest zr-erc-link-http-inherited-response-limit ()
  (zr-erc-link-test--server
   (lambda (base directory)
     (with-temp-buffer
       (let* ((zr-erc-link-rules '((:type file :max-bytes 12 :timeout 2)
                                  (:regexp "https?://[^[:space:]]+" :type file)))
              (destination (expand-file-name "download" directory))
              (item (zr-erc-link--item (concat base "/data") nil)))
         (write-region "original" nil destination nil 'silent)
         (let ((job (zr-erc-link--fetch item destination t)))
           (should (= (zr-erc-link--job-timeout job) 2))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should (zr-erc-link--job-error job))
           (should (equal (zr-erc-link-test--read destination) "original")))
         ;; A specific rule can raise the inherited response limit.
         (setf (plist-get (cadr zr-erc-link-rules) :max-bytes) 13)
         (let ((job (zr-erc-link--fetch (zr-erc-link--item (concat base "/data") nil)
                                       destination t)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should-not (zr-erc-link--job-error job))
           (should (= (length (zr-erc-link-test--read destination)) 13))))))))

(provide 'zr-erc-link-test)
;;; zr-erc-link-test.el ends here
