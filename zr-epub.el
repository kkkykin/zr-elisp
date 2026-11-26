;;; zr-epub.el --- Extract and parse EPUB books -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Open an EPUB with `zr-epub-open', read its numbered resources with
;; `zr-epub-book-chapters', and release extracted files with `zr-epub-close'.
;; `zr-epub-chapter-html' lets callers supply their own link and image URLs.
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

(defgroup zr-epub nil
  "EPUB books."
  :group 'applications)

(defcustom zr-epub-7z-program nil
  "7-Zip executable, or nil to find 7zz followed by 7z."
  :type '(choice (const :tag "Find automatically" nil) string)
  :group 'zr-epub)

(cl-defstruct (zr-epub-book (:constructor zr-epub--make-book))
  file root title author modified chapters resources spine)

(defvar zr-epub--path-cache nil
  "Path containment checks cached only while indexing one extracted book.")

(defun zr-epub--local-name (name)
  "Return NAME without an XML namespace prefix."
  (if-let* ((colon (cl-position ?: (symbol-name name) :from-end t)))
      (intern (substring (symbol-name name) (1+ colon)))
    name))

(defun zr-epub--elements (node tag)
  "Return NODE and descendants whose local name is TAG, in document order."
  (let (nodes)
    (cl-labels ((visit (node)
                  (when (consp node)
                    (when (eq (zr-epub--local-name (dom-tag node)) tag) (push node nodes))
                    (dolist (child (dom-children node)) (visit child)))))
      (visit node))
    (nreverse nodes)))

(defun zr-epub--first-element (node tag)
  "Return the first element with local name TAG, stopping when found."
  (when (consp node)
    (if (eq (zr-epub--local-name (dom-tag node)) tag) node
      (cl-some (lambda (child) (zr-epub--first-element child tag)) (dom-children node)))))

(defun zr-epub--child (node tag)
  "Return the first direct child of NODE with local name TAG."
  (cl-find-if (lambda (child)
                (and (consp child)
                     (eq (zr-epub--local-name (dom-tag child)) tag)))
              (dom-children node)))

(defun zr-epub--attr (node name)
  "Return the attribute of NODE with local name NAME."
  (cdr (or (assq name (dom-attributes node))
           (cl-find-if (lambda (attr)
                         (eq (zr-epub--local-name (car attr)) name))
                       (dom-attributes node)))))

(defun zr-epub-single-line (text)
  "Return trimmed TEXT with control characters replaced by spaces."
  (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " (or text ""))))

(defun zr-epub--text (node)
  "Return the text of NODE as a single line."
  (zr-epub-single-line (and node (dom-inner-text node))))

(defun zr-epub-decode-url (text)
  "Decode the UTF-8 URL component TEXT."
  (save-match-data
    (decode-coding-string (url-unhex-string text) 'utf-8)))

(defun zr-epub--external-url-p (url)
  "Return non-nil if URL denotes an external resource."
  (string-match-p "\\`\\(?:[[:alpha:]][[:alnum:]+.-]*:\\|//\\)" url))

(defun zr-epub-resolve (root base href)
  "Resolve HREF relative to BASE inside ROOT, returning (PATH . FRAGMENT).
External URLs and paths escaping the EPUB are rejected."
  (when (zr-epub--external-url-p href)
    (error "External EPUB resource: %s" href))
  (string-match "\\`\\([^?#]*\\)\\(?:\\?[^#]*\\)?\\(?:#\\(.*\\)\\)?\\'" href)
  (let* ((part (zr-epub-decode-url (match-string 1 href)))
         (fragment (when-let* ((value (match-string 2 href)))
                     (zr-epub-decode-url value)))
         (path (if (string-empty-p part) base
                 (expand-file-name part (file-name-directory base)))))
    (unless
        (if (not zr-epub--path-cache) (file-in-directory-p path root)
          ;; Extraction is complete and this tree stays unchanged during
          ;; indexing.  Cache canonical root/validated paths for this scope;
          ;; rendering later still performs fresh filesystem checks.
          (let* ((directory (file-name-as-directory root))
                 (key (cons directory path)))
            (or (gethash key zr-epub--path-cache)
                (let ((true-root (or (gethash directory zr-epub--path-cache)
                                     (puthash directory (file-name-as-directory (file-truename directory))
                                              zr-epub--path-cache)))
                      (true-path (file-truename path)))
                  (when (or (equal true-path (directory-file-name true-root))
                            (string-prefix-p true-root true-path))
                    (puthash key t zr-epub--path-cache))))))
      (error "EPUB resource outside book: %s" href))
    (cons path fragment)))

(defun zr-epub--read-xml (file &optional html)
  "Parse FILE as XML, or HTML when HTML is non-nil."
  (with-temp-buffer
    (insert-file-contents file)
    (or (if html
            (libxml-parse-html-region (point-min) (point-max))
          (libxml-parse-xml-region (point-min) (point-max)))
        (error "Could not parse EPUB resource: %s" file))))

(defun zr-epub-file-digest (file)
  "Return the SHA-256 digest of the bytes in FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun zr-epub--extract (file root)
  "Extract FILE into ROOT with 7-Zip."
  (let ((program (or zr-epub-7z-program
                     (executable-find "7zz") (executable-find "7z")
                     (error "Install 7zz or 7z, or set zr-epub-7z-program"))))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (unless (eq 0 (call-process program nil t nil
                                    "x" "-y" "-bd" "-bb0" "-sccUTF-8"
                                    (concat "-o" root) "--" file))
          (error "7-Zip could not extract %s: %s"
                 file (string-trim (buffer-string))))))))

(defun zr-epub--navigation (root package resources)
  "Read navigation titles from PACKAGE and RESOURCES inside ROOT.
Return a hash table of resource paths and their first navigation title."
  (let* ((spine (zr-epub--child package 'spine))
         (nav (cl-find-if (lambda (item)
                            (member "nav" (split-string (or (plist-get item :properties) ""))))
                          resources))
         (ncx (cl-find (zr-epub--attr spine 'toc) resources
                       :key (lambda (item) (plist-get item :id)) :test #'equal))
         (resource (or nav ncx))
         (titles (make-hash-table :test #'equal)))
    (when resource
      (let* ((file (plist-get resource :path))
             (document (zr-epub--read-xml file))
             (navigation (if nav
                             (cl-find-if
                              (lambda (node)
                                (member "toc" (split-string (or (zr-epub--attr node 'type) ""))))
                              (zr-epub--elements document 'nav))
                           (zr-epub--first-element document 'navMap)))
             (nodes (zr-epub--elements navigation (if nav 'a 'navPoint))))
        (dolist (node nodes)
          (let* ((href (if nav (zr-epub--attr node 'href)
                         (zr-epub--attr (zr-epub--child node 'content) 'src)))
                 (title (if nav (zr-epub--text node)
                          (zr-epub--text (zr-epub--child node 'navLabel)))))
            (when (and href (not (zr-epub--external-url-p href)))
              (let ((path (car (zr-epub-resolve root file href))))
                (unless (or (gethash path titles) (string-empty-p title))
                  (puthash path title titles))))))))
    titles))

(defun zr-epub-open (file)
  "Read local FILE and return a book with extracted resources.
Call `zr-epub-close' when the book is no longer needed."
  (unless (libxml-available-p)
    (error "Reading EPUB requires Emacs with libxml support"))
  (unless (and (not (file-remote-p file)) (file-regular-p file) (file-readable-p file))
    (error "Unreadable local EPUB file: %s" file))
  (let* ((file (file-truename file))
         (modified (file-attribute-modification-time (file-attributes file)))
         (root (make-temp-file "zr-epub-" t))
         (zr-epub--path-cache (make-hash-table :test #'equal))
         (started (float-time)) extracted success)
    (unwind-protect
        (progn
          (message "zr-epub: Extracting %s..." (file-name-nondirectory file))
          (zr-epub--extract file root)
          (setq extracted (float-time))
          (message "zr-epub: Extracted (%.2fs); indexing chapters..." (- extracted started))
          (let* ((container (zr-epub--read-xml
                             (expand-file-name "META-INF/container.xml" root)))
                 (rootfile (cl-find-if
                            (lambda (node)
                              (equal (zr-epub--attr node 'media-type)
                                     "application/oebps-package+xml"))
                            (zr-epub--elements container 'rootfile)))
                 (package-path (or (zr-epub--attr rootfile 'full-path)
                                   (error "EPUB has no package document")))
                 (package-file (car (zr-epub-resolve
                                     root (expand-file-name "container.xml" root)
                                     package-path)))
                 (package (zr-epub--read-xml package-file))
                 (metadata (zr-epub--child package 'metadata))
                 (spine (zr-epub--child package 'spine))
                 (by-id (make-hash-table :test #'equal))
                 (seen (make-hash-table :test #'equal))
                 resources chapters reading-order)
            (dolist (item (zr-epub--elements (zr-epub--child package 'manifest) 'item))
              (let ((href (zr-epub--attr item 'href)))
                (when (and href (not (zr-epub--external-url-p href)))
                  (push (list :id (zr-epub--attr item 'id)
                              :path (car (zr-epub-resolve root package-file href))
                              :type (zr-epub--attr item 'media-type)
                              :properties (zr-epub--attr item 'properties))
                        resources))))
            (setq resources (nreverse resources))
            (dolist (resource resources)
              (let ((id (plist-get resource :id)))
                (unless (gethash id by-id) (puthash id resource by-id))))
            (dolist (item (zr-epub--elements spine 'itemref))
              (let* ((id (zr-epub--attr item 'idref))
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
            (let ((titles (zr-epub--navigation root package resources))
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
                                   (zr-epub--text
                                    (zr-epub--first-element (zr-epub--read-xml path) 'title)))))
                         (append (list :number (cl-incf number)
                                       :title (if (string-empty-p title)
                                                  (format "Chapter %d" number) title))
                                 resource)))
                     chapters)))
            (prog1
                (zr-epub--make-book
                 :file file :root root :modified modified
                 :title (let ((title (zr-epub--text (zr-epub--child metadata 'title))))
                          (if (string-empty-p title) (file-name-base file) title))
                 :author (let ((authors (mapcar #'zr-epub--text
                                               (zr-epub--elements metadata 'creator))))
                           (if authors (string-join authors ", ") "Unknown"))
                 :chapters chapters :resources resources :spine reading-order)
              (setq success t)
              (message "zr-epub: Ready (%d chapters; indexing %.2fs)"
                       (length chapters) (- (float-time) extracted)))))
      (unless success (delete-directory root t)))))

(defun zr-epub-close (book)
  "Remove BOOK's extracted temporary resources."
  (when-let* ((root (zr-epub-book-root book))
              ((file-directory-p root)))
    (delete-directory root t)))

(defun zr-epub-chapter (book number)
  "Return BOOK's chapter with NUMBER, starting at 1."
  (or (and (integerp number) (> number 0) (nth (1- number) (zr-epub-book-chapters book)))
      (error "No such EPUB chapter: %s" number)))

(defun zr-epub-chapter-html (book chapter &optional link-function image-function)
  "Return HTML for BOOK's CHAPTER.
LINK-FUNCTION receives a destination chapter and fragment and returns a URL.
IMAGE-FUNCTION receives a readable image resource plist and returns its URL.
Without a callback, leave the corresponding URLs unchanged."
  (let* ((root (zr-epub-book-root book))
         (file (plist-get chapter :path))
         (document (if (string-prefix-p "image/" (plist-get chapter :type))
                       `(html nil (body nil (img ((src . ,(file-name-nondirectory file))
                                                 (alt . ,(plist-get chapter :title))))))
                     (zr-epub--read-xml file t))))
    ;; EPUB covers often wrap a single bitmap in SVG.
    (dolist (svg (zr-epub--elements document 'svg))
      (let ((children (cl-remove-if-not #'consp (dom-children svg))))
        (when (and children
                   (cl-every (lambda (child)
                               (memq (zr-epub--local-name (dom-tag child)) '(image title desc)))
                             children))
          (let ((bitmaps
                 (mapcar (lambda (image)
                           `(img ((src . ,(or (zr-epub--attr image 'href) ""))
                                  (alt . ,(plist-get chapter :title)))))
                         (zr-epub--elements svg 'image))))
            (when bitmaps (setcar svg 'span) (setcdr svg (cons nil bitmaps)))))))
    (when link-function
      (dolist (anchor (zr-epub--elements document 'a))
        (when-let* ((href (zr-epub--attr anchor 'href))
                    ((not (zr-epub--external-url-p href)))
                    (target (zr-epub-resolve root file href))
                    (destination (cl-find (car target) (zr-epub-book-chapters book)
                                          :key (lambda (item) (plist-get item :path)) :test #'equal)))
          (dom-set-attribute anchor 'href (funcall link-function destination (cdr target))))))
    (when image-function
      (dolist (image (zr-epub--elements document 'img))
        (when-let* ((src (zr-epub--attr image 'src))
                    ((not (zr-epub--external-url-p src))))
          (let* ((path (car (zr-epub-resolve root file src)))
                 (resource (cl-find path (zr-epub-book-resources book)
                                    :key (lambda (item) (plist-get item :path)) :test #'equal)))
            (dom-set-attribute image 'src
                               (if (and resource (file-readable-p path)
                                        (string-prefix-p "image/" (or (plist-get resource :type) "")))
                                   (funcall image-function resource)
                                 ""))))))
    (with-temp-buffer (xml-print (list document)) (buffer-string))))

(provide 'zr-epub)
;;; zr-epub.el ends here
