;;; zr-erc-link.el --- Org link handlers and media previews in ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Enable `erc-zr-link-mode' to turn rule matches into clickable actions.
;; `zr-erc-link-rules' dispatches images, downloads, ERC commands and Org
;; links.  Media previews are opt-in; see README.md for configuration.
;;; Code:
(require 'zr-erc-common)
(require 'button)
(require 'ol)
(require 'auth-source)
(require 'url)
(require 'url-http)
(require 'iso8601)
(defvar url-http-response-status)
(defvar url-http-end-of-headers)
(defvar url-http-after-change-function)

(defgroup zr-erc-link nil "Rule-based link actions in ERC." :group 'erc)
(defcustom zr-erc-link-rules
  '((:regexp "https?://[^[:space:]<>\"\x01]+\\.\\(?:png\\|jpe?g\\|gif\\|webp\\|avif\\)\\(?:[?#][^[:space:]<>\"\x01]*\\)?" :type image)
    (:regexp "https?://[^[:space:]<>\"\x01]+\\.\\(?:pdf\\|zip\\|gz\\|7z\\|tar\\|txt\\|mp4\\|mp3\\)\\(?:[?#][^[:space:]<>\"\x01]*\\)?" :type file)
    (:regexp "\\b\\(?:https?\\|file\\):[^[:space:]<>\"\x01]+" :type org))
  "Ordered rules for clickable message text; nil disables recognition.
Each rule has :regexp and :type (image, file, command or org).
Regexps match displayed message text, case-sensitively.  Every nonempty
match becomes a button; earlier rules win overlapping ranges.
:replace is an optional string using `replace-match' backreferences,
with case preserved.  Without it, the entire match is the target.
:match is a `zr-erc-match-p' selector.  :url-tag reads a tag instead of
message text and appends a button; without :replace its whole value is used.
Image/file targets must be HTTP(S) URLs.  Command targets must be single
slash commands, executed in the clicked buffer by `erc-send-input'.
Org targets are passed to `org-link-open-from-string' when clicked.
Only image rules can run automatically; commands and Org links require a click.
Media keys: :headers is an HTTP header alist; :auth-source is t or an
auth-source search plist; :auth-scheme is basic or bearer; :auth-header
defaults to Authorization.  :auto-show, :ffmpeg, :max-width, :max-height
and :max-age override module options.  :max-age is seconds; nil disables
age checks.  :proxy overrides `zr-erc-link-proxy' (inherit, nil, or an
HTTP proxy).  Redirects are rejected; rewrite to the final URL so custom
credentials cannot be forwarded to another host.
This option supports buffer-local values."
  :type 'sexp :group 'zr-erc-link)
(defcustom zr-erc-link-auto-show nil
  "Whether recognized images are automatically fetched and displayed."
  :type 'boolean :group 'zr-erc-link)
(defcustom zr-erc-link-max-age nil
  "Maximum message age in seconds for starting a media request.
Nil disables the age limit.  A rule's :max-age overrides this option,
including an explicit nil.  Age is measured from the message's IRC
server-time tag (time), or local receipt when the tag is absent or invalid.
Expired links skip automatic previews; manual previews and downloads
report an error without requesting the URL.  Existing previews and
requests already in progress are retained."
  :type '(choice (const :tag "No age limit" nil) (natnum :tag "Seconds"))
  :group 'zr-erc-link)
(defcustom zr-erc-link-proxy 'inherit
  "HTTP proxy for media previews and downloads.
The default, inherit, uses Emacs's existing URL proxy configuration.
Nil forces a direct connection.  A string specifies an HTTP proxy as
host:port or http://host:port, for example http://127.0.0.1:7890.
IPv6 addresses must be bracketed.  Proxy URLs with credentials or paths
are not supported.  HTTPS media uses a CONNECT tunnel through the proxy.
A rule's :proxy overrides this option, including an explicit nil.
Explicit proxies bypass no_proxy exclusions.  Proxy settings apply only
to the media request, without changing other Emacs network requests."
  :type '(choice (const :tag "Use Emacs proxy settings" inherit)
                 (const :tag "Connect directly" nil)
                 (string :tag "HTTP proxy (host:port or http://host:port)"))
  :group 'zr-erc-link)
(defcustom zr-erc-link-use-ffmpeg nil
  "Whether to use FFmpeg to create a scaled, single-frame PNG preview."
  :type 'boolean :group 'zr-erc-link)
(defcustom zr-erc-link-ffmpeg-program "ffmpeg"
  "FFmpeg executable used for previews when enabled."
  :type 'string :group 'zr-erc-link)
(defcustom zr-erc-link-max-width 0.85
  "Maximum preview width: integer pixels or fraction of the current window."
  :type '(choice integer float) :group 'zr-erc-link)
(defcustom zr-erc-link-max-height 0.6
  "Maximum preview height: integer pixels or fraction of the current window."
  :type '(choice integer float) :group 'zr-erc-link)
(defcustom zr-erc-link-timeout 30
  "Maximum seconds allowed for an HTTP request or an FFmpeg conversion."
  :type 'number :group 'zr-erc-link)
(defcustom zr-erc-link-max-bytes (* 64 1024 1024)
  "Maximum response body size accepted for a preview or download."
  :type 'integer :group 'zr-erc-link)
(defcustom zr-erc-link-download-directory "~/Downloads/"
  "Initial directory offered by `zr-erc-link-download'."
  :type 'directory :group 'zr-erc-link)

(cl-defstruct zr-erc-link--job
  buffer anchor item destination overwrite request process timer raw preview overlay
  timeout max-bytes ffmpeg width height done error)
(defvar-local zr-erc-link--jobs nil)
(defvar erc-zr-link-mode)

(defun zr-erc-link--option (rule key fallback)
  "Read KEY from RULE, or use FALLBACK when KEY is absent."
  (if (plist-member rule key) (plist-get rule key) fallback))

(defun zr-erc-link--item (value context &optional only-rule)
  "Describe VALUE using CONTEXT and the first applicable rule.
When ONLY-RULE is non-nil, only consider that rule."
  (save-match-data
    (let ((case-fold-search nil))
      (cl-loop
       for rule in (if only-rule (list only-rule) zr-erc-link-rules)
       when (and (zr-erc-match-p (plist-get rule :match) context)
                 (string-match (or (plist-get rule :regexp) "\\`\\(?:.\\|\n\\)*\\'") value))
       thereis
       (zr-erc-link--make-item
        value (if-let* ((replacement (plist-get rule :replace)))
                  (match-substitute-replacement replacement t nil value)
                value)
        rule context)))))

(defun zr-erc-link--make-item (value target rule context)
  "Build an action from VALUE, expanded TARGET, RULE and CONTEXT."
  (let ((type (plist-get rule :type)))
    (when (and (memq type '(image file command org))
               (not (string-empty-p target))
               (or (not (memq type '(image file)))
                   (string-match-p "\\`https?://" target)))
      (list :target target :original value :rule rule :type type
            :time (or (when-let* ((stamp (cdr (assoc "time" (plist-get context :tags)))))
                        (condition-case nil
                            (encode-time (iso8601-parse stamp t))
                          (error nil)))
                      (current-time))))))

(defun zr-erc-link--expired-p (item)
  "Whether ITEM exceeds the current buffer's or its rule's age limit."
  (when-let* ((max-age (zr-erc-link--option
                       (plist-get item :rule) :max-age zr-erc-link-max-age))
              (time (plist-get item :time)))
    (> (float-time (time-subtract (current-time) time)) max-age)))

(defun zr-erc-link--check-age (item)
  "Signal a user error if ITEM has expired."
  (when (zr-erc-link--expired-p item)
    (user-error "Media link has expired (message exceeds the configured age limit)")))

(defun zr-erc-link--proxy-locator (proxy)
  "Return a URL proxy locator for PROXY, rejecting invalid proxy addresses."
  (pcase proxy
    ('inherit url-proxy-locator)
    ('nil (lambda (_url _host) "DIRECT"))
    (_ (save-match-data
         (let ((case-fold-search t))
           (unless (and (stringp proxy)
                        (string-match
                         (concat "\\`\\(?:http://\\)?"
                                 "\\(\\(?:\\[[[:xdigit:]:.]+\\]\\|[[:alnum:]._-]+\\)\\)"
                                 ":\\([0-9]+\\)/?\\'")
                         proxy)
                        (<= 1 (string-to-number (match-string 2 proxy)) 65535))
             (user-error "Media proxy must be inherit, nil, or an HTTP host:port"))
           (let ((directive (format "PROXY %s:%d" (match-string 1 proxy)
                                    (string-to-number (match-string 2 proxy)))))
             (lambda (_url _host) directive)))))))

(defun zr-erc-link--headers (item)
  "Build request headers for ITEM, resolving secrets only when fetching."
  (let* ((rule (plist-get item :rule))
         (headers (copy-tree (plist-get rule :headers)))
         (auth (plist-get rule :auth-source)))
    (when auth
      (let* ((url (url-generic-parse-url (plist-get item :target)))
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

(defun zr-erc-link--cleanup (job)
  "Cancel JOB and remove its temporary resources, retaining downloaded files."
  (setf (zr-erc-link--job-done job) t)
  (when (timerp (zr-erc-link--job-timer job))
    (cancel-timer (zr-erc-link--job-timer job)))
  (when-let* ((process (zr-erc-link--job-process job)) ((process-live-p process)))
    (delete-process process))
  (when-let* ((buffer (zr-erc-link--job-request job)) ((buffer-live-p buffer)))
    (when-let* ((process (get-buffer-process buffer)) ((process-live-p process)))
      (delete-process process))
    (kill-buffer buffer))
  (when (overlayp (zr-erc-link--job-overlay job))
    (delete-overlay (zr-erc-link--job-overlay job)))
  (dolist (file (list (zr-erc-link--job-raw job) (zr-erc-link--job-preview job)))
    (when (and file (file-exists-p file)) (delete-file file)))
  (when (markerp (zr-erc-link--job-anchor job))
    (set-marker (zr-erc-link--job-anchor job) nil))
  (when (buffer-live-p (zr-erc-link--job-buffer job))
    (with-current-buffer (zr-erc-link--job-buffer job)
      (setq zr-erc-link--jobs (delq job zr-erc-link--jobs)))))

(defun zr-erc-link--fail (job reason)
  "Stop JOB with a concise REASON, without exposing its URL or credentials."
  (unless (zr-erc-link--job-done job)
    (setf (zr-erc-link--job-error job) reason)
    (zr-erc-link--cleanup job)
    (message "ERC media: %s" reason)))

(defun zr-erc-link--cleanup-buffer ()
  "Cancel requests and remove previews owned by the current buffer."
  (mapc #'zr-erc-link--cleanup (copy-sequence zr-erc-link--jobs))
  (setq zr-erc-link--jobs nil)
  (remove-hook 'after-change-functions #'zr-erc-link--prune t)
  (remove-hook 'kill-buffer-hook #'zr-erc-link--cleanup-buffer t))

(defun zr-erc-link--prune (&rest _)
  "Discard previews whose source link was removed from the scrollback."
  (save-restriction
    (widen)
    (dolist (job (copy-sequence zr-erc-link--jobs))
      (unless (zr-erc-link--job-destination job)
        (let ((position (marker-position (zr-erc-link--job-anchor job))))
          (unless (and position (> position (point-min))
                       (eq (get-text-property (1- position) 'zr-erc-link-item)
                           (zr-erc-link--job-item job)))
            (zr-erc-link--cleanup job)))))))

(defun zr-erc-link--show (job file)
  "Render FILE as JOB's inline preview."
  (when (and (buffer-live-p (zr-erc-link--job-buffer job))
             (marker-position (zr-erc-link--job-anchor job)))
    (with-current-buffer (zr-erc-link--job-buffer job)
      (let* ((image (or (create-image file nil nil
                                  :max-width (zr-erc-link--job-width job)
                                  :max-height (zr-erc-link--job-height job))
                        (error "Unsupported image")))
             (overlay (make-overlay (zr-erc-link--job-anchor job)
                                     (zr-erc-link--job-anchor job))))
        (overlay-put overlay 'after-string
                     (concat "\n" (propertize " " 'display image) "\n"))
        (setf (zr-erc-link--job-overlay job) overlay
              (zr-erc-link--job-done job) t)))))

(defun zr-erc-link--converted (process _event)
  "Finish a preview conversion by PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let ((job (process-get process 'zr-erc-link-job)))
      (when (and job (not (zr-erc-link--job-done job)))
        (cancel-timer (zr-erc-link--job-timer job))
        (if (zerop (process-exit-status process))
            (condition-case nil
                (zr-erc-link--show job (zr-erc-link--job-preview job))
              (error (zr-erc-link--fail job "Cannot display the converted image")))
          (zr-erc-link--fail job "FFmpeg could not decode this image"))))))

(defun zr-erc-link--ffmpeg-command (job)
  "Return FFmpeg argv for JOB, fitting its current window without upscaling."
  (list (zr-erc-link--job-ffmpeg job) "-nostdin" "-v" "error" "-y"
        "-protocol_whitelist" "file,pipe" "-i" (zr-erc-link--job-raw job)
        "-vf" (format "scale=w='min(iw,%d)':h='min(ih,%d)':force_original_aspect_ratio=decrease"
                       (zr-erc-link--job-width job) (zr-erc-link--job-height job))
        "-frames:v" "1" (zr-erc-link--job-preview job)))

(defun zr-erc-link--received (status job)
  "Handle URL response STATUS for JOB in the HTTP response buffer."
  (let ((response (current-buffer)))
    (unwind-protect
        (unless (zr-erc-link--job-done job)
          (cancel-timer (zr-erc-link--job-timer job))
          (condition-case nil
              (progn
                (when (or (plist-get status :error)
                          ;; A failed TLS handshake can leave CONNECT's 200
                          ;; response behind.  It is not a media response.
                          (eq url-http-after-change-function
                              #'url-https-proxy-after-change-function)
                          (not (and (integerp url-http-response-status)
                                    (<= 200 url-http-response-status 299))))
                  (error "HTTP failure"))
                (unless (and url-http-end-of-headers
                             (<= (- (point-max) (1+ url-http-end-of-headers))
                                 (zr-erc-link--job-max-bytes job)))
                  (error "Invalid or oversized response"))
                (let ((coding-system-for-write 'no-conversion))
                  (write-region (1+ url-http-end-of-headers) (point-max)
                                (zr-erc-link--job-raw job) nil 'silent))
                (cond
                 ((zr-erc-link--job-destination job)
                  (copy-file (zr-erc-link--job-raw job) (zr-erc-link--job-destination job)
                             (zr-erc-link--job-overwrite job))
                  (zr-erc-link--cleanup job)
                  (message "ERC media: download saved"))
                 ((zr-erc-link--job-ffmpeg job)
                  (setf (zr-erc-link--job-preview job) (make-temp-file "erc-preview-" nil ".png")
                        (zr-erc-link--job-timer job)
                        (run-at-time (zr-erc-link--job-timeout job) nil
                                     #'zr-erc-link--fail job "FFmpeg timed out"))
                  (let ((process (make-process
                                  :name "erc-media-ffmpeg" :buffer nil :noquery t
                                  :command (zr-erc-link--ffmpeg-command job)
                                  :sentinel #'zr-erc-link--converted)))
                    (process-put process 'zr-erc-link-job job)
                    (setf (zr-erc-link--job-process job) process)))
                 (t (zr-erc-link--show job (zr-erc-link--job-raw job)))))
            (error (zr-erc-link--fail job "Request failed, response too large, or unsupported image"))))
      (when (buffer-live-p response) (kill-buffer response)))))

(defun zr-erc-link--dimension (value pixels)
  "Convert configured VALUE and available PIXELS to a positive dimension."
  (max 1 (floor (if (floatp value) (* value pixels) value))))

(defun zr-erc-link--fetch (item anchor &optional destination overwrite)
  "Fetch ITEM at ANCHOR, optionally to DESTINATION with OVERWRITE permission."
  (zr-erc-link--check-age item)
  (let* ((rule (plist-get item :rule))
         (locator (zr-erc-link--proxy-locator
                   (zr-erc-link--option rule :proxy zr-erc-link-proxy)))
         ;; URL's connection cache is keyed by destination, not proxy.
         (connections (make-hash-table :test #'equal))
         (window (or (get-buffer-window (current-buffer) t) (selected-window)))
         (headers (zr-erc-link--headers item))
         (ffmpeg (and (not destination)
                       (zr-erc-link--option rule :ffmpeg zr-erc-link-use-ffmpeg)
                       zr-erc-link-ffmpeg-program))
         (job (make-zr-erc-link--job
               :buffer (current-buffer) :anchor (copy-marker anchor) :item item
               :destination destination :overwrite overwrite :ffmpeg ffmpeg
               :width (zr-erc-link--dimension
                       (zr-erc-link--option rule :max-width zr-erc-link-max-width)
                       (window-body-width window t))
               :height (zr-erc-link--dimension
                        (zr-erc-link--option rule :max-height zr-erc-link-max-height)
                        (window-body-height window t))
               :timeout zr-erc-link-timeout :max-bytes zr-erc-link-max-bytes)))
    (when (and ffmpeg (not (executable-find ffmpeg)))
      (user-error "FFmpeg executable is unavailable"))
    (setf (zr-erc-link--job-raw job) (make-temp-file "erc-media-"))
    (push job zr-erc-link--jobs)
    (add-hook 'kill-buffer-hook #'zr-erc-link--cleanup-buffer nil t)
    (add-hook 'after-change-functions #'zr-erc-link--prune nil t)
    (condition-case nil
        (let ((url-request-extra-headers headers)
              (url-request-noninteractive t)
              (url-proxy-locator locator)
              (url-proxy-services (copy-tree url-proxy-services))
              (url-http-open-connections connections)
              (url-http-attempt-keepalives nil)
              (url-max-redirections 0))
          (setf (zr-erc-link--job-timer job)
                (run-at-time zr-erc-link-timeout nil #'zr-erc-link--fail job "Request timed out")
                (zr-erc-link--job-request job)
                (url-retrieve (plist-get item :target) #'zr-erc-link--received (list job) t t))
          (unless (zr-erc-link--job-request job) (error "No request"))
          ;; Preserve routing for asynchronous connection retries as well.
          (let ((services url-proxy-services))
            (with-current-buffer (zr-erc-link--job-request job)
              (setq-local url-max-redirections 0
                          url-proxy-locator locator
                          url-proxy-services services
                          url-http-open-connections connections
                          url-http-attempt-keepalives nil))))
      (error (zr-erc-link--fail job "Could not start the request")))
    job))

(defun zr-erc-link--button-item ()
  "Return the media button at point, or signal a user error."
  (let ((button (button-at (point))))
    (unless (and button (memq (plist-get (button-get button 'zr-erc-link-item) :type)
                                     '(image file)))
      (user-error "No media link at point"))
    button))

(defun zr-erc-link--show-button (button)
  "Fetch and show the image at BUTTON, replacing its existing preview."
  (let ((item (button-get button 'zr-erc-link-item)))
    (unless (eq (plist-get item :type) 'image) (user-error "This link is not an image"))
    (zr-erc-link--check-age item)
    (when-let* ((old (button-get button 'zr-erc-link-job))) (zr-erc-link--cleanup old))
    (let ((job (zr-erc-link--fetch item (button-end button)))
          (inhibit-read-only t))
      (button-put button 'zr-erc-link-job job))))

(defun zr-erc-link--hide-button (button)
  "Hide BUTTON's preview and cancel any pending image request."
  (when-let* ((job (button-get button 'zr-erc-link-job)))
    (zr-erc-link--cleanup job)
    (let ((inhibit-read-only t))
      (button-put button 'zr-erc-link-job nil))))

(defun zr-erc-link--image-buttons (beg end)
  "Return image buttons overlapping BEG through END, in buffer order."
  (let ((button (and (< beg end) (next-button beg t))) buttons)
    (while (and button (< (button-start button) end))
      (when (eq (plist-get (button-get button 'zr-erc-link-item) :type) 'image)
        (push button buttons))
      (setq button (next-button (button-end button) t)))
    (nreverse buttons)))

;;;###autoload
(defun zr-erc-link-show (&optional beg end)
  "Toggle inline images, fitting the current window when showing them.
Interactively, toggle the image at point, or images overlapping the active
region.  With a prefix argument, use the selected window's visible range
instead, even when the region is active.
From Lisp, toggle the image at point, or images overlapping BEG through END
when both bounds are supplied.  The end boundary is exclusive.
If any targeted image is displayed or loading, hide all targeted previews
and cancel their pending requests; otherwise, fetch and show them.
This also hides automatic previews, even after their links have expired.
For a range, skip file links and report errors without stopping the other
previews.  This command works regardless of `zr-erc-link-auto-show'."
  (interactive
   (cond (current-prefix-arg (list (window-start) (window-end nil t)))
         ((use-region-p) (list (region-beginning) (region-end)))))
  (let* ((range (and beg end))
         (buttons (if range (zr-erc-link--image-buttons beg end)
                    (list (zr-erc-link--button-item))))
         ;; Completed previews remain in `zr-erc-link--jobs'; failed or
         ;; canceled jobs are removed, even if a button still refers to them.
         (hide (cl-some (lambda (button)
                          (memq (button-get button 'zr-erc-link-job)
                                zr-erc-link--jobs))
                        buttons)))
    (unless buttons (user-error "No image links in the selected range"))
    (unless (or hide (display-images-p))
      (user-error "This display cannot show images; use zr-erc-link-download"))
    (dolist (button buttons)
      (cond (hide (zr-erc-link--hide-button button))
            (range
             (condition-case err (zr-erc-link--show-button button)
               (error (message "ERC media: %s" (error-message-string err)))))
            (t (zr-erc-link--show-button button))))))

;;;###autoload
(defun zr-erc-link-download (destination &optional overwrite)
  "Download the media link at point to DESTINATION.
Existing files require explicit OVERWRITE permission."
  (interactive
   (let* ((button (zr-erc-link--button-item))
          (item (button-get button 'zr-erc-link-item))
          (name (file-name-nondirectory
                 (car (split-string (url-filename (url-generic-parse-url (plist-get item :target))) "?"))))
          (file (progn
                  (zr-erc-link--check-age item)
                  (read-file-name "Download to: " zr-erc-link-download-directory nil nil name)))
          (exists (file-exists-p file)))
     (when (and exists (not (yes-or-no-p "Overwrite the existing file? "))) (user-error "Canceled"))
     (list file exists)))
  (let* ((button (zr-erc-link--button-item))
         (item (button-get button 'zr-erc-link-item)))
    (zr-erc-link--check-age item)
    (when (and (file-exists-p destination) (not overwrite)) (user-error "Destination already exists"))
    (make-directory (file-name-directory (expand-file-name destination)) t)
    (zr-erc-link--fetch item (button-end button) (expand-file-name destination) overwrite)))

(defun zr-erc-link--activate (button)
  "Dispatch BUTTON's rule action in its ERC buffer."
  (with-current-buffer (if (markerp button) (marker-buffer button) (current-buffer))
    (goto-char (button-start button))
    (let* ((item (button-get button 'zr-erc-link-item))
           (target (plist-get item :target)))
      (pcase (plist-get item :type)
        ('image (zr-erc-link--toggle-at-point))
        ('file (call-interactively #'zr-erc-link-download))
        ('command
         (unless (and (string-match-p "\\`/[[:alpha:]][[:alnum:]-]*\\(?:[ \t]\\|\\'\\)" target)
                      (not (string-match-p "[\r\n\x00]" target)))
           (user-error "Link target must be a single ERC slash command"))
         (let ((inhibit-read-only t)) (erc-send-input target)))
        ('org (org-link-open-from-string target current-prefix-arg))
        (_ (user-error "Unknown link action"))))))

(defun zr-erc-link--toggle-at-point ()
  "Toggle only the clicked image, ignoring the active region."
  (let ((button (zr-erc-link--button-item)))
    (if (memq (button-get button 'zr-erc-link-job) zr-erc-link--jobs)
        (zr-erc-link--hide-button button)
      (unless (display-images-p) (user-error "This display cannot show images"))
      (zr-erc-link--show-button button))))

(defun zr-erc-link--buttonize (start end item)
  "Turn START to END into a button for ITEM."
  (remove-text-properties start end '(keymap nil erc-callback nil erc-data nil))
  (make-text-button start end 'action #'zr-erc-link--activate
                    'keymap button-map 'follow-link t 'zr-erc-link-item item
                    'help-echo (pcase (plist-get item :type)
                                 ('image "RET: toggle image")
                                 ('file "RET: download file")
                                 ('command "RET: execute ERC command")
                                 ('org "RET: open Org link")))
  (when (and (eq (plist-get item :type) 'image) (display-images-p)
             (not (zr-erc-link--expired-p item))
             (zr-erc-link--option (plist-get item :rule) :auto-show zr-erc-link-auto-show))
    (save-excursion
      (goto-char start)
      (condition-case nil (zr-erc-link--toggle-at-point)
        (error (message "ERC link: automatic preview could not start"))))))

(defun zr-erc-link--insert ()
  "Apply link rules to the narrowed incoming ERC message."
  (when (and (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed) '("PRIVMSG" "NOTICE")))
    (let ((context (zr-erc-context erc-message-parsed))
          (text (buffer-substring-no-properties (point-min) (point-max)))
          (base (point-min))
          (case-fold-search nil)
          ranges seen tagged)
      (save-excursion
        (dolist (rule zr-erc-link-rules)
          (when (zr-erc-match-p (plist-get rule :match) context)
            (if-let* ((tag (plist-get rule :url-tag)))
                (when-let* ((value (cdr (assoc tag (plist-get context :tags))))
                            (item (zr-erc-link--item value context rule)))
                  (push item tagged))
              (when-let* ((regexp (plist-get rule :regexp)))
                (let ((offset 0))
                  (while (and (<= offset (length text)) (string-match regexp text offset))
                    (let* ((beg (match-beginning 0))
                           (end (match-end 0))
                           (value (match-string 0 text))
                           ;; Expand against the original source so anchors and
                           ;; capture groups keep their matching semantics.
                           (target (if-let* ((replacement (plist-get rule :replace)))
                                       (match-substitute-replacement replacement t nil text)
                                     value)))
                      (setq offset (if (= beg end) (1+ end) end))
                      (unless (or (= beg end)
                                  (cl-some (lambda (range)
                                             (and (< beg (cdr range)) (< (car range) end)))
                                           ranges))
                        (when-let* ((item (zr-erc-link--make-item
                                          value target rule context)))
                          (push (cons beg end) ranges)
                          (push (plist-get item :target) seen)
                          (zr-erc-link--buttonize (+ base beg) (+ base end) item))))))))))
        ;; Append tags after scanning text, keeping original offsets stable
        ;; and avoiding duplicate targets already present in the message.
        (dolist (item (nreverse tagged))
          (unless (member (plist-get item :target) seen)
            (push (plist-get item :target) seen)
            (goto-char (point-max))
            (when (eq (char-before) ?\n) (backward-char))
            (insert " ")
            (let ((start (point)))
              (insert (format "[%s]" (plist-get item :type)))
              (zr-erc-link--buttonize start (point) item))))))))

;;;###autoload (autoload 'erc-zr-link-mode "zr-erc-link" nil t)
(define-erc-module zr-link nil
  "Turn message rule matches into media, ERC command and Org link buttons."
  ((add-hook 'erc-insert-post-hook #'zr-erc-link--insert 95))
  ((remove-hook 'erc-insert-post-hook #'zr-erc-link--insert)
   (erc-buffer-list #'zr-erc-link--cleanup-buffer)))

(provide 'zr-erc-link)
;;; zr-erc-link.el ends here
