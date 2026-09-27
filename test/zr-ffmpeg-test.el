;;; zr-ffmpeg-test.el --- Tests for zr-ffmpeg -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for FFmpeg subtitle input, mapping, and burn-in handling, and
;; for remote files.  Remote integration tests run FFmpeg and curl against
;; the WebDAV fixture and, when rclone is available, a local rcd.

;;; Code:

(require 'ert)

(defconst zr-ffmpeg-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(dolist (file '("../zr-ffmpeg.el" "../zr-tramp-webdav.el" "../zr-tramp-rcrc.el"))
  (load (expand-file-name file zr-ffmpeg-test--directory) nil 'nomessage))

(declare-function zr-ffmpeg--new-page "zr-ffmpeg")
(declare-function zr-ffmpeg--build-command "zr-ffmpeg")
(declare-function zr-ffmpeg--input-specs "zr-ffmpeg")
(declare-function zr-ffmpeg--filtergraph "zr-ffmpeg")

(defvar zr-ffmpeg--inputs-state)
(defvar zr-ffmpeg--current-input-id)
(defvar zr-ffmpeg--composition-mode)
(defvar zr-ffmpeg--composition-input-ids)
(defvar zr-ffmpeg--output-format)
(defvar zr-ffmpeg--output-target)
(defvar zr-ffmpeg--output-framerate)
(defvar zr-ffmpeg--global-args)
(defvar zr-ffmpeg--output-args)
(defvar zr-ffmpeg-output-resolution)

(defun zr-ffmpeg-test--page (id source &optional subtitle mode codec)
  "Create test page ID for SOURCE with SUBTITLE, MODE, and CODEC."
  (let ((page (zr-ffmpeg--new-page id))
        overrides)
    (setf (plist-get page :source) source
          (plist-get page :subtitle-source) subtitle
          ;; Existing tests focus on external subtitle behavior.  Internal
          ;; subtitle selection is covered by dedicated tests below.
          (plist-get page :subtitle-streams) nil
          (plist-get page :data-streams) nil)
    (when mode
      (setq overrides (plist-put overrides :subtitle-mode mode)))
    (when codec
      (setq overrides
            (plist-put overrides :subtitle-args `((c:s . ,codec)))))
    (setf (plist-get page :overrides) overrides)
    page))

(defun zr-ffmpeg-test--option-values (option argv)
  "Return values following every OPTION in ARGV."
  (let (values)
    (while argv
      (when (and (equal (car argv) option) (cdr argv))
        (push (cadr argv) values))
      (setq argv (cdr argv)))
    (nreverse values)))

(defmacro zr-ffmpeg-test--with-task (pages mode &rest body)
  "Evaluate BODY with PAGES and composition MODE as isolated task state."
  (declare (indent 2) (debug (form form body)))
  `(let ((zr-ffmpeg--inputs-state ,pages)
         (zr-ffmpeg--current-input-id 1)
         (zr-ffmpeg--composition-mode ,mode)
         (zr-ffmpeg--composition-input-ids nil)
         (zr-ffmpeg--output-format nil)
         (zr-ffmpeg--output-target nil)
         (zr-ffmpeg--output-framerate nil)
         (zr-ffmpeg--global-args nil)
         (zr-ffmpeg--output-args nil)
         (zr-ffmpeg-output-resolution nil))
     ;; Fixture subtitle files contain one stream.  Primary metadata comes
     ;; from each page's cache; tests can override this stub for other inputs.
     (cl-letf (((symbol-function 'zr-ffmpeg--probe-streams)
                (lambda (source)
                  (when (cl-find source zr-ffmpeg--inputs-state
                                 :test #'equal
                                 :key (lambda (page)
                                        (plist-get page :subtitle-source)))
                    '((:index 0 :type subtitle :ordinal 0))))))
       ,@body)))

(ert-deftest zr-ffmpeg-test-stream-selector-states ()
  "Stream selectors should distinguish all, none, and ordinals."
  (let ((page (zr-ffmpeg--new-page 1)))
    (should (equal (zr-ffmpeg--stream-selectors page 'video)
                   '("v?")))
    (should (equal (zr-ffmpeg--stream-selectors page 'subtitle)
                   '("s?")))
    (should-not (zr-ffmpeg--stream-selectors page 'data))
    (setf (plist-get page :subtitle-streams) nil
          (plist-get page :data-streams) '(0 2))
    (should-not (zr-ffmpeg--stream-selectors page 'subtitle))
    (should (equal (zr-ffmpeg--stream-selectors page 'data)
                   '("d:0?" "d:2?")))))

(ert-deftest zr-ffmpeg-test-probe-url-and-type-ordinals ()
  "Probe should accept URLs and derive ordinals per stream type."
  (let ((json
         "{\"streams\":[{\"index\":0,\"codec_type\":\"video\",\"codec_name\":\"hevc\"},{\"index\":1,\"codec_type\":\"audio\",\"codec_name\":\"flac\"},{\"index\":2,\"codec_type\":\"subtitle\",\"codec_name\":\"pgs\"},{\"index\":3,\"codec_type\":\"subtitle\",\"codec_name\":\"pgs\"},{\"index\":4,\"codec_type\":\"data\",\"codec_name\":\"bin_data\"}]}" )
        (seen nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) t))
              ((symbol-function 'call-process)
               (lambda (_program _infile _destination _display &rest args)
                 (push (car (last args)) seen)
                 (insert json)
                 (goto-char (point-min))
                 0)))
      (let ((streams (zr-ffmpeg--probe-streams
                      "https://example.com/video.mkv")))
        (should (equal (car seen) "https://example.com/video.mkv"))
        (should (equal (mapcar (lambda (stream)
                                 (list (plist-get stream :index)
                                       (plist-get stream :type)
                                       (plist-get stream :ordinal)))
                               streams)
                       '((0 video 0) (1 audio 0) (2 subtitle 0)
                         (3 subtitle 1) (4 data 0)))))
      (should (zr-ffmpeg--probe-streams "/tmp/video.mkv"))
      (should-not (zr-ffmpeg--probe-streams "-")))))

(ert-deftest zr-ffmpeg-test-probe-failure-returns-nil ()
  "Probe failures and malformed JSON should be reported as unavailable."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_program) t))
            ((symbol-function 'call-process)
             (lambda (&rest _args) 1)))
    (should-not (zr-ffmpeg--probe-streams "/tmp/video.mkv")))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_program) t))
            ((symbol-function 'call-process)
             (lambda (_program _infile _destination _display &rest _args)
               (insert "not json")
               (goto-char (point-min))
               0)))
    (should-not (zr-ffmpeg--probe-streams "https://example.com/video.mkv"))))

(ert-deftest zr-ffmpeg-test-url-input-spec-preserves-source ()
  "URL file sources should remain URLs in expanded input specs."
  (let ((page (zr-ffmpeg--new-page 1)))
    (setf (plist-get page :source) "https://example.com/video.mkv"
          (plist-get page :subtitle-streams) nil
          (plist-get page :data-streams) nil)
    (let ((spec (car (zr-ffmpeg--input-specs (list page)))))
      (should (equal (plist-get spec :source)
                     "https://example.com/video.mkv"))
      (should-not (plist-get spec :file)))))

(ert-deftest zr-ffmpeg-test-command-source-clears-stream-info-cache ()
  "Programmatic source replacement must not reuse stale probe metadata."
  (let ((page (zr-ffmpeg--new-page 1)))
    (setf (plist-get page :source) "/tmp/old.mkv"
          (plist-get page :stream-info)
          '((:index 0 :type video :ordinal 0)))
    (zr-ffmpeg-test--with-task (list page) 'separate
      (let (built-page)
        (cl-letf (((symbol-function 'zr-ffmpeg--build-command)
                   (lambda (pages _output)
                     (setq built-page (car pages))
                     '("ffmpeg")))
                  ((symbol-function 'zr-ffmpeg--output-for-input)
                   (lambda (&rest _args) "/tmp/out.mkv")))
          (zr-ffmpeg--command "https://example.com/new.mkv")
          (should (equal (plist-get built-page :source)
                         "https://example.com/new.mkv"))
          (should-not (plist-get built-page :stream-info)))))))

(ert-deftest zr-ffmpeg-test-stream-selection-ui-stores-ordinals ()
  "The stream selection UI should store type-relative ordinals."
  (let* ((page (zr-ffmpeg--new-page 1))
         (responses (list nil nil '("2: pgs (jpn)") '("4: bin_data")))
         (streams '((:index 0 :ordinal 0 :type video :codec "hevc")
                    (:index 1 :ordinal 0 :type audio :codec "flac")
                    (:index 2 :ordinal 0 :type subtitle :codec "pgs"
                             :language "jpn")
                    (:index 4 :ordinal 0 :type data :codec "bin_data"))))
    (setf (plist-get page :source) "/tmp/video.mkv")
    (zr-ffmpeg-test--with-task (list page) 'separate
      (cl-letf (((symbol-function 'zr-ffmpeg--probe-streams)
                 (lambda (_source) streams))
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _args) (pop responses)))
                ((symbol-function 'transient-setup)
                 (lambda (&rest _args) nil)))
        (zr-ffmpeg-set-stream-selection)
        (should (equal (plist-get page :subtitle-streams) '(0)))
        (should (equal (plist-get page :data-streams) '(0)))))))

(ert-deftest zr-ffmpeg-test-default-and-explicit-internal-stream-maps ()
  "Subtitle defaults to all, while data defaults to none."
  (let ((page (zr-ffmpeg--new-page 1)))
    (setf (plist-get page :source) "/tmp/v1.mkv")
    (zr-ffmpeg-test--with-task (list page) 'separate
      (let ((argv (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("0:v?" "0:a?" "0:s?")))
        (should-not (member "0:d?" argv)))
      (setf (plist-get page :subtitle-streams) '(0 1)
            (plist-get page :data-streams) '(0))
      (let ((argv (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("0:v?" "0:a?" "0:s:0?" "0:s:1?" "0:d:0?")))
        (should (equal (zr-ffmpeg-test--option-values "-c:d" argv)
                       '("copy"))))
      (setf (plist-get page :subtitle-streams) nil
            (plist-get page :data-streams) nil)
      (let ((argv (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("0:v?" "0:a?")))))))

(ert-deftest zr-ffmpeg-test-internal-subtitles-preserve-external-output-index ()
  "All internal subtitles get args before the external subtitle's index."
  (let ((page (zr-ffmpeg-test--page
               1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft-default "mov_text")))
    (setf (plist-get page :subtitle-streams) 'all
          (plist-get page :stream-info)
          '((:index 0 :type video :ordinal 0)
            (:index 1 :type audio :ordinal 0)
            (:index 2 :type subtitle :ordinal 0)
            (:index 3 :type subtitle :ordinal 1)))
    (dolist (mode '(separate concat))
      (zr-ffmpeg-test--with-task (list page) mode
        (let ((argv (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")))
          (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                         (if (eq mode 'separate)
                             '("0:v?" "0:a?" "0:s?" "1:s:0?")
                           '("[vout]" "[aout]" "0:s?" "1:s:0?"))))
          (dotimes (index 3)
            (should (equal (zr-ffmpeg-test--option-values
                            (format "-c:s:%d" index) argv)
                           '("mov_text")))
            (should (equal (zr-ffmpeg-test--option-values
                            (format "-disposition:s:%d" index) argv)
                           '("default"))))
          (should-not (member "-c:s" argv))
          (should-not (member "-c:s:3" argv)))))))

(ert-deftest zr-ffmpeg-test-internal-subtitle-uses-copy-arg ()
  "An internal-only selection uses its output index for copy and default."
  (let ((page (zr-ffmpeg-test--page 1 "/tmp/multi.mkv")))
    (setf (plist-get page :subtitle-streams) '(1)
          (plist-get page :stream-info)
          '((:index 0 :type video :ordinal 0)
            (:index 1 :type audio :ordinal 0)
            (:index 2 :type subtitle :ordinal 0)
            (:index 3 :type subtitle :ordinal 1)))
    (dolist (mode '(separate concat))
      (zr-ffmpeg-test--with-task (list page) mode
        (let ((argv (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")))
          (should (member "0:s:1?"
                          (zr-ffmpeg-test--option-values "-map" argv)))
          (should (equal (zr-ffmpeg-test--option-values "-c:s:0" argv)
                         '("copy")))
          (should (equal (zr-ffmpeg-test--option-values
                          "-disposition:s:0" argv)
                         '("default")))
          (should-not (member "-c:s" argv))
          (should-not (member "-c:s:1" argv)))))))

(ert-deftest zr-ffmpeg-test-mixed-subtitles-follow-map-order ()
  "Each page's internal and external subtitle args follow interleaved maps."
  (let* ((page1 (zr-ffmpeg-test--page
                 1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft-default "mov_text"))
         (page2 (zr-ffmpeg-test--page
                 2 "/tmp/v2.mkv" "/tmp/s2.ass" 'soft "webvtt"))
         (pages (list page1 page2)))
    (dolist (page pages)
      (setf (plist-get page :stream-info)
            '((:index 0 :type video :ordinal 0)
              (:index 1 :type audio :ordinal 0)
              (:index 2 :type subtitle :ordinal 0)
              (:index 3 :type subtitle :ordinal 1))))
    (setf (plist-get page1 :subtitle-streams) '(1)
          (plist-get page2 :subtitle-streams) '(0)
          (plist-get page1 :overrides)
          '(:subtitle-mode soft-default
            :subtitle-args ((c:s . "mov_text") (metadata:s . "language=eng")))
          (plist-get page2 :overrides)
          '(:subtitle-mode soft
            :subtitle-args ((c:s . "webvtt") (metadata:s:s . "language=jpn"))))
    (dolist (mode '(separate concat))
      (zr-ffmpeg-test--with-task pages mode
        (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
          (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                         (if (eq mode 'separate)
                             '("0:v?" "0:a?" "0:s:1?" "1:s:0?"
                               "2:v?" "2:a?" "2:s:0?" "3:s:0?")
                           '("[vout]" "[aout]" "0:s:1?" "1:s:0?"
                             "2:s:0?" "3:s:0?"))))
          (cl-loop
           for (codec language disposition) in
           '(("mov_text" "language=eng" "default")
             ("mov_text" "language=eng" "default")
             ("webvtt" "language=jpn" nil)
             ("webvtt" "language=jpn" nil))
           for index from 0
           do
           (should (equal (zr-ffmpeg-test--option-values
                           (format "-c:s:%d" index) argv)
                          (list codec)))
           (should (equal (zr-ffmpeg-test--option-values
                           (format "-metadata:s:s:%d" index) argv)
                          (list language)))
           (should (equal (zr-ffmpeg-test--option-values
                           (format "-disposition:s:%d" index) argv)
                          (and disposition (list disposition)))))
          (should-not (member "-c:s" argv))
          (should-not (cl-some (lambda (arg)
                                 (string-match-p "\\`-metadata:s\\(?::[0-9]+\\)?\\'" arg))
                               argv))
          (should-not (member "-c:s:4" argv)))))))

(ert-deftest zr-ffmpeg-test-no-subtitles-have-no-output-args ()
  "Neither none nor an empty wildcard match should inject subtitle args."
  (let ((page (zr-ffmpeg-test--page 1 "/tmp/no-subtitles.mkv")))
    (setf (plist-get page :stream-info)
          '((:index 0 :type video :ordinal 0)
            (:index 1 :type audio :ordinal 0)))
    (dolist (selection '(nil all))
      (setf (plist-get page :subtitle-streams) selection)
      (zr-ffmpeg-test--with-task (list page) 'separate
        (let ((argv (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")))
          (should-not
           (cl-some (lambda (arg)
                      (string-match-p "\\`-\\(?:c\\|metadata\\|disposition\\):s" arg))
                    argv)))))))

(ert-deftest zr-ffmpeg-test-missing-optional-subtitles-do-not-shift-codecs ()
  "Absent optional internal and external streams consume no output index."
  (let* ((page1 (zr-ffmpeg-test--page
                 1 "/tmp/v1.mkv" "/tmp/empty.mkv" 'soft "mov_text"))
         (page2 (zr-ffmpeg-test--page
                 2 "/tmp/v2.mkv" "/tmp/s2.srt" 'soft "webvtt"))
         (pages (list page1 page2)))
    (dolist (page pages)
      (setf (plist-get page :stream-info)
            '((:index 0 :type video :ordinal 0)
              (:index 1 :type subtitle :ordinal 0))))
    (setf (plist-get page1 :subtitle-streams) '(9 0)
          (plist-get page2 :subtitle-streams) '(0))
    (dolist (mode '(separate concat))
      (zr-ffmpeg-test--with-task pages mode
        (cl-letf (((symbol-function 'zr-ffmpeg--probe-streams)
                   (lambda (source)
                     (if (equal source "/tmp/empty.mkv")
                         '((:index 0 :type video :ordinal 0))
                       '((:index 0 :type subtitle :ordinal 0))))))
          (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
            (should (member "0:s:9?"
                            (zr-ffmpeg-test--option-values "-map" argv)))
            (should (equal (zr-ffmpeg-test--option-values "-c:s:0" argv)
                           '("mov_text")))
            (should (equal (zr-ffmpeg-test--option-values "-c:s:1" argv)
                           '("webvtt")))
            (should (equal (zr-ffmpeg-test--option-values "-c:s:2" argv)
                           '("webvtt")))
            (should-not (member "-c:s:3" argv))))))))

(ert-deftest zr-ffmpeg-test-unknown-subtitle-counts-share-identical-args ()
  "Unavailable metadata permits common args for one input or mixed inputs."
  (let ((page1 (zr-ffmpeg-test--page 1 "-"))
        (page2 (zr-ffmpeg-test--page 2 "/tmp/v2.mkv" "/tmp/s2.srt")))
    (dolist (page (list page1 page2))
      (setf (plist-get page :overrides)
            '(:subtitle-args ((c:s . "copy") (metadata:s . "language=eng")))))
    (setf (plist-get page1 :subtitle-streams) 'all
          (plist-get page2 :subtitle-streams) '(0 1))
    (dolist (pages (list (list page1) (list page1 page2)))
      (zr-ffmpeg-test--with-task pages 'separate
        (cl-letf (((symbol-function 'zr-ffmpeg--probe-streams)
                   (lambda (_source) nil)))
          (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
            (should (equal (zr-ffmpeg-test--option-values "-c:s" argv)
                           '("copy")))
            (should (equal (zr-ffmpeg-test--option-values
                            "-disposition:s" argv)
                           '("default")))
            (should (equal (zr-ffmpeg-test--option-values
                            "-metadata:s:s" argv)
                           '("language=eng")))
            (should-not (member "-metadata:s" argv))
            (should-not (cl-some (lambda (arg)
                                   (string-prefix-p "-c:s:" arg))
                                 argv))))))))

(ert-deftest zr-ffmpeg-test-unknown-subtitle-counts-reject-different-args ()
  "Unknown optional maps must not guess indices for different page args."
  (dolist (settings '((soft "mov_text" soft "webvtt")
                      (soft "copy" soft-default "copy")))
    (let ((pages (list (zr-ffmpeg-test--page
                       1 "/tmp/v1.mkv" nil (nth 0 settings) (nth 1 settings))
                      (zr-ffmpeg-test--page
                       2 "/tmp/v2.mkv" nil (nth 2 settings) (nth 3 settings)))))
      (dolist (selection '(all (0)))
        (dolist (page pages)
          (setf (plist-get page :subtitle-streams) selection))
        (zr-ffmpeg-test--with-task pages 'separate
          (cl-letf (((symbol-function 'zr-ffmpeg--probe-streams)
                     (lambda (_source) nil)))
            (let ((error (should-error
                          (zr-ffmpeg--build-command pages "/tmp/out.mkv")
                          :type 'user-error)))
              (should (string-match-p "different subtitle arguments"
                                      (error-message-string error))))))))))

(ert-deftest zr-ffmpeg-test-empty-subtitle-matches-do-not-prevent-shared-args ()
  "Known empty matches do not contribute arguments to an unknown count."
  (let* ((page1 (zr-ffmpeg-test--page
                 1 "/tmp/empty.mkv" nil 'soft "mov_text"))
         (page2 (zr-ffmpeg-test--page 2 "/tmp/unprobed.mkv"))
         (pages (list page1 page2)))
    (setf (plist-get page1 :subtitle-streams) 'all
          (plist-get page1 :stream-info) '((:index 0 :type video :ordinal 0))
          (plist-get page2 :subtitle-streams) 'all)
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-c:s" argv)
                       '("copy")))
        (should-not (member "mov_text" argv))))))

(ert-deftest zr-ffmpeg-test-composed-internal-data-maps ()
  "Composed output should directly map selected subtitle and data streams."
  (let ((page1 (zr-ffmpeg--new-page 1))
        (page2 (zr-ffmpeg--new-page 2)))
    (setf (plist-get page1 :source) "/tmp/v1.mkv"
          (plist-get page1 :subtitle-streams) '(0)
          (plist-get page1 :data-streams) '(0)
          (plist-get page2 :source) "/tmp/v2.mkv"
          (plist-get page2 :subtitle-streams) nil
          (plist-get page2 :data-streams) nil)
    (zr-ffmpeg-test--with-task (list page1 page2) 'concat
      (let ((argv (zr-ffmpeg--build-command
                   (list page1 page2) "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("[vout]" "[aout]" "0:s:0?" "0:d:0?")))
        (should (equal (zr-ffmpeg-test--option-values "-c:d" argv)
                       '("copy")))))))

(ert-deftest zr-ffmpeg-test-soft-separate-order-and-codecs ()
  "Soft subtitles should follow their page inputs and use scoped codecs."
  (let ((pages (list (zr-ffmpeg-test--page
                      1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft "mov_text")
                     (zr-ffmpeg-test--page
                      2 "/tmp/v2.mkv" "/tmp/s2.ass" 'soft "webvtt"))))
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-i" argv)
                       '("/tmp/v1.mkv" "/tmp/s1.srt"
                         "/tmp/v2.mkv" "/tmp/s2.ass")))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("0:v?" "0:a?" "1:s:0?"
                         "2:v?" "2:a?" "3:s:0?")))
        (should (equal (zr-ffmpeg-test--option-values "-c:s:0" argv)
                       '("mov_text")))
        (should (equal (zr-ffmpeg-test--option-values "-c:s:1" argv)
                       '("webvtt")))))))

(ert-deftest zr-ffmpeg-test-soft-composed-maps ()
  "Composed output should preserve soft subtitle maps in page order."
  (let ((pages (list (zr-ffmpeg-test--page
                      1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft "mov_text")
                     (zr-ffmpeg-test--page
                      2 "/tmp/v2.mkv" "/tmp/s2.ass" 'soft "webvtt"))))
    (zr-ffmpeg-test--with-task pages 'concat
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-i" argv)
                       '("/tmp/v1.mkv" "/tmp/s1.srt"
                         "/tmp/v2.mkv" "/tmp/s2.ass")))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("[vout]" "[aout]" "1:s:0?" "3:s:0?")))
        (should (equal (zr-ffmpeg-test--option-values "-c:s:0" argv)
                       '("mov_text")))
        (should (equal (zr-ffmpeg-test--option-values "-c:s:1" argv)
                       '("webvtt")))))))

(ert-deftest zr-ffmpeg-test-burn-in-separate-replaces-video-map ()
  "Separate burn-in should replace only its selected page video map."
  (let* ((page1 (zr-ffmpeg-test--page
                 1 "/tmp/v1.mkv" "/tmp/s1.srt" 'burn-in))
         (page2 (zr-ffmpeg-test--page 2 "/tmp/v2.mkv"))
         (pages (list page1 page2)))
    (setf (plist-get page1 :preset) 'file-stream
          (plist-get page1 :video-streams) '(1))
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-i" argv)
                       '("/tmp/v1.mkv" "/tmp/v2.mkv")))
        (should
         (equal (zr-ffmpeg-test--option-values "-filter_complex" argv)
                (list (concat
                       "[0:v:1]subtitles=filename='/tmp/s1.srt'"
                       "[v1]"))))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("[v1]" "0:a?" "1:v?" "1:a?")))))))

(ert-deftest zr-ffmpeg-test-burn-in-composed-follows-video-output ()
  "Composed burn-in should filter the composed video output."
  (let* ((page1 (zr-ffmpeg-test--page
                 1 "/tmp/v1.mkv" "/tmp/s1.srt" 'burn-in))
         (pages (list page1 (zr-ffmpeg-test--page 2 "/tmp/v2.mkv"))))
    (setf (plist-get page1 :preset) 'file-stream)
    (zr-ffmpeg-test--with-task pages 'concat
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values "-i" argv)
                       '("/tmp/v1.mkv" "/tmp/v2.mkv")))
        (should
         (equal
          (zr-ffmpeg-test--option-values "-filter_complex" argv)
          (list
           (concat
            "[0:v:0][1:v:0]concat=n=2:v=1:a=0[vout];"
            "[0:a:0][1:a:0]concat=n=2:v=0:a=1[aout];"
            "[vout]subtitles=filename='/tmp/s1.srt'[vburn]"))))
        (should (equal (zr-ffmpeg-test--option-values "-map" argv)
                       '("[vburn]" "[aout]")))))))

(ert-deftest zr-ffmpeg-test-all-composition-modes-build-a-graph ()
  "Every composition mode should return a usable filter graph."
  (let ((pages (list (zr-ffmpeg-test--page 1 "/tmp/v1.mkv")
                     (zr-ffmpeg-test--page 2 "/tmp/v2.mkv"))))
    (dolist (mode '(concat concat-video concat-audio amix
                           hstack vstack xstack overlay))
      (zr-ffmpeg-test--with-task pages mode
        (let* ((specs (zr-ffmpeg--input-specs pages))
               (graph (zr-ffmpeg--filtergraph pages specs)))
          (should (stringp (car graph)))
          (should (cdr graph)))))))

(ert-deftest zr-ffmpeg-test-burn-in-rejects-url-source ()
  "Burn-in should reject subtitle URLs that the filter cannot load safely."
  (let* ((page (zr-ffmpeg-test--page
                1 "/tmp/v1.mkv" "https://example.com/s.srt" 'burn-in))
         (pages (list page)))
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((error (should-error
                    (zr-ffmpeg--build-command pages "/tmp/out.mkv")
                    :type 'user-error)))
        (should (string-match-p "must be a local file"
                                (error-message-string error)))))))

(ert-deftest zr-ffmpeg-test-burn-in-rejects-video-copy ()
  "Burn-in should reject stream-copy video output."
  (let* ((page (zr-ffmpeg-test--page
                1 "/tmp/v1.mkv" "/tmp/s1.srt" 'burn-in))
         (pages (list page)))
    (setf (plist-get page :preset) 'file-copy)
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((error (should-error
                    (zr-ffmpeg--build-command pages "/tmp/out.mkv")
                    :type 'user-error)))
        (should (string-match-p "requires video encoding"
                                (error-message-string error)))))))

(ert-deftest zr-ffmpeg-test-composed-rejects-multiple-burn-in-sources ()
  "Composed output should reject ambiguous multiple burn-in sources."
  (let ((pages (list (zr-ffmpeg-test--page
                      1 "/tmp/v1.mkv" "/tmp/s1.srt" 'burn-in)
                     (zr-ffmpeg-test--page
                      2 "/tmp/v2.mkv" "/tmp/s2.srt" 'burn-in))))
    (zr-ffmpeg-test--with-task pages 'concat
      (let ((error (should-error
                    (zr-ffmpeg--build-command pages "/tmp/out.mkv")
                    :type 'user-error)))
        (should (string-match-p "supports one burn-in"
                                (error-message-string error)))))))

(ert-deftest zr-ffmpeg-test-soft-default-sets-disposition ()
  "soft-default should mark the subtitle stream as the default subtitle."
  (let ((pages (list (zr-ffmpeg-test--page
                      1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft-default "mov_text"))))
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values
                        "-disposition:s:0" argv)
                       '("default")))))))

(ert-deftest zr-ffmpeg-test-soft-mode-has-no-disposition ()
  "Plain soft mode should not inject a default disposition."
  (let ((pages (list (zr-ffmpeg-test--page
                     1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft "mov_text"))))
    (zr-ffmpeg-test--with-task pages 'separate
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should-not (member "-disposition:s:0" argv))
        (should-not (cl-some (lambda (a)
                              (and (stringp a)
                                   (string-match-p "disposition" a)))
                            argv))))))

(ert-deftest zr-ffmpeg-test-soft-default-composed-disposition ()
  "soft-default composed output should scope disposition to each subtitle."
  (let ((pages (list (zr-ffmpeg-test--page
                    1 "/tmp/v1.mkv" "/tmp/s1.srt" 'soft-default "mov_text")
                    (zr-ffmpeg-test--page
                    2 "/tmp/v2.mkv" "/tmp/s2.ass" 'soft-default "webvtt"))))
    (zr-ffmpeg-test--with-task pages 'concat
      (let ((argv (zr-ffmpeg--build-command pages "/tmp/out.mkv")))
        (should (equal (zr-ffmpeg-test--option-values
                        "-disposition:s:0" argv)
                       '("default")))
        (should (equal (zr-ffmpeg-test--option-values
                        "-disposition:s:1" argv)
                       '("default")))))))

(ert-deftest zr-ffmpeg-test-set-preset-refreshes-mirror-variables ()
  "Switching preset must refresh the transient mirror variables
so the Video/Audio/Subtitle mode infixes display the new preset's
values."
  (let* ((pages (list (zr-ffmpeg-test--page 1 "/tmp/v1.mkv")))
         (page (car pages)))
    (zr-ffmpeg-test--with-task pages 'separate
      (setq page (car zr-ffmpeg--inputs-state))
      ;; Start on the screen-stream preset for a distinctive signal.
      (zr-ffmpeg--set-preset nil 'screen-stream)
      (should (eq zr-ffmpeg--current-preset 'screen-stream))
      ;; The screen-stream preset has :video t :audio t :subtitle-mode
      ;; burn-in.
      (should (eq zr-ffmpeg--video-toggle t))
      (should (eq zr-ffmpeg--audio-toggle t))
      (should (eq zr-ffmpeg--subtitle-mode 'burn-in))
      ;; Purposely set an override, then switch to file-copy to
      ;; confirm the mirror variables refresh even when the page would
      ;; otherwise stall.
      (zr-ffmpeg--set-preset nil 'file-copy)
      (should (eq zr-ffmpeg--current-preset 'file-copy))
      (should (eq zr-ffmpeg--video-toggle t))
      (should (eq zr-ffmpeg--audio-toggle t))
      (should (eq zr-ffmpeg--subtitle-mode 'soft-default)))))

;;; Remote files

(defmacro zr-ffmpeg-test--with-remote-requests (&rest body)
  "Evaluate BODY with readable remote files and fake HTTP requests."
  (declare (indent 0) (debug body))
  `(cl-letf (((symbol-function 'zr-ffmpeg--remote-backend) #'ignore)
             ((symbol-function 'zr-ffmpeg--remote-request)
              (lambda (file &optional upload _resolve)
                (cons (concat (if (string-prefix-p "/webdavs:" file) "https" "http")
                              "://example.org/" (if upload "upload/" "")
                              (file-name-nondirectory file))
                      '(("Authorization" . "Basic eDp5") ("X-Test" . "1")))))
             ((symbol-function 'file-regular-p) (lambda (_file) t))
             ((symbol-function 'file-directory-p)
              (let ((original (symbol-function 'file-directory-p)))
                (lambda (file)
                  (if (file-remote-p file) (directory-name-p file)
                    (funcall original file))))))
     ,@body))

(ert-deftest zr-ffmpeg-test-remote-source-classification ()
  "TRAMP names are remote files, distinct from local paths and URLs."
  (dolist (source '("/webdav:host#8080:/dav/in.mkv" "/rcrc:127.0.0.1#5572:/fx:/in.mkv"))
    (should (zr-ffmpeg--remote-p source))
    (should (zr-ffmpeg--file-p source))
    (should-not (zr-ffmpeg--local-path-p source)))
  (should (zr-ffmpeg--local-path-p "/tmp/in.mkv"))
  (dolist (source '("/tmp/in.mkv" "https://example.com/in.mkv" "-" nil))
    (should-not (zr-ffmpeg--remote-p source))))

(ert-deftest zr-ffmpeg-test-capture-sources-are-not-file-names ()
  "Device and filter inputs must not be expanded like file names."
  (let ((default-directory temporary-file-directory)
        (audio (zr-ffmpeg--new-page 1))
        (screen (zr-ffmpeg--new-page 2)))
    (setf (plist-get audio :kind) 'audio-device
          (plist-get audio :audio-device) "Microphone (USB)"
          (plist-get screen :kind) 'screen
          (plist-get screen :monitor) 0)
    (zr-ffmpeg-test--with-task (list audio screen) 'separate
      (let ((specs (zr-ffmpeg--input-specs (list audio screen))))
        (should (equal (mapcar (lambda (spec) (plist-get spec :source)) specs)
                       (list "audio=Microphone (USB)"
                             (zr-ffmpeg--screen-filter screen))))
        (should-not (cl-some (lambda (spec) (plist-get spec :file)) specs))))))

(ert-deftest zr-ffmpeg-test-input-basename ()
  "Only URLs lose their query and fragment in default output names."
  (should (equal (zr-ffmpeg--input-basename "/webdav:host#8080:/dav/in.mkv") "in"))
  (should (equal (zr-ffmpeg--input-basename "/tmp/a#b?c.mkv") "a#b?c"))
  (should (equal (zr-ffmpeg--input-basename
                  "https://example.com/v/in.mkv?token=a#t=1")
                 "in"))
  (should (equal (zr-ffmpeg--input-basename "https://example.com/") "recording")))

(ert-deftest zr-ffmpeg-test-remote-task-keeps-file-names ()
  "Task commands name remote files, and outputs default next to the input."
  (let* ((input "/webdav:host#8080:/dav/in.mkv")
         (page (zr-ffmpeg-test--page 1 input)))
    (zr-ffmpeg-test--with-task (list page) 'separate
      (setq zr-ffmpeg--output-format "mp4")
      (let* ((output (zr-ffmpeg--output-for-input))
             (argv (zr-ffmpeg--build-command (list page) output)))
        (should (equal output "/webdav:host#8080:/dav/in.mp4"))
        (should (equal (zr-ffmpeg-test--option-values "-i" argv) (list input)))
        (should (equal (car (last argv)) output)))
      (should (string-match-p
               "identical"
               (error-message-string
                (should-error (zr-ffmpeg--build-command (list page) input)
                              :type 'user-error))))
      ;; Burn-in subtitles are read by a filter, which cannot send headers.
      (setf (plist-get page :subtitle-source) "/webdav:host#8080:/dav/in.srt"
            (plist-get page :overrides) '(:subtitle-mode burn-in))
      (setf (plist-get page :preset) 'file-stream)
      (should (string-match-p
               "must be a local file"
               (error-message-string
                (should-error (zr-ffmpeg--build-command (list page) "/tmp/out.mkv")
                              :type 'user-error)))))))

(ert-deftest zr-ffmpeg-test-split-command ()
  "Edited commands split into POSIX shell words and report other syntax."
  (let ((args (list "ffmpeg" "-i" "/webdav:host#8080:/dav/中 文 [1].mkv"
                    "-filter_complex" "[0:v]null[v];[0:a]anull[a]"
                    "-metadata" "title=a'b\"c\\d$e`f&g|h" "" "out.mkv")))
    (should (equal (zr-ffmpeg--split-command
                    (mapconcat #'shell-quote-argument args " "))
                   (cons args nil))))
  (should (equal (zr-ffmpeg--split-command
                  "ffmpeg  -i \"a b\"'c d'e\\ f \"q\\\"\\\\\"\n")
                 '(("ffmpeg" "-i" "a bc de f" "q\"\\"))))
  (dolist (command '("ffmpeg -i in.mkv out.mkv | tee log" "ffmpeg -i $IN out.mkv"
                     "ffmpeg -i \"$IN\" out.mkv" "ffmpeg -i ~/in.mkv out.mkv"
                     "ffmpeg -i 'in.mkv out.mkv" "ffmpeg -i in.mkv out.mkv # x"))
    (ert-info (command)
      (should (cdr (zr-ffmpeg--split-command command))))))

(ert-deftest zr-ffmpeg-test-remote-argv-reads-http-and-writes-locally ()
  "Remote inputs become HTTP(S) inputs, and remote outputs local files."
  (let ((directory (make-temp-file "zr-ffmpeg-test-" t))
        (input "/webdavs:alice@example.org:/dav/in.mkv")
        (output "/rcrc:127.0.0.1#5572:/fx:/out dir/中 文.mkv"))
    (unwind-protect
        (zr-ffmpeg-test--with-remote-requests
          (pcase-let ((`(,argv . ,outputs)
                       (cl-letf (((symbol-function 'file-exists-p) #'ignore))
                         (zr-ffmpeg--remote-argv
                          (list "ffmpeg" "-i" input "-i" "/tmp/local.srt"
                                "-c" "copy" output)
                          directory))))
            (should (equal (butlast argv)
                           '("ffmpeg" "-tls_verify" "1"
                             "-headers" "Authorization: Basic eDp5\r\nX-Test: 1\r\n"
                             "-max_redirects" "0"
                             "-i" "https://example.org/in.mkv"
                             "-i" "/tmp/local.srt" "-c" "copy")))
            (should (equal outputs (list (list (directory-file-name
                                                (file-name-directory
                                                 (car (last argv))))
                                               output nil))))
            (should (equal (file-name-nondirectory (car (last argv))) "中 文.mkv"))
            (should (file-in-directory-p (car (last argv)) directory))
            ;; FFmpeg rejects TLS options that an HTTP input leaves unused.
            (should (equal (car (zr-ffmpeg--remote-argv
                                 (list "ffmpeg" "-i" "/webdav:host:/dav/in.mkv")
                                 directory))
                           '("ffmpeg" "-headers"
                             "Authorization: Basic eDp5\r\nX-Test: 1\r\n"
                             "-max_redirects" "0"
                             "-i" "http://example.org/in.mkv")))
            ;; Existing outputs are replaced after -y or consent only.
            (cl-letf (((symbol-function 'file-exists-p) (lambda (_file) t))
                      ((symbol-function 'y-or-n-p) #'ignore))
              (dolist (argv (list (list "ffmpeg" "-i" "/tmp/in.mkv" output)
                                  (list "ffmpeg" "-n" "-i" "/tmp/in.mkv" output)))
                (should-error (zr-ffmpeg--remote-argv argv directory)
                              :type 'user-error)))
            (cl-letf (((symbol-function 'file-exists-p) (lambda (_file) t))
                      ((symbol-function 'y-or-n-p)
                       (lambda (_prompt) (error "Should not ask"))))
              (should (zr-ffmpeg--remote-argv
                       (list "ffmpeg" "-y" "-i" "/tmp/in.mkv" output) directory)))
            (should-error (zr-ffmpeg--remote-argv
                           (list "ffmpeg" "-i" "/tmp/in.mkv" "/webdav:host:/dav/")
                           directory)
                          :type 'user-error)))
      (delete-directory directory t))
    (should-error (zr-ffmpeg--remote-argv
                   (list "ffmpeg" "-i" "/ssh:host:/in.mkv" "/tmp/out.mkv") nil)
                  :type 'user-error)))

(ert-deftest zr-ffmpeg-test-probe-remote-source-sends-headers ()
  "Probing a remote source reads it over HTTP(S) with its headers."
  (let (seen)
    (zr-ffmpeg-test--with-remote-requests
      (cl-letf (((symbol-function 'executable-find) (lambda (_program) t))
                ((symbol-function 'call-process)
                 (lambda (_program _infile _destination _display &rest args)
                   (setq seen args)
                   (insert "{\"streams\":[{\"index\":0,\"codec_type\":\"video\"}]}")
                   0)))
        (should (equal (mapcar (lambda (stream) (plist-get stream :type))
                               (zr-ffmpeg--probe-streams "/webdav:host:/dav/in.mkv"))
                       '(video)))
        (should (equal (last seen 6)
                       '("-headers" "Authorization: Basic eDp5\r\nX-Test: 1\r\n"
                         "-max_redirects" "0"
                         "-i" "http://example.org/in.mkv")))))))

(ert-deftest zr-ffmpeg-test-edited-remote-commands-run-without-shell ()
  "Edited commands naming remote files run their words without a shell."
  (let ((zr-ffmpeg-command-history nil)
        started)
    (cl-letf (((symbol-function 'zr-ffmpeg--start-remote)
               (lambda (argv _buffer) (setq started (list 'remote argv))))
              ((symbol-function 'start-process-shell-command)
               (lambda (_name _buffer command) (setq started (list 'shell command)))))
      (zr-ffmpeg--start-command "ffmpeg -i /webdav\\:host\\:/dav/a\\ b.mkv out.mkv")
      (should (equal started
                     '(remote ("ffmpeg" "-i" "/webdav:host:/dav/a b.mkv" "out.mkv"))))
      (zr-ffmpeg--start-command "ffmpeg -i in.mkv out.mkv 2>&1 | tee log")
      (should (equal started '(shell "ffmpeg -i in.mkv out.mkv 2>&1 | tee log")))
      (should-error (zr-ffmpeg--start-command
                     "ffmpeg -i /webdav:host:/dav/a.mkv out.mkv | tee log")
                    :type 'user-error)
      (should (equal (car zr-ffmpeg-command-history)
                     "ffmpeg -i /webdav:host:/dav/a.mkv out.mkv | tee log")))))

;;; Remote integration

(defvar zr-ffmpeg-test--servers nil
  "Fixture server processes of the remote integration tests.")

(defvar zr-ffmpeg-test--webdav-port nil)

(defvar zr-ffmpeg-test--rcd nil
  "The (TOP . DATA) of the running rcd fixture.")

(defun zr-ffmpeg-test--stop ()
  "Stop the fixture servers and remove the files of the rcd."
  (dolist (process zr-ffmpeg-test--servers)
    (when (process-live-p process) (delete-process process)))
  (when zr-ffmpeg-test--rcd
    (delete-directory (file-name-directory (cdr zr-ffmpeg-test--rcd)) t)))

(add-hook 'kill-emacs-hook #'zr-ffmpeg-test--stop)

(defmacro zr-ffmpeg-test--with-remote (&rest body)
  "Run BODY without proxies and with a private `temporary-file-directory'."
  (declare (indent 0) (debug body))
  `(let* ((url-proxy-services '(("no_proxy" . ".*")))
          (process-environment (append '("NO_PROXY=*" "no_proxy=*")
                                       process-environment))
          (auth-sources nil)
          (tramp-verbose 0)
          (zr-ffmpeg-command-history nil)
          (temporary-file-directory
           (file-name-as-directory (make-temp-file "zr-ffmpeg-test-" t))))
     (unwind-protect
         (progn
           (dolist (program (list zr-ffmpeg-program zr-ffmpeg-ffprobe-program
                                  zr-ffmpeg-curl-program))
             (unless (executable-find program)
               (ert-skip (format "%s is required" program))))
           ,@body)
       (delete-directory temporary-file-directory t))))

(defun zr-ffmpeg-test--webdav-port ()
  "Return the port of the WebDAV fixture, starting it if needed."
  (unless (executable-find "python3") (ert-skip "Python 3 is required"))
  (unless zr-ffmpeg-test--webdav-port
    (let* ((buffer (generate-new-buffer " *zr-ffmpeg-test-webdav*"))
           (process (make-process
                     :name "zr-ffmpeg-test-webdav" :buffer buffer :noquery t
                     :command (list "python3" "-u"
                                    (expand-file-name "webdav-server.py"
                                                      zr-ffmpeg-test--directory))))
           (deadline (+ (float-time) 5)))
      (push process zr-ffmpeg-test--servers)
      (while (and (not zr-ffmpeg-test--webdav-port) (< (float-time) deadline))
        (accept-process-output process 0.05)
        (with-current-buffer buffer
          (goto-char (point-min))
          (when (re-search-forward "PORT \\([0-9]+\\)" nil t)
            (setq zr-ffmpeg-test--webdav-port (match-string 1)))))
      (unless zr-ffmpeg-test--webdav-port
        (error "WebDAV fixture did not start"))))
  zr-ffmpeg-test--webdav-port)

(defun zr-ffmpeg-test--rcd ()
  "Return (TOP . DATA) of an rcd serving objects, starting it if needed.
TOP is the rcrc name of the rcd, whose `fixture' remote serves DATA."
  (let ((program (or (getenv "RCLONE_TEST_PROGRAM") (executable-find "rclone"))))
    (unless program (ert-skip "Set RCLONE_TEST_PROGRAM or install rclone"))
    (unless zr-ffmpeg-test--rcd
      (let* ((root (let ((temporary-file-directory
                          (default-toplevel-value 'temporary-file-directory)))
                     (make-temp-file "zr-ffmpeg-test-rcd-" t)))
             (data (expand-file-name "data" root))
             (config (expand-file-name "rclone.conf" root))
             (socket (make-network-process :name "zr-ffmpeg-test-port" :server t
                                           :host "127.0.0.1" :family 'ipv4
                                           :service t :noquery t))
             (port (process-contact socket :service))
             (url (format "http://127.0.0.1:%s/" port))
             (top (zr-tramp-rcrc-file-name url nil))
             (process-environment (append '("RCLONE_RC_USER=test"
                                            "RCLONE_RC_PASS=secret")
                                          process-environment))
             (deadline (+ (float-time) 10))
             ready)
        (delete-process socket)
        (make-directory data)
        (with-temp-file config
          (insert "[fixture]\ntype = alias\nremote = " data "\n"))
        (push (make-process
               :name "zr-ffmpeg-test-rcd" :buffer nil :noquery t
               :command (list program "rcd" "--rc-serve"
                              "--rc-addr" (format "127.0.0.1:%s" port)
                              "--config" config
                              "--cache-dir" (expand-file-name "cache" root)))
              zr-ffmpeg-test--servers)
        (zr-tramp-rcrc-register-endpoint url "test" "secret")
        (while (and (not ready) (< (float-time) deadline))
          (let ((zr-tramp-rcrc-timeout 0.5))
            (setq ready (ignore-errors (directory-files (concat top "fixture:/")))))
          (unless ready (accept-process-output nil 0.1)))
        (unless ready (error "rcd fixture did not start"))
        (setq zr-ffmpeg-test--rcd (cons top data)))))
  zr-ffmpeg-test--rcd)

(defun zr-ffmpeg-test--sample (file)
  "Write a short media FILE with one video and one audio stream."
  (should (zerop (call-process zr-ffmpeg-program nil nil nil
                               "-v" "error" "-f" "lavfi"
                               "-i" "testsrc=duration=1:size=64x64:rate=5"
                               "-f" "lavfi" "-i" "sine=duration=1"
                               "-c:v" "mpeg4" "-c:a" "aac" "-shortest" "-y" file))))

(defun zr-ffmpeg-test--run (args)
  "Run FFmpeg ARGS and wait for its uploads, including their sentinels."
  (zr-ffmpeg--start-command args)
  ;; A process leaves `process-list' just before its sentinel runs.
  (let ((deadline (+ (float-time) 60)))
    (while (and (cl-some (lambda (process)
                           (string-match-p "\\`zr-ffmpeg\\(?:-upload\\)?\\(?:<[0-9]+>\\)?\\'"
                                           (process-name process)))
                         (process-list))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(defun zr-ffmpeg-test--kept-outputs ()
  "Return the files kept in private temporary directories of uploads."
  (cl-loop for directory in (directory-files temporary-file-directory t
                                             "\\`zr-ffmpeg-")
           append (directory-files-recursively directory "")))

(defun zr-ffmpeg-test--stream-types (file)
  "Return the stream types that ffprobe finds in FILE."
  (mapcar (lambda (stream) (plist-get stream :type))
          (zr-ffmpeg--probe-streams file)))

(ert-deftest zr-ffmpeg-test-webdav-input-and-output ()
  "FFmpeg reads WebDAV input over HTTP, and curl uploads its output."
  (zr-ffmpeg-test--with-remote
    (let* ((port (zr-ffmpeg-test--webdav-port))
           (root (format "/webdav:alice@127.0.0.1#%s:/auth/ffmpeg-%d/"
                         port (random 1000000)))
           (input (concat root "in 中.mkv"))
           (output (concat root "out 中 \"q\" ;x.mkv"))
           (sample (make-temp-file "sample-" nil ".mkv"))
           (key (tramp-make-tramp-file-name (tramp-dissect-file-name root) 'noloc))
           (zr-tramp-webdav--passwords (make-hash-table :test #'equal))
           (zr-tramp-webdav--connected (make-hash-table :test #'equal))
           (tramp-cache-data (make-hash-table :test #'equal)))
      (puthash key '("alice" . "app-password") zr-tramp-webdav--passwords)
      (zr-ffmpeg-test--sample sample)
      (make-directory root)
      (copy-file sample input)
      (zr-ffmpeg-test--run (list zr-ffmpeg-program "-loglevel" "error" "-i" input
                                 "-map" "0" "-c" "copy" output))
      (should-not (zr-ffmpeg-test--kept-outputs))
      (should (equal (zr-ffmpeg-test--stream-types output) '(video audio)))
      ;; History names files without credentials, and replays as edited.
      (let ((command (car zr-ffmpeg-command-history)))
        (should-not (string-match-p "Basic\\|http:" command))
        (zr-ffmpeg-test--run (replace-regexp-in-string "\\`\\S-+" "\\& -y" command))
        (should-not (zr-ffmpeg-test--kept-outputs))
        (should (equal (zr-ffmpeg-test--stream-types output) '(video audio))))
      ;; A failed FFmpeg run uploads nothing.
      (zr-ffmpeg-test--run (list zr-ffmpeg-program "-loglevel" "quiet" "-i" input
                                 "-c:v" "no-such-codec" (concat root "failed.mkv")))
      (should-not (zr-ffmpeg-test--kept-outputs))
      (should-not (let ((remote-file-name-inhibit-cache t))
                    (file-exists-p (concat root "failed.mkv"))))
      (should (string-match-p
               "does not exist"
               (error-message-string
                (should-error (zr-ffmpeg--start-command
                               (list zr-ffmpeg-program "-i" input
                                     (concat root "missing/out.mkv")))
                              :type 'user-error))))
      ;; A failed upload keeps FFmpeg's output.
      (cl-letf (((symbol-function 'zr-ffmpeg--start-remote)
                 (let ((start (symbol-function 'zr-ffmpeg--start-remote)))
                   (lambda (&rest args)
                     (prog1 (apply start args)
                       (puthash key '("alice" . "wrong") zr-tramp-webdav--passwords))))))
        (zr-ffmpeg-test--run (list zr-ffmpeg-program "-loglevel" "error" "-i" input
                                   "-c" "copy" (concat root "kept.mkv"))))
      (should (equal (mapcar #'file-name-nondirectory (zr-ffmpeg-test--kept-outputs))
                     '("kept.mkv"))))))

(ert-deftest zr-ffmpeg-test-rcrc-input-and-output ()
  "FFmpeg reads rcrc input from --rc-serve, and curl uploads its output."
  (zr-ffmpeg-test--with-remote
    (pcase-let* ((`(,top . ,data) (zr-ffmpeg-test--rcd))
                 (name (format "case-%d" (random 1000000)))
                 (local (expand-file-name name data))
                 (remote (concat top "fixture:/" name "/"))
                 (output "out 中 \"q\" ;x.mkv"))
      (make-directory local)
      (zr-ffmpeg-test--sample (expand-file-name "in 中.mkv" local))
      (zr-tramp-rcrc-clear-cache)
      (zr-ffmpeg-test--run (list zr-ffmpeg-program "-loglevel" "error"
                                 "-i" (concat remote "in 中.mkv")
                                 "-map" "0" "-c" "copy" (concat remote output)))
      (should-not (zr-ffmpeg-test--kept-outputs))
      (should (equal (zr-ffmpeg-test--stream-types (expand-file-name output local))
                     '(video audio)))
      (should (equal (zr-ffmpeg-test--stream-types (concat remote output))
                     '(video audio))))))

(defun zr-ffmpeg-test--webdav-root ()
  "Create a fresh directory on the WebDAV fixture and return its name."
  (let ((root (format "/webdav:127.0.0.1#%s:/dav/ffmpeg-%d/"
                      (zr-ffmpeg-test--webdav-port) (random 1000000))))
    (make-directory root)
    root))

(defun zr-ffmpeg-test--contents (file)
  "Read FILE literally, bypassing cached remote contents."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(defun zr-ffmpeg-test--webdav-requests ()
  "Return the requests received by the WebDAV fixture."
  (json-parse-string
   (zr-ffmpeg-test--contents
    (format "/webdav:127.0.0.1#%s:/__test__/requests"
            (zr-ffmpeg-test--webdav-port)))
   :object-type 'alist :array-type 'list))

(ert-deftest zr-ffmpeg-test-webdav-same-origin-redirects ()
  "Resolve input redirects and upload to a redirect's actual destination."
  (zr-ffmpeg-test--with-remote
    (let* ((input (zr-ffmpeg-test--webdav-root))
           (output (zr-ffmpeg-test--webdav-root))
           (sample (make-temp-file "sample-" nil ".mkv"))
           (zr-tramp-webdav-extra-headers '(("Authorization" . "Bearer fixture"))))
      (zr-ffmpeg-test--sample sample)
      (copy-file sample (concat input "redirect-target"))
      (should (equal (zr-ffmpeg-test--stream-types (concat input "redirect-source"))
                     '(video audio)))
      (zr-ffmpeg-test--run
       (list zr-ffmpeg-program "-v" "error" "-i" (concat input "redirect-source")
             "-c" "copy" "-f" "matroska" (concat output "redirect-source")))
      (should (equal (zr-ffmpeg-test--stream-types (concat output "redirect-target"))
                     '(video audio)))
      (should-not (zr-ffmpeg-test--kept-outputs))
      (should-not (directory-files temporary-file-directory nil "\\`zr-http-")))))

(ert-deftest zr-ffmpeg-test-webdav-input-never-forwards-credentials ()
  "A GET-only cross-origin redirect must fail in both ffprobe and FFmpeg."
  (zr-ffmpeg-test--with-remote
    (let* ((root (zr-ffmpeg-test--webdav-root))
           (input (concat root "get-cross-origin.mkv"))
           (target (concat root "cross-origin-target.mkv"))
           (output (expand-file-name "out.mkv" temporary-file-directory))
           (sample (make-temp-file "sample-" nil ".mkv"))
           (zr-tramp-webdav-extra-headers '(("Authorization" . "Bearer fixture"))))
      (zr-ffmpeg-test--sample sample)
      (copy-file sample input)
      (copy-file sample target)
      ;; HEAD succeeds; GET redirects, including after the preflight check.
      (should-not (zr-ffmpeg--probe-streams input))
      (zr-ffmpeg-test--run
       (list zr-ffmpeg-program "-v" "error" "-i" input "-c" "copy" output))
      (should-not (file-exists-p output))
      (should-not
       (cl-find-if
        (lambda (request)
          (and (equal (alist-get 'method request) "GET")
               (equal (alist-get 'path request) (file-local-name target))))
        (zr-ffmpeg-test--webdav-requests))))))

(ert-deftest zr-ffmpeg-test-webdav-unsuccessful-uploads-keep-files ()
  "Cross-origin redirects, loops, and unhandled 3xx responses retain output."
  (dolist (case '(("put-cross-origin.mkv" . "Unsafe upload redirect")
                  ("put-loop.mkv" . "Too many upload redirects")
                  ("put-see-other.mkv" . "HTTP 303")))
    (ert-info ((car case))
      (zr-ffmpeg-test--with-remote
        (let* ((root (zr-ffmpeg-test--webdav-root))
               (output (concat root (car case)))
               (sample (make-temp-file "sample-" nil ".mkv"))
               (zr-tramp-webdav-extra-headers '(("Authorization" . "Bearer fixture")))
               ;; Even extra curl arguments cannot enable unchecked redirects.
               (zr-ffmpeg-curl-arguments '("--location-trusted")))
          (zr-ffmpeg-test--sample sample)
          (zr-ffmpeg-test--run
           (list zr-ffmpeg-program "-v" "error" "-i" sample "-c" "copy" output))
          (should (equal (mapcar #'file-name-nondirectory
                                 (zr-ffmpeg-test--kept-outputs))
                         (list (car case))))
          (should-not (let ((remote-file-name-inhibit-cache t)) (file-exists-p output)))
          (should (with-current-buffer "*zr-ffmpeg*"
                    (string-match-p (cdr case) (buffer-string))))
          (should-not
           (cl-find-if
            (lambda (request)
              (and (equal (alist-get 'method request) "PUT")
                   (equal (alist-get 'path request)
                          (file-local-name (concat root "cross-origin-target.mkv")))))
            (zr-ffmpeg-test--webdav-requests)))
          (should-not (directory-files temporary-file-directory nil "\\`zr-http-")))))))

(defun zr-ffmpeg-test--pattern-overwrite (root)
  "Check no-overwrite, declined confirmation, and overwrite below ROOT."
  (dolist (flag '("-n" nil "-y"))
    (let* ((directory (concat root (or flag "ask") "/"))
           (target (concat directory "frame001.png"))
           (kept (length (zr-ffmpeg-test--kept-outputs)))
           (prompts 0))
      (make-directory directory)
      (write-region "existing output" nil target nil 'silent)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_prompt) (cl-incf prompts) nil)))
        (zr-ffmpeg-test--run
         (append (list zr-ffmpeg-program "-v" "error") (when flag (list flag))
                 (list "-f" "lavfi" "-i" "color=s=16x16:d=0.1" "-frames:v" "1"
                       (concat directory "frame%03d.png")))))
      (should (= prompts (if flag 0 1)))
      (if (equal flag "-y")
          (progn
            (should (equal (zr-ffmpeg-test--stream-types target) '(video)))
            (should (= kept (length (zr-ffmpeg-test--kept-outputs)))))
        (should (equal (zr-ffmpeg-test--contents target) "existing output"))
        (should (= (1+ kept) (length (zr-ffmpeg-test--kept-outputs))))))))

(ert-deftest zr-ffmpeg-test-webdav-pattern-overwrite ()
  "Image patterns honor the overwrite policy for each actual WebDAV file."
  (zr-ffmpeg-test--with-remote
    (zr-ffmpeg-test--pattern-overwrite (zr-ffmpeg-test--webdav-root))))

(ert-deftest zr-ffmpeg-test-rcrc-pattern-overwrite ()
  "Image patterns honor the overwrite policy for each actual rcrc file."
  (zr-ffmpeg-test--with-remote
    (let ((root (concat (car (zr-ffmpeg-test--rcd)) "fixture:/pattern-"
                        (number-to-string (random 1000000)) "/")))
      (make-directory root)
      (zr-ffmpeg-test--pattern-overwrite root))))

(ert-deftest zr-ffmpeg-test-webdav-exclusive-upload ()
  "A concurrent writer between checking and PUT is protected by HTTP 412."
  (zr-ffmpeg-test--with-remote
    (let* ((root (zr-ffmpeg-test--webdav-root))
           (output (concat root "put-race.mkv"))
           (sample (make-temp-file "sample-" nil ".mkv")))
      (zr-ffmpeg-test--sample sample)
      (zr-ffmpeg-test--run
       (list zr-ffmpeg-program "-v" "error" "-n" "-i" sample "-c" "copy" output))
      (should (equal (zr-ffmpeg-test--contents output) "created by another writer"))
      (should (equal (mapcar #'file-name-nondirectory (zr-ffmpeg-test--kept-outputs))
                     '("put-race.mkv"))))))

(ert-deftest zr-ffmpeg-test-built-task-mixes-local-webdav-and-rcrc ()
  "Run generated task commands with mixed inputs and all three output kinds."
  (zr-ffmpeg-test--with-remote
    (let* ((dav (zr-ffmpeg-test--webdav-root))
           (rc (concat (car (zr-ffmpeg-test--rcd)) "fixture:/mixed-"
                       (number-to-string (random 1000000)) "/"))
           (sample (make-temp-file "sample-" nil ".mkv"))
           (inputs (list sample (concat dav "in 中.mkv") (concat rc "in 中.mkv")))
           (subtitle (concat rc "字幕.srt")))
      (make-directory rc)
      (zr-ffmpeg-test--sample sample)
      (dolist (input (cdr inputs)) (copy-file sample input))
      (write-region "1\n00:00:00,000 --> 00:00:00,800\nHello\n" nil subtitle nil 'silent)
      (dolist (output (list (expand-file-name "out.mkv" temporary-file-directory)
                            (concat dav "out 中.mkv") (concat rc "out 中.mkv")))
        (with-temp-buffer
          ;; Exercise the same state and command builder as the transient,
          ;; including execution from a remote buffer's default-directory.
          (setq default-directory dav
                zr-ffmpeg--inputs-state
                (cl-loop for input in inputs for id from 1
                         collect (let ((page (zr-ffmpeg--new-page id)))
                                   (setf (plist-get page :source) input
                                         (plist-get page :overrides)
                                         '(:output-args nil :subtitle-mode soft))
                                   page))
                zr-ffmpeg--composition-mode 'separate
                zr-ffmpeg--output-target output
                zr-ffmpeg--output-format "matroska")
          (setf (plist-get (car zr-ffmpeg--inputs-state) :subtitle-source) subtitle)
          (let ((command (zr-ffmpeg--command)))
            (should (equal (zr-ffmpeg-test--option-values "-i" command)
                           (list sample subtitle (cadr inputs) (caddr inputs))))
            (zr-ffmpeg-test--run command)))
        (should (equal (zr-ffmpeg-test--stream-types output)
                       '(video audio subtitle video audio video audio)))
        (should-not (zr-ffmpeg-test--kept-outputs))))))

(provide 'zr-ffmpeg-test)

;;; zr-ffmpeg-test.el ends here
