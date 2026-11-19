;;; zr-erc-link.el --- Link actions and file buffers in ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;;; Commentary:
;; Enable `erc-zr-link-mode' to turn rule matches into clickable actions.
;; `zr-erc-link-rules' dispatches files, ERC commands and Org
;; links.  Files open in separate buffers; see README.md for configuration.
;;; Code:
(require 'zr-erc-common)
(require 'button)
(require 'ol)
(require 'auth-source)
(require 'url-parse)
(require 'zr-http)
(require 'iso8601)
(require 'image)

(defgroup zr-erc-link nil "Rule-based link actions in ERC." :group 'erc)
(defcustom zr-erc-link-rules
  '((:regexp "https?://[^[:space:]<>\"\x01]+\\.\\(?:png\\|jpe?g\\|gif\\|webp\\|avif\\|pdf\\|zip\\|gz\\|7z\\|tar\\|txt\\|mp4\\|mp3\\)\\(?:[?#][^[:space:]<>\"\x01]*\\)?" :type file)
    (:regexp "\\b\\(?:https?\\|file\\):[^[:space:]<>\"\x01]+" :type org))
  "Ordered rules for clickable message text; nil disables recognition.
Each rule has :type (file, command or org).  A rule without :regexp
or :url-tag supplies defaults for later rules of the same type.  Defaults
respect :selector and merge in order; later values override earlier ones.
A matching rule overrides its inherited defaults, including explicit nil.
Values are replaced as a whole, including :headers and :auth-source plists.
Regexps match displayed message text, case-sensitively.  Every nonempty
match becomes a button; earlier rules win overlapping ranges.
:replace is an optional string using `replace-match' backreferences,
with case preserved.  Without it, the entire match is the target.
:selector is a `zr-erc-selector-match-p' selector.  :url-tag reads a tag
instead of message text and appends a button; without :replace its whole
value is used.
File targets must be HTTP(S) URLs and open in separate buffers using
Emacs's native file modes.  Command targets must be single
slash commands, executed in the clicked buffer by `erc-send-input'.
Org targets are passed to `org-link-open-from-string' when clicked.
All actions require explicit activation.
File keys: :headers is an HTTP header alist; :auth-source is t or an
auth-source search plist; :auth-scheme is basic or bearer; :auth-header
defaults to Authorization.  :max-age is seconds; nil disables age checks
(the default).  Age uses the IRC time tag or local receipt time; expired
links reject file requests.  :proxy is inherit (the default), nil for a
direct connection, or a curl proxy URL (host:port means HTTP).
Explicit proxies bypass no_proxy and HTTPS uses CONNECT.  :timeout limits
each HTTP request (inherited from `zr-http-default-options').  :max-bytes
limits response body size (default 64 MiB).  :dir is the initial download
directory (default ~/Downloads/).  Redirects are rejected; rewrite to the
final URL so custom credentials cannot be forwarded to another host.
This option supports buffer-local values."
  :type 'sexp :group 'zr-erc-link)

(defcustom zr-erc-link-http-options '(:max-bytes 67108864)
  "HTTP options overriding `zr-http-default-options' for file links.
Rules can override :proxy, :timeout and :max-bytes for individual links."
  :type 'sexp :group 'zr-erc-link)

(cl-defstruct zr-erc-link--job
  buffer item destination overwrite callback request raw done error)
(defvar-local zr-erc-link--jobs nil)
(defvar zr-erc-link--directory nil
  "Shared temporary directory for files fetched by this Emacs session.")
(defvar zr-erc-link--file-sequence 0
  "Sequence number preserving request order for equal message times.")
(defvar erc-zr-link-mode)

(defun zr-erc-link--option (rule key fallback)
  "Read KEY from RULE, or use FALLBACK when KEY is absent."
  (if (plist-member rule key) (plist-get rule key) fallback))

(defun zr-erc-link--inherit (rule context)
  "Merge earlier defaults of RULE's type matching CONTEXT, then RULE.
Only entries without :regexp or :url-tag supply defaults."
  (let ((type (plist-get rule :type)) options)
    (cl-loop for entry in zr-erc-link-rules
             until (eq entry rule)
             when (and (eq (plist-get entry :type) type)
                       (not (plist-get entry :regexp))
                       (not (plist-get entry :url-tag))
                       (zr-erc-selector-match-p (plist-get entry :selector) context))
             do (cl-loop for (key value) on entry by #'cddr
                         unless (memq key '(:type :selector :replace))
                         do (setq options (plist-put options key value))))
    (cl-loop for (key value) on rule by #'cddr
             do (setq options (plist-put options key value)))
    options))

(defun zr-erc-link--item (value context &optional only-rule)
  "Describe VALUE using CONTEXT and the first applicable rule.
When ONLY-RULE is non-nil, only consider that rule."
  (save-match-data
    (let ((case-fold-search nil))
      (cl-loop
       for rule in (if only-rule (list only-rule) zr-erc-link-rules)
       when (and (or only-rule (plist-get rule :regexp) (plist-get rule :url-tag))
                 (zr-erc-selector-match-p (plist-get rule :selector) context)
                 (string-match (or (plist-get rule :regexp) "\\`\\(?:.\\|\n\\)*\\'") value))
       thereis
       (zr-erc-link--make-item
        (if-let* ((replacement (plist-get rule :replace)))
            (match-substitute-replacement replacement t nil value)
          value)
        rule context)))))

(defun zr-erc-link--make-item (target rule context)
  "Build an action from expanded TARGET, RULE and CONTEXT."
  (let ((type (plist-get rule :type)))
    (when (and (memq type '(file command org))
               (not (string-empty-p target))
               (or (not (eq type 'file))
                   (string-match-p "\\`https?://" target)))
      (list :target target
            :rule (zr-erc-link--inherit rule context) :type type
            :time (or (when-let* ((stamp (cdr (assoc "time" (plist-get context :tags)))))
                        (condition-case nil
                            (encode-time (iso8601-parse stamp t))
                          (error nil)))
                      (current-time))))))

(defun zr-erc-link--expired-p (item)
  "Whether ITEM exceeds its rule's age limit."
  (when-let* ((max-age (plist-get (plist-get item :rule) :max-age))
              (time (plist-get item :time)))
    (> (float-time (time-subtract (current-time) time)) max-age)))

(defun zr-erc-link--check-age (item)
  "Signal a user error if ITEM has expired."
  (when (zr-erc-link--expired-p item)
    (user-error "Media link has expired (message exceeds the configured age limit)")))

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
  (when-let* ((request (zr-erc-link--job-request job)))
    (zr-http-cancel request))

  (when-let* ((file (zr-erc-link--job-raw job)) ((file-exists-p file)))
    (delete-file file))
  (when (buffer-live-p (zr-erc-link--job-buffer job))
    (with-current-buffer (zr-erc-link--job-buffer job)
      (setq zr-erc-link--jobs (delq job zr-erc-link--jobs)))))

(defun zr-erc-link--fail (job reason)
  "Stop JOB with a concise REASON, without exposing its URL or credentials."
  (unless (zr-erc-link--job-done job)
    (setf (zr-erc-link--job-error job) reason)
    (zr-erc-link--cleanup job)
    (message "ERC media: %s" reason)
    (when-let* ((callback (zr-erc-link--job-callback job)))
      (funcall callback nil (zr-erc-link--job-item job)))))

(defun zr-erc-link--cleanup-buffer ()
  "Cancel pending requests owned by the current ERC buffer."
  (mapc #'zr-erc-link--cleanup (copy-sequence zr-erc-link--jobs))
  (setq zr-erc-link--jobs nil)
  (remove-hook 'kill-buffer-hook #'zr-erc-link--cleanup-buffer t))

(defun zr-erc-link--cleanup-directory ()
  "Remove this session's temporary directory when Emacs exits."
  (when (and zr-erc-link--directory (file-directory-p zr-erc-link--directory))
    (delete-directory zr-erc-link--directory t))
  (setq zr-erc-link--directory nil))

(defun zr-erc-link--temp-directory ()
  "Return the shared temporary directory, creating it on first use."
  (unless (and zr-erc-link--directory (file-directory-p zr-erc-link--directory))
    (setq zr-erc-link--directory (make-temp-file "erc-link-" t))
    (add-hook 'kill-emacs-hook #'zr-erc-link--cleanup-directory))
  zr-erc-link--directory)

(defun zr-erc-link--file-name (item)
  "Return ITEM's URL basename, without query or fragment."
  (let ((name (file-name-nondirectory
               (car (split-string
                     (url-filename (url-generic-parse-url (plist-get item :target)))
                     "[?#]")))))
    (if (string-empty-p name) "media" name)))

(defun zr-erc-link--image-suffix (file)
  "Give cached FILE a content-derived image suffix when it lacks one.
Return its possibly renamed path.  Leave non-images unchanged."
  (let ((case-fold-search t))
    (unless (cl-some (lambda (entry) (string-match-p (car entry) file))
                     image-type-file-name-regexps)
      (when-let* ((type (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file nil 0 8192)
                         (image-type-from-data (buffer-string))))
                  (suffix (if (eq type 'postscript) "ps" (symbol-name type)))
                  (name (concat file "." suffix)))
        (rename-file file name)
        (setq file name))))
  file)

(defun zr-erc-link--open-file (file item)
  "Open fetched FILE for ITEM in a separate buffer using its native mode."
  (let* ((enable-local-variables nil)
         (enable-local-eval nil)
         buffer opened)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (rename-buffer (format "*ERC link: %s*" (zr-erc-link--file-name item)) t))
          (pop-to-buffer buffer)
          (setq opened t))
      (unless opened
        (when-let* ((buffer (get-file-buffer file)))
          (kill-buffer buffer))))))

(defun zr-erc-link--received (response error job)
  "Handle HTTP RESPONSE or ERROR for JOB."
  (unless (zr-erc-link--job-done job)
    (condition-case nil
        (progn
          (when (or error (not (<= 200 (plist-get response :status) 299)))
            (error "HTTP failure"))
          (unless (zr-erc-link--job-destination job)
            (setf (zr-erc-link--job-raw job)
                  (zr-erc-link--image-suffix (zr-erc-link--job-raw job))))
          (cond
           ((zr-erc-link--job-destination job)
            (copy-file (zr-erc-link--job-raw job) (zr-erc-link--job-destination job)
                       (zr-erc-link--job-overwrite job))
            (zr-erc-link--cleanup job)
            (message "ERC media: download saved"))
           ((zr-erc-link--job-callback job)
            (let ((file (zr-erc-link--job-raw job)))
              (setf (zr-erc-link--job-raw job) nil)
              (zr-erc-link--cleanup job)
              (funcall (zr-erc-link--job-callback job) file (zr-erc-link--job-item job))))
           (t
            (zr-erc-link--open-file (zr-erc-link--job-raw job) (zr-erc-link--job-item job))
            (setf (zr-erc-link--job-raw job) nil)
            (zr-erc-link--cleanup job))))
      (error (zr-erc-link--fail job "Request failed, response too large, or cannot open file")))))

(defun zr-erc-link--fetch (item &optional destination overwrite callback)
  "Fetch ITEM to open, save to DESTINATION, or pass to CALLBACK.
CALLBACK receives the downloaded file and ITEM, or nil and ITEM on failure."
  (zr-erc-link--check-age item)
  (let* ((rule (plist-get item :rule))
         (overrides (cl-loop for key in '(:proxy :timeout :max-bytes)
                             when (plist-member rule key) append (list key (plist-get rule key))))
         (options (zr-http-options zr-http-default-options zr-erc-link-http-options overrides))
         (headers (zr-erc-link--headers item))
         (job (make-zr-erc-link--job
               :buffer (current-buffer) :item item
               :destination destination :overwrite overwrite :callback callback)))
    (setf (zr-erc-link--job-raw job)
          (make-temp-file
           (expand-file-name
            (format "erc-media-%s-%09d-"
                    (format-time-string "%Y%m%dT%H%M%S.%N" (plist-get item :time) t)
                    (cl-incf zr-erc-link--file-sequence))
            (zr-erc-link--temp-directory))
           nil (concat "-" (zr-erc-link--file-name item))))
    (push job zr-erc-link--jobs)
    (add-hook 'kill-buffer-hook #'zr-erc-link--cleanup-buffer nil t)
    (condition-case nil
        (setf (zr-erc-link--job-request job)
              (zr-http-request
               (plist-get item :target) :options options :headers headers
               :output-file (zr-erc-link--job-raw job)
               :callback (lambda (response error) (zr-erc-link--received response error job))))
      (error (zr-erc-link--fail job "Could not start the request")))
    job))

(defun zr-erc-link--file-button-at-point ()
  "Return the file button at point, or signal a user error."
  (let ((button (button-at (point))))
    (unless (and button (eq (plist-get (button-get button 'zr-erc-link-item) :type) 'file))
      (user-error "No file link at point"))
    button))

(defun zr-erc-link--file-buttons (beg end)
  "Return file buttons overlapping BEG through END, in buffer order."
  (let ((button (and (< beg end) (next-button beg t))) buttons)
    (while (and button (< (button-start button) end))
      (when (eq (plist-get (button-get button 'zr-erc-link-item) :type) 'file)
        (push button buttons))
      (setq button (next-button (button-end button) t)))
    (nreverse buttons)))

(defun zr-erc-link--open-files (buttons)
  "Fetch all file BUTTONS, then open the first successfully fetched file."
  (unless buttons (user-error "No file links in the selected range"))
  (let* ((items (mapcar (lambda (button) (button-get button 'zr-erc-link-item)) buttons))
         (remaining (length items))
         files
         (finish (lambda (file item)
                   (when file (push (cons item file) files))
                   (when (zerop (cl-decf remaining))
                     (when-let* ((entry (cl-loop for item in items
                                                thereis (assq item files))))
                       (condition-case err
                           (zr-erc-link--open-file (cdr entry) (car entry))
                         (error (message "ERC files: %s" (error-message-string err)))))))))
    (dolist (item items)
      (condition-case err
          (zr-erc-link--fetch item nil nil finish)
        (error
         (message "ERC files: %s" (error-message-string err))
         (funcall finish nil item))))))

;;;###autoload
(defun zr-erc-link-open (&optional beg end)
  "Open the rule link at point, or the nearest rule link before point.
File links open asynchronously in separate buffers.  Command and Org
links use their configured actions.
With an active region, fetch all file links overlapping it.  A prefix
argument uses the selected window's visible range instead of the region.
From Lisp, BEG and END specify that range; END is exclusive.  Range opens
skip command and Org links, fetch all files, and display only the first
successful file after the requests finish.  All fetched files share a
temporary directory, so Image mode's n/p can browse its images."
  (interactive
   (cond (current-prefix-arg (list (window-start) (window-end nil t)))
         ((use-region-p) (list (region-beginning) (region-end)))))
  (if (and beg end)
      (zr-erc-link--open-files (zr-erc-link--file-buttons beg end))
    (let ((button (previous-button (point) t)))
      (while (and button (not (button-get button 'zr-erc-link-item)))
        (setq button (previous-button (button-start button))))
      (unless button (user-error "No link at or before point"))
      (zr-erc-link--activate button))))

;;;###autoload
(defun zr-erc-link-download (destination &optional overwrite)
  "Download the file link at point to DESTINATION.
Existing files require explicit OVERWRITE permission."
  (interactive
   (let* ((button (zr-erc-link--file-button-at-point))
          (item (button-get button 'zr-erc-link-item))
          (name (zr-erc-link--file-name item))
          (file (progn
                  (zr-erc-link--check-age item)
                  (read-file-name "Download to: "
                                  (zr-erc-link--option (plist-get item :rule) :dir "~/Downloads/")
                                  nil nil name)))
          (exists (file-exists-p file)))
     (when (and exists (not (yes-or-no-p "Overwrite the existing file? "))) (user-error "Canceled"))
     (list file exists)))
  (let* ((button (zr-erc-link--file-button-at-point))
         (item (button-get button 'zr-erc-link-item)))
    (zr-erc-link--check-age item)
    (when (and (file-exists-p destination) (not overwrite)) (user-error "Destination already exists"))
    (make-directory (file-name-directory (expand-file-name destination)) t)
    (zr-erc-link--fetch item (expand-file-name destination) overwrite)))

(defun zr-erc-link--activate (button)
  "Dispatch BUTTON's rule action in its ERC buffer."
  (with-current-buffer (if (markerp button) (marker-buffer button) (current-buffer))
    (let* ((item (button-get button 'zr-erc-link-item))
           (target (plist-get item :target)))
      (pcase (plist-get item :type)
        ('file (zr-erc-link--fetch item))
        ('command
         (unless (and (string-match-p "\\`/[[:alpha:]][[:alnum:]-]*\\(?:[ \t]\\|\\'\\)" target)
                      (not (string-match-p "[\r\n\x00]" target)))
           (user-error "Link target must be a single ERC slash command"))
         (let ((inhibit-read-only t)) (erc-send-input target)))
        ('org (org-link-open-from-string target current-prefix-arg))
        (_ (user-error "Unknown link action"))))))

(defun zr-erc-link--buttonize (start end item)
  "Turn START to END into a button for ITEM."
  (remove-text-properties start end '(keymap nil erc-callback nil erc-data nil))
  (make-text-button start end 'action #'zr-erc-link--activate
                    'keymap button-map 'follow-link t 'zr-erc-link-item item
                    'help-echo (pcase (plist-get item :type)
                                 ('file "RET: open in a separate buffer")
                                 ('command "RET: execute ERC command")
                                 ('org "RET: open Org link"))))

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
          (when (zr-erc-selector-match-p (plist-get rule :selector) context)
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
                                          target rule context)))
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
  "Turn message rule matches into file, ERC command and Org link buttons."
  ((add-hook 'erc-insert-post-hook #'zr-erc-link--insert 95))
  ((remove-hook 'erc-insert-post-hook #'zr-erc-link--insert)
   (erc-buffer-list #'zr-erc-link--cleanup-buffer)))

(provide 'zr-erc-link)
;;; zr-erc-link.el ends here
