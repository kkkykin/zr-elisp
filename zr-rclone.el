;;; zr-rclone.el --- Rclone RC control and file-list consumers -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (transient "0.4"))
;; Keywords: files, comm

;;; Commentary:

;; M-x zr-rclone opens the RC panel in the current buffer.  Connections
;; retain their own current/target paths and per-operation options.
;; HTTP and rclone rc send the same JSON requests; transfers are RC jobs.
;; core/command is a separate entry for manually entered rclone arguments.
;;
;; File listings feed external consumers such as mpv.  This package does
;; not provide a file browser.  Open the current path with zr-tramp-webdav
;; when ordinary Emacs file access or file management is needed.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'crm)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'url)
(require 'url-http)
(defvar url-http-response-status)

(defgroup zr-rclone nil
  "Rclone remote control."
  :group 'files)

(defcustom zr-rclone-program "rclone"
  "Rclone executable for the CLI transport and owned local daemons."
  :type 'file)

(defcustom zr-rclone-transport 'http
  "Initial transport for new connections."
  :type '(choice (const http) (const cli)))

(defcustom zr-rclone-url "http://127.0.0.1:5572/"
  "Initial RC endpoint, including any reverse proxy path."
  :type 'string)

(defcustom zr-rclone-timeout 30
  "Timeout in seconds for an individual RC request."
  :type 'number)

(defcustom zr-rclone-poll-interval 2
  "Seconds between updates of running jobs."
  :type 'number)

(defcustom zr-rclone-rcd-arguments nil
  "Additional arguments for an owned local rcd.
For example, (\"--rc-serve\") also enables HTTP access to remote objects."
  :type '(repeat string))

(defcustom zr-rclone-config-file nil
  "Optional rclone config file for new connections.
This is a path on the rcd machine.  It is also passed explicitly to
core/command, whose subprocess does not inherit the daemon's CLI flags."
  :type '(choice (const nil) file))

(defcustom zr-rclone-mpv-program "mpv"
  "Executable used to play files returned by RC listing."
  :type 'file)

(defcustom zr-rclone-mpv-arguments nil
  "Additional mpv arguments."
  :type '(repeat string))

(defvar zr-rclone-url-history nil)
(defvar zr-rclone-path-history nil)
(defvar zr-rclone-command-history nil)
(defvar zr-rclone-json-history nil)
(defvar savehist-additional-variables)

(with-eval-after-load 'savehist
  (dolist (variable '(zr-rclone-url-history zr-rclone-path-history
                      zr-rclone-command-history zr-rclone-json-history))
    (add-to-list 'savehist-additional-variables variable)))

(defcustom zr-rclone-file-list-function #'zr-rclone-play-files
  "Function called by zr-rclone-send-file-list with FILES and CONNECTION.
FILES is an ordered list of full rclone path strings, with directories
excluded.  The default consumer converts them to URLs and starts mpv."
  :type 'function)

(cl-defstruct (zr-rclone-connection (:constructor zr-rclone--make-connection))
  url (transport zr-rclone-transport) local-p user password
  (config-file zr-rclone-config-file)
  connected methods version instance process jobs job-buffer timer mappings
  (status "Disconnected") current-path target-path dry-run
  call-options bisync-options mount-options webdav-options
  list-recursive media-rc-serve)

(defvar zr-rclone--connections nil)
(defvar zr-rclone--serial 0)
(defvar zr-rclone--connection nil
  "Selected RC connection, independent of the current buffer.")
(defvar-local zr-rclone--jobs-connection nil
  "Connection owning this jobs buffer.")

;;; JSON and transports

(defun zr-rclone--json (value)
  "Encode VALUE as an RC JSON object."
  (json-serialize (or value (make-hash-table))
                  :null-object nil :false-object :false))

(defun zr-rclone--parse-json (text)
  "Decode RC JSON TEXT, preserving arrays and distinguishing false from true."
  (json-parse-string text :object-type 'alist :array-type 'array
                     :null-object nil :false-object :false))

(defun zr-rclone--read-json (prompt initial)
  "Read an object with PROMPT and INITIAL value."
  (let ((text (read-string prompt (zr-rclone--json initial)
                           'zr-rclone-json-history)))
    (unless (string-prefix-p "{" (string-trim-left text))
      (user-error "Expected a JSON object"))
    (zr-rclone--parse-json text)))

(defun zr-rclone--normalize-url (url)
  "Validate an HTTP endpoint URL and add a trailing slash."
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (member (url-type parsed) '("http" "https"))
                 (not (string-empty-p (or (url-host parsed) "")))
                 (not (url-user parsed)) (not (url-password parsed))
                 (not (url-target parsed))
                 (not (string-match-p "[?\n\r]" (url-filename parsed))))
      (user-error "Use an HTTP(S) URL without credentials, query or fragment"))
    (concat (string-remove-suffix "/" url) "/")))

(defun zr-rclone--credentials (connection)
  "Return (USER . PASSWORD) for CONNECTION, without prompting."
  (let* ((parsed (url-generic-parse-url
                  (zr-rclone-connection-url connection)))
         (user (zr-rclone-connection-user connection))
         (password (zr-rclone-connection-password connection)))
    (if (and user password)
        (cons user password)
      (when-let* ((entry (car (auth-source-search
                              :host (url-host parsed)
                              :port (number-to-string (url-port parsed))
                              :user (or user t) :require '(:user :secret)
                              :max 1)))
                  (secret (plist-get entry :secret)))
        (cons (plist-get entry :user)
              (if (functionp secret) (funcall secret) secret))))))

(defun zr-rclone--basic-header (credentials)
  "Build a Basic authorization header from CREDENTIALS."
  (when credentials
    (concat "Basic "
            (base64-encode-string
             (encode-coding-string
              (concat (car credentials) ":" (cdr credentials)) 'utf-8) t))))

(defun zr-rclone--new-password ()
  "Generate a password from the OS random source, or read one interactively."
  (if (file-readable-p "/dev/urandom")
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally "/dev/urandom" nil 0 32)
        (secure-hash 'sha256 (current-buffer)))
    (let ((password (read-passwd "Password for the new rclone service: " t)))
      (when (string-empty-p password) (user-error "A password is required"))
      password)))

(defun zr-rclone--http-request (connection method params callback)
  "Send METHOD and PARAMS over HTTP; call CALLBACK with (RESULT ERROR).
Return a cancellation function.  ERROR is nil or a readable string."
  (let (buffer timer done)
    (cl-labels
        ((finish (result error)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (when (buffer-live-p buffer)
               (when-let* ((process (get-buffer-process buffer)))
                 (delete-process process))
               (kill-buffer buffer))
             (funcall callback result error))))
      (condition-case err
          (let ((default-directory temporary-file-directory)
                (url-request-method "POST")
                (url-request-extra-headers
                 (list '("Content-Type" . "application/json")
                       (cons "Authorization"
                             (or (zr-rclone--basic-header
                                  (zr-rclone--credentials connection)) ""))))
                (url-request-data
                 (encode-coding-string (zr-rclone--json params) 'utf-8))
                (url-request-noninteractive t)
                (url-show-status nil)
                (url-max-redirections 0)
                (url-http-attempt-keepalives nil))
            (setq buffer
                  (url-retrieve
                   (concat (zr-rclone-connection-url connection) method)
                   (lambda (status)
                     (let ((response-buffer (current-buffer)))
                       (unwind-protect
                           (condition-case error
                               (progn
                                 (goto-char (point-min))
                                 (unless (re-search-forward "\r?\n\r?\n" nil t)
                                   (error "Incomplete HTTP response: %s" status))
                                 (let* ((code (or url-http-response-status 0))
                                        (body (decode-coding-string
                                               (buffer-substring-no-properties
                                                (point) (point-max)) 'utf-8))
                                        (result
                                         (condition-case nil
                                             (zr-rclone--parse-json body)
                                           (error
                                            (error "HTTP %s: invalid RC JSON" code)))))
                                   (if (<= 200 code 299)
                                       (finish result nil)
                                     (finish nil
                                             (format "HTTP %s: %s" code
                                                     (or (alist-get 'error result)
                                                         "RC request failed"))))))
                             (error (finish nil (error-message-string error))))
                         (when (buffer-live-p response-buffer)
                           (kill-buffer response-buffer)))))
                   nil t t))
            (unless (or done (buffer-live-p buffer))
              (finish nil "Cannot create HTTP request"))
            (unless done
              (setq timer
                    (run-at-time zr-rclone-timeout nil
                                 (lambda () (finish nil "RC request timed out"))))))
        (error (finish nil (error-message-string err))))
      (lambda () (finish nil "RC request cancelled")))))

(defun zr-rclone--cli-request (connection method params callback)
  "Send METHOD and PARAMS through rclone rc, then call CALLBACK."
  (let ((buffer (generate-new-buffer " *zr-rclone-response*"))
        (stderr (generate-new-buffer " *zr-rclone-stderr*"))
        process timer done)
    (cl-labels
        ((finish (result error)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (when (process-live-p process) (delete-process process))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (when (buffer-live-p stderr) (kill-buffer stderr))
             (funcall callback result error))))
      (condition-case err
          (let ((default-directory temporary-file-directory)
                (process-environment (copy-sequence process-environment))
                (credentials (zr-rclone--credentials connection)))
            ;; Credentials never appear in process arguments or command logs.
            (setenv "RCLONE_RC_USER" (car credentials))
            (setenv "RCLONE_RC_PASS" (cdr credentials))
            (setenv "RCLONE_USER" (car credentials))
            (setenv "RCLONE_PASS" (cdr credentials))
            (setq process
                  (make-process
                   :name "zr-rclone-rc" :buffer buffer :stderr stderr
                   :command (list zr-rclone-program "rc"
                                  "--url" (zr-rclone-connection-url connection)
                                  "--json" (zr-rclone--json params) method)
                   :connection-type 'pipe :coding 'utf-8-unix :noquery t
                   :sentinel
                   (lambda (proc _event)
                     (when (and (not done)
                                (memq (process-status proc) '(exit signal)))
                       (condition-case error
                           (let* ((text (with-current-buffer buffer (buffer-string)))
                                  (result (zr-rclone--parse-json text)))
                             (if (zerop (process-exit-status proc))
                                 (finish result nil)
                               (finish nil
                                       (format "%s" (or (alist-get 'error result)
                                                       "rclone rc failed")))))
                         (error
                          (finish nil
                                  (let ((message (with-current-buffer stderr
                                                   (string-trim (buffer-string)))))
                                    (if (string-empty-p message)
                                        (error-message-string error)
                                      message)))))))))
            (setq timer
                  (run-at-time zr-rclone-timeout nil
                               (lambda () (finish nil "RC request timed out")))))
        (error (finish nil (error-message-string err))))
      (lambda () (finish nil "RC request cancelled")))))

(defun zr-rclone--request (connection method params callback)
  "Dispatch an RC request for CONNECTION, METHOD, PARAMS and CALLBACK."
  (unless (string-match-p "\\`[[:alnum:]_-]+/[[:alnum:]_/-]+\\'" method)
    (user-error "Invalid RC method"))
  (funcall (pcase (zr-rclone-connection-transport connection)
             ('http #'zr-rclone--http-request)
             ('cli #'zr-rclone--cli-request)
             (_ (user-error "Unknown RC transport")))
           connection method params callback))

(defun zr-rclone--call (connection method &optional params)
  "Perform a bounded RC request, returning its result.
Used for short interactive queries.  Transfers use background RC jobs."
  (let (done result failure cancel)
    (unwind-protect
        (progn
          (setq cancel
                (zr-rclone--request
                 connection method params
                 (lambda (value error)
                   (setq result value failure error done t))))
          (while (not done) (accept-process-output nil 0.05))
          (when failure (user-error "%s" failure))
          result)
      (when (and cancel (not done)) (funcall cancel)))))

;;; Rclone paths (no Emacs filesystem expansion)

(defun zr-rclone--split-path (path)
  "Split absolute rclone PATH into (ROOT . RELATIVE), or return nil.
Preserve remote: versus remote:/ and support Windows drives, UNC
shares, and quoted connection-string parameters."
  (cond
   ((string-prefix-p "\\\\" path)
    (zr-rclone--split-path (replace-regexp-in-string "\\\\" "/" path t t)))
   ((string-match "\\`\\([[:alpha:]]:\\)[/\\\\]" path)
    (cons (concat (match-string 1 path) "/")
          (replace-regexp-in-string "\\\\" "/" (substring path 3) t t)))
   ((string-match "\\`//[^/]+/[^/]+\\(?:/\\|\\'\\)" path)
    (let ((end (match-end 0)))
      (cons (concat (string-remove-suffix "/" (substring path 0 end)) "/")
            (substring path end))))
   ((string-prefix-p "/" path) (cons "/" (substring path 1)))
   (t
    (let ((index (if (string-prefix-p ":" path) 1 0)) quote end stop)
      (while (and (< index (length path)) (not end) (not stop))
        (let ((char (aref path index)))
          (cond
           (quote (when (= char quote) (setq quote nil)))
           ((memq char '(?\' ?\")) (setq quote char))
           ((= char ?:) (setq end (1+ index)))
           ((= char ?/) (setq stop t))))
        (setq index (1+ index)))
      (when end
        (when (and (< end (length path)) (= (aref path end) ?/))
          (setq end (1+ end)))
        (cons (substring path 0 end) (substring path end)))))))

(defun zr-rclone--join (base path)
  "Join rclone BASE and relative PATH without treating either as a file."
  (if (string-empty-p path) base
    (concat base (unless (or (string-suffix-p "/" base)
                            (string-suffix-p ":" base)) "/")
            path)))

(defun zr-rclone--resolve-path (path &optional base)
  "Resolve user-entered PATH relative to BASE using rclone path syntax."
  (when (or (string-empty-p path) (string-match-p "\0" path))
    (user-error "An rclone path is required"))
  (let* ((parts (or (zr-rclone--split-path path)
                    (and base (zr-rclone--split-path
                               (zr-rclone--join base path)))))
         stack)
    (unless parts
      (user-error "Use remote:path or an absolute path on the rcd machine"))
    (dolist (part (split-string (cdr parts) "/" t))
      (cond ((equal part "."))
            ((equal part "..") (pop stack))
            (t (push part stack))))
    (zr-rclone--join (car parts) (string-join (nreverse stack) "/"))))

(defun zr-rclone--parent (path)
  "Return the parent of absolute rclone PATH, or nil at its root."
  (let* ((parts (zr-rclone--split-path path))
         (relative (and parts (string-remove-suffix "/" (cdr parts))))
         (slash (and relative (string-match "/[^/]*\\'" relative))))
    (when (and relative (not (string-empty-p relative)))
      (zr-rclone--join (car parts) (if slash (substring relative 0 slash) "")))))

(defun zr-rclone--basename (path)
  "Return the last component of rclone PATH."
  (car (last (split-string (cdr (zr-rclone--split-path path)) "/" t))))

(defun zr-rclone--relative-to (path root)
  "Return PATH relative to ROOT, or nil if it is outside ROOT."
  (let ((prefix (if (or (string-suffix-p "/" root)
                        (string-suffix-p ":" root)) root (concat root "/"))))
    (cond ((equal path root) "")
          ((string-prefix-p prefix path) (substring path (length prefix))))))

;;; Session paths and completion

(defun zr-rclone--context ()
  "Return the selected RC connection, creating the default session if needed."
  (or zr-rclone--connection
      (setq zr-rclone--connection (zr-rclone--find-connection zr-rclone-url))))

(defun zr-rclone--connected (&optional connection)
  "Return CONNECTION or the selected session, requiring it to be connected."
  (let ((connection (or connection (zr-rclone--context))))
    (unless (zr-rclone-connection-connected connection)
      (user-error "Connect to rcd first"))
    connection))

(defun zr-rclone--require-method (connection method)
  "Check that CONNECTION advertises METHOD, when its methods are known."
  (when (and (zr-rclone-connection-methods connection)
             (not (assoc method (zr-rclone-connection-methods connection))))
    (user-error "This rclone does not support %s" method)))

(defun zr-rclone--directory (&optional connection)
  "Return CONNECTION's current directory, requiring a connected session."
  (or (zr-rclone-connection-current-path (zr-rclone--connected connection))
      (user-error "Set a current path first")))

(defun zr-rclone--status (connection text)
  "Record TEXT as CONNECTION's status."
  (setf (zr-rclone-connection-status connection) text))

(defun zr-rclone--list-entries (connection path)
  "List PATH for completion, or return CONNECTION's roots when PATH is nil."
  (if path
      (mapcar (lambda (entry)
                (list :name (alist-get 'Name entry)
                      :directory (eq (alist-get 'IsDir entry) t)))
              (alist-get 'list (zr-rclone--call
                               connection "operations/list"
                               (list (cons 'fs path) '(remote . "")
                                     '(opt . ((noMimeType . t)))))))
    (let* ((remotes (alist-get 'remotes
                               (zr-rclone--call connection "config/listremotes")))
           (disks (if (assoc "core/disks" (zr-rclone-connection-methods connection))
                      (alist-get 'disks (zr-rclone--call connection "core/disks"))
                    (if (equal (alist-get 'os (zr-rclone-connection-version connection))
                               "windows") '("C:/") '("/")))))
      (mapcar (lambda (path) (list :path path :name path :directory t))
              (delete-dups (append (mapcar (lambda (name) (concat name ":")) remotes)
                                   disks nil))))))

(defun zr-rclone--path-completions (connection input base directories-only)
  "Complete INPUT relative to BASE on CONNECTION.
When DIRECTORIES-ONLY is non-nil, omit files.  No TRAMP access is used."
  (condition-case nil
      (let* ((absolute (zr-rclone--resolve-path (if (string-empty-p input) "." input)
                                               base))
             (trailing (or (string-empty-p input) (string-suffix-p "/" input)
                           (string-suffix-p ":" input)))
             (directory (if trailing absolute (zr-rclone--parent absolute)))
             (leaf (and (not trailing) (zr-rclone--basename absolute)))
             (typed-prefix (if trailing input
                             (substring input 0 (max 0 (- (length input)
                                                          (length leaf)))))))
        (if directory
            (mapcar
             (lambda (entry)
               (concat typed-prefix (plist-get entry :name)
                       (when (plist-get entry :directory) "/")))
             (cl-remove-if-not
              (lambda (entry) (or (not directories-only)
                                  (plist-get entry :directory)))
              (zr-rclone--list-entries connection directory)))
          (mapcar (lambda (entry) (plist-get entry :path))
                  (zr-rclone--list-entries connection nil))))
    (error
     (condition-case nil
         (mapcar (lambda (entry) (plist-get entry :path))
                 (zr-rclone--list-entries connection nil))
       (error nil)))))

(defun zr-rclone--read-path (prompt initial &optional directories-only)
  "Read an rclone path with RC completion using PROMPT and INITIAL."
  (let* ((connection (zr-rclone--connected))
         (base (zr-rclone-connection-current-path connection))
         (cache (make-hash-table :test #'equal))
         (table
          (completion-table-dynamic
           (lambda (input)
             (or (gethash input cache)
                 (puthash input
                          (zr-rclone--path-completions
                           connection input base directories-only) cache)))))
         (input (completing-read prompt table nil nil initial
                                 'zr-rclone-path-history))
         (path (zr-rclone--resolve-path input base)))
    (if (and (not directories-only) (string-suffix-p "/" input)
             (not (string-suffix-p "/" path)))
        (concat path "/") path)))

(defun zr-rclone-cd (path)
  "Set the current rclone directory to PATH without listing it."
  (interactive
   (list (zr-rclone--read-path
          "Current path: " (zr-rclone-connection-current-path (zr-rclone--context)) t)))
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-current-path connection)
          (zr-rclone--resolve-path path (zr-rclone-connection-current-path connection)))))

(defun zr-rclone-set-target (path)
  "Set the target rclone directory to PATH."
  (interactive
   (list (zr-rclone--read-path
          "Target path: " (or (zr-rclone-connection-target-path (zr-rclone--context))
                             (zr-rclone-connection-current-path (zr-rclone--context))) t)))
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-target-path connection)
          (zr-rclone--resolve-path path (zr-rclone-connection-current-path connection)))))

(defun zr-rclone-swap-paths ()
  "Exchange the selected connection's current and target paths."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (unless (and (zr-rclone-connection-current-path connection)
                 (zr-rclone-connection-target-path connection))
      (user-error "Set current and target paths first"))
    (cl-rotatef (zr-rclone-connection-current-path connection)
                (zr-rclone-connection-target-path connection))))

;;; Connection lifecycle

(defun zr-rclone--find-connection (url)
  "Find or create a connection for URL."
  (setq url (zr-rclone--normalize-url url))
  (or (cl-find url zr-rclone--connections :test #'equal
               :key #'zr-rclone-connection-url)
      (let ((connection (zr-rclone--make-connection :url url)))
        (push connection zr-rclone--connections)
        connection)))

(defun zr-rclone--server-instance (connection)
  "Read CONNECTION's process identity, using a PID on older servers."
  (or (alist-get 'executeId (zr-rclone--call connection "job/list"))
      (alist-get 'pid (zr-rclone--call connection "core/pid"))))

(defun zr-rclone--probe (connection)
  "Connect to CONNECTION and discover capabilities and process identity."
  (condition-case err
      (let* ((version (zr-rclone--call connection "core/version"))
             (methods (alist-get 'commands (zr-rclone--call connection "rc/list")))
             (instance (zr-rclone--server-instance connection)))
        (when (and (zr-rclone-connection-instance connection)
                   (not (equal instance (zr-rclone-connection-instance connection))))
          (dolist (job (zr-rclone-connection-jobs connection))
            (unless (plist-get job :finished)
              (setf (plist-get job :finished) t
                    (plist-get job :state) "stale"
                    (plist-get job :error) "rclone restarted")))
          (mapc #'zr-rclone--forget-webdav (zr-rclone-connection-mappings connection))
          (setf (zr-rclone-connection-mappings connection) nil))
        (setf (zr-rclone-connection-version connection) version
              (zr-rclone-connection-methods connection)
              (mapcar (lambda (method) (cons (alist-get 'Path method) method)) methods)
              (zr-rclone-connection-instance connection) instance
              (zr-rclone-connection-connected connection) t)
        (zr-rclone--status connection "Connected")
        (zr-rclone--ensure-polling connection)
        connection)
    (error
     (setf (zr-rclone-connection-connected connection) nil)
     (zr-rclone--status connection (error-message-string err))
     (signal (car err) (cdr err)))))

(defun zr-rclone-connect (url &optional local-p)
  "Select and connect to URL.
With prefix LOCAL-P, paths share Emacs's filesystem."
  (interactive (list (read-string "RC URL: " zr-rclone-url 'zr-rclone-url-history)
                     current-prefix-arg))
  (let ((connection (zr-rclone--find-connection url)))
    (setq zr-rclone--connection connection)
    (setf (zr-rclone-connection-local-p connection) (and local-p t))
    (zr-rclone--probe connection)))

(defun zr-rclone-disconnect ()
  "Stop polling this connection, leaving all server jobs and services running."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-connected connection) nil)
    (when (zr-rclone-connection-timer connection)
      (cancel-timer (zr-rclone-connection-timer connection))
      (setf (zr-rclone-connection-timer connection) nil))
    (zr-rclone--status connection "Disconnected; server tasks continue")))

(defun zr-rclone-reconnect ()
  "Reconnect the selected RC session."
  (interactive)
  (zr-rclone--probe (zr-rclone--context)))

(defun zr-rclone-select-connection ()
  "Select another connection, retaining each session's paths and options."
  (interactive)
  (setq zr-rclone--connection
        (zr-rclone--find-connection
         (completing-read "Connection: "
                          (mapcar #'zr-rclone-connection-url zr-rclone--connections)
                          nil t))))

(defun zr-rclone-set-credentials ()
  "Set session-only RC credentials.  An empty user restores auth-source lookup."
  (interactive)
  (let* ((connection (zr-rclone--context))
         (user (read-string "RC user (empty uses auth-source): "
                            (zr-rclone-connection-user connection))))
    (setf (zr-rclone-connection-user connection)
          (unless (string-empty-p user) user)
          (zr-rclone-connection-password connection)
          (unless (string-empty-p user) (read-passwd "RC password: ")))))

(defun zr-rclone-toggle-transport ()
  "Switch this connection between HTTP and rclone rc."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-transport connection)
          (if (eq (zr-rclone-connection-transport connection) 'http) 'cli 'http))
    (force-mode-line-update)))

(defun zr-rclone-toggle-local ()
  "Toggle whether this rcd shares Emacs's local filesystem."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-local-p connection)
          (not (zr-rclone-connection-local-p connection)))
    (force-mode-line-update)))

(defun zr-rclone-set-config-file ()
  "Set the server config path for owned daemons and temporary CLI commands."
  (interactive)
  (let* ((connection (zr-rclone--context))
         (path (read-string "Config on rcd machine (empty uses rclone default): "
                            (zr-rclone-connection-config-file connection))))
    (setf (zr-rclone-connection-config-file connection)
          (unless (string-empty-p path) path))))

(defun zr-rclone-start-daemon (address)
  "Start an owned local rcd listening at ADDRESS, with generated credentials."
  (interactive (list (read-string "Local rcd listen address: " "127.0.0.1:5572")))
  (when (string-suffix-p ":0" address)
    (user-error "Choose a fixed RC port; WebDAV servers may use port zero"))
  (let* ((url (concat "http://"
                      (if (string-prefix-p ":" address)
                          (concat "127.0.0.1" address) address) "/"))
         (connection (zr-rclone--find-connection url))
         (buffer (get-buffer-create (format "*rclone rcd %s*" address)))
         (default-directory temporary-file-directory)
         (process-environment (copy-sequence process-environment))
         (user "zr-rclone")
         (password (zr-rclone--new-password)))
    (when (process-live-p (zr-rclone-connection-process connection))
      (user-error "This rcd is already running"))
    (setenv "RCLONE_RC_USER" user)
    (setenv "RCLONE_RC_PASS" password)
    (setf (zr-rclone-connection-user connection) user
          (zr-rclone-connection-password connection) password
          (zr-rclone-connection-local-p connection) t)
    (with-current-buffer buffer (let ((inhibit-read-only t)) (erase-buffer)))
    (setf (zr-rclone-connection-process connection)
          (make-process
           :name "zr-rclone-rcd" :buffer buffer
           :command (append (list zr-rclone-program "rcd" "--rc-addr" address)
                            (when (zr-rclone-connection-config-file connection)
                              (list "--config" (zr-rclone-connection-config-file connection)))
                            zr-rclone-rcd-arguments)
           :connection-type 'pipe :coding 'utf-8-unix :noquery t
           :sentinel
           (lambda (process event)
             (when (memq (process-status process) '(exit signal))
               (setf (zr-rclone-connection-connected connection) nil)
               (when (zr-rclone-connection-timer connection)
                 (cancel-timer (zr-rclone-connection-timer connection))
                 (setf (zr-rclone-connection-timer connection) nil))
               (mapc #'zr-rclone--forget-webdav (zr-rclone-connection-mappings connection))
               (setf (zr-rclone-connection-mappings connection) nil)
               (zr-rclone--status connection (concat "rcd: " (string-trim event)))))))
    (setq zr-rclone--connection connection)
    (let ((deadline (+ (float-time) 10)) ready)
      (while (and (not ready) (< (float-time) deadline)
                  (process-live-p (zr-rclone-connection-process connection)))
        (let ((zr-rclone-timeout 0.5))
          (setq ready (ignore-errors (zr-rclone--probe connection))))
        (unless ready (accept-process-output nil 0.1)))
      (unless ready
        (display-buffer buffer)
        (user-error "rcd did not start; see %s" (buffer-name buffer))))
    connection))

(defun zr-rclone-stop-daemon ()
  "Stop the local rcd process owned by this connection."
  (interactive)
  (let* ((connection (zr-rclone--context))
         (process (zr-rclone-connection-process connection)))
    (unless (process-live-p process)
      (user-error "This connection has no running rcd owned by Emacs"))
    (when (yes-or-no-p "Stop owned rcd, including its jobs, mounts and servers? ")
      (ignore-errors (zr-rclone--call connection "core/quit"))
      (let ((deadline (+ (float-time) 1)))
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.05)))
      (when (process-live-p process) (delete-process process))
      (zr-rclone-disconnect)
      (mapc #'zr-rclone--forget-webdav (zr-rclone-connection-mappings connection))
      (setf (zr-rclone-connection-mappings connection) nil))))

;;; Background jobs

(defun zr-rclone--merge (&rest objects)
  "Merge alist OBJECTS, with later values taking precedence."
  (let (result)
    (dolist (object objects)
      (dolist (pair object)
        (setf (alist-get (car pair) result) (cdr pair))))
    result))

(defun zr-rclone--operation-params (params &optional connection)
  "Add CONNECTION's dry-run and per-call options to PARAMS."
  (let* ((connection (or connection (zr-rclone--context)))
         (options (zr-rclone-connection-call-options connection))
         (config (copy-tree (alist-get '_config options))))
    (setf (alist-get 'DryRun config) (if (zr-rclone-connection-dry-run connection) t :false))
    (zr-rclone--merge options (list (cons '_config config)) params)))

(defun zr-rclone--submit (method params label &optional raw)
  "Submit METHOD with PARAMS as a job named LABEL.
RAW omits native file-operation options, for services and core/command."
  (let* ((connection (zr-rclone--connected))
         (group (format "zr-rclone-%d-%d" (emacs-pid) (cl-incf zr-rclone--serial)))
         (request (zr-rclone--merge
                   (if raw params (zr-rclone--operation-params params connection))
                   (list '(_async . t) (cons '_group group)))))
    (zr-rclone--require-method connection method)
    (let* ((result (zr-rclone--call connection method request))
           (id (alist-get 'jobid result))
           (job (list :id id :group group :label label :state "running"
                      :instance (zr-rclone-connection-instance connection)
                      :execute-id (alist-get 'executeId result)
                      :finished nil :polling nil
                      :output nil :error nil :stats nil)))
      (unless id (user-error "RC did not return a job ID"))
      (push job (zr-rclone-connection-jobs connection))
      (zr-rclone--ensure-polling connection)
      (zr-rclone--render-jobs connection)
      (message "rclone job %s: %s" id label)
      job)))

(defun zr-rclone--ensure-polling (connection)
  "Start polling while CONNECTION has unfinished jobs."
  (when (and (zr-rclone-connection-connected connection)
             (cl-some (lambda (job) (not (plist-get job :finished)))
                      (zr-rclone-connection-jobs connection))
             (not (zr-rclone-connection-timer connection)))
    (setf (zr-rclone-connection-timer connection)
          (run-at-time 0.2 zr-rclone-poll-interval
                       #'zr-rclone--poll-jobs connection))))

(defun zr-rclone--finish-job (connection job result)
  "Store the completed RESULT for JOB on CONNECTION."
  (let* ((output (alist-get 'output result))
         (command-error (eq (alist-get 'error output) t))
         (success (and (eq (alist-get 'success result) t) (not command-error))))
    (setf (plist-get job :finished) t
          (plist-get job :state) (if success "done" "failed")
          (plist-get job :output) output
          (plist-get job :error)
          (if command-error (alist-get 'result output) (alist-get 'error result)))
    (message "rclone job %s: %s" (plist-get job :id) (plist-get job :state))
    (zr-rclone--render-jobs connection)))

(defun zr-rclone--poll-jobs (connection)
  "Fetch status and progress for unfinished jobs on CONNECTION."
  (if (not (and (zr-rclone-connection-connected connection)
                (cl-some (lambda (job) (not (plist-get job :finished)))
                         (zr-rclone-connection-jobs connection))))
      (when (zr-rclone-connection-timer connection)
        (cancel-timer (zr-rclone-connection-timer connection))
        (setf (zr-rclone-connection-timer connection) nil))
    (dolist (job (zr-rclone-connection-jobs connection))
      (unless (or (plist-get job :finished) (plist-get job :polling))
        (setf (plist-get job :polling) t)
        (zr-rclone--request
         connection "job/status" (list (cons 'jobid (plist-get job :id)))
         (lambda (result error)
           (setf (plist-get job :polling) nil)
           (cond
            ((plist-get job :finished))
            (error
             (setf (plist-get job :state) "unreachable"
                   (plist-get job :error) error)
             (when (string-match-p "job.*not found\\|job.*not exist" error)
               (setf (plist-get job :finished) t
                     (plist-get job :state) "expired")))
            ((and (plist-get job :execute-id) (alist-get 'executeId result)
                  (not (equal (plist-get job :execute-id)
                              (alist-get 'executeId result))))
             (setf (plist-get job :finished) t
                   (plist-get job :state) "stale"
                   (plist-get job :error) "rclone restarted"))
            ((eq (alist-get 'finished result) t)
             (zr-rclone--finish-job connection job result))
            (t
             (setf (plist-get job :state) "running" (plist-get job :error) nil)
             (zr-rclone--request
              connection "core/stats" (list (cons 'group (plist-get job :group)))
              (lambda (stats error)
                (unless error
                  (setf (plist-get job :stats) stats)
                  (zr-rclone--render-jobs connection))))))
           (zr-rclone--render-jobs connection)))))))

(defvar zr-rclone-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'zr-rclone-refresh-jobs)
    (define-key map (kbd "k") #'zr-rclone-cancel-job)
    (define-key map (kbd "RET") #'zr-rclone-job-output)
    map))

(define-derived-mode zr-rclone-jobs-mode tabulated-list-mode "Rclone jobs"
  "RC jobs; g refreshes, k cancels, RET displays retained results."
  (setq tabulated-list-format [("ID" 8 t) ("Operation" 35 t)
                               ("State" 12 t) ("Progress" 30 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun zr-rclone--render-jobs (connection)
  "Update CONNECTION's jobs table when it exists."
  (when (buffer-live-p (zr-rclone-connection-job-buffer connection))
    (with-current-buffer (zr-rclone-connection-job-buffer connection)
      (setq tabulated-list-entries
            (mapcar
             (lambda (job)
               (let* ((stats (plist-get job :stats))
                      (bytes (or (alist-get 'bytes stats) 0))
                      (total (or (alist-get 'totalBytes stats) 0))
                      (speed (or (alist-get 'speed stats) 0)))
                 (list (plist-get job :group)
                       (vector (format "%s" (plist-get job :id))
                               (plist-get job :label) (plist-get job :state)
                               (format "%s / %s (%s/s)"
                                       (file-size-human-readable bytes)
                                       (file-size-human-readable total)
                                       (file-size-human-readable speed))))))
             (zr-rclone-connection-jobs connection)))
      (tabulated-list-print t))))

(defun zr-rclone-jobs ()
  "Display the current connection's jobs and retained results."
  (interactive)
  (let* ((connection (zr-rclone--context))
         (buffer (or (and (buffer-live-p (zr-rclone-connection-job-buffer connection))
                          (zr-rclone-connection-job-buffer connection))
                     (let ((buffer (generate-new-buffer
                                    (format "*rclone jobs %s*"
                                            (zr-rclone-connection-url connection)))))
                       (with-current-buffer buffer
                         (zr-rclone-jobs-mode)
                         (setq zr-rclone--jobs-connection connection))
                       (setf (zr-rclone-connection-job-buffer connection) buffer)))))
    (zr-rclone--render-jobs connection)
    (pop-to-buffer buffer)))

(defun zr-rclone--jobs-context ()
  "Return the connection owning the current jobs buffer."
  (or zr-rclone--jobs-connection (user-error "Open a jobs buffer first")))

(defun zr-rclone-refresh-jobs ()
  "Refresh this jobs buffer's connection, even if another session is selected."
  (interactive)
  (zr-rclone--poll-jobs (zr-rclone--connected (zr-rclone--jobs-context))))

(defun zr-rclone--job-at-point ()
  "Return the job at point in a jobs table."
  (or (cl-find (tabulated-list-get-id)
               (zr-rclone-connection-jobs (zr-rclone--jobs-context))
               :test #'equal :key (lambda (job) (plist-get job :group)))
      (user-error "No job at point")))

(defun zr-rclone-cancel-job ()
  "Cancel the selected running job on its original rclone instance."
  (interactive)
  (let* ((connection (zr-rclone--connected (zr-rclone--jobs-context)))
         (job (zr-rclone--job-at-point)))
    (when (plist-get job :finished) (user-error "This job has already finished"))
    (unless (equal (plist-get job :instance)
                   (zr-rclone--server-instance connection))
      (user-error "rclone restarted; reconnect before issuing more commands"))
    ;; A status callback can finish the job while the identity/stop request runs.
    (unless (plist-get job :finished)
      (zr-rclone--call connection "job/stop" (list (cons 'jobid (plist-get job :id))))
      (unless (plist-get job :finished)
        (setf (plist-get job :state) "cancelling")))
    (zr-rclone--render-jobs connection)))

(defun zr-rclone--show-result (title result &optional error)
  "Display RESULT and optional ERROR in a buffer named TITLE."
  (let ((buffer (get-buffer-create (format "*rclone %s*" title))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (cond ((stringp result) result)
                      ((stringp (alist-get 'result result)) (alist-get 'result result))
                      (t (zr-rclone--json result))))
        (when (and error (not (string-empty-p error)))
          (insert "\n\nError: " error))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)
    buffer))

(defun zr-rclone-job-output ()
  "Show the selected job's retained output, even after the server expires it."
  (interactive)
  (let ((job (zr-rclone--job-at-point)))
    (zr-rclone--show-result (format "job %s" (plist-get job :group))
                            (plist-get job :output) (plist-get job :error))))

;;; Directory operations

(defun zr-rclone--target ()
  "Return the selected session's target directory, prompting if unset."
  (or (zr-rclone-connection-target-path (zr-rclone--context))
      (progn (call-interactively #'zr-rclone-set-target)
             (zr-rclone-connection-target-path (zr-rclone--context)))))

(defun zr-rclone--path-pair ()
  "Return non-overlapping current and target directories."
  (let ((source (zr-rclone--directory)) (target (zr-rclone--target)))
    (when (or (zr-rclone--relative-to source target)
              (zr-rclone--relative-to target source))
      (user-error "Current and target paths must be different and non-overlapping"))
    (cons source target)))

(defun zr-rclone--transfer (method)
  "Run directory METHOD from the current path to the target path."
  (let* ((connection (zr-rclone--connected))
         (paths (zr-rclone--path-pair))
         (move (equal method "move")))
    (when (or (not move) (zr-rclone-connection-dry-run connection)
              (yes-or-no-p (format "Move contents of %s → %s? " (car paths) (cdr paths))))
      (zr-rclone--submit
       (concat "sync/" method)
       (append (list (cons 'srcFs (car paths)) (cons 'dstFs (cdr paths))
                     '(createEmptySrcDirs . t))
               (when move '((deleteEmptySrcDirs . t))))
       (format "%s %s → %s" method (car paths) (cdr paths))))))

(defun zr-rclone-copy ()
  "Copy current directory contents to the target, preserving extra target files."
  (interactive)
  (zr-rclone--transfer "copy"))

(defun zr-rclone-move ()
  "Move current directory contents to the target."
  (interactive)
  (zr-rclone--transfer "move"))

(defun zr-rclone-sync ()
  "Sync current directory contents to the target, deleting extra target files."
  (interactive)
  (let ((paths (zr-rclone--path-pair)))
    (when (or (zr-rclone-connection-dry-run (zr-rclone--context))
              (yes-or-no-p (format "Sync %s → %s, deleting extra target files? "
                                   (car paths) (cdr paths))))
      (zr-rclone--submit "sync/sync"
                        (list (cons 'srcFs (car paths)) (cons 'dstFs (cdr paths))
                              '(createEmptySrcDirs . t))
                        (format "sync %s → %s" (car paths) (cdr paths))))))

(defun zr-rclone-bisync (&optional resync)
  "Bidirectionally sync current and target paths.
With prefix RESYNC, explicitly initialize or rebuild the bisync state."
  (interactive "P")
  (let* ((connection (zr-rclone--context))
         (paths (zr-rclone--path-pair))
         (dry-run (zr-rclone-connection-dry-run connection)))
    (when (or dry-run
              (yes-or-no-p (format "%s %s ↔ %s? "
                                   (if resync "Initialize/resync" "Bisync")
                                   (car paths) (cdr paths))))
      (zr-rclone--submit
       "sync/bisync"
       (zr-rclone--merge
        (zr-rclone-connection-bisync-options connection)
        (list (cons 'path1 (car paths)) (cons 'path2 (cdr paths))
              (cons 'resync (if resync t :false))
              (cons 'dryRun (if dry-run t :false))))
       (format "bisync%s %s ↔ %s" (if resync " --resync" "")
               (car paths) (cdr paths))))))

(defun zr-rclone-bisync-resync ()
  "Explicitly initialize or rebuild this bisync pair."
  (interactive)
  (zr-rclone-bisync t))

(defun zr-rclone-toggle-dry-run ()
  "Toggle dry-run for this connection's native file operations."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-dry-run connection)
          (not (zr-rclone-connection-dry-run connection)))))

(defun zr-rclone-set-call-options ()
  "Edit per-operation _config and _filter objects."
  (interactive)
  (let* ((connection (zr-rclone--context))
         (options (zr-rclone--read-json
                   "Call options (_config / _filter): "
                   (zr-rclone-connection-call-options connection))))
    (unless (cl-every (lambda (pair) (memq (car pair) '(_config _filter))) options)
      (user-error "Only _config and _filter belong in call options"))
    (setf (zr-rclone-connection-call-options connection) options)))

(defun zr-rclone-set-bisync-options ()
  "Edit bisync options, including workdir and conflict handling."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-bisync-options connection)
          (zr-rclone--read-json "Bisync options: "
                                (zr-rclone-connection-bisync-options connection)))))

;;; Temporary commands

(defun zr-rclone--command-words (text)
  "Parse TEXT into arguments, respecting quotes and backslash escaping.
No shell is invoked.  Reject unquoted shell operators and incomplete quoting."
  (let (words chars quote escaped started)
    (cl-labels ((emit ()
                  (when started
                    (push (apply #'string (nreverse chars)) words)
                    (setq chars nil started nil))))
      (cl-loop for index from 0 below (length text)
               for char = (aref text index)
               do (cond
                   (escaped (push char chars) (setq escaped nil started t))
                   ((eq quote ?\')
                    (if (= char ?\') (setq quote nil) (push char chars)))
                   ((= char ?\\)
                    (if (and (eq quote ?\")
                             (< (1+ index) (length text))
                             (not (memq (aref text (1+ index))
                                        '(?\" ?\\ ?$ ?` ?\n))))
                        (push char chars)
                      (setq escaped t))
                    (setq started t))
                   (quote
                    (if (= char quote) (setq quote nil) (push char chars)))
                   ((memq char '(?\' ?\")) (setq quote char started t))
                   ((memq char '(?\s ?\t ?\n ?\r)) (emit))
                   ((memq char '(?| ?& ?\; ?< ?> ?`))
                    (user-error "Enter rclone arguments; shell operators are not supported"))
                   (t (push char chars) (setq started t))))
      (when (or quote escaped) (user-error "Unterminated quote or escape"))
      (emit))
    (nreverse words)))

(defconst zr-rclone--commands
  '("about" "backend" "bisync" "cat" "check" "checksum" "cleanup" "config"
    "copy" "copyto" "copyurl" "cryptcheck" "cryptdecode" "dedupe" "delete"
    "deletefile" "hashsum" "help" "link" "listremotes" "ls" "lsd" "lsf"
    "lsjson" "lsl" "mkdir" "move" "moveto" "purge" "rmdir" "rmdirs"
    "settier" "size" "sync" "touch" "tree" "version")
  "Completion candidates for temporary CLI commands.")

(defun zr-rclone--read-command ()
  "Read a temporary rclone command with command and path completion."
  (let* ((connection (zr-rclone--connected))
        (base (zr-rclone-connection-current-path connection)))
    (minibuffer-with-setup-hook
        (lambda ()
          (use-local-map (copy-keymap (current-local-map)))
          (setq-local
           completion-at-point-functions
           (list
            (lambda ()
              (let ((end (point))
                    (start (save-excursion
                             (skip-chars-backward "^ \t" (minibuffer-prompt-end))
                             (point))))
                (list start end
                      (if (= start (minibuffer-prompt-end)) zr-rclone--commands
                        (completion-table-dynamic
                         (lambda (input)
                           (zr-rclone--path-completions connection input base nil))))
                      :exclusive 'no)))))
          (local-set-key (kbd "TAB") #'completion-at-point))
      (read-string "rclone command (on rcd machine): "
                   nil 'zr-rclone-command-history))))

(defun zr-rclone-command (command)
  "Run manually entered rclone COMMAND through core/command.
Native dry-run/filter settings do not apply; include desired CLI flags.
The output is retained in the jobs table, including command failures."
  (interactive (list (zr-rclone--read-command)))
  (let* ((connection (zr-rclone--connected))
         (words (zr-rclone--command-words command))
         (config (zr-rclone-connection-config-file connection)))
    (when (equal (car words) "rclone") (setq words (cdr words)))
    (unless words (user-error "Enter an rclone command"))
    (when (and config (not (cl-some
                           (lambda (word) (or (equal word "--config")
                                             (string-prefix-p "--config=" word))) words)))
      (setq words (append words (list "--config" config))))
    (zr-rclone--submit
     "core/command"
     (list (cons 'command (car words)) (cons 'arg (vconcat (cdr words)))
           '(returnType . "COMBINED_OUTPUT"))
     (concat "command: " (car words)) t)))

(defun zr-rclone-call ()
  "Call any advertised RC method with manually entered JSON parameters."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (method (completing-read "RC method: "
                                  (zr-rclone-connection-methods connection) nil t))
         (params (zr-rclone--read-json "Parameters: " nil)))
    (if (eq (alist-get '_async params) t)
        (zr-rclone--submit method params method t)
      (zr-rclone--show-result method (zr-rclone--call connection method params)))))

;;; Mounts and WebDAV services

(defun zr-rclone-set-mount-options ()
  "Edit mountType, mountOpt and vfsOpt options."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-mount-options connection)
          (zr-rclone--read-json "Mount options: "
                                (zr-rclone-connection-mount-options connection)))))

(defun zr-rclone-mount ()
  "Mount the current path on the rcd machine."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (source (zr-rclone--directory))
         (default-directory temporary-file-directory)
         (point (if (zr-rclone-connection-local-p connection)
                    (read-directory-name "Local mount point: ")
                  (read-string "Mount point on rcd machine: "))))
    (when (string-empty-p point) (user-error "A mount point is required"))
    (zr-rclone--submit
     "mount/mount"
     (zr-rclone--merge (zr-rclone-connection-mount-options connection)
                       (list (cons 'fs source) (cons 'mountPoint point)))
     (concat "mount " source) t)))

(defun zr-rclone-list-mounts ()
  "Display the current connection's active mounts."
  (interactive)
  (zr-rclone--show-result
   "mounts" (zr-rclone--call (zr-rclone--connected) "mount/listmounts")))

(defun zr-rclone-unmount ()
  "Choose and unmount one mount on the rcd machine."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (mounts (alist-get 'mountPoints
                            (zr-rclone--call connection "mount/listmounts")))
         (choices (mapcar (lambda (mount)
                            (or (alist-get 'MountPoint mount)
                                (alist-get 'mountPoint mount))) mounts)))
    (unless choices (user-error "No active mounts"))
    (zr-rclone--call connection "mount/unmount"
                     (list (cons 'mountPoint
                                 (completing-read "Unmount: " choices nil t))))
    (message "rclone mount removed")))

(defun zr-rclone--encode-path (path)
  "Encode each component of PATH for an HTTP URL."
  (mapconcat #'url-hexify-string (split-string path "/") "/"))

(defun zr-rclone--mapping-url (mapping path)
  "Return the URL of PATH under WebDAV MAPPING, or nil."
  (when-let* ((relative (zr-rclone--relative-to path (plist-get mapping :root))))
    (concat (plist-get mapping :url) (zr-rclone--encode-path relative))))

(defun zr-rclone--mapping-credentials (mapping)
  "Find Basic credentials for MAPPING, keeping RC credentials separate."
  (let* ((url (url-generic-parse-url (plist-get mapping :url)))
         (user (plist-get mapping :user))
         (password (plist-get mapping :password)))
    (if (and user password)
        (cons user password)
      (when-let* ((entry (car (auth-source-search
                              :host (url-host url)
                              :port (list (number-to-string (url-port url))
                                          (if (equal (url-type url) "https")
                                              "webdavs" "webdav"))
                              :user (or user t) :require '(:user :secret) :max 1)))
                  (secret (plist-get entry :secret)))
        (cons (plist-get entry :user)
              (if (functionp secret) (funcall secret) secret))))))

(defun zr-rclone-set-webdav ()
  "Map a WebDAV URL to the current rclone directory.
The URL must be reachable from Emacs, including any proxy path."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (root (zr-rclone--directory))
         (url (zr-rclone--normalize-url
               (read-string "WebDAV URL serving current path: ")))
         (user (read-string "WebDAV user (empty uses auth-source): ")))
    (push (list :root root :url url
                :user (unless (string-empty-p user) user))
          (zr-rclone-connection-mappings connection))
    (message "Mapped %s to %s" root url)))

(defun zr-rclone--backend-mapping (connection path)
  "Discover a directly configured WebDAV backend for PATH on CONNECTION.
Aliases, crypt wrappers and backend-specific authentication are left
to explicit mappings or rclone's own WebDAV server."
  (let* ((parts (zr-rclone--split-path path))
         (root (car parts))
         (name (and root (string-match "\\`\\([^/:,]+\\):\\'" root)
                    (match-string 1 root))))
    (when name
      (let ((config (zr-rclone--call connection "config/get" (list (cons 'name name)))))
        (when (and (equal (alist-get 'type config) "webdav")
                   (not (member (alist-get 'vendor config) '("sharepoint-ntlm" "sharepoint"))))
          (let ((mapping (list :root root
                               :url (zr-rclone--normalize-url (alist-get 'url config))
                               :user (alist-get 'user config))))
            ;; Obscured rclone passwords are not auth-source passwords.
            (push mapping (zr-rclone-connection-mappings connection))
            mapping))))))

(defun zr-rclone--mapping (connection path)
  "Return the most specific WebDAV mapping for PATH on CONNECTION."
  (or (car (sort
            (cl-remove-if-not
             (lambda (mapping) (zr-rclone--mapping-url mapping path))
             (copy-sequence (zr-rclone-connection-mappings connection)))
            (lambda (a b) (> (length (plist-get a :root))
                             (length (plist-get b :root))))))
      (zr-rclone--backend-mapping connection path)
      (user-error "Start WebDAV or set a WebDAV URL for this path first")))

(defun zr-rclone-serve-webdav ()
  "Start a WebDAV server for the current path through serve/start.
Local servers use a generated password and an automatically assigned port.
For remote servers, ask separately for the listening and accessible addresses."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (root (zr-rclone--directory))
         (local (zr-rclone-connection-local-p connection))
         (address (if local "127.0.0.1:0"
                    (read-string "WebDAV listen address on rcd machine: "
                                 "127.0.0.1:8080")))
         (external (unless local
                     (zr-rclone--normalize-url
                      (read-string "WebDAV URL reachable from Emacs: ")))))
    (zr-rclone--require-method connection "serve/start")
    (let* ((user "zr-rclone")
           (password (zr-rclone--new-password))
           (result
            (zr-rclone--call
             connection "serve/start"
             (zr-rclone--merge
              (zr-rclone-connection-webdav-options connection)
              (list '(type . "webdav") (cons 'fs root)
                    (cons 'addr address) (cons 'user user) (cons 'pass password)))))
           (id (alist-get 'id result))
           (url (or external
                    (zr-rclone--normalize-url
                     (concat "http://" (alist-get 'addr result))))))
      (push (list :id id :root root :url url :user user :password password)
            (zr-rclone-connection-mappings connection))
      (message "WebDAV %s: %s" id url))))

(defun zr-rclone-set-webdav-options ()
  "Edit additional WebDAV serve options."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-webdav-options connection)
          (zr-rclone--read-json "WebDAV serve options: "
                                (zr-rclone-connection-webdav-options connection)))))

(defun zr-rclone-list-servers ()
  "Display server IDs, roots and addresses, omitting credential parameters."
  (interactive)
  (let ((servers (alist-get 'list
                            (zr-rclone--call (zr-rclone--connected) "serve/list"))))
    (zr-rclone--show-result
     "servers"
     (list
      (cons 'servers
            (vconcat
             (mapcar (lambda (server)
                       (list (cons 'id (alist-get 'id server))
                             (cons 'addr (alist-get 'addr server))
                             (cons 'fs (alist-get 'fs (alist-get 'params server)))
                             (cons 'type (alist-get 'type (alist-get 'params server)))))
                     servers)))))))

(defun zr-rclone-stop-webdav ()
  "Select and stop one active WebDAV server."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (servers (alist-get 'list (zr-rclone--call connection "serve/list")))
         (choices
          (delq nil
                (mapcar
                 (lambda (server)
                   (let ((params (alist-get 'params server)))
                     (when (equal (alist-get 'type params) "webdav")
                       (cons (format "%s  %s  %s" (alist-get 'id server)
                                     (alist-get 'fs params) (alist-get 'addr server))
                             (alist-get 'id server)))))
                 servers))))
    (unless choices (user-error "No running WebDAV servers"))
    (let ((id (cdr (assoc (completing-read "Stop WebDAV: " choices nil t) choices))))
      (zr-rclone--call connection "serve/stop" (list (cons 'id id)))
      (dolist (mapping (zr-rclone-connection-mappings connection))
        (when (equal (plist-get mapping :id) id) (zr-rclone--forget-webdav mapping)))
      (setf (zr-rclone-connection-mappings connection)
            (cl-remove id (zr-rclone-connection-mappings connection)
                       :test #'equal :key (lambda (mapping) (plist-get mapping :id))))
      (message "Stopped WebDAV %s" id))))

(declare-function tramp-make-tramp-file-name "tramp")
(declare-function tramp-dissect-file-name "tramp")
(declare-function tramp-file-name-method "tramp")
(declare-function tramp-file-name-user "tramp")
(declare-function tramp-file-name-host "tramp")
(declare-function tramp-file-name-port "tramp")
(declare-function tramp-file-name-unquote-localname "tramp")
(defvar zr-tramp-webdav-extra-headers)

(defun zr-rclone--webdav-name (url user)
  "Convert URL and USER to a zr-tramp-webdav file name."
  (require 'tramp)
  (let ((parsed (url-generic-parse-url url)))
    (tramp-make-tramp-file-name
     (if (equal (url-type parsed) "https") "webdavs" "webdav")
     user nil (url-host parsed) (number-to-string (url-port parsed))
     (decode-coding-string (url-unhex-string (url-filename parsed)) 'utf-8))))

(defun zr-rclone-open-webdav ()
  "Open the current directory through zr-tramp-webdav for file management."
  (interactive)
  (let* ((connection (zr-rclone--connected))
         (path (zr-rclone--directory connection))
         (mapping (zr-rclone--mapping connection path))
         (credentials (zr-rclone--mapping-credentials mapping))
         (name (zr-rclone--webdav-name
                (zr-rclone--mapping-url mapping path)
                (or (car credentials) (plist-get mapping :user)))))
    (unless (require 'zr-tramp-webdav nil t)
      (user-error "zr-tramp-webdav is not available on load-path"))
    (when credentials
      (zr-rclone--install-webdav-credentials mapping credentials))
    (find-file (file-name-as-directory name))))

(defvar zr-rclone--webdav-auth nil
  "Managed WebDAV credentials scoped by origin, path root, and user.")
(defvar zr-rclone--previous-webdav-headers nil)

(defun zr-rclone--webdav-headers (file)
  "Supply managed authentication for FILE, preserving existing headers."
  (let* ((vec (tramp-dissect-file-name file))
         (secure (equal (tramp-file-name-method vec) "webdavs"))
         (origin (list (if secure "https" "http")
                       (downcase (tramp-file-name-host vec))
                       (if (tramp-file-name-port vec)
                           (string-to-number (tramp-file-name-port vec))
                         (if secure 443 80))))
         (path (tramp-file-name-unquote-localname vec))
         (match (cl-find-if
                 (lambda (entry)
                   (and (equal origin (plist-get entry :origin))
                        (equal (tramp-file-name-user vec) (plist-get entry :user))
                        (or (equal path (string-remove-suffix "/" (plist-get entry :root)))
                            (string-prefix-p (plist-get entry :root) path))))
                 zr-rclone--webdav-auth))
         (previous (if (functionp zr-rclone--previous-webdav-headers)
                       (funcall zr-rclone--previous-webdav-headers file)
                     zr-rclone--previous-webdav-headers)))
    (if match
        (cons (cons "Authorization" (plist-get match :header))
              (cl-remove "Authorization" previous :key #'car :test #'string-equal-ignore-case))
      previous)))

(defun zr-rclone--install-webdav-credentials (mapping credentials)
  "Make MAPPING's CREDENTIALS available to the existing WebDAV handler."
  (let* ((parsed (url-generic-parse-url (plist-get mapping :url)))
         (root (decode-coding-string (url-unhex-string (url-filename parsed)) 'utf-8))
         (origin (zr-rclone--origin (plist-get mapping :url))))
    (push (list :origin origin :root root :user (car credentials)
                :header (zr-rclone--basic-header credentials))
          zr-rclone--webdav-auth)
    (setq zr-rclone--webdav-auth
          (sort zr-rclone--webdav-auth
                (lambda (a b) (> (length (plist-get a :root))
                                 (length (plist-get b :root)))))))
  (unless (eq zr-tramp-webdav-extra-headers #'zr-rclone--webdav-headers)
    (setq zr-rclone--previous-webdav-headers zr-tramp-webdav-extra-headers
          zr-tramp-webdav-extra-headers #'zr-rclone--webdav-headers)))

(defun zr-rclone--forget-webdav (mapping)
  "Forget cached credentials for MAPPING's URL root."
  (let* ((parsed (url-generic-parse-url (plist-get mapping :url)))
         (root (decode-coding-string (url-unhex-string (url-filename parsed)) 'utf-8))
         (origin (zr-rclone--origin (plist-get mapping :url))))
    (setq zr-rclone--webdav-auth
          (cl-remove-if (lambda (entry)
                          (and (equal (plist-get entry :origin) origin)
                               (equal (plist-get entry :root) root)))
                        zr-rclone--webdav-auth))))

;;; Playback

(defvar zr-rclone--mpv-configs nil
  "Private mpv config files awaiting process cleanup.")

(defun zr-rclone--delete-mpv-config (file)
  "Remove the private mpv config FILE, if present."
  (when file
    (when (file-exists-p file) (delete-file file))
    (setq zr-rclone--mpv-configs (delete file zr-rclone--mpv-configs))))

(add-hook 'kill-emacs-hook
          (lambda ()
            (dolist (file (copy-sequence zr-rclone--mpv-configs))
              (ignore-errors (zr-rclone--delete-mpv-config file)))))

(defun zr-rclone--media (connection path rc-serve)
  "Return (URL . CREDENTIALS) for full rclone PATH on CONNECTION.
RC-SERVE uses HTTP object serving on the RC port instead of WebDAV."
  (if rc-serve
      (let ((parts (zr-rclone--split-path path)))
        (unless parts (user-error "A full rclone path is required"))
        (cons (concat (zr-rclone-connection-url connection)
                      (url-hexify-string (format "[%s]" (car parts)))
                      "/" (zr-rclone--encode-path (cdr parts)))
              (zr-rclone--credentials connection)))
    (let ((mapping (zr-rclone--mapping connection path)))
      (cons (zr-rclone--mapping-url mapping path)
            (zr-rclone--mapping-credentials mapping)))))

(defun zr-rclone--origin (url)
  "Return the HTTP origin of URL."
  (let ((parsed (url-generic-parse-url url)))
    (list (url-type parsed) (downcase (url-host parsed)) (url-port parsed))))

(defun zr-rclone--launch-mpv (media)
  "Pipe MEDIA URLs to mpv as an M3U playlist.
Keep Basic authentication out of argv and URLs using a private config file."
  (unless media (user-error "No files to play"))
  (let ((credentials (cdar media))
        (origin (zr-rclone--origin (caar media)))
        (default-directory temporary-file-directory)
        (buffer (get-buffer-create "*rclone mpv*"))
        config process)
    (unless (cl-every (lambda (item)
                        (and (equal (cdr item) credentials)
                             (equal (zr-rclone--origin (car item)) origin))) media)
      (user-error "One playlist must use one origin and authentication identity"))
    (unwind-protect
        (progn
          (when credentials
            (setq config (make-temp-file "zr-rclone-mpv-" nil ".conf"))
            (push config zr-rclone--mpv-configs)
            (set-file-modes config #o600)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region
               (concat "http-header-fields=\"Authorization: "
                       (zr-rclone--basic-header credentials) "\"\n")
               nil config nil 'silent)))
          (setq process
                (make-process
                 :name "zr-rclone-mpv" :buffer buffer
                 :command (append
                           (list zr-rclone-mpv-program "--input-terminal=no")
                           (when config (list (concat "--include=" config)))
                           zr-rclone-mpv-arguments (list "--playlist=-"))
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :sentinel
                 (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (zr-rclone--delete-mpv-config config)
                     (unless (zerop (process-exit-status proc))
                       (message "mpv exited with an error; see *rclone mpv*"))))))
          (process-send-string process
                               (concat "#EXTM3U\n" (string-join (mapcar #'car media) "\n")
                                       "\n"))
          (process-send-eof process)
          process)
      (unless process
        (zr-rclone--delete-mpv-config config)))))

;;; File lists for external consumers

(defun zr-rclone-toggle-recursive ()
  "Toggle recursive file listing for the selected connection."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-list-recursive connection)
          (not (zr-rclone-connection-list-recursive connection)))))

(defun zr-rclone-toggle-media-source ()
  "Switch playback URLs between WebDAV and rcd's --rc-serve interface."
  (interactive)
  (let ((connection (zr-rclone--context)))
    (setf (zr-rclone-connection-media-rc-serve connection)
          (not (zr-rclone-connection-media-rc-serve connection)))))

(defun zr-rclone-list-files (&optional connection)
  "Return sorted full rclone file paths from CONNECTION's current directory.
Honor the session's recursion setting and per-call filters.  No buffer is
created.  Directory entries are omitted."
  (let* ((connection (zr-rclone--connected connection))
         (path (zr-rclone--directory connection))
         (result
          (zr-rclone--call
           connection "operations/list"
           (zr-rclone--operation-params
            (list (cons 'fs path) '(remote . "")
                  (cons 'opt
                        (list '(filesOnly . t) '(noMimeType . t)
                              (cons 'recurse
                                    (if (zr-rclone-connection-list-recursive connection)
                                        t :false)))))
            connection))))
    (sort (mapcar (lambda (entry) (zr-rclone--join path (alist-get 'Path entry)))
                  (cl-remove-if (lambda (entry) (eq (alist-get 'IsDir entry) t))
                                (alist-get 'list result)))
          #'string-lessp)))

(defun zr-rclone--consumer-files (connection select)
  "Get CONNECTION's file list, optionally prompting to SELECT a subset."
  (let ((files (zr-rclone-list-files connection)))
    (unless files (user-error "No files matched the current path and filters"))
    (if (not select) files
      ;; Display escaped names; match the original paths instead of decoding
      ;; text entered in the minibuffer.  This also handles commas/newlines.
      (let* ((root (zr-rclone--directory connection))
             (print-escape-newlines t)
             (choices (cl-loop for file in files for index from 1
                               collect (cons (format "%d %S" index
                                                     (zr-rclone--relative-to file root))
                                             file)))
             (crm-separator "\n")
             (selected (completing-read-multiple
                        "Files (TAB completes; C-q C-j separates): " choices nil t))
             (paths (mapcar (lambda (choice) (cdr (assoc choice choices))) selected)))
        (unless paths (user-error "No files selected"))
        (cl-remove-if-not (lambda (file) (member file paths)) files)))))

(defun zr-rclone-send-file-list (&optional select)
  "Send matching file paths to zr-rclone-file-list-function.
With prefix SELECT, choose a subset using minibuffer completion."
  (interactive "P")
  (let* ((connection (zr-rclone--connected))
         (files (zr-rclone--consumer-files connection select)))
    (funcall zr-rclone-file-list-function files connection)))

(defun zr-rclone-file-urls (files connection)
  "Convert full rclone FILES to (URL . CREDENTIALS) pairs on CONNECTION.
CREDENTIALS is nil or (USER . PASSWORD).  Use the session's selected
WebDAV or RC HTTP media source."
  (mapcar (lambda (file)
            (zr-rclone--media connection file
                               (zr-rclone-connection-media-rc-serve connection)))
          files))

(defun zr-rclone-play-files (files connection)
  "Play full rclone FILES on CONNECTION through mpv.
Use this as a zr-rclone-file-list-function consumer."
  (zr-rclone--launch-mpv (zr-rclone-file-urls files connection)))

(defun zr-rclone-play (&optional select)
  "List matching files and play them through mpv.
With prefix SELECT, choose a subset using minibuffer completion."
  (interactive "P")
  (let ((connection (zr-rclone--connected)))
    (zr-rclone-play-files (zr-rclone--consumer-files connection select) connection)))

;;; Transient

(defun zr-rclone--panel-description ()
  "Describe the selected RC connection without creating a session buffer."
  (let ((connection (zr-rclone--context)))
    (truncate-string-to-width
     (format "%s [%s, %s] %s"
             (zr-rclone-connection-url connection)
             (zr-rclone-connection-transport connection)
             (if (zr-rclone-connection-local-p connection) "local" "server")
             (zr-rclone-connection-status connection))
     78 nil nil "…")))

(transient-define-prefix zr-rclone-services-menu ()
  "Control mounts and WebDAV services and edit their options."
  [[ "Mount"
     ("m" "Mount current" zr-rclone-mount)
     ("u" "Unmount" zr-rclone-unmount)
     ("M" "List mounts" zr-rclone-list-mounts)
     ("-m" "Mount options" zr-rclone-set-mount-options :transient t)]
   [ "WebDAV"
     ("w" "Start current" zr-rclone-serve-webdav)
     ("W" "Stop" zr-rclone-stop-webdav)
     ("v" "List servers" zr-rclone-list-servers)
     ("-w" "Serve options" zr-rclone-set-webdav-options :transient t)
     ("U" "URL mapping" zr-rclone-set-webdav :transient t)
     ("o" "Open with TRAMP" zr-rclone-open-webdav)]
   [ "Operations"
     ("-o" "Call options" zr-rclone-set-call-options :transient t)
     ("-b" "Bisync options" zr-rclone-set-bisync-options :transient t)]])

(transient-define-prefix zr-rclone-menu ()
  "Control RC tasks and send file lists to external consumers."
  [:description zr-rclone--panel-description
   ["Connection"
    ("c" "Connect (C-u: local)" zr-rclone-connect :transient t)
    ("r" "Reconnect" zr-rclone-reconnect :transient t)
    ("d" "Disconnect" zr-rclone-disconnect :transient t)
    ("J" "Switch connection" zr-rclone-select-connection :transient t)
    ("a" "RC credentials" zr-rclone-set-credentials :transient t)
    ("e" "HTTP / CLI" zr-rclone-toggle-transport :transient t)
    ("L" "Local / server paths" zr-rclone-toggle-local :transient t)
    ("f" "Config path" zr-rclone-set-config-file :transient t)
    ("S" "Start local rcd" zr-rclone-start-daemon :transient t)
    ("Q" "Stop owned rcd" zr-rclone-stop-daemon :transient t)]
   ["Paths and transfers"
    ("p" (lambda () (format "Current: %s"
                            (truncate-string-to-width
                             (or (zr-rclone-connection-current-path (zr-rclone--context))
                                 "[unset]") 14 nil nil "…")))
     zr-rclone-cd :transient t)
    ("t" (lambda () (format "Target: %s"
                            (truncate-string-to-width
                             (or (zr-rclone-connection-target-path (zr-rclone--context))
                                 "[unset]") 14 nil nil "…")))
     zr-rclone-set-target :transient t)
    ("x" "Swap paths" zr-rclone-swap-paths :transient t)
    ("C" "Copy contents → target" zr-rclone-copy)
    ("R" "Move contents → target" zr-rclone-move)
    ("s" "Sync current → target" zr-rclone-sync)
    ("b" "Bisync current ↔ target" zr-rclone-bisync)
    ("B" "Bisync init / resync" zr-rclone-bisync-resync)
    ("-n" (lambda () (format "Dry run: %s"
                             (if (zr-rclone-connection-dry-run (zr-rclone--context))
                                 "on" "off")))
     zr-rclone-toggle-dry-run :transient t)
    ("-o" "Call options" zr-rclone-set-call-options :transient t)]
   ["Tasks and file lists"
    ("j" "Jobs / output / cancel" zr-rclone-jobs)
    ("!" "Temporary command" zr-rclone-command)
    (":" "Raw RC request" zr-rclone-call)
    ("l" "List → consumer" zr-rclone-send-file-list)
    ("P" "List → mpv" zr-rclone-play)
    ("-r" (lambda () (format "Recursive: %s"
                             (if (zr-rclone-connection-list-recursive (zr-rclone--context))
                                 "on" "off")))
     zr-rclone-toggle-recursive :transient t)
    ("-h" (lambda () (format "Media: %s"
                             (if (zr-rclone-connection-media-rc-serve (zr-rclone--context))
                                 "RC HTTP" "WebDAV")))
     zr-rclone-toggle-media-source :transient t)
    ("v" "Mount / WebDAV" zr-rclone-services-menu)
    ("w" "Start WebDAV" zr-rclone-serve-webdav)
    ("o" "Open current via TRAMP" zr-rclone-open-webdav)]])

;;;###autoload
(defun zr-rclone ()
  "Open the RC transient in the current buffer."
  (interactive)
  (zr-rclone--context)
  (zr-rclone-menu))

(provide 'zr-rclone)
;;; zr-rclone.el ends here
