;;; zr-erc-upload.el --- Upload files and share links in ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; Keywords: comm

;;; Commentary:

;; Enable `erc-zr-upload-mode' to use `yank-media' for clipboard images
;; and files copied from a file manager.  `zr-erc-upload-file' also works
;; without enabling the module.  Uploads run asynchronously and append links
;; to the originating conversation's input.  Set `zr-erc-upload-auto-send'
;; to send them directly instead, preserving draft input.
;; Configure `zr-erc-upload-backend-order' for automatic fallback and
;; `zr-erc-upload-expiry-hours' for a minimum retention time.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'erc)
(require 'yank-media)
(require 'mailcap)
(require 'dnd)
(require 'url-parse)
(require 'zr-http)
(require 'format-spec)

(defgroup zr-erc-upload nil
  "Upload files and share their links in ERC."
  :group 'erc :prefix "zr-erc-upload-")

(defcustom zr-erc-upload-backends
  '((litterbox . zr-erc-upload-litterbox)
    (tempfile . zr-erc-upload-tempfile)
    (tmp0 . zr-erc-upload-tmp0)
    (beacon . zr-erc-upload-beacon))
  "Alist of backend names and upload functions.
Each function receives a local FILE and a CALLBACK, and returns a
function of no arguments that cancels the upload and releases resources.
Call CALLBACK with (URL nil) on success, or (nil ERROR-STRING) on failure.
The callback may run synchronously.  Backend functions run in the
originating ERC buffer, so they can use buffer-local configuration."
  :type '(alist :key-type symbol :value-type function))

(defcustom zr-erc-upload-backend-order '(litterbox tempfile tmp0 beacon)
  "Backend names to try in order, from `zr-erc-upload-backends'.
Each backend is tried once, stopping at the first valid URL.  Errors,
timeouts and invalid responses advance to the next backend.  A prefix
argument to `zr-erc-upload-file' selects just one backend for that upload."
  :type '(repeat symbol))

(defcustom zr-erc-upload-expiry-hours 1
  "Minimum retention time in hours for uploaded files.
Backends round up to their shortest supported duration.  A backend that
cannot meet this duration fails, allowing the next backend to be tried.
Beacon's anonymous uploads always last 24 hours."
  :type 'number)

(defcustom zr-erc-upload-auto-send nil
  "Whether to send upload links directly instead of inserting them in input.
By default, append each link to the originating conversation's draft,
separated by a space when needed.  Non-nil sends each link as a literal
message through ERC, preserving draft input.  The setting is captured
when uploading starts and can be buffer-local."
  :type 'boolean)

(defcustom zr-erc-upload-link-format "%u"
  "Format of the link inserted or sent after uploading.
A string template supports %u for the URL, %f for the file's basename,
and %% for a percent sign.  Alternatively, a function receives the URL
and original filename and returns the message.  The format is captured
when uploading starts.  The result must be a nonempty single line."
  :type '(choice string function))

(defcustom zr-erc-upload-http-options '(:timeout 120)
  "HTTP options overriding `zr-http-default-options' for uploads."
  :type 'sexp)

(cl-defstruct zr-erc-upload--job
  buffer target connection file temporary format auto-send backends errors
  expiry-hours http-options cancel done)

(defvar-local zr-erc-upload--jobs nil)
(defvar-local zr-erc-upload--yank-state nil)
(defconst zr-erc-upload--file-types
  '(text/uri-list x-special/gnome-copied-files
    x-special/KDE-copied-files x-special/mate-copied-files))

(defun zr-erc-upload--expiry (durations)
  "Choose a value from ascending DURATIONS meeting the requested lifetime.
DURATIONS is an alist of hours and API values."
  (if-let* ((duration (cl-find-if
                      (lambda (entry)
                        (>= (car entry) zr-erc-upload-expiry-hours))
                      durations)))
      (cdr duration)
    (error "Retention of %s hours is unsupported (maximum %s)"
           zr-erc-upload-expiry-hours (caar (last durations)))))

(defun zr-erc-upload--json (text)
  "Parse a successful upload response from JSON TEXT."
  (let ((data (json-parse-string text :object-type 'alist :array-type 'list
                                 :null-object nil :false-object nil)))
    (unless (eq (alist-get 'success data) t)
      (error "%s" (or (alist-get 'error data) (alist-get 'message data)
                       "Upload rejected")))
    data))

(defun zr-erc-upload--request (url form callback &optional parser)
  "Upload multipart FORM to URL, returning a cancellation function.
PARSER extracts a link from the response text; nil uses the trimmed text."
  (let ((request
         (zr-http-request
          url :options zr-erc-upload-http-options :form form
          :callback
          (lambda (response error)
            (let (link reason)
              (condition-case err
                  (cond
                   (error (setq reason error))
                   ((not (<= 200 (plist-get response :status) 299))
                    (setq reason (format "HTTP %s" (plist-get response :status))))
                   (t
                    (let ((text (decode-coding-string (plist-get response :body) 'utf-8)))
                      (setq link (if parser (funcall parser text) (string-trim text))))))
                (error (setq reason (error-message-string err))))
              (funcall callback link reason))))))
    (lambda () (zr-http-cancel request))))

(defun zr-erc-upload-litterbox (file callback)
  "Upload local FILE to Litterbox, returning a cancellation function."
  (zr-erc-upload--request
   "https://litterbox.catbox.moe/resources/internals/api.php"
   (list '("reqtype" . "fileupload")
         (cons "time" (zr-erc-upload--expiry
                       '((1 . "1h") (12 . "12h") (24 . "24h") (72 . "72h"))))
         (cons "fileToUpload" (list :file file)))
   callback))

(defun zr-erc-upload-beacon (file callback)
  "Upload local FILE to Beacon, returning a cancellation function.
The anonymous single-request API accepts up to 4 MB and retains files
for 24 hours."
  (zr-erc-upload--expiry '((24)))
  (zr-erc-upload--request
   "https://beacon.host/v1/upload"
   (list (cons "file" (list :file file))) callback))

(defun zr-erc-upload-tempfile (file callback)
  "Upload local FILE to TempFile, returning a cancellation function."
  (zr-erc-upload--request
   "https://tempfile.org/api/upload/local"
   (list (cons "files" (list :file file))
         (cons "expiryHours" (zr-erc-upload--expiry
                              '((1 . "1") (6 . "6") (24 . "24") (48 . "48")))))
   callback
   (lambda (text)
     (alist-get 'url (car (alist-get 'files (zr-erc-upload--json text)))))))

(defun zr-erc-upload-tmp0 (file callback)
  "Upload local FILE to tmp0, returning a cancellation function.
Share the download page: the API's direct download URL requires POST."
  (zr-erc-upload--request
   "https://tmp0.cc/api/v1/upload"
   (list (cons "file" (list :file file))
         (cons "expires" (zr-erc-upload--expiry
                          '((1 . "1h") (6 . "6h") (12 . "12h") (24 . "1d")
                            (72 . "3d") (168 . "7d") (336 . "14d") (720 . "30d")))))
   callback (lambda (text) (alist-get 'fullUrl (zr-erc-upload--json text)))))

(defun zr-erc-upload--check ()
  "Require a connected ERC conversation."
  (unless (and (derived-mode-p 'erc-mode)
               (erc-server-process-alive) (erc-default-target))
    (user-error "Upload requires a connected ERC conversation")))

(defun zr-erc-upload--check-file (file)
  "Require FILE to be a readable local regular file."
  (unless (and (not (file-remote-p file))
               (file-regular-p file) (file-readable-p file))
    (user-error "Upload requires a readable local file: %s" file)))

(defun zr-erc-upload--cancel-request (job)
  "Release JOB's current request, clearing its cancellation function."
  (when-let* ((cancel (zr-erc-upload--job-cancel job)))
    (setf (zr-erc-upload--job-cancel job) nil)
    (funcall cancel)))

(defun zr-erc-upload--cleanup (job)
  "Cancel JOB and release its temporary file exactly once."
  (unless (zr-erc-upload--job-done job)
    (setf (zr-erc-upload--job-done job) t)
    (unwind-protect
        (zr-erc-upload--cancel-request job)
      (when (zr-erc-upload--job-temporary job)
        (delete-file (zr-erc-upload--job-file job)))
      (when (buffer-live-p (zr-erc-upload--job-buffer job))
        (with-current-buffer (zr-erc-upload--job-buffer job)
          (setq zr-erc-upload--jobs (delq job zr-erc-upload--jobs))
          (unless zr-erc-upload--jobs
            (remove-hook 'kill-buffer-hook #'zr-erc-upload-cancel t)))))))

(defun zr-erc-upload--check-url (url)
  "Require URL to be an HTTP(S) link suitable for sharing."
  (unless (and (stringp url)
               (string-match-p "\\`https?://[^[:space:][:cntrl:]]+\\'" url)
               (when-let* ((host (url-host (url-generic-parse-url url))))
                 (not (string-empty-p host))))
    (error "Backend did not return an HTTP(S) URL: %s" url)))

(defun zr-erc-upload--message (url file template)
  "Format URL and FILE according to TEMPLATE and validate the message."
  (zr-erc-upload--check-url url)
  (let ((text (if (functionp template)
                  (funcall template url file)
                (format-spec template
                             `((?u . ,url) (?f . ,(file-name-nondirectory file)))))))
    (unless (and (stringp text) (not (string-blank-p text))
                 (not (string-match-p "[\0\r\n]" text)))
      (error "Upload link format must produce a nonempty single line"))
    text))

(defun zr-erc-upload--check-origin (job)
  "Require JOB's original conversation and connection to remain available."
  (unless (buffer-live-p (zr-erc-upload--job-buffer job))
    (error "Originating conversation was closed"))
  (with-current-buffer (zr-erc-upload--job-buffer job)
    (zr-erc-upload--check)
    (unless (and (eq erc-server-process (zr-erc-upload--job-connection job))
                 (equal (erc-default-target) (zr-erc-upload--job-target job)))
      (error "Originating connection or target changed"))))

(defun zr-erc-upload--complete (job url reason)
  "Insert or send JOB's URL, or report failure REASON, and release JOB."
  (unless (zr-erc-upload--job-done job)
    (unwind-protect
        (condition-case err
            (progn
              (when reason (error "%s" reason))
              (zr-erc-upload--check-origin job)
              (with-current-buffer (zr-erc-upload--job-buffer job)
                (let ((text (zr-erc-upload--message
                             url (zr-erc-upload--job-file job)
                             (zr-erc-upload--job-format job)))
                      (erc-command-regexp "\\`\\b\\B")
                      (inhibit-read-only t))
                  (save-excursion
                    (save-restriction
                      (widen)
                      (if (zr-erc-upload--job-auto-send job)
                          (unless (erc-send-input text)
                            (error "ERC did not send the upload link"))
                        (unless (and (markerp erc-input-marker)
                                     (eq (marker-buffer erc-input-marker)
                                         (current-buffer)))
                          (error "ERC input area is unavailable"))
                        (goto-char (point-max))
                        (when (and (> (point) erc-input-marker)
                                   (not (memq (char-before) '(?\s ?\t ?\n ?\r))))
                          (insert " "))
                        (insert text)))))))
          (error (message "ERC upload failed: %s%s"
                          (error-message-string err)
                          (if (and (stringp url) (string-match-p "\\`https?://" url))
                              (format " (uploaded URL: %s)" url) ""))))
      (zr-erc-upload--cleanup job))))

(defun zr-erc-upload--next (job)
  "Try JOB's next backend, reporting all failures when none remain."
  (unless (zr-erc-upload--job-done job)
    (condition-case err
        (progn
          (zr-erc-upload--check-origin job)
          (if-let* ((backend (pop (zr-erc-upload--job-backends job))))
              (with-current-buffer (zr-erc-upload--job-buffer job)
                (let ((zr-erc-upload-expiry-hours (zr-erc-upload--job-expiry-hours job))
                      (zr-erc-upload-http-options (zr-erc-upload--job-http-options job))
                      finished)
                  (message "Uploading %s via %s…"
                           (file-name-nondirectory (zr-erc-upload--job-file job))
                           (car backend))
                  (cl-labels
                      ((complete
                        (url reason)
                        (unless (or finished (zr-erc-upload--job-done job))
                          (setq finished t)
                          (unless reason
                            (condition-case err
                                (zr-erc-upload--check-url url)
                              (error (setq reason (error-message-string err)))))
                          (zr-erc-upload--cancel-request job)
                          (if reason
                              (progn
                                (push (format "%s: %s" (car backend) reason)
                                      (zr-erc-upload--job-errors job))
                                (zr-erc-upload--next job))
                            (zr-erc-upload--complete job url nil)))))
                    (let ((cancel
                           (condition-case err
                               (funcall (cdr backend) (zr-erc-upload--job-file job)
                                        #'complete)
                             (error (complete nil (error-message-string err)) nil))))
                      ;; A synchronous callback can already have started the
                      ;; next backend.  Do not replace its cancellation handle.
                      (if (or finished (zr-erc-upload--job-done job))
                          (when cancel (funcall cancel))
                        (setf (zr-erc-upload--job-cancel job) cancel))))))
            (zr-erc-upload--complete
             job nil (string-join (reverse (zr-erc-upload--job-errors job)) "; "))))
      (error (zr-erc-upload--complete job nil (error-message-string err))))))

(defun zr-erc-upload--start (file &optional backend temporary)
  "Upload FILE and share its link in this conversation.
Try `zr-erc-upload-backend-order', or only BACKEND when it is non-nil.
Insert the link in input unless `zr-erc-upload-auto-send' is non-nil.
If TEMPORARY is non-nil, take ownership of FILE and delete it afterwards."
  (let ((job (make-zr-erc-upload--job
              :buffer (current-buffer) :target (erc-default-target)
              :connection erc-server-process :file file :temporary temporary
              :format zr-erc-upload-link-format :auto-send zr-erc-upload-auto-send
              :expiry-hours zr-erc-upload-expiry-hours
              :http-options (copy-tree zr-erc-upload-http-options))))
    (condition-case err
        (progn
          (zr-erc-upload--check)
          (zr-erc-upload--check-file file)
          (unless (and (numberp zr-erc-upload-expiry-hours)
                       (> zr-erc-upload-expiry-hours 0))
            (user-error "Upload expiry must be a positive number of hours"))
          (let ((order (if backend (list backend) zr-erc-upload-backend-order)))
            (unless (and order (proper-list-p order) (cl-every #'symbolp order))
              (user-error "Upload backend order must be a nonempty list of names"))
            (setf (zr-erc-upload--job-backends job)
                  (mapcar
                   (lambda (name)
                     (let ((function (alist-get name zr-erc-upload-backends)))
                       (unless (functionp function)
                         (user-error "Unknown upload backend: %s" name))
                       (cons name function)))
                   (delete-dups (copy-sequence order)))))
          (push job zr-erc-upload--jobs)
          (add-hook 'kill-buffer-hook #'zr-erc-upload-cancel nil t)
          (zr-erc-upload--next job))
      (error (zr-erc-upload--cleanup job) (signal (car err) (cdr err))))
    job))

;;;###autoload
(defun zr-erc-upload-file (file &optional backend)
  "Upload local FILE and insert its link in the current ERC conversation.
If `zr-erc-upload-auto-send' is non-nil, send the link directly instead.
With a prefix argument, choose BACKEND from `zr-erc-upload-backends'."
  (interactive
   (progn
     (zr-erc-upload--check)
     (list (read-file-name "Upload file: " nil nil t)
           (when current-prefix-arg
             (intern (completing-read "Upload backend: "
                                      zr-erc-upload-backends nil t))))))
  (zr-erc-upload--start (expand-file-name file) backend))

;;;###autoload
(defun zr-erc-upload-cancel ()
  "Cancel all pending uploads in the current buffer."
  (interactive)
  (mapc #'zr-erc-upload--cleanup (copy-sequence zr-erc-upload--jobs)))

(defun zr-erc-upload--yank (type data)
  "Upload clipboard DATA of MIME TYPE."
  (zr-erc-upload--check)
  (if (memq type zr-erc-upload--file-types)
      (let ((files
             (delete-dups
              (cl-loop for uri in (split-string data "[\0\r\n]" t)
                       for line = (string-trim uri)
                       unless (or (member line '("copy" "cut" ""))
                                  (string-prefix-p "#" line))
                       collect
                       (let* ((url (url-generic-parse-url line))
                              (host (url-host url))
                              (file (and (equal (url-type url) "file")
                                         (member host '(nil "" "localhost"))
                                         (dnd-get-local-file-name
                                          (concat "file:" (url-filename url))))))
                         (unless (and file (file-name-absolute-p file))
                           (user-error "Clipboard item is not a local file: %s" line))
                         (zr-erc-upload--check-file file)
                         file)))))
        (unless files (user-error "No files in clipboard"))
        (mapc #'zr-erc-upload-file files))
    (let* ((extension (mailcap-mime-type-to-extension type))
           (file (make-temp-file "erc-upload-" nil
                                 (concat "." (symbol-name extension)))))
      (condition-case err
          (let ((coding-system-for-write 'no-conversion))
            (write-region data nil file nil 'silent))
        (error (delete-file file) (signal (car err) (cdr err))))
      (zr-erc-upload--start file nil t))))

(defun zr-erc-upload--install ()
  "Register clipboard handlers in the current ERC buffer."
  (when (and (derived-mode-p 'erc-mode) (not zr-erc-upload--yank-state))
    (setq zr-erc-upload--yank-state
          (mapcar (lambda (variable)
                    (list variable (local-variable-p variable) (symbol-value variable)))
                  '(yank-media--registered-handlers yank-media-preferred-types)))
    (setq-local yank-media--registered-handlers
                (copy-alist yank-media--registered-handlers))
    (setq-local yank-media-preferred-types
                (append yank-media-preferred-types zr-erc-upload--file-types))
    (yank-media-handler (cons "\\`image/" zr-erc-upload--file-types)
                        #'zr-erc-upload--yank)))

(defun zr-erc-upload--uninstall ()
  "Restore clipboard settings and cancel uploads in the current buffer."
  (zr-erc-upload-cancel)
  (pcase-dolist (`(,variable ,local ,value) zr-erc-upload--yank-state)
    (if local (set variable value) (kill-local-variable variable)))
  (setq zr-erc-upload--yank-state nil))

;;;###autoload (autoload 'erc-zr-upload-mode "zr-erc-upload" nil t)
(define-erc-module zr-upload nil
  "Upload clipboard images and files and share their links."
  ((add-hook 'erc-mode-hook #'zr-erc-upload--install)
   (erc-buffer-list #'zr-erc-upload--install))
  ((remove-hook 'erc-mode-hook #'zr-erc-upload--install)
   (erc-buffer-list #'zr-erc-upload--uninstall)))

(provide 'zr-erc-upload)
;;; zr-erc-upload.el ends here
