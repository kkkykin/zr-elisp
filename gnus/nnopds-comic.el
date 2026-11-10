;;; nnopds-comic.el --- Stream Divina comics in Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; OPDS 2 links to a Divina manifest supply the original reading order.
;; Each image is an article; spreads and reading direction are local view
;; settings.  Article retrieval never fetches images.  Only the active reader
;; schedules image requests, with a bounded queue and persistent file cache.

;;; Code:

(require 'nnopds)
(require 'gnus-art)
(require 'gnus-sum)
(require 'image)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function image-flush "image.c" (spec &optional frame))

(defgroup nnopds-comic nil "Streaming comics in Gnus." :group 'nnopds)

(defcustom nnopds-comic-layout 'single
  "Initial page layout for comics without saved settings."
  :type '(choice (const single) (const double)) :group 'nnopds-comic)

(defcustom nnopds-comic-cover-single t
  "Whether the first image occupies its own spread in double page mode."
  :type 'boolean :group 'nnopds-comic)

(defcustom nnopds-comic-direction 'auto
  "Initial reading direction; auto follows the manifest."
  :type '(choice (const auto) (const ltr) (const rtl)) :group 'nnopds-comic)

(defcustom nnopds-comic-prefetch-pages 4
  "Number of original pages to fetch ahead of the current spread."
  :type 'natnum :group 'nnopds-comic)

(defcustom nnopds-comic-max-requests 2
  "Maximum simultaneous image requests per comic."
  :type 'natnum :group 'nnopds-comic)

(defcustom nnopds-comic-gap 12
  "Space in pixels between two displayed pages."
  :type 'natnum :group 'nnopds-comic)

(cl-defstruct (nnopds-comic--book (:constructor nnopds-comic--make-book))
  connection publication pages directory progression layout cover direction position
  readers active queue errors pumping closed)

(cl-defstruct (nnopds-comic--reader (:constructor nnopds-comic--make-reader))
  book summary article anchor start images committed closed)

(cl-defstruct (nnopds-comic--job (:constructor nnopds-comic--make-job))
  state temporary)

(defvar-local nnopds-comic--reader nil)
(defvar-local nnopds-comic--saved-variables nil)
(defvar nnopds-comic-mode)
(defvar nnopds-comic-mode-map)

(defconst nnopds-comic--image-types
  '(("image/jpeg" . jpeg) ("image/png" . png) ("image/gif" . gif)
    ("image/webp" . webp) ("image/avif" . avif) ("image/jxl" . jpeg-xl)
    ("image/svg+xml" . svg) ("image/tiff" . tiff) ("image/bmp" . bmp)))

(defun nnopds-comic--link (resource base)
  "Choose RESOURCE's supported image representation and resolve it at BASE."
  (let* ((links (cons resource (append (plist-get resource :alternate) nil)))
         (link (or (cl-find-if
                    (lambda (candidate)
                      (when-let* ((type (cdr (assoc (nnopds--media-type candidate)
                                                   nnopds-comic--image-types))))
                        (image-type-available-p type))) links)
                   ;; A terminal can still browse and cache a manifest.
                   (cl-find-if (lambda (candidate)
                                 (member (nnopds--media-type candidate)
                                         '("image/jpeg" "image/png" "image/gif" "image/webp"))) links)
                   resource))
         (type (nnopds--media-type link)))
    (unless (string-prefix-p "image/" type)
      (error "Divina reading order contains a non-image resource"))
    (list :href (nnopds--url (plist-get link :href) base) :type type :measured nil
          :image-type (cdr (assoc type nnopds-comic--image-types))
          :width (plist-get resource :width) :height (plist-get resource :height))))

(cl-defmethod nnopds--load-publication ((_format (eql comic)) connection publication)
  (let* ((directory (nnopds--cache-file connection
                                       (concat (secure-hash 'sha256 (nnopds--publication-group publication)) ".comic/")))
         (manifest-file (expand-file-name "manifest.json" directory))
         (cached (nnopds--read-json manifest-file))
         (response (unless cached
                     (nnopds--request connection "GET" (nnopds--publication-acquisition publication)
                                      nil nil '(("Accept" . "application/divina+json, application/opds-publication+json;q=0.9, application/webpub+json;q=0.8")))))
         (manifest (if cached (plist-get cached :manifest) (nnopds--json response)))
         (base (or (and cached (plist-get cached :url)) (plist-get response :url)
                   (nnopds--publication-acquisition publication)))
         (order (plist-get manifest :readingOrder))
         (settings (nnopds--read-json (expand-file-name "position.json" directory)))
         (sizes (plist-get settings :sizes))
         (pages (vconcat (seq-map-indexed
                          (lambda (resource index)
                            (let* ((page (append (list :number (1+ index) :title (format "Page %d" (1+ index)))
                                                 (nnopds-comic--link resource base)))
                                   (size (and (vectorp sizes) (= (length sizes) (length order)) (aref sizes index))))
                              (when (and (vectorp size) (= (length size) 2)
                                         (numberp (aref size 0)) (> (aref size 0) 0)
                                         (numberp (aref size 1)) (> (aref size 1) 0))
                                (setf (plist-get page :width) (aref size 0) (plist-get page :height) (aref size 1)))
                              page)) order)))
         (layout (plist-get settings :layout))
         (direction (plist-get settings :direction))
         (position (plist-get settings :page)))
    (unless (and (plist-get manifest :metadata) (> (length pages) 0))
      (error "Not a Divina comic manifest with page images"))
    (unless cached (nnopds--write-json manifest-file (list :url base :manifest manifest)))
    (nnopds-comic--make-book
     :connection connection :publication publication :pages pages :directory directory
     :progression (if (equal (plist-get (plist-get manifest :metadata) :readingProgression) "rtl") 'rtl 'ltr)
     :layout (if (member layout '("single" "double")) (intern layout) nnopds-comic-layout)
     :cover (if (plist-member settings :cover) (eq (plist-get settings :cover) t) nnopds-comic-cover-single)
     :direction (if (member direction '("auto" "ltr" "rtl")) (intern direction) nnopds-comic-direction)
     :position (when (and (integerp position) (<= 1 position (length pages))) position)
     :active (make-hash-table) :errors (make-hash-table))))

(cl-defmethod nnopds--chapters ((_format (eql comic)) book) (nnopds-comic--book-pages book))

(cl-defmethod nnopds--header ((_format (eql comic)) book page)
  (let ((publication (nnopds-comic--book-publication book)))
    (make-full-mail-header
     (plist-get page :number) (plist-get page :title)
     (concat (nnopds--publication-author publication) " <reader@nnopds.invalid>")
     (format-time-string "%a, %d %b %Y %T %z"
                         (or (ignore-errors (date-to-time (nnopds--publication-modified publication))) 0) t)
     (format "<%d.%s@nnopds>" (plist-get page :number) (nnopds--publication-group publication)) "" 0 0)))

(cl-defmethod nnopds--article ((_format (eql comic)) book page group)
  (let ((header (nnopds--header 'comic book page)))
    (concat "Subject: " (rfc2047-encode-string (mail-header-subject header)) "\n"
            "From: " (rfc2047-encode-string (mail-header-from header)) "\n"
            "Date: " (mail-header-date header) "\nMessage-ID: " (mail-header-id header) "\n"
            "Newsgroups: " group "\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\n"
            (plist-get page :title) "\n")))

(cl-defmethod nnopds--locator ((_format (eql comic)) book page)
  (list :href (plist-get page :href) :type (plist-get page :type)
        :locations (list :position (plist-get page :number)
                         :totalProgression (/ (float (1- (plist-get page :number)))
                                              (max 1 (1- (length (nnopds-comic--book-pages book))))))))

(cl-defmethod nnopds--locate ((_format (eql comic)) book locator)
  (let ((number (plist-get (plist-get locator :locations) :position)))
    (if (and (integerp number) (<= 1 number (length (nnopds-comic--book-pages book))))
        (cons number nil)
      (when-let* ((page (cl-find (plist-get locator :href) (nnopds-comic--book-pages book)
                                 :key (lambda (entry) (plist-get entry :href)) :test #'equal)))
        (cons (plist-get page :number) nil)))))

(defun nnopds-comic--save (book)
  "Persist BOOK's original page number and local view preferences."
  (nnopds--write-json
   (expand-file-name "position.json" (nnopds-comic--book-directory book))
   (list :page (nnopds-comic--book-position book)
         :layout (symbol-name (nnopds-comic--book-layout book))
         :cover (if (nnopds-comic--book-cover book) t :false)
         :direction (symbol-name (nnopds-comic--book-direction book))
         ;; Remember discovered dimensions so earlier landscape pages keep
         ;; the same pairing when a calibre reader resumes further ahead.
         :sizes (vconcat (seq-map (lambda (page)
                                   (when (and (numberp (plist-get page :width)) (numberp (plist-get page :height)))
                                     (vector (plist-get page :width) (plist-get page :height))))
                                 (nnopds-comic--book-pages book))))))

(defun nnopds-comic--page (book number)
  "Return BOOK's original page NUMBER, numbered from one."
  (aref (nnopds-comic--book-pages book) (1- number)))

(defun nnopds-comic--file (book page)
  "Return the cached image file for BOOK's PAGE representation."
  (expand-file-name (secure-hash 'sha256 (plist-get page :href)) (nnopds-comic--book-directory book)))

(defun nnopds-comic--landscape-p (page)
  "Whether PAGE's known dimensions describe a landscape image."
  (let ((width (plist-get page :width)) (height (plist-get page :height)))
    (and (numberp width) (numberp height) (> width height) (> height 0))))

(defun nnopds-comic--spreads (book)
  "Return BOOK's reading units in original page order."
  (let ((number 1) (count (length (nnopds-comic--book-pages book))) spreads)
    (while (<= number count)
      (if (and (eq (nnopds-comic--book-layout book) 'double)
               (< number count)
               (not (and (= number 1) (nnopds-comic--book-cover book)))
               (not (nnopds-comic--landscape-p (nnopds-comic--page book number)))
               (not (nnopds-comic--landscape-p (nnopds-comic--page book (1+ number)))))
          (progn (push (list number (1+ number)) spreads) (cl-incf number 2))
        (push (list number) spreads) (cl-incf number)))
    (nreverse spreads)))

(defun nnopds-comic--visible (reader)
  "Return the reading unit containing READER's original page anchor."
  (cl-find-if (lambda (spread) (memq (nnopds-comic--reader-anchor reader) spread))
              (nnopds-comic--spreads (nnopds-comic--reader-book reader))))

(defun nnopds-comic--direction (book)
  "Return BOOK's effective horizontal reading direction."
  (if (eq (nnopds-comic--book-direction book) 'auto)
      (nnopds-comic--book-progression book)
    (nnopds-comic--book-direction book)))

(defun nnopds-comic--live-p (reader)
  "Whether READER still owns its summary, article and selected page."
  (and (not (nnopds-comic--reader-closed reader))
       (buffer-live-p (nnopds-comic--reader-summary reader))
       (buffer-live-p (nnopds-comic--reader-article reader))
       (get-buffer-window (nnopds-comic--reader-article reader) t)
       (buffer-local-value 'nnopds-comic-mode (nnopds-comic--reader-article reader))
       (eq reader (buffer-local-value 'nnopds-comic--reader (nnopds-comic--reader-summary reader)))
       (eq reader (buffer-local-value 'nnopds-comic--reader (nnopds-comic--reader-article reader)))
       (eq (nnopds-comic--reader-anchor reader)
           (buffer-local-value 'gnus-current-article (nnopds-comic--reader-summary reader)))
       (marker-position (nnopds-comic--reader-start reader))))

(defun nnopds-comic--notify (book &optional number)
  "Update BOOK's active readers from current state, never a captured old page."
  (dolist (reader (nnopds-comic--book-readers book))
    (when (and (nnopds-comic--live-p reader)
               (or (null number) (memq number (nnopds-comic--visible reader))))
      (nnopds-comic--update reader))))

(defun nnopds-comic--pump (book)
  "Start queued image requests up to BOOK's concurrency limit."
  (unless (or (nnopds-comic--book-closed book) (nnopds-comic--book-pumping book))
    (setf (nnopds-comic--book-pumping book) t)
    (unwind-protect
        (while (and (nnopds-comic--book-queue book)
                    (< (hash-table-count (nnopds-comic--book-active book)) (max 1 nnopds-comic-max-requests)))
          (let* ((number (pop (nnopds-comic--book-queue book)))
                 (page (nnopds-comic--page book number))
                 (file (nnopds-comic--file book page)))
            (unless (or (file-readable-p file) (gethash number (nnopds-comic--book-errors book))
                        (gethash number (nnopds-comic--book-active book)))
              (let* ((temporary (nnopds--temporary-file file))
                     (job (nnopds-comic--make-job :temporary temporary)))
                (puthash number job (nnopds-comic--book-active book))
                (setf (nnopds-comic--job-state job)
                      (nnopds--request
                       (nnopds-comic--book-connection book) "GET" (plist-get page :href) nil
                       (lambda (response failure)
                         (unwind-protect
                             (when (eq job (gethash number (nnopds-comic--book-active book)))
                               (remhash number (nnopds-comic--book-active book))
                               (condition-case err
                                   (progn
                                     (when failure (error "%s" failure))
                                     (unless (= (plist-get response :status) 200)
                                       (error "HTTP %s" (plist-get response :status)))
                                     (let ((type (with-temp-buffer
                                                   (set-buffer-multibyte nil)
                                                   (insert-file-contents-literally temporary nil 0 8192)
                                                   (image-type-from-data (buffer-string)))))
                                       (unless type (error "Response is not an image"))
                                       (setf (plist-get page :image-type) type))
                                     (rename-file temporary file t))
                                 (error (puthash number (error-message-string err) (nnopds-comic--book-errors book))))
                               (nnopds-comic--notify book number)
                               (nnopds-comic--pump book))
                           (when (file-exists-p temporary) (delete-file temporary))))
                       (list (cons "Accept" (concat (plist-get page :type) ", application/octet-stream;q=0.5")))
                       nil temporary))))))
      (setf (nnopds-comic--book-pumping book) nil))))

(defun nnopds-comic--schedule (reader)
  "Prioritize READER's visible pages and a bounded lookahead."
  (let* ((book (nnopds-comic--reader-book reader))
         (visible (nnopds-comic--visible reader))
         (last (car (last visible)))
         (ahead (number-sequence (1+ last)
                                 (min (length (nnopds-comic--book-pages book))
                                      (+ last nnopds-comic-prefetch-pages)))))
    (setf (nnopds-comic--book-queue book) (append visible ahead))
    (nnopds-comic--pump book)))

(defun nnopds-comic--cancel (book)
  "Cancel BOOK's queued and active requests without committing any page."
  (let (jobs)
    (maphash (lambda (_number job) (push job jobs)) (nnopds-comic--book-active book))
    (setf (nnopds-comic--book-queue book) nil)
    (clrhash (nnopds-comic--book-active book))
    (dolist (job jobs)
      (when-let* ((state (nnopds-comic--job-state job))
                  (process (nnopds--request-state-process state))
                  ((process-live-p process)))
        (delete-process process))
      (when (file-exists-p (nnopds-comic--job-temporary job))
        (delete-file (nnopds-comic--job-temporary job))))))

(defun nnopds-comic--flush-images (reader)
  "Release the decoded images held by READER."
  (when (fboundp 'image-flush)
    (dolist (image (nnopds-comic--reader-images reader)) (image-flush image)))
  (setf (nnopds-comic--reader-images reader) nil))

(defun nnopds-comic--dimensions (book page)
  "Read PAGE's native image dimensions once, when its file is available."
  (unless (plist-get page :measured)
    (let* ((image (create-image (nnopds-comic--file book page) (plist-get page :image-type) nil :scale 1))
           (size (and image (image-size image t))))
      (unless (and size (> (car size) 0) (> (cdr size) 0)) (error "Cannot decode page image"))
      (image-flush image)
      (setf (plist-get page :width) (car size) (plist-get page :height) (cdr size)
            (plist-get page :measured) t))))

(defun nnopds-comic--viewport ()
  "Return the available image width and height in pixels."
  (let ((window (get-buffer-window (current-buffer) t)))
    (cons (max 1 (- (window-body-width window t) 2))
          (max 1 (- (window-body-height window t) 2)))))

(defun nnopds-comic--sizes (pages viewport)
  "Fit PAGES into VIEWPORT with equal display heights and preserved aspect ratios."
  (let* ((ratios (mapcar (lambda (page) (/ (float (plist-get page :width)) (plist-get page :height))) pages))
         (width (max 1 (- (car viewport) (* nnopds-comic-gap (1- (length pages))))))
         (height (max 1 (floor (min (cdr viewport) (/ width (apply #'+ ratios)))))))
    (mapcar (lambda (ratio) (cons (max 1 (floor (* height ratio))) height)) ratios)))

(defun nnopds-comic--commit (reader visible)
  "Record READER's original page after VISIBLE images were displayed."
  (let* ((book (nnopds-comic--reader-book reader))
         (anchor (nnopds-comic--reader-anchor reader))
         (changed (not (eq anchor (nnopds-comic--reader-committed reader)))))
    (with-current-buffer (nnopds-comic--reader-summary reader)
      (save-excursion
        (when changed
          (gnus-summary-goto-subject anchor)
          (gnus-run-hooks 'gnus-mark-article-hook))
        ;; Showing the companion image also reads it, preserving ticks and
        ;; other deliberate Gnus marks.  Prefetch never reaches this code.
        (dolist (number visible)
          (let ((mark (gnus-summary-article-mark number)))
            (when (and (/= number anchor)
                       (or (gnus-unread-mark-p mark) (gnus-read-mark-p mark)))
              (gnus-summary-mark-article number gnus-read-mark t))))
        (gnus-summary-goto-subject anchor)))
    (when changed
      (setf (nnopds-comic--reader-committed reader) anchor
            (nnopds-comic--book-position book) anchor)
      (nnopds-comic--save book))))

(defun nnopds-comic--redraw (reader)
  "Redraw READER's current layout, committing only a complete displayed spread."
  (let* ((book (nnopds-comic--reader-book reader))
         (visible (nnopds-comic--visible reader))
         (can-display (display-images-p)))
    (with-current-buffer (nnopds-comic--reader-article reader)
      ;; Calibre omits dimensions.  Discover them lazily, then recalculate the
      ;; spread containing the same anchor if an image is a landscape spread.
      (when can-display
        (let (stable)
          (while (not stable)
            (dolist (number visible)
              (let* ((page (nnopds-comic--page book number)) (file (nnopds-comic--file book page)))
                (when (and (file-readable-p file) (not (gethash number (nnopds-comic--book-errors book))))
                  (condition-case err
                      (nnopds-comic--dimensions book page)
                    (error
                     (delete-file file)
                     (puthash number (error-message-string err) (nnopds-comic--book-errors book)))))))
            (let ((next (nnopds-comic--visible reader)))
              (setq stable (equal next visible) visible next)))))
      (setq visible (nnopds-comic--visible reader))
      (let* ((display-order (if (eq (nnopds-comic--direction book) 'rtl) (reverse visible) visible))
             (ready (and can-display
                         (cl-every (lambda (number)
                                     (let ((page (nnopds-comic--page book number)))
                                       (and (plist-get page :measured)
                                            (file-readable-p (nnopds-comic--file book page))
                                            (not (gethash number (nnopds-comic--book-errors book)))))) visible)))
             (inhibit-read-only t))
        (save-restriction
          (widen)
          (nnopds-comic--flush-images reader)
          (delete-region (nnopds-comic--reader-start reader) (point-max))
          (goto-char (nnopds-comic--reader-start reader))
          (setq-local header-line-format
                      (format " %s · %s/%d · %s · %s%s"
                              (nnopds--publication-title (nnopds-comic--book-publication book))
                              (string-join (mapcar #'number-to-string visible) "–")
                              (length (nnopds-comic--book-pages book))
                              (nnopds-comic--book-layout book) (nnopds-comic--direction book)
                              (if (nnopds-comic--book-cover book) " · cover single" "")))
          (if ready
              (let* ((pages (mapcar (lambda (number) (nnopds-comic--page book number)) display-order))
                     (viewport (nnopds-comic--viewport))
                     (sizes (nnopds-comic--sizes pages viewport))
                     (padding (max 0 (/ (- (car viewport) (apply #'+ (mapcar #'car sizes))
                                           (* nnopds-comic-gap (1- (length pages)))) 2))))
                (when (> padding 0) (insert (propertize " " 'display `(space :width (,padding)))))
                (cl-loop for page in pages for size in sizes for index from 0 do
                         (when (> index 0) (insert (propertize " " 'display `(space :width (,nnopds-comic-gap)))))
                         (let ((start (point))
                               (image (create-image (nnopds-comic--file book page) (plist-get page :image-type) nil
                                                    :scale 1 :width (car size) :height (cdr size) :ascent 'center)))
                           (unless image (error "Cannot display page image"))
                           (push image (nnopds-comic--reader-images reader))
                           (insert-image image (propertize (format "[Page %d]" (plist-get page :number))
                                                         'nnopds-comic-page (plist-get page :number)))
                           (put-text-property start (point) 'keymap nnopds-comic-mode-map)))
                (insert "\n"))
            (if (not can-display)
                (insert "Comic images require a graphical Emacs frame with image support.\n")
              (dolist (number display-order)
                (insert (format "Page %d: %s\n" number
                                (or (gethash number (nnopds-comic--book-errors book)) "Loading…"))))
              (insert "\ng: retry   1/2: single/double   c: cover   r: direction\n")))
          (set-buffer-modified-p nil)
          (goto-char (nnopds-comic--reader-start reader))
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (set-window-start window (point) t)
            (set-window-point window (point)))
          (when ready (nnopds-comic--commit reader visible)))))))

(defun nnopds-comic--update (reader)
  "Redraw READER and schedule its current images."
  (when (nnopds-comic--live-p reader)
    (condition-case err
        (nnopds-comic--redraw reader)
      (error
       (puthash (nnopds-comic--reader-anchor reader) (error-message-string err)
                (nnopds-comic--book-errors (nnopds-comic--reader-book reader)))
       (nnopds-comic--redraw reader)))
    (with-current-buffer (nnopds-comic--reader-article reader)
      (when (display-images-p) (nnopds-comic--schedule reader)))))

(defun nnopds-comic--resized (window)
  "Refit the active comic in resized WINDOW."
  (when (and nnopds-comic--reader
             (eq (window-buffer window) (current-buffer))
             (nnopds-comic--live-p nnopds-comic--reader))
    (nnopds-comic--update nnopds-comic--reader)))

(defun nnopds-comic--display (article &optional all-headers)
  "Prepare ARTICLE with Gnus, then display its asynchronously fetched images."
  (let ((reader nnopds-comic--reader))
    (nnopds-comic--flush-images reader)
    ;; The ordinary selection hook would mark a loading placeholder read.
    (when (let ((gnus-mark-article-hook nil)) (gnus-article-prepare article all-headers))
      (setf (nnopds-comic--reader-anchor reader) gnus-current-article
            (nnopds-comic--reader-article reader) (get-buffer gnus-article-buffer))
      (with-current-buffer gnus-article-buffer
        (when (and nnopds-comic--reader (not (eq reader nnopds-comic--reader)))
          (nnopds-comic--close nnopds-comic--reader))
        (setq-local nnopds-comic--reader reader)
        (nnopds-comic-mode 1)
        (widen)
        (article-goto-body)
        (when (nnopds-comic--reader-start reader) (set-marker (nnopds-comic--reader-start reader) nil))
        (setf (nnopds-comic--reader-start reader) (point-marker)))
      (nnopds-comic--update reader)
      t)))

(defun nnopds-comic--close (reader)
  "Detach READER and cancel requests when its book has no remaining readers."
  (unless (nnopds-comic--reader-closed reader)
    (setf (nnopds-comic--reader-closed reader) t)
    (nnopds-comic--flush-images reader)
    (when (nnopds-comic--reader-start reader) (set-marker (nnopds-comic--reader-start reader) nil))
    (dolist (buffer (list (nnopds-comic--reader-summary reader) (nnopds-comic--reader-article reader)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq reader nnopds-comic--reader)
            (nnopds-comic-mode -1)
            (setq nnopds-comic--reader nil)))))
    (let ((book (nnopds-comic--reader-book reader)))
      (setf (nnopds-comic--book-readers book) (delq reader (nnopds-comic--book-readers book)))
      (unless (nnopds-comic--book-readers book) (nnopds-comic--cancel book)))))

(defun nnopds-comic--killed ()
  "Close the comic session owning the killed buffer."
  (when nnopds-comic--reader (nnopds-comic--close nnopds-comic--reader)))

(cl-defmethod nnopds--close-reader ((_format (eql comic)) book)
  (dolist (reader (copy-sequence (nnopds-comic--book-readers book))) (nnopds-comic--close reader)))

(cl-defmethod nnopds--dispose ((_format (eql comic)) book)
  (setf (nnopds-comic--book-closed book) t)
  (nnopds--close-reader 'comic book)
  (nnopds-comic--cancel book))

(cl-defmethod nnopds--prepare-reader ((_format (eql comic)) book)
  (when nnopds-comic--reader (nnopds-comic--close nnopds-comic--reader))
  (setq-local nnopds-comic--reader
              (nnopds-comic--make-reader :book book :summary (current-buffer)
                                         :anchor (or (nnopds-comic--book-position book) 1)))
  (push nnopds-comic--reader (nnopds-comic--book-readers book))
  (nnopds-comic-mode 1)
  (when (nnopds-comic--book-position book)
    (gnus-summary-goto-article (nnopds-comic--book-position book) nil t)))

(defvar-keymap nnopds-comic-mode-map
  "1" #'nnopds-comic-single-page
  "2" #'nnopds-comic-double-page
  "c" #'nnopds-comic-toggle-cover
  "r" #'nnopds-comic-toggle-direction
  "n" #'nnopds-comic-next
  "p" #'nnopds-comic-previous
  "SPC" #'nnopds-comic-next
  "DEL" #'nnopds-comic-previous
  "<right>" #'nnopds-comic-right
  "<left>" #'nnopds-comic-left
  "j" #'nnopds-comic-goto-page
  "g" #'nnopds-comic-retry)

(define-minor-mode nnopds-comic-mode
  "Read streaming comics in this Gnus summary or article buffer.
\\<nnopds-comic-mode-map>\\[nnopds-comic-single-page]/\\[nnopds-comic-double-page] select single/double pages,
\\[nnopds-comic-toggle-cover] toggles a separate cover, and \\[nnopds-comic-toggle-direction] reverses reading direction.
\\[nnopds-comic-next]/\\[nnopds-comic-previous] follow reading order; arrow keys follow the reading direction."
  :lighter " Comic"
  (if nnopds-comic-mode
      (progn
        (when (and (derived-mode-p 'gnus-summary-mode) (not nnopds-comic--saved-variables))
          (push (list 'gnus-summary-display-article-function
                      (local-variable-p 'gnus-summary-display-article-function)
                      gnus-summary-display-article-function) nnopds-comic--saved-variables)
          (setq-local gnus-summary-display-article-function #'nnopds-comic--display))
        (when (and (derived-mode-p 'gnus-article-mode) (not nnopds-comic--saved-variables))
          (dolist (entry '((truncate-lines . t) (bidi-paragraph-direction . left-to-right)
                           (cursor-type . nil) (header-line-format . nil)))
            (let ((variable (car entry)))
              (push (list variable (local-variable-p variable) (symbol-value variable)) nnopds-comic--saved-variables)
              (set (make-local-variable variable) (cdr entry))))
          (add-hook 'window-size-change-functions #'nnopds-comic--resized nil t))
        (add-hook 'kill-buffer-hook #'nnopds-comic--killed nil t))
    (remove-hook 'kill-buffer-hook #'nnopds-comic--killed t)
    (remove-hook 'window-size-change-functions #'nnopds-comic--resized t)
    (dolist (entry nnopds-comic--saved-variables)
      (if (nth 1 entry) (set (make-local-variable (car entry)) (nth 2 entry))
        (kill-local-variable (car entry))))
    (setq nnopds-comic--saved-variables nil)
    (when (and nnopds-comic--reader (not (nnopds-comic--reader-closed nnopds-comic--reader)))
      (nnopds-comic--close nnopds-comic--reader))))

(defun nnopds-comic--current ()
  "Return the comic reader for commands in its summary or article."
  (or (and nnopds-comic--reader (not (nnopds-comic--reader-closed nnopds-comic--reader)) nnopds-comic--reader)
      (user-error "No comic is open in this buffer")))

(defun nnopds-comic--preference (key value)
  "Set view preference KEY to VALUE while retaining the original page anchor."
  (let* ((reader (nnopds-comic--current)) (book (nnopds-comic--reader-book reader)))
    (pcase key
      ('layout (setf (nnopds-comic--book-layout book) value))
      ('cover (setf (nnopds-comic--book-cover book) value))
      ('direction (setf (nnopds-comic--book-direction book) value)))
    (nnopds-comic--save book)
    (nnopds-comic--notify book)))

(defun nnopds-comic-single-page ()
  "Show one original page at a time."
  (interactive)
  (nnopds-comic--preference 'layout 'single))

(defun nnopds-comic-double-page ()
  "Show pairs of original pages, keeping the current page visible."
  (interactive)
  (nnopds-comic--preference 'layout 'double))

(defun nnopds-comic-toggle-cover ()
  "Toggle whether the cover occupies its own spread."
  (interactive)
  (nnopds-comic--preference 'cover (not (nnopds-comic--book-cover (nnopds-comic--reader-book (nnopds-comic--current))))))

(defun nnopds-comic-set-direction (direction)
  "Set DIRECTION to auto, ltr or rtl, keeping the same original page."
  (interactive (list (intern (completing-read "Reading direction: " '("auto" "ltr" "rtl") nil t))))
  (unless (memq direction '(auto ltr rtl)) (user-error "Direction must be auto, ltr or rtl"))
  (nnopds-comic--preference 'direction direction))

(defun nnopds-comic-toggle-direction ()
  "Switch between left-to-right and right-to-left reading."
  (interactive)
  (nnopds-comic-set-direction
   (if (eq (nnopds-comic--direction (nnopds-comic--reader-book (nnopds-comic--current))) 'rtl) 'ltr 'rtl)))

(defun nnopds-comic-goto-page (number)
  "Display original page NUMBER, preserving its identity in double page mode."
  (interactive "nPage: ")
  (let* ((reader (nnopds-comic--current)) (book (nnopds-comic--reader-book reader)))
    (unless (and (integerp number) (<= 1 number (length (nnopds-comic--book-pages book))))
      (user-error "Page out of range"))
    (with-current-buffer (nnopds-comic--reader-summary reader)
      (gnus-summary-goto-article number nil t))))

(defun nnopds-comic--move (amount)
  "Move AMOUNT reading units, independent of their on-screen order."
  (let* ((reader (nnopds-comic--current))
         (spreads (nnopds-comic--spreads (nnopds-comic--reader-book reader)))
         (index (cl-position-if (lambda (spread) (memq (nnopds-comic--reader-anchor reader) spread)) spreads))
         (target (+ index amount)))
    (unless (<= 0 target (1- (length spreads))) (user-error "End of comic"))
    (nnopds-comic-goto-page (car (nth target spreads)))))

(defun nnopds-comic-next (&optional count)
  "Advance COUNT reading units."
  (interactive "p")
  (nnopds-comic--move (or count 1)))

(defun nnopds-comic-previous (&optional count)
  "Go back COUNT reading units."
  (interactive "p")
  (nnopds-comic--move (- (or count 1))))

(defun nnopds-comic-right ()
  "Turn right according to the current reading direction."
  (interactive)
  (nnopds-comic--move (if (eq (nnopds-comic--direction (nnopds-comic--reader-book (nnopds-comic--current))) 'rtl) -1 1)))

(defun nnopds-comic-left ()
  "Turn left according to the current reading direction."
  (interactive)
  (nnopds-comic--move (if (eq (nnopds-comic--direction (nnopds-comic--reader-book (nnopds-comic--current))) 'rtl) 1 -1)))

(defun nnopds-comic-retry ()
  "Retry failed images in the current reading unit."
  (interactive)
  (let* ((reader (nnopds-comic--current)) (book (nnopds-comic--reader-book reader)))
    (dolist (number (nnopds-comic--visible reader)) (remhash number (nnopds-comic--book-errors book)))
    (nnopds-comic--update reader)))

(provide 'nnopds-comic)
;;; nnopds-comic.el ends here
