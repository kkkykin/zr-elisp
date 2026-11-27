;;; nnopds-search.el --- Search cached EPUB chapters with Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loading this module registers a gnus-search engine for nnopds servers.
;; Search selected books or all known books on a server, using only locally
;; cached EPUBs.  Results refer to the original chapter article numbers.
;; Unopened caches are extracted temporarily, without changing reading state.
;; Raw queries match literal text, ignoring case.  Gnus's parsed queries also
;; support Boolean expressions, quoted phrases, /regexps/ and body, text,
;; subject, from, sender and id fields.

;;; Code:

(require 'nnopds)
(require 'gnus-search)
(require 'shr)

(defvar gnus-inhibit-demon)

(defclass gnus-search-nnopds (gnus-search-engine) nil
  :documentation "Search the text of locally cached nnopds EPUB chapters.")

(defun nnopds-search--normalize-text (text)
  "Collapse whitespace in TEXT for chapter and phrase matching."
  (string-trim (replace-regexp-in-string "[[:space:]\u00a0]+" " " text)))

(defun nnopds-search--chapter-text (chapter)
  "Return CHAPTER's rendered text, without fetching images."
  (let ((document (zr-epub--read-xml (plist-get chapter :path) t))
        (shr-inhibit-images t)
        (shr-use-fonts nil)
        (shr-use-colors nil)
        (shr-fill-text nil)
        (shr-external-rendering-functions nil))
    (with-temp-buffer
      (shr-insert-document (or (zr-epub--first-element document 'body) document))
      (nnopds-search--normalize-text (buffer-substring-no-properties (point-min) (point-max))))))

(defun nnopds-search--pattern (term)
  "Convert a parsed TERM into a validated search regexp."
  (let ((pattern
         (cond
          ((and (string-prefix-p "\"" term) (string-suffix-p "\"" term))
           (regexp-quote (nnopds-search--normalize-text (car (read-from-string term)))))
          ((and (string-prefix-p "/" term) (string-suffix-p "/" term) (> (length term) 1))
           (string-replace "\\/" "/" (substring term 1 -1)))
          (t (regexp-quote (nnopds-search--normalize-text term))))))
    (condition-case err
        (string-match-p pattern "")
      (invalid-regexp (user-error "%s" (error-message-string err))))
    pattern))

(defun nnopds-search--term-matcher (field pattern)
  "Return a predicate matching FIELD with PATTERN in a chapter's fields."
  (lambda (fields) (string-match-p pattern (alist-get field fields ""))))

(defun nnopds-search--matcher (expression)
  "Compile a parsed search EXPRESSION into a chapter predicate.
Reject unsupported expressions before opening any books."
  (pcase expression
    ((pred stringp)
     (nnopds-search--term-matcher 'text (nnopds-search--pattern expression)))
    (`(or ,left ,right)
     (let ((left-match (nnopds-search--matcher left))
           (right-match (nnopds-search--matcher right)))
       (lambda (fields) (or (funcall left-match fields) (funcall right-match fields)))))
    (`(not ,term)
     (let ((match (nnopds-search--matcher term)))
       (lambda (fields) (not (funcall match fields)))))
    (`(,(and field (or 'body 'text 'subject 'from 'sender 'id)) . ,(pred stringp))
     (nnopds-search--term-matcher (if (eq field 'sender) 'from field)
                                (nnopds-search--pattern (cdr expression))))
    ('and (lambda (_fields) t))
    ((pred proper-list-p)
     (unless expression (user-error "Enter a search query"))
     (let ((matches (mapcar #'nnopds-search--matcher expression)))
       (lambda (fields) (cl-every (lambda (match) (funcall match fields)) matches))))
    (_ (user-error "Unsupported EPUB search expression: %S" expression))))

(defun nnopds-search--query-matcher (engine query)
  "Return a chapter predicate for ENGINE's prepared QUERY."
  (let ((text (alist-get 'query query)))
    (unless (and (stringp text) (not (string-blank-p text)))
      (user-error "Enter a search query"))
    (when (alist-get 'grep query)
      (user-error "EPUB searches do not support grep; use /regexp/ in a parsed query"))
    (if (and gnus-search-use-parsed-queries
             (not (alist-get 'raw query))
             (not (slot-value engine 'raw-queries-p)))
        (nnopds-search--matcher (or (alist-get 'parsed-query query) (gnus-search-parse-query text)))
      (nnopds-search--term-matcher 'text (regexp-quote (nnopds-search--normalize-text text))))))

(defun nnopds-search--cached-book (connection publication)
  "Open PUBLICATION's cached EPUB on CONNECTION, or return nil.
The caller owns the returned book and must close it.  No download or reading
position initialization is performed.  Preserve the cached edition's digest."
  (let* ((key (secure-hash 'sha256 (nnopds--publication-group publication)))
         (file (nnopds--cache-file connection (concat key ".epub"))))
    (when (file-readable-p file)
      (when-let* ((digest (plist-get (nnopds--read-json
                                     (nnopds--cache-file connection (concat key ".json"))) :digest)))
        (unless (equal digest (zr-epub-file-digest file))
          (error "EPUB content changed within the same OPDS version")))
      (let ((book (zr-epub-open file)))
        (unless (string-empty-p (nnopds--publication-author publication))
          (setf (zr-epub-book-author book) (nnopds--publication-author publication)))
        book))))

(defun nnopds-search--fields (book chapter group)
  "Return searchable fields for BOOK's CHAPTER in GROUP."
  (let* ((header (nnopds--header 'zr-epub book chapter group))
         (body (nnopds-search--chapter-text chapter))
         (subject (mail-header-subject header))
         (from (mail-header-from header))
         (id (mail-header-id header)))
    (list (cons 'body body) (cons 'subject subject) (cons 'from from) (cons 'id id)
          (cons 'text (string-join (list subject from id body) "\n")))))

(cl-defmethod gnus-search-run-search ((engine gnus-search-nnopds) server query groups)
  "Search cached EPUB chapters in GROUPS on SERVER for QUERY.
With nil GROUPS, search known books, respecting Gnus's ignored newsgroups.
Return [FULL-GROUP CHAPTER-NUMBER SCORE] results.  PDF, comic and image-only
resources are skipped.  Searching does not download books or update progress."
  (let* ((match (nnopds-search--query-matcher engine query))
         (limit (alist-get 'limit query))
         (method (gnus-server-to-method server))
         (gnus-inhibit-demon t)
         (case-fold-search t)
         (count 0) results)
    (unless (eq (car method) 'nnopds)
      (signal 'gnus-search-config-error (list "EPUB search requires an nnopds server")))
    (unless (or (null limit) (natnump limit)) (user-error "Search limit must be a nonnegative integer"))
    (unless (gnus-check-server method) (user-error "OPDS server unavailable"))
    (let* ((connection (nnopds--change-server (cadr method)))
           (table (nnopds--connection-publications connection))
           (groups (delete-dups (mapcar (lambda (group)
                                         (string-remove-suffix ".pages" (gnus-group-real-name group)))
                                       (or groups (gnus-search-get-active server))))))
      (unless (eql limit 0)
        (catch 'limit
          (dolist (group groups)
            (when-let* ((publication (gethash group table))
                        ((eq (nnopds--publication-format publication) 'epub)))
              (let* ((loaded (nnopds--publication-data publication))
                     (book (or loaded (nnopds-search--cached-book connection publication))))
                (unwind-protect
                    (when book
                      (dolist (chapter (zr-epub-book-chapters book))
                        (when (and (member (plist-get chapter :type) '("application/xhtml+xml" "text/html"))
                                   (funcall match (nnopds-search--fields book chapter group)))
                          (push (vector (gnus-group-full-name group method) (plist-get chapter :number) 0) results)
                          (cl-incf count)
                          (when (and limit (>= count limit)) (throw 'limit nil)))))
                  (when (and book (not loaded)) (zr-epub-close book)))))))))
    (vconcat (nreverse results))))

(unless (assq 'nnopds gnus-search-default-engines)
  (add-to-list 'gnus-search-default-engines '(nnopds . gnus-search-nnopds)))

(provide 'nnopds-search)
;;; nnopds-search.el ends here
