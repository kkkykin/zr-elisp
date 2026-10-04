;;; zr-erc-link-test.el --- Media retrieval tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-link)
(require 'gnutls)

(ert-deftest zr-erc-link-forward-command-and-org-dispatch ()
  (with-temp-buffer
    (let ((zr-erc-link-rules
           '((:regexp "\\[查看合并转发：ircs?://[^/[:space:]]+/\\(#[^?[:space:]]+\\)\\?\\([^][:space:]]+\\)\\]"
              :replace "/join \\1 \\2" :type command :auto-show t)
             (:regexp "文档(\\([^)]*\\))" :replace "\\1" :type org :auto-show t)))
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
          (button-activate first)
          (button-activate (next-button (button-end first) t))))
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
  (dolist (rules '(nil ((:regexp "https?://[^[:space:]]+" :type org :match (:sender "^other!")))))
    (with-temp-buffer
      (let ((zr-erc-link-rules rules)
            (erc-message-parsed (make-erc-response :command "PRIVMSG" :sender "bot!u@h")))
        (insert "https://example.test/a.png")
        (zr-erc-link--insert)
        (should-not (next-button (point-min) t))))))

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
      (should (equal (nreverse types) '(image file org org))))))

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
            :type image :match (:tags (("+bridge" . "^onebot$")))))))
    (should-not (zr-erc-link--item "https://cdn.test/a" nil))
    (should (equal (plist-get (zr-erc-link--item "https://cdn.test/a"
                                                '(:tags (("+bridge" . "onebot")))) :target)
                   "https://proxy.test/a")))
  (with-temp-buffer
    (let ((zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :url-tag "+image" :type image)))
          (erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "hello"
                              :unparsed "@+image=https://example.test/photo :bot PRIVMSG #c :hello")))
      (insert "<bot> hello\n")
      (zr-erc-link--insert)
      (goto-char (point-min))
      (search-forward "[image]")
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

(ert-deftest zr-erc-link-auto-show-is-opt-in-and-overridable ()
  (with-temp-buffer
    (let ((erc-message-parsed
           (make-erc-response :command "PRIVMSG" :sender "bot!u@h" :contents "url"
                              :unparsed ":bot PRIVMSG #c :target")) fetched)
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'zr-erc-link--fetch)
                 (lambda (&rest _) (setq fetched t))))
        (insert "<bot> https://example.test/a.png\n")
        (zr-erc-link--insert)
        (should-not fetched)
        (erase-buffer)
        (insert "<bot> https://example.test/a.png\n")
        (let ((zr-erc-link-rules '((:regexp "https?://[^[:space:]]+png" :type image :auto-show t))))
          (zr-erc-link--insert))
        (should fetched)))))

(defun zr-erc-link-test--button (label &optional type rule)
  "Insert a media button named LABEL, with TYPE and RULE, then a newline."
  (let ((start (point)))
    (insert label)
    (zr-erc-link--buttonize
     start (point) (list :target (concat "https://example.test/" label)
                        :type (or type 'image) :rule rule :time (current-time)))
    (prog1 (button-at start) (insert "\n"))))

(ert-deftest zr-erc-link-show-at-point-with-auto-show-disabled ()
  (with-temp-buffer
    (let ((zr-erc-link-auto-show nil) fetched)
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'zr-erc-link--fetch)
                 (lambda (item anchor &rest _)
                   (push (list (plist-get item :target) anchor) fetched) nil)))
        (let ((button (zr-erc-link-test--button "first.png")))
          (zr-erc-link-test--button "second.png")
          (should-not fetched)
          (goto-char (1+ (button-start button)))
          (call-interactively #'zr-erc-link-show)
          (should (equal fetched `(("https://example.test/first.png" ,(button-end button)))))
          (should (= (point) (1+ (button-start button)))))))))

(ert-deftest zr-erc-link-toggle-manual-and-automatic-previews ()
  (dolist (auto-show '(nil t))
    (with-temp-buffer
      (let ((zr-erc-link-auto-show auto-show)
            (image-display t))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) image-display))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _) (generate-new-buffer " *erc-media-request*")))
                  ((symbol-function 'create-image)
                   (lambda (file &rest _) (list 'image :type 'png :file file))))
          (let ((button (zr-erc-link-test--button "image.png")))
            (goto-char (button-start button))
            (unless auto-show (call-interactively #'zr-erc-link-show))
            (let* ((job (button-get button 'zr-erc-link-job))
                   (raw (zr-erc-link--job-raw job)))
              (zr-erc-link--show job raw)
              (should (overlay-buffer (zr-erc-link--job-overlay job)))
              ;; Hiding needs neither a fresh link nor an image-capable display.
              (setf (plist-get (zr-erc-link--job-item job) :time) 0)
              (setq-local zr-erc-link-max-age 60)
              (setq buffer-read-only t image-display nil)
              (if auto-show (button-activate button)
                (call-interactively #'zr-erc-link-show))
              (should-not (overlay-buffer (zr-erc-link--job-overlay job)))
              (should-not (file-exists-p raw))
              (should-not (buffer-live-p (zr-erc-link--job-request job)))
              (should-not (memq (zr-erc-link--job-timer job) timer-list))
              (should-not (marker-buffer (zr-erc-link--job-anchor job)))
              (should-not (button-get button 'zr-erc-link-job))
              (should-not zr-erc-link--jobs)
              ;; Once hidden, the next activation starts a new preview.
              (setq-local zr-erc-link-max-age nil)
              (setq image-display t)
              (button-activate button)
              (let ((next (button-get button 'zr-erc-link-job)))
                (should (memq next zr-erc-link--jobs))
                (should-not (eq job next))))))))))

(ert-deftest zr-erc-link-toggle-cancels-pending-preview-and-retries-failures ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'url-retrieve)
               (lambda (&rest _) (generate-new-buffer " *erc-media-request*"))))
      (let ((button (zr-erc-link-test--button "image.png")))
        (goto-char (button-start button))
        (zr-erc-link-show)
        (let* ((job (button-get button 'zr-erc-link-job))
               (download (zr-erc-link--fetch (zr-erc-link--job-item job)
                                              (button-end button) "/unused/download")))
          (should-not (zr-erc-link--job-done job))
          (zr-erc-link-show)
          (should (zr-erc-link--job-done job))
          (should-not (buffer-live-p (zr-erc-link--job-request job)))
          (should-not (file-exists-p (zr-erc-link--job-raw job)))
          (should-not (button-get button 'zr-erc-link-job))
          (should (equal zr-erc-link--jobs (list download)))
          (should-not (zr-erc-link--job-done download))
          ;; A late callback cannot recreate the canceled preview.
          (cl-letf (((symbol-function 'zr-erc-link--show)
                     (lambda (&rest _) (ert-fail "Canceled preview was displayed"))))
            (with-temp-buffer (zr-erc-link--received nil job)))
          (should-not (zr-erc-link--job-overlay job)))
        ;; Failed and buffer-cleaned jobs must not consume an extra toggle.
        (dolist (cleanup '(failure buffer))
          (zr-erc-link-show)
          (let ((job (button-get button 'zr-erc-link-job)))
            (if (eq cleanup 'failure) (zr-erc-link--fail job "Test failure")
              (zr-erc-link--cleanup-buffer))
            (zr-erc-link-show)
            (let ((next (button-get button 'zr-erc-link-job)))
              (should (memq next zr-erc-link--jobs))
              (should-not (eq next job)))
            (zr-erc-link-show)))))))

(ert-deftest zr-erc-link-toggle-range-hides-mixed-previews ()
  (dolist (visible-window '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (let ((transient-mark-mode t)
              (current-prefix-arg (and visible-window '(4))))
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                    ((symbol-function 'url-retrieve)
                     (lambda (&rest _) (generate-new-buffer " *erc-media-request*")))
                    ((symbol-function 'create-image)
                     (lambda (file &rest _) (list 'image :type 'png :file file))))
            (let* ((outside (zr-erc-link-test--button "outside.png" 'image '(:auto-show t)))
                   (shown (zr-erc-link-test--button "shown.png" 'image '(:auto-show t)))
                   (pending (zr-erc-link-test--button "pending.png" 'image '(:auto-show t)))
                   (hidden (zr-erc-link-test--button "hidden.png"))
                   (file (zr-erc-link-test--button "archive.zip" 'file))
                   (job (button-get shown 'zr-erc-link-job))
                   (beg (1+ (button-start shown)))
                   (end (button-start file)))
              (zr-erc-link--show job (zr-erc-link--job-raw job))
              (goto-char beg)
              ;; With a prefix, the visible window takes precedence over a
              ;; region that includes OUTSIDE and excludes our target images.
              (set-mark (if visible-window (point-min) end))
              (set-window-start (selected-window) beg)
              (setq mark-active t buffer-read-only t)
              (cl-letf (((symbol-function 'window-end) (lambda (&rest _) end)))
                (call-interactively #'zr-erc-link-show)
                (should (equal zr-erc-link--jobs
                               (list (button-get outside 'zr-erc-link-job))))
                (should-not (overlay-buffer (zr-erc-link--job-overlay job)))
                (dolist (button (list shown pending hidden))
                  (should-not (button-get button 'zr-erc-link-job)))
                (should (= (point) beg))
                (should (= (mark) (if visible-window (point-min) end)))
                (call-interactively #'zr-erc-link-show)
                (dolist (button (list shown pending hidden))
                  (should (memq (button-get button 'zr-erc-link-job) zr-erc-link--jobs)))
                (should-not (button-get file 'zr-erc-link-job))
                (should (= (length zr-erc-link--jobs) 4))))))))))

(ert-deftest zr-erc-link-show-region-overlaps-and-skips-files ()
  (dolist (reverse '(nil t))
    (with-temp-buffer
      (let ((transient-mark-mode t) fetched)
        (zr-erc-link-test--button "outside-before.png")
        (let* ((first (zr-erc-link-test--button "first.png"))
               (_file (zr-erc-link-test--button "archive.zip" 'file))
               (_plain (insert-text-button "ordinary button"))
               (last (zr-erc-link-test--button "[image]"))
               (after (zr-erc-link-test--button "outside-after.png"))
               (beg (1+ (button-start first)))
               (end (button-start after)))
          ;; LAST is a tag-style label adjacent to a non-media button.
          (goto-char (if reverse end beg))
          (set-mark (if reverse beg end))
          (setq mark-active t buffer-read-only t)
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                    ((symbol-function 'zr-erc-link--fetch)
                     (lambda (item anchor &rest _)
                       (push (list (plist-get item :target) anchor) fetched)
                       (make-zr-erc-link--job :item item))))
            (call-interactively #'zr-erc-link-show)
            (should (equal (nreverse fetched)
                           `(("https://example.test/first.png" ,(button-end first))
                             ("https://example.test/[image]" ,(button-end last)))))
            (dolist (button (list first last))
              (should (zr-erc-link--job-p (button-get button 'zr-erc-link-job)))))
          (should (= (point) (if reverse end beg)))
          (should (= (mark) (if reverse beg end))))))))

(ert-deftest zr-erc-link-show-prefix-uses-visible-window-over-region ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let ((transient-mark-mode t) (current-prefix-arg '(4)) fetched)
        (zr-erc-link-test--button "above.png")
        (let* ((first (zr-erc-link-test--button "visible-first.png"))
               (last (zr-erc-link-test--button "visible-last.png")))
          (zr-erc-link-test--button "below.png")
          (goto-char (button-start first))
          (set-window-start (selected-window) (button-start first))
          (set-mark (point-min))
          (setq mark-active t)
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                    ;; Batch Emacs has no redisplay; end partway through LAST.
                    ((symbol-function 'window-end)
                     (lambda (&rest _) (1+ (button-start last))))
                    ((symbol-function 'zr-erc-link--fetch)
                     (lambda (item _anchor &rest _)
                       (push (plist-get item :target) fetched) nil)))
            (call-interactively #'zr-erc-link-show)
            (should (equal (nreverse fetched)
                           '("https://example.test/visible-first.png"
                             "https://example.test/visible-last.png")))))))))

(ert-deftest zr-erc-link-show-range-continues-after-expiration-and-errors ()
  (with-temp-buffer
    (let ((expired (zr-erc-link-test--button "expired.png" 'image '(:max-age 60)))
          fetched)
      (let ((item (button-get expired 'zr-erc-link-item)))
        (setf (plist-get item :time) 0))
      (zr-erc-link-test--button "broken.png")
      (zr-erc-link-test--button "valid.png")
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'zr-erc-link--fetch)
                 (lambda (item _anchor &rest _)
                   (let ((url (plist-get item :target)))
                     (push url fetched)
                     (when (string-suffix-p "broken.png" url)
                       (user-error "No auth-source entry for this media rule")))
                   nil)))
        (zr-erc-link-show (point-min) (point-max))
        (should (equal (nreverse fetched)
                       '("https://example.test/broken.png" "https://example.test/valid.png")))))))

(ert-deftest zr-erc-link-show-empty-range-and-non-image-display ()
  (with-temp-buffer
    (zr-erc-link-test--button "archive.zip" 'file)
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
      (should-error (zr-erc-link-show (point-min) (point-max)) :type 'user-error))
    (let ((image (zr-erc-link-test--button "image.png")))
      (goto-char (button-start image))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
        (should-error (zr-erc-link-show (1+ (point)) (1+ (point))) :type 'user-error))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil))
                ((symbol-function 'zr-erc-link--fetch)
                 (lambda (&rest _) (ert-fail "Must not fetch without image support"))))
        (should-error (call-interactively #'zr-erc-link-show) :type 'user-error)))))

(ert-deftest zr-erc-link-button-activation-ignores-region-and-prefix ()
  (with-temp-buffer
    (let* ((transient-mark-mode t)
           (current-prefix-arg '(4))
           (button (zr-erc-link-test--button "first.png"))
           fetched)
      (zr-erc-link-test--button "second.png")
      (goto-char (point-min))
      (set-mark (point-max))
      (setq mark-active t)
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'zr-erc-link--fetch)
                 (lambda (item _anchor &rest _)
                   (push (plist-get item :target) fetched) nil)))
        (button-activate button)
        (should (equal fetched '("https://example.test/first.png")))))))

(ert-deftest zr-erc-link-age-uses-server-time-or-receipt ()
  (let ((now (encode-time '(0 0 12 2 10 2026 nil nil 0)))
        (zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :type image))))
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

(ert-deftest zr-erc-link-age-boundary-and-local-overrides ()
  (let ((now 1000)
        (zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :type image))))
    (cl-letf (((symbol-function 'current-time) (lambda () now)))
      (let ((item (zr-erc-link--item "https://example.test/a" nil)))
        (setq now 1060)
        (with-temp-buffer
          (setq-local zr-erc-link-max-age 60)
          (should-not (zr-erc-link--expired-p item))
          (setq now 1061)
          (should (zr-erc-link--expired-p item))
          (with-temp-buffer
            (should-not (zr-erc-link--expired-p item)))
          (setf (plist-get (plist-get item :rule) :max-age) nil)
          (should-not (zr-erc-link--expired-p item))
          (setq-local zr-erc-link-max-age nil)
          (setf (plist-get (plist-get item :rule) :max-age) 60)
          (should (zr-erc-link--expired-p item)))))))

(ert-deftest zr-erc-link-expired-history-skips-auto-requests ()
  ;; Both visible URLs and URLs supplied only by tags use the message time.
  (dolist (tag-url '(nil t))
    (with-temp-buffer
      (let* ((zr-erc-link-rules
              `((:regexp "https?://[^[:space:]]+" :type image :auto-show t :max-age 60
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
          (zr-erc-link-rules '((:regexp "https?://[^[:space:]]+" :type image :max-age 60)))
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
          (should-error (zr-erc-link-show) :type 'user-error)
          (should-error (zr-erc-link-download "/unused/download") :type 'user-error)
          (should-error (call-interactively #'zr-erc-link-download) :type 'user-error)
          (setf (plist-get (plist-get item :rule) :auth-source) t)
          (dolist (destination '(nil "/unused/download"))
            (should-error (zr-erc-link--fetch item (point-max) destination) :type 'user-error))
          (should-not side-effects)
          (should-not zr-erc-link--jobs))))))

(ert-deftest zr-erc-link-invalid-proxy-does-not-start-request ()
  (with-temp-buffer
    (dolist (proxy '(t "" "localhost" "host:0" "host:65536" "host:bad"
                    "https://host:80" "socks5://host:80" "http://user:secret@host:80"
                    "http://host:80/path" "host:80;DIRECT" "host:80\n"))
      (let ((zr-erc-link-proxy proxy))
        (should-error (zr-erc-link--fetch '(:target "http://127.0.0.1/image") (point))
                      :type 'user-error)
        (should-not zr-erc-link--jobs))))
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
            (setq-local zr-erc-link-proxy proxy)
            ;; Explicit proxy overrides no_proxy; nil forces a direct request.
            (dolist (rule '(nil (:proxy nil)))
              (let ((job (zr-erc-link--fetch (list :target (concat base "/data") :rule rule)
                                              (point) destination t)))
                (with-current-buffer (zr-erc-link--job-request job)
                  (should-not (eq url-http-open-connections connections))
                  (should (equal (url-find-proxy-for-url (url-generic-parse-url base) "127.0.0.1")
                                 (unless rule (concat proxy "/")))))
                (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
                (should-not (zr-erc-link--job-error job))))
            (with-current-buffer log
              (should (= 1 (how-many "^GET " (point-min) (point-max)))))
            ;; Another buffer keeps the default (inherited direct connection).
            (with-temp-buffer
              (let ((job (zr-erc-link--fetch (list :target (concat base "/data"))
                                              (point) destination t)))
                (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
                (should-not (zr-erc-link--job-error job))))
            ;; A rule can restore an inherited proxy over a local direct setting.
            (setq-local zr-erc-link-proxy nil)
            (let* ((url-proxy-locator (lambda (_url _host) (concat "PROXY " (substring proxy 7))))
                   (job (zr-erc-link--fetch (list :target (concat base "/data") :rule '(:proxy inherit))
                                             (point) destination t)))
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
                       (point) destination)))
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
                                 (point) destination)))
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
                                         (point) destination)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should-not (zr-erc-link--job-error job))
           (should (equal (zr-erc-link-test--read destination) (unibyte-string 98 105 110 97 114 121 0 102 105 108 101 255 10)))
           (should-not (file-exists-p (zr-erc-link--job-raw job))))
         ;; Failures never overwrite an existing destination.
         (dolist (path '("/redirect" "/error"))
           (let ((job (zr-erc-link--fetch (list :target (concat base path) :rule rule)
                                           (point) destination t)))
             (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
             (should (zr-erc-link--job-error job))
             (should (= 13 (length (zr-erc-link-test--read destination))))))
         (let ((job (zr-erc-link--fetch (list :target (concat base "/leak-count"))
                                         (point) destination t)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should (equal (zr-erc-link-test--read destination) "0")))
         (let* ((zr-erc-link-timeout 0.05)
                (job (zr-erc-link--fetch (list :target (concat base "/slow")) (point) destination t)))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job)))
           (should (zr-erc-link--job-error job))
           (should-not (buffer-live-p (zr-erc-link--job-request job)))))))))

(ert-deftest zr-erc-link-real-ffmpeg-preview-and-cleanup ()
  (skip-unless (and (executable-find "ffmpeg") (executable-find "ffprobe")))
  (zr-erc-link-test--server
   (lambda (base _directory)
     (with-temp-buffer
       (insert "image link\n")
       (let ((zr-erc-link-use-ffmpeg t)
             (zr-erc-link-max-width 160) (zr-erc-link-max-height 100)
             job)
         ;; This terminal build has no image support.  The actual HTTP and
         ;; FFmpeg pipeline still runs; inspect the output and display property.
         (cl-letf (((symbol-function 'create-image)
                    (lambda (file &rest _) (list 'image :type 'png :file file))))
           (setq job (zr-erc-link--fetch (list :target (concat base "/image.png") :type 'image) 1))
           (zr-erc-link-test--wait (lambda () (zr-erc-link--job-done job))))
         (should-not (zr-erc-link--job-error job))
         (let ((file (zr-erc-link--job-preview job)))
           (with-temp-buffer
             (should (= 0 (call-process "ffprobe" nil t nil "-v" "error" "-select_streams" "v:0"
                                        "-show_entries" "stream=width,height" "-of" "csv=s=x:p=0" file)))
             (should (equal (string-trim (buffer-string)) "160x90")))
           (should (get-text-property 1 'display
                                      (overlay-get (zr-erc-link--job-overlay job) 'after-string)))
           (zr-erc-link--cleanup-buffer)
           (should-not (file-exists-p file))
           (should-not (file-exists-p (zr-erc-link--job-raw job)))))))))

(provide 'zr-erc-link-test)
;;; zr-erc-link-test.el ends here
