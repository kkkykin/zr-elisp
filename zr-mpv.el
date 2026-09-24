;;; zr-mpv.el --- Control and play media with mpv -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia, processes

;;; Commentary:

;; Play local and remote media using mpv across multiple environments:
;; - Local mpv process via IPC and stdin playlist
;; - WezTerm terminal multiplexer via OSC 1337 JSON escape sequence
;; - HTTP remote control daemon via JSON POST
;; - Android Termux via m3u8 local streaming provider and Activity Manager intent
;;
;; Key features:
;; - `zr-mpv-play-dwim': Context-aware playback command for Dired, active region,
;;   file buffers, or URLs.
;; - `zr-mpv-path-transform-alist': Configurable path rewriting rules (regex or function).
;; - `zr-mpv-backend': Auto-detects the current environment (WezTerm, SSH, Android,
;;   or local desktop).
;; - IPC commands: `zr-mpv-toggle-pause', `zr-mpv-stop', `zr-mpv-next', `zr-mpv-previous'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'url)
(require 'auth-source)

(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))
(declare-function dired-current-directory "dired" (&optional localp))
(declare-function zr-wezterm-send-json "zr-wezterm" (object))

(defvar savehist-additional-variables)

(defgroup zr-mpv nil
  "Media playback with mpv."
  :group 'multimedia
  :prefix "zr-mpv-")

(defcustom zr-mpv-program "mpv"
  "Name of or path to the mpv executable."
  :type 'string
  :group 'zr-mpv)

(defcustom zr-mpv-default-arguments nil
  "Default arguments passed to mpv."
  :type '(repeat string)
  :group 'zr-mpv)

(defcustom zr-mpv-ipc-server
  (pcase system-type
    ('windows-nt "\\\\.\\pipe\\mpv-ipc")
    (_ (expand-file-name "mpv.sock" temporary-file-directory)))
  "Path to mpv IPC socket or named pipe.
If nil, the IPC server option is omitted when launching mpv."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'zr-mpv)

(defcustom zr-mpv-windows-ipc-program "powershell.exe"
  "PowerShell executable used to connect to mpv's Windows named pipe."
  :type 'string
  :group 'zr-mpv)

(defcustom zr-mpv-backend 'auto
  "Playback backend to use.
When `auto', detects between `android', `wezterm', `http', and `local'.
May also be set to a custom function accepting (FILES &optional ARGS)."
  :type '(choice (const :tag "Auto-detect" auto)
                 (const :tag "Local process" local)
                 (const :tag "WezTerm escape sequence" wezterm)
                 (const :tag "HTTP remote server" http)
                 (const :tag "Android Intent" android)
                 (function :tag "Custom function"))
  :group 'zr-mpv)

(defcustom zr-mpv-prompt-arguments nil
  "Whether to prompt for extra mpv arguments on every invocation.
When nil, extra arguments are only prompted when a prefix argument is given."
  :type 'boolean
  :group 'zr-mpv)

(defcustom zr-mpv-path-transform-alist nil
  "Alist of transformations applied to media paths before playback.
Each element has the form (REGEXP . REPLACEMENT).

REGEXP is matched against the path.
REPLACEMENT can be:
  - a replacement string (supports \\&, \\1, etc. as in `replace-match')
  - a function called with (PATH [MATCH-DATA]) returning the transformed string.

Rules are applied sequentially in order."
  :type '(repeat (cons (regexp :tag "Pattern")
                       (choice (string :tag "Replacement")
                               (function :tag "Function"))))
  :group 'zr-mpv)

(defcustom zr-mpv-media-extensions
  '("mp4" "mkv" "avi" "mov" "wmv" "flv" "webm" "m4v" "ts" "mts" "m2ts" "vob" "ogv" "rmvb"
    "mp3" "flac" "wav" "ogg" "m4a" "aac" "opus" "ape" "wma" "alac" "aiff"
    "m3u" "m3u8" "pls" "cue"
    "jpg" "jpeg" "png" "gif" "webp" "bmp" "svg" "avif")
  "List of supported media file extensions (without leading dot)."
  :type '(repeat string)
  :group 'zr-mpv)

(defcustom zr-mpv-buffer-name "*zr-mpv*"
  "Name of buffer to collect mpv process output."
  :type 'string
  :group 'zr-mpv)

(defcustom zr-mpv-http-url "http://127.0.0.1:7780/mpv/"
  "URL endpoint for the HTTP remote mpv service."
  :type 'string
  :group 'zr-mpv)

(defcustom zr-mpv-http-auth-host "mpv.caddy.local"
  "Host name to query in `auth-source' for HTTP Basic Auth credentials.
Set to nil to disable authentication lookup."
  :type '(choice (const :tag "No authentication" nil) string)
  :group 'zr-mpv)

(defcustom zr-mpv-http-origin nil
  "Custom Origin header value for HTTP requests.
If nil, defaults to ssh://<system-name> when inside an SSH session."
  :type '(choice (const :tag "Default / Auto" nil) string)
  :group 'zr-mpv)

(defcustom zr-mpv-http-extra-headers nil
  "Additional HTTP headers alist to send with HTTP backend requests."
  :type '(repeat (cons (string :tag "Header name") (string :tag "Value")))
  :group 'zr-mpv)

(defcustom zr-mpv-android-package "is.xyz.mpv.ytdl"
  "Android package name for mpv."
  :type 'string
  :group 'zr-mpv)

(defcustom zr-mpv-android-am-program "termux-am"
  "Command name or path to invoke Android Activity Manager."
  :type 'string
  :group 'zr-mpv)

(defcustom zr-mpv-android-server-timeout 10
  "Seconds before the temporary m3u8 playlist server terminates on Android.
Set to 0 to disable automatic shutdown."
  :type 'integer
  :group 'zr-mpv)

(defvar zr-mpv-args-history nil
  "Minibuffer history for extra mpv arguments.")

(defvar zr-mpv-playlist-history nil
  "Minibuffer history for played files or URLs.")

(with-eval-after-load 'savehist
  (dolist (var '(zr-mpv-args-history zr-mpv-playlist-history))
    (add-to-list 'savehist-additional-variables var)))

;;; Media Files & Path Transformations

(defun zr-mpv-media-regexp ()
  "Return a regular expression matching media file extensions."
  (concat "\\.\\(?:"
          (string-join (mapcar #'regexp-quote zr-mpv-media-extensions) "\\|")
          "\\)\\'"))

(defun zr-mpv-media-file-p (file)
  "Return non-nil if FILE has a recognized media extension."
  (when-let* ((file)
              (ext (file-name-extension file)))
    (member (downcase ext) zr-mpv-media-extensions)))

(defun zr-mpv-expand-directory (dir)
  "Find all media files in DIR recursively, sorted by version/name."
  (when (file-directory-p dir)
    (let ((files (directory-files-recursively dir (zr-mpv-media-regexp) nil nil t)))
      (sort files #'string-version-lessp))))

(defun zr-mpv-transform-path (path)
  "Transform PATH according to `zr-mpv-path-transform-alist'.
Each rule in `zr-mpv-path-transform-alist' is tried in order.
If the rule's regexp matches, the replacement is applied.
REPLACEMENT can be a string (passed to `replace-match') or a function
called with (PATH [MATCH-DATA])."
  (if (not (stringp path))
      path
    (let ((result path))
      (dolist (transform zr-mpv-path-transform-alist result)
        (when (string-match (car transform) result)
          (let ((repl (cdr transform)))
            (setq result
                  (cond
                   ((stringp repl)
                    (replace-match repl nil nil result))
                   ((functionp repl)
                    (condition-case nil
                        (funcall repl result (match-data))
                      (wrong-number-of-arguments
                       (funcall repl result))))
                   (t result)))))))))

(defun zr-mpv-normalize-files (files)
  "Normalize FILES into a flat list of transformed path or URL strings.
FILES can be a list of paths/URLs, a buffer, or a newline-delimited string."
  (let ((raw-list
         (cond
          ((null files) nil)
          ((listp files) files)
          ((stringp files)
           (split-string files "[\r\n]+" t "[ \t\r\n]+"))
          ((bufferp files)
           (with-current-buffer files
             (split-string (buffer-string) "[\r\n]+" t "[ \t\r\n]+")))
          (t (list (format "%s" files))))))
    (delq nil
          (mapcar (lambda (file)
                    (when (and (stringp file) (not (string-blank-p file)))
                      (zr-mpv-transform-path file)))
                  raw-list))))

(defun zr-mpv-format-playlist (files)
  "Format a list of normalized FILES into an M3U playlist string.
Call `zr-mpv-normalize-files' before this function to transform raw input."
  (concat "#EXTM3U\n"
          (if files (concat (string-join files "\n") "\n") "")))

(defun zr-mpv--split-args (args)
  "Normalize ARGS into a list of strings."
  (cond
   ((null args) nil)
   ((listp args) args)
   ((stringp args) (split-string-shell-command args))
   (t (list (format "%s" args)))))

(defun zr-mpv-read-arguments (&optional prompt initial)
  "Prompt the user for extra mpv command line arguments."
  (let ((input (read-shell-command (or prompt "mpv extra args: ")
                                   (or initial "")
                                   'zr-mpv-args-history)))
    (when (and (stringp input) (not (string-blank-p input)))
      (add-to-history 'zr-mpv-args-history input 100))
    input))

;;; Playback Backends

(defvar zr-mpv--temp-configs nil
  "Private mpv config files awaiting process cleanup.")

(defun zr-mpv--delete-temp-config (file)
  "Remove the private mpv config FILE, if present."
  (when file
    (when (file-exists-p file) (delete-file file))
    (setq zr-mpv--temp-configs (delete file zr-mpv--temp-configs))))

(add-hook 'kill-emacs-hook
          (lambda ()
            (dolist (file (copy-sequence zr-mpv--temp-configs))
              (ignore-errors (zr-mpv--delete-temp-config file)))))

(defun zr-mpv--format-headers (headers)
  "Normalize HEADERS into a list of \"Name: Value\" strings."
  (cond
   ((null headers) nil)
   ((stringp headers) (list headers))
   ((listp headers)
    (delq nil
          (mapcar (lambda (item)
                    (cond
                     ((consp item)
                      (format "%s: %s" (car item) (cdr item)))
                     ((stringp item) item)
                     (t nil)))
                  headers)))))

(defun zr-mpv-play-local (files &optional args headers)
  "Play FILES locally by spawning the mpv executable.
FILES is normalized via `zr-mpv-normalize-files' and passed via stdin.
ARGS specifies additional command-line arguments.
HEADERS is an optional alist or list of HTTP header strings."
  (let ((items (zr-mpv-normalize-files files)))
    (unless items
      (user-error "No files to play"))
    (let* ((formatted-headers (zr-mpv--format-headers headers))
           (extra (zr-mpv--split-args args))
           config proc)
      (unwind-protect
          (progn
            (when formatted-headers
              (setq config (make-temp-file "zr-mpv-" nil ".conf"))
              (push config zr-mpv--temp-configs)
              (set-file-modes config #o600)
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region
                 (format "http-header-fields=\"%s\"\n"
                         (string-join formatted-headers ","))
                 nil config nil 'silent)))
            (let ((cmd (append (list zr-mpv-program)
                               (when zr-mpv-ipc-server
                                 (list (concat "--input-ipc-server=" zr-mpv-ipc-server)))
                               (when config
                                 (list (concat "--include=" config)))
                               zr-mpv-default-arguments
                               extra
                               (list "--playlist=-")))
                  (buffer (get-buffer-create zr-mpv-buffer-name))
                  (playlist (zr-mpv-format-playlist items)))
              (setq proc
                    (make-process
                     :name "zr-mpv"
                     :buffer buffer
                     :command cmd
                     :connection-type 'pipe
                     :coding 'utf-8-unix
                     :noquery t
                     :sentinel
                     (lambda (p _event)
                       (when (memq (process-status p) '(exit signal))
                         (when config (zr-mpv--delete-temp-config config))
                         (unless (zerop (process-exit-status p))
                           (message "mpv exited with code %s; see %s"
                                    (process-exit-status p)
                                    (buffer-name (process-buffer p))))))))
              (process-send-string proc playlist)
              (process-send-eof proc)
              proc))
        (unless proc
          (when config (zr-mpv--delete-temp-config config)))))))

(defun zr-mpv-play-wezterm (files &optional args headers)
  "Play FILES via WezTerm terminal escape sequence.
Encodes payload with `args' and `stdin' and sends via `zr-wezterm-send-json'.
HEADERS is an optional alist or list of HTTP header strings."
  (let ((items (zr-mpv-normalize-files files)))
    (unless items
      (user-error "No files to play"))
    (unless (fboundp 'zr-wezterm-send-json)
      (require 'zr-wezterm))
    (let* ((formatted-headers (zr-mpv--format-headers headers))
           (header-args (when formatted-headers
                          (list (format "--http-header-fields=%s"
                                        (string-join formatted-headers ",")))))
           (all-args (append zr-mpv-default-arguments (zr-mpv--split-args args) header-args))
           (msg `((args . ,(vconcat all-args))
                  (type . "mpv")
                  (stdin . ,(string-join items "\n")))))
      (zr-wezterm-send-json msg))))

(defun zr-mpv--auth-header (host)
  "Return Basic Authorization header string for HOST using `auth-source', or nil."
  (when-let* ((host)
              (cred (auth-source-user-and-password host))
              (user (car cred))
              (secret (cadr cred)))
    (concat "Basic "
            (base64-encode-string
             (encode-coding-string (format "%s:%s" user secret) 'utf-8) t))))

(defun zr-mpv-play-http (files &optional args headers)
  "Play FILES via HTTP POST to remote mpv daemon at `zr-mpv-http-url'.
HEADERS is an optional alist or list of HTTP header strings."
  (let ((items (zr-mpv-normalize-files files)))
    (unless items
      (user-error "No files to play"))
    (let* ((formatted-headers (zr-mpv--format-headers headers))
           (header-args (when formatted-headers
                          (list (format "--http-header-fields=%s"
                                        (string-join formatted-headers ",")))))
           (all-args (append zr-mpv-default-arguments (zr-mpv--split-args args) header-args))
           (payload (json-serialize `((args . ,(vconcat all-args))
                                      (stdin . ,(string-join items "\n")))))
           (req-headers `(("Content-Type" . "application/json")))
           (origin (or zr-mpv-http-origin
                       (when (or (getenv "SSH_CONNECTION") (getenv "SSH_CLIENT"))
                         (concat "ssh://" (system-name))))))
      (when origin
        (push `("Origin" . ,(encode-coding-string origin 'utf-8)) req-headers))
      (when-let* ((auth (zr-mpv--auth-header zr-mpv-http-auth-host)))
        (push `("Authorization" . ,auth) req-headers))
      (when zr-mpv-http-extra-headers
        (setq req-headers (append req-headers zr-mpv-http-extra-headers)))
      (let ((url-request-method "POST")
            (url-request-extra-headers req-headers)
            (url-request-data (encode-coding-string payload 'utf-8 t)))
        (url-retrieve
         zr-mpv-http-url
         (lambda (status)
           (if (plist-get status :error)
               (message "zr-mpv HTTP error: %S" (plist-get status :error))
             (message "zr-mpv: playback started on %s" zr-mpv-http-url)))
         nil t)))))

(defun zr-mpv-serve-playlist (files &optional timeout)
  "Start a temporary HTTP server providing an M3U8 playlist of FILES.
The server automatically terminates after TIMEOUT seconds (default
`zr-mpv-android-server-timeout').  Returns the server process."
  (let* ((items (or (zr-mpv-normalize-files files)
                    (user-error "No files to play")))
         (body (zr-mpv-format-playlist items))
         (encoded-body (encode-coding-string body 'utf-8 t))
         (body-bytes (string-bytes encoded-body))
         (response (concat "HTTP/1.1 200 OK\r\n"
                           "Content-Type: application/vnd.apple.mpegurl\r\n"
                           (format "Content-Length: %d\r\n" body-bytes)
                           "Connection: close\r\n"
                           "\r\n"
                           encoded-body))
         server-proc)
    (setq server-proc
          (make-network-process
           :name "zr-mpv-m3u8-provider"
           :server t
           :host "127.0.0.1"
           :service t
           :family 'ipv4
           :sentinel
           (lambda (proc event)
             (when (string-prefix-p "open from" event)
               (condition-case nil
                   (progn
                     (process-send-string proc response)
                     (delete-process proc))
                 (error nil))))))
    (let ((tout (or timeout zr-mpv-android-server-timeout 10)))
      (when (> tout 0)
        (run-at-time tout nil
                     (lambda ()
                       (when (process-live-p server-proc)
                         (delete-process server-proc))))))
    server-proc))

(defun zr-mpv-play-android (files &optional _args _headers)
  "Play FILES on Android via mpv-android and `zr-mpv-android-am-program'."
  (let* ((server (zr-mpv-serve-playlist files))
         (port (process-contact server :service))
         (url (format "http://127.0.0.1:%d" port)))
    (apply #'call-process
           zr-mpv-android-am-program nil 0 nil
           "start" "-a" "android.intent.action.VIEW"
           "-t" "video/any"
           "-p" zr-mpv-android-package
           "-d" url
           nil)))

;;; Backend Selection & Dispatcher

(defun zr-mpv-detect-backend ()
  "Detect the appropriate playback backend for the current environment.
Returns one of `local', `wezterm', `http', or `android'."
  (cond
   ((or (eq system-type 'android)
        (and (executable-find "termux-am")
             (not (getenv "DISPLAY"))
             (not (getenv "WAYLAND_DISPLAY"))))
    'android)
   ((string= (or (getenv "TERM_PROGRAM" (selected-frame))
                 (getenv "TERM_PROGRAM"))
             "WezTerm")
    'wezterm)
   ((or (getenv "SSH_CONNECTION" (selected-frame))
        (getenv "SSH_CLIENT" (selected-frame))
        (getenv "SSH_CONNECTION")
        (getenv "SSH_CLIENT"))
    'http)
   (t 'local)))

(defun zr-mpv-get-backend ()
  "Return the active backend symbol or function."
  (if (eq zr-mpv-backend 'auto)
      (zr-mpv-detect-backend)
    zr-mpv-backend))

;;;###autoload
(defun zr-mpv-play (files &optional args backend headers)
  "Play FILES using BACKEND with optional ARGS and HEADERS.
FILES can be a list of paths/URLs or a newline-separated string.
ARGS can be a list of strings or a shell command argument string.
BACKEND defaults to `zr-mpv-backend' (or auto-detected).
HEADERS is an optional alist of (NAME . VALUE) or list of \"Name: Value\"
HTTP header strings to pass to mpv."
  (let ((be (or backend (zr-mpv-get-backend))))
    (pcase be
      ('local
       (if headers
           (zr-mpv-play-local files args headers)
         (zr-mpv-play-local files args)))
      ('wezterm
       (if headers
           (zr-mpv-play-wezterm files args headers)
         (zr-mpv-play-wezterm files args)))
      ('http
       (if headers
           (zr-mpv-play-http files args headers)
         (zr-mpv-play-http files args)))
      ('android
       (if headers
           (zr-mpv-play-android files args headers)
         (zr-mpv-play-android files args)))
      ((pred functionp)
       (condition-case nil
           (if headers
               (funcall be files args headers)
             (funcall be files args))
         (wrong-number-of-arguments
          (funcall be files args))))
      (_ (error "Unknown zr-mpv backend: %S" be)))))

;;; IPC Control

(defun zr-mpv--ipc-send-windows (payload server)
  "Send UTF-8 JSON PAYLOAD to the Windows named pipe SERVER.
Use PowerShell's .NET pipe client; Emacs pipe processes are anonymous.
Pass the pipe name and payload as JSON on stdin, never as script code."
  (let ((prefix "\\\\.\\pipe\\"))
    (unless (string-prefix-p prefix server t)
      (error "Expected a Windows named pipe path: %s" server))
    (with-temp-buffer
      (insert (json-serialize `((pipe . ,(substring server (length prefix)))
				(payload . ,payload))))
      (let* ((coding-system-for-read 'utf-8-unix)
             (coding-system-for-write 'utf-8-unix)
             (status
              (call-process-region
               (point-min) (point-max) zr-mpv-windows-ipc-program t t nil
               "-NoProfile" "-NonInteractive" "-Command"
               (concat
                "$ErrorActionPreference = 'Stop'; "
                "[Console]::InputEncoding = [Text.UTF8Encoding]::new($false); "
                "$request = ConvertFrom-Json ([Console]::In.ReadToEnd()); "
                "$pipe = [IO.Pipes.NamedPipeClientStream]::new("
                "'.', [string]$request.pipe, [IO.Pipes.PipeDirection]::Out); "
                "try { $pipe.Connect(1000); "
                "$bytes = [Text.Encoding]::UTF8.GetBytes([string]$request.payload); "
                "$pipe.Write($bytes, 0, $bytes.Length); $pipe.Flush() } "
                "finally { $pipe.Dispose() }"))))
        (unless (eq status 0)
          (error "Windows IPC helper failed (%s): %s"
                 status (string-trim (buffer-string))))
        t))))

(defun zr-mpv-ipc-send (command &optional ipc-server)
  "Send JSON-IPC COMMAND to mpv IPC socket/pipe.
COMMAND is a list of strings/values, e.g. (\'(\"cycle\" \"pause\")).
Returns non-nil on success."
  (let ((server (or ipc-server zr-mpv-ipc-server)))
    (unless server
      (user-error "`zr-mpv-ipc-server' is not configured"))
    (let ((payload (concat (json-serialize `((command . ,(vconcat command)))) "\n")))
      (condition-case err
          (if (eq system-type 'windows-nt)
              (zr-mpv--ipc-send-windows payload server)
            (let ((proc (make-network-process
                         :name "zr-mpv-ipc"
                         :family 'local
                         :coding 'utf-8-unix
                         :noquery t
                         :service (expand-file-name server))))
              (unwind-protect
                  (progn (process-send-string proc payload) t)
                (delete-process proc))))
        (error
         (message "Cannot send to mpv IPC server %s: %s"
                  server (error-message-string err))
         nil)))))

;;;###autoload
(defun zr-mpv-toggle-pause ()
  "Toggle playback pause in mpv via IPC."
  (interactive)
  (zr-mpv-ipc-send '("cycle" "pause")))

;;;###autoload
(defun zr-mpv-stop ()
  "Stop playback and quit mpv via IPC."
  (interactive)
  (zr-mpv-ipc-send '("quit")))

;;;###autoload
(defun zr-mpv-next ()
  "Skip to next playlist track in mpv via IPC."
  (interactive)
  (zr-mpv-ipc-send '("playlist-next")))

;;;###autoload
(defun zr-mpv-previous ()
  "Skip to previous playlist track in mpv via IPC."
  (interactive)
  (zr-mpv-ipc-send '("playlist-prev")))

;;; Context Collection & DWIM

(defun zr-mpv-collect-dwim-files ()
  "Collect files or URLs from the current context for DWIM playback."
  (cond
   ;; Active region: each line is treated as a file or URL
   ((use-region-p)
    (split-string (buffer-substring-no-properties
                   (region-beginning) (region-end))
                  "[\r\n]+" t "[ \t\r\n]+"))
   ;; Dired mode: marked files or directory at point
   ((derived-mode-p 'dired-mode)
    (let ((marked (or (ignore-errors (dired-get-marked-files nil nil nil nil nil))
                      (when (fboundp 'dired-current-directory)
                        (list (dired-current-directory)))
                      (list default-directory))))
      (cl-mapcan
       (lambda (item)
         (if (file-directory-p item)
             (zr-mpv-expand-directory item)
           (list item)))
       marked)))
   ;; Buffer visiting a file
   (buffer-file-name
    (list buffer-file-name))
   ;; Thing at point: URL
   ((thing-at-point 'url t)
    (list (thing-at-point 'url t)))
   ;; Thing at point: filename
   ((thing-at-point 'filename t)
    (let ((fn (thing-at-point 'filename t)))
      (when (or (zr-mpv-media-file-p fn) (file-exists-p fn))
        (list fn))))
   (t nil)))

;;;###autoload
(defun zr-mpv-play-dwim (&optional arg)
  "Play media from the current context (Dired, region, buffer, or point).
With prefix argument ARG (or when `zr-mpv-prompt-arguments' is non-nil),
prompt for extra mpv arguments."
  (interactive "P")
  (let* ((files (zr-mpv-collect-dwim-files))
         (extra-args (when (or arg zr-mpv-prompt-arguments)
                       (zr-mpv-read-arguments))))
    (unless files
      (setq files (list (read-file-name "Play file or directory: "))))
    (zr-mpv-play files extra-args)))

;;;###autoload
(defun zr-mpv-play-file (file &optional args)
  "Prompt for a FILE or directory and play it with optional ARGS."
  (interactive
   (list (read-file-name "Play media file: ")
         (when (or current-prefix-arg zr-mpv-prompt-arguments)
           (zr-mpv-read-arguments))))
  (let ((target (if (file-directory-p file)
                    (zr-mpv-expand-directory file)
                  (list file))))
    (zr-mpv-play target args)))

;;;###autoload
(defun zr-mpv-play-url (url &optional args)
  "Prompt for a media URL and play it with optional ARGS."
  (interactive
   (list (read-string "Play media URL: " (thing-at-point 'url t))
         (when (or current-prefix-arg zr-mpv-prompt-arguments)
           (zr-mpv-read-arguments))))
  (zr-mpv-play (list url) args))

(provide 'zr-mpv)
;;; zr-mpv.el ends here
