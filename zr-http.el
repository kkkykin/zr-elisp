;;; zr-http.el --- Shared HTTP requests through curl -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `zr-http-request' starts an asynchronous request and returns a handle.
;; `zr-http-request-sync' waits for the same implementation, preserving point
;; and allowing process output, timers and quit.  `zr-http-cancel' finishes a
;; pending request exactly once and releases its resources.
;;
;; Options override `zr-http-default-options': package options go in :options,
;; followed by explicit request keywords.  Headers merge case-insensitively;
;; a nil field removes an inherited header, and :headers nil clears them all.
;; Other options, including :curl-arguments, are replaced as a whole.
;; Bodies are byte strings.  Responses contain :status, :headers, :url and
;; :body, or :file when :output-file is supplied.  HTTP error statuses are
;; responses; transport failures use (nil ERROR) with a readable error string.
;; Files are staged privately and published only after a complete response.
;;
;; Each request performs one HTTP exchange.  Callers implement authentication
;; challenges and redirects according to their own credential scope and method
;; rules.  Loading this library changes no URL settings or environment variables.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)

(defgroup zr-http nil "Shared HTTP transport." :group 'comm)

(defcustom zr-http-default-options
  '(:curl-program "curl" :timeout 30 :proxy inherit)
  "Default HTTP options, overridden by package and request options.
Supported keys:
  :curl-program      Local curl executable.
  :curl-arguments    Extra transport arguments, as a list of strings.
  :timeout           Positive total timeout in seconds, or nil for no limit.
  :connect-timeout   Positive connection timeout in seconds, or nil.
  :proxy             inherit (curl's environment), nil (direct), or a proxy URL.
                     Explicit proxies bypass no_proxy; host:port means HTTP.
  :headers           Alist of header names and values; nil values remove fields.
  :method            HTTP method (default GET, or POST with a body/form).
  :body              Unibyte request body; nil means no body.
  :upload-file       Readable local file sent as the request body (default PUT).
  :form              Multipart fields: (NAME . STRING) or
                     (NAME . (:file FILE :filename NAME :type MEDIA-TYPE)).
  :auth              (:scheme basic/digest :user USER :password PASSWORD).
  :max-bytes         Maximum response body bytes, or nil for no limit.
  :output-file       Local destination, replaced after a complete response.

HTTP statuses, including 4xx/5xx, are returned to callers.  Redirects are
returned without following them.  Extra curl arguments must not configure
requests, retries, output, or additional transfers; use the structured keys.
Options are captured when a request starts, including buffer-local settings."
  :type 'sexp :group 'zr-http)

(cl-defstruct (zr-http-request (:constructor zr-http--make-request))
  process done response error callback timer buffers files output-file body-file
  bytes max-bytes url)

(defun zr-http-options (&rest layers)
  "Merge option LAYERS in order without modifying them.
Later values override earlier ones.  Headers merge ignoring case, with nil
values deleting inherited fields and :headers nil clearing the whole alist.
Validate the resulting headers and proxy before callers allocate resources."
  (let (result)
    (dolist (layer layers)
      (unless (and (proper-list-p layer) (zerop (% (length layer) 2)))
        (error "HTTP options must be a property list"))
      (cl-loop for (key value) on layer by #'cddr
               do (unless (keywordp key) (error "Invalid HTTP option: %S" key))
               do (setq result
                        (plist-put result key
                                   (if (and (eq key :headers) value)
                                       (let ((headers (copy-tree (plist-get result key))))
                                         (dolist (header value)
                                           (unless (consp header) (error "Invalid HTTP header"))
                                           (setq headers
                                                 (cl-remove (car header) headers
                                                            :key #'car :test #'string-equal-ignore-case))
                                           (setq headers (append headers (list (copy-tree header)))))
                                         headers)
                                     (if (functionp value) value (copy-tree value)))))))
    (when (plist-member result :headers)
      (zr-http--check-headers (plist-get result :headers)))
    (when (plist-member result :proxy)
      (zr-http--proxy (plist-get result :proxy)))
    result))

(defun zr-http--check-headers (headers)
  "Validate HEADERS and return fields with non-nil values."
  (unless (proper-list-p headers) (error "HTTP headers must be an alist"))
  (dolist (header headers)
    (unless (and (consp header) (stringp (car header))
                 (string-match-p "\\`[!#$%&'*+.^_`|~A-Za-z0-9-]+\\'" (car header))
                 (or (null (cdr header))
                     (and (stringp (cdr header))
                          (not (string-match-p "[\r\n\0]" (cdr header))))))
      (error "Invalid HTTP header")))
  (cl-remove-if-not #'cdr headers))

(defun zr-http--local-file (file &optional readable)
  "Validate local FILE; with READABLE require a readable regular file."
  (unless (and (stringp file) (not (file-remote-p file))
               (not (string-match-p "[\0\r\n]" file))
               (or (not readable)
                   (and (file-regular-p file) (file-readable-p file))))
    (error "HTTP requires a %slocal file" (if readable "readable " "")))
  (expand-file-name file))

(defun zr-http--proxy (proxy)
  "Validate PROXY and return curl routing arguments."
  (pcase proxy
    ('inherit nil)
    ('nil '("--proxy" ""))
    (_
     (unless (and (stringp proxy) (not (string-match-p "[[:space:][:cntrl:]]" proxy)))
       (error "Invalid HTTP proxy"))
     (let* ((address (if (string-search "://" proxy) proxy (concat "http://" proxy)))
            (parsed (url-generic-parse-url address)))
       (unless (and (member (url-type parsed) '("http" "https" "socks4" "socks4a" "socks5" "socks5h"))
                    (url-host parsed) (not (string-empty-p (url-host parsed)))
                    (not (url-user parsed)) (not (url-password parsed))
                    (not (url-target parsed))
                    (member (url-filename parsed) '("" "/"))
                    (url-portspec parsed) (<= 1 (url-port parsed) 65535))
         (error "Invalid HTTP proxy"))
       (list "--proxy" address "--noproxy" "")))))

(defun zr-http--extra-arguments (arguments)
  "Validate transport ARGUMENTS, reserving request and output controls."
  (unless (and (proper-list-p arguments) (cl-every #'stringp arguments))
    (error "HTTP curl arguments must be a list of strings"))
  (dolist (argument arguments)
    (when (or (string-match-p "[\0\r\n]" argument)
              (string-match-p
               (concat "\\`\\(?:--\\(?:config\\|next\\|url\\|output\\|output-dir\\|remote-name"
                       "\\|remote-header-name\\|dump-header\\|write-out\\|request\\|head"
                       "\\|data[^=]*\\|form[^=]*\\|upload-file\\|user\\|oauth2-bearer"
                       "\\|retry[^=]*\\|fail[^=]*\\|parallel[^=]*\\)\\(?:=\\|\\'\\)"
                       "\\|-[K:oODwXIduFTf]\\)")
               argument))
      (error "Reserved HTTP curl argument: %s" argument)))
  arguments)

(defun zr-http--quote (text)
  "Quote TEXT for curl's configuration and multipart grammars."
  (unless (and (stringp text) (not (string-match-p "[\0\r\n]" text)))
    (error "Invalid curl field"))
  (concat "\"" (replace-regexp-in-string "[\\\"]" "\\\\\\&" text t) "\""))

(defun zr-http--form-arguments (form)
  "Build curl arguments for structured multipart FORM."
  (unless (proper-list-p form) (error "HTTP form must be an alist"))
  (cl-loop
   for (name . value) in form
   append
   (progn
     (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9_.-]+\\'" name))
       (error "Invalid HTTP form field name"))
     (if (stringp value)
         (list "--form-string" (concat name "=" value))
       (let* ((file (zr-http--local-file (plist-get value :file) t))
              (filename (or (plist-get value :filename) (file-name-nondirectory file)))
              (type (plist-get value :type)))
         (when (and type (not (string-match-p "\\`[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+\\'" type)))
           (error "Invalid HTTP form media type"))
         ;; RFC 5987 preserves Unicode and delimiter characters in filenames.
         (list "--form"
               (concat name "=@" (zr-http--quote file)
                       ";headers="
                       (zr-http--quote
                        (format "Content-Disposition: form-data; name=\"%s\"; filename*=utf-8''%s"
                                name (url-hexify-string filename)))
                       (when type (concat ";type=" type)))))))))

(defun zr-http--write-bytes (bytes file)
  "Write BYTES into private FILE without coding conversion."
  (let ((coding-system-for-write 'no-conversion))
    (write-region bytes nil file nil 'silent)))

(defun zr-http--temp-file (request prefix &optional directory)
  "Create a private file owned by REQUEST under optional DIRECTORY."
  (let ((file (make-temp-file (if directory (expand-file-name prefix directory) prefix))))
    (push file (zr-http-request-files request))
    file))

(defun zr-http--parse-headers (text)
  "Parse the final HTTP header block in TEXT, retaining repeated fields."
  (let (status headers)
    (dolist (line (split-string text "\r?\n"))
      (cond
       ((string-match "\\`HTTP/[0-9.]+ +\\([0-9][0-9][0-9]\\)\\(?: \\|\\'\\)" line)
        (setq status (string-to-number (match-string 1 line)) headers nil))
       ((string-match "\\`\\([^: \t]+\\):[ \t]*\\(.*\\)" line)
        (push (cons (downcase (match-string 1 line))
                    (string-trim (match-string 2 line))) headers))))
    (unless (and status (>= status 200)) (error "Incomplete HTTP response"))
    (list :status status :headers (nreverse headers))))

(defun zr-http--cleanup (request)
  "Release all resources owned by REQUEST."
  (when (timerp (zr-http-request-timer request))
    (cancel-timer (zr-http-request-timer request)))
  (when-let* ((process (zr-http-request-process request)) ((process-live-p process)))
    (delete-process process))
  (dolist (buffer (zr-http-request-buffers request))
    (when (buffer-live-p buffer)
      (when-let* ((process (get-buffer-process buffer)) ((process-live-p process)))
        (delete-process process))
      (kill-buffer buffer)))
  (dolist (file (zr-http-request-files request))
    (when (file-exists-p file) (delete-file file))))

(defun zr-http--finish (request response error)
  "Finish REQUEST with RESPONSE or ERROR, invoking its callback once."
  (unless (zr-http-request-done request)
    (setf (zr-http-request-done request) t
          (zr-http-request-response request) response
          (zr-http-request-error request) error)
    (zr-http--cleanup request)
    (when-let* ((callback (zr-http-request-callback request)))
      (funcall callback response error))))

(defun zr-http-cancel (request)
  "Cancel pending REQUEST, notifying its callback once with an error."
  (zr-http--finish request nil "HTTP request cancelled"))

(defun zr-http--start (request options)
  "Start REQUEST using fully merged OPTIONS."
  (let* ((default-directory temporary-file-directory)
         (url (zr-http-request-url request))
         (parsed (and (stringp url) (url-generic-parse-url url)))
         (body (plist-get options :body))
         (upload (plist-get options :upload-file))
         (form (plist-get options :form))
         (method (or (plist-get options :method) (cond (upload "PUT") ((or body form) "POST") (t "GET"))))
         (timeout (plist-get options :timeout))
         (connect-timeout (plist-get options :connect-timeout))
         (headers (zr-http--check-headers (plist-get options :headers)))
         (proxy-args (zr-http--proxy (plist-get options :proxy)))
         (extra-args (zr-http--extra-arguments (plist-get options :curl-arguments)))
         (form-args (zr-http--form-arguments form))
         (auth (plist-get options :auth)))
    (unless (and parsed (member (url-type parsed) '("http" "https"))
                 (url-host parsed) (not (string-empty-p (url-host parsed)))
                 (not (url-user parsed)) (not (url-password parsed))
                 (not (string-match-p "[[:space:][:cntrl:]]" url)))
      (error "HTTP requires an HTTP(S) URL without embedded credentials"))
    (unless (and (stringp method) (string-match-p "\\`[A-Z]+\\'" method))
      (error "Invalid HTTP method"))
    (when (and body (or (not (stringp body)) (multibyte-string-p body)))
      (error "HTTP body must be a unibyte string"))
    (when (> (+ (if body 1 0) (if upload 1 0) (if form 1 0)) 1)
      (error "HTTP body, upload-file and form are mutually exclusive"))
    (dolist (seconds (list timeout connect-timeout))
      (unless (or (null seconds) (and (numberp seconds) (> seconds 0)))
        (error "HTTP timeouts must be positive or nil")))
    (unless (or (null (zr-http-request-max-bytes request))
                (natnump (zr-http-request-max-bytes request)))
      (error "HTTP max-bytes must be a natural number or nil"))
    (let* ((head-file (zr-http--temp-file request "zr-http-headers-"))
           (header-file (and headers (zr-http--temp-file request "zr-http-request-")))
           (data-file (and body (zr-http--temp-file request "zr-http-body-")))
           (config-file (and auth (zr-http--temp-file request "zr-http-auth-")))
           (output-file (when (plist-get options :output-file)
                          (zr-http--local-file (plist-get options :output-file))))
           (body-file (when output-file
                        (zr-http--temp-file request ".zr-http-" (file-name-directory output-file))))
           (buffer (generate-new-buffer " *zr-http-body*" t))
           (errors (generate-new-buffer " *zr-http-errors*" t)))
      (setf (zr-http-request-buffers request) (list buffer errors)
            (zr-http-request-output-file request) output-file
            (zr-http-request-body-file request) body-file)
      (with-current-buffer buffer (set-buffer-multibyte nil))
      (when headers
        (zr-http--write-bytes
         (encode-coding-string (mapconcat (lambda (h) (concat (car h) ": " (cdr h))) headers "\n") 'utf-8 t)
         header-file))
      (when body (zr-http--write-bytes body data-file))
      (when auth
        (unless (memq (plist-get auth :scheme) '(basic digest)) (error "Unsupported HTTP authentication"))
        (zr-http--write-bytes
         (encode-coding-string
          (concat "user = " (zr-http--quote (concat (plist-get auth :user) ":" (plist-get auth :password))) "\n")
          'utf-8 t) config-file))
      (setf
       (zr-http-request-process request)
       (make-process
        :name "zr-http-curl" :buffer buffer :stderr errors :noquery t
        :connection-type 'pipe :coding 'binary
        :command
        (append (list (plist-get options :curl-program) "--disable" "--silent" "--show-error" "--globoff")
                extra-args proxy-args
                (when timeout (list "--max-time" (number-to-string timeout)))
                (when connect-timeout (list "--connect-timeout" (number-to-string connect-timeout)))
                (when config-file (list "--config" config-file (if (eq (plist-get auth :scheme) 'digest) "--digest" "--basic")))
                (when header-file (list "--header" (concat "@" header-file)))
                (when data-file (list "--data-binary" (concat "@" data-file)))
                (when upload (list "--upload-file" (zr-http--local-file upload t)))
                form-args
                (when (equal method "HEAD") '("--head"))
                ;; Business code inspects redirects before reusing credentials.
                (list "--no-location" "--proto" "=http,https"
                      "--request" method "--dump-header" head-file "--url" url))
        :filter
        (lambda (_process chunk)
          (unless (or (zr-http-request-done request) (equal method "HEAD"))
            (condition-case err
                (progn
                  (cl-incf (zr-http-request-bytes request) (string-bytes chunk))
                  (when (and (zr-http-request-max-bytes request)
                             (> (zr-http-request-bytes request) (zr-http-request-max-bytes request)))
                    (error "HTTP response exceeds max-bytes"))
                  (if body-file
                      (let ((coding-system-for-write 'no-conversion))
                        (write-region chunk nil body-file t 'silent))
                    (with-current-buffer buffer (goto-char (point-max)) (insert chunk))))
              (error (zr-http--finish request nil (error-message-string err))))))
        :sentinel
        (lambda (process _event)
          (when (and (not (zr-http-request-done request)) (memq (process-status process) '(exit signal)))
            (let (response failure)
              (condition-case err
                  (progn
                    (unless (and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
                      (error "HTTP curl request failed: %s"
                             (with-current-buffer errors (string-trim (buffer-string)))))
                    (setq response
                          (with-temp-buffer
                            (insert-file-contents head-file)
                            (zr-http--parse-headers (buffer-string))))
                    (setq response (plist-put response :url url))
                    (if output-file
                        (progn
                          (rename-file body-file output-file t)
                          (setq response (plist-put response :file output-file)))
                      (setq response (plist-put response :body (with-current-buffer buffer (buffer-string))))))
                (error (setq failure (error-message-string err))))
              (zr-http--finish request (unless failure response) failure))))))
      (when-let* ((stderr-process (get-buffer-process errors)))
        (set-process-sentinel stderr-process #'ignore))
      (when timeout
        (setf (zr-http-request-timer request)
              (run-at-time timeout nil (lambda () (zr-http--finish request nil "HTTP request timed out"))))))))

(defun zr-http-request (url &rest arguments)
  "Request URL asynchronously, returning a cancellable request handle.
ARGUMENTS are request option keywords, with :options for package defaults
and :callback for a function called exactly once with (RESPONSE ERROR).
Options are captured before starting.  Validation/startup failures are
signaled synchronously; an established request reports transport errors
through its callback.  See `zr-http-default-options' for supported keys."
  (let* ((options (zr-http-options '(:curl-program "curl" :timeout 30 :proxy inherit)
                                  zr-http-default-options (plist-get arguments :options) arguments))
         (request (zr-http--make-request :url url :bytes 0 :callback (plist-get options :callback)
                                         :max-bytes (plist-get options :max-bytes))))
    (cl-loop for (key _value) on options by #'cddr
             unless (memq key '(:options :callback :curl-program :curl-arguments :timeout :connect-timeout
                               :proxy :headers :method :body :upload-file :form :auth :max-bytes :output-file))
             do (error "Unknown HTTP option: %S" key))
    (condition-case err
        (zr-http--start request options)
      ((error quit)
       (setf (zr-http-request-done request) t)
       (zr-http--cleanup request)
       (signal (car err) (cdr err))))
    request))

(defun zr-http-request-sync (url &rest arguments)
  "Request URL with ARGUMENTS and wait for its response.
Transport failures are signaled as `zr-http-error'; HTTP statuses are
returned unchanged.  Quit cancels the request and removes staging files."
  (let ((request (apply #'zr-http-request url (append arguments '(:callback nil)))))
    (save-excursion
      (unwind-protect
          (progn
            (while (not (zr-http-request-done request)) (accept-process-output nil 0.05))
            (when-let* ((error (zr-http-request-error request))) (signal 'zr-http-error (list error)))
            (zr-http-request-response request))
        (zr-http-cancel request)))))

(define-error 'zr-http-error "HTTP transport failed")

(provide 'zr-http)
;;; zr-http.el ends here
