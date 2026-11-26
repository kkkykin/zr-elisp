;;; nnopds-paged.el --- Read page images in Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Comics and PDFs provide page images through source-specific adapters.
;; A stable original page anchors a sliding window of up to N pages.
;; Arrow keys move one page; SPC and DEL move by a screen.  Only successfully
;; displayed pages are marked read, and page jobs and decoded images are bounded.

;;; Code:

(require 'nnopds)
(require 'gnus-art)
(require 'gnus-sum)
(require 'image)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function image-flush "image.c" (spec &optional frame))

(defgroup nnopds-paged nil "Page-based reading in Gnus." :group 'nnopds)

(defcustom nnopds-paged-visible-pages 1
  "Initial maximum number of pages shown side by side."
  :type 'integer :group 'nnopds-paged)

(defcustom nnopds-paged-cover-single t
  "Whether a comic's cover is displayed alone by default."
  :type 'boolean :group 'nnopds-paged)

(defcustom nnopds-paged-landscape-single t
  "Whether landscape comic pages are displayed alone by default."
  :type 'boolean :group 'nnopds-paged)

(defcustom nnopds-paged-direction 'auto
  "Initial reading direction; auto follows the publication."
  :type '(choice (const auto) (const ltr) (const rtl)) :group 'nnopds-paged)

(defcustom nnopds-paged-prefetch-pages 4
  "Number of original pages to prepare on either side of the displayed pages."
  :type 'natnum :group 'nnopds-paged)

(defcustom nnopds-paged-max-requests 2
  "Maximum simultaneous page jobs per publication."
  :type 'integer :group 'nnopds-paged)

(defcustom nnopds-paged-gap 12
  "Space in pixels between displayed pages."
  :type 'natnum :group 'nnopds-paged)

(cl-defstruct (nnopds-paged--book (:constructor nnopds-paged--make-book))
  source source-data connection publication pages directory progression visible-pages cover landscape direction position
  readers active queue errors pumping closed)

(cl-defstruct (nnopds-paged--reader (:constructor nnopds-paged--make-reader))
  book summary article anchor start images committed closed)

(cl-defstruct (nnopds-paged--job (:constructor nnopds-paged--make-job))
  cancel temporary)

(defvar-local nnopds-paged--reader nil)
(defvar-local nnopds-paged--saved-variables nil)
(defvar nnopds-paged-mode)
(defvar nnopds-paged-mode-map)

(cl-defgeneric nnopds-paged--file (source book page width)
  "Return the cached image path for PAGE at requested pixel WIDTH.")

(cl-defgeneric nnopds-paged--fetch (source book page width temporary callback)
  "Asynchronously write PAGE's image to TEMPORARY.
Call CALLBACK with nil on success or an error string on failure.
Return a function that cancels this job.  WIDTH is a requested pixel width.")

(cl-defun nnopds-paged--open-book (source connection publication pages directory
                                          &key (progression 'ltr) cover landscape source-data)
  "Create a page book with its saved position and display preferences."
  (let* ((settings (nnopds--read-json (expand-file-name "position.json" directory)))
         (sizes (plist-get settings :sizes))
         (count (plist-get settings :visiblePages))
         (direction (plist-get settings :direction))
         (position (plist-get settings :page)))
    (when (and (vectorp sizes) (= (length sizes) (length pages)))
      (seq-do-indexed
       (lambda (page index)
         (let ((size (aref sizes index)))
           (when (and (not (plist-get page :measured))
                      (vectorp size) (= (length size) 2)
                      (numberp (aref size 0)) (> (aref size 0) 0)
                      (numberp (aref size 1)) (> (aref size 1) 0))
             (setf (plist-get page :width) (aref size 0)
                   (plist-get page :height) (aref size 1)))))
       pages))
    (unless (and (integerp nnopds-paged-visible-pages) (> nnopds-paged-visible-pages 0))
      (error "nnopds-paged-visible-pages must be positive"))
    (nnopds-paged--make-book
     :source source :source-data source-data :connection connection :publication publication
     :pages pages :directory directory :progression progression
     :visible-pages (if (and (integerp count) (> count 0)) count nnopds-paged-visible-pages)
     :cover (if (plist-member settings :cover) (eq (plist-get settings :cover) t) cover)
     :landscape (if (plist-member settings :landscape) (eq (plist-get settings :landscape) t) landscape)
     :direction (if (member direction '("auto" "ltr" "rtl")) (intern direction) nnopds-paged-direction)
     :position (when (and (integerp position) (<= 1 position (length pages))) position)
     :active (make-hash-table :test #'equal) :errors (make-hash-table))))

(cl-defmethod nnopds--chapters (_format (book nnopds-paged--book))
  (nnopds-paged--book-pages book))

(cl-defmethod nnopds--header (_format (book nnopds-paged--book) page _group)
  (let ((publication (nnopds-paged--book-publication book)))
    (make-full-mail-header
     (plist-get page :number) (plist-get page :title)
     (concat (nnopds--publication-author publication) " <reader@nnopds.invalid>")
     (format-time-string "%a, %d %b %Y %T %z"
                         (or (ignore-errors (date-to-time (nnopds--publication-modified publication))) 0) t)
     (format "<%d.%s@nnopds>" (plist-get page :number)
             (secure-hash 'sha256 (nnopds--publication-group publication))) "" 0 0)))

(cl-defmethod nnopds--article (_format (book nnopds-paged--book) page group)
  (let ((header (nnopds--header (nnopds-paged--book-source book) book page group)))
    (concat "Subject: " (rfc2047-encode-string (mail-header-subject header)) "\n"
            "From: " (rfc2047-encode-string (mail-header-from header)) "\n"
            "Date: " (mail-header-date header) "\nMessage-ID: " (mail-header-id header) "\n"
            "Newsgroups: " group "\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\n"
            (plist-get page :title) "\n")))

(cl-defmethod nnopds--locator (_format (book nnopds-paged--book) page)
  (list :href (plist-get page :href) :type (plist-get page :type)
        :locations (list :position (plist-get page :number)
                         :totalProgression (/ (float (1- (plist-get page :number)))
                                              (max 1 (1- (length (nnopds-paged--book-pages book))))))))

(cl-defmethod nnopds--locate (_format (book nnopds-paged--book) locator)
  (let ((number (plist-get (plist-get locator :locations) :position)))
    (if (and (integerp number) (<= 1 number (length (nnopds-paged--book-pages book))))
        (cons number nil)
      (when-let* ((page (cl-find (plist-get locator :href) (nnopds-paged--book-pages book)
                                 :key (lambda (entry) (plist-get entry :href)) :test #'equal)))
        (cons (plist-get page :number) nil)))))

(defun nnopds-paged--save (book)
  "Persist BOOK's original page number and local view preferences."
  (nnopds--write-json
   (expand-file-name "position.json" (nnopds-paged--book-directory book))
   (list :page (nnopds-paged--book-position book)
         :visiblePages (nnopds-paged--book-visible-pages book)
         :landscape (if (nnopds-paged--book-landscape book) t :false)
         :cover (if (nnopds-paged--book-cover book) t :false)
         :direction (symbol-name (nnopds-paged--book-direction book))
         ;; Reuse discovered comic dimensions when reopening the book.
         :sizes (vconcat (seq-map (lambda (page)
                                    (when (and (numberp (plist-get page :width)) (numberp (plist-get page :height)))
                                      (vector (plist-get page :width) (plist-get page :height))))
                                  (nnopds-paged--book-pages book))))))

(defun nnopds-paged--page (book number)
  "Return BOOK's original page NUMBER, numbered from one."
  (aref (nnopds-paged--book-pages book) (1- number)))

(defun nnopds-paged--landscape-p (page)
  "Whether PAGE's known dimensions describe a landscape image."
  (let ((width (plist-get page :width)) (height (plist-get page :height)))
    (and (numberp width) (numberp height) (> width height) (> height 0))))

(defun nnopds-paged--standalone-p (book number)
  "Whether BOOK's original page NUMBER should be displayed alone."
  (or (and (= number 1) (nnopds-paged--book-cover book))
      (and (nnopds-paged--book-landscape book)
           (nnopds-paged--landscape-p (nnopds-paged--page book number)))))

(defun nnopds-paged--pages-from (book anchor)
  "Return BOOK's display range starting at original page ANCHOR."
  (let* ((end (min (length (nnopds-paged--book-pages book))
                   (+ anchor (1- (nnopds-paged--book-visible-pages book)))))
         (number anchor) pages)
    (if (nnopds-paged--standalone-p book anchor)
        (list anchor)
      (while (and (<= number end) (not (nnopds-paged--standalone-p book number)))
        (push number pages)
        (cl-incf number))
      (nreverse pages))))

(defun nnopds-paged--visible (reader)
  "Return consecutive pages starting at READER's original page anchor."
  (nnopds-paged--pages-from (nnopds-paged--reader-book reader)
                            (nnopds-paged--reader-anchor reader)))

(defun nnopds-paged--direction (book)
  "Return BOOK's effective horizontal reading direction."
  (if (eq (nnopds-paged--book-direction book) 'auto)
      (nnopds-paged--book-progression book)
    (nnopds-paged--book-direction book)))

(defun nnopds-paged--live-p (reader)
  "Whether READER still owns its summary, article and selected page."
  (and (not (nnopds-paged--reader-closed reader))
       (buffer-live-p (nnopds-paged--reader-summary reader))
       (buffer-live-p (nnopds-paged--reader-article reader))
       (get-buffer-window (nnopds-paged--reader-article reader) t)
       (buffer-local-value 'nnopds-paged-mode (nnopds-paged--reader-article reader))
       (eq reader (buffer-local-value 'nnopds-paged--reader (nnopds-paged--reader-summary reader)))
       (eq reader (buffer-local-value 'nnopds-paged--reader (nnopds-paged--reader-article reader)))
       (eq (nnopds-paged--reader-anchor reader)
           (buffer-local-value 'gnus-current-article (nnopds-paged--reader-summary reader)))
       (marker-position (nnopds-paged--reader-start reader))))

(defun nnopds-paged--notify (book &optional number)
  "Update BOOK's active readers from current state, never a captured old page."
  (dolist (reader (nnopds-paged--book-readers book))
    (when (and (nnopds-paged--live-p reader)
               (or (null number) (memq number (nnopds-paged--visible reader))))
      (nnopds-paged--update reader))))

(defun nnopds-paged--pump (book)
  "Start queued page jobs up to BOOK's concurrency limit."
  (unless (or (nnopds-paged--book-closed book) (nnopds-paged--book-pumping book))
    (setf (nnopds-paged--book-pumping book) t)
    (unwind-protect
        (while (and (nnopds-paged--book-queue book)
                    (< (hash-table-count (nnopds-paged--book-active book))
                       (max 1 nnopds-paged-max-requests)))
          (pcase-let* ((`(,number . ,width) (pop (nnopds-paged--book-queue book)))
                       (page (nnopds-paged--page book number))
                       (source (nnopds-paged--book-source book))
                       (file (nnopds-paged--file source book page width)))
            (unless (or (file-readable-p file) (gethash number (nnopds-paged--book-errors book))
                        (gethash file (nnopds-paged--book-active book)))
              (let* ((temporary (nnopds--temporary-file file))
                     (job (nnopds-paged--make-job :temporary temporary)))
                (puthash file job (nnopds-paged--book-active book))
                (cl-labels
                    ((done (failure)
                       (unwind-protect
                           (when (eq job (gethash file (nnopds-paged--book-active book)))
                             (remhash file (nnopds-paged--book-active book))
                             (condition-case err
                                 (progn
                                   (when failure (error "%s" failure))
                                   (let ((type (with-temp-buffer
                                                 (set-buffer-multibyte nil)
                                                 (insert-file-contents-literally temporary nil 0 8192)
                                                 (image-type-from-data (buffer-string)))))
                                     (unless type (error "Response is not an image"))
                                     (setf (plist-get page :image-type) type))
                                   (rename-file temporary file t))
                               (error (puthash number (error-message-string err)
                                               (nnopds-paged--book-errors book))))
                             (nnopds-paged--notify book number)
                             (nnopds-paged--pump book))
                         (when (file-exists-p temporary) (delete-file temporary)))))
                  (condition-case err
                      (setf (nnopds-paged--job-cancel job)
                            (nnopds-paged--fetch source book page width temporary #'done))
                    (error (done (error-message-string err)))))))))
      (setf (nnopds-paged--book-pumping book) nil))))

(defun nnopds-paged--targets (reader)
  "Return READER's visible page numbers and requested pixel widths."
  (with-current-buffer (nnopds-paged--reader-article reader)
    (let* ((book (nnopds-paged--reader-book reader))
           (visible (nnopds-paged--visible reader))
           (pages (mapcar (lambda (number)
                            (let ((page (nnopds-paged--page book number)))
                              (if (and (numberp (plist-get page :width)) (> (plist-get page :width) 0)
                                       (numberp (plist-get page :height)) (> (plist-get page :height) 0))
                                  page
                                '(:width 1 :height 1))))
                          visible))
           (sizes (nnopds-paged--sizes pages (nnopds-paged--viewport))))
      (cl-mapcar (lambda (number size)
                   (cons number (max 1 (ceiling (* (car size) (frame-scale-factor))))))
                 visible sizes))))

(defun nnopds-paged--schedule (reader)
  "Prioritize active readers' visible pages, then bounded neighbors."
  (let ((book (nnopds-paged--reader-book reader)) visible neighbors)
    (dolist (current (nnopds-paged--book-readers book))
      (when (nnopds-paged--live-p current)
        (let* ((targets (nnopds-paged--targets current))
               (first (caar targets))
               (last (caar (last targets)))
               (width (apply #'max (mapcar #'cdr targets))))
          (setq visible (append visible targets)
                neighbors
                (append neighbors
                        (mapcar (lambda (number) (cons number width))
                                (append
                                 (number-sequence (1+ last)
                                                  (min (length (nnopds-paged--book-pages book))
                                                       (+ last nnopds-paged-prefetch-pages)))
                                 (number-sequence (1- first)
                                                  (max 1 (- first nnopds-paged-prefetch-pages)) -1))))))))
    (setf (nnopds-paged--book-queue book) (delete-dups (append visible neighbors)))
    (nnopds-paged--pump book)))

(defun nnopds-paged--cancel (book)
  "Cancel BOOK's queued and active jobs without committing any page."
  (let (jobs)
    (maphash (lambda (_file job) (push job jobs)) (nnopds-paged--book-active book))
    (setf (nnopds-paged--book-queue book) nil)
    (clrhash (nnopds-paged--book-active book))
    (dolist (job jobs)
      (when-let* ((cancel (nnopds-paged--job-cancel job))) (funcall cancel))
      (when (file-exists-p (nnopds-paged--job-temporary job))
        (delete-file (nnopds-paged--job-temporary job))))))

(defun nnopds-paged--flush-images (reader)
  "Release the decoded images held by READER."
  (when (fboundp 'image-flush)
    (dolist (image (nnopds-paged--reader-images reader)) (image-flush image)))
  (setf (nnopds-paged--reader-images reader) nil))

(defun nnopds-paged--dimensions (page file)
  "Read PAGE's native image dimensions once, when its file is available."
  (unless (plist-get page :measured)
    (let* ((image (create-image file (plist-get page :image-type) nil :scale 1))
           (size (and image (image-size image t))))
      (unless (and size (> (car size) 0) (> (cdr size) 0)) (error "Cannot decode page image"))
      (image-flush image)
      (setf (plist-get page :width) (car size) (plist-get page :height) (cdr size)
            (plist-get page :measured) t))))

(defun nnopds-paged--viewport ()
  "Return the available image width and height in pixels."
  (let ((window (get-buffer-window (current-buffer) t)))
    (cons (max 1 (- (window-body-width window t) 2))
          (max 1 (- (window-body-height window t) 2)))))

(defun nnopds-paged--sizes (pages viewport)
  "Fit PAGES into VIEWPORT with equal display heights and preserved aspect ratios."
  (let* ((ratios (mapcar (lambda (page) (/ (float (plist-get page :width)) (plist-get page :height))) pages))
         (width (max 1 (- (car viewport) (* nnopds-paged-gap (1- (length pages))))))
         (height (max 1 (floor (min (cdr viewport) (/ width (apply #'+ ratios)))))))
    (mapcar (lambda (ratio) (cons (max 1 (floor (* height ratio))) height)) ratios)))

(defun nnopds-paged--commit (reader visible)
  "Record READER's original page after VISIBLE images were displayed."
  (let* ((book (nnopds-paged--reader-book reader))
         (anchor (nnopds-paged--reader-anchor reader))
         (changed (not (eq anchor (nnopds-paged--reader-committed reader)))))
    (with-current-buffer (nnopds-paged--reader-summary reader)
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
      (setf (nnopds-paged--reader-committed reader) anchor
            (nnopds-paged--book-position book) anchor)
      (nnopds-paged--save book))))

(defun nnopds-paged--redraw (reader)
  "Redraw READER's current layout, committing only a complete displayed view."
  (let* ((book (nnopds-paged--reader-book reader))
         (visible (nnopds-paged--visible reader))
         (targets (nnopds-paged--targets reader))
         (source (nnopds-paged--book-source book))
         (can-display (display-images-p)))
    (with-current-buffer (nnopds-paged--reader-article reader)
      ;; Calibre omits dimensions.  Discover them lazily, then recalculate the
      ;; view containing the same anchor if an image is a landscape view.
      (when can-display
        (let (stable)
          (while (not stable)
            (dolist (number visible)
              (let* ((page (nnopds-paged--page book number))
                     (file (nnopds-paged--file source book page (cdr (assq number targets)))))
                (when (and (file-readable-p file) (not (gethash number (nnopds-paged--book-errors book))))
                  (condition-case err
                      (nnopds-paged--dimensions page file)
                    (error
                     (delete-file file)
                     (puthash number (error-message-string err) (nnopds-paged--book-errors book)))))))
            (let ((next (nnopds-paged--visible reader)))
              (setq stable (equal next visible) visible next
                    targets (nnopds-paged--targets reader))))))
      (setq visible (nnopds-paged--visible reader))
      (let* ((display-order (if (eq (nnopds-paged--direction book) 'rtl) (reverse visible) visible))
             (ready (and can-display
                         (cl-every (lambda (number)
                                     (let ((page (nnopds-paged--page book number)))
                                       (and (plist-get page :measured)
                                            (file-readable-p (nnopds-paged--file source book page (cdr (assq number targets))))
                                            (not (gethash number (nnopds-paged--book-errors book)))))) visible)))
             (inhibit-read-only t))
        (save-restriction
          (widen)
          (nnopds-paged--flush-images reader)
          (delete-region (nnopds-paged--reader-start reader) (point-max))
          (goto-char (nnopds-paged--reader-start reader))
          (setq-local header-line-format
                      (format " %s · %s/%d · %s pages · %s%s"
                              (nnopds--publication-title (nnopds-paged--book-publication book))
                              (string-join (mapcar #'number-to-string visible) "–")
                              (length (nnopds-paged--book-pages book))
                              (nnopds-paged--book-visible-pages book) (nnopds-paged--direction book)
                              (if (nnopds-paged--book-cover book) " · cover single" "")))
          (if ready
              (let* ((pages (mapcar (lambda (number) (nnopds-paged--page book number)) display-order))
                     (viewport (nnopds-paged--viewport))
                     (sizes (nnopds-paged--sizes pages viewport))
                     (padding (max 0 (/ (- (car viewport) (apply #'+ (mapcar #'car sizes))
                                           (* nnopds-paged-gap (1- (length pages)))) 2))))
                (when (> padding 0) (insert (propertize " " 'display `(space :width (,padding)))))
                (cl-loop for page in pages for size in sizes for index from 0 do
                         (when (> index 0) (insert (propertize " " 'display `(space :width (,nnopds-paged-gap)))))
                         (let ((start (point))
                               (image (create-image (nnopds-paged--file source book page
                                                                        (cdr (assq (plist-get page :number) targets)))
                                                    (plist-get page :image-type) nil
                                                    :scale 1 :width (car size) :height (cdr size) :ascent 'center)))
                           (unless image (error "Cannot display page image"))
                           (push image (nnopds-paged--reader-images reader))
                           (insert-image image (propertize (format "[Page %d]" (plist-get page :number))
                                                           'nnopds-paged-page (plist-get page :number)))
                           (put-text-property start (point) 'keymap nnopds-paged-mode-map)))
                (insert "\n"))
            (if (not can-display)
                (insert "Page images require a graphical Emacs frame with image support.\n")
              (dolist (number display-order)
                (insert (format "Page %d: %s\n" number
                                (or (gethash number (nnopds-paged--book-errors book)) "Loading…"))))
              (insert "\ng: retry   1/2/v: page count   c: cover   l: landscape   r: direction\n")))
          (set-buffer-modified-p nil)
          (goto-char (nnopds-paged--reader-start reader))
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (set-window-start window (point) t)
            (set-window-point window (point)))
          (when ready (nnopds-paged--commit reader visible)))))))

(defun nnopds-paged--update (reader)
  "Redraw READER and schedule its current images."
  (when (nnopds-paged--live-p reader)
    (condition-case err
        (nnopds-paged--redraw reader)
      (error
       (puthash (nnopds-paged--reader-anchor reader) (error-message-string err)
                (nnopds-paged--book-errors (nnopds-paged--reader-book reader)))
       (nnopds-paged--redraw reader)))
    (with-current-buffer (nnopds-paged--reader-article reader)
      (when (display-images-p) (nnopds-paged--schedule reader)))))

(defun nnopds-paged--resized (window)
  "Refit the active page reader in resized WINDOW."
  (when (and nnopds-paged--reader
             (eq (window-buffer window) (current-buffer))
             (nnopds-paged--live-p nnopds-paged--reader))
    (nnopds-paged--update nnopds-paged--reader)))

(defun nnopds-paged--display (article &optional all-headers)
  "Prepare ARTICLE with Gnus, then display its asynchronously fetched images."
  (let ((reader nnopds-paged--reader))
    (nnopds-paged--flush-images reader)
    ;; The ordinary selection hook would mark a loading placeholder read.
    (when (let ((gnus-mark-article-hook nil)) (gnus-article-prepare article all-headers))
      (setf (nnopds-paged--reader-anchor reader) gnus-current-article
            (nnopds-paged--reader-article reader) (get-buffer gnus-article-buffer))
      (with-current-buffer gnus-article-buffer
        (when (and nnopds-paged--reader (not (eq reader nnopds-paged--reader)))
          (nnopds-paged--close nnopds-paged--reader))
        (setq-local nnopds-paged--reader reader)
        (nnopds-paged-mode 1)
        (widen)
        (article-goto-body)
        (when (nnopds-paged--reader-start reader) (set-marker (nnopds-paged--reader-start reader) nil))
        (setf (nnopds-paged--reader-start reader) (point-marker)))
      (nnopds-paged--update reader)
      t)))

(defun nnopds-paged--close (reader)
  "Detach READER and cancel jobs when its book has no remaining readers."
  (unless (nnopds-paged--reader-closed reader)
    (setf (nnopds-paged--reader-closed reader) t)
    (nnopds-paged--flush-images reader)
    (when (nnopds-paged--reader-start reader) (set-marker (nnopds-paged--reader-start reader) nil))
    (dolist (buffer (list (nnopds-paged--reader-summary reader) (nnopds-paged--reader-article reader)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq reader nnopds-paged--reader)
            (nnopds-paged-mode -1)
            (setq nnopds-paged--reader nil)))))
    (let ((book (nnopds-paged--reader-book reader)))
      (setf (nnopds-paged--book-readers book) (delq reader (nnopds-paged--book-readers book)))
      (unless (nnopds-paged--book-readers book) (nnopds-paged--cancel book)))))

(defun nnopds-paged--killed ()
  "Close the page reader owning the killed buffer."
  (when nnopds-paged--reader (nnopds-paged--close nnopds-paged--reader)))

(cl-defmethod nnopds--close-reader (_format (book nnopds-paged--book))
  (dolist (reader (copy-sequence (nnopds-paged--book-readers book))) (nnopds-paged--close reader)))

(cl-defmethod nnopds--dispose (_format (book nnopds-paged--book))
  (setf (nnopds-paged--book-closed book) t)
  (nnopds--close-reader (nnopds-paged--book-source book) book)
  (nnopds-paged--cancel book))

(cl-defmethod nnopds--prepare-reader (_format (book nnopds-paged--book))
  (when nnopds-paged--reader (nnopds-paged--close nnopds-paged--reader))
  (setq-local nnopds-paged--reader
              (nnopds-paged--make-reader :book book :summary (current-buffer)
                                         :anchor (or (nnopds-paged--book-position book) 1)))
  (push nnopds-paged--reader (nnopds-paged--book-readers book))
  (nnopds-paged-mode 1)
  (when (nnopds-paged--book-position book)
    (gnus-summary-goto-article (nnopds-paged--book-position book) nil t)))

(defvar-keymap nnopds-paged-mode-map
  "1" #'nnopds-paged-single-page
  "2" #'nnopds-paged-double-page
  "v" #'nnopds-paged-set-visible-pages
  "c" #'nnopds-paged-toggle-cover
  "l" #'nnopds-paged-toggle-landscape
  "r" #'nnopds-paged-toggle-direction
  "n" #'nnopds-paged-next
  "p" #'nnopds-paged-previous
  "SPC" #'nnopds-paged-next
  "DEL" #'nnopds-paged-previous
  "<right>" #'nnopds-paged-right
  "<left>" #'nnopds-paged-left
  "j" #'nnopds-paged-goto-page
  "g" #'nnopds-paged-retry)

(define-minor-mode nnopds-paged-mode
  "Read page images in this Gnus summary or article buffer.
\\<nnopds-paged-mode-map>\\[nnopds-paged-single-page]/\\[nnopds-paged-double-page] select single/double pages,
\\[nnopds-paged-toggle-cover] toggles a separate cover, and \\[nnopds-paged-toggle-direction] reverses reading direction.
\\[nnopds-paged-set-visible-pages] sets an arbitrary page count.
\\[nnopds-paged-next]/\\[nnopds-paged-previous] turn screens in reading order;
arrow keys turn one original page according to the reading direction."
  :lighter " Pages"
  (if nnopds-paged-mode
      (progn
        (when (and (derived-mode-p 'gnus-summary-mode) (not nnopds-paged--saved-variables))
          (push (list 'gnus-summary-display-article-function
                      (local-variable-p 'gnus-summary-display-article-function)
                      gnus-summary-display-article-function) nnopds-paged--saved-variables)
          (setq-local gnus-summary-display-article-function #'nnopds-paged--display))
        (when (and (derived-mode-p 'gnus-article-mode) (not nnopds-paged--saved-variables))
          (dolist (entry '((truncate-lines . t) (bidi-paragraph-direction . left-to-right)
                           (cursor-type . nil) (header-line-format . nil)))
            (let ((variable (car entry)))
              (push (list variable (local-variable-p variable) (symbol-value variable)) nnopds-paged--saved-variables)
              (set (make-local-variable variable) (cdr entry))))
          (add-hook 'window-size-change-functions #'nnopds-paged--resized nil t))
        (add-hook 'kill-buffer-hook #'nnopds-paged--killed nil t))
    (remove-hook 'kill-buffer-hook #'nnopds-paged--killed t)
    (remove-hook 'window-size-change-functions #'nnopds-paged--resized t)
    (dolist (entry nnopds-paged--saved-variables)
      (if (nth 1 entry) (set (make-local-variable (car entry)) (nth 2 entry))
        (kill-local-variable (car entry))))
    (setq nnopds-paged--saved-variables nil)
    (when (and nnopds-paged--reader (not (nnopds-paged--reader-closed nnopds-paged--reader)))
      (nnopds-paged--close nnopds-paged--reader))))

(defun nnopds-paged--current ()
  "Return the page reader for commands in its summary or article."
  (or (and nnopds-paged--reader (not (nnopds-paged--reader-closed nnopds-paged--reader)) nnopds-paged--reader)
      (user-error "No page reader is open in this buffer")))

(defun nnopds-paged--preference (key value)
  "Set view preference KEY to VALUE while retaining the original page anchor."
  (let* ((reader (nnopds-paged--current)) (book (nnopds-paged--reader-book reader)))
    (pcase key
      ('visible-pages (setf (nnopds-paged--book-visible-pages book) value))
      ('landscape (setf (nnopds-paged--book-landscape book) value))
      ('cover (setf (nnopds-paged--book-cover book) value))
      ('direction (setf (nnopds-paged--book-direction book) value)))
    (nnopds-paged--save book)
    (nnopds-paged--notify book)))

(defun nnopds-paged-set-visible-pages (count)
  "Show up to COUNT consecutive pages, retaining the current original page."
  (interactive "nVisible pages: ")
  (unless (and (integerp count) (> count 0)) (user-error "Page count must be positive"))
  (nnopds-paged--preference 'visible-pages count))

(defun nnopds-paged-toggle-landscape ()
  "Toggle whether landscape pages are displayed alone."
  (interactive)
  (nnopds-paged--preference
   'landscape (not (nnopds-paged--book-landscape
                    (nnopds-paged--reader-book (nnopds-paged--current))))))

(defun nnopds-paged-single-page ()
  "Show one original page at a time."
  (interactive)
  (nnopds-paged-set-visible-pages 1))

(defun nnopds-paged-double-page ()
  "Show up to two original pages starting at the current page."
  (interactive)
  (nnopds-paged-set-visible-pages 2))

(defun nnopds-paged-toggle-cover ()
  "Toggle whether the cover occupies its own view."
  (interactive)
  (nnopds-paged--preference 'cover (not (nnopds-paged--book-cover (nnopds-paged--reader-book (nnopds-paged--current))))))

(defun nnopds-paged-set-direction (direction)
  "Set DIRECTION to auto, ltr or rtl, keeping the same original page."
  (interactive (list (intern (completing-read "Reading direction: " '("auto" "ltr" "rtl") nil t))))
  (unless (memq direction '(auto ltr rtl)) (user-error "Direction must be auto, ltr or rtl"))
  (nnopds-paged--preference 'direction direction))

(defun nnopds-paged-toggle-direction ()
  "Switch between left-to-right and right-to-left reading."
  (interactive)
  (nnopds-paged-set-direction
   (if (eq (nnopds-paged--direction (nnopds-paged--reader-book (nnopds-paged--current))) 'rtl) 'ltr 'rtl)))

(defun nnopds-paged-goto-page (number)
  "Display up to N consecutive pages starting at original page NUMBER."
  (interactive "nPage: ")
  (let* ((reader (nnopds-paged--current))
         (book (nnopds-paged--reader-book reader))
         (windows (when (derived-mode-p 'gnus-article-mode) (current-window-configuration))))
    (unless (and (integerp number) (<= 1 number (length (nnopds-paged--book-pages book))))
      (user-error "Page out of range"))
    (unwind-protect
        (with-current-buffer (nnopds-paged--reader-summary reader)
          (gnus-summary-goto-article number nil t))
      (when windows
        ;; Gnus selects the summary while preparing an article.  Keep the
        ;; reader's layout and refit cached images to the restored window.
        (set-window-configuration windows)
        (nnopds-paged--update reader)))))

(defun nnopds-paged--move (amount)
  "Move AMOUNT original pages, independent of the displayed page count."
  (let* ((reader (nnopds-paged--current))
         (target (+ (nnopds-paged--reader-anchor reader) amount)))
    (unless (<= 1 target (length (nnopds-paged--book-pages (nnopds-paged--reader-book reader))))
      (user-error "End of publication"))
    (nnopds-paged-goto-page target)))

(defun nnopds-paged--screen-target (book anchor direction)
  "Return BOOK's adjacent screen start from ANCHOR in DIRECTION."
  (if (> direction 0)
      (let ((target (1+ (car (last (nnopds-paged--pages-from book anchor))))))
        (when (> target (length (nnopds-paged--book-pages book)))
          (user-error "End of publication"))
        target)
    (when (= anchor 1) (user-error "Beginning of publication"))
    (let ((number (1- anchor)) (count 1))
      (unless (nnopds-paged--standalone-p book number)
        (while (and (< count (nnopds-paged--book-visible-pages book))
                    (> number 1)
                    (not (nnopds-paged--standalone-p book (1- number))))
          (cl-decf number)
          (cl-incf count)))
      number)))

(defun nnopds-paged--move-screens (amount)
  "Move AMOUNT screens, preparing only the destination page."
  (unless (zerop amount)
    (let* ((reader (nnopds-paged--current))
           (book (nnopds-paged--reader-book reader))
           (target (nnopds-paged--reader-anchor reader)))
      (dotimes (_ (abs amount))
        (setq target (nnopds-paged--screen-target book target amount)))
      (nnopds-paged-goto-page target))))

(defun nnopds-paged-next (&optional count)
  "Advance COUNT screens in original reading order."
  (interactive "p")
  (nnopds-paged--move-screens (or count 1)))

(defun nnopds-paged-previous (&optional count)
  "Go back COUNT screens in original reading order."
  (interactive "p")
  (nnopds-paged--move-screens (- (or count 1))))

(defun nnopds-paged-right ()
  "Move one original page to the right according to the reading direction."
  (interactive)
  (nnopds-paged--move
   (if (eq (nnopds-paged--direction (nnopds-paged--reader-book (nnopds-paged--current))) 'rtl) -1 1)))

(defun nnopds-paged-left ()
  "Move one original page to the left according to the reading direction."
  (interactive)
  (nnopds-paged--move
   (if (eq (nnopds-paged--direction (nnopds-paged--reader-book (nnopds-paged--current))) 'rtl) 1 -1)))

(defun nnopds-paged-retry ()
  "Retry failed images in the current reading unit."
  (interactive)
  (let* ((reader (nnopds-paged--current)) (book (nnopds-paged--reader-book reader)))
    (dolist (number (nnopds-paged--visible reader)) (remhash number (nnopds-paged--book-errors book)))
    (nnopds-paged--update reader)))

(provide 'nnopds-paged)
;;; nnopds-paged.el ends here
