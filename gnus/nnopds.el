;;; nnopds.el --- Read OPDS 2 publications with Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An OPDS 2 catalog is a server, a publication is a group, and its reading
;; resources are articles.  EPUB files are downloaded on first group entry
;; and read using nnepub; Divina comics stream images page by page.
;; Catalog directories and pagination are browsed
;; on demand, with visited pages cached locally.  Reading formats and
;; progress protocols have separate interfaces for future extensions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'url-expand)
(require 'url-parse)
(require 'auth-source)
(require 'nnepub)

(autoload 'nnopds-progress-prepare "nnopds-progress")
(autoload 'nnopds-progress-close "nnopds-progress")
(autoload 'nnopds-progress-configure "nnopds-progress")
(autoload 'nnopds-progress-before-download "nnopds-progress")
(autoload 'nnopds-progress-loaded "nnopds-progress")
(autoload 'nnopds-resume "nnopds-progress" nil t)
(autoload 'nnopds-save-position "nnopds-progress" nil t)
(autoload 'nnopds-browse "nnopds-browse" nil t)
(autoload 'nnopds-browse-search "nnopds-browse" nil t)

(defgroup nnopds nil "OPDS 2 publications in Gnus." :group 'gnus)

(defcustom nnopds-request-timeout 30
  "Maximum seconds for each HTTP request."
  :type 'natnum :group 'nnopds)

(defcustom nnopds-catalog-cache-ttl nil
  "Seconds before a visited OPDS page is fetched again.
Nil reuses cached pages until explicitly refreshed.  Zero always revalidates
visited pages.  Gnus startup only reads the local publication index."
  :type '(choice (const :tag "Refresh manually" nil) natnum) :group 'nnopds)

(nnoo-declare nnopds)
(defvoo nnopds-url nil "OPDS 2 catalog URL.  Defaults to the server name.")
(defvoo nnopds-address nil "Catalog address or original server name for Gnus temporary groups.")
(defvoo nnopds-user nil "HTTP user, optionally looked up in auth-source.")
(defvoo nnopds-password nil "HTTP password.  Prefer auth-source.")
(defvoo nnopds-auth-method 'basic "HTTP authentication method: basic or digest.")
(defvoo nnopds-headers nil "Additional HTTP headers, for example an API key.")
(defvoo nnopds-progress-protocol 'koreader "Reading position protocol.  Currently supports koreader.")
(defvoo nnopds-koreader-url nil "Explicit KOReader sync base URL.  Nil keeps reading positions local.")
(defvoo nnopds-koreader-user nil "KOReader username, or a Komga API key; optionally looked up in auth-source.")
(defvoo nnopds-koreader-password nil "KOReader password.  Prefer auth-source; Komga does not require it.")
(defvoo nnopds--connection nil)
(defvoo nnopds--group nil)

;; Protocol modules inline accessors; append fields to keep their offsets stable.
(cl-defstruct (nnopds--connection (:constructor nnopds--make-connection))
  name url headers directory catalog publications processes readers fetched closed progress auth-method counts)

(cl-defstruct (nnopds--publication (:constructor nnopds--make-publication))
  group title author modified source acquisition format progress document data count)

(cl-defstruct (nnopds--request-state (:constructor nnopds--make-request-state))
  process done response error)

(nnoo-define-basics nnopds)

(defmacro nnopds--report-errors (&rest body)
  "Run BODY and report failures to Gnus."
  (declare (indent 0) (debug t))
  `(condition-case err (progn ,@body)
     (error (nnheader-report 'nnopds "%s" (error-message-string err)))))

(defun nnopds--url (href &optional base)
  "Resolve HTTP HREF against BASE, without its fragment."
  (unless (and (stringp href) (not (string-empty-p href)))
    (error "Missing OPDS link URL"))
  (let* ((url (url-expand-file-name href base))
         (parsed (url-generic-parse-url url)))
    (unless (member (url-type parsed) '("http" "https"))
      (error "OPDS requires an HTTP or HTTPS URL"))
    (unless (url-host parsed) (error "Missing OPDS host"))
    (setf (url-target parsed) nil)
    (url-recreate-url parsed)))

(defun nnopds--origin (url)
  "Return the origin of URL for credential scoping."
  (let ((parsed (url-generic-parse-url url)))
    (list (url-type parsed) (downcase (url-host parsed)) (url-port parsed))))

(defun nnopds--auth (url user password)
  "Return USER and PASSWORD for URL, filling missing values from auth-source."
  (let* ((parsed (url-generic-parse-url url))
         (entry (unless password
                  (car (auth-source-search :host (url-host parsed)
                                           :port (number-to-string (url-port parsed))
                                           :user user :max 1
                                           :require '(:user :secret)))))
         (secret (or password (plist-get entry :secret))))
    (cons (or user (plist-get entry :user)) (if (functionp secret) (funcall secret) secret))))

(defun nnopds--credentials (url)
  "Build this server's HTTP headers for URL."
  (let* ((auth (unless (and nnopds-headers (not nnopds-user) (not nnopds-password))
                 (nnopds--auth url nnopds-user nnopds-password)))
         (user (car auth))
         (password (cdr auth)))
    (append (copy-tree nnopds-headers)
            (when (and user password)
              (list (cons "Authorization"
                          (concat "Basic " (base64-encode-string
                                            (encode-coding-string
                                             (concat user ":" password) 'utf-8) t))))))))

(defun nnopds--read-bytes (file)
  "Return the unibyte contents of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun nnopds--response (headers body &optional output-file)
  "Parse curl's HEADERS and BODY files into a response plist."
  (with-temp-buffer
    (insert-file-contents headers)
    (goto-char (point-min))
    (let (status fields)
      ;; A proxy may prepend its own HTTP status and headers.
      (while (re-search-forward "^HTTP/[^ ]+ \\([0-9]+\\)[^\n]*\n" nil t)
        (setq status (string-to-number (match-string 1)) fields nil)
        (while (looking-at "\\([^:\r\n]+\\):[ \t]*\\([^\r\n]*\\)\r?\n")
          (push (cons (downcase (match-string 1)) (match-string 2)) fields)
          (goto-char (match-end 0))))
      (unless status (error "No HTTP response"))
      (append (list :status status :headers fields)
              (if output-file (list :file output-file)
                (list :body (nnopds--read-bytes body)))))))

(defun nnopds--request (connection method url &optional data callback request-headers authentication output-file)
  "Request URL with METHOD and optional JSON DATA using CONNECTION.
With CALLBACK, return a request state and call it once with (RESPONSE ERROR).
Without CALLBACK, wait for a response, allowing process output and quit.
REQUEST-HEADERS specify the request's media types.  AUTHENTICATION, when
non-nil, replaces the catalog credentials with its :headers, scoped to
its :url origin.  With OUTPUT-FILE, curl writes directly there and the
response contains :file instead of :body.  The caller owns this file,
including cleanup on failure or quit.  Other response bodies are unibyte
strings.  Redirects
are bounded and credentials are only sent to the configured origin."
  (let ((state (nnopds--make-request-state))
        (output-file (when output-file (expand-file-name output-file))))
    (cl-labels
        ((finish (response error)
           (unless (nnopds--request-state-done state)
             (setf (nnopds--request-state-done state) t
                   (nnopds--request-state-response state) response
                   (nnopds--request-state-error state) error)
             (when callback (funcall callback response error))))
         (start (target redirects)
           (condition-case err
               (progn
                 (when (nnopds--connection-closed connection)
                   (error "OPDS server is closed"))
                 (let* ((body-file (or output-file (make-temp-file "nnopds-body-")))
                        (head-file (make-temp-file "nnopds-head-"))
                        (buffer (generate-new-buffer " *nnopds-http*"))
                        (headers (append request-headers
                                         (when (equal (nnopds--origin target)
                                                      (nnopds--origin (if authentication (plist-get authentication :url)
                                                                       (nnopds--connection-url connection))))
                                           (if authentication (plist-get authentication :headers)
                                             (nnopds--connection-headers connection)))))
                        (digest-header (when (and (not authentication)
                                                  (eq (nnopds--connection-auth-method connection) 'digest))
                                         (assoc-string "Authorization" headers t)))
                        (digest-user (when (and digest-header (string-prefix-p "Basic " (cdr digest-header)))
                                       (decode-coding-string (base64-decode-string (substring (cdr digest-header) 6)) 'utf-8)))
                        (headers (if digest-user (remq digest-header headers) headers))
                        (args (append (list "--silent" "--show-error" "--max-time"
                                            (number-to-string (max 1 nnopds-request-timeout))
                                            "--request" method "--dump-header" head-file
                                            "--output" body-file)
                                      (when digest-user (list "--digest" "--user" digest-user))
                                      (mapcan (lambda (header)
                                                (list "--header" (concat (car header) ": " (cdr header))))
                                              headers)
                                      (when data
                                        (append (unless (assoc-string "Content-Type" headers t)
                                                  (list "--header" "Content-Type: application/json"))
                                                (list "--data-binary" "@-")))
                                      (list "--url" target)))
                        process started)
                   (unwind-protect
                       (progn
                         (setq process
                               (make-process
                                :name "nnopds-http" :buffer buffer :noquery t
                                :connection-type 'pipe :coding 'binary
                                :command (cons "curl" args)
                                :sentinel
                                (lambda (proc _event)
                                  (unless (process-live-p proc)
                                    (setf (nnopds--connection-processes connection)
                                          (delq proc (nnopds--connection-processes connection)))
                                    (unwind-protect
                                        (condition-case failure
                                            (if (not (and (eq (process-status proc) 'exit)
                                                          (zerop (process-exit-status proc))))
                                                (finish nil "HTTP request failed or timed out")
                                              (let* ((response (nnopds--response head-file body-file output-file))
                                                     (status (plist-get response :status))
                                                     (location (cdr (assoc "location" (plist-get response :headers)))))
                                                (if (and location (memq status '(301 302 303 307 308)))
                                                    (if (or (>= redirects 5)
                                                            (and (not (equal method "GET"))
                                                                 (not (memq status '(307 308)))))
                                                        (finish nil "Unsupported or excessive HTTP redirects")
                                                      (start (nnopds--url location target) (1+ redirects)))
                                                  (finish (plist-put response :url target) nil))))
                                          (error (finish nil (error-message-string failure))))
                                      (unless output-file (delete-file body-file))
                                      (delete-file head-file)
                                      (kill-buffer buffer))))))
                         (setf (nnopds--request-state-process state) process)
                         (push process (nnopds--connection-processes connection))
                         (when data (process-send-string process (encode-coding-string data 'utf-8)))
                         (process-send-eof process)
                         (setq started t))
                     (unless started
                       (when (and process (process-live-p process)) (delete-process process))
                       (when (and (not output-file) (file-exists-p body-file)) (delete-file body-file))
                       (when (file-exists-p head-file) (delete-file head-file))
                       (when (buffer-live-p buffer) (kill-buffer buffer))))))
             (error (finish nil (error-message-string err))))))
      (start (nnopds--url url) 0))
    (if callback state
      (unwind-protect
          (progn
            (while (not (nnopds--request-state-done state))
              (accept-process-output nil 0.05))
            (when-let* ((error (nnopds--request-state-error state))) (error "%s" error))
            (nnopds--request-state-response state))
        (when-let* ((process (nnopds--request-state-process state))
                    ((process-live-p process)))
          (delete-process process))))))

(defun nnopds--json (response)
  "Parse a successful HTTP RESPONSE as JSON."
  (pcase (plist-get response :status)
    (200 (json-parse-string (decode-coding-string (plist-get response :body) 'utf-8)
                            :object-type 'plist :array-type 'array
                            :null-object nil :false-object :false))
    (code (error "HTTP %s" code))))

(defun nnopds--rel-p (link relation)
  "Whether LINK has RELATION, accepting a string or an array of relations."
  (let ((rel (plist-get link :rel)))
    (if (stringp rel) (equal rel relation) (seq-contains-p rel relation #'equal))))

(defun nnopds--media-type (link)
  "Return LINK's media type without parameters."
  (car (split-string (or (plist-get link :type) "") ";[ \t]*")))

(defun nnopds--normalize (document base)
  "Return DOCUMENT with publication link URLs resolved against BASE."
  (setq document (copy-tree document t))
  (dolist (key '(:links :images))
    (seq-doseq (link (plist-get document key))
      (when-let* ((href (plist-get link :href)))
        (setf (plist-get link :href) (nnopds--url href base)))))
  document)

(defvar nnopds--formats '((comic "application/divina+json")
                         (epub "application/epub+zip"))
  "Reading formats in preference order and their link media types.")

(cl-defgeneric nnopds--load-publication (format connection publication)
  "Load PUBLICATION's reading data for FORMAT using CONNECTION.")
(cl-defgeneric nnopds--chapters (format data) "Return FORMAT DATA's numbered resources.")
(cl-defgeneric nnopds--header (format data chapter) "Return CHAPTER's Gnus header.")
(cl-defgeneric nnopds--article (format data chapter group) "Return CHAPTER's MIME article in GROUP.")
(cl-defgeneric nnopds--dispose (format data) "Free temporary reading DATA for FORMAT.")
(cl-defgeneric nnopds--locator (format data chapter) "Return CHAPTER's portable locator, or nil.")
(cl-defgeneric nnopds--locate (format data locator) "Return (NUMBER . FRAGMENT) for LOCATOR, or nil.")
(cl-defgeneric nnopds--prepare-reader (format data) "Prepare FORMAT DATA's current Gnus summary.")
(cl-defgeneric nnopds--close-reader (format data) "Close FORMAT DATA's reading sessions.")
(cl-defmethod nnopds--close-reader (_format _data) nil)

(defun nnopds--publication (document base &optional connection)
  "Convert an OPDS publication DOCUMENT at BASE into a reading entry.
With nil BASE, DOCUMENT already has absolute URLs, as in the catalog cache."
  (let* ((document (if base (nnopds--normalize document base) document))
         (links (plist-get document :links))
         (acquisition
          (cl-loop for format in nnopds--formats
                   thereis
                   (cl-find-if
                    (lambda (link)
                      (and (plist-get link :href)
                           (not (eq t (plist-get link :templated)))
                           (member (nnopds--media-type link) (cdr format))
                           ;; Komga's Divina manifest is a self link; calibre's
                           ;; is an acquisition link.  Komga also offers some
                           ;; alternate Divina manifests without a relation.
                           (or (eq (car format) 'comic)
                               (cl-some (lambda (rel) (nnopds--rel-p link rel))
                                        '("http://opds-spec.org/acquisition" "http://opds-spec.org/acquisition/open-access"
                                          "acquisition" "download"))))) links)))
         (self (cl-find-if (lambda (link) (nnopds--rel-p link "self")) links))
         (format (car (cl-find-if (lambda (entry) (member (nnopds--media-type acquisition) (cdr entry))) nnopds--formats)))
         (metadata (plist-get document :metadata)))
    (when acquisition
      (let* ((source (or (plist-get self :href) (plist-get acquisition :href)))
             (modified (plist-get metadata :modified))
             (group (concat "book." (secure-hash 'sha256 source) "."
                            (secure-hash 'sha256 (or modified "unversioned"))))
             (author (plist-get metadata :author)))
        (nnopds--make-publication
         :group group :source source :modified modified :document document
         :title (nnepub--header-text (plist-get metadata :title))
         :author (nnepub--header-text
                  (if (stringp author) author
                    (string-join (mapcar (lambda (entry) (if (stringp entry) entry (or (plist-get entry :name) "")))
                                         (if (and (listp author) (plist-get author :name)) (list author) author)) ", ")))
         :format format
         :acquisition (plist-get acquisition :href)
         :progress (when (and connection (eq format 'epub))
                     (copy-sequence (nnopds--connection-progress connection))))))))

(defun nnopds--cache-file (connection name)
  "Return cache NAME in CONNECTION's account directory."
  (expand-file-name name (nnopds--connection-directory connection)))

(defun nnopds--temporary-file (file)
  "Create a short-named temporary sibling of FILE for atomic replacement."
  (let ((directory (file-name-directory (expand-file-name file))))
    (make-directory directory t)
    (make-temp-file (expand-file-name ".nnopds-" directory))))

(defun nnopds--write-json (file data)
  "Write JSON DATA atomically to FILE."
  (let ((temporary (nnopds--temporary-file file))
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file temporary (insert (json-serialize data)))
          (rename-file temporary file t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun nnopds--read-json (file &optional object-type)
  "Read a cached JSON FILE, returning nil if unavailable or invalid."
  (when (file-readable-p file)
    (condition-case nil
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
          (json-parse-buffer :object-type (or object-type 'plist) :array-type 'array
                             :null-object nil :false-object :false))
      (error nil))))

(defun nnopds--install-catalog (connection entries)
  "Install publication ENTRIES into CONNECTION, preserving reading data."
  (let ((table (nnopds--connection-publications connection))
        (seen (make-hash-table :test #'equal)) catalog)
    (seq-doseq (entry entries)
      (when entry
        (let* ((group (nnopds--publication-group entry))
               (old (gethash group table)))
          (when old (setf (nnopds--publication-data entry) (nnopds--publication-data old)))
          (setf (nnopds--publication-count entry)
                (or (and old (nnopds--publication-count old))
                    (gethash group (nnopds--connection-counts connection))))
          (puthash group entry table)
          (unless (gethash group seen)
            (puthash group t seen)
            (push group catalog)))))
    (setf (nnopds--connection-catalog connection) (nreverse catalog))))

(defun nnopds--cache-fresh-p (fetched)
  "Whether a cache FETCHED at a Unix timestamp can be reused."
  (and (numberp fetched)
       (or (null nnopds-catalog-cache-ttl)
           (< (- (float-time) fetched) nnopds-catalog-cache-ttl))))

(defun nnopds--feed (connection url force)
  "Read an OPDS feed at URL on CONNECTION, using its persistent cache.
FORCE revalidates cached pages with HTTP conditional requests.  Each page
is saved separately.  Ordinary browsing falls back to the cached page if
revalidation fails; an explicit refresh reports the error."
  (let* ((file (nnopds--cache-file connection (concat "feed." (secure-hash 'sha256 url) ".json")))
         (cached (nnopds--read-json file)))
    (if (and (not force) (plist-get cached :feed)
             (nnopds--cache-fresh-p (plist-get cached :fetched)))
        cached
      (condition-case err
          (let* ((headers (append '(("Accept" . "application/opds+json"))
                                  (when-let* ((etag (plist-get cached :etag)))
                                    (list (cons "If-None-Match" etag)))
                                  (when-let* ((modified (plist-get cached :last-modified)))
                                    (list (cons "If-Modified-Since" modified)))))
                 (response (nnopds--request connection "GET" url nil nil headers))
                 (fields (plist-get response :headers))
                 (feed (if (= (plist-get response :status) 304)
                           (or (plist-get cached :feed) (error "HTTP 304 without a cached OPDS feed"))
                         (nnopds--json response))))
            (unless (and (plist-get feed :metadata)
                         (or (plist-member feed :navigation) (plist-member feed :publications)
                             (plist-member feed :groups)
                             ;; Komga omits empty result arrays.  Its empty
                             ;; search feed still advertises OPDS search.
                             (seq-some (lambda (link)
                                         (and (nnopds--rel-p link "search")
                                              (equal (nnopds--media-type link) "application/opds+json")))
                                       (plist-get feed :links))))
              (error "Not an OPDS 2 catalog"))
            (let ((value (list :fetched (float-time) :feed feed
                               :url (if (= (plist-get response :status) 304) (plist-get cached :url)
                                      (or (plist-get response :url) url))
                               :etag (or (cdr (assoc "etag" fields))
                                         (and (= (plist-get response :status) 304) (plist-get cached :etag)))
                               :last-modified (or (cdr (assoc "last-modified" fields))
                                                  (and (= (plist-get response :status) 304)
                                                       (plist-get cached :last-modified))))))
              (nnopds--write-json file value)
              value))
        (error
         (if (and (not force) (plist-get cached :feed))
             (progn
               (message "nnopds: Using cached page (%s)" (error-message-string err))
               cached)
           (signal (car err) (cdr err))))))))

(defun nnopds--collections (feed)
  "Return FEED and its embedded groups, without fetching navigation links."
  (cons feed (seq-mapcat #'nnopds--collections (plist-get feed :groups))))

(defun nnopds--catalog-page (connection url &optional force)
  "Read one catalog page at URL on CONNECTION, optionally revalidating it.
Register only publications embedded in this page.  Navigation and pagination
remain links for the browser to follow on demand.  Previously encountered
publications stay available for subscriptions and offline reading."
  (let* ((page (nnopds--feed connection url force))
         (base (plist-get page :url))
         (table (nnopds--connection-publications connection))
         (entries (make-hash-table :test #'eq))
         staged additions changed)
    ;; Parse the entire page before changing the known publication index.
    (dolist (collection (nnopds--collections (plist-get page :feed)))
      (seq-doseq (document (plist-get collection :publications))
        (when-let* ((entry (nnopds--publication document base connection)))
          (push (cons document entry) staged))))
    (dolist (pair (nreverse staged))
      (let* ((entry (cdr pair))
             (group (nnopds--publication-group entry))
             (old (gethash group table)))
        (if (and old (equal (nnopds--publication-document old) (nnopds--publication-document entry)))
            (setq entry old)
          (setf (nnopds--publication-data entry) (and old (nnopds--publication-data old))
                (nnopds--publication-count entry)
                (or (and old (nnopds--publication-count old))
                    (gethash group (nnopds--connection-counts connection))))
          (unless old (push group additions))
          (puthash group entry table)
          (setq changed t))
        (puthash (car pair) entry entries)))
    (when changed
      (let ((catalog (append (nnopds--connection-catalog connection) (nreverse additions)))
            (fetched (float-time)))
        (nnopds--write-json (nnopds--cache-file connection "catalog.json")
                            (list :fetched fetched
                                  :publications
                                  (vconcat (mapcar (lambda (group)
                                                     (nnopds--publication-document (gethash group table)))
                                                   catalog))))
        (setf (nnopds--connection-catalog connection) catalog
              (nnopds--connection-fetched connection) fetched)))
    (plist-put page :entries entries)))

(defun nnopds-refresh-catalog (&optional server)
  "Refresh SERVER's root OPDS directory without traversing its descendants.
In the OPDS browser, use g to refresh the displayed page.
SERVER defaults to the current OPDS server."
  (interactive
   (list (completing-read "OPDS server: "
                          (nnopds--servers)
                          nil t nil nil (nnoo-current-server 'nnopds))))
  (let* ((connection (nnopds--change-server server))
         (page (nnopds--catalog-page connection (nnopds--connection-url connection) t)))
    (message "nnopds: Refreshed %s" (plist-get (plist-get (plist-get page :feed) :metadata) :title))
    t))

(defun nnopds--servers ()
  "Return the names of open OPDS servers."
  (delete "*internal-non-initialized-backend*"
          (delete-dups (delq nil (cons (nnoo-current-server 'nnopds)
                                     (mapcar #'car (cddr (assq 'nnopds nnoo-state-alist))))))))

(defun nnopds--change-server (server)
  "Switch to the already open SERVER and return its connection."
  (when (and server (not (nnoo-current-server-p 'nnopds server)))
    (unless (assoc server (cddr (assq 'nnopds nnoo-state-alist)))
      (error "OPDS server is not open: %s" server))
    (nnoo-change-server 'nnopds server nil))
  (or nnopds--connection (error "No OPDS server is open")))

(defun nnopds--get-publication (group &optional server load)
  "Return GROUP's publication on SERVER, optionally LOAD reading data."
  (let* ((connection (nnopds--change-server server))
         (publication (or (gethash (or group nnopds--group) (nnopds--connection-publications connection))
                          (error "OPDS publication unavailable; browse its catalog directory: %s" group))))
    (when (and load (not (nnopds--publication-data publication)))
      (when (eq (nnopds--publication-format publication) 'comic)
        (require 'nnopds-comic))
      (setf (nnopds--publication-data publication)
            (nnopds--load-publication (nnopds--publication-format publication) connection publication)
            (nnopds--publication-count publication)
            (length (nnopds--chapters (nnopds--publication-format publication)
                                    (nnopds--publication-data publication))))
      (let ((counts (nnopds--connection-counts connection))
            (count (nnopds--publication-count publication)))
        (unless (equal count (gethash (nnopds--publication-group publication) counts))
          (puthash (nnopds--publication-group publication) count counts)
          (nnopds--write-json (nnopds--cache-file connection "counts.json") counts))))
    (when load (nnopds-progress-loaded publication))
    publication))

(cl-defmethod nnopds--load-publication ((_format (eql epub)) connection publication)
  (let* ((group (nnopds--publication-group publication))
         (key (secure-hash 'sha256 group))
         (file (nnopds--cache-file connection (concat key ".epub")))
         (index-file (nnopds--cache-file connection (concat key ".json")))
         (index (nnopds--read-json index-file))
         (temporary (unless (file-readable-p file) (nnopds--temporary-file file)))
         book digest success)
    (unwind-protect
        (progn
          (when temporary
            (nnopds-progress-before-download connection publication)
            (message "nnopds: Downloading %s..." (nnopds--publication-title publication))
            (let* ((started (float-time))
                   (response (nnopds--request connection "GET" (nnopds--publication-acquisition publication)
                                              nil nil '(("Accept" . "application/epub+zip, application/octet-stream;q=0.9, */*;q=0.1"))
                                              nil temporary)))
              (unless (= (plist-get response :status) 200)
                (error "EPUB download: HTTP %s" (plist-get response :status)))
              (message "nnopds: Downloaded %s (%.2fs)" (nnopds--publication-title publication)
                       (- (float-time) started))))
          (message "nnopds: Validating %s EPUB..." (if temporary "downloaded" "cached"))
          (setq digest (nnepub--fingerprint (or temporary file)))
          (when (and (plist-get index :digest) (not (equal (plist-get index :digest) digest)))
            (error "EPUB content changed within the same OPDS version"))
          ;; Checkpoint the edition identity and the completed download before
          ;; extraction/indexing, so a crash there never loses the EPUB cache.
          (unless (equal (plist-get index :digest) digest)
            (setq index (plist-put index :digest digest))
            (nnopds--write-json index-file index))
          (when temporary (rename-file temporary file t))
          (setq book (nnepub--load-book file (nnepub--file-signature file) digest))
          (setf (nnepub--book-group book) group
                (nnepub--book-title book) (nnopds--publication-title publication))
          (unless (string-empty-p (nnopds--publication-author publication))
            (setf (nnepub--book-author book) (nnopds--publication-author publication)))
          (let ((value (list :count (length (nnepub--book-chapters book)) :digest digest)))
            (unless (equal index value) (nnopds--write-json index-file value)))
          (setq success t)
          book)
      (unless success (when book (nnepub--dispose-book book)))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(cl-defmethod nnopds--chapters ((_format (eql epub)) data) (nnepub--book-chapters data))
(cl-defmethod nnopds--header ((_format (eql epub)) data chapter) (nnepub--header data chapter))
(cl-defmethod nnopds--article ((_format (eql epub)) data chapter group) (nnepub--mime data chapter group t))
(cl-defmethod nnopds--dispose ((_format (eql epub)) data) (nnepub--dispose-book data))
(cl-defmethod nnopds--prepare-reader ((_format (eql epub)) _data) (nnopds-progress-prepare))

(cl-defmethod nnopds--locator ((_format (eql epub)) data chapter)
  ;; Supplementary footnotes must not replace the main reading position.
  (when (member (plist-get chapter :path) (nnepub--book-spine data))
    (list :href (url-encode-url (file-relative-name (plist-get chapter :path) (nnepub--book-root data)))
          :type (plist-get chapter :type) :locations (list :progression 0.0))))

(cl-defmethod nnopds--locate ((_format (eql epub)) data locator)
  (when-let* ((href (plist-get locator :href))
              ((not (string-empty-p href))))
    (pcase-let* ((`(,path . ,fragment)
                  (nnepub--resolve (nnepub--book-root data)
                                   (expand-file-name "locator" (nnepub--book-root data)) href))
                 (chapter (cl-find path (nnepub--book-chapters data)
                                   :key (lambda (entry) (plist-get entry :path)) :test #'equal)))
      (when chapter (cons (plist-get chapter :number) fragment)))))

(defun nnopds--chapter (publication article)
  "Find PUBLICATION's ARTICLE by number or Message-ID."
  (let ((data (nnopds--publication-data publication)))
    (or (cl-find-if (lambda (chapter)
                      (if (integerp article) (= article (plist-get chapter :number))
                        (equal article (mail-header-id
                                        (nnopds--header (nnopds--publication-format publication) data chapter)))))
                    (nnopds--chapters (nnopds--publication-format publication) data))
        (error "No such OPDS article: %s" article))))

;;; Gnus interface

(deffoo nnopds-open-server (server &optional definitions)
  (nnopds--report-errors
    (unless (nnoo-current-server-p 'nnopds server) (nnoo-change-server 'nnopds server definitions))
    (unless nnopds--connection
      (unless (memq nnopds-auth-method '(basic digest))
        (error "Unsupported HTTP authentication method: %s" nnopds-auth-method))
      (let* ((url (nnopds--url (or nnopds-url nnopds-address server)))
             (headers (nnopds--credentials url))
             (directory (expand-file-name (secure-hash 'sha256 (prin1-to-string (list (or nnopds-address server) url headers)))
                                          (expand-file-name "nnopds/" gnus-cache-directory))))
        (make-directory directory t)
        (set-file-modes directory #o700)
        (setq nnopds--connection
              (nnopds--make-connection :name server :url url :headers headers :directory directory
                                      :publications (make-hash-table :test #'equal) :auth-method nnopds-auth-method
                                      :counts (or (nnopds--read-json (expand-file-name "counts.json" directory) 'hash-table)
                                                  (make-hash-table :test #'equal))))
        (nnopds-progress-configure nnopds--connection)
        (when-let* ((cached (nnopds--read-json (nnopds--cache-file nnopds--connection "catalog.json"))))
          (nnopds--install-catalog nnopds--connection
                                  (seq-map (lambda (document) (nnopds--publication document nil nnopds--connection))
                                           (plist-get cached :publications)))
          (setf (nnopds--connection-fetched nnopds--connection) (plist-get cached :fetched)))))
    t))

(deffoo nnopds-close-server (&optional server _definitions)
  (setq server (or server (nnoo-current-server 'nnopds)))
  (when (and server (or (nnoo-current-server-p 'nnopds server)
                        (assoc server (cddr (assq 'nnopds nnoo-state-alist)))))
    (unless (nnoo-current-server-p 'nnopds server)
      (nnoo-change-server 'nnopds server nil))
    (when-let* ((connection nnopds--connection))
      (dolist (reader (copy-sequence (nnopds--connection-readers connection)))
        (nnopds-progress-close (cdr reader)))
      (maphash (lambda (_group publication)
                 (when-let* ((data (nnopds--publication-data publication)))
                   (nnopds--close-reader (nnopds--publication-format publication) data)))
               (nnopds--connection-publications connection))
      (setf (nnopds--connection-closed connection) t)
      (dolist (process (copy-sequence (nnopds--connection-processes connection)))
        (when (process-live-p process) (delete-process process)))
      (maphash (lambda (_group publication)
                 (when-let* ((data (nnopds--publication-data publication)))
                   (nnopds--dispose (nnopds--publication-format publication) data)))
               (nnopds--connection-publications connection)))
    (setq nnopds--connection nil nnopds--group nil)
    (nnoo-close-server 'nnopds server))
  t)

(deffoo nnopds-request-close ()
  (dolist (server (nnopds--servers))
    (nnopds-close-server server))
  (nnoo-close 'nnopds))

(deffoo nnopds-request-list (&optional server)
  (nnopds--report-errors
    (let ((connection (nnopds--change-server server)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer)
        (dolist (group (nnopds--connection-catalog connection))
          (insert (format "%s %d 1 n\n" group
                          (or (nnopds--publication-count (gethash group (nnopds--connection-publications connection))) 1))))))
    t))

(deffoo nnopds-request-group (group &optional server fast _info)
  (nnopds--report-errors
    (let ((publication (nnopds--get-publication group server (not fast))))
      (setq nnopds--group group)
      (unless fast
        (with-current-buffer nntp-server-buffer
          (erase-buffer)
          (insert (format "211 %d 1 %d %s\n" (nnopds--publication-count publication)
                          (nnopds--publication-count publication) group))))
      t)))

(deffoo nnopds-close-group (group &optional server)
  (nnopds--report-errors
    (let ((connection (nnopds--change-server server)))
      (when-let* ((reader (cdr (assoc group (nnopds--connection-readers connection)))))
        (nnopds-progress-close reader))
      (when-let* ((publication (gethash group (nnopds--connection-publications connection)))
                  (data (nnopds--publication-data publication)))
        (nnopds--close-reader (nnopds--publication-format publication) data)))
    (setq nnopds--group nil)
    t))

(deffoo nnopds-retrieve-headers (articles &optional group server _fetch-old)
  (nnopds--report-errors
    (let* ((publication (nnopds--get-publication group server t))
           (format (nnopds--publication-format publication))
           (data (nnopds--publication-data publication)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer)
        (dolist (article (if (and (consp articles) (stringp (car articles))) articles (range-uncompress articles)))
          (nnheader-insert-nov (nnopds--header format data (nnopds--chapter publication article)))))
      'nov)))

(deffoo nnopds-request-article (article &optional group server to-buffer)
  (nnopds--report-errors
    (let* ((publication (nnopds--get-publication group server t))
           (chapter (nnopds--chapter publication article))
           (name (gnus-group-prefixed-name (nnopds--publication-group publication)
                                          (list 'nnopds (nnoo-current-server 'nnopds)))))
      (with-current-buffer (or to-buffer nntp-server-buffer)
        (erase-buffer)
        (insert (nnopds--article (nnopds--publication-format publication)
                                (nnopds--publication-data publication) chapter name)))
      (cons (nnopds--publication-group publication) (plist-get chapter :number)))))

(deffoo nnopds-request-scan (&optional _group server)
  (nnopds--report-errors (nnopds--change-server server) t))

(deffoo nnopds-request-list-newsgroups (&optional server)
  (nnopds--report-errors
    (let ((connection (nnopds--change-server server)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer)
        (dolist (group (nnopds--connection-catalog connection))
          (insert group "\t" (nnopds--publication-title (gethash group (nnopds--connection-publications connection))) "\n"))))
    t))

(deffoo nnopds-request-group-description (group &optional server)
  (nnopds--report-errors
    (let ((publication (nnopds--get-publication group server)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer) (insert group "\t" (nnopds--publication-title publication) "\n")))
    t))

(deffoo nnopds-request-post (&optional _server)
  (nnheader-report 'nnopds "OPDS publications are read-only"))

(unless (assoc "nnopds" gnus-valid-select-methods)
  (gnus-declare-backend "nnopds" 'none 'address))

(defun nnopds--browse-server (original server &optional return-buffer)
  "Browse OPDS SERVER hierarchically, delegating other servers to ORIGINAL."
  (let ((method (gnus-server-to-method server)))
    (if (eq (car-safe method) 'nnopds)
        (nnopds-browse method return-buffer)
      (funcall original server return-buffer))))

(with-eval-after-load 'gnus-srvr
  (advice-add 'gnus-browse-foreign-server :around #'nnopds--browse-server))

(defun nnopds--prepare-summary ()
  "Prepare the reading format of this OPDS summary."
  (when (string-match-p "\\`nnopds[+:]" gnus-newsgroup-name)
    (let* ((method (gnus-find-method-for-group gnus-newsgroup-name))
           (publication (nnopds--get-publication (gnus-group-real-name gnus-newsgroup-name)
                                                (nth 1 method) t)))
      (nnopds--prepare-reader (nnopds--publication-format publication)
                             (nnopds--publication-data publication)))))

(with-eval-after-load 'gnus-sum
  (add-to-list 'gnus-parameters
               '("\\`nnopds[+:]"
                 (display . all)
                 (gnus-large-newsgroup nil)
                 (mm-text-html-renderer 'nnepub--render-html)
                 (gnus-show-threads nil)
                 (gnus-article-sort-functions '(gnus-article-sort-by-number))
                 (gnus-thread-sort-functions '(gnus-thread-sort-by-number))))
  (add-hook 'gnus-summary-prepared-hook #'nnopds--prepare-summary))

(provide 'nnopds)
;;; nnopds.el ends here
