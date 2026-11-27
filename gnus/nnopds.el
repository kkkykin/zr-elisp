;;; nnopds.el --- Read OPDS 2 publications with Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An OPDS 2 catalog is a server, and chapters or pages are articles in each
;; book's Gnus group.  EPUB chapter and page readers use separate groups.
;; MuPDF renders local documents, and Divina supplies streamed comic images.
;; Browse catalog directories and pagination with `nnopds-browse', caching
;; visited pages locally.  The standard Gnus server browser lists known
;; publications through `nnopds-request-list'.
;; Group deletion forgets a publication locally; with a prefix argument it
;; also removes its downloaded cache.  Browsing can discover the book again.
;; Reading formats and progress protocols have separate interfaces for
;; future extensions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'url-expand)
(require 'url-parse)
(require 'auth-source)
(require 'zr-http)
(require 'zr-epub)
(require 'gnus-start)
(require 'gnus-range)
(require 'nnoo)
(require 'nnheader)
(require 'zr-gnus-epub)

(autoload 'nnopds-progress-prepare "nnopds-progress")
(autoload 'nnopds-progress-close "nnopds-progress")
(autoload 'nnopds-progress-configure "nnopds-progress")
(autoload 'nnopds-progress-before-download "nnopds-progress")
(autoload 'nnopds-progress-loaded "nnopds-progress")
(autoload 'nnopds-resume "nnopds-progress" nil t)
(autoload 'nnopds-save-position "nnopds-progress" nil t)
(autoload 'nnopds-browse "nnopds-browse" nil t)
(autoload 'nnopds-browse-search "nnopds-browse" nil t)
(autoload 'nnopds-comic--load "nnopds-comic")
(autoload 'nnopds-mupdf--load "nnopds-mupdf")
(autoload 'nnopds-mupdf--cache-document "nnopds-mupdf")
(autoload 'nnopds-mupdf--program "nnopds-mupdf")

(defgroup nnopds nil "OPDS 2 publications in Gnus." :group 'gnus)

(defcustom nnopds-http-options nil
  "HTTP options overriding `zr-http-default-options' for OPDS requests."
  :type 'sexp :group 'nnopds)

(defcustom nnopds-catalog-cache-ttl nil
  "Seconds before a visited OPDS page is fetched again.
Nil reuses cached pages until explicitly refreshed.  Zero always revalidates
visited pages.  Gnus startup only reads the local publication index."
  :type '(choice (const :tag "Refresh manually" nil) natnum) :group 'nnopds)

(defcustom nnopds-book-readers '((epub . zr-epub))
  "Readers by book format, used in Gnus article buffers.
Formats without an entry use `zr-doc-view' for page images.
The `zr-epub' reader displays EPUB chapters."
  :type '(alist :key-type (choice (const epub) (const pdf) (const cbz))
                :value-type (choice (const zr-epub) (const zr-doc-view)))
  :group 'nnopds)

(nnoo-declare nnopds)
(defvoo nnopds-url nil "OPDS 2 catalog URL.  Defaults to the server name.")
(defvoo nnopds-address nil "Catalog address or original server name for Gnus temporary groups.")
(defvoo nnopds-user nil "HTTP user, optionally looked up in auth-source.")
(defvoo nnopds-password nil "HTTP password.  Prefer auth-source.")
(defvoo nnopds-auth-method 'basic "HTTP authentication method: basic or digest.")
(defvoo nnopds-headers nil
  "Additional HTTP headers, for example an API key or a reverse proxy token.
Also sent to the KOReader sync server when it shares the catalog's origin.")
(defvoo nnopds-progress-protocol 'koreader "Reading position protocol.  Currently supports koreader.")
(defvoo nnopds-koreader-url nil "Explicit KOReader sync base URL.  Nil keeps reading positions local.")
(defvoo nnopds-koreader-user nil "KOReader username, or a Komga API key; optionally looked up in auth-source.")
(defvoo nnopds-koreader-password nil "KOReader password.  Prefer auth-source; Komga does not require it.")
(defvoo nnopds--connection nil)
(defvoo nnopds--group nil)

;; Protocol modules inline accessors; append fields to keep their offsets stable.
(cl-defstruct (nnopds--connection (:constructor nnopds--make-connection))
  name url headers directory catalog publications requests readers fetched closed progress auth-method counts)

(cl-defstruct (nnopds--publication (:constructor nnopds--make-publication))
  group title author modified acquisition format progress document data count stream reader edition data-source)

(cl-defstruct (nnopds--request-state (:constructor nnopds--make-request-state))
  request done response error)

(nnoo-define-basics nnopds)

(defmacro nnopds--report-errors (&rest body)
  "Run BODY, returning nil and reporting failures to Gnus and Messages."
  (declare (indent 0) (debug t))
  `(condition-case err (progn ,@body)
     (error
      (let ((reason (error-message-string err)))
        (message "nnopds: %s" reason)
        (nnheader-report 'nnopds "%s" reason)))))

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

(defun nnopds--request (connection method url &optional data callback request-headers authentication output-file)
  "Request URL with METHOD and optional JSON DATA using CONNECTION.
With CALLBACK, return a request state and call it once with (RESPONSE ERROR).
Without CALLBACK, wait while allowing process output and quit.
AUTHENTICATION replaces catalog credentials with :headers scoped to :url.
With OUTPUT-FILE the response contains :file instead of the byte :body.
Redirects are bounded; credentials only go to their configured origin."
  (let ((state (nnopds--make-request-state))
        (options (copy-tree nnopds-http-options)))
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
                 (when (nnopds--connection-closed connection) (error "OPDS server is closed"))
                 (let* ((headers
                         (append request-headers
                                 (when (equal (nnopds--origin target)
                                              (nnopds--origin (if authentication (plist-get authentication :url)
                                                               (nnopds--connection-url connection))))
                                   (if authentication (plist-get authentication :headers)
                                     (nnopds--connection-headers connection)))))
                        (digest-header
                         (when (and (not authentication)
                                    (eq (nnopds--connection-auth-method connection) 'digest))
                           (assoc-string "Authorization" headers t)))
                        (digest-user
                         (when (and digest-header (string-prefix-p "Basic " (cdr digest-header)))
                           (decode-coding-string (base64-decode-string (substring (cdr digest-header) 6)) 'utf-8)))
                        (headers (if digest-user (remq digest-header headers) headers))
                        request)
                   (when (and data (not (assoc-string "Content-Type" headers t)))
                     (push '("Content-Type" . "application/json") headers))
                   (setq request
                         (zr-http-request
                          target :options options :method method :headers headers
                          :body (when data (encode-coding-string data 'utf-8 t))
                          :output-file output-file
                          :auth (when digest-user
                                  (let ((separator (string-search ":" digest-user)))
                                    (list :scheme 'digest :user (substring digest-user 0 separator)
                                          :password (substring digest-user (1+ separator)))))
                          :callback
                          (lambda (response failure)
                            (setf (nnopds--connection-requests connection)
                                  (delq request (nnopds--connection-requests connection)))
                            (if failure
                                (finish nil failure)
                              (let ((status (plist-get response :status))
                                    (location (cdr (assoc "location" (plist-get response :headers)))))
                                (if (and location (memq status '(301 302 303 307 308)))
                                    (if (or (>= redirects 5)
                                            (and (not (equal method "GET")) (not (memq status '(307 308)))))
                                        (finish nil "Unsupported or excessive HTTP redirects")
                                      (start (nnopds--url location target) (1+ redirects)))
                                  (finish response nil)))))))
                   (setf (nnopds--request-state-request state) request)
                   (push request (nnopds--connection-requests connection))))
             (error (finish nil (error-message-string err))))))
      (start (nnopds--url url) 0))
    (if callback state
      (save-excursion
        (unwind-protect
            (progn
              (while (not (nnopds--request-state-done state)) (accept-process-output nil 0.05))
              (when-let* ((error (nnopds--request-state-error state))) (error "%s" error))
              (nnopds--request-state-response state))
          (when-let* ((request (nnopds--request-state-request state)))
            (zr-http-cancel request)))))))

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

(defconst nnopds--formats
  '((epub "application/epub+zip")
    (pdf "application/pdf")
    (cbz "application/x-cbz" "application/vnd.comicbook+zip"))
  "Reading formats and their link media types.")

(cl-defgeneric nnopds--chapters (reader data) "Return READER DATA's numbered resources.")
(cl-defgeneric nnopds--header (reader data chapter group) "Return CHAPTER's Gnus header for GROUP.")
(cl-defgeneric nnopds--article (reader data chapter group) "Return CHAPTER's MIME article in GROUP.")
(cl-defgeneric nnopds--dispose (reader data) "Free temporary reading DATA for READER.")
(cl-defgeneric nnopds--locator (reader data chapter) "Return CHAPTER's portable locator, or nil.")
(cl-defgeneric nnopds--locate (reader data locator) "Return (NUMBER . FRAGMENT) for LOCATOR, or nil.")
(cl-defgeneric nnopds--prepare-reader (reader data)
  "Prepare READER DATA's current Gnus summary.
Return the saved article number, or nil if none.")
(cl-defgeneric nnopds--close-reader (reader data) "Close READER DATA's reading sessions.")
(cl-defmethod nnopds--close-reader (_reader _data) nil)
(cl-defgeneric nnopds--reading-p (data)
  "Return non-nil if DATA has an active page reader.")
(cl-defmethod nnopds--reading-p (_data) nil)

(defun nnopds--group-label (text fallback)
  "Return up to 64 letters or digits from TEXT, joined by hyphens.
Use FALLBACK when TEXT contains no letters or digits."
  (let ((label (string-trim (replace-regexp-in-string "[^[:alnum:]]+" "-" text) "-+" "-+")))
    (if (string-empty-p label) fallback
      (substring label 0 (min 64 (length label))))))

(defun nnopds--group-name (title author source modified)
  "Return a readable group for TITLE and AUTHOR's edition at SOURCE.
MODIFIED distinguishes editions; nil denotes an unversioned publication."
  (string-join
   (list "book" (nnopds--group-label title "untitled")
         (nnopds--group-label author "unknown-author")
         (substring (secure-hash 'sha256
                                 (encode-coding-string (concat source "\0" (or modified "unversioned")) 'utf-8))
                    0 16))
   "."))

(defun nnopds--acquisition-link (links format)
  "Return the first usable link for FORMAT from LINKS."
  (seq-find
   (lambda (link)
     (and (plist-get link :href)
          (not (eq t (plist-get link :templated)))
          (if (eq format 'divina)
              (equal (nnopds--media-type link) "application/divina+json")
            (and (member (nnopds--media-type link) (alist-get format nnopds--formats))
                 (seq-some (lambda (rel) (nnopds--rel-p link rel))
                           '("http://opds-spec.org/acquisition" "http://opds-spec.org/acquisition/open-access"
                             "acquisition" "download"))))))
   links))

(defun nnopds--publication (document base &optional connection)
  "Convert an OPDS publication DOCUMENT at BASE into a reading entry.
With nil BASE, DOCUMENT already has absolute URLs, as in the catalog cache."
  (let* ((document (if base (nnopds--normalize document base) document))
         (links (plist-get document :links))
         (stream (plist-get (nnopds--acquisition-link links 'divina) :href))
         (download (seq-some (lambda (format)
                               (when-let* ((link (nnopds--acquisition-link links format)))
                                 (cons format (plist-get link :href))))
                             (if stream '(cbz) '(epub pdf cbz))))
         (acquisition (cdr download))
         (self (cl-find-if (lambda (link) (nnopds--rel-p link "self")) links))
         (format (if stream 'cbz (car download)))
         (metadata (plist-get document :metadata)))
    (when (or stream acquisition)
      (let* ((source (or (plist-get self :href) stream acquisition))
             (modified (plist-get metadata :modified))
             (title (zr-epub-single-line (plist-get metadata :title)))
             (author (plist-get metadata :author))
             (author (zr-epub-single-line
                      (if (stringp author) author
                        (string-join (mapcar (lambda (entry) (if (stringp entry) entry (or (plist-get entry :name) "")))
                                             (if (and (listp author) (plist-get author :name)) (list author) author)) ", "))))
             (group (nnopds--group-name title author source modified)))
        (nnopds--make-publication
         :group group :edition group :modified modified :document document
         :title title :author author
         :format format :reader (if (eq format 'epub) 'zr-epub 'zr-doc-view)
         :acquisition acquisition :stream stream
         :progress (when (and connection (eq format 'epub))
                     (copy-sequence (nnopds--connection-progress connection))))))))

(defun nnopds--cache-file (connection name)
  "Return cache NAME in CONNECTION's account directory."
  (expand-file-name name (nnopds--connection-directory connection)))

(defun nnopds--temporary-file (file &optional suffix)
  "Create a short-named temporary sibling of FILE, optionally with SUFFIX."
  (let ((directory (file-name-directory (expand-file-name file))))
    (make-directory directory t)
    (make-temp-file (expand-file-name ".nnopds-" directory) nil suffix)))

(defun nnopds--download-file (connection publication)
  "Return the full download path for PUBLICATION on CONNECTION, if offered."
  (when (nnopds--publication-acquisition publication)
    (let ((format (nnopds--publication-format publication))
          (key (secure-hash 'sha256 (nnopds--publication-edition publication))))
      (nnopds--cache-file connection (if (eq format 'epub) (concat key ".epub")
                                       (format "%s.%s/book.%s" key format format))))))

(defun nnopds--ensure-download (connection publication file validate)
  "Validate cached FILE or download PUBLICATION on CONNECTION atomically.
Return the result of calling VALIDATE on the cached or freshly downloaded file."
  (if (file-readable-p file)
      (funcall validate file)
    (let* ((format (nnopds--publication-format publication))
           (url (nnopds--publication-acquisition publication))
           (title (nnopds--publication-title publication))
           (accept (string-join (alist-get format nnopds--formats) ", "))
           (temporary (nnopds--temporary-file file (file-name-extension file t)))
           (started (float-time)))
      (unwind-protect
          (progn
            (when (eq format 'epub)
              (nnopds-progress-before-download
               connection (or (nnopds--find-publication connection (nnopds--publication-edition publication))
                              publication)))
            (message "nnopds: Downloading %s..." title)
            (let ((response (nnopds--request
                             connection "GET" url nil nil
                             (list (cons "Accept" (concat accept ", application/octet-stream;q=0.9, */*;q=0.1")))
                             nil temporary)))
              (unless (= (plist-get response :status) 200)
                (error "%s download: HTTP %s" (upcase (symbol-name format)) (plist-get response :status))))
            (prog1 (funcall validate temporary)
              (rename-file temporary file t)
              (message "nnopds: Downloaded %s (%.2fs)" title (- (float-time) started))))
        (when (file-exists-p temporary) (delete-file temporary))))))

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
          (when old
            (setf (nnopds--publication-data entry) (nnopds--publication-data old)
                  (nnopds--publication-data-source entry) (nnopds--publication-data-source old)))
          (setf (nnopds--publication-count entry)
                (or (and old (nnopds--publication-count old))
                    (gethash group (nnopds--connection-counts connection))))
          (puthash group entry table)
          (unless (gethash group seen)
            (puthash group t seen)
            (push group catalog)))))
    (setf (nnopds--connection-catalog connection) (nreverse catalog))))

(defun nnopds--save-catalog (connection catalog)
  "Persist CATALOG's known publications on CONNECTION."
  (let ((table (nnopds--connection-publications connection))
        (fetched (float-time)))
    (nnopds--write-json (nnopds--cache-file connection "catalog.json")
                        (list :fetched fetched
                              :publications
                              (vconcat (mapcar (lambda (group)
                                                 (nnopds--publication-document (gethash group table)))
                                               catalog))))
    (setf (nnopds--connection-catalog connection) catalog
          (nnopds--connection-fetched connection) fetched)))

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
                (nnopds--publication-data-source entry) (and old (nnopds--publication-data-source old))
                (nnopds--publication-count entry)
                (or (and old (nnopds--publication-count old))
                    (gethash group (nnopds--connection-counts connection))))
          (unless old (push group additions))
          (puthash group entry table)
          (setq changed t))
        (puthash (car pair) entry entries)))
    (when changed
      (nnopds--save-catalog connection
                            (append (nnopds--connection-catalog connection) (nreverse additions))))
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

(defun nnopds--find-publication (connection group)
  "Look up GROUP, deriving a page group from its canonical EPUB when needed."
  (let* ((table (nnopds--connection-publications connection))
         (entry (gethash group table)))
    (if (and group (string-suffix-p ".pages" group))
        (when-let* ((book (gethash (string-remove-suffix ".pages" group) table))
                    ((eq (nnopds--publication-format book) 'epub)))
          (unless entry
            (setq entry (copy-nnopds--publication book))
            (setf (nnopds--publication-group entry) group
                  (nnopds--publication-reader entry) 'zr-doc-view
                  (nnopds--publication-count entry) (gethash group (nnopds--connection-counts connection))
                  (nnopds--publication-data entry) nil
                  (nnopds--publication-data-source entry) nil
                  (nnopds--publication-progress entry) nil)
            (puthash group entry table))
          (setf (nnopds--publication-document entry) (nnopds--publication-document book)
                (nnopds--publication-acquisition entry) (nnopds--publication-acquisition book))
          entry)
      entry)))

(defun nnopds--preferred-publication (connection publication)
  "Return PUBLICATION's group for the configured reader on CONNECTION."
  (let* ((format (nnopds--publication-format publication))
         (reader (alist-get format nnopds-book-readers 'zr-doc-view)))
    (pcase reader
      ('zr-doc-view
       (if (eq format 'epub)
           (nnopds--find-publication connection (concat (nnopds--publication-edition publication) ".pages"))
         publication))
      ('zr-epub
       (unless (eq format 'epub) (user-error "zr-epub only reads EPUB files"))
       (nnopds--find-publication connection (nnopds--publication-edition publication)))
      (_ (user-error "Unknown reader for %s: %s" format reader)))))

(defun nnopds--reading-source (connection publication)
  "Choose local reading when the original exists, or use an advertised stream."
  (if (and (nnopds--publication-stream publication)
           (not (when-let* ((file (nnopds--download-file connection publication)))
                  (file-readable-p file))))
      'stream
    'local))

(defun nnopds--load-publication (source connection publication)
  "Load PUBLICATION's reading data from SOURCE on CONNECTION."
  (cond
   ((eq source 'stream) (nnopds-comic--load connection publication))
   ((eq (nnopds--publication-reader publication) 'zr-epub) (nnopds--load-epub connection publication))
   (t (nnopds-mupdf--load connection publication))))

(defun nnopds--get-publication (group &optional server load)
  "Return GROUP's publication on SERVER, optionally LOAD reading data."
  (let* ((connection (nnopds--change-server server))
         (publication (or (nnopds--find-publication connection (or group nnopds--group))
                          (error "OPDS publication unavailable; browse its catalog directory: %s" group))))
    (when load
      (let ((source (nnopds--reading-source connection publication))
            (old (nnopds--publication-data publication))
            (reader (nnopds--publication-reader publication)))
        ;; A Summary keeps its numbered articles until it is closed.
        (when (or (null old)
                  (and (not (eq source (nnopds--publication-data-source publication)))
                       (not (nnopds--reading-p old))))
          (let* ((data (nnopds--load-publication source connection publication))
                 (count (length (nnopds--chapters reader data)))
                 (counts (nnopds--connection-counts connection))
                 (name (nnopds--publication-group publication)))
            (when old (nnopds--dispose reader old))
            (setf (nnopds--publication-data publication) data
                  (nnopds--publication-data-source publication) source
                  (nnopds--publication-count publication) count)
            (unless (equal count (gethash name counts))
              (puthash name count counts)
              (nnopds--write-json (nnopds--cache-file connection "counts.json") counts)))))
      (nnopds-progress-loaded publication))
    publication))

(defun nnopds--cache-epub (connection publication file)
  "Cache PUBLICATION's EPUB in FILE on CONNECTION and return its index."
  (let ((index-file (file-name-with-extension file "json")))
    (nnopds--ensure-download
     connection publication file
     (lambda (candidate)
       (message "nnopds: Validating %s EPUB..." (if (equal candidate file) "cached" "downloaded"))
       (unless (equal candidate file)
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (insert-file-contents-literally candidate nil 0 4)
           (unless (equal (buffer-string) "PK\003\004") (error "Downloaded content is not an EPUB"))))
       (let* ((digest (zr-epub-file-digest candidate))
              (index (nnopds--read-json index-file)))
         (when (and (plist-get index :digest) (not (equal (plist-get index :digest) digest)))
           (error "EPUB content changed within the same OPDS version"))
         ;; Save the completed download's identity before extraction and indexing.
         (unless (equal (plist-get index :digest) digest)
           (setq index (plist-put index :digest digest))
           (nnopds--write-json index-file index))
         index)))))

(defun nnopds--load-epub (connection publication)
  "Load PUBLICATION's EPUB chapters from CONNECTION's original file cache."
  (let* ((file (nnopds--download-file connection publication))
         (index (nnopds--cache-epub connection publication file))
         book success)
    (unwind-protect
        (progn
          (setq book (zr-epub-open file))
          (unless (string-empty-p (nnopds--publication-author publication))
            (setf (zr-epub-book-author book) (nnopds--publication-author publication)))
          (let ((count (length (zr-epub-book-chapters book))))
            (unless (equal (plist-get index :count) count)
              (nnopds--write-json (file-name-with-extension file "json") (plist-put index :count count))))
          (setq success t)
          book)
      (when (and book (not success)) (zr-epub-close book)))))

(cl-defmethod nnopds--chapters ((_reader (eql zr-epub)) data) (zr-epub-book-chapters data))
(cl-defmethod nnopds--header ((_reader (eql zr-epub)) data chapter group)
  (zr-gnus-epub-header data chapter (gnus-group-real-name group)))
(cl-defmethod nnopds--article ((reader (eql zr-epub)) data chapter group)
  (zr-gnus-epub-article data chapter group (nnopds--header reader data chapter group)))
(cl-defmethod nnopds--dispose ((_reader (eql zr-epub)) data) (zr-epub-close data))
(cl-defmethod nnopds--prepare-reader ((_reader (eql zr-epub)) _data)
  (zr-gnus-epub-prepare-summary)
  (nnopds-progress-prepare))

(cl-defmethod nnopds--locator ((_reader (eql zr-epub)) data chapter)
  ;; Supplementary footnotes must not replace the main reading position.
  (when (member (plist-get chapter :path) (zr-epub-book-spine data))
    (list :href (url-encode-url (file-relative-name (plist-get chapter :path) (zr-epub-book-root data)))
          :type (plist-get chapter :type) :locations (list :progression 0.0))))

(cl-defmethod nnopds--locate ((_reader (eql zr-epub)) data locator)
  (when-let* ((href (plist-get locator :href))
              ((not (string-empty-p href))))
    (pcase-let* ((`(,path . ,fragment)
                  (zr-epub-resolve (zr-epub-book-root data)
                                   (expand-file-name "locator" (zr-epub-book-root data)) href))
                 (chapter (cl-find path (zr-epub-book-chapters data)
                                   :key (lambda (entry) (plist-get entry :path)) :test #'equal)))
      (when chapter (cons (plist-get chapter :number) fragment)))))

(defun nnopds--chapter (publication article)
  "Find PUBLICATION's ARTICLE by number or Message-ID."
  (let ((data (nnopds--publication-data publication))
        (reader (nnopds--publication-reader publication))
        (group (nnopds--publication-group publication)))
    (or (cl-find-if (lambda (chapter)
                      (if (integerp article) (= article (plist-get chapter :number))
                        (equal article (mail-header-id
                                         (nnopds--header reader data chapter group)))))
                    (nnopds--chapters reader data))
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
                   (nnopds--close-reader (nnopds--publication-reader publication) data)))
               (nnopds--connection-publications connection))
      (setf (nnopds--connection-closed connection) t)
      (mapc #'zr-http-cancel (copy-sequence (nnopds--connection-requests connection)))
      (maphash (lambda (_group publication)
                 (when-let* ((data (nnopds--publication-data publication)))
                   (nnopds--dispose (nnopds--publication-reader publication) data)))
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
          (let ((book (nnopds--preferred-publication connection (nnopds--find-publication connection group))))
            (insert (format "%s %d 1 n\n" (nnopds--publication-group book)
                            (or (nnopds--publication-count book) 1)))))))
    t))

(deffoo nnopds-request-group (group &optional server fast info)
  (nnopds--report-errors
    (let* ((publication (nnopds--get-publication group server t))
           (count (nnopds--publication-count publication)))
      (setq nnopds--group group)
      ;; Gnus can select a subscribed group using its cached active range.
      ;; FAST skips the response, but still needs the book's real chapter count.
      (when (and fast info)
        (gnus-set-active (gnus-info-group info) (cons 1 count)))
      (unless fast
        (with-current-buffer nntp-server-buffer
          (erase-buffer)
          (insert (format "211 %d 1 %d %s\n" count count group))))
      t)))

(deffoo nnopds-close-group (group &optional server)
  (nnopds--report-errors
    (let ((connection (nnopds--change-server server)))
      (when-let* ((reader (cdr (assoc group (nnopds--connection-readers connection)))))
        (nnopds-progress-close reader))
      (when-let* ((publication (gethash group (nnopds--connection-publications connection)))
                  (data (nnopds--publication-data publication)))
        (nnopds--close-reader (nnopds--publication-reader publication) data)))
    (setq nnopds--group nil)
    t))

(deffoo nnopds-request-delete-group (group &optional force server)
  "Forget GROUP locally on SERVER, closing its reading sessions.
With FORCE, also delete its downloaded files and local reading settings.
The remote publication remains available and browsing can register it again."
  (nnopds--report-errors
    (let* ((connection (nnopds--change-server server))
           (table (nnopds--connection-publications connection))
           (publication (nnopds--find-publication connection group))
           (edition (if publication (nnopds--publication-edition publication) group))
           (paged-epub (not (equal group edition)))
           (groups (if (and (not paged-epub) publication (eq (nnopds--publication-format publication) 'epub))
                       (list group (concat group ".pages"))
                     (list group)))
           (catalog (remove group (nnopds--connection-catalog connection)))
           (counts (copy-hash-table (nnopds--connection-counts connection))))
      (dolist (reader (copy-sequence (nnopds--connection-readers connection)))
        (when (member (car reader) groups) (nnopds-progress-close (cdr reader))))
      (dolist (name groups)
        (when-let* ((book (gethash name table))
                    (data (nnopds--publication-data book)))
          (nnopds--dispose (nnopds--publication-reader book) data)
          (setf (nnopds--publication-data book) nil))
        (remhash name counts))
      (when force
        ;; All formats keep their files under the fixed-length group hash.
        (dolist (file (directory-files (nnopds--connection-directory connection) t
                                      (concat "\\`" (secure-hash 'sha256 edition)
                                              (if paged-epub "\\.epub-pages\\'" "\\."))))
          (if (file-directory-p file) (delete-directory file t) (delete-file file))))
      (nnopds--write-json (nnopds--cache-file connection "counts.json") counts)
      (nnopds--save-catalog connection catalog)
      (dolist (name groups) (remhash name table))
      (setf (nnopds--connection-counts connection) counts)
      (when (member nnopds--group groups) (setq nnopds--group nil))
      t)))

(deffoo nnopds-retrieve-headers (articles &optional group server _fetch-old)
  (nnopds--report-errors
    (let* ((publication (nnopds--get-publication group server t))
           (reader (nnopds--publication-reader publication))
           (data (nnopds--publication-data publication)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer)
        (dolist (article (if (and (consp articles) (stringp (car articles))) articles (range-uncompress articles)))
          (nnheader-insert-nov (nnopds--header reader data (nnopds--chapter publication article)
                                             (nnopds--publication-group publication)))))
      'nov)))

(deffoo nnopds-request-article (article &optional group server to-buffer)
  (nnopds--report-errors
    (let* ((publication (nnopds--get-publication group server t))
           (chapter (nnopds--chapter publication article))
           (name (gnus-group-prefixed-name (nnopds--publication-group publication)
                                          (list 'nnopds (nnoo-current-server 'nnopds)))))
      (with-current-buffer (or to-buffer nntp-server-buffer)
        (erase-buffer)
        (insert (nnopds--article (nnopds--publication-reader publication)
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
          (let ((book (nnopds--preferred-publication connection (nnopds--find-publication connection group))))
            (insert (nnopds--publication-group book) "\t" (nnopds--publication-title book) "\n")))))
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

(defun nnopds--summary-defaults ()
  "Set overridable reading defaults in OPDS summaries."
  (when (and gnus-newsgroup-name (eq (car (gnus-find-method-for-group gnus-newsgroup-name)) 'nnopds))
    (unless (assq 'display (gnus-group-find-parameter gnus-newsgroup-name))
      (gnus-group-add-parameter gnus-newsgroup-name '(display . all)))
    (zr-gnus-epub-summary-defaults)
    (setq-local gnus-large-newsgroup nil
                gnus-summary-goto-unread 'never)))

(defun nnopds--setup-summary ()
  "Arrange to prepare the OPDS reader when Gnus positions the initial subject."
  (when-let* ((method (gnus-find-method-for-group gnus-newsgroup-name))
              ((eq (car method) 'nnopds)))
    (let ((select-subject gnus-auto-select-subject)
          (local-select-subject (local-variable-p 'gnus-auto-select-subject)))
      (setq-local gnus-auto-select-subject
                  (lambda ()
                    (if local-select-subject
                        (setq gnus-auto-select-subject select-subject)
                      (kill-local-variable 'gnus-auto-select-subject))
                    (let* ((publication (nnopds--get-publication
                                         (gnus-group-real-name gnus-newsgroup-name) (nth 1 method) t))
                           (article (nnopds--prepare-reader (nnopds--publication-reader publication)
                                                            (nnopds--publication-data publication))))
                      (unless (and article (gnus-summary-goto-subject article t t))
                        (gnus-summary-auto-select-subject))))))))

(add-hook 'gnus-summary-mode-hook #'nnopds--summary-defaults)
(add-hook 'gnus-select-group-hook #'nnopds--setup-summary)

(provide 'nnopds)
;;; nnopds.el ends here
