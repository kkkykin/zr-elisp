;;; zr-tramp-webdav.el --- Portable WebDAV for TRAMP -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, files

;;; Commentary:

;; WebDAV file access without GVFS, FUSE, or a remote shell:
;;
;;   (require 'zr-tramp-webdav)
;;   (setq zr-tramp-webdav-backend 'curl) ; Default; alternatively `url'.
;;   (setq zr-tramp-webdav-curl-arguments '("--ipv4"))
;;   (find-file "/webdavs:alice@example.org:/dav/notes.txt")
;;   (dired "/webdav:alice@localhost#8080:/dav/")
;;
;; `webdav' uses HTTP; `webdavs' uses HTTPS with certificate verification.
;; Paths are ordinary file names, not URL-encoded strings.  An explicit
;; port uses TRAMP's #PORT syntax.  The server's WebDAV endpoint, including
;; any Nextcloud remote.php/dav/files/USER prefix, belongs in the path.
;; These methods leave the GVFS `dav' and `davs' methods available.
;;
;; HTTP Basic credentials are read from `auth-source', for example:
;;   machine example.org port 443 login alice password APP_PASSWORD
;; A port named webdav/webdavs is also accepted.  If no entry is found,
;; an interactive request prompts after a Basic authentication challenge.
;; `zr-tramp-webdav-extra-headers' also accepts a function of the remote
;; file name, useful for bearer tokens and per-server configuration.
;;
;; Supports visiting/saving files, completion, Dired, directory creation,
;; deletion, copying and renaming, including transfers to/from local files.
;; Directory listings use PROPFIND; same-server copies/moves use COPY/MOVE.
;; File contents are staged locally to preserve Emacs coding conventions.
;; ETags (or Last-Modified) guard saves and read/modify/write appends when
;; the server supplies them.  Exclusive creation uses If-None-Match.
;; Backups use copying so the original resource keeps its write validator.
;;
;; WebDAV does not expose a POSIX shell, symlinks, Unix modes or ownership.
;; Modes/IDs are synthetic; permission checks are estimates, with the
;; server enforcing access on each request.  Setting modes/times is a
;; no-op.  DAV LOCK, trash, file notifications, TRAMP multi-hop, and
;; cross-server directory renames are not implemented.  Requests are
;; synchronous and file contents pass through memory.  Both transports
;; support Basic/custom-header authentication, not Digest/NTLM negotiation.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'subr-x)
(require 'tramp)
(require 'url)
(require 'url-http)
(require 'xml)

(defgroup zr-tramp-webdav nil
  "Portable WebDAV file access through TRAMP."
  :group 'tramp)

(defcustom zr-tramp-webdav-backend 'curl
  "HTTP transport used for WebDAV requests."
  :type '(choice (const :tag "curl executable" curl)
                 (const :tag "Emacs URL library" url)))

(defcustom zr-tramp-webdav-curl-program "curl"
  "Executable used when `zr-tramp-webdav-backend' is `curl'."
  :type 'file)

(defcustom zr-tramp-webdav-curl-arguments nil
  "Extra command-line arguments for curl, as a list or a function.
The function is called with the remote file name and must return
a list of strings.  Arguments are inserted before the request URL."
  :type '(choice (repeat string) function))

(defcustom zr-tramp-webdav-timeout 30
  "Maximum number of seconds to wait for one HTTP request."
  :type 'number)

(defcustom zr-tramp-webdav-extra-headers nil
  "Extra HTTP headers, as an alist or a function of the remote file name.
The function must return an alist of (NAME . VALUE) strings.  An
Authorization header takes precedence over Basic authentication.
Headers are never forwarded to a different origin on redirects."
  :type '(choice (alist :key-type string :value-type string) function))

(defvar zr-tramp-webdav--passwords (make-hash-table :test #'equal)
  "Credentials entered interactively, keyed by remote identity.")

(defvar-local zr-tramp-webdav--visited nil
  "File name and HTTP validators recorded when visiting or saving a file.")

(defvar-local zr-tramp-webdav--pending-move nil
  "Original and staged metadata during a `file-precious-flag' save.")

;; `find-file' chooses a major mode after insert-file-contents has run.
;; Changing modes must not discard the version that was actually read.
(put 'zr-tramp-webdav--visited 'permanent-local t)
(put 'zr-tramp-webdav--pending-move 'permanent-local t)

(defconst zr-tramp-webdav--propfind-body
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:propfind xmlns:D=\"DAV:\"><D:prop><D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:creationdate/><D:getetag/></D:prop></D:propfind>"
  "Properties needed for file attributes and conditional writes.")

(defun zr-tramp-webdav-file-name-p (file)
  "Whether FILE, a TRAMP vector or file name, uses this backend."
  (when-let* ((vec (tramp-ensure-dissected-file-name file)))
    (member (tramp-file-name-method vec) '("webdav" "webdavs"))))

(defun zr-tramp-webdav--expand-file-name (name &optional directory)
  "Expand NAME relative to DIRECTORY without using a remote shell."
  (let ((file (if (file-name-absolute-p name)
                  name
                (concat (file-name-as-directory
                         (or directory default-directory)) name))))
    (when (and (tramp-tramp-file-p file)
               (tramp-file-name-hop (tramp-dissect-file-name file)))
      (signal 'file-error (list "WebDAV does not support TRAMP multi-hop" file)))
    (tramp-handle-expand-file-name name directory)))

(defun zr-tramp-webdav--url (vec)
  "Return the HTTP URL for TRAMP vector VEC, without credentials."
  (let* ((secure (equal (tramp-file-name-method vec) "webdavs"))
         (host (tramp-file-name-host vec))
         (port (or (tramp-file-name-port vec) (if secure "443" "80")))
         (path (tramp-file-name-unquote-localname vec)))
    (when (tramp-file-name-hop vec)
      (signal 'file-error '("WebDAV does not support TRAMP multi-hop")))
    (concat (if secure "https://" "http://")
            (if (string-search ":" host) (concat "[" host "]") host)
            ":" port
            (mapconcat #'url-hexify-string (split-string path "/") "/"))))

(defun zr-tramp-webdav--origin (url)
  "Return the scheme, host and effective port of URL."
  (let ((parsed (url-generic-parse-url url)))
    (list (downcase (or (url-type parsed) ""))
          (downcase (or (url-host parsed) "")) (url-port parsed))))

(defun zr-tramp-webdav--header (headers name)
  "Return the value of NAME in HEADERS, ignoring case."
  (cdr (assoc-string name headers t)))

(defun zr-tramp-webdav--check-headers (headers)
  "Validate request HEADERS and return them."
  (dolist (header headers)
    (unless (and (consp header) (stringp (car header)) (stringp (cdr header))
                 (string-match-p "\\`[!#$%&'*+.^_`|~A-Za-z0-9-]+\\'" (car header))
                 (not (string-match-p "[\r\n\0]" (cdr header))))
      (signal 'file-error '("Invalid WebDAV HTTP header"))))
  headers)

(defun zr-tramp-webdav--merge-headers (&rest lists)
  "Merge header LISTS, keeping the first value for each name."
  (let (result)
    (dolist (header (zr-tramp-webdav--check-headers (apply #'append lists)))
      (unless (assoc-string (car header) result t)
        ;; url-http recognizes this spelling when suppressing its own auth.
        (push (if (string-equal (downcase (car header)) "authorization")
                  (cons "Authorization" (cdr header)) header) result)))
    (nreverse result)))

(defun zr-tramp-webdav--authorization (vec &optional prompt)
  "Return Basic authorization for VEC, optionally allowing PROMPT."
  (let* ((key (tramp-make-tramp-file-name vec 'noloc))
         (host (tramp-file-name-host vec))
         (port (number-to-string (nth 2 (zr-tramp-webdav--origin
                                        (zr-tramp-webdav--url vec)))))
         (user (tramp-file-name-user-domain vec))
         (entry (car (auth-source-search
                      :host host :port (list port (tramp-file-name-method vec))
                      :user (if (string-empty-p (or user "")) t user)
                      :require '(:user :secret) :max 1)))
         (secret (plist-get entry :secret))
         (credentials (or (gethash key zr-tramp-webdav--passwords)
                          (when entry
                            (cons (plist-get entry :user)
                                  (if (functionp secret) (funcall secret) secret))))))
    (when (and (not credentials) prompt (not noninteractive))
      (setq credentials
            (cons (if (string-empty-p (or user ""))
                      (read-string (format "WebDAV user for %s: " host))
                    user)
                  (read-passwd (format "WebDAV password for %s: " host))))
      (puthash key credentials zr-tramp-webdav--passwords))
    (when credentials
      (concat "Basic "
              (base64-encode-string
               (encode-coding-string
                (concat (car credentials) ":" (cdr credentials)) 'utf-8) t)))))

(defun zr-tramp-webdav--parse-headers (text)
  "Parse HTTP header TEXT, returning (:status CODE :headers ALIST).
Use the final header block, skipping proxy and informational responses."
  (let (status headers)
    (dolist (line (split-string text "\r?\n"))
      (cond
       ((string-match "\\`HTTP/[0-9.]+ +\\([0-9][0-9][0-9]\\)\\(?: \\|\\'\\)" line)
        (setq status (string-to-number (match-string 1 line)) headers nil))
       ((string-match "\\`\\([^: \t]+\\):[ \t]*\\(.*\\)" line)
        (push (cons (downcase (match-string 1 line))
                    (string-trim (match-string 2 line))) headers))))
    (unless status
      (signal 'file-error '("Invalid HTTP response from WebDAV server")))
    (list :status status :headers (nreverse headers))))

(defun zr-tramp-webdav--url-request (_file method url headers data)
  "Send METHOD to URL with HEADERS and byte string DATA using `url'."
  (let ((default-directory tramp-compat-temporary-file-directory)
        (url-request-method method)
        (url-request-extra-headers
         ;; An explicit empty field prevents url-http from independently
         ;; prompting/retrying authentication.  Both transports use our
         ;; common auth-source and challenge handling instead.
         (if (assoc-string "Authorization" headers t) headers
           (cons '("Authorization" . "") headers)))
        (url-request-data data)
        (url-request-noninteractive t)
        (url-max-redirections 0)
        (url-http-attempt-keepalives nil)
        (url-mime-encoding-string nil)
        (url-automatic-caching nil)
        (coding-system-for-read 'no-conversion)
        (coding-system-for-write 'no-conversion)
        (deadline (+ (float-time) zr-tramp-webdav-timeout))
        buffer done callback-status)
    (unwind-protect
        (progn
          (setq buffer
                (url-retrieve
                 url (lambda (status)
                       (setq callback-status status done t)) nil t t))
          (unless (buffer-live-p buffer)
            (signal 'file-error (list "Cannot open WebDAV URL" url)))
          (while (and (not done) (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (unless done
            (signal 'file-error (list "WebDAV request timed out" url)))
          (with-current-buffer buffer
            (goto-char (point-min))
            (unless (re-search-forward "\r?\n\r?\n" nil t)
              (signal 'file-error (list "Incomplete WebDAV HTTP response" url)))
            (let* ((body-start (point))
                   (response (zr-tramp-webdav--parse-headers
                              (buffer-substring-no-properties
                               (point-min) body-start))))
              (when (and (plist-get callback-status :error)
                         (< (plist-get response :status) 300))
                (signal 'file-error (list "WebDAV transport failed" url)))
              (plist-put response :body
                         (buffer-substring-no-properties body-start (point-max))))))
      (when (buffer-live-p buffer)
        (when-let* ((process (get-buffer-process buffer)))
          (delete-process process))
        (kill-buffer buffer)))))

(defun zr-tramp-webdav--read-bytes (file)
  "Read FILE as an unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun zr-tramp-webdav--write-bytes (data file)
  "Write byte string DATA to local FILE without conversion."
  (let ((coding-system-for-write 'no-conversion)
        (file-name-handler-alist nil)
        (write-region-annotate-functions nil)
        (write-region-post-annotation-function nil)
        (create-lockfiles nil))
    (write-region data nil file nil 'silent)))

(defun zr-tramp-webdav--curl-arguments (file)
  "Return extra curl command-line arguments for FILE."
  (let ((args (if (functionp zr-tramp-webdav-curl-arguments)
                  (funcall zr-tramp-webdav-curl-arguments file)
                zr-tramp-webdav-curl-arguments)))
    (unless (and (listp args) (cl-every #'stringp args))
      (signal 'file-error '("WebDAV curl arguments must be a list of strings")))
    args))

(defun zr-tramp-webdav--curl-request (file method url headers data)
  "Send METHOD to URL with HEADERS and byte string DATA using curl."
  (let* ((default-directory tramp-compat-temporary-file-directory)
         (request-file (make-temp-file "zr-webdav-headers-"))
         (response-file (make-temp-file "zr-webdav-response-"))
         (error-file (make-temp-file "zr-webdav-error-"))
         (data-file (and data (make-temp-file "zr-webdav-data-")))
         (coding-system-for-read 'no-conversion)
         (coding-system-for-write 'no-conversion))
    (unwind-protect
        (with-temp-buffer
          (set-buffer-multibyte nil)
          ;; Private header files keep credentials out of the process list.
          (zr-tramp-webdav--write-bytes
           (encode-coding-string
            (mapconcat (lambda (h) (concat (car h) ": " (cdr h))) headers "\n")
            'utf-8) request-file)
          (when data (zr-tramp-webdav--write-bytes data data-file))
          (let ((status
                 (apply #'call-process zr-tramp-webdav-curl-program
                        nil (list t error-file) nil
                        (append
                         (list "--disable" "--silent" "--show-error" "--globoff"
                               "--proto" "=http,https" "--request" method
                               "--max-time" (number-to-string zr-tramp-webdav-timeout)
                               "--header" (concat "@" request-file)
                               "--dump-header" response-file)
                         (when data (list "--data-binary" (concat "@" data-file)))
                         (zr-tramp-webdav--curl-arguments file)
                         (list "--url" url)))))
            (unless (equal status 0)
              (signal 'file-error
                      (list "WebDAV curl request failed"
                            (string-trim (zr-tramp-webdav--read-bytes error-file)))))
            (plist-put (zr-tramp-webdav--parse-headers
                        (zr-tramp-webdav--read-bytes response-file))
                       :body (buffer-string))))
      (dolist (temp-file (list request-file response-file error-file data-file))
        (when temp-file (delete-file temp-file))))))

(defun zr-tramp-webdav--request (file method &optional headers data)
  "Send a WebDAV METHOD request for FILE with HEADERS and DATA.
Return a plist containing :status, :headers, :body and the final :url.
HTTP error codes are left to the caller; transport errors are signaled."
  (when non-essential (throw 'non-essential 'non-essential))
  (unless (and (numberp zr-tramp-webdav-timeout) (> zr-tramp-webdav-timeout 0))
    (signal 'file-error '("WebDAV timeout must be positive")))
  (let* ((vec (tramp-dissect-file-name (expand-file-name file)))
         (url (zr-tramp-webdav--url vec))
         (origin (zr-tramp-webdav--origin url))
         (extra (if (functionp zr-tramp-webdav-extra-headers)
                    (funcall zr-tramp-webdav-extra-headers file)
                  zr-tramp-webdav-extra-headers))
         (headers (zr-tramp-webdav--merge-headers
                   headers extra '(("Accept-Encoding" . "identity"))))
         (authorization (or (zr-tramp-webdav--header headers "Authorization")
                            (zr-tramp-webdav--authorization vec)))
         (transport (pcase zr-tramp-webdav-backend
                      ('url #'zr-tramp-webdav--url-request)
                      ('curl #'zr-tramp-webdav--curl-request)
                      (_ (signal 'file-error '("Unknown WebDAV backend")))))
         (redirects 0)
         response finished)
    (when (and authorization (not (assoc-string "Authorization" headers t)))
      (push (cons "Authorization" authorization) headers))
    (zr-tramp-webdav--check-headers headers)
    (while (not finished)
      (setq response (funcall transport file method url headers data))
      (let ((status (plist-get response :status)))
        (cond
         ((and (= status 401) (not authorization)
               (let ((case-fold-search t))
                 (string-match-p
                  "\\bbasic\\b" (or (zr-tramp-webdav--header
                                        (plist-get response :headers)
                                        "www-authenticate") "")))
               (setq authorization (zr-tramp-webdav--authorization vec t)))
          (push (cons "Authorization" authorization) headers))
         ((memq status '(301 302 307 308))
          (let* ((location (zr-tramp-webdav--header
                            (plist-get response :headers) "location"))
                 (next (and location (url-expand-file-name location url)))
                 (parsed (and next (url-generic-parse-url next))))
            (unless (and next (< redirects 5)
                         (equal origin (zr-tramp-webdav--origin next))
                         (not (url-user parsed)) (not (url-password parsed)))
              (signal 'file-error
                      (list "Unsafe or excessive WebDAV redirect" file)))
            (setq redirects (1+ redirects) url next)))
         (t (setq finished t)))))
    (when (= (plist-get response :status) 401)
      (remhash (tramp-make-tramp-file-name vec 'noloc) zr-tramp-webdav--passwords))
    (plist-put response :url url)))

(defun zr-tramp-webdav--http-error (response file &optional exclusive)
  "Signal an appropriate file error for RESPONSE concerning FILE.
EXCLUSIVE makes HTTP 412 a `file-already-exists' error."
  (let ((status (plist-get response :status)))
    (signal (cond ((memq status '(404 410)) 'file-missing)
                  ((and exclusive (= status 412)) 'file-already-exists)
                  (t 'file-error))
            (list (if (= status 412)
                      "WebDAV precondition failed; file already exists or changed on server"
                    (format "WebDAV request failed: HTTP %s" status)) file))))

(defun zr-tramp-webdav--xml (response)
  "Parse the XML body of RESPONSE with namespace expansion."
  (condition-case err
      (with-temp-buffer
        (insert (decode-coding-string (plist-get response :body) 'utf-8))
        (let ((root (car (xml-parse-region (point-min) (point-max) nil nil t))))
          (unless (equal (car-safe root) '("DAV:" . "multistatus"))
            (error "Expected DAV:multistatus"))
          root))
    (error (signal 'file-error
                   (list "Invalid WebDAV XML response" (error-message-string err))))))

(defun zr-tramp-webdav--children (node name)
  "Return the DAV children of NODE with local NAME."
  (cl-remove-if-not (lambda (child) (equal (car-safe child) (cons "DAV:" name)))
                    (cddr node)))

(defun zr-tramp-webdav--text (node)
  "Return direct text children of XML NODE, with outer whitespace removed."
  (string-trim (mapconcat #'identity (cl-remove-if-not #'stringp (cddr node)) "")))

(defun zr-tramp-webdav--child-text (node name)
  "Return text from the first DAV child of NODE with NAME."
  (zr-tramp-webdav--text (car (zr-tramp-webdav--children node name))))

(defun zr-tramp-webdav--status (node)
  "Return the HTTP status in DAV NODE, or nil if it is absent."
  (let ((text (zr-tramp-webdav--child-text node "status")))
    (when (string-match "HTTP/[0-9.]+ +\\([0-9][0-9][0-9]\\)" text)
      (string-to-number (match-string 1 text)))))

(defun zr-tramp-webdav--time (text)
  "Parse HTTP or ISO date TEXT, returning nil for an unknown date."
  (unless (string-empty-p (or text ""))
    (ignore-errors (date-to-time text))))

(defun zr-tramp-webdav--href-path (href base)
  "Decode an HTTP HREF relative to BASE, or nil for another origin.
Encoded slashes and dot components are rejected to preserve hierarchy."
  (unless (string-empty-p href)
    (let* ((url (url-expand-file-name href base))
           (parsed (url-generic-parse-url url))
           (path (car (url-path-and-query parsed))))
      (when (and (equal (zr-tramp-webdav--origin url)
                        (zr-tramp-webdav--origin base))
                 (not (url-user parsed)) (not (url-password parsed))
                 (not (let ((case-fold-search t))
                        (string-match-p "%2f\\|%00" path))))
        (setq path (decode-coding-string
                    (url-unhex-string (encode-coding-string path 'utf-8)) 'utf-8))
        (unless (cl-intersection '("." "..") (split-string path "/") :test #'equal)
          (directory-file-name path))))))

(defun zr-tramp-webdav--entries (response)
  "Return metadata entries parsed from a PROPFIND RESPONSE."
  (let (entries)
    (dolist (node (zr-tramp-webdav--children (zr-tramp-webdav--xml response) "response"))
      (when-let* ((path (zr-tramp-webdav--href-path
                        (zr-tramp-webdav--child-text node "href")
                        (plist-get response :url))))
        (let (properties success)
          (dolist (propstat (zr-tramp-webdav--children node "propstat"))
            (when (equal (zr-tramp-webdav--status propstat) 200)
              (setq success t
                    properties
                    (append properties
                            (cddr (car (zr-tramp-webdav--children propstat "prop")))))))
          (let* ((prop (cons '("DAV:" . "prop") (cons nil properties)))
                 (modified (zr-tramp-webdav--child-text prop "getlastmodified"))
                 (etag (zr-tramp-webdav--child-text prop "getetag")))
            (push (list :path path
                        :status (or (zr-tramp-webdav--status node) (if success 200 403))
                        :directory (and (zr-tramp-webdav--children
                                         (car (zr-tramp-webdav--children prop "resourcetype"))
                                         "collection") t)
                        :size (string-to-number (zr-tramp-webdav--child-text prop "getcontentlength"))
                        :mtime (zr-tramp-webdav--time modified)
                        :modified (unless (string-empty-p modified) modified)
                        :ctime (zr-tramp-webdav--time (zr-tramp-webdav--child-text prop "creationdate"))
                        :etag (unless (string-empty-p etag) etag)) entries)))))
    (nreverse entries)))

(defun zr-tramp-webdav--propfind (file depth)
  "Retrieve WebDAV metadata for FILE at DEPTH, returning the response."
  (zr-tramp-webdav--request
   file "PROPFIND" `(("Depth" . ,depth) ("Content-Type" . "application/xml; charset=utf-8"))
   zr-tramp-webdav--propfind-body))

(defun zr-tramp-webdav--stat (file &optional fresh)
  "Return metadata for FILE, or nil if missing; FRESH bypasses the cache."
  (with-parsed-tramp-file-name (expand-file-name file) nil
    (let ((remote-file-name-inhibit-cache (or fresh remote-file-name-inhibit-cache)))
      (with-tramp-file-property v localname "zr-webdav-stat"
        (let* ((response (zr-tramp-webdav--propfind file "0"))
               (status (plist-get response :status)))
          (cond
           ((memq status '(404 410)) nil)
           ((= status 207)
            (let* ((path (zr-tramp-webdav--href-path
                          (plist-get response :url) (plist-get response :url)))
                   (entry (cl-find path (zr-tramp-webdav--entries response)
                                   :key (lambda (e) (plist-get e :path)) :test #'equal)))
              (unless entry
                (signal 'file-error (list "WebDAV response omitted requested resource" file)))
              (cond ((memq (plist-get entry :status) '(404 410)) nil)
                    ((= (plist-get entry :status) 200) entry)
                    (t (zr-tramp-webdav--http-error entry file)))))
           (t (zr-tramp-webdav--http-error response file))))))))

(defun zr-tramp-webdav--attributes (entry file id-format)
  "Convert metadata ENTRY for FILE to file attributes in ID-FORMAT."
  (when entry
    (let ((directory (plist-get entry :directory))
          (unknown (if (eq id-format 'string) "unknown" -1)))
      (list directory 1 unknown unknown '(0 0)
            (or (plist-get entry :mtime) '(0 0))
            (or (plist-get entry :ctime) '(0 0)) (plist-get entry :size)
            (if directory "drwx------" "-rw-------") nil
            (abs (sxhash-equal (directory-file-name (expand-file-name file))))
            (cons -1 (abs (sxhash-equal (file-remote-p file))))))))

(defun zr-tramp-webdav--file-attributes (file &optional id-format)
  "Implement `file-attributes' for FILE and ID-FORMAT."
  (zr-tramp-webdav--attributes (zr-tramp-webdav--stat file) file id-format))

(defun zr-tramp-webdav--directory-entries (directory)
  "Return (NAME . METADATA) pairs for immediate children of DIRECTORY."
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (with-parsed-tramp-file-name directory nil
    (with-tramp-file-property v localname "directory-webdav"
      (let ((response (zr-tramp-webdav--propfind directory "1")))
        (unless (= (plist-get response :status) 207)
          (zr-tramp-webdav--http-error response directory))
        (let* ((path (zr-tramp-webdav--href-path
                      (plist-get response :url) (plist-get response :url)))
               (prefix (file-name-as-directory path))
               (entries (zr-tramp-webdav--entries response))
               (self (cl-find path entries :key (lambda (e) (plist-get e :path)) :test #'equal))
               result)
          (unless (and self (= (plist-get self :status) 200) (plist-get self :directory))
            (signal 'file-error (list "Not an accessible WebDAV directory" directory)))
          ;; Do not query the parent: the DAV endpoint itself may be the
          ;; highest accessible collection on this server.
          (push (cons "." self) result)
          (push (cons ".." self) result)
          (dolist (entry entries)
            (let ((child (plist-get entry :path)))
              (when (and (string-prefix-p prefix child)
                         (not (equal child path))
                         (not (string-search "/" (substring child (length prefix)))))
                (unless (= (plist-get entry :status) 200)
                  (zr-tramp-webdav--http-error entry directory))
                (let ((name (substring child (length prefix))))
                  (push (cons name entry) result)
                  (tramp-set-file-property
                   v (concat (file-name-as-directory localname) name) "zr-webdav-stat" entry)))))
          (tramp-set-file-property v localname "zr-webdav-stat" self)
          (nreverse result))))))

(defun zr-tramp-webdav--directory-files-and-attributes
    (directory &optional full match nosort id-format count)
  "Implement `directory-files-and-attributes' with its usual arguments."
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (let ((entries (zr-tramp-webdav--directory-entries directory)) result)
    (dolist (entry entries)
      (when (or (not match) (string-match-p match (car entry)))
        (let ((file (concat directory (car entry))))
          (push (cons (if full file (car entry))
                      (zr-tramp-webdav--attributes (cdr entry) file id-format)) result))))
    (setq result (if nosort (nreverse result)
                   (sort result (lambda (a b) (string< (car a) (car b))))))
    (if (natnump count) (seq-take result count) result)))

(defun zr-tramp-webdav--directory-files (directory &optional full match nosort count)
  "Implement `directory-files' with its usual arguments."
  (mapcar #'car (zr-tramp-webdav--directory-files-and-attributes
                directory full match nosort nil count)))

(defun zr-tramp-webdav--all-completions (file directory)
  "Return completions for FILE in DIRECTORY."
  (tramp-skeleton-file-name-all-completions file directory
    (let ((completion-ignore-case read-file-name-completion-ignore-case))
      (all-completions
       file (mapcar (lambda (entry)
                      (if (plist-get (cdr entry) :directory)
                          (file-name-as-directory (car entry)) (car entry)))
                    (zr-tramp-webdav--directory-entries directory))))))

(defun zr-tramp-webdav--file-exists-p (file)
  "Whether FILE exists.  Preserve transport and permission errors."
  (and (zr-tramp-webdav--stat file) t))

(defun zr-tramp-webdav--file-writable-p (file)
  "Estimate whether FILE can be written; the server has the final say."
  (or (zr-tramp-webdav--file-exists-p file)
      (file-directory-p (file-name-directory (directory-file-name (expand-file-name file))))))

(defun zr-tramp-webdav--flush (file)
  "Invalidate FILE, its descendants and its parent's directory listing."
  (with-parsed-tramp-file-name (expand-file-name file) nil
    (tramp-flush-directory-properties v localname)))

(defun zr-tramp-webdav--get (file)
  "Retrieve FILE, returning a successful GET response."
  (let ((response (zr-tramp-webdav--request file "GET")))
    (unless (= (plist-get response :status) 200)
      (zr-tramp-webdav--http-error response file))
    response))

(defun zr-tramp-webdav--response-entry (response)
  "Extract file validators and modification time from HTTP RESPONSE."
  (let* ((headers (plist-get response :headers))
         (modified (zr-tramp-webdav--header headers "last-modified")))
    (list :etag (zr-tramp-webdav--header headers "etag") :modified modified
          :mtime (zr-tramp-webdav--time modified))))

(defun zr-tramp-webdav--setup-buffer ()
  "Keep the original WebDAV resource in place when making a backup."
  (when (and buffer-file-name (zr-tramp-webdav-file-name-p buffer-file-name))
    (setq-local backup-by-copying t)))

(put 'zr-tramp-webdav--setup-buffer 'permanent-local-hook t)

(defun zr-tramp-webdav--remember (file entry)
  "Record FILE and ENTRY as the current buffer's visited state."
  (setq zr-tramp-webdav--visited (cons (expand-file-name file) entry))
  ;; Renaming the original to a backup would invalidate its If-Match guard.
  (zr-tramp-webdav--setup-buffer)
  (add-hook 'after-change-major-mode-hook #'zr-tramp-webdav--setup-buffer nil t)
  (tramp-run-real-handler #'set-visited-file-modtime
                         (list (or (plist-get entry :mtime) '(0 0)))))

(defun zr-tramp-webdav--file-local-copy (file)
  "Download FILE to a private local temporary file and return its name."
  (when (file-directory-p file)
    (signal 'file-error (list "Cannot read a WebDAV directory as a file" file)))
  (let ((temp (tramp-compat-make-temp-file file)) success)
    (unwind-protect
        (progn
          (zr-tramp-webdav--write-bytes (plist-get (zr-tramp-webdav--get file) :body) temp)
          (run-hooks 'tramp-handle-file-local-copy-hook)
          (setq success t)
          temp)
      (unless success (delete-file temp)))))

(defun zr-tramp-webdav--insert-file-contents (file &optional visit beg end replace)
  "Implement `insert-file-contents' with its usual arguments."
  (barf-if-buffer-read-only)
  (when (and visit (or beg end))
    (error "Cannot visit a partial file"))
  (setq file (expand-file-name file))
  (let ((temp (tramp-compat-make-temp-file file)) response result coding)
    (unwind-protect
        (condition-case err
            (progn
              (when (file-directory-p file)
                (signal 'file-error (list "Cannot read a WebDAV directory as a file" file)))
              (setq response (zr-tramp-webdav--get file))
              (zr-tramp-webdav--write-bytes (plist-get response :body) temp)
              (let ((file-coding-system-alist
                     (tramp-find-file-name-coding-system-alist file temp)))
                (setq result (insert-file-contents temp nil beg end replace)
                      coding last-coding-system-used))
              (when visit
                (setq buffer-file-name file)
                (zr-tramp-webdav--remember file (zr-tramp-webdav--response-entry response))
                (set-buffer-modified-p nil))
              (list file (cadr result)))
          (file-missing
           (when visit
             (setq buffer-file-name file)
             (zr-tramp-webdav--remember file '(:missing t))
             (tramp-run-real-handler #'set-visited-file-modtime '(-1))
             (set-buffer-modified-p nil))
           (signal (car err) (cdr err))))
      (delete-file temp)
      (when coding (setq last-coding-system-used coding)))))

(defun zr-tramp-webdav--conditions (entry)
  "Return conditional write headers for metadata ENTRY."
  (let ((etag (plist-get entry :etag)) (modified (plist-get entry :modified)))
    (cond ((plist-get entry :missing) '(("If-None-Match" . "*")))
          ((and etag (not (string-prefix-p "W/" etag))) (list (cons "If-Match" etag)))
          (modified (list (cons "If-Unmodified-Since" modified))))))

(defun zr-tramp-webdav--mutate (file method &optional headers data exclusive)
  "Run METHOD on FILE using HEADERS and DATA, then invalidate its cache.
EXCLUSIVE controls the error for a failed create-only precondition."
  (unwind-protect
      (let* ((response (zr-tramp-webdav--request file method headers data))
             (status (plist-get response :status)))
        (unless (<= 200 status 299)
          (zr-tramp-webdav--http-error response file exclusive))
        ;; DELETE/COPY/MOVE may return HTTP 207 with per-resource failures.
        (when (= status 207)
          (let ((nodes (zr-tramp-webdav--children (zr-tramp-webdav--xml response) "response")))
            (unless nodes
              (signal 'file-error (list "Empty WebDAV mutation response" file)))
            (dolist (node nodes)
              (unless (let ((code (zr-tramp-webdav--status node)))
                        (and code (<= 200 code 299)))
                (zr-tramp-webdav--http-error
                 (list :status (or (zr-tramp-webdav--status node) 500)) file)))))
        response)
    (zr-tramp-webdav--flush file)))

(defun zr-tramp-webdav--write-region (start end file &optional append visit _lockname mustbenew)
  "Implement `write-region' using a conditional WebDAV PUT."
  (setq file (expand-file-name file))
  (let* ((existing (zr-tramp-webdav--stat file t))
         (exclusive (or (eq mustbenew 'excl) (and mustbenew (not existing))))
         (entry (when (equal file (car zr-tramp-webdav--visited))
                  (cdr zr-tramp-webdav--visited)))
         (temp (tramp-compat-make-temp-file file))
         response coding)
    (unwind-protect
        (progn
          (when (plist-get existing :directory)
            (signal 'file-error (list "Cannot overwrite a WebDAV directory" file)))
          (when (and mustbenew existing
                     (or (eq mustbenew 'excl)
                         (not (y-or-n-p (format "File %s exists; overwrite? " file)))))
            (signal 'file-already-exists (list "File exists" file)))
          (when append
            (if existing
                (let ((download (zr-tramp-webdav--get file)))
                  (zr-tramp-webdav--write-bytes (plist-get download :body) temp)
                  (setq entry (zr-tramp-webdav--response-entry download)))
              (setq entry '(:missing t))))
          (let ((create-lockfiles nil)
                (file-coding-system-alist (tramp-find-file-name-coding-system-alist file temp)))
            (write-region start end temp append 'silent)
            (setq coding last-coding-system-used))
          (setq response
                (zr-tramp-webdav--mutate
                 file "PUT"
                 (append '(("Content-Type" . "application/octet-stream"))
                         (if exclusive '(("If-None-Match" . "*"))
                           (zr-tramp-webdav--conditions entry)))
                 (zr-tramp-webdav--read-bytes temp) exclusive))
          (when (or (eq visit t) (stringp visit))
            (setq buffer-file-name (if (stringp visit) (expand-file-name visit) file))
            (let ((saved (zr-tramp-webdav--response-entry response)))
              (unless (or (plist-get saved :etag) (plist-get saved :mtime))
                (setq saved (zr-tramp-webdav--stat file t)))
              (if (and file-precious-flag (not (equal file buffer-file-name))
                       (equal buffer-file-name (car zr-tramp-webdav--visited)))
                  ;; write-region VISIT names the real file, but this PUT
                  ;; only wrote its temporary replacement.  Keep the old
                  ;; destination validator until the subsequent MOVE.
                  (progn
                    (setq zr-tramp-webdav--pending-move
                          (list :from file :to buffer-file-name
                                :old (cdr zr-tramp-webdav--visited)))
                    (tramp-run-real-handler #'set-visited-file-modtime
                                            (list (or (plist-get saved :mtime) '(0 0)))))
                (zr-tramp-webdav--remember buffer-file-name saved)))
            (set-buffer-modified-p nil))
          (run-hooks 'tramp-handle-write-region-hook)
          (when (and (not noninteractive) (or (null visit) (eq visit t) (stringp visit)))
            (message "Wrote %s" file))
          nil)
      (delete-file temp)
      (when coding (setq last-coding-system-used coding)))))

(defun zr-tramp-webdav--set-visited-file-modtime (&optional time)
  "Record TIME or freshly retrieved metadata for the visited WebDAV file."
  (if time
      (tramp-run-real-handler #'set-visited-file-modtime (list time))
    (let ((entry (zr-tramp-webdav--stat buffer-file-name t)))
      (zr-tramp-webdav--remember buffer-file-name (or entry '(:missing t)))
      (unless entry (tramp-run-real-handler #'set-visited-file-modtime '(-1))))))

(defun zr-tramp-webdav--verify-visited-file-modtime (&optional buffer)
  "Check BUFFER's recorded HTTP validators against current server metadata."
  (with-current-buffer (or buffer (current-buffer))
    (if (not buffer-file-name) t
      (let* ((current (zr-tramp-webdav--stat buffer-file-name t))
             (old (cdr zr-tramp-webdav--visited))
             (etag (plist-get old :etag)))
        (cond ((not current) (or (plist-get old :missing)
                                (equal (visited-file-modtime) -1)))
              ((plist-get old :missing) nil)
              ((and etag (plist-get current :etag))
               (equal etag (plist-get current :etag)))
              ((and (plist-get current :mtime) (not (equal (visited-file-modtime) 0)))
               (time-equal-p (plist-get current :mtime) (visited-file-modtime)))
              (t t))))))

(defun zr-tramp-webdav--make-directory (directory &optional parents)
  "Create DIRECTORY using MKCOL, optionally creating PARENTS."
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (let ((entry (zr-tramp-webdav--stat directory t)))
    (if entry
        (unless (and parents (plist-get entry :directory))
          (signal 'file-already-exists (list "File exists" directory)))
      (when parents
        (let ((parent (file-name-directory (directory-file-name directory))))
          (unless (file-directory-p parent) (make-directory parent t))))
      (zr-tramp-webdav--mutate directory "MKCOL"))
    nil))

(defun zr-tramp-webdav--delete-file (file &optional trash)
  "Delete FILE using WebDAV; refuse an unsupported TRASH request."
  (when (and trash delete-by-moving-to-trash)
    (signal 'file-error '("WebDAV does not support trash")))
  (when (file-directory-p file)
    (signal 'file-error (list "File is a directory" file)))
  (zr-tramp-webdav--mutate file "DELETE")
  nil)

(defun zr-tramp-webdav--delete-directory (directory &optional recursive trash)
  "Delete DIRECTORY, checking emptiness unless RECURSIVE; honor TRASH."
  (when (and trash delete-by-moving-to-trash)
    (signal 'file-error '("WebDAV does not support trash")))
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (let ((remote-file-name-inhibit-cache t))
    (unless (file-directory-p directory)
      (signal 'file-error (list "Not a WebDAV directory" directory)))
    (when (and (not recursive)
               (directory-files directory nil directory-files-no-dot-files-regexp))
      (signal 'file-error (list "Directory is not empty" directory))))
  (zr-tramp-webdav--mutate directory "DELETE")
  nil)

(defun zr-tramp-webdav--destination (file newname)
  "Expand NEWNAME, appending the base name of FILE for a directory name."
  (setq newname (expand-file-name newname))
  (if (directory-name-p newname)
      (concat newname (file-name-nondirectory (directory-file-name file)))
    newname))

(defun zr-tramp-webdav--check-destination (file newname okay &optional directory)
  "Check a copy/move from FILE to NEWNAME with overwrite option OKAY.
DIRECTORY permits replacing an empty directory.  Return overwrite consent."
  (when (equal (expand-file-name file) (expand-file-name newname))
    (signal 'file-error (list "Source and destination are the same file" file)))
  (let* ((remote-file-name-inhibit-cache t)
         (exists (file-exists-p newname)))
    (when (and exists
               (or (not okay)
                   (and (integerp okay)
                        (not (y-or-n-p (format "File %s exists; overwrite? " newname))))))
      (signal 'file-already-exists (list "File exists" newname)))
    (when (and exists (file-directory-p newname)
               (or (not directory)
                   (directory-files newname nil directory-files-no-dot-files-regexp)))
      (signal 'file-error (list "Cannot overwrite a directory" newname)))
    (when (and exists directory (not (file-directory-p newname)))
      (signal 'file-error (list "Cannot replace a file with a directory" newname)))
    (if (integerp okay) exists okay)))

(defun zr-tramp-webdav--server-copy-move (file newname method overwrite &optional headers)
  "Use server METHOD from FILE to NEWNAME with OVERWRITE and HEADERS."
  (unwind-protect
      (zr-tramp-webdav--mutate
       file method
       (append `(("Destination" . ,(zr-tramp-webdav--url (tramp-dissect-file-name newname)))
                 ("Overwrite" . ,(if overwrite "T" "F"))) headers)
       nil (not overwrite))
    (zr-tramp-webdav--flush newname)))

(defun zr-tramp-webdav--copy-file
    (file newname &optional okay keep-time preserve-uid-gid preserve-permissions)
  "Implement `copy-file', using COPY or staging a transfer locally."
  (setq file (expand-file-name file)
        newname (zr-tramp-webdav--destination file newname))
  (when (file-directory-p file)
    (signal 'file-error (list "Cannot copy a directory with copy-file" file)))
  (let ((overwrite (zr-tramp-webdav--check-destination file newname okay)))
    (if (and (zr-tramp-webdav-file-name-p file)
             (zr-tramp-webdav-file-name-p newname) (tramp-equal-remote file newname))
        (zr-tramp-webdav--server-copy-move file newname "COPY" overwrite)
      (let ((temp (file-local-copy file)))
        (unwind-protect
            (if (zr-tramp-webdav-file-name-p newname)
                (zr-tramp-webdav--mutate
                 newname "PUT"
                 (append '(("Content-Type" . "application/octet-stream"))
                         (unless overwrite '(("If-None-Match" . "*"))))
                 (zr-tramp-webdav--read-bytes (or temp file)) (not overwrite))
              (when (and temp keep-time)
                (set-file-times temp (file-attribute-modification-time (file-attributes file))))
              (copy-file (or temp file) newname overwrite keep-time
                         preserve-uid-gid preserve-permissions))
          (when temp (delete-file temp))))))
  nil)

(defun zr-tramp-webdav--rename-file (file newname &optional okay)
  "Rename FILE to NEWNAME, honoring overwrite option OKAY."
  (setq file (expand-file-name file)
        newname (zr-tramp-webdav--destination file newname))
  (let* ((pending (and (equal file (plist-get zr-tramp-webdav--pending-move :from))
                       (equal newname (plist-get zr-tramp-webdav--pending-move :to))
                       zr-tramp-webdav--pending-move))
         (old (plist-get pending :old))
         (etag (plist-get old :etag)))
    (condition-case err
        (let* ((directory (file-directory-p file))
               (overwrite (zr-tramp-webdav--check-destination file newname okay directory)))
          (cond
           ((and (zr-tramp-webdav-file-name-p file)
                 (zr-tramp-webdav-file-name-p newname) (tramp-equal-remote file newname))
            (zr-tramp-webdav--server-copy-move
             (if directory (file-name-as-directory file) file) newname "MOVE"
             (and overwrite (not (plist-get old :missing)))
             ;; If-Match applies to the source URI.  A tagged DAV If
             ;; condition is needed to protect the destination of MOVE.
             (when (and etag (not (string-prefix-p "W/" etag)))
               (list (cons "If" (format "<%s> ([%s])"
                                       (zr-tramp-webdav--url (tramp-dissect-file-name newname))
                                       etag))))))
           (directory
            (signal 'file-error '("WebDAV cannot rename directories across servers")))
           (t (copy-file file newname overwrite t) (delete-file file)))
          (when pending
            (zr-tramp-webdav--remember newname (zr-tramp-webdav--stat newname t))
            (setq zr-tramp-webdav--pending-move nil)
            (set-buffer-modified-p nil)))
      (error
       (when pending
         (zr-tramp-webdav--remember newname old)
         (setq zr-tramp-webdav--pending-move nil)
         (set-buffer-modified-p t)
         (ignore-errors (delete-file file)))
       (signal (car err) (cdr err)))))
  nil)

(defun zr-tramp-webdav--unsupported (&rest _args)
  "Report an operation that WebDAV cannot provide."
  (signal 'file-error '("Operation is not supported by WebDAV")))

(defconst zr-tramp-webdav-file-name-handler-alist
  '((access-file . tramp-handle-access-file)
    (add-name-to-file . zr-tramp-webdav--unsupported)
    (copy-directory . tramp-handle-copy-directory)
    (copy-file . zr-tramp-webdav--copy-file)
    (delete-directory . zr-tramp-webdav--delete-directory)
    (delete-file . zr-tramp-webdav--delete-file)
    (directory-file-name . tramp-handle-directory-file-name)
    (directory-files . zr-tramp-webdav--directory-files)
    (directory-files-and-attributes . zr-tramp-webdav--directory-files-and-attributes)
    (dired-compress-file . zr-tramp-webdav--unsupported)
    (dired-uncache . tramp-handle-dired-uncache)
    (exec-path . ignore)
    (expand-file-name . zr-tramp-webdav--expand-file-name)
    (file-accessible-directory-p . tramp-handle-file-accessible-directory-p)
    (file-acl . ignore)
    (file-attributes . zr-tramp-webdav--file-attributes)
    (file-directory-p . tramp-handle-file-directory-p)
    (file-equal-p . tramp-handle-file-equal-p)
    (file-executable-p . tramp-handle-file-directory-p)
    (file-exists-p . zr-tramp-webdav--file-exists-p)
    (file-in-directory-p . tramp-handle-file-in-directory-p)
    (file-local-copy . zr-tramp-webdav--file-local-copy)
    (file-locked-p . ignore)
    (file-modes . tramp-handle-file-modes)
    (file-name-all-completions . zr-tramp-webdav--all-completions)
    (file-name-as-directory . tramp-handle-file-name-as-directory)
    (file-name-case-insensitive-p . ignore)
    (file-name-completion . tramp-handle-file-name-completion)
    (file-name-directory . tramp-handle-file-name-directory)
    (file-name-nondirectory . tramp-handle-file-name-nondirectory)
    (file-newer-than-file-p . tramp-handle-file-newer-than-file-p)
    (file-notify-add-watch . tramp-handle-file-notify-add-watch)
    (file-notify-rm-watch . ignore)
    (file-notify-valid-p . ignore)
    (file-ownership-preserved-p . ignore)
    (file-readable-p . zr-tramp-webdav--file-exists-p)
    (file-regular-p . tramp-handle-file-regular-p)
    (file-remote-p . tramp-handle-file-remote-p)
    (file-selinux-context . tramp-handle-file-selinux-context)
    (file-symlink-p . ignore)
    (file-system-info . ignore)
    (file-truename . zr-tramp-webdav--expand-file-name)
    (file-writable-p . zr-tramp-webdav--file-writable-p)
    (find-backup-file-name . tramp-handle-find-backup-file-name)
    (insert-directory . tramp-handle-insert-directory)
    (insert-file-contents . zr-tramp-webdav--insert-file-contents)
    (list-system-processes . zr-tramp-webdav--unsupported)
    (load . tramp-handle-load)
    (lock-file . ignore)
    (make-auto-save-file-name . tramp-handle-make-auto-save-file-name)
    (make-directory . zr-tramp-webdav--make-directory)
    (make-directory-internal . zr-tramp-webdav--make-directory)
    (make-lock-file-name . tramp-handle-make-lock-file-name)
    (make-nearby-temp-file . tramp-handle-make-nearby-temp-file)
    (make-process . zr-tramp-webdav--unsupported)
    (make-symbolic-link . zr-tramp-webdav--unsupported)
    (memory-info . zr-tramp-webdav--unsupported)
    (process-attributes . zr-tramp-webdav--unsupported)
    (process-file . zr-tramp-webdav--unsupported)
    (rename-file . zr-tramp-webdav--rename-file)
    (set-file-acl . ignore)
    (set-file-modes . ignore)
    (set-file-selinux-context . ignore)
    (set-file-times . ignore)
    (set-visited-file-modtime . zr-tramp-webdav--set-visited-file-modtime)
    (shell-command . zr-tramp-webdav--unsupported)
    (start-file-process . zr-tramp-webdav--unsupported)
    (substitute-in-file-name . tramp-handle-substitute-in-file-name)
    (temporary-file-directory . tramp-handle-temporary-file-directory)
    (tramp-get-home-directory . ignore)
    (tramp-get-remote-gid . ignore)
    (tramp-get-remote-groups . ignore)
    (tramp-get-remote-uid . ignore)
    (tramp-set-file-uid-gid . ignore)
    (unhandled-file-name-directory . ignore)
    (unlock-file . ignore)
    (vc-registered . ignore)
    (verify-visited-file-modtime . zr-tramp-webdav--verify-visited-file-modtime)
    (write-region . zr-tramp-webdav--write-region))
  "File operations provided by the portable WebDAV backend.")

(defun zr-tramp-webdav-file-name-handler (operation &rest args)
  "Dispatch TRAMP OPERATION with ARGS to the WebDAV implementation."
  (if-let* ((handler (alist-get operation zr-tramp-webdav-file-name-handler-alist)))
      (save-match-data (apply handler args))
    (tramp-run-real-handler operation args)))

;;;###autoload
(defun zr-tramp-webdav-clear-cache ()
  "Forget WebDAV file metadata and interactively entered credentials."
  (interactive)
  (clrhash zr-tramp-webdav--passwords)
  (dolist (key (hash-table-keys tramp-cache-data))
    (when (and (tramp-file-name-p key) (zr-tramp-webdav-file-name-p key))
      (remhash key tramp-cache-data))))

(dolist (method '(("webdav" 80) ("webdavs" 443)))
  (add-to-list 'tramp-methods
               `(,(car method) (tramp-default-port ,(cadr method)))))

(tramp-register-foreign-file-name-handler
 #'zr-tramp-webdav-file-name-p #'zr-tramp-webdav-file-name-handler)

(provide 'zr-tramp-webdav)
;;; zr-tramp-webdav.el ends here
