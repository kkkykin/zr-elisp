;;; nnepub.el --- Read local EPUB books with Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A directory is a virtual server, each EPUB is a group, and its spine
;; resources are articles.  Configure
;; (nnepub "books" (nnepub-directory "~/Books/")) as a select method,
;; then use Gnus' server browser to subscribe to and read book groups.
;; Gnus stores subscriptions and article marks in its usual state files.
;; Changed EPUB contents get a new group; article numbers are never reused
;; for a different edition.  Supplementary XHTML resources follow the spine.
;;
;; Requires 7zz or 7z, and Emacs with libxml support.  EPUB container, OPF,
;; NCX and navigation processing was informed by Vasilij Schneidermann's
;; nov.el: https://depp.brause.cc/nov.el/nov.el .  No nov dependency is needed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dom)
(require 'xml)
(require 'url-util)
(require 'shr)
(require 'gnus)
(require 'gnus-start)
(require 'gnus-range)
(require 'nnheader)
(require 'nnoo)
(require 'mm-view)
(require 'rfc2047)

(declare-function gnus-summary-goto-article "gnus-sum" (article &optional all-headers force))

(defgroup nnepub nil
  "Local EPUB books in Gnus."
  :group 'gnus)

(defcustom nnepub-7z-program nil
  "7-Zip executable, or nil to find 7zz followed by 7z."
  :type '(choice (const :tag "Find automatically" nil) string)
  :group 'nnepub)

(nnoo-declare nnepub)

(defvoo nnepub-directory nil
  "Directory containing this server's EPUB files.
Defaults to the virtual server name.  Only this directory is scanned.")
(defvoo nnepub--books nil)
(defvoo nnepub--group nil)

(cl-defstruct (nnepub--book (:constructor nnepub--make-book))
  file signature root key group title author date chapters resources spine)

(defvar nnepub--path-cache nil
  "Path containment checks cached only while indexing one extracted book.")

(nnoo-define-basics nnepub)

(defmacro nnepub--report-errors (&rest body)
  "Run BODY, returning nil and reporting failures to Gnus."
  (declare (indent 0) (debug t))
  `(condition-case err
       (progn ,@body)
     (error (nnheader-report 'nnepub "%s" (error-message-string err)))))

(defun nnepub--local-name (name)
  "Return NAME without an XML namespace prefix."
  (if-let* ((colon (cl-position ?: (symbol-name name) :from-end t)))
      (intern (substring (symbol-name name) (1+ colon)))
    name))

(defun nnepub--elements (node tag)
  "Return NODE and descendants whose local name is TAG, in document order."
  (let (nodes)
    (cl-labels ((visit (node)
                  (when (consp node)
                    (when (eq (nnepub--local-name (dom-tag node)) tag) (push node nodes))
                    (dolist (child (dom-children node)) (visit child)))))
      (visit node))
    (nreverse nodes)))

(defun nnepub--first-element (node tag)
  "Return the first element with local name TAG, stopping when found."
  (when (consp node)
    (if (eq (nnepub--local-name (dom-tag node)) tag) node
      (cl-some (lambda (child) (nnepub--first-element child tag)) (dom-children node)))))

(defun nnepub--child (node tag)
  "Return the first direct child of NODE with local name TAG."
  (cl-find-if (lambda (child)
                (and (consp child)
                     (eq (nnepub--local-name (dom-tag child)) tag)))
              (dom-children node)))

(defun nnepub--attr (node name)
  "Return the attribute of NODE with local name NAME."
  (cdr (or (assq name (dom-attributes node))
           (cl-find-if (lambda (attr)
                         (eq (nnepub--local-name (car attr)) name))
                       (dom-attributes node)))))

(defun nnepub--header-text (text)
  "Make TEXT suitable for a single header or summary field."
  (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " (or text ""))))

(defun nnepub--text (node)
  "Return the text of NODE as a single line."
  (nnepub--header-text (and node (dom-inner-text node))))

(defun nnepub--decode-url (text)
  "Decode the UTF-8 URL component TEXT."
  (save-match-data
    (decode-coding-string (url-unhex-string text) 'utf-8)))

(defun nnepub--external-url-p (url)
  "Return non-nil if URL denotes an external resource."
  (string-match-p "\\`\\(?:[[:alpha:]][[:alnum:]+.-]*:\\|//\\)" url))

(defun nnepub--resolve (root base href)
  "Resolve HREF relative to BASE inside ROOT, returning (PATH . FRAGMENT).
External URLs and paths escaping the EPUB are rejected."
  (when (nnepub--external-url-p href)
    (error "External EPUB resource: %s" href))
  (string-match "\\`\\([^?#]*\\)\\(?:\\?[^#]*\\)?\\(?:#\\(.*\\)\\)?\\'" href)
  (let* ((part (nnepub--decode-url (match-string 1 href)))
         (fragment (when-let* ((value (match-string 2 href)))
                     (nnepub--decode-url value)))
         (path (if (string-empty-p part) base
                 (expand-file-name part (file-name-directory base)))))
    (unless
        (if (not nnepub--path-cache) (file-in-directory-p path root)
          ;; Extraction is complete and this tree stays unchanged during
          ;; indexing.  Cache canonical root/validated paths for this scope;
          ;; rendering later still performs fresh filesystem checks.
          (let* ((directory (file-name-as-directory root))
                 (key (cons directory path)))
            (or (gethash key nnepub--path-cache)
                (let ((true-root (or (gethash directory nnepub--path-cache)
                                     (puthash directory (file-name-as-directory (file-truename directory))
                                              nnepub--path-cache)))
                      (true-path (file-truename path)))
                  (when (or (equal true-path (directory-file-name true-root))
                            (string-prefix-p true-root true-path))
                    (puthash key t nnepub--path-cache))))))
      (error "EPUB resource outside book: %s" href))
    (cons path fragment)))

(defun nnepub--read-xml (file &optional html)
  "Parse FILE as XML, or HTML when HTML is non-nil."
  (with-temp-buffer
    (insert-file-contents file)
    (or (if html
            (libxml-parse-html-region (point-min) (point-max))
          (libxml-parse-xml-region (point-min) (point-max)))
        (error "Could not parse EPUB resource: %s" file))))

(defun nnepub--file-signature (file)
  "Return the modification time and size of FILE."
  (let ((attributes (file-attributes file)))
    (unless (and attributes (file-regular-p file) (file-readable-p file))
      (error "Unreadable EPUB file: %s" file))
    (list (file-attribute-modification-time attributes)
          (file-attribute-size attributes))))

(defun nnepub--fingerprint (file)
  "Return the SHA-256 digest of the bytes in FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun nnepub--extract (file root)
  "Extract FILE into ROOT with 7-Zip."
  (let ((program (or nnepub-7z-program
                     (executable-find "7zz") (executable-find "7z")
                     (error "Install 7zz or 7z, or set nnepub-7z-program"))))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (unless (eq 0 (call-process program nil t nil
                                    "x" "-y" "-bd" "-bb0" "-sccUTF-8"
                                    (concat "-o" root) "--" file))
          (error "7-Zip could not extract %s: %s"
                 file (string-trim (buffer-string))))))))

(defun nnepub--navigation (root package resources)
  "Read navigation titles from PACKAGE and RESOURCES inside ROOT.
Return a hash table of resource paths and their first navigation title."
  (let* ((spine (nnepub--child package 'spine))
         (nav (cl-find-if (lambda (item)
                            (member "nav" (split-string (or (plist-get item :properties) ""))))
                          resources))
         (ncx (cl-find (nnepub--attr spine 'toc) resources
                       :key (lambda (item) (plist-get item :id)) :test #'equal))
         (resource (or nav ncx))
         (titles (make-hash-table :test #'equal)))
    (when resource
      (let* ((file (plist-get resource :path))
             (document (nnepub--read-xml file))
             (navigation (if nav
                             (cl-find-if
                              (lambda (node)
                                (member "toc" (split-string (or (nnepub--attr node 'type) ""))))
                              (nnepub--elements document 'nav))
                           (nnepub--first-element document 'navMap)))
             (nodes (nnepub--elements navigation (if nav 'a 'navPoint))))
        (dolist (node nodes)
          (let* ((href (if nav (nnepub--attr node 'href)
                         (nnepub--attr (nnepub--child node 'content) 'src)))
                 (title (if nav (nnepub--text node)
                          (nnepub--text (nnepub--child node 'navLabel)))))
            (when (and href (not (nnepub--external-url-p href)))
              (let ((path (car (nnepub--resolve root file href))))
                (unless (or (gethash path titles) (string-empty-p title))
                  (puthash path title titles))))))))
    titles))

(defun nnepub--load-book (file signature &optional fingerprint)
  "Read FILE with SIGNATURE, returning a book with extracted resources.
FINGERPRINT, when supplied, is the already computed SHA-256 of FILE."
  (unless (libxml-available-p)
    (error "Reading EPUB requires Emacs with libxml support"))
  (let ((root (make-temp-file "nnepub-" t))
        (nnepub--path-cache (make-hash-table :test #'equal))
        (started (float-time)) extracted
        success)
    (unwind-protect
        (progn
          (message "nnepub: Extracting %s..." (file-name-nondirectory file))
          (nnepub--extract file root)
          (setq extracted (float-time))
          (message "nnepub: Extracted (%.2fs); indexing chapters..." (- extracted started))
          (let* ((container (nnepub--read-xml
                             (expand-file-name "META-INF/container.xml" root)))
                 (rootfile (cl-find-if
                            (lambda (node)
                              (equal (nnepub--attr node 'media-type)
                                     "application/oebps-package+xml"))
                            (nnepub--elements container 'rootfile)))
                 (package-path (or (nnepub--attr rootfile 'full-path)
                                   (error "EPUB has no package document")))
                 (package-file (car (nnepub--resolve
                                     root (expand-file-name "container.xml" root)
                                     package-path)))
                 (package (nnepub--read-xml package-file))
                 (metadata (nnepub--child package 'metadata))
                 (spine (nnepub--child package 'spine))
                 (fingerprint (or fingerprint (nnepub--fingerprint file)))
                 (key (secure-hash 'sha256 file))
                 (group (concat "book." key "." fingerprint))
                 (by-id (make-hash-table :test #'equal))
                 (seen (make-hash-table :test #'equal))
                 resources chapters reading-order)
            (dolist (item (nnepub--elements (nnepub--child package 'manifest) 'item))
              (let ((href (nnepub--attr item 'href)))
                (when (and href (not (nnepub--external-url-p href)))
                  (push (list :id (nnepub--attr item 'id)
                              :path (car (nnepub--resolve root package-file href))
                              :type (nnepub--attr item 'media-type)
                              :properties (nnepub--attr item 'properties))
                        resources))))
            (setq resources (nreverse resources))
            (dolist (resource resources)
              (let ((id (plist-get resource :id)))
                (unless (gethash id by-id) (puthash id resource by-id))))
            (dolist (item (nnepub--elements spine 'itemref))
              (let* ((id (nnepub--attr item 'idref))
                     (resource (gethash id by-id)))
                (unless resource (error "Missing EPUB spine resource: %s" id))
                (push (plist-get resource :path) reading-order)
                (unless (or (member (plist-get resource :type)
                                    '("application/xhtml+xml" "text/html"))
                            (string-prefix-p "image/" (or (plist-get resource :type) "")))
                  (error "Unsupported EPUB spine resource: %s" id))
                (unless (gethash resource seen)
                  (puthash resource t seen)
                  (push resource chapters))))
            (unless chapters (error "EPUB has an empty spine"))
            (setq reading-order (nreverse reading-order))
            ;; Footnotes and navigation documents can be outside the spine.
            (dolist (resource resources)
              (when (and (member (plist-get resource :type)
                                 '("application/xhtml+xml" "text/html"))
                         (not (gethash resource seen)))
                (puthash resource t seen)
                (push resource chapters)))
            (setq chapters (nreverse chapters))
            (let ((titles (nnepub--navigation root package resources))
                  (number 0))
              (setq chapters
                    (mapcar
                     (lambda (resource)
                       (let* ((path (plist-get resource :path))
                              (title (gethash path titles)))
                         (unless (file-readable-p path)
                           (error "Missing EPUB resource: %s" path))
                         (unless title
                           (setq title
                                 (if (string-prefix-p "image/" (plist-get resource :type))
                                     (file-name-base path)
                                   (nnepub--text
                                    (nnepub--first-element (nnepub--read-xml path) 'title)))))
                         (append (list :number (cl-incf number)
                                       :title (if (string-empty-p title)
                                                  (format "Chapter %d" number) title))
                                 resource)))
                     chapters)))
            (prog1
                (nnepub--make-book
                 :file file :signature signature :root root :key key :group group
                 :title (let ((title (nnepub--text (nnepub--child metadata 'title))))
                          (if (string-empty-p title) (file-name-base file) title))
                 :author (let ((authors (mapcar #'nnepub--text
                                               (nnepub--elements metadata 'creator))))
                           (if authors (string-join authors ", ") "Unknown"))
                 :date (format-time-string "%a, %d %b %Y %T %z" (car signature) t)
                 :chapters chapters :resources resources :spine reading-order)
              (setq success t)
              (message "nnepub: Ready (%d chapters; indexing %.2fs)"
                       (length chapters) (- (float-time) extracted)))))
      (unless success (delete-directory root t)))))

(defun nnepub--dispose-book (book)
  "Remove BOOK's extracted temporary resources."
  (when-let* ((root (nnepub--book-root book))
              ((file-directory-p root)))
    (delete-directory root t)))

(defun nnepub--change-server (server)
  "Switch to the already opened SERVER, or keep the current server."
  (when (and server (not (nnoo-current-server-p 'nnepub server)))
    (unless (assoc server (cddr (assq 'nnepub nnoo-state-alist)))
      (error "EPUB server is not open: %s" server))
    (nnoo-change-server 'nnepub server nil))
  (unless nnepub-directory (error "No EPUB server is open")))

(defun nnepub--scan ()
  "Update the current directory's book catalog, reusing unchanged books."
  (let ((files (directory-files nnepub-directory t "\\.[eE][pP][uU][bB]\\'"))
        books created success)
    (unwind-protect
        (progn
          (dolist (file files)
            (when (file-regular-p file)
              (setq file (file-truename file))
              (condition-case err
                  (let* ((signature (nnepub--file-signature file))
                         (old (cl-find file nnepub--books :key #'nnepub--book-file :test #'equal))
                         (book (if (and old (equal signature (nnepub--book-signature old))) old
                                 (let ((new (nnepub--load-book file signature)))
                                   (push new created)
                                   new))))
                    (unless (memq book books) (push book books)))
                (error
                 (nnheader-report 'nnepub "Skipping %s: %s" file (error-message-string err))
                 (nnheader-message 3 "nnepub: Skipping %s: %s" file (error-message-string err))))))
          (dolist (old nnepub--books)
            (unless (memq old books) (nnepub--dispose-book old)))
          (setq nnepub--books (nreverse books)
                success t))
      (unless success (mapc #'nnepub--dispose-book created)))))

(defun nnepub--get-book (group &optional server)
  "Return GROUP's book on SERVER, refreshing the directory if necessary."
  (nnepub--change-server server)
  (when (or (null nnepub--books)
            (cl-some (lambda (book)
                       (or (not (file-readable-p (nnepub--book-file book)))
                           (not (equal (nnepub--book-signature book)
                                       (nnepub--file-signature (nnepub--book-file book))))))
                     nnepub--books))
    (nnepub--scan))
  (or (cl-find (or group nnepub--group) nnepub--books
               :key #'nnepub--book-group :test #'equal)
      (error "EPUB group is unavailable; rescan or reopen the updated book: %s" group)))

(defun nnepub--message-id (book number)
  "Return BOOK's stable Message-ID for article NUMBER."
  (format "<%d.%s@nnepub>" number (nnepub--book-group book)))

(defun nnepub--chapter (book article)
  "Find ARTICLE, a number or Message-ID, in BOOK."
  (or (cl-find-if
       (lambda (chapter)
         (let ((number (plist-get chapter :number)))
           (if (integerp article) (= article number)
             (equal article (nnepub--message-id book number)))))
       (nnepub--book-chapters book))
      (error "No such EPUB article: %s" article)))

(defun nnepub--header (book chapter)
  "Return the Gnus mail header for BOOK's CHAPTER."
  (make-full-mail-header
   (plist-get chapter :number) (plist-get chapter :title)
   (concat (nnepub--book-author book) " <reader@nnepub.invalid>")
   (nnepub--book-date book)
   (nnepub--message-id book (plist-get chapter :number)) "" 0 0))

(defun nnepub--link (book chapter group fragment &optional by-number)
  "Return the internal URL for BOOK's CHAPTER in GROUP at FRAGMENT.
Use the article number instead of its Message-ID when BY-NUMBER is non-nil."
  (concat "nnepub:" (url-hexify-string group) "/"
          (url-hexify-string
           (if by-number (number-to-string (plist-get chapter :number))
             (nnepub--message-id book (plist-get chapter :number))))
          (when fragment (concat "#" (url-hexify-string fragment)))))

(defun nnepub--html (book chapter group &optional by-number)
  "Return (HTML . IMAGES) for BOOK's CHAPTER in GROUP.
IMAGES is an alist of content IDs and manifest resource records.
Use numbered chapter links when BY-NUMBER is non-nil."
  (let* ((root (nnepub--book-root book))
         (file (plist-get chapter :path))
         (document (if (string-prefix-p "image/" (plist-get chapter :type))
                       `(html nil (body nil (img ((src . ,(file-name-nondirectory file))
                                                 (alt . ,(plist-get chapter :title))))))
                     (nnepub--read-xml file t)))
         images)
    ;; EPUB covers often wrap a single bitmap in SVG.  Render these like
    ;; ordinary images, allowing Gnus to resolve their MIME content IDs.
    (dolist (svg (nnepub--elements document 'svg))
      (let ((children (cl-remove-if-not #'consp (dom-children svg))))
        (when (and children
                   (cl-every (lambda (child)
                               (memq (nnepub--local-name (dom-tag child)) '(image title desc)))
                             children))
          (let ((bitmaps
                 (mapcar (lambda (image)
                           `(img ((src . ,(or (nnepub--attr image 'href) ""))
                                  (alt . ,(plist-get chapter :title)))))
                         (nnepub--elements svg 'image))))
            (when bitmaps (setcar svg 'span) (setcdr svg (cons nil bitmaps)))))))
    (dolist (anchor (nnepub--elements document 'a))
      (when-let* ((href (nnepub--attr anchor 'href))
                  ((not (nnepub--external-url-p href))))
        (let* ((target (nnepub--resolve root file href))
               (destination (cl-find (car target) (nnepub--book-chapters book)
                                     :key (lambda (item) (plist-get item :path)) :test #'equal)))
          (when destination
            (dom-set-attribute anchor 'href
                               (nnepub--link book destination group (cdr target) by-number))))))
    (dolist (image (nnepub--elements document 'img))
      (when-let* ((src (nnepub--attr image 'src))
                  ((not (nnepub--external-url-p src))))
        (let* ((path (car (nnepub--resolve root file src)))
               (resource (cl-find path (nnepub--book-resources book)
                                  :key (lambda (item) (plist-get item :path)) :test #'equal))
               (id (concat (secure-hash 'sha256 (file-relative-name path root)) "@nnepub")))
          (if (and resource (file-readable-p path)
                   (string-prefix-p "image/" (or (plist-get resource :type) "")))
              (progn
                (dom-set-attribute image 'src (concat "cid:" id))
                (unless (assoc id images) (push (cons id resource) images)))
            (dom-set-attribute image 'src "")))))
    (cons (with-temp-buffer (xml-print (list document)) (buffer-string))
          (nreverse images))))

(defun nnepub--article-head (book chapter)
  "Return the message headers for BOOK's CHAPTER."
  (concat "Subject: " (rfc2047-encode-string (plist-get chapter :title)) "\n"
          "From: " (rfc2047-encode-string (nnepub--book-author book)) " <reader@nnepub.invalid>\n"
          "Date: " (nnepub--book-date book) "\n"
          "Message-ID: " (nnepub--message-id book (plist-get chapter :number)) "\n"
          "MIME-Version: 1.0\n"))

(defun nnepub--mime (book chapter group &optional by-number)
  "Build the MIME article for BOOK's CHAPTER in GROUP.
Use numbered chapter links when BY-NUMBER is non-nil."
  (pcase-let* ((`(,html . ,images) (nnepub--html book chapter group by-number))
              (number (plist-get chapter :number))
              (boundary (concat "nnepub-" (nnepub--book-key book) "-" (number-to-string number))))
    (with-temp-buffer
      (insert (nnepub--article-head book chapter))
      (when images
        (insert "Content-Type: multipart/related; boundary=\"" boundary "\"\n\n"
                "--" boundary "\n"))
      (insert "Content-Type: text/html; charset=utf-8\n"
              "Content-Transfer-Encoding: base64\n\n"
              (base64-encode-string (encode-coding-string html 'utf-8)) "\n")
      (dolist (image images)
        (insert "--" boundary "\nContent-Type: " (plist-get (cdr image) :type) "\n"
                "Content-ID: <" (car image) ">\n"
                "Content-Disposition: inline\nContent-Transfer-Encoding: base64\n\n"
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally (plist-get (cdr image) :path))
                  (base64-encode-string (buffer-string))) "\n"))
      (when images (insert "--" boundary "--\n"))
      (buffer-string))))

;;; Gnus interface

(deffoo nnepub-open-server (server &optional definitions)
  (nnepub--report-errors
    (let ((directory (or (cadr (assq 'nnepub-directory definitions)) server)))
      (when (file-remote-p directory) (error "EPUB directories must be local"))
      (unless (file-directory-p directory) (error "Not an EPUB directory: %s" directory))
      (nnoo-change-server 'nnepub server definitions)
      (setq nnepub-directory (file-name-as-directory (file-truename directory)))
      (nnepub--scan)
      t)))

(deffoo nnepub-close-server (&optional server _definitions)
  (let ((server (or server (nnoo-current-server 'nnepub))))
    (if (or (null server)
            (and (not (nnoo-current-server-p 'nnepub server))
                 (not (assoc server (cddr (assq 'nnepub nnoo-state-alist))))))
        t
      (nnepub--report-errors
        (nnepub--change-server server)
        (mapc #'nnepub--dispose-book nnepub--books)
        (setq nnepub--books nil nnepub--group nil)
        (nnoo-close-server 'nnepub server)))))

(deffoo nnepub-request-close ()
  (let ((servers (delete-dups
                  (cons (nnoo-current-server 'nnepub)
                        (mapcar #'car (cddr (assq 'nnepub nnoo-state-alist)))))))
    (dolist (server (delete "*internal-non-initialized-backend*" (delq nil servers)))
      (nnepub-close-server server))
    (nnoo-close 'nnepub)))

(deffoo nnepub-request-list (&optional server)
  (nnepub--report-errors
    (nnepub--change-server server)
    (nnepub--scan)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (book nnepub--books)
        (insert (format "%s %d 1 n\n" (nnepub--book-group book)
                        (length (nnepub--book-chapters book))))))
    t))

(deffoo nnepub-request-group (group &optional server fast _info)
  (nnepub--report-errors
    (let ((book (nnepub--get-book group server)))
      (setq nnepub--group group)
      (unless fast
        (with-current-buffer nntp-server-buffer
          (erase-buffer)
          (let ((count (length (nnepub--book-chapters book))))
            (insert (format "211 %d 1 %d %s\n" count count group)))))
      t)))

(deffoo nnepub-close-group (_group &optional server)
  (nnepub--report-errors (nnepub--change-server server) (setq nnepub--group nil) t))

(deffoo nnepub-retrieve-headers (articles &optional group server _fetch-old)
  (nnepub--report-errors
    (let ((book (nnepub--get-book group server)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer)
        (dolist (article (if (and (consp articles) (stringp (car articles))) articles
                          (range-uncompress articles)))
          (condition-case nil
              (nnheader-insert-nov (nnepub--header book (nnepub--chapter book article)))
            (error nil))))
      'nov)))

(deffoo nnepub-request-article (article &optional group server to-buffer)
  (nnepub--report-errors
    (let* ((book (nnepub--get-book group server))
           (chapter (nnepub--chapter book article))
           (name (gnus-group-prefixed-name (nnepub--book-group book)
                                          (list 'nnepub (nnoo-current-server 'nnepub))))
           (mime (nnepub--mime book chapter name)))
      (with-current-buffer (or to-buffer nntp-server-buffer)
        (erase-buffer)
        (insert mime))
      (cons (nnepub--book-group book) (plist-get chapter :number)))))

(deffoo nnepub-request-scan (&optional _group server)
  (nnepub--report-errors (nnepub--change-server server) (nnepub--scan) t))

(deffoo nnepub-request-list-newsgroups (&optional server)
  (nnepub--report-errors
    (nnepub--change-server server)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (book nnepub--books)
        (insert (nnepub--book-group book) "\t" (nnepub--book-title book) "\n")))
    t))

(deffoo nnepub-request-group-description (group &optional server)
  (nnepub--report-errors
    (let ((book (nnepub--get-book group server)))
      (with-current-buffer nntp-server-buffer
        (erase-buffer)
        (insert group "\t" (nnepub--book-title book) "\n"))
      t)))

(deffoo nnepub-request-post (&optional _server)
  (nnheader-report 'nnepub "EPUB books are read-only"))

;;; Reading commands and scoped HTML rendering

(defvar nnepub--link-map
  (let ((map (copy-keymap shr-map)))
    (keymap-set map "RET" #'nnepub-follow-link)
    (keymap-set map "<mouse-2>" #'nnepub-follow-link)
    map))

(defun nnepub--render-html (handle)
  "Render MIME HANDLE using shr and EPUB link bindings."
  (let ((shr-map nnepub--link-map)) (mm-shr handle)))

(defun nnepub--goto-fragment (fragment)
  "Move point to the shr anchor named FRAGMENT in the current buffer."
  (when (and fragment (not (string-empty-p fragment)))
    (let ((position (point-min)) found)
      (while (and position (not found))
        (let ((ids (get-text-property position 'shr-target-id)))
          (when (or (equal ids fragment) (and (listp ids) (member fragment ids)))
            (setq found position)))
        (setq position (next-single-property-change position 'shr-target-id)))
      (unless found (user-error "EPUB anchor not found: %s" fragment))
      (goto-char found)
      (when-let* ((window (get-buffer-window (current-buffer))))
        (set-window-point window found)))))

(defun nnepub-follow-link (&optional event)
  "Follow an EPUB link at point or mouse EVENT, including chapter anchors."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((url (get-text-property (point) 'shr-url)))
    (if (and url (string-prefix-p "nnepub:" url))
        (progn
          (unless (string-match "\\`nnepub:\\([^/]+\\)/\\([^#]+\\)\\(?:#\\(.*\\)\\)?\\'" url)
            (user-error "Invalid EPUB link"))
          (let ((encoded-group (match-string 1 url))
                (group (nnepub--decode-url (match-string 1 url)))
                (id (nnepub--decode-url (match-string 2 url)))
                (fragment (when-let* ((value (match-string 3 url)))
                            (nnepub--decode-url value))))
            (require 'gnus-sum)
            (if (string-match-p "\\`[0-9]+\\'" id)
                (with-current-buffer gnus-summary-buffer
                  (unless (equal encoded-group (url-hexify-string gnus-newsgroup-name))
                    (user-error "EPUB chapter belongs to another group"))
                  (unless (gnus-summary-goto-article (string-to-number id) nil t)
                    (user-error "EPUB chapter not found: %s" id)))
              (gnus-select-group-with-message-id group id))
            (with-current-buffer gnus-article-buffer (nnepub--goto-fragment fragment))))
      (shr-browse-url event))))

(unless (assoc "nnepub" gnus-valid-select-methods)
  (gnus-declare-backend "nnepub" 'none 'address))

;; These parameters apply only to groups from this backend.  A function is
;; accepted as a MIME HTML renderer, so no global renderer registration is needed.
(with-eval-after-load 'gnus-sum
  (add-to-list 'gnus-parameters
               '("\\`nnepub[+:]"
                 (mm-text-html-renderer 'nnepub--render-html)
                 (gnus-show-threads nil)
                 (gnus-article-sort-functions '(gnus-article-sort-by-number))
                 (gnus-thread-sort-functions '(gnus-thread-sort-by-number)))))

(provide 'nnepub)
;;; nnepub.el ends here
