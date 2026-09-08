;;; zr-ffmpeg.el --- FFmpeg UI                   -*- lexical-binding: t; -*-

;;; Commentary:

;; Text-based FFmpeg User Interface.
;;
;; A task is a list of input pages plus one output/composition configuration.
;; Each page describes one FFmpeg source and its local processing choices.
;; Pages can be reordered and edited through the transient pager.  The final
;; command is generated only after all pages have been expanded into FFmpeg
;; input declarations, stream maps, and (when requested) a filter graph.
;;
;; Supported composition modes are `separate', `concat', `concat-video',
;; `concat-audio', `amix', `hstack', `vstack', and `overlay'.  `separate'
;; preserves every selected stream in one output.  The other modes produce a
;; combined stream and are configured at task/output scope.
;;
;; RET executes the complete task.  `e' edits the complete shell command,
;; while `?' previews the current input page and `SPC' previews the task.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'subr-x)
(require 'transient)
(require 'url-parse)

;;; User options and histories

(defvar zr-ffmpeg-input-history nil
  "History of input paths, URLs, and devices.")

(defvar zr-ffmpeg-target-history nil
  "History of FFmpeg output targets.")

(defvar zr-ffmpeg-command-history nil
  "History of complete FFmpeg commands that were executed or edited.")

(defvar savehist-additional-variables)

(with-eval-after-load 'savehist
  (dolist (variable '(zr-ffmpeg-input-history
                      zr-ffmpeg-target-history
                      zr-ffmpeg-command-history))
    (add-to-list 'savehist-additional-variables variable)))

(defgroup zr-ffmpeg nil
  "FFmpeg integration."
  :group 'multimedia)

(defcustom zr-ffmpeg-program "ffmpeg"
  "FFmpeg executable."
  :type 'file)

(defcustom zr-ffmpeg-ffprobe-program "ffprobe"
  "FFprobe executable used to inspect input streams."
  :type 'file)

(defcustom zr-ffmpeg-log-level "warning"
  "FFmpeg log level."
  :type 'string)

(defcustom zr-ffmpeg-window-hwnd nil
  "Default window handle for screen capture."
  :type '(choice (const nil) string))

(defcustom zr-ffmpeg-window-exe nil
  "Default executable name for screen capture."
  :type '(choice (const nil) string))

(defcustom zr-ffmpeg-monitor nil
  "Default zero-based monitor index for screen capture."
  :type '(choice (const nil) integer))

(defcustom zr-ffmpeg-window-framerate 30
  "Default capture framerate for screen capture."
  :type 'integer)

(defcustom zr-ffmpeg-audio-device nil
  "Default DirectShow audio device."
  :type '(choice (const nil) string))

(defcustom zr-ffmpeg-stream-target nil
  "Default streaming target."
  :type '(choice (const nil) string))

(defcustom zr-ffmpeg-output-directory nil
  "Optional default directory for file output."
  :type '(choice (const nil) directory))

(defcustom zr-ffmpeg-global-args '("-nostats")
  "Fallback global arguments used when no page contributes them."
  :type '(repeat (choice string (cons symbol sexp))))

(defcustom zr-ffmpeg-output-args nil
  "Fallback output arguments used when no page contributes them."
  :type '(repeat (choice string (cons symbol sexp))))

(defcustom zr-ffmpeg-output-resolution nil
  "Task output dimensions as a WIDTH/HEIGHT cons cell."
  :type '(choice (const nil) (cons integer integer)))

;;; Presets

;; An argument list contains strings for flags/options without values and
;; conses such as `(c:v . "h264_nvenc")' for options with one value.
(defcustom zr-ffmpeg-presets
  '((screen-stream
     :video-args ((c:v . "libx264") (preset . "veryfast")
                  (b:v . "10M") (fps_mode . "cfr")
                  (pix_fmt . "yuv420p"))
     :audio-args ((c:a . "libopus") (b:a . "128k"))
     :output-args ((fflags . "+nobuffer") (flags . "+low_delay"))
     :subtitle-mode burn-in
     :audio t
     :video t
     :output-resolution (1920 . 1080))
    (file-stream
     :input-args ("-re")
     :video-args ((c:v . "libx264") (preset . "veryfast")
                  (b:v . "10M") (fps_mode . "vfr")
                  (pix_fmt . "yuv420p") (bf . "0"))
     :audio-args ((c:a . "libopus") (b:a . "128k"))
     :subtitle-mode burn-in
     :audio t
     :video t
     :output-resolution (1920 . 1080))
    (file-copy
     :global-args ("-nostats")
     :video-args ((c:v . "copy"))
     :audio-args ((c:a . "copy"))
     :output-args ((movflags . "+faststart"))
     :subtitle-args ((c:s . "copy"))
     :subtitle-mode soft-default
     :audio t
     :video t)
    (file-general-volume
     :global-args ("-nostats")
     :video-args ((c:v . "copy"))
     :audio-args ((c:a . "libopus") (b:a . "192k")
                  (af . "loudnorm=I=-16:TP=-1.5:LRA=11"))
     :subtitle-args ((c:s . "copy"))
     :subtitle-mode soft-default
     :audio t
     :video t)
    (file-cinema-volume
     :global-args ("-nostats")
     :video-args ((c:v . "copy"))
     :audio-args ((c:a . "libopus") (b:a . "192k")
                  (af . "loudnorm=I=-23:TP=-1.5:LRA=11"))
     :subtitle-args ((c:s . "copy"))
     :subtitle-mode soft-default
     :audio t
     :video t))
  "FFmpeg presets.

Every preset uses only these keys: :global-args, :input-args, :video-args,
:audio-args, :subtitle-args, :output-args, :subtitle-mode, :audio, :video,
and :output-resolution.  Argument values are strings or cons cells whose car
is the option symbol and whose cdr is its value."
  :type '(alist :key-type symbol :value-type plist))

(defun zr-ffmpeg--preset-plist (name)
  "Return preset plist for NAME."
  (or (cdr (assq name zr-ffmpeg-presets))
      (user-error "Unknown FFmpeg preset: %s" name)))

(defun zr-ffmpeg--preset-value (name key)
  "Return KEY from preset NAME."
  (plist-get (zr-ffmpeg--preset-plist name) key))

(defun zr-ffmpeg--preset-candidates ()
  "Return preset completion candidates."
  (mapcar (lambda (entry) (symbol-name (car entry))) zr-ffmpeg-presets))

;;; Task state

(defvar-local zr-ffmpeg--inputs-state nil
  "Input pages for the current FFmpeg task.

Each page is a plist with an integer `:id', a `:kind' (`file', `screen', or
`audio-device'), a `:source', a `:preset', and an `:overrides' plist.  A file
page's `:source' supplies selected video, audio, subtitle, and data streams.
`:subtitle-source' is an optional external subtitle file associated with the
page.  Use additional pages for independent media inputs and devices.")

(defvar-local zr-ffmpeg--current-input-id 1)
(defvar-local zr-ffmpeg--composition-mode 'separate)
(defvar-local zr-ffmpeg--composition-input-ids nil)
(defvar-local zr-ffmpeg--output-format nil)
(defvar-local zr-ffmpeg--output-target nil)
(defvar-local zr-ffmpeg--output-framerate nil)
(defvar-local zr-ffmpeg--global-args nil)
(defvar-local zr-ffmpeg--output-args nil)

;; Values mirrored into transient infixes and synchronized from the current
;; page whenever the menu is displayed.
(defvar-local zr-ffmpeg--current-preset 'file-copy)
(defvar-local zr-ffmpeg--video-toggle nil)
(defvar-local zr-ffmpeg--audio-toggle nil)
(defvar-local zr-ffmpeg--subtitle-mode 'soft)

(defun zr-ffmpeg--new-page (&optional id)
  "Create an empty input page with ID."
  (list :id (or id 1) :kind 'file :source nil :monitor nil
        :window-hwnd nil :window-exe nil
        :audio-device nil :video-streams 'all :audio-streams 'all
        :subtitle-streams 'all :data-streams nil
        :subtitle-source nil
        :preset 'file-copy :overrides nil
        :stream-info nil))

(defun zr-ffmpeg--ensure-state ()
  "Initialize task state when it is empty."
  (unless (and (listp zr-ffmpeg--inputs-state) zr-ffmpeg--inputs-state)
    (let ((sources
           (cond
            ((derived-mode-p 'dired-mode)
             (dired-get-marked-files))
            ((buffer-file-name) (list (buffer-file-name)))
            (t nil))))
      (setq zr-ffmpeg--inputs-state
            (if sources
                (cl-loop for source in sources for id from 1
                         collect (let ((page (zr-ffmpeg--new-page id)))
                                   (setf (plist-get page :source)
                                         (zr-ffmpeg--normalize-source source))
                                   page))
              (list (zr-ffmpeg--new-page))))))
  (unless (cl-find zr-ffmpeg--current-input-id zr-ffmpeg--inputs-state
                   :key (lambda (page) (plist-get page :id)))
    (setq zr-ffmpeg--current-input-id
          (plist-get (car zr-ffmpeg--inputs-state) :id))))

(defun zr-ffmpeg--current-page ()
  "Return the current input page."
  (zr-ffmpeg--ensure-state)
  (or (cl-find zr-ffmpeg--current-input-id zr-ffmpeg--inputs-state
               :key (lambda (page) (plist-get page :id)))
      (user-error "No current FFmpeg input page")))

(defun zr-ffmpeg--sync-page-vars ()
  "Synchronize transient mirror variables from the current page."
  (let ((page (zr-ffmpeg--current-page)))
    (setq zr-ffmpeg--current-preset (plist-get page :preset)
          zr-ffmpeg--video-toggle
          (zr-ffmpeg--page-effective page :video)
          zr-ffmpeg--audio-toggle
          (zr-ffmpeg--page-effective page :audio)
          zr-ffmpeg--subtitle-mode
          (or (zr-ffmpeg--page-effective page :subtitle-mode) 'soft))))

(defun zr-ffmpeg--replace-page (page)
  "Replace PAGE in the task state."
  (setq zr-ffmpeg--inputs-state
        (mapcar (lambda (candidate)
                  (if (= (plist-get candidate :id) (plist-get page :id))
                      page candidate))
                zr-ffmpeg--inputs-state))
  (zr-ffmpeg--sync-page-vars))

(defun zr-ffmpeg--page-set (key value)
  "Set KEY to VALUE on the current page."
  (let ((page (zr-ffmpeg--current-page)))
    (setf (plist-get page key) value)
    (zr-ffmpeg--replace-page page)))

(defun zr-ffmpeg--page-override (key value)
  "Set effective override KEY to VALUE on the current page."
  (let* ((page (zr-ffmpeg--current-page))
         (overrides (copy-sequence (plist-get page :overrides))))
    (setf (plist-get page :overrides) (plist-put overrides key value))
    (zr-ffmpeg--replace-page page)))

(defun zr-ffmpeg--page-effective (page key)
  "Return effective KEY for PAGE, honoring explicit nil overrides."
  (let ((overrides (plist-get page :overrides)))
    (if (plist-member overrides key)
        (plist-get overrides key)
      (plist-get (zr-ffmpeg--preset-plist (plist-get page :preset)) key))))

(defun zr-ffmpeg--page-index (&optional id)
  "Return one-based page index for ID or the current page."
  (let ((wanted (or id zr-ffmpeg--current-input-id)) (index 1))
    (catch 'found
      (dolist (page zr-ffmpeg--inputs-state)
        (when (= wanted (plist-get page :id)) (throw 'found index))
        (setq index (1+ index)))
      nil)))

;;; Generic helpers

(defun zr-ffmpeg-system-processes ()
  "Return running system process executable names."
  (delete-dups
   (delq nil
         (mapcar (lambda (pid)
                   (cdr (assq 'comm (process-attributes pid))))
                 (list-system-processes)))))

(defun zr-ffmpeg-dshow-audio-devices ()
  "Return available DirectShow audio devices."
  (let ((output (with-temp-buffer
                  (call-process zr-ffmpeg-program nil (list t t) nil
                                "-hide_banner" "-list_devices" "true"
                                "-f" "dshow" "-i" "dummy")
                  (buffer-string)))
        devices)
    (dolist (line (split-string output "\n" t))
      (when (string-match "\"\\([^\"]+\\)\"[ \t]*(audio)" line)
        (push (match-string 1 line) devices)))
    (delete-dups (nreverse devices))))

(defun zr-ffmpeg--url-p (source)
  "Return non-nil when SOURCE has a URL scheme, excluding drive letters."
  (and (stringp source)
       (not (string-match-p "\\`[[:alpha:]]:" source))
       (url-type (url-generic-parse-url source))))

(defun zr-ffmpeg--normalize-source (source)
  "Return SOURCE as a URL or absolute local path."
  (if (or (equal source "-") (zr-ffmpeg--url-p source))
      source (expand-file-name source)))

(defun zr-ffmpeg--local-path-p (source)
  "Return non-nil when SOURCE is a local path."
  (and source (not (equal source "-")) (not (zr-ffmpeg--url-p source))))

(defun zr-ffmpeg--args->argv (args)
  "Flatten structured ARGS into an argv list.
An element is either a string or a cons whose car is an option symbol and
whose cdr is its value."
  (apply #'append
         (mapcar (lambda (entry)
                   (cond
                    ((stringp entry) (list entry))
                    ((and (consp entry) (symbolp (car entry)))
                     (let ((option (concat "-" (symbol-name (car entry))))
                           (value (cdr entry)))
                       (if value
                           (list option (format "%s" value))
                         (list option))))
                    (t (user-error "Invalid FFmpeg argument: %S" entry))))
                 args)))

(defun zr-ffmpeg--argument-list (key page &optional fallback)
  "Return structured effective argument list KEY for PAGE."
  (or (let ((overrides (plist-get page :overrides)))
        (and (plist-member overrides key) (plist-get overrides key)))
      (zr-ffmpeg--preset-value (plist-get page :preset) key)
      fallback))

(defun zr-ffmpeg--argument-argv (key page &optional fallback)
  "Return flattened argv for structured argument list KEY of PAGE."
  (zr-ffmpeg--args->argv (zr-ffmpeg--argument-list key page fallback)))

(defun zr-ffmpeg--stream-selection (page key)
  "Return PAGE's stream selection for KEY.
The value is `all', nil, or a list of type-relative stream ordinals."
  (if (plist-member page key)
      (plist-get page key)
    (if (eq key :data-streams) nil 'all)))

(defun zr-ffmpeg--stream-selectors (page kind)
  "Return relative FFmpeg stream selectors for PAGE and KIND.
The default `all' selects every stream of that type, nil selects none, and a
list of integers selects type-relative stream ordinals."
  (let* ((key (pcase kind
                ('video :video-streams)
                ('audio :audio-streams)
                ('subtitle :subtitle-streams)
                ('data :data-streams)
                (_ (user-error "Unsupported stream kind: %s" kind))))
         (selection (zr-ffmpeg--stream-selection page key))
         (prefix (pcase kind
                   ('video "v")
                   ('audio "a")
                   ('subtitle "s")
                   ('data "d"))))
    (cond
     ((eq selection 'all) (list (concat prefix "?")))
     ((null selection) nil)
     (t (mapcar (lambda (index) (format "%s:%d?" prefix index))
                selection)))))

(defun zr-ffmpeg--selected-stream-index (page key label)
  "Return one selected stream index for PAGE's KEY.
Treat `all' as the primary stream and reject multiple explicit selections."
  (let ((selection (zr-ffmpeg--stream-selection page key)))
    (cond
     ((eq selection 'all) 0)
     ((and (listp selection) (= (length selection) 1))
      (car selection))
     (t (user-error "Video processing requires one %s stream on page %s"
                    label (plist-get page :id))))))

(defun zr-ffmpeg--burn-video-index (page)
  "Return the video stream index used by PAGE's burn-in filter."
  (zr-ffmpeg--selected-stream-index page :video-streams "video"))

(defun zr-ffmpeg--subtitle-source (page)
  "Return PAGE's configured subtitle source."
  (plist-get page :subtitle-source))

(defun zr-ffmpeg--stream-selector-kind-p (stream kind)
  "Return non-nil when STREAM is a selector for KIND.
KIND is the one-letter FFmpeg stream type, such as `v', `a', `s', or `d'.
This accepts both the all-stream spelling `v?' and indexed spellings such as
`v:0?'."
  (and (stringp stream)
       (or (equal stream kind)
           (string-prefix-p (concat kind "?") stream)
           (string-prefix-p (concat kind ":") stream))))

(defun zr-ffmpeg--probe-streams (source)
  "Return stream metadata for local or URL SOURCE, or nil when unavailable.
Each result includes the global ffprobe `:index' and type-relative `:ordinal'."
  (when (and (or (zr-ffmpeg--local-path-p source)
                 (zr-ffmpeg--url-p source))
             (executable-find zr-ffmpeg-ffprobe-program))
    (with-temp-buffer
      (when (zerop (call-process zr-ffmpeg-ffprobe-program nil t nil
                                 "-v" "quiet" "-print_format" "json"
                                 "-show_streams" source))
        (goto-char (point-min))
        (condition-case nil
            (let ((json (json-parse-buffer :object-type 'alist
                                           :array-type 'list
                                           :null-object nil))
                  (ordinals (make-hash-table :test 'eq)))
              (mapcar
               (lambda (stream)
                 (let* ((codec-type (alist-get 'codec_type stream))
                        (type (and (stringp codec-type)
                                   (intern codec-type)))
                        (ordinal (and type (gethash type ordinals 0))))
                   (when type
                     (puthash type (1+ ordinal) ordinals))
                   (list :index (alist-get 'index stream)
                         :ordinal ordinal
                         :type type
                         :codec (alist-get 'codec_name stream)
                         :language (alist-get 'language
                                               (alist-get 'tags stream)))))
               (alist-get 'streams json)))
          (json-parse-error nil))))))

(defun zr-ffmpeg-set-stream-selection ()
  "Choose all, none, or selected streams for the current page."
  (interactive)
  (let* ((page (zr-ffmpeg--current-page))
         (source (plist-get page :source))
         (streams (zr-ffmpeg--probe-streams source))
         (types '(("video" . :video-streams)
                  ("audio" . :audio-streams)
                  ("subtitle" . :subtitle-streams)
                  ("data" . :data-streams))))
    (unless streams
      (user-error "No stream metadata available for %s" (or source "input")))
    (setf (plist-get page :stream-info) streams)
    (dolist (type types)
      (let* ((kind (intern (car type)))
             (key (cdr type))
             (default (if (eq kind 'data) nil 'all))
             (available (cl-remove-if-not
                         (lambda (stream)
                           (eq (plist-get stream :type) kind)) streams))
             (choices
              (append
               (list (cons "[all] all streams" 'all)
                     (cons "[none] no streams" nil))
               (mapcar
                (lambda (stream)
                  (cons (format "%d: %s%s"
                                (plist-get stream :index)
                                (or (plist-get stream :codec) "unknown")
                                (if-let* ((language (plist-get stream :language)))
                                    (format " (%s)" language) ""))
                        (plist-get stream :ordinal)))
                available)))
             (selected (completing-read-multiple
                        (format "%s streams (empty = %s): "
                                (car type) (if (eq default 'all) "all" "none"))
                        choices nil nil)))
        (let* ((values (mapcar (lambda (choice) (cdr (assoc choice choices)))
                               selected))
               (specials (cl-remove-if-not
                          (lambda (value) (memq value '(all nil))) values)))
          (when (and specials (> (length values) 1))
            (user-error "Choose all/none or specific %s streams, not both"
                        (car type)))
          (when (> (length specials) 1)
            (user-error "Choose either all or none for %s streams"
                        (car type)))
          (zr-ffmpeg--page-set
           key (cond
                ((null selected) default)
                ((eq (car specials) 'all) 'all)
                ((and specials (null (car specials))) nil)
                (t values))))))
    (transient-setup)))

(defun zr-ffmpeg--read-source (prompt current &optional target)
  "Read a path or URL with unified input history.
When TARGET is non-nil, use output target history instead."
  (let ((source (string-trim
                 (completing-read prompt #'completion-file-name-table
                                  nil nil (or current "")
                                  (if target 'zr-ffmpeg-target-history
                                    'zr-ffmpeg-input-history)))))
    (unless (string-empty-p source)
      (zr-ffmpeg--normalize-source source))))

;;; Input pages and source selection

(defun zr-ffmpeg--clear-capture-fields ()
  "Clear capture-specific fields on the current page."
  (dolist (key '(:monitor :window-hwnd :window-exe :audio-device))
    (zr-ffmpeg--page-set key nil)))

(defun zr-ffmpeg-set-input ()
  "Set the current page to a file or URL input."
  (interactive)
  (let* ((page (zr-ffmpeg--current-page))
         (source (zr-ffmpeg--read-source
                  "Input path/URL: " (plist-get page :source))))
    (zr-ffmpeg--page-set :kind 'file)
    (zr-ffmpeg--page-set :source source)
    (dolist (selection '((:video-streams . all)
                         (:audio-streams . all)
                         (:subtitle-streams . all)
                         (:data-streams . nil)))
      (zr-ffmpeg--page-set (car selection) (cdr selection)))
    (zr-ffmpeg--page-set :stream-info nil)
    (zr-ffmpeg--clear-capture-fields)
    (transient-setup)))

(defun zr-ffmpeg-set-subtitle-source ()
  "Set or clear the external subtitle source for the current page."
  (interactive)
  (zr-ffmpeg--page-set
   :subtitle-source
   (zr-ffmpeg--read-source
    "Subtitle path/URL (empty clears): "
    (plist-get (zr-ffmpeg--current-page) :subtitle-source)))
  (transient-setup))

(defun zr-ffmpeg-set-monitor ()
  "Set the current page to monitor capture."
  (interactive)
  (unless (fboundp 'display-monitor-attributes-list)
    (user-error "This Emacs does not provide monitor attributes"))
  (let ((index 0) candidates)
    (dolist (attributes (display-monitor-attributes-list))
      (let* ((name (or (cdr (assq 'name attributes))
                       (format "Monitor %d" index)))
             (geometry (cdr (assq 'geometry attributes)))
             (label (if (and geometry (>= (length geometry) 4))
                        (format "%d: %s (%dx%d+%d+%d)" index name
                                (nth 2 geometry) (nth 3 geometry)
                                (nth 0 geometry) (nth 1 geometry))
                      (format "%d: %s" index name))))
        (push (cons label index) candidates)
        (setq index (1+ index))))
    (unless candidates (user-error "No monitors are available"))
    (let* ((choices (nreverse candidates))
           (choice (completing-read "Monitor: " choices nil t)))
      (zr-ffmpeg--page-set :kind 'screen)
      (zr-ffmpeg--page-set :source nil)
      (zr-ffmpeg--page-set :monitor (cdr (assoc choice choices)))
      (zr-ffmpeg--page-set :window-hwnd nil)
      (zr-ffmpeg--page-set :window-exe nil)
      (zr-ffmpeg--page-set :audio-device nil)
      (transient-setup))))

(defun zr-ffmpeg-set-window ()
  "Set the current page to window capture."
  (interactive)
  (let ((window (completing-read "Window: " (zr-ffmpeg-system-processes)
                                nil t)))
    (zr-ffmpeg--page-set :kind 'screen)
    (zr-ffmpeg--page-set :source nil)
    (zr-ffmpeg--page-set :window-exe window)
    (zr-ffmpeg--page-set :monitor nil)
    (zr-ffmpeg--page-set :window-hwnd nil)
    (zr-ffmpeg--page-set :audio-device nil)
    (transient-setup)))

(defun zr-ffmpeg-set-audio-device ()
  "Set the current page to a DirectShow audio device."
  (interactive)
  (let ((device (completing-read "Audio device: "
                                (zr-ffmpeg-dshow-audio-devices)
                                nil nil zr-ffmpeg-audio-device
                                'zr-ffmpeg-input-history)))
    (zr-ffmpeg--page-set :kind 'audio-device)
    (zr-ffmpeg--page-set :audio-device device)
    (zr-ffmpeg--page-set :source nil)
    (zr-ffmpeg--page-set :monitor nil)
    (zr-ffmpeg--page-set :window-hwnd nil)
    (zr-ffmpeg--page-set :window-exe nil)
    (zr-ffmpeg--page-override :video nil)
    (zr-ffmpeg--page-override :audio t)
    (transient-setup)))

(defun zr-ffmpeg-add-input ()
  "Append a new input page and make it current."
  (interactive)
  (zr-ffmpeg--ensure-state)
  (let ((id (1+ (apply #'max (mapcar (lambda (page) (plist-get page :id))
                                     zr-ffmpeg--inputs-state)))))
    (setq zr-ffmpeg--inputs-state
          (append zr-ffmpeg--inputs-state (list (zr-ffmpeg--new-page id)))
          zr-ffmpeg--current-input-id id)
    (zr-ffmpeg--sync-page-vars)
    (transient-setup)))

(defun zr-ffmpeg-delete-input ()
  "Delete the current input page."
  (interactive)
  (zr-ffmpeg--ensure-state)
  (when (= (length zr-ffmpeg--inputs-state) 1)
    (user-error "Keep at least one input page"))
  (setq zr-ffmpeg--inputs-state
        (cl-remove-if (lambda (page)
                        (= (plist-get page :id) zr-ffmpeg--current-input-id))
                      zr-ffmpeg--inputs-state)
        zr-ffmpeg--current-input-id
        (plist-get (car zr-ffmpeg--inputs-state) :id))
  (zr-ffmpeg--sync-page-vars)
  (transient-setup))

(defun zr-ffmpeg-duplicate-input ()
  "Duplicate the current input page and make the copy current."
  (interactive)
  (let* ((page (copy-tree (zr-ffmpeg--current-page)))
         (id (1+ (apply #'max (mapcar (lambda (candidate)
                                        (plist-get candidate :id))
                                      zr-ffmpeg--inputs-state)))))
    (setf (plist-get page :id) id)
    (setq zr-ffmpeg--inputs-state
          (append zr-ffmpeg--inputs-state (list page))
          zr-ffmpeg--current-input-id id)
    (zr-ffmpeg--sync-page-vars)
    (transient-setup)))

(defun zr-ffmpeg-next-input ()
  "Select the next input page."
  (interactive)
  (let* ((pages zr-ffmpeg--inputs-state)
         (position (cl-position zr-ffmpeg--current-input-id pages
                                :key (lambda (page) (plist-get page :id))))
         (next (nth (mod (1+ position) (length pages)) pages)))
    (setq zr-ffmpeg--current-input-id (plist-get next :id))
    (zr-ffmpeg--sync-page-vars)
    (transient-setup)))

(defun zr-ffmpeg-previous-input ()
  "Select the previous input page."
  (interactive)
  (let* ((pages zr-ffmpeg--inputs-state)
         (position (cl-position zr-ffmpeg--current-input-id pages
                                :key (lambda (page) (plist-get page :id))))
         (previous (nth (mod (1- position) (length pages)) pages)))
    (setq zr-ffmpeg--current-input-id (plist-get previous :id))
    (zr-ffmpeg--sync-page-vars)
    (transient-setup)))

(defun zr-ffmpeg-select-input ()
  "Select an input page by its one-based index."
  (interactive)
  (let* ((choices (cl-loop for page in zr-ffmpeg--inputs-state
                           for index from 1
                           collect (cons (format "%d: %s" index
                                                  (or (plist-get page :source)
                                                      (symbol-name
                                                       (plist-get page :kind))))
                                         (plist-get page :id))))
         (choice (completing-read "Input page: " choices nil t)))
    (setq zr-ffmpeg--current-input-id (cdr (assoc choice choices)))
    (zr-ffmpeg--sync-page-vars)
    (transient-setup)))

(defun zr-ffmpeg-move-input-up ()
  "Move the current input page one position earlier."
  (interactive)
  (let* ((pages zr-ffmpeg--inputs-state)
         (pos (cl-position zr-ffmpeg--current-input-id pages
                           :key (lambda (page) (plist-get page :id)))))
    (when (> pos 0)
      (let ((previous (nth (1- pos) pages))
            (current (nth pos pages)))
        (setf (nth (1- pos) pages) current
              (nth pos pages) previous)
        (setq zr-ffmpeg--inputs-state pages)
        (transient-setup)))))

(defun zr-ffmpeg-move-input-down ()
  "Move the current input page one position later."
  (interactive)
  (let* ((pages zr-ffmpeg--inputs-state)
         (pos (cl-position zr-ffmpeg--current-input-id pages
                           :key (lambda (page) (plist-get page :id)))))
    (when (< pos (1- (length pages)))
      (let ((current (nth pos pages))
            (next (nth (1+ pos) pages)))
        (setf (nth pos pages) next
              (nth (1+ pos) pages) current)
        (setq zr-ffmpeg--inputs-state pages)
        (transient-setup)))))

;;; Screen and output helpers

(defun zr-ffmpeg--screen-filter (page)
  "Build the gfxcapture filter for PAGE."
  (let* ((framerate (or zr-ffmpeg--output-framerate zr-ffmpeg-window-framerate))
         (resolution (or zr-ffmpeg-output-resolution
                         (zr-ffmpeg--page-effective page :output-resolution)))
         (size (and resolution
                    (format ":width=%d:height=%d:resize_mode=scale_aspect"
                            (car resolution) (cdr resolution))))
         (monitor (or (plist-get page :monitor) zr-ffmpeg-monitor))
         (window-hwnd (or (plist-get page :window-hwnd)
                          zr-ffmpeg-window-hwnd))
         (window-exe (or (plist-get page :window-exe) zr-ffmpeg-window-exe)))
    (cond
     (window-hwnd
      (format "gfxcapture=window_hwnd=%s:max_framerate=%s%s,hwdownload,format=bgra"
              window-hwnd framerate (or size "")))
     ((integerp monitor)
      (format "gfxcapture=monitor_idx=%d:max_framerate=%s%s,hwdownload,format=bgra"
              monitor framerate (or size "")))
     (window-exe
      (format "gfxcapture=window_exe='%s':max_framerate=%s%s,hwdownload,format=bgra"
              window-exe framerate (or size "")))
     (t (user-error "Set a monitor or window for screen input %s"
                    (plist-get page :id))))))

(defun zr-ffmpeg--validate-resolution (value)
  "Return VALUE after validating its WIDTH/HEIGHT cons."
  (unless (or (null value)
              (and (consp value)
                   (integerp (car value)) (> (car value) 0)
                   (integerp (cdr value)) (> (cdr value) 0)))
    (user-error "Resolution must be a positive (WIDTH . HEIGHT) cons: %S"
                value))
  value)

(defun zr-ffmpeg--output-resolution (&optional page)
  "Return effective task output resolution as a cons cell.
PAGE is used for page previews; task commands use the first selected page's
preset only as a default, while an explicit Output value always wins."
  (let ((page (or page (car (zr-ffmpeg--selected-pages))
                 (zr-ffmpeg--current-page))))
    (zr-ffmpeg--validate-resolution
     (or zr-ffmpeg-output-resolution
         (zr-ffmpeg--page-effective page :output-resolution)))))

(defun zr-ffmpeg--output-extension ()
  "Return a default output extension."
  (pcase zr-ffmpeg--output-format
    ("mp4" ".mp4") ("mov" ".mov") ("webm" ".webm")
    ("mpegts" ".ts") ("matroska" ".mkv") (_ ".mkv")))

(defun zr-ffmpeg--input-basename (source)
  "Return a file-name base derived from SOURCE."
  (let* ((path (if (zr-ffmpeg--url-p source)
                   (url-filename (url-generic-parse-url source)) source))
         (path (car (split-string (or path "") "[?#]" t)))
         (name (and path (file-name-nondirectory path))))
    (if (string-empty-p (or name "")) "recording"
      (file-name-sans-extension name))))

(defun zr-ffmpeg--file-output-path (&optional source)
  "Return a default file target derived from SOURCE or the first page."
  (let* ((page (zr-ffmpeg--current-page))
         (source (or source (plist-get page :source)))
         (directory (or zr-ffmpeg-output-directory
                        (and source (zr-ffmpeg--local-path-p source)
                             (file-name-directory source))
                        default-directory)))
    (expand-file-name (concat (zr-ffmpeg--input-basename source)
                              (zr-ffmpeg--output-extension)) directory)))

(defun zr-ffmpeg--output-for-input (&optional source)
  "Return the task's output target."
  (or zr-ffmpeg--output-target zr-ffmpeg-stream-target
      (zr-ffmpeg--file-output-path source)))

;;; FFmpeg input specifications

(defun zr-ffmpeg--spec (page source args streams &optional role)
  "Build an expanded FFmpeg spec owned by PAGE."
  (let ((source (zr-ffmpeg--normalize-source source)))
    (list :owner-id (plist-get page :id) :role (or role 'primary)
          :source source :args args :streams streams
          :file (and (zr-ffmpeg--local-path-p source) source))))

(defun zr-ffmpeg--input-specs (&optional pages)
  "Expand PAGES into FFmpeg input declarations in stable page order."
  (let ((pages (or pages zr-ffmpeg--inputs-state)) specs)
    (dolist (page pages (nreverse specs))
      (let* ((kind (plist-get page :kind))
             (input-args (zr-ffmpeg--argument-argv :input-args page))
             (video (zr-ffmpeg--page-effective page :video))
             (audio (zr-ffmpeg--page-effective page :audio))
             (source (plist-get page :source))
             (subtitle-mode (zr-ffmpeg--page-effective page :subtitle-mode))
             (external-subtitle (plist-get page :subtitle-source)))
        (pcase kind
          ('file
           (unless (and source (not (string-empty-p source)))
             (user-error "Input page %s has no path or URL"
                         (plist-get page :id)))
           (push (zr-ffmpeg--spec
                  page source input-args
                  (append (when video
                            (if (and external-subtitle
                                     (eq subtitle-mode 'burn-in))
                                (list (format "v:%d?"
                                              (zr-ffmpeg--burn-video-index page)))
                              (zr-ffmpeg--stream-selectors page 'video)))
                           (when audio
                            (zr-ffmpeg--stream-selectors page 'audio))
                          (zr-ffmpeg--stream-selectors page 'subtitle)
                          (zr-ffmpeg--stream-selectors page 'data)))
                 specs))
          ('screen
           (push (zr-ffmpeg--spec
                  page (zr-ffmpeg--screen-filter page)
                  (append input-args '("-f" "lavfi"))
                  (when video '("v:0")))
                 specs))
          ('audio-device
           (let ((device (or (plist-get page :audio-device)
                             zr-ffmpeg-audio-device)))
             (unless device
               (user-error "Input page %s has no audio device"
                           (plist-get page :id)))
             (push (zr-ffmpeg--spec
                    page (concat "audio=" device)
                    (append input-args '("-f" "dshow"))
                    (when audio '("a:0")))
                   specs)))
          (_ (user-error "Unsupported input kind: %s" kind)))
        (when (and external-subtitle
                   (memq subtitle-mode '(soft soft-default)))
          (push (zr-ffmpeg--spec page external-subtitle nil '("s:0?")
                                 'subtitle)
                specs))))))

(defun zr-ffmpeg--build-input-args (specs)
  "Build FFmpeg input declarations from SPECS."
  (cl-loop for spec in specs
           append (append (plist-get spec :args)
                          (list "-i" (plist-get spec :source)))))

(defun zr-ffmpeg--mapping-args (specs)
  "Build direct stream maps for SPECS."
  (cl-loop for spec in specs for index from 0
           append (cl-loop for stream in (plist-get spec :streams)
                           append (list "-map" (format "%d:%s" index stream)))))

(defun zr-ffmpeg--spec-index (specs owner &optional role)
  "Return FFmpeg index for OWNER and ROLE in SPECS."
  (let ((index 0) result)
    (dolist (spec specs result)
      (when (and (= owner (plist-get spec :owner-id))
                 (or (null role) (eq role (plist-get spec :role))))
        (setq result index))
      (setq index (1+ index)))))

;;; Filter graph and command generation

(defun zr-ffmpeg--filter-quote (value)
  "Escape VALUE for a filter filename."
  (replace-regexp-in-string "[\\\\':,;]"
                            (lambda (match) (concat "\\" match))
                            value t t))

(defun zr-ffmpeg--subtitle-filter (source)
  "Return a subtitles filter for SOURCE."
  (format "subtitles=filename='%s'" (zr-ffmpeg--filter-quote source)))

(defun zr-ffmpeg--selected-pages (&optional pages)
  "Return pages participating in the configured composition."
  (let ((pages (or pages zr-ffmpeg--inputs-state)))
    (if (null zr-ffmpeg--composition-input-ids) pages
      (cl-remove-if-not
       (lambda (page)
         (memq (plist-get page :id) zr-ffmpeg--composition-input-ids))
       pages))))

(defun zr-ffmpeg--page-video-args (page)
  "Return PAGE video arguments."
  (zr-ffmpeg--argument-list :video-args page))

(defun zr-ffmpeg--page-audio-args (page)
  "Return PAGE audio arguments."
  (zr-ffmpeg--argument-list :audio-args page))

(defun zr-ffmpeg--page-subtitle-args (page)
  "Return PAGE arguments for mapped subtitle streams."
  (zr-ffmpeg--argument-list :subtitle-args page))

(defun zr-ffmpeg--burn-subtitle-page-p (page)
  "Return non-nil when PAGE has an active burn-in subtitle source."
  (and (eq (zr-ffmpeg--page-effective page :subtitle-mode) 'burn-in)
       (zr-ffmpeg--subtitle-source page)))

(defun zr-ffmpeg--page-subtitle-disposition (page)
  "Return default disposition args for PAGE's mapped soft-default subtitles."
  (when (eq (zr-ffmpeg--page-effective page :subtitle-mode) 'soft-default)
    '((disposition:s . "default"))))

(defun zr-ffmpeg--scope-output-args (args kind index)
  "Scope stream-specific ARGS of KIND to output INDEX.
With nil INDEX, target all streams of KIND.  Subtitle metadata uses the
metadata stream selector `s:s', followed by the subtitle ordinal if known."
  (let ((suffix (if (or (null index)
                       (and (= index 0) (memq kind '(video audio))))
                    "" (format ":%d" index)))
        result)
    (dolist (entry args (nreverse result))
      (if (stringp entry)
          (push entry result)
        (let* ((option (if (and (eq kind 'subtitle)
                                (eq (car entry) 'metadata:s))
                           'metadata:s:s
                         (car entry)))
               (scoped
                (if (and (not (string-empty-p suffix))
                         (pcase kind
                           ('video (memq option '(c:v b:v maxrate:v bufsize:v
                                                  filter:v filter:v:0)))
                           ('audio (memq option '(c:a b:a maxrate:a bufsize:a
                                                  filter:a filter:a:0)))
                           ('subtitle (memq option '(c:s metadata:s:s disposition:s)))
                           ('data (memq option '(c:d metadata:d disposition:d)))
                           (_ nil)))
                    (intern (format "%s:%d" option index)) option)))
          (push (cons scoped (cdr entry)) result))))))

(defun zr-ffmpeg--page-stream-info (page)
  "Return cached or probed stream metadata for file PAGE."
  (or (plist-get page :stream-info)
      (when (and (eq (plist-get page :kind) 'file)
                 (plist-get page :source))
        (let ((streams (zr-ffmpeg--probe-streams
                        (plist-get page :source))))
          (when streams
            (setf (plist-get page :stream-info) streams))
          streams))))

(defun zr-ffmpeg--stream-selector-count (stream info)
  "Return the number of streams selected by STREAM in metadata INFO.
Return nil when INFO is unavailable.  Optional ordinal selectors can match
zero streams, so they also require metadata for an accurate count."
  (when info
    (let ((kind (pcase (substring stream 0 1)
                  ("v" 'video) ("a" 'audio) ("s" 'subtitle) ("d" 'data)))
          (ordinal (and (string-match "\\`[vasd]:\\([0-9]+\\)\\??\\'" stream)
                        (string-to-number (match-string 1 stream)))))
      (cl-count-if
       (lambda (candidate)
         (and (eq (plist-get candidate :type) kind)
              (or (null ordinal)
                  (equal (plist-get candidate :ordinal) ordinal))))
       info))))

(defun zr-ffmpeg--subtitle-output-args (pages specs)
  "Return output args for all mapped subtitle streams in SPECS.
Known stream counts allow per-stream args in mapping order.  Unknown counts
allow only identical arguments shared by all potentially mapped subtitles."
  (let (groups)
    ;; Both direct mapping and the filter graph preserve this spec/stream
    ;; order, including interleaved primary and external subtitle inputs.
    (dolist (spec specs)
      (when-let* ((streams
                   (cl-remove-if-not
                    (lambda (stream)
                      (zr-ffmpeg--stream-selector-kind-p stream "s"))
                    (plist-get spec :streams))))
        (let* ((page (cl-find (plist-get spec :owner-id) pages
                              :key (lambda (candidate)
                                     (plist-get candidate :id))))
               (args (zr-ffmpeg--scope-output-args
                      (append (zr-ffmpeg--page-subtitle-args page)
                              (zr-ffmpeg--page-subtitle-disposition page))
                      'subtitle nil))
               (info (if (eq (plist-get spec :role) 'primary)
                         (zr-ffmpeg--page-stream-info page)
                       (zr-ffmpeg--probe-streams (plist-get spec :source)))))
          (dolist (stream streams)
            (let ((count (zr-ffmpeg--stream-selector-count stream info)))
              (unless (eql count 0)
                (push (cons count args) groups)))))))
    (setq groups (nreverse groups))
    (if (cl-some (lambda (group) (null (car group))) groups)
        (let ((args (cdar groups)))
          (unless (cl-every (lambda (group) (equal (cdr group) args)) groups)
            (user-error
             (concat "Cannot determine subtitle stream counts: "
                     "different subtitle arguments require stream metadata")))
          args)
      (let ((subtitle-index 0) result)
        (dolist (group groups result)
          (dotimes (_ (car group))
            (setq result
                  (append result
                          (zr-ffmpeg--scope-output-args
                           (cdr group) 'subtitle subtitle-index)))
            (setq subtitle-index (1+ subtitle-index))))))))

(defun zr-ffmpeg--primary-data-output-args (specs)
  "Return default copy args when primary data streams are selected."
  (when (cl-some
         (lambda (spec)
           (and (eq (plist-get spec :role) 'primary)
                (cl-some (lambda (stream)
                           (zr-ffmpeg--stream-selector-kind-p stream "d"))
                         (plist-get spec :streams))))
         specs)
    '((c:d . "copy"))))

(defun zr-ffmpeg--filtergraph (pages specs)
  "Return (FILTERGRAPH . MAPS) for PAGES and SPECS, or nil."
  (let* ((mode zr-ffmpeg--composition-mode)
         (pages (zr-ffmpeg--selected-pages pages))
         (video-pages (cl-remove-if-not
                       (lambda (page)
                         (and (zr-ffmpeg--page-effective page :video)
                              (zr-ffmpeg--stream-selectors page 'video)))
                       pages))
         (audio-pages (cl-remove-if-not
                       (lambda (page)
                         (and (zr-ffmpeg--page-effective page :audio)
                              (zr-ffmpeg--stream-selectors page 'audio)))
                       pages))
         (burn-pages (cl-remove-if-not
                      #'zr-ffmpeg--burn-subtitle-page-p pages))
         (audio-refs nil)
         (filters nil) maps)
    (when (and (not (eq mode 'separate))
               (> (length burn-pages) 1))
      (user-error "Composed output supports one burn-in subtitle source"))
    ;; Every audio-enabled page contributes its primary audio stream.  An
    ;; external microphone or file is represented by another input page.
    (dolist (page audio-pages)
      (let ((primary (zr-ffmpeg--spec-index
                      specs (plist-get page :id) 'primary)))
        (when (integerp primary)
          (push (format "%d:a:%d" primary
                        (zr-ffmpeg--selected-stream-index
                         page :audio-streams "audio"))
                audio-refs))))
    (setq audio-refs (nreverse audio-refs))
    (cl-labels
        ((vlabel (page)
           (format "%d:v:%d" (zr-ffmpeg--spec-index
                               specs (plist-get page :id) 'primary)
                   (zr-ffmpeg--selected-stream-index
                    page :video-streams "video")))
         (input-video (page) (format "[%s]" (vlabel page)))
         (input-audio (label) (format "[%s]" label))
         (add-output (filter map)
           (setq filters (append filters (list filter))
                 maps (append maps (list map)))))
      (pcase mode
        ('separate nil)
        ((or 'concat 'concat-video)
         (when video-pages
           (add-output
            (concat (mapconcat #'input-video video-pages "")
                    (format "concat=n=%d:v=1:a=0[vout]"
                            (length video-pages)))
            "[vout]"))
         (when (and (eq mode 'concat) audio-pages)
           (add-output
            (concat (mapconcat #'input-audio audio-refs "")
                    (format "concat=n=%d:v=0:a=1[aout]"
                            (length audio-refs)))
            "[aout]")))
        ('concat-audio
         (when audio-refs
           (add-output
            (concat (mapconcat #'input-audio audio-refs "")
                    (format "concat=n=%d:v=0:a=1[aout]"
                            (length audio-refs)))
            "[aout]")))
        ('amix
         (when audio-refs
           (add-output
            (concat (mapconcat #'input-audio audio-refs "")
                    (format "amix=inputs=%d:duration=longest[aout]"
                            (length audio-refs)))
            "[aout]")))
        ((or 'hstack 'vstack 'xstack)
         (when video-pages
           (let ((layout
                  (when (eq mode 'xstack)
                    (mapconcat
                     (lambda (index)
                       (if (= index 0) "0_0"
                         (format "%s_0"
                                 (mapconcat
                                  (lambda (previous)
                                    (format "w%d" previous))
                                  (number-sequence 0 (1- index)) "+"))))
                     (number-sequence 0 (1- (length video-pages))) "|"))))
             (add-output
              (concat (mapconcat #'input-video video-pages "")
                      (if layout
                          (format "xstack=inputs=%d:layout=%s[vout]"
                                  (length video-pages) layout)
                        (format "%s=inputs=%d[vout]"
                                (symbol-name mode) (length video-pages))))
              "[vout]"))))
        ('overlay
         (unless (>= (length video-pages) 2)
           (user-error "Overlay composition needs at least two video pages"))
         (add-output
          (concat (input-video (nth 0 video-pages))
                  (input-video (nth 1 video-pages)) "overlay[vout]")
          "[vout]"))
        (_ (user-error "Unsupported composition mode: %s" mode)))
      ;; Burn-in is a video operation.  In separate mode each page uses its
      ;; own subtitle source.  In a composed mode the first configured burn-in
      ;; source is applied to the combined video result.
      (if (eq mode 'separate)
          (dolist (page burn-pages)
            (let ((label (format "[v%d]" (plist-get page :id))))
              (setq filters
                    (append filters
                            (list
                             (format "[%s]%s%s" (vlabel page)
                                     (zr-ffmpeg--subtitle-filter
                                      (zr-ffmpeg--subtitle-source page))
                                     label))))))
        (when-let* ((burn-page (car burn-pages)))
          (unless (member "[vout]" maps)
            (user-error "Burn-in requires a composed video output"))
          (setq filters
                (append filters
                        (list
                         (format "[vout]%s[vburn]"
                                 (zr-ffmpeg--subtitle-filter
                                  (zr-ffmpeg--subtitle-source burn-page))))))
          (setq maps (mapcar (lambda (map)
                               (if (equal map "[vout]") "[vburn]" map))
                             maps))))
      ;; Streams not consumed by a composition remain direct output streams.
      ;; In separate mode a burned video replaces only its corresponding map.
      (when (and filters (eq mode 'separate))
        (setq maps
              (cl-loop
               for spec in specs
               for index from 0
               for owner = (plist-get spec :owner-id)
               for page = (cl-find owner pages
                                   :key (lambda (candidate)
                                          (plist-get candidate :id)))
               for burn-video = (and page
                                     (eq (plist-get spec :role) 'primary)
                                     (zr-ffmpeg--burn-subtitle-page-p page))
               append
               (mapcar
                (lambda (stream)
                  (if (and burn-video
                           (zr-ffmpeg--stream-selector-kind-p stream "v"))
                      (format "[v%d]" owner)
                    (format "%d:%s" index stream)))
                (plist-get spec :streams)))))
      (when (and filters (not (eq mode 'separate)))
        (setq maps
              (append
               maps
               (cl-loop for spec in specs
                        for index from 0
                        append
                        (cl-loop for stream in (plist-get spec :streams)
                                 when (or (zr-ffmpeg--stream-selector-kind-p
                                           stream "s")
                                          (zr-ffmpeg--stream-selector-kind-p
                                           stream "d"))
                                 collect (format "%d:%s" index stream))))))
      (when filters
        (cons (mapconcat #'identity filters ";") maps)))))

(defun zr-ffmpeg--validate-output (specs output)
  "Reject OUTPUT when it overwrites a local input in SPECS."
  (when (zr-ffmpeg--local-path-p output)
    (let ((target (file-truename output)))
      (dolist (spec specs)
        (when-let* ((file (plist-get spec :file)))
          (when (equal target (file-truename file))
            (user-error "Input and output are identical: %s" file)))))))

(defun zr-ffmpeg--copy-video-p (page)
  "Return non-nil when PAGE requests stream-copy video output."
  (cl-some (lambda (entry)
             (and (consp entry)
                  (memq (car entry) '(c:v codec:v))
                  (equal (format "%s" (cdr entry)) "copy")))
           (zr-ffmpeg--page-video-args page)))

(defun zr-ffmpeg--validate-subtitles (pages)
  "Validate subtitle configuration for PAGES."
  (let ((burn-pages
         (cl-remove-if-not #'zr-ffmpeg--burn-subtitle-page-p pages)))
    (dolist (page burn-pages)
      (unless (zr-ffmpeg--page-effective page :video)
        (user-error "Burn-in requires video on page %s"
                    (plist-get page :id)))
      (zr-ffmpeg--burn-video-index page)
      (unless (zr-ffmpeg--local-path-p (zr-ffmpeg--subtitle-source page))
        (user-error "Burn-in subtitle source must be a local file on page %s"
                    (plist-get page :id))))
    (if (eq zr-ffmpeg--composition-mode 'separate)
        (dolist (page burn-pages)
          (when (zr-ffmpeg--copy-video-p page)
            (user-error "Burn-in requires video encoding on page %s, not copy"
                        (plist-get page :id))))
      (when-let* ((video-page
                  (and burn-pages
                       (cl-find-if
                        (lambda (page)
                          (zr-ffmpeg--page-effective page :video))
                        pages))))
        (when (zr-ffmpeg--copy-video-p video-page)
          (user-error "Burn-in requires video encoding for composed output, not copy"))))))

(defun zr-ffmpeg--page-output-args (pages composed video-output audio-output specs)
  "Collect output stream arguments from PAGES and SPECS.
VIDEO-OUTPUT and AUDIO-OUTPUT describe streams produced by the task."
  (let (result)
    (if composed
        (progn
          (when video-output
            (when-let* ((page (cl-find-if
                               (lambda (candidate)
                                 (zr-ffmpeg--page-effective candidate :video))
                               pages)))
              (setq result
                    (append result (zr-ffmpeg--page-video-args page)))))
          (when audio-output
            (when-let* ((page (cl-find-if
                               (lambda (candidate)
                                 (zr-ffmpeg--page-effective candidate :audio))
                               pages)))
              (setq result
                    (append result (zr-ffmpeg--page-audio-args page))))))
      (let ((video-index 0) (audio-index 0))
        (dolist (page pages)
          (when (and video-output
                     (zr-ffmpeg--page-effective page :video))
            (setq result
                  (append result
                          (zr-ffmpeg--scope-output-args
                           (zr-ffmpeg--page-video-args page) 'video video-index)))
            (setq video-index (1+ video-index)))
          (when (and audio-output
                     (zr-ffmpeg--page-effective page :audio))
            (setq result
                  (append result
                          (zr-ffmpeg--scope-output-args
                           (zr-ffmpeg--page-audio-args page) 'audio audio-index)))
            (setq audio-index (1+ audio-index))))))
    (append result
            (zr-ffmpeg--subtitle-output-args pages specs)
            (zr-ffmpeg--primary-data-output-args specs))))

(defun zr-ffmpeg--build-command (&optional pages output)
  "Build one complete FFmpeg argv for PAGES and OUTPUT."
  (zr-ffmpeg--ensure-state)
  (let* ((pages (or pages zr-ffmpeg--inputs-state))
         (output (or output (zr-ffmpeg--output-for-input)))
         (selected (zr-ffmpeg--selected-pages pages))
         (specs (zr-ffmpeg--input-specs selected))
         (graph (zr-ffmpeg--filtergraph pages specs))
         (composed (not (eq zr-ffmpeg--composition-mode 'separate)))
         (graph-maps (and graph (cdr graph)))
         (video-output (if composed
                           (or (member "[vout]" graph-maps)
                               (member "[vburn]" graph-maps))
                         (cl-some
                          (lambda (spec)
                            (cl-some (lambda (stream)
                                       (zr-ffmpeg--stream-selector-kind-p
                                        stream "v"))
                                     (plist-get spec :streams)))
                          specs)))
         (audio-output (if composed
                           (member "[aout]" graph-maps)
                         (cl-some
                          (lambda (spec)
                            (cl-some (lambda (stream)
                                       (zr-ffmpeg--stream-selector-kind-p
                                        stream "a"))
                                     (plist-get spec :streams)))
                          specs)))
         (resolution (zr-ffmpeg--output-resolution (car selected)))
         (global-args
          (zr-ffmpeg--args->argv
           (or zr-ffmpeg--global-args
               (apply #'append
                      (mapcar (lambda (page)
                                (zr-ffmpeg--argument-list
                                 :global-args page)) selected))
               zr-ffmpeg-global-args)))
         (page-output-args (zr-ffmpeg--page-output-args
                            selected composed video-output audio-output specs))
         (output-args
          (zr-ffmpeg--args->argv
           (append page-output-args
                   (apply #'append
                          (mapcar (lambda (page)
                                    (zr-ffmpeg--argument-list
                                     :output-args page)) selected))
                   (or zr-ffmpeg--output-args
                       zr-ffmpeg-output-args)))))
    (zr-ffmpeg--validate-subtitles selected)
    (zr-ffmpeg--validate-output specs output)
    (append (list zr-ffmpeg-program "-loglevel" zr-ffmpeg-log-level)
            global-args
            (zr-ffmpeg--build-input-args specs)
            (when graph (list "-filter_complex" (car graph)))
            (if graph
                (apply #'append
                       (mapcar (lambda (map) (list "-map" map)) (cdr graph)))
              (zr-ffmpeg--mapping-args specs))
            output-args
            (when zr-ffmpeg--output-framerate
              (list "-r" (format "%s" zr-ffmpeg--output-framerate)))
            (when resolution
              (list "-s:v" (format "%dx%d" (car resolution)
                                      (cdr resolution))))
            (when zr-ffmpeg--output-format
              (list "-f" zr-ffmpeg--output-format))
            (list output))))

(defun zr-ffmpeg--command (&optional input output)
  "Build the current task command.
INPUT may be a page or source for programmatic callers; nil renders the task."
  (cond
   ((and (listp input) (plist-get input :id))
    (zr-ffmpeg--build-command (list input) output))
   ((stringp input)
    (let ((page (copy-tree (zr-ffmpeg--current-page))))
      (setf (plist-get page :kind) 'file
            (plist-get page :source) input
            (plist-get page :stream-info) nil)
      (zr-ffmpeg--build-command (list page) output)))
   (t (zr-ffmpeg--build-command nil output))))

(defun zr-ffmpeg--commands ()
  "Return the single complete task command as a list."
  (list (zr-ffmpeg--command)))

;;; History, execution, and previews

(defun zr-ffmpeg--shell-quote (arg)
  "Quote ARG as a shell argument."
  (shell-quote-argument arg))

(defun zr-ffmpeg--command-string (args)
  "Return shell representation of ARGS."
  (mapconcat #'zr-ffmpeg--shell-quote args " "))

(defun zr-ffmpeg--preview-command ()
  "Return the complete task command as a shell string."
  (zr-ffmpeg--command-string (zr-ffmpeg--command)))

(defun zr-ffmpeg--start-command (args)
  "Start ARGS and record the exact command string."
  (let* ((command (if (stringp args) args (zr-ffmpeg--command-string args)))
         (buffer (get-buffer-create "*zr-ffmpeg*")))
    (setq zr-ffmpeg-command-history
          (cons command (delete command zr-ffmpeg-command-history)))
    (message "%s" command)
    (if (stringp args)
        (start-process-shell-command "zr-ffmpeg" buffer args)
      (apply #'start-process "zr-ffmpeg" buffer args))))

(defun zr-ffmpeg--edit-command ()
  "Read a shell command using the current task or command history.
If the current task is incomplete, use the most recently executed command as
the initial value instead of failing before the minibuffer opens."
  (let* ((initial
          (condition-case nil
              (zr-ffmpeg--command-string (zr-ffmpeg--command))
            (error (or (car zr-ffmpeg-command-history) ""))))
         (command (read-shell-command "FFmpeg command: " initial
                                      'zr-ffmpeg-command-history)))
    (when (string-empty-p (string-trim command))
      (user-error "FFmpeg command is empty; no command history is available"))
    command))

(defun zr-ffmpeg-run (&optional edit)
  "Execute the complete task, optionally editing its command first."
  (interactive "P")
  (let ((command (if edit
                     (zr-ffmpeg--edit-command)
                   (zr-ffmpeg--command))))
    (zr-ffmpeg--start-command command)))

(defun zr-ffmpeg-edit-and-run ()
  "Edit and execute the complete task command."
  (interactive)
  (zr-ffmpeg-run t))

(defun zr-ffmpeg-preview ()
  "Preview the complete task command."
  (interactive)
  (message "%s" (zr-ffmpeg--preview-command)))

(defun zr-ffmpeg-preview-page ()
  "Preview the effective command fragment for the current input page."
  (interactive)
  (message "Input %d/%d: %s" (zr-ffmpeg--page-index)
           (length zr-ffmpeg--inputs-state)
           (zr-ffmpeg--command-string
            (zr-ffmpeg--build-command (list (zr-ffmpeg--current-page))))))

;;; Transient setters

(defun zr-ffmpeg--set-preset (_variable value)
  "Persist preset VALUE for the current page."
  (zr-ffmpeg--page-set :preset value)
  ;; Changing the preset updates the mirror variables, but the
  ;; transient objects cache their `value' slot at setup time
  ;; (transient-lisp-variable's `format-value' reads the object slot,
  ;; not the variable).  Re-run `transient-init-value' so
  ;; Video/Audio/Subtitle mode refresh in the panel.
  (when transient--suffixes
    (mapc #'transient-init-value transient--suffixes)))

(defun zr-ffmpeg--read-preset (prompt _initial _history)
  "Read a preset."
  (intern (completing-read prompt (zr-ffmpeg--preset-candidates)
                           nil t nil nil
                           (symbol-name (plist-get (zr-ffmpeg--current-page)
                                                   :preset)))))

(defun zr-ffmpeg--set-page-toggle (key value)
  "Set boolean page override KEY to VALUE."
  (zr-ffmpeg--page-override key value))

(defun zr-ffmpeg--toggle-value (key)
  "Return effective boolean page value KEY."
  (and (zr-ffmpeg--page-effective (zr-ffmpeg--current-page) key) t))

(defun zr-ffmpeg--read-subtitle-mode (prompt _initial _history)
  "Read subtitle mode."
  (intern (completing-read prompt '("soft" "soft-default" "burn-in") nil t nil nil
                           (symbol-name
                            (or (zr-ffmpeg--page-effective
                                 (zr-ffmpeg--current-page) :subtitle-mode)
                                'soft)))))

(defun zr-ffmpeg--set-argument-list (scope label key)
  "Read structured argument data for SCOPE with LABEL and KEY.
The value is read as Lisp: strings represent flags and `(symbol . value)'
conses represent options with values."
  (let* ((page (zr-ffmpeg--current-page))
         (current (pcase scope
                    ('page (zr-ffmpeg--argument-list key page))
                    ('global (or zr-ffmpeg--global-args zr-ffmpeg-global-args))
                    ('output (or zr-ffmpeg--output-args zr-ffmpeg-output-args))))
         (value (read-string (format "%s (Lisp): " label)
                             (prin1-to-string current)))
         (parsed (condition-case err
                     (read value)
                   (error (user-error "Invalid argument list: %s"
                                     (error-message-string err))))))
    (unless (listp parsed)
      (user-error "Argument list must be a list"))
    (pcase scope
      ('page (zr-ffmpeg--page-override key parsed))
      ('global (setq zr-ffmpeg--global-args parsed))
      ('output (setq zr-ffmpeg--output-args parsed)))
    (transient-setup)))

(defun zr-ffmpeg-set-input-args ()
  "Set input arguments for the current page."
  (interactive)
  (zr-ffmpeg--set-argument-list 'page "Input FFmpeg args" :input-args))

(defun zr-ffmpeg-set-video-args ()
  "Set video arguments for the current page."
  (interactive)
  (zr-ffmpeg--set-argument-list 'page "Video FFmpeg args" :video-args))

(defun zr-ffmpeg-set-audio-args ()
  "Set audio arguments for the current page."
  (interactive)
  (zr-ffmpeg--set-argument-list 'page "Audio FFmpeg args" :audio-args))

(defun zr-ffmpeg-set-subtitle-args ()
  "Set soft subtitle arguments for the current page."
  (interactive)
  (zr-ffmpeg--set-argument-list 'page "Subtitle FFmpeg args" :subtitle-args))

(defun zr-ffmpeg-set-global-args ()
  "Set task global arguments."
  (interactive)
  (zr-ffmpeg--set-argument-list 'global "Global FFmpeg args" :global-args))

(defun zr-ffmpeg-set-output-args ()
  "Set task output arguments."
  (interactive)
  (zr-ffmpeg--set-argument-list 'output "Output FFmpeg args" :output-args))

(defun zr-ffmpeg-set-composition ()
  "Select the task composition mode."
  (interactive)
  (setq zr-ffmpeg--composition-mode
        (intern (completing-read
                 "Composition: "
                 '("separate" "concat" "concat-video" "concat-audio"
                   "amix" "hstack" "vstack" "xstack" "overlay")
                 nil t nil nil (symbol-name zr-ffmpeg--composition-mode))))
  (transient-setup))

(defun zr-ffmpeg-set-composition-inputs ()
  "Choose which input pages participate in the composition.
An empty selection means all pages in their current order."
  (interactive)
  (let* ((choices (cl-loop for page in zr-ffmpeg--inputs-state
                           for index from 1
                           collect (cons (format "%d: %s" index
                                                  (or (plist-get page :source)
                                                      (symbol-name
                                                       (plist-get page :kind))))
                                         (plist-get page :id))))
         (selected (completing-read-multiple
                    "Composition inputs (empty = all): " choices nil nil)))
    (setq zr-ffmpeg--composition-input-ids
          (unless (null selected)
            (mapcar (lambda (choice) (cdr (assoc choice choices))) selected)))
    (transient-setup)))

(defun zr-ffmpeg-set-resolution ()
  "Set task output resolution."
  (interactive)
  (setq zr-ffmpeg-output-resolution
        (let* ((current (and zr-ffmpeg-output-resolution
                             (format "%d x %d"
                                     (car zr-ffmpeg-output-resolution)
                                     (cdr zr-ffmpeg-output-resolution))))
               (value (read-string "Resolution (WIDTHxHEIGHT, empty clears): "
                                   (or current ""))))
          (unless (string-empty-p value)
            (if (string-match "\\`\\([1-9][0-9]*\\)x[ \\t]*\\([1-9][0-9]*\\)\\'"
                             value)
                (cons (string-to-number (match-string 1 value))
                      (string-to-number (match-string 2 value)))
              (user-error "Resolution must look like WIDTHxHEIGHT")))))
  (when zr-ffmpeg-output-resolution
    (zr-ffmpeg--validate-resolution zr-ffmpeg-output-resolution))
  (transient-setup))

(defun zr-ffmpeg-set-framerate ()
  "Set task output framerate."
  (interactive)
  (let ((value (read-string "Output framerate (empty clears): "
                            (or (and zr-ffmpeg--output-framerate
                                     (format "%s" zr-ffmpeg--output-framerate))
                                ""))))
    (setq zr-ffmpeg--output-framerate
          (unless (string-empty-p value) (string-to-number value))))
  (transient-setup))

(defun zr-ffmpeg-set-target ()
  "Set task output target."
  (interactive)
  (setq zr-ffmpeg--output-target
        (zr-ffmpeg--read-source "Output target: " zr-ffmpeg--output-target t))
  (transient-setup))

(defun zr-ffmpeg-set-format ()
  "Set task output format."
  (interactive)
  (setq zr-ffmpeg--output-format
        (let ((value (completing-read "Output format: "
                                      '("rtsp" "flv" "whip" "mpegts"
                                        "matroska" "mp4" "mov" "webm")
                                      nil nil zr-ffmpeg--output-format)))
          (unless (string-empty-p value) value)))
  (transient-setup))

;;; Reset operations

(defun zr-ffmpeg-reset-page ()
  "Clear current page overrides while preserving its source."
  (interactive)
  (zr-ffmpeg--page-set :overrides nil)
  (transient-setup))

(defun zr-ffmpeg-reset-all ()
  "Clear all pages and task output overrides."
  (interactive)
  (setq zr-ffmpeg--inputs-state (list (zr-ffmpeg--new-page))
        zr-ffmpeg--current-input-id 1
        zr-ffmpeg--composition-mode 'separate
        zr-ffmpeg--composition-input-ids nil
        zr-ffmpeg--output-format nil
        zr-ffmpeg--output-target nil
        zr-ffmpeg--output-framerate nil
        zr-ffmpeg--global-args nil
        zr-ffmpeg--output-args nil
        zr-ffmpeg-output-resolution nil)
  (zr-ffmpeg--sync-page-vars)
  (transient-setup))

(defalias 'zr-ffmpeg--reset-overrides #'zr-ffmpeg-reset-page)

;;; Transient UI

(defclass zr-ffmpeg-short-variable (transient-lisp-variable) ()
  "Transient variable with a bounded display value.")

(cl-defmethod transient-format-value ((object zr-ffmpeg-short-variable))
  (let ((value (oref object value)))
    (propertize (if (> (length (format "%s" value)) 28)
                   (concat (substring (format "%s" value) 0 25) "...")
                 (format "%s" value))
                'face 'transient-value)))

(transient-define-infix zr-ffmpeg-preset-infix ()
  :class 'transient-lisp-variable :key "Q" :description "Preset"
  :variable 'zr-ffmpeg--current-preset :reader #'zr-ffmpeg--read-preset
  :set-value #'zr-ffmpeg--set-preset)

(transient-define-infix zr-ffmpeg-video-toggle-infix ()
  :class 'transient-lisp-variable :key "V" :description "Video"
  :variable 'zr-ffmpeg--video-toggle
  :reader (lambda (_prompt _initial _history)
            (not (zr-ffmpeg--toggle-value :video)))
  :set-value (lambda (_variable value)
               (zr-ffmpeg--set-page-toggle :video value)))

(transient-define-infix zr-ffmpeg-audio-toggle-infix ()
  :class 'transient-lisp-variable :key "A" :description "Audio"
  :variable 'zr-ffmpeg--audio-toggle
  :reader (lambda (_prompt _initial _history)
            (not (zr-ffmpeg--toggle-value :audio)))
  :set-value (lambda (_variable value)
               (zr-ffmpeg--set-page-toggle :audio value)))

(transient-define-infix zr-ffmpeg-subtitle-mode-infix ()
  :class 'transient-lisp-variable :key "m" :description "Subtitle mode"
  :variable 'zr-ffmpeg--subtitle-mode
  :reader #'zr-ffmpeg--read-subtitle-mode
  :set-value (lambda (_variable value)
               (zr-ffmpeg--page-override :subtitle-mode value)))

(transient-define-prefix zr-ffmpeg-menu ()
  "Configure and run a multi-input FFmpeg task."
  [["Input page"
    ("n" "Next" zr-ffmpeg-next-input :transient t)
    ("p" "Previous" zr-ffmpeg-previous-input :transient t)
    ("j" "Jump" zr-ffmpeg-select-input :transient t)
    ("<" "Move up" zr-ffmpeg-move-input-up :transient t)
    (">" "Move down" zr-ffmpeg-move-input-down :transient t)
    ("+" "Add" zr-ffmpeg-add-input :transient t)
    ("d" "Delete" zr-ffmpeg-delete-input :transient t)
    ("c" "Copy" zr-ffmpeg-duplicate-input :transient t)]
   ["Input"
    ("I" "Input" zr-ffmpeg-set-input :transient t)
    ("M" "Monitor" zr-ffmpeg-set-monitor :transient t)
    ("W" "Window" zr-ffmpeg-set-window :transient t)
    ("D" "Audio device" zr-ffmpeg-set-audio-device :transient t)
    ("S" "Subtitle source" zr-ffmpeg-set-subtitle-source :transient t)
    ("i" "Input args" zr-ffmpeg-set-input-args :transient t)]
   ["Preset / Process"
    (zr-ffmpeg-preset-infix)
    (zr-ffmpeg-video-toggle-infix)
    (zr-ffmpeg-audio-toggle-infix)
    (zr-ffmpeg-subtitle-mode-infix)
    ("k" "Stream selection" zr-ffmpeg-set-stream-selection :transient t)
    ("v" "Video args" zr-ffmpeg-set-video-args :transient t)
    ("a" "Audio args" zr-ffmpeg-set-audio-args :transient t)
    ("s" "Subtitle args" zr-ffmpeg-set-subtitle-args :transient t)]]
  [["Output"
    ("C" "Composition" zr-ffmpeg-set-composition :transient t)
    ("J" "Composition inputs" zr-ffmpeg-set-composition-inputs :transient t)
    ("r" "Framerate" zr-ffmpeg-set-framerate :transient t)
    ("R" "Resolution" zr-ffmpeg-set-resolution :transient t)
    ("f" "Format" zr-ffmpeg-set-format :transient t)
    ("t" "Target" zr-ffmpeg-set-target :transient t)
    ("o" "Output args" zr-ffmpeg-set-output-args :transient t)
    ("g" "Global args" zr-ffmpeg-set-global-args :transient t)]
   ["Run"
    ("RET" "Run" zr-ffmpeg-run :transient nil)
    ("e" "Edit & run" zr-ffmpeg-edit-and-run :transient nil)
    ("0" "Reset page" zr-ffmpeg-reset-page :transient t)
    ("!" "Reset task" zr-ffmpeg-reset-all :transient t)
    ("?" "Preview page" zr-ffmpeg-preview-page :transient t)
    ("SPC" "Preview task" zr-ffmpeg-preview :transient t)]])

;;;###autoload
(defun zr-ffmpeg ()
  "Open the FFmpeg transient."
  (interactive)
  (zr-ffmpeg--ensure-state)
  (zr-ffmpeg--sync-page-vars)
  (zr-ffmpeg-menu))

(provide 'zr-ffmpeg)

;;; zr-ffmpeg.el ends here
