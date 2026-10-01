;;; zr-erc-media.el --- Image previews and file downloads in ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Enable `erc-zr-media-mode'.  Recognized URLs become buttons: images can
;; be previewed inline, files downloaded.  `zr-erc-media-download' downloads
;; either type.  Automatic previews are opt-in.  Options are buffer-local;
;; see README.md for URL rewriting, request headers, auth-source and FFmpeg.
;;; Code:
(require 'zr-erc-common)
(require 'button)
(require 'auth-source)
(require 'url)
(require 'url-http)
(defvar url-http-response-status)
(defvar url-http-end-of-headers)

(defgroup zr-erc-media nil "Images and files in ERC." :group 'erc)
(defcustom zr-erc-media-rules
  '((:regexp "\\.\\(?:png\\|jpe?g\\|gif\\|webp\\|avif\\)\\(?:[?#].*\\)?\\'" :type image)
    (:regexp "\\.\\(?:pdf\\|zip\\|gz\\|7z\\|tar\\|txt\\|mp4\\|mp3\\)\\(?:[?#].*\\)?\\'" :type file))
  "Ordered rules for recognizing media URLs.
Each plist has :regexp and :type (image or file).  Optional keys:
:match is a `zr-erc-match-p' selector; :replace rewrites the matching URL
with Emacs regexp backreferences; :headers is an HTTP header alist;
:auth-source is t or an auth-source search plist; :auth-scheme is basic
or bearer; :auth-header defaults to Authorization.  :auto-show, :ffmpeg,
:max-width and :max-height override the corresponding module options.
:url-tag names a message tag whose value supplies an additional URL.
Regexp matching of URLs is case-sensitive; use explicit alternatives as
needed.  Only HTTP(S) URLs can be fetched.  Redirects are rejected: rewrite
to the final URL so custom credentials cannot be forwarded to another host."
  :type 'sexp :group 'zr-erc-media)
(defcustom zr-erc-media-auto-show nil
  "Whether recognized images are automatically fetched and displayed."
  :type 'boolean :group 'zr-erc-media)
(defcustom zr-erc-media-use-ffmpeg nil
  "Whether to use FFmpeg to create a scaled, single-frame PNG preview."
  :type 'boolean :group 'zr-erc-media)
(defcustom zr-erc-media-ffmpeg-program "ffmpeg"
  "FFmpeg executable used for previews when enabled."
  :type 'string :group 'zr-erc-media)
(defcustom zr-erc-media-max-width 0.85
  "Maximum preview width: integer pixels or fraction of the current window."
  :type '(choice integer float) :group 'zr-erc-media)
(defcustom zr-erc-media-max-height 0.6
  "Maximum preview height: integer pixels or fraction of the current window."
  :type '(choice integer float) :group 'zr-erc-media)
(defcustom zr-erc-media-timeout 30
  "Maximum seconds allowed for an HTTP request or an FFmpeg conversion."
  :type 'number :group 'zr-erc-media)
(defcustom zr-erc-media-max-bytes (* 64 1024 1024)
  "Maximum response body size accepted for a preview or download."
  :type 'integer :group 'zr-erc-media)
(defcustom zr-erc-media-download-directory "~/Downloads/"
  "Initial directory offered by `zr-erc-media-download'."
  :type 'directory :group 'zr-erc-media)

(cl-defstruct zr-erc-media--job
  buffer anchor item destination overwrite request process timer raw preview overlay
  timeout max-bytes ffmpeg width height done error)
(defvar-local zr-erc-media--jobs nil)
(defvar erc-zr-media-mode)

(defun zr-erc-media--option (rule key fallback)
  "Read KEY from RULE, or use FALLBACK when KEY is absent."
  (if (plist-member rule key) (plist-get rule key) fallback))

(defun zr-erc-media--item (url context &optional only-rule)
  "Describe URL according to CONTEXT and the first matching rule.
When ONLY-RULE is non-nil, only consider that rule."
  (let ((case-fold-search nil))
    (when-let* ((rule (cl-find-if
                      (lambda (rule)
                        (and (zr-erc-match-p (plist-get rule :match) context)
                             (string-match-p (or (plist-get rule :regexp) ".") url)))
                      (if only-rule (list only-rule) zr-erc-media-rules))))
      (let ((rewritten (if-let* ((replacement (plist-get rule :replace)))
                           (replace-regexp-in-string (plist-get rule :regexp)
                                                     replacement url t nil) url)))
        (when (string-match-p "\\`https?://" rewritten)
          (list :url rewritten :original url :rule rule
                :type (or (plist-get rule :type) 'file)))))))

(defun zr-erc-media--headers (item)
  "Build request headers for ITEM, resolving secrets only when fetching."
  (let* ((rule (plist-get item :rule))
         (headers (copy-tree (plist-get rule :headers)))
         (auth (plist-get rule :auth-source)))
    (when auth
      (let* ((url (url-generic-parse-url (plist-get item :url)))
             (query (if (listp auth) (copy-sequence auth) nil))
             (query (append query
                            (unless (plist-member query :host) (list :host (url-host url)))
                            (unless (plist-member query :port)
                              (list :port (number-to-string (url-port url))))
                            '(:max 1 :require (:secret) :create nil)))
             (entry (car (apply #'auth-source-search query)))
             (secret (plist-get entry :secret)))
        (unless entry (user-error "No auth-source entry for this media rule"))
        (when (functionp secret) (setq secret (funcall secret)))
        (unless (stringp secret) (user-error "Media credential has no secret"))
        (setf (alist-get (or (plist-get rule :auth-header) "Authorization")
                         headers nil nil #'string-equal)
              (if (eq (plist-get rule :auth-scheme) 'bearer)
                  (concat "Bearer " secret)
                (concat "Basic " (base64-encode-string
                                   (encode-coding-string
                                    (concat (or (plist-get entry :user) "") ":" secret)
                                    'utf-8) t))))))
    (dolist (header headers)
      (when (or (string-match-p "[\r\n]" (car header))
                (string-match-p "[\r\n]" (cdr header)))
        (user-error "Invalid media request header")))
    headers))

(defun zr-erc-media--cleanup (job)
  "Cancel JOB and remove its temporary resources, retaining downloaded files."
  (setf (zr-erc-media--job-done job) t)
  (when (timerp (zr-erc-media--job-timer job))
    (cancel-timer (zr-erc-media--job-timer job)))
  (when-let* ((process (zr-erc-media--job-process job)) ((process-live-p process)))
    (delete-process process))
  (when-let* ((buffer (zr-erc-media--job-request job)) ((buffer-live-p buffer)))
    (when-let* ((process (get-buffer-process buffer)) ((process-live-p process)))
      (delete-process process))
    (kill-buffer buffer))
  (when (overlayp (zr-erc-media--job-overlay job))
    (delete-overlay (zr-erc-media--job-overlay job)))
  (dolist (file (list (zr-erc-media--job-raw job) (zr-erc-media--job-preview job)))
    (when (and file (file-exists-p file)) (delete-file file)))
  (when (markerp (zr-erc-media--job-anchor job))
    (set-marker (zr-erc-media--job-anchor job) nil))
  (when (buffer-live-p (zr-erc-media--job-buffer job))
    (with-current-buffer (zr-erc-media--job-buffer job)
      (setq zr-erc-media--jobs (delq job zr-erc-media--jobs)))))

(defun zr-erc-media--fail (job reason)
  "Stop JOB with a concise REASON, without exposing its URL or credentials."
  (unless (zr-erc-media--job-done job)
    (setf (zr-erc-media--job-error job) reason)
    (zr-erc-media--cleanup job)
    (message "ERC media: %s" reason)))

(defun zr-erc-media--cleanup-buffer ()
  "Cancel requests and remove previews owned by the current buffer."
  (mapc #'zr-erc-media--cleanup (copy-sequence zr-erc-media--jobs))
  (setq zr-erc-media--jobs nil)
  (remove-hook 'after-change-functions #'zr-erc-media--prune t)
  (remove-hook 'kill-buffer-hook #'zr-erc-media--cleanup-buffer t))

(defun zr-erc-media--prune (&rest _)
  "Discard previews whose source link was removed from the scrollback."
  (save-restriction
    (widen)
    (dolist (job (copy-sequence zr-erc-media--jobs))
      (unless (zr-erc-media--job-destination job)
        (let ((position (marker-position (zr-erc-media--job-anchor job))))
          (unless (and position (> position (point-min))
                       (eq (get-text-property (1- position) 'zr-erc-media-item)
                           (zr-erc-media--job-item job)))
            (zr-erc-media--cleanup job)))))))

(defun zr-erc-media--show (job file)
  "Render FILE as JOB's inline preview."
  (when (and (buffer-live-p (zr-erc-media--job-buffer job))
             (marker-position (zr-erc-media--job-anchor job)))
    (with-current-buffer (zr-erc-media--job-buffer job)
      (let* ((image (or (create-image file nil nil
                                  :max-width (zr-erc-media--job-width job)
                                  :max-height (zr-erc-media--job-height job))
                        (error "Unsupported image")))
             (overlay (make-overlay (zr-erc-media--job-anchor job)
                                     (zr-erc-media--job-anchor job))))
        (overlay-put overlay 'after-string
                     (concat "\n" (propertize " " 'display image) "\n"))
        (setf (zr-erc-media--job-overlay job) overlay
              (zr-erc-media--job-done job) t)))))

(defun zr-erc-media--converted (process _event)
  "Finish a preview conversion by PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let ((job (process-get process 'zr-erc-media-job)))
      (when (and job (not (zr-erc-media--job-done job)))
        (cancel-timer (zr-erc-media--job-timer job))
        (if (zerop (process-exit-status process))
            (condition-case nil
                (zr-erc-media--show job (zr-erc-media--job-preview job))
              (error (zr-erc-media--fail job "Cannot display the converted image")))
          (zr-erc-media--fail job "FFmpeg could not decode this image"))))))

(defun zr-erc-media--ffmpeg-command (job)
  "Return FFmpeg argv for JOB, fitting its current window without upscaling."
  (list (zr-erc-media--job-ffmpeg job) "-nostdin" "-v" "error" "-y"
        "-protocol_whitelist" "file,pipe" "-i" (zr-erc-media--job-raw job)
        "-vf" (format "scale=w='min(iw,%d)':h='min(ih,%d)':force_original_aspect_ratio=decrease"
                       (zr-erc-media--job-width job) (zr-erc-media--job-height job))
        "-frames:v" "1" (zr-erc-media--job-preview job)))

(defun zr-erc-media--received (status job)
  "Handle URL response STATUS for JOB in the HTTP response buffer."
  (let ((response (current-buffer)))
    (unwind-protect
        (unless (zr-erc-media--job-done job)
          (cancel-timer (zr-erc-media--job-timer job))
          (condition-case nil
              (progn
                (when (or (plist-get status :error)
                          (not (and (integerp url-http-response-status)
                                    (<= 200 url-http-response-status 299))))
                  (error "HTTP failure"))
                (unless (and url-http-end-of-headers
                             (<= (- (point-max) (1+ url-http-end-of-headers))
                                 (zr-erc-media--job-max-bytes job)))
                  (error "Invalid or oversized response"))
                (let ((coding-system-for-write 'no-conversion))
                  (write-region (1+ url-http-end-of-headers) (point-max)
                                (zr-erc-media--job-raw job) nil 'silent))
                (cond
                 ((zr-erc-media--job-destination job)
                  (copy-file (zr-erc-media--job-raw job) (zr-erc-media--job-destination job)
                             (zr-erc-media--job-overwrite job))
                  (zr-erc-media--cleanup job)
                  (message "ERC media: download saved"))
                 ((zr-erc-media--job-ffmpeg job)
                  (setf (zr-erc-media--job-preview job) (make-temp-file "erc-preview-" nil ".png")
                        (zr-erc-media--job-timer job)
                        (run-at-time (zr-erc-media--job-timeout job) nil
                                     #'zr-erc-media--fail job "FFmpeg timed out"))
                  (let ((process (make-process
                                  :name "erc-media-ffmpeg" :buffer nil :noquery t
                                  :command (zr-erc-media--ffmpeg-command job)
                                  :sentinel #'zr-erc-media--converted)))
                    (process-put process 'zr-erc-media-job job)
                    (setf (zr-erc-media--job-process job) process)))
                 (t (zr-erc-media--show job (zr-erc-media--job-raw job)))))
            (error (zr-erc-media--fail job "Request failed, response too large, or unsupported image"))))
      (when (buffer-live-p response) (kill-buffer response)))))

(defun zr-erc-media--dimension (value pixels)
  "Convert configured VALUE and available PIXELS to a positive dimension."
  (max 1 (floor (if (floatp value) (* value pixels) value))))

(defun zr-erc-media--fetch (item anchor &optional destination overwrite)
  "Fetch ITEM at ANCHOR, optionally to DESTINATION with OVERWRITE permission."
  (let* ((rule (plist-get item :rule))
         (window (or (get-buffer-window (current-buffer) t) (selected-window)))
         (headers (zr-erc-media--headers item))
         (ffmpeg (and (not destination)
                       (zr-erc-media--option rule :ffmpeg zr-erc-media-use-ffmpeg)
                       zr-erc-media-ffmpeg-program))
         (job (make-zr-erc-media--job
               :buffer (current-buffer) :anchor (copy-marker anchor) :item item
               :destination destination :overwrite overwrite :ffmpeg ffmpeg
               :width (zr-erc-media--dimension
                       (zr-erc-media--option rule :max-width zr-erc-media-max-width)
                       (window-body-width window t))
               :height (zr-erc-media--dimension
                        (zr-erc-media--option rule :max-height zr-erc-media-max-height)
                        (window-body-height window t))
               :timeout zr-erc-media-timeout :max-bytes zr-erc-media-max-bytes)))
    (when (and ffmpeg (not (executable-find ffmpeg)))
      (user-error "FFmpeg executable is unavailable"))
    (setf (zr-erc-media--job-raw job) (make-temp-file "erc-media-"))
    (push job zr-erc-media--jobs)
    (add-hook 'kill-buffer-hook #'zr-erc-media--cleanup-buffer nil t)
    (add-hook 'after-change-functions #'zr-erc-media--prune nil t)
    (condition-case nil
        (let ((url-request-extra-headers headers)
              (url-request-noninteractive t)
              (url-max-redirections 0))
          (setf (zr-erc-media--job-timer job)
                (run-at-time zr-erc-media-timeout nil #'zr-erc-media--fail job "Request timed out")
                (zr-erc-media--job-request job)
                (url-retrieve (plist-get item :url) #'zr-erc-media--received (list job) t t))
          (unless (zr-erc-media--job-request job) (error "No request"))
          (with-current-buffer (zr-erc-media--job-request job)
            (setq-local url-max-redirections 0)))
      (error (zr-erc-media--fail job "Could not start the request")))
    job))

(defun zr-erc-media--button-item ()
  "Return the media button at point, or signal a user error."
  (let ((button (button-at (point))))
    (unless (and button (button-get button 'zr-erc-media-item))
      (user-error "No media link at point"))
    button))

;;;###autoload
(defun zr-erc-media-show ()
  "Fetch and show the image at point, fitting the current window."
  (interactive)
  (unless (display-images-p) (user-error "This display cannot show images; use zr-erc-media-download"))
  (let* ((button (zr-erc-media--button-item))
         (item (button-get button 'zr-erc-media-item)))
    (unless (eq (plist-get item :type) 'image) (user-error "This link is a file"))
    (when-let* ((old (button-get button 'zr-erc-media-job))) (zr-erc-media--cleanup old))
    (button-put button 'zr-erc-media-job (zr-erc-media--fetch item (button-end button)))))

;;;###autoload
(defun zr-erc-media-download (destination &optional overwrite)
  "Download the media link at point to DESTINATION.
Existing files require explicit OVERWRITE permission."
  (interactive
   (let* ((button (zr-erc-media--button-item))
          (item (button-get button 'zr-erc-media-item))
          (name (file-name-nondirectory
                 (car (split-string (url-filename (url-generic-parse-url (plist-get item :url))) "?"))))
          (file (read-file-name "Download to: " zr-erc-media-download-directory nil nil name))
          (exists (file-exists-p file)))
     (when (and exists (not (yes-or-no-p "Overwrite the existing file? "))) (user-error "Canceled"))
     (list file exists)))
  (let* ((button (zr-erc-media--button-item))
         (item (button-get button 'zr-erc-media-item)))
    (when (and (file-exists-p destination) (not overwrite)) (user-error "Destination already exists"))
    (make-directory (file-name-directory (expand-file-name destination)) t)
    (zr-erc-media--fetch item (button-end button) (expand-file-name destination) overwrite)))

(defun zr-erc-media--activate (button)
  "Activate media BUTTON."
  (goto-char (button-start button))
  (if (eq (plist-get (button-get button 'zr-erc-media-item) :type) 'image)
      (zr-erc-media-show)
    (call-interactively #'zr-erc-media-download)))

(defun zr-erc-media--buttonize (start end item)
  "Turn START to END into an ITEM button."
  (remove-text-properties start end '(keymap nil erc-callback nil erc-data nil))
  (make-text-button start end 'action #'zr-erc-media--activate
                    'keymap button-map 'follow-link t 'zr-erc-media-item item
                    'help-echo "RET: preview image / download file; M-x zr-erc-media-download: save")
  (when (and (eq (plist-get item :type) 'image) (display-images-p)
             (zr-erc-media--option (plist-get item :rule) :auto-show zr-erc-media-auto-show))
    (save-excursion
      (goto-char start)
      (condition-case nil (zr-erc-media-show)
        (error (message "ERC media: automatic preview could not start"))))))

(defun zr-erc-media--insert ()
  "Recognize media in the narrowed incoming message after ERC formatting."
  (when (and (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed) '("PRIVMSG" "NOTICE")))
    (let ((context (zr-erc-context erc-message-parsed)) seen)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "https?://[^[:space:]<>\"\x01]+" nil t)
          (let ((start (match-beginning 0)) (end (match-end 0)) (url (match-string-no-properties 0)))
            (unless (button-at start)
              (when-let* ((item (zr-erc-media--item url context)))
                (push url seen)
                (zr-erc-media--buttonize start end item)))))
        (dolist (rule zr-erc-media-rules)
          (when-let* ((tag (plist-get rule :url-tag))
                      (url (cdr (assoc tag (plist-get context :tags))))
                      ((not (member url seen)))
                      (item (zr-erc-media--item url context rule)))
            (goto-char (point-max))
            (when (eq (char-before) ?\n) (backward-char))
            (insert " ")
            (let ((start (point)))
              (insert (format "[%s]" (plist-get item :type)))
              (zr-erc-media--buttonize start (point) item))))))))

;;;###autoload (autoload 'erc-zr-media-mode "zr-erc-media" nil t)
(define-erc-module zr-media nil
  "Recognize media links, preview images and download files."
  ((add-hook 'erc-insert-post-hook #'zr-erc-media--insert 95))
  ((remove-hook 'erc-insert-post-hook #'zr-erc-media--insert)
   (erc-buffer-list #'zr-erc-media--cleanup-buffer)))

(provide 'zr-erc-media)
;;; zr-erc-media.el ends here
