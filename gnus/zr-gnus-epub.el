;;; zr-gnus-epub.el --- Display EPUB chapters in Gnus -*- lexical-binding: t; -*-

;;; Code:

(require 'zr-epub)
(require 'gnus-sum)
(require 'gnus-art)
(require 'mm-view)
(require 'shr)
(require 'rfc2047)

(defun zr-gnus-epub-header (book chapter identity)
  "Build the mail header for BOOK's CHAPTER using IDENTITY."
  (let ((number (plist-get chapter :number)))
    (make-full-mail-header
     number (plist-get chapter :title)
     (concat (zr-epub-book-author book) " <reader@nnepub.invalid>")
     (format-time-string "%a, %d %b %Y %T %z" (zr-epub-book-modified book) t)
     (format "<%d.%s@nnepub>" number (secure-hash 'sha256 identity)) "" 0 0)))

(defun zr-gnus-epub-article-head (header)
  "Return the message headers for HEADER."
  (concat "Subject: " (rfc2047-encode-string (mail-header-subject header)) "\n"
          "From: " (rfc2047-encode-string (mail-header-from header)) "\n"
          "Date: " (mail-header-date header) "\n"
          "Message-ID: " (mail-header-id header) "\n"
          "MIME-Version: 1.0\n"))

(defun zr-gnus-epub-article (book chapter group header)
  "Build a MIME article for BOOK's CHAPTER in GROUP with HEADER."
  (let* (images
         (html (zr-epub-chapter-html
                book chapter
                (lambda (destination fragment)
                  (concat "zr-epub:" (url-hexify-string group) "/"
                          (number-to-string (plist-get destination :number))
                          (when fragment (concat "#" (url-hexify-string fragment)))))
                (lambda (resource)
                  (let* ((path (file-relative-name (plist-get resource :path) (zr-epub-book-root book)))
                         (id (concat (secure-hash 'sha256 path) "@zr-epub")))
                    (unless (assoc id images) (push (cons id resource) images))
                    (concat "cid:" id)))))
         (boundary (concat "zr-epub-" (secure-hash 'sha256 (mail-header-id header)))))
    (with-temp-buffer
      (insert (zr-gnus-epub-article-head header))
      (when images
        (insert "Content-Type: multipart/related; boundary=\"" boundary "\"\n\n"
                "--" boundary "\n"))
      (insert "Content-Type: text/html; charset=utf-8\n"
              "Content-Transfer-Encoding: base64\n\n"
              (base64-encode-string (encode-coding-string html 'utf-8)) "\n")
      (dolist (image (nreverse images))
        (insert "--" boundary "\nContent-Type: " (plist-get (cdr image) :type) "\n"
                "Content-ID: <" (car image) ">\n"
                "Content-Disposition: inline\nContent-Transfer-Encoding: base64\n\n"
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally (plist-get (cdr image) :path))
                  (base64-encode-string (buffer-string))) "\n"))
      (when images (insert "--" boundary "--\n"))
      (buffer-string))))

(defvar zr-gnus-epub--link-map
  (let ((map (copy-keymap shr-map)))
    (keymap-set map "RET" #'zr-gnus-epub-follow-link)
    (keymap-set map "<mouse-2>" #'zr-gnus-epub-follow-link)
    map))

(defvar-local zr-gnus-epub--reading nil
  "Whether the current summary uses EPUB link rendering.")

(defvar-local zr-gnus-epub--saved-renderer nil
  "Previous HTML renderer and whether it was local to this article buffer.")

(defun zr-gnus-epub--render-html (handle)
  "Render MIME HANDLE using shr and EPUB link bindings."
  (let ((shr-map zr-gnus-epub--link-map)) (mm-shr handle)))

(defun zr-gnus-epub--goto-fragment (fragment)
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

(defun zr-gnus-epub-follow-link (&optional event)
  "Follow an EPUB link at point or mouse EVENT, including chapter anchors."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((url (get-text-property (point) 'shr-url)))
    (if (and url (string-prefix-p "zr-epub:" url))
        (progn
          (unless (string-match "\\`zr-epub:\\([^/]+\\)/\\([0-9]+\\)\\(?:#\\(.*\\)\\)?\\'" url)
            (user-error "Invalid EPUB link"))
          (let ((encoded-group (match-string 1 url))
                (number (string-to-number (match-string 2 url)))
                (fragment (when-let* ((value (match-string 3 url))) (zr-epub-decode-url value))))
            (with-current-buffer gnus-summary-buffer
              (unless (equal (url-hexify-string gnus-newsgroup-name) encoded-group)
                (user-error "EPUB chapter belongs to another group"))
              (unless (gnus-summary-goto-article number nil t)
                (user-error "EPUB chapter not found: %s" number))
              (with-current-buffer gnus-article-buffer (zr-gnus-epub--goto-fragment fragment)))))
      (shr-browse-url event))))

(defun zr-gnus-epub-summary-defaults ()
  "Use chapter order in the current summary unless overridden by group parameters."
  (let ((parameters (gnus-group-find-parameter gnus-newsgroup-name)))
    (dolist (entry '((gnus-show-threads . nil)
                     (gnus-article-sort-functions . (gnus-article-sort-by-number))
                     (gnus-thread-sort-functions . (gnus-thread-sort-by-number))))
      (unless (assq (car entry) parameters)
        (set (make-local-variable (car entry)) (cdr entry))))))

(defun zr-gnus-epub--article-renderer ()
  "Select the renderer for the current article, restoring it on buffer reuse."
  (if (and (gnus-buffer-live-p gnus-summary-buffer)
           (buffer-local-value 'zr-gnus-epub--reading (get-buffer gnus-summary-buffer)))
      (unless zr-gnus-epub--saved-renderer
        (setq zr-gnus-epub--saved-renderer
              (cons (local-variable-p 'mm-text-html-renderer) mm-text-html-renderer))
        (setq-local mm-text-html-renderer #'zr-gnus-epub--render-html))
    (when zr-gnus-epub--saved-renderer
      (if (car zr-gnus-epub--saved-renderer)
          (setq-local mm-text-html-renderer (cdr zr-gnus-epub--saved-renderer))
        (kill-local-variable 'mm-text-html-renderer))
      (setq zr-gnus-epub--saved-renderer nil))))

(defun zr-gnus-epub-prepare-summary ()
  "Enable EPUB link rendering for the current summary."
  (setq zr-gnus-epub--reading
        (not (assq 'mm-text-html-renderer (gnus-group-find-parameter gnus-newsgroup-name)))))

(add-hook 'gnus-article-decode-hook #'zr-gnus-epub--article-renderer)

(provide 'zr-gnus-epub)
;;; zr-gnus-epub.el ends here
