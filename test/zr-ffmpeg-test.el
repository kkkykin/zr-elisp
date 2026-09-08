;;; zr-ffmpeg-test.el --- Tests for zr-ffmpeg -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for FFmpeg subtitle input, mapping, and burn-in handling.

;;; Code:

(require 'ert)

(load (expand-file-name
       "../zr-ffmpeg.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

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

(provide 'zr-ffmpeg-test)

;;; zr-ffmpeg-test.el ends here
