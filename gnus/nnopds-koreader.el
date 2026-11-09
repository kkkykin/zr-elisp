;;; nnopds-koreader.el --- KOReader progress sync for nnopds -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Implements the KOReader sync API used by Komga and calibre.  The sync
;; URL and account are configured independently of the OPDS catalog.
;; EPUBs use KOReader's partial MD5 and CREngine DocFragment XPointers;
;; Gnus resumes and saves at resource boundaries, not at text offsets.

;;; Code:

(require 'nnopds-progress)

(defconst nnopds-koreader--headers '(("Accept" . "application/vnd.koreader.v1+json")))

(defun nnopds-koreader-configure (connection)
  "Store explicit KOReader settings on CONNECTION without contacting HTTP."
  (let* ((url (concat (string-trim-right (nnopds--url nnopds-koreader-url) "/+") "/"))
         (auth (nnopds--auth url nnopds-koreader-user nnopds-koreader-password))
         (user (car auth))
         (password (cdr auth)))
    (unless (and (stringp user) (not (string-empty-p user)))
      (error "Configure nnopds-koreader-user or an auth-source account for the sync server"))
    (setf (nnopds--connection-progress connection)
          (list :protocol 'koreader :url url
                :headers (append (list (cons "X-Auth-User" user))
                                 (when password
                                   (list (cons "X-Auth-Key" (secure-hash 'md5 (encode-coding-string password 'utf-8))))))))))

(defun nnopds-koreader-authorize (connection)
  "Authenticate CONNECTION's sync account before calibre serves a book."
  (let ((endpoint (nnopds--connection-progress connection)))
    (unless (plist-get endpoint :authenticated)
      (let ((response (nnopds--request connection "GET" (concat (plist-get endpoint :url) "users/auth")
                                       nil nil nnopds-koreader--headers endpoint)))
        (unless (equal (plist-get (nnopds--json response) :authorized) "OK")
          (error "Invalid KOReader authentication response"))
        (setf (plist-get endpoint :authenticated) t
              (nnopds--connection-progress connection) endpoint)))))

(defun nnopds-koreader--digest (file)
  "Return KOReader's partial MD5 of FILE, sampling at most twelve KiB."
  (let ((size (file-attribute-size (file-attributes file))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (cl-loop for i from -1 to 10
               for offset = (if (= i -1) 0 (ash 1024 (* 2 i)))
               while (< offset size)
               do (goto-char (point-max))
               do (insert-file-contents-literally file nil offset (min size (+ offset 1024))))
      (secure-hash 'md5 (current-buffer)))))

(cl-defgeneric nnopds-koreader--encode (format data locator)
  "Translate FORMAT's LOCATOR in DATA to KOReader progress and percentage.")

(cl-defgeneric nnopds-koreader--decode (format data progress percentage)
  "Translate KOReader PROGRESS and PERCENTAGE to FORMAT's locator in DATA.")

(cl-defmethod nnopds-progress-initialize ((_protocol (eql koreader)) endpoint (_format (eql epub)) data)
  (setf (plist-get endpoint :document) (nnopds-koreader--digest (nnepub--book-file data))
        (plist-get endpoint :format) 'epub
        (plist-get endpoint :data) data)
  endpoint)

(cl-defmethod nnopds-progress-local-locator ((_protocol (eql koreader)) endpoint locator)
  (let ((position (nnopds-koreader--encode (plist-get endpoint :format) (plist-get endpoint :data) locator)))
    (setf (plist-get (plist-get locator :locations) :totalProgression) (plist-get position :percentage))
    locator))

(cl-defmethod nnopds-koreader--encode ((_format (eql epub)) data locator)
  (let* ((location (nnopds--locate 'epub data locator))
         (chapter (cl-find (car location) (nnepub--book-chapters data)
                           :key (lambda (chapter) (plist-get chapter :number))))
         (spine (nnepub--book-spine data))
         (index (cl-position (plist-get chapter :path) spine :test #'equal)))
    (unless index (error "KOReader position is outside the EPUB spine"))
    ;; This is also the XPointer Komga returns for an EPUB resource start.
    ;; Percentage is an estimate by spine index; no layout engine is shared.
    (list :progress (format "/body/DocFragment[%d].0" (1+ index))
          :percentage (/ (float index) (length spine)))))

(cl-defmethod nnopds-koreader--decode ((_format (eql epub)) data progress percentage)
  (let* ((case-fold-search t)
         (index (cond
                 ((string-match "DocFragment\\[\\([0-9]+\\)\\]" progress)
                  (1- (string-to-number (match-string 1 progress))))
                 ((string-match "DocFragment[/\\.]" progress) 0)
                 ((string-match "\\`#_doc_fragment_\\([0-9]+\\)_" progress)
                  (string-to-number (match-string 1 progress)))))
         (path (and index (>= index 0) (nth index (nnepub--book-spine data))))
         (chapter (and path (cl-find path (nnepub--book-chapters data)
                                     :key (lambda (chapter) (plist-get chapter :path)) :test #'equal))))
    (unless chapter (error "KOReader XPointer does not match an EPUB resource: %s" progress))
    (let ((locator (nnopds--locator 'epub data chapter)))
      (setf (plist-get (plist-get locator :locations) :totalProgression) percentage)
      locator)))

(cl-defmethod nnopds-progress-read ((_protocol (eql koreader)) connection endpoint callback)
  (nnopds--request
   connection "GET" (concat (plist-get endpoint :url) "syncs/progress/" (plist-get endpoint :document)) nil
   (lambda (response error)
     (let (progression failure)
       (condition-case err
           (if error (setq failure error)
             (unless (eq (plist-get response :status) 200)
               (error "KOReader HTTP %s" (plist-get response :status)))
             ;; Komga can return an empty HTTP 200 for no position; calibre
             ;; and the reference server return an empty JSON object.
             (unless (string-empty-p (string-trim (plist-get response :body)))
               (let* ((value (nnopds--json response))
                      (progress (plist-get value :progress))
                      (percentage (plist-get value :percentage))
                      (stamp (plist-get value :timestamp)))
                 (unless (or (and (null value) (string-prefix-p "{" (string-trim (plist-get response :body))))
                             (and (equal (plist-get value :status) 200)
                                  (equal (plist-get value :message) "No progress found for this book")))
                   (unless (and (equal (plist-get value :document) (plist-get endpoint :document))
                                (stringp progress) (not (string-empty-p progress))
                                (numberp percentage) (<= 0 percentage 1)
                                (stringp (plist-get value :device))
                                (or (null (plist-get value :device_id)) (stringp (plist-get value :device_id)))
                                (or (null stamp) (and (numberp stamp) (>= stamp 0))))
                     (error "Invalid KOReader progress response"))
                   (setq progression
                         (list :locator (nnopds-koreader--decode (plist-get endpoint :format) (plist-get endpoint :data)
                                                                progress percentage)
                               :device (plist-get value :device)
                               :device_id (or (plist-get value :device_id) (plist-get value :device))
                               :timestamp stamp))))))
         (error (setq failure (error-message-string err))))
       (funcall callback progression failure)))
   nnopds-koreader--headers endpoint))

(cl-defmethod nnopds-progress-write ((_protocol (eql koreader)) connection endpoint progression callback)
  (let* ((position (nnopds-koreader--encode (plist-get endpoint :format) (plist-get endpoint :data)
                                          (plist-get progression :locator)))
         (body (append (list :document (plist-get endpoint :document)
                             :device (plist-get progression :device) :device_id (plist-get progression :device_id)) position)))
    (nnopds--request
     connection "PUT" (concat (plist-get endpoint :url) "syncs/progress") (json-serialize body)
     (lambda (response error)
       (let ((status (and response (plist-get response :status))) (failure error))
         (when (not error)
           (condition-case err
               (progn
                 (unless (eq status 200)
                   (error "%s" (if (eq status 409) "Position conflict; use nnopds-resume to refresh"
                                 (format "KOReader HTTP %s" status))))
                 ;; Komga's successful PUT has no body; calibre returns an
                 ;; acknowledgement with document and a server timestamp.
                 (unless (string-empty-p (string-trim (plist-get response :body)))
                   (let ((value (nnopds--json response)))
                     (unless (and (equal (plist-get value :document) (plist-get endpoint :document))
                                  (numberp (plist-get value :timestamp)))
                       (error "Invalid KOReader save response")))))
             (error (setq failure (error-message-string err)))))
         (funcall callback (not failure) failure)))
     nnopds-koreader--headers endpoint)))

(provide 'nnopds-koreader)
;;; nnopds-koreader.el ends here
