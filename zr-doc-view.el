;;; zr-doc-view.el --- Multiple pages in DocView windows -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Enable `zr-doc-view-mode' in a DocView buffer, or open a document with
;; `zr-doc-view-open'.  Consecutive pages share a window and an equal display
;; height.  The current original page anchors the view: arrows move one page;
;; SPC and DEL move a whole view.  Conversion, search, bookmarks and document
;; caches belong to DocView.  Loading this library installs no extensions.
;;
;; DocView has no replaceable layout function.  While at least one buffer opts
;; in, three guarded advices compose page images, refresh completed neighbors,
;; and report the composed image size to DocView's scaling/scrolling commands.
;; Window and buffer lifecycle management uses hooks.  A DocView slice displays
;; its current page alone; clearing the slice restores the multiple-page view.
;;
;; `zr-doc-view-page-change-functions' and `zr-doc-view-after-display-functions'
;; allow another reader to follow original page numbers without depending on
;; the layout implementation.  Only the latter reports fully displayed views.

;;; Code:

(require 'cl-lib)
(require 'doc-view)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function image-flush "image.c" (spec &optional frame))
(declare-function clear-image-cache "image.c" (&optional filter))

(defgroup zr-doc-view nil
  "Multiple-page reading in DocView."
  :group 'doc-view)

(defcustom zr-doc-view-visible-pages 2
  "Maximum number of consecutive pages shown in an enabled buffer."
  :type 'natnum
  :group 'zr-doc-view)
(make-variable-buffer-local 'zr-doc-view-visible-pages)

(defcustom zr-doc-view-direction 'auto
  "Horizontal reading direction in an enabled buffer.
Auto follows the publication when a reader provides a direction.
Right-to-left reverses page placement and arrow keys.  SPC and DEL always
follow the original document order."
  :type '(choice (const auto) (const ltr) (const rtl))
  :group 'zr-doc-view)
(make-variable-buffer-local 'zr-doc-view-direction)

(defcustom zr-doc-view-cover-single nil
  "Whether the first page is displayed alone."
  :type 'boolean
  :group 'zr-doc-view)
(make-variable-buffer-local 'zr-doc-view-cover-single)

(defcustom zr-doc-view-landscape-single t
  "Whether landscape pages are displayed alone.
Page dimensions become available as DocView converts the document."
  :type 'boolean
  :group 'zr-doc-view)
(make-variable-buffer-local 'zr-doc-view-landscape-single)

(defcustom zr-doc-view-gap 12
  "Horizontal space between page images at fitted scale, in pixels."
  :type 'natnum
  :group 'zr-doc-view)
(make-variable-buffer-local 'zr-doc-view-gap)

(defvar-local zr-doc-view-page-change-functions nil
  "Functions called with (WINDOW PAGE) when the original page changes.
The current buffer is the document buffer.  PAGE is numbered from one.
Images may still be loading; use `zr-doc-view-after-display-functions' to
record pages as read.")

(defvar-local zr-doc-view-after-display-functions nil
  "Functions called with (WINDOW PAGES) after a complete view is displayed.
PAGES are original page numbers in document order, including in RTL layouts.
Loading or failed views are not reported.  Redrawing the same complete view
for a resize, zoom or direction change does not report it again.")

(cl-defstruct (zr-doc-view--view (:constructor zr-doc-view--make-view))
  window page pages images complete signature slice-width (zoom 1.0))

(defvar zr-doc-view-mode)
(defvar zr-doc-view--buffers nil)
(defvar zr-doc-view--rendering nil)
(defvar zr-doc-view--opening-buffer nil)
(defvar-local zr-doc-view--saved-variables nil)
(defvar-local zr-doc-view--dimensions nil)
(defvar-local zr-doc-view--last-width nil)

(defun zr-doc-view--file (page)
  "Return DocView's cached image file for original PAGE."
  (expand-file-name (format doc-view--image-file-pattern page)
                    (doc-view--current-cache-dir)))

(defun zr-doc-view--create-image (file &rest properties)
  "Create a page image from FILE with PROPERTIES in the current DocView buffer."
  (apply #'create-image file doc-view--image-type nil :scale 1
         (append properties
                 (when (eq doc-view--image-type 'svg)
                   (list :background (face-background 'doc-view-svg-face)
                         :foreground (face-foreground 'doc-view-svg-face)
                         :css "svg{fill:currentcolor;}")))))

(defun zr-doc-view--info (page)
  "Return original PAGE's image path, dimensions and conversion state."
  (let* ((file (zr-doc-view--file page))
         (attributes (file-attributes file))
         (stamp (when attributes
                  (list doc-view--image-type
                        (file-attribute-size attributes)
                        (file-attribute-modification-time attributes)
                        (file-attribute-file-identifier attributes))))
         (cached (gethash file zr-doc-view--dimensions))
         size failure)
    (when (and attributes (display-images-p))
      (if (equal stamp (car cached))
          (setq size (cdr cached))
        (condition-case err
            ;; Emacs returns a 30-pixel placeholder on decode failure and
            ;; applies margins only to a successfully loaded image.
            (let* ((margin 16)
                   (image (zr-doc-view--create-image file :margin margin)))
              (unwind-protect
                  (let ((measured (and image (image-size image t)))
                        (padding (* 2 margin)))
                    (unless (and measured (> (car measured) padding)
                                 (> (cdr measured) padding))
                      (error "Cannot decode page %d" page))
                    (setq size (cons (- (car measured) padding) (- (cdr measured) padding)))
                    (puthash file (cons stamp size) zr-doc-view--dimensions))
                (when image (image-flush image))))
          (error (setq size nil failure (error-message-string err))))))
    (list :page page :file file :stamp stamp :size size :error failure)))

(defun zr-doc-view--page-size (page &optional required)
  "Return PAGE's decoded dimensions, signaling an error when REQUIRED."
  (or (plist-get (zr-doc-view--info page) :size)
      (when required (user-error "Page %d is not ready for screen navigation" page))))

(defun zr-doc-view--standalone-p (page &optional require-size)
  "Whether PAGE occupies its own view, optionally REQUIRE-SIZE to decide."
  (or (and zr-doc-view-cover-single (= page 1))
      (when-let* ((size (and zr-doc-view-landscape-single
                            (zr-doc-view--page-size page require-size))))
        (> (car size) (cdr size)))))

(defun zr-doc-view-page-count ()
  "Return the current DocView document's confirmed page count, or nil.
An incomplete conversion may already have generated some page images."
  (when (and (derived-mode-p 'doc-view-mode)
             (file-readable-p (expand-file-name "resolution.el" (doc-view--current-cache-dir))))
    (doc-view-last-page-number)))

(defun zr-doc-view-page-range (page page-count visible-pages standalone-p)
  "Return up to VISIBLE-PAGES consecutive pages starting at PAGE.
Page numbers start at one.  PAGE-COUNT is nil if the last page is unknown.
STANDALONE-P takes a page number and returns non-nil if it must appear alone."
  (when (or (null page-count) (<= page page-count))
    (if (or (= visible-pages 1) (funcall standalone-p page))
        (list page)
      (let ((end (+ page (1- visible-pages)))
            (pages (list page)))
        (cl-loop for number from (1+ page) to (if page-count (min end page-count) end)
                 until (funcall standalone-p number)
                 do (push number pages))
        (nreverse pages)))))

(defun zr-doc-view-screen-target
    (page direction page-count visible-pages standalone-p &optional check-page)
  "Return the adjacent screen's start from PAGE in DIRECTION, or nil at an end.
A positive DIRECTION moves forward.  PAGE-COUNT, VISIBLE-PAGES and
STANDALONE-P are as in `zr-doc-view-page-range'.
If CHECK-PAGE is non-nil, call it on each page being left when moving
forward and on the target page.  It can signal if a page is unavailable."
  (let ((target
         (cond
          ((> direction 0)
           (let ((pages (zr-doc-view-page-range page page-count visible-pages standalone-p)))
             (when check-page (mapc check-page pages))
             (1+ (or (car (last pages)) page))))
          ((> page 1)
           (let ((number (1- page))
                 (earliest (max 1 (- page visible-pages))))
             (unless (or (= visible-pages 1) (funcall standalone-p number))
               (while (and (> number earliest) (not (funcall standalone-p (1- number))))
                 (cl-decf number)))
             number)))))
    (when (and target (or (null page-count) (<= target page-count)))
      (when check-page (funcall check-page target))
      target)))

(defun zr-doc-view--pages-from (page)
  "Return a view starting at PAGE in document order."
  (zr-doc-view-page-range
   page (zr-doc-view-page-count) (if (doc-view-current-slice) 1 zr-doc-view-visible-pages)
   #'zr-doc-view--standalone-p))

(defun zr-doc-view--view ()
  "Return the selected document window's independent view state."
  (let ((old (image-mode-window-get 'zr-doc-view-view))
        (window (selected-window)))
    (if (and old (eq window (zr-doc-view--view-window old)))
        old
      (let ((view (zr-doc-view--make-view
                   :window window :zoom (if old (zr-doc-view--view-zoom old) 1.0))))
        (image-mode-window-put 'zr-doc-view-view view)
        view))))

(defun zr-doc-view--flush (view)
  "Release the decoded images retained by VIEW."
  (let ((frame (window-frame (zr-doc-view--view-window view))))
    (when (and (frame-live-p frame) (display-graphic-p frame) (fboundp 'image-flush))
      (dolist (image (zr-doc-view--view-images view))
        (image-flush image frame))))
  (setf (zr-doc-view--view-images view) nil))

(defun zr-doc-view--viewport ()
  "Return the selected window's available pixel width and height."
  (cons (max 1 (- (window-body-width nil t) 2))
        (max 1 (- (window-body-height nil t) 2))))

(defun zr-doc-view-fit-pages (sizes viewport gap &optional zoom)
  "Fit page SIZES to VIEWPORT with equal heights and a GAP, then apply ZOOM.
SIZES is a list of (WIDTH . HEIGHT) pairs."
  (when sizes
    (let* ((ratios (mapcar (lambda (size) (/ (float (car size)) (cdr size))) sizes))
           (width (max 1 (- (car viewport) (* gap (1- (length sizes))))))
           (height (max 1 (floor (* (or zoom 1) (min (cdr viewport) (/ width (apply #'+ ratios))))))))
      (mapcar (lambda (ratio) (cons (max 1 (floor (* height ratio))) height)) ratios))))

(defun zr-doc-view--sizes (infos viewport zoom)
  "Fit INFOS to VIEWPORT with equal heights, then apply ZOOM."
  (zr-doc-view-fit-pages (mapcar (lambda (info) (plist-get info :size)) infos)
                        viewport zr-doc-view-gap zoom))

(defun zr-doc-view--notify (view page pages ready)
  "Report VIEW's changed PAGE and completely displayed PAGES when READY."
  (let ((window (selected-window))
        (buffer (current-buffer))
        (changed (not (eql page (zr-doc-view--view-page view)))))
    (setf (zr-doc-view--view-page view) page
          (zr-doc-view--view-pages view) pages)
    (when changed
      (setf (zr-doc-view--view-complete view) nil)
      (save-selected-window
        (save-current-buffer
          (run-hook-with-args 'zr-doc-view-page-change-functions window page))))
    ;; A page-change consumer can navigate again.  Never report its old view.
    (when (and ready (buffer-live-p buffer) (window-live-p window)
               (eq (window-buffer window) buffer))
      (with-selected-window window
        (when (and zr-doc-view-mode (eql page (doc-view-current-page))
                   (eq view (image-mode-window-get 'zr-doc-view-view))
                   (zr-doc-view--view-images view)
                   (equal pages (zr-doc-view--view-pages view))
                   (not (equal pages (zr-doc-view--view-complete view))))
          (setf (zr-doc-view--view-complete view) (copy-sequence pages))
          (run-hook-with-args 'zr-doc-view-after-display-functions
                              window (copy-sequence pages)))))))

(defun zr-doc-view--render (view)
  "Display consecutive images for VIEW in the selected document window."
  (unless zr-doc-view--rendering
    (let* ((page (max 1 (or (doc-view-current-page) 1)))
           (pages (zr-doc-view--pages-from page))
           (infos (mapcar #'zr-doc-view--info pages))
           (viewport (zr-doc-view--viewport))
           (ready (and pages (display-images-p)
                       (cl-every (lambda (info) (plist-get info :size)) infos)))
           (signature (list page pages infos viewport zr-doc-view-gap
                            zr-doc-view-direction (zr-doc-view--view-zoom view)))
           (overlay (doc-view-current-overlay)))
      (let ((zr-doc-view--rendering t))
        (setf (zr-doc-view--view-slice-width view) nil)
        (setf (doc-view-current-page) page)
        (unless (and (equal signature (zr-doc-view--view-signature view))
                     (eq (overlay-buffer overlay) (current-buffer)))
          (zr-doc-view--flush view)
          (let (images display dimensions failure)
            (when ready
              (condition-case err
                  (let* ((zoom (zr-doc-view--view-zoom view))
                         (gap (round (* zoom zr-doc-view-gap)))
                         (sizes (zr-doc-view--sizes infos viewport zoom))
                         (width (+ (apply #'+ (mapcar #'car sizes))
                                   (* gap (1- (length sizes))))))
                    (cl-mapc
                     (lambda (info size)
                       (let ((image (zr-doc-view--create-image
                                     (plist-get info :file) :width (car size) :height (cdr size)
                                     :ascent 'center :pointer 'arrow :transform-smoothing t)))
                         (unless image (error "Cannot display page %d" (plist-get info :page)))
                         (push image images)))
                     infos sizes)
                    (setq images (nreverse images)
                          dimensions (cons width (cdar sizes)))
                    (let ((items (cl-mapcar
                                  (lambda (number image)
                                    (propertize " " 'display image 'zr-doc-view-page number
                                                'help-echo (format "Page %d" number)))
                                  pages images)))
                      (when (eq zr-doc-view-direction 'rtl) (setq items (nreverse items)))
                      (setq display
                            (mapconcat #'identity items
                                       (propertize " " 'display
                                                   `(space :width (,gap)))))))
                (error
                 (setq failure (error-message-string err) ready nil)
                 (dolist (image images) (image-flush image))
                 (setq images nil dimensions nil))))
            (unless ready
              (setq display
                    (cond
                     ((not (display-images-p)) "Page images require a graphical Emacs frame.")
                     (failure failure)
                     ((null pages) "The document has no rendered pages.  Press g to reconvert.")
                     (t (mapconcat
                         (lambda (info)
                           (format "Page %d: %s" (plist-get info :page)
                                   (or (plist-get info :error)
                                       (if (plist-get info :size) "Ready"
                                         (if doc-view--current-converter-processes "Loading…"
                                           "Image unavailable; press g to reconvert")))))
                         infos "\n")))))
            (setf (zr-doc-view--view-images view) images
                  (zr-doc-view--view-signature view) (unless failure signature)
                  (doc-view-current-image) (car images))
            (move-overlay overlay (point-min) (point-max))
            ;; Display replacement strings do not interpret nested image
            ;; properties.  Overlay strings do; the zero-size replacement
            ;; hides the source bytes and carries the size for image-mode.
            (overlay-put overlay 'display
                         (if dimensions
                             `(space :width (0) :height (0) :zr-doc-view-size ,dimensions)
                           display))
            (overlay-put overlay 'before-string
                         (when dimensions
                           (concat
                            (when (< (car dimensions) (car viewport))
                              (propertize " " 'display
                                          `(space :width (,(/ (- (car viewport) (car dimensions)) 2)))))
                            display)))
            (when (or (not ready) (not (eql page (zr-doc-view--view-page view))))
              (image-set-window-hscroll 0)
              (image-set-window-vscroll 0))
            (set-window-start (selected-window) (point-min) t)
            (force-mode-line-update))))
      (zr-doc-view--notify view page pages ready))))

(defun zr-doc-view--insert-slice (original args view)
  "Render a native crop in VIEW with ORIGINAL and ARGS."
  (let* ((page (doc-view-current-page))
         (info (zr-doc-view--info page))
         (file (when (plist-get info :size) (plist-get info :file)))
         (zoom (zr-doc-view--view-zoom view)))
    (when (and file (null (zr-doc-view--view-slice-width view)))
      ;; Slice coordinates refer to the anchor image displayed before cropping.
      (setf (zr-doc-view--view-slice-width view)
            (if-let* ((image (doc-view-current-image)))
                (/ (car (image-size image t)) zoom)
              (caar (zr-doc-view--sizes (list info) (zr-doc-view--viewport) 1.0)))))
    (zr-doc-view--flush view)
    (when-let* ((width (zr-doc-view--view-slice-width view)))
      (setq args (plist-put args :width (max 1 (round (* width zoom))))))
    (apply original file (plist-put args :scale 1))
    (let ((image (doc-view-current-image)))
      (setf (zr-doc-view--view-images view) (and image (list image))
            (zr-doc-view--view-signature view) nil)
      (zr-doc-view--notify view page (list page) image))))

(defun zr-doc-view--insert-image (original file &rest args)
  "Adapt ORIGINAL's insertion of FILE with ARGS in enabled buffers."
  (if (not zr-doc-view-mode)
      (apply original file args)
    (when (and (not (eq (current-buffer) zr-doc-view--opening-buffer))
               (eq (current-buffer) (window-buffer))
               (window-live-p (overlay-get (doc-view-current-overlay) 'window)))
      (let ((view (zr-doc-view--view)))
        (when-let* ((width (plist-get args :width)))
          (setf (zr-doc-view--view-zoom view)
                (if (local-variable-p 'doc-view-image-width)
                    (* (zr-doc-view--view-zoom view) (/ (float width) zr-doc-view--last-width))
                  ;; DocView resets zoom by killing this local variable.
                  1.0))
          (setq zr-doc-view--last-width (max 1 width)))
        (when doc-view--pending-cache-flush
          (clear-image-cache)
          (clrhash zr-doc-view--dimensions)
          (setq doc-view--pending-cache-flush nil))
        (if (doc-view-current-slice)
            (zr-doc-view--insert-slice original args view)
          (zr-doc-view--render view))))))

(defun zr-doc-view--display-size (original spec &optional pixels frame)
  "Return composed SPEC's size, or delegate to ORIGINAL using PIXELS and FRAME."
  (if-let* ((size (and zr-doc-view-mode (consp spec) (eq (car spec) 'space)
                      (plist-get (cdr spec) :zr-doc-view-size))))
      (if pixels (cons (car size) (cdr size))
        (cons (/ (float (car size)) (frame-char-width frame))
              (/ (float (cdr size)) (frame-char-height frame))))
    (funcall original spec pixels frame)))

(defun zr-doc-view--refresh (&rest _)
  "Redraw this buffer's document windows, keeping their original page anchors."
  (when (and zr-doc-view-mode (not zr-doc-view--rendering)
             (not (eq (current-buffer) zr-doc-view--opening-buffer)))
    (dolist (props image-mode-winprops-alist)
      (when-let* ((view (cdr (assq 'zr-doc-view-view (cdr props))))
                  (window (zr-doc-view--view-window view))
                  ((eq window (car props)))
                  ((not (and (window-live-p window)
                             (eq (window-buffer window) (current-buffer))))))
        (zr-doc-view--flush view)
        (setf (zr-doc-view--view-signature view) nil)
        (when-let* ((overlay (cdr (assq 'overlay (cdr props)))))
          (overlay-put overlay 'display "")
          (overlay-put overlay 'before-string nil))))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (with-selected-window window
        (doc-view-insert-image (zr-doc-view--file (max 1 (or (doc-view-current-page) 1)))
                               :pointer 'arrow)))))

(defun zr-doc-view--windows-changed ()
  "Release hidden views and fit visible windows in every enabled buffer."
  (dolist (buffer zr-doc-view--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (zr-doc-view--refresh)))))

(defun zr-doc-view--after-conversion (buffer &optional _force)
  "Refresh BUFFER's companion pages after DocView updates its image cache."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (zr-doc-view--refresh))))

(defun zr-doc-view--new-window (winprops)
  "Fit the newly displayed document window described by WINPROPS."
  (when (window-live-p (car winprops))
    (with-selected-window (car winprops) (zr-doc-view--refresh))))

(defun zr-doc-view--after-revert ()
  "Discard old dimensions before displaying the reconverted document."
  (clrhash zr-doc-view--dimensions)
  (zr-doc-view--refresh))

(defun zr-doc-view--register ()
  "Register the current enabled buffer and install guarded layout adapters."
  (unless zr-doc-view--buffers
    (advice-add 'doc-view-insert-image :around #'zr-doc-view--insert-image)
    (advice-add 'doc-view-display :after #'zr-doc-view--after-conversion)
    (advice-add 'image-display-size :around #'zr-doc-view--display-size)
    (add-hook 'window-configuration-change-hook #'zr-doc-view--windows-changed 90))
  (cl-pushnew (current-buffer) zr-doc-view--buffers))

(defun zr-doc-view--clone ()
  "Register an enabled indirect clone with independent dimension state."
  (when zr-doc-view-mode
    (setq zr-doc-view--saved-variables (copy-tree zr-doc-view--saved-variables)
          zr-doc-view--dimensions (make-hash-table :test #'equal))
    (zr-doc-view--register)))

(defun zr-doc-view--restore-hidden-windows (windows)
  "Restore native DocView once each of the hidden WINDOWS shows this buffer."
  (when windows
    (let ((buffer (current-buffer)) restore)
      (setq restore
            (lambda (window)
              (when (eq (window-buffer window) buffer)
                (setq windows (cl-delete-if-not #'window-live-p windows))
                (let ((pending (memq window windows)))
                  (setq windows (delq window windows))
                  (unless windows
                    (remove-hook 'window-buffer-change-functions restore t))
                  (when pending
                    (with-selected-window window
                      (when (and (not (bound-and-true-p zr-doc-view-mode))
                                 (equal (overlay-get (doc-view-current-overlay) 'display) ""))
                        (doc-view-goto-page (or (doc-view-current-page) 1)))))))))
      (add-hook 'window-buffer-change-functions restore nil t))))

(defun zr-doc-view--disable (&optional redraw)
  "Remove this buffer's layout adapters and optionally REDRAW single pages."
  (remove-hook 'window-size-change-functions #'zr-doc-view--refresh t)
  (remove-hook 'image-mode-new-window-functions #'zr-doc-view--new-window t)
  (remove-hook 'after-revert-hook #'zr-doc-view--after-revert t)
  (remove-hook 'clone-indirect-buffer-hook #'zr-doc-view--clone t)
  (remove-hook 'change-major-mode-hook #'zr-doc-view--stop t)
  (remove-hook 'kill-buffer-hook #'zr-doc-view--stop t)
  (let ((redraw (and redraw zr-doc-view--saved-variables)) hidden)
    (when zr-doc-view--saved-variables
      (dolist (props image-mode-winprops-alist)
        (when-let* ((view (cdr (assq 'zr-doc-view-view (cdr props))))
                    ((eq (car props) (zr-doc-view--view-window view))))
          (zr-doc-view--flush view))
        (when-let* (redraw
                    (overlay (cdr (assq 'overlay (cdr props))))
                    ((or (null (overlay-buffer overlay)) (eq (overlay-buffer overlay) (current-buffer)))))
          (overlay-put overlay 'display "")
          (overlay-put overlay 'before-string nil)
          (when (and (window-live-p (car props)) (not (eq (window-buffer (car props)) (current-buffer))))
            (push (car props) hidden)))
        (setcdr props (assq-delete-all 'zr-doc-view-view (cdr props))))
      (dolist (entry zr-doc-view--saved-variables)
        (if (nth 1 entry)
            (set (make-local-variable (car entry)) (nth 2 entry))
          (kill-local-variable (car entry))))
      (setq zr-doc-view--saved-variables nil
            zr-doc-view--dimensions nil
            zr-doc-view--last-width nil))
    (setq zr-doc-view--buffers (delq (current-buffer)
                                    (cl-delete-if-not #'buffer-live-p zr-doc-view--buffers)))
    (unless zr-doc-view--buffers
      (advice-remove 'doc-view-insert-image #'zr-doc-view--insert-image)
      (advice-remove 'doc-view-display #'zr-doc-view--after-conversion)
      (advice-remove 'image-display-size #'zr-doc-view--display-size)
      (remove-hook 'window-configuration-change-hook #'zr-doc-view--windows-changed))
    (when redraw
      (zr-doc-view--restore-hidden-windows hidden)
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (with-selected-window window
          (doc-view-insert-image (zr-doc-view--file (max 1 (or (doc-view-current-page) 1)))
                                 :pointer 'arrow))))))

(defun zr-doc-view--stop ()
  "Remove this buffer's extensions before it is killed or changes major mode."
  (setq zr-doc-view-mode nil)
  (zr-doc-view--disable))

(defun zr-doc-view--check ()
  "Require an enabled, selected document window."
  (unless (and zr-doc-view-mode (eq (current-buffer) (window-buffer)))
    (user-error "Select a document window with zr-doc-view-mode enabled")))

(defun zr-doc-view-current-pages (&optional window)
  "Return WINDOW's requested original page numbers in document order.
With nil WINDOW, use this buffer's selected or most recent view.  An explicit
WINDOW can display a different buffer; return nil if its mode is disabled.
Some images may still be loading; `zr-doc-view-after-display-functions'
reports successfully displayed views."
  (if window
      (progn
        (unless (window-live-p window) (user-error "Window is not live"))
        (with-selected-window window
          (when zr-doc-view-mode
            (zr-doc-view--pages-from (max 1 (or (doc-view-current-page) 1))))))
    (when zr-doc-view-mode
      (zr-doc-view--pages-from (max 1 (or (doc-view-current-page) 1))))))

(defun zr-doc-view--mode-line ()
  "Describe the current document window's page range."
  (let ((pages (zr-doc-view-current-pages)))
    (format " P%s/%s · %d %s"
            (if pages
                (if (cdr pages) (format "%d–%d" (car pages) (car (last pages)))
                  (number-to-string (car pages)))
              "…")
            (or (zr-doc-view-page-count) "?") zr-doc-view-visible-pages zr-doc-view-direction)))

;;;###autoload
(define-minor-mode zr-doc-view-mode
  "Display multiple consecutive pages in each DocView window.
The current page is the view's starting page.  Arrows move one original
page; SPC/DEL move a view.  Page images fit the window with equal heights;
DocView's zoom, text search and bookmarks continue to work.
Enable only in `doc-view-mode'.  Disabling restores native single-page
display and the buffer's original display settings."
  :lighter " Pages"
  :group 'zr-doc-view
  :keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'zr-doc-view-next-screen)
    (define-key map (kbd "S-SPC") #'zr-doc-view-previous-screen)
    (define-key map (kbd "DEL") #'zr-doc-view-previous-screen)
    (define-key map (kbd "<next>") #'zr-doc-view-next-screen)
    (define-key map (kbd "<prior>") #'zr-doc-view-previous-screen)
    (define-key map (kbd "<right>") #'zr-doc-view-right)
    (define-key map (kbd "<left>") #'zr-doc-view-left)
    (define-key map (kbd "1") #'zr-doc-view-single-page)
    (define-key map (kbd "2") #'zr-doc-view-double-page)
    (define-key map (kbd "v") #'zr-doc-view-set-visible-pages)
    (define-key map (kbd "d") #'zr-doc-view-toggle-direction)
    (define-key map (kbd "C") #'zr-doc-view-toggle-cover)
    (define-key map (kbd "L") #'zr-doc-view-toggle-landscape)
    (define-key map (kbd "g") #'doc-view-reconvert-doc)
    map)
  (if zr-doc-view-mode
      (condition-case err
          (progn
            (unless (derived-mode-p 'doc-view-mode)
              (user-error "Enable zr-doc-view-mode in a DocView buffer"))
            (unless (and (integerp zr-doc-view-visible-pages) (> zr-doc-view-visible-pages 0))
              (user-error "Visible page count must be positive"))
            (unless (memq zr-doc-view-direction '(auto ltr rtl))
              (user-error "Reading direction must be auto, ltr or rtl"))
            (unless (and (integerp zr-doc-view-gap) (>= zr-doc-view-gap 0))
              (user-error "Page gap must be a nonnegative integer"))
            (unless zr-doc-view--saved-variables
              (setq zr-doc-view--saved-variables
                    (mapcar (lambda (variable)
                              (list variable (local-variable-p variable) (symbol-value variable)))
                            '(doc-view-scale-internally doc-view-image-width truncate-lines mode-line-position))
                    zr-doc-view--dimensions (make-hash-table :test #'equal)
                    zr-doc-view--last-width (max 1 doc-view-image-width))
              (setq-local doc-view-scale-internally t
                          doc-view-image-width doc-view-image-width
                          truncate-lines t
                          mode-line-position '(:eval (zr-doc-view--mode-line)))
              (add-hook 'window-size-change-functions #'zr-doc-view--refresh nil t)
              (add-hook 'image-mode-new-window-functions #'zr-doc-view--new-window 90 t)
              (add-hook 'after-revert-hook #'zr-doc-view--after-revert 90 t)
              (add-hook 'clone-indirect-buffer-hook #'zr-doc-view--clone 90 t)
              (add-hook 'change-major-mode-hook #'zr-doc-view--stop nil t)
              (add-hook 'kill-buffer-hook #'zr-doc-view--stop nil t))
            (zr-doc-view--register)
            (zr-doc-view--refresh))
        (error
         (setq zr-doc-view-mode nil)
         (zr-doc-view--disable t)
         (signal (car err) (cdr err))))
    (zr-doc-view--disable t)))

;;;###autoload
(defun zr-doc-view-open (file &optional page)
  "Visit FILE in DocView with multiple-page reading, optionally starting at PAGE.
Return the document buffer.  Conversion uses DocView's configured backend."
  (interactive "fDocument: ")
  (when (and page (not (and (integerp page) (> page 0))))
    (user-error "Page number must be positive"))
  (let ((buffer (find-file-noselect file)))
    (let ((zr-doc-view--opening-buffer (and page buffer)))
      (pop-to-buffer buffer)
      (unless (derived-mode-p 'doc-view-mode) (doc-view-mode))
      (when (and page (derived-mode-p 'doc-view-mode))
        (zr-doc-view--check-page page)
        (doc-view-goto-page page)))
    (zr-doc-view-mode 1)
    buffer))

(defun zr-doc-view-set-visible-pages (count)
  "Display up to COUNT pages, retaining every window's current original page."
  (interactive "nVisible pages: ")
  (zr-doc-view--check)
  (unless (and (integerp count) (> count 0)) (user-error "Page count must be positive"))
  (setq-local zr-doc-view-visible-pages count)
  (zr-doc-view--refresh))

(defun zr-doc-view-single-page ()
  "Display one original page at a time."
  (interactive)
  (zr-doc-view-set-visible-pages 1))

(defun zr-doc-view-double-page ()
  "Display up to two consecutive original pages."
  (interactive)
  (zr-doc-view-set-visible-pages 2))

(defun zr-doc-view-set-direction (direction)
  "Set DIRECTION to auto, ltr or rtl without changing original page anchors."
  (interactive (list (intern (completing-read "Reading direction: " '("auto" "ltr" "rtl") nil t))))
  (zr-doc-view--check)
  (unless (memq direction '(auto ltr rtl)) (user-error "Direction must be auto, ltr or rtl"))
  (setq-local zr-doc-view-direction direction)
  (zr-doc-view--refresh))

(defun zr-doc-view-toggle-direction ()
  "Reverse horizontal page placement and arrow navigation."
  (interactive)
  (zr-doc-view-set-direction (if (eq zr-doc-view-direction 'rtl) 'ltr 'rtl)))

(defun zr-doc-view-toggle-cover ()
  "Toggle whether the first page occupies its own view."
  (interactive)
  (zr-doc-view--check)
  (setq-local zr-doc-view-cover-single (not zr-doc-view-cover-single))
  (zr-doc-view--refresh))

(defun zr-doc-view-toggle-landscape ()
  "Toggle whether landscape pages occupy their own views."
  (interactive)
  (zr-doc-view--check)
  (setq-local zr-doc-view-landscape-single (not zr-doc-view-landscape-single))
  (zr-doc-view--refresh))

(defun zr-doc-view--check-page (page)
  "Require a positive original PAGE within the known document range."
  (let ((limit (zr-doc-view-page-count)))
    (unless (and (integerp page) (> page 0) (or (null limit) (<= page limit)))
      (user-error "Page out of range"))))

(defun zr-doc-view-goto-page (page)
  "Start a multiple-page view at original PAGE, numbered from one."
  (interactive "nPage: ")
  (zr-doc-view--check)
  (zr-doc-view--check-page page)
  (doc-view-goto-page page))

(defun zr-doc-view-right ()
  "Move one original page to the right according to the reading direction."
  (interactive)
  (zr-doc-view--check)
  (zr-doc-view-goto-page (+ (doc-view-current-page) (if (eq zr-doc-view-direction 'rtl) -1 1))))

(defun zr-doc-view-left ()
  "Move one original page to the left according to the reading direction."
  (interactive)
  (zr-doc-view--check)
  (zr-doc-view-goto-page (+ (doc-view-current-page) (if (eq zr-doc-view-direction 'rtl) 1 -1))))

(defun zr-doc-view--screen-target (page direction)
  "Return the adjacent view's start from PAGE in DIRECTION."
  (let ((limit (zr-doc-view-page-count)))
    (or (zr-doc-view-screen-target
         page direction limit (if (doc-view-current-slice) 1 zr-doc-view-visible-pages)
         (lambda (number) (zr-doc-view--standalone-p number t))
         (unless limit (lambda (number) (zr-doc-view--page-size number t))))
        (user-error (if (> direction 0) "End of document" "Beginning of document")))))

(defun zr-doc-view--move-screens (count)
  "Move COUNT display ranges, rendering only the destination view."
  (zr-doc-view--check)
  (let ((page (doc-view-current-page)))
    (dotimes (_ (abs count))
      (setq page (zr-doc-view--screen-target page count)))
    (unless (zerop count) (zr-doc-view-goto-page page))))

(defun zr-doc-view-next-screen (&optional count)
  "Advance COUNT views in original document order."
  (interactive "p")
  (zr-doc-view--move-screens (or count 1)))

(defun zr-doc-view-previous-screen (&optional count)
  "Go back COUNT views in original document order."
  (interactive "p")
  (zr-doc-view--move-screens (- (or count 1))))

(defun zr-doc-view-unload-function ()
  "Remove layout extensions from every enabled document buffer."
  (dolist (buffer (copy-sequence zr-doc-view--buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (zr-doc-view-mode -1))))
  nil)

(provide 'zr-doc-view)
;;; zr-doc-view.el ends here
