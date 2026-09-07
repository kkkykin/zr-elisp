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
          (plist-get page :subtitle-source) subtitle)
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
     ,@body))

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
