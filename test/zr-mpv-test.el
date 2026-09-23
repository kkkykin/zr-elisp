;;; zr-mpv-test.el --- Tests for zr-mpv -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for `zr-mpv' covering path transformations, media detection,
;; directory expansion, backend detection, and each playback backend
;; (local, WezTerm, HTTP, Android) plus IPC and DWIM contexts.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dired)

(load (expand-file-name
       "../zr-mpv.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

;;; Path Transformations

(ert-deftest zr-mpv-test-path-transform-string-and-function ()
  "Test string replacement and function transformation in `zr-mpv-transform-path'."
  (let ((zr-mpv-path-transform-alist
         `((,(rx bos "/remote/" (group (*? nonl)) eos) . "/mnt/local/\\1")
           (,(rx bos "/nas/" (group (*? nonl)) eos)
            . ,(lambda (path md)
                 (format "http://nas.lan/%s" (match-string 1 path)))))))
    ;; String replacement
    (should (equal "/mnt/local/video.mkv"
                   (zr-mpv-transform-path "/remote/video.mkv")))
    ;; Function replacement
    (should (equal "http://nas.lan/music.flac"
                   (zr-mpv-transform-path "/nas/music.flac")))
    ;; No match
    (should (equal "/other/path.mp4"
                   (zr-mpv-transform-path "/other/path.mp4")))
    ;; Non-string input
    (should (null (zr-mpv-transform-path nil)))))

(ert-deftest zr-mpv-test-path-transform-cascading ()
  "Test that multiple rules cascade in sequence."
  (let ((zr-mpv-path-transform-alist
         '(("foo" . "bar")
           ("bar" . "baz"))))
    (should (equal "/path/baz/file.mp4"
                   (zr-mpv-transform-path "/path/foo/file.mp4")))))

;;; Media File Recognition

(ert-deftest zr-mpv-test-media-recognition ()
  "Test detection of media files by extension and regex."
  (should (zr-mpv-media-file-p "movie.mp4"))
  (should (zr-mpv-media-file-p "AUDIO.FLAC"))
  (should (zr-mpv-media-file-p "playlist.m3u8"))
  (should (zr-mpv-media-file-p "photo.jpg"))
  (should-not (zr-mpv-media-file-p "source.el"))
  (should-not (zr-mpv-media-file-p "doc.txt"))
  (should-not (zr-mpv-media-file-p "noextension"))
  (should-not (zr-mpv-media-file-p nil))
  (should (string-match-p (zr-mpv-media-regexp) "video.webm"))
  (should-not (string-match-p (zr-mpv-media-regexp) "script.py")))

;;; File Normalization & Playlist Generation

(ert-deftest zr-mpv-test-normalize-files-list-and-string ()
  "Test normalization of list, string, and buffer inputs."
  (let ((zr-mpv-path-transform-alist '(("^/a/" . "/b/"))))
    ;; List input
    (should (equal '("/b/1.mp4" "/b/2.mkv")
                   (zr-mpv-normalize-files '("/a/1.mp4" "  " "/a/2.mkv"))))
    ;; String input with newlines and whitespace
    (should (equal '("/b/1.mp4" "/b/2.mkv")
                   (zr-mpv-normalize-files "/a/1.mp4\n  \n/a/2.mkv\n")))
    ;; Buffer input
    (with-temp-buffer
      (insert "/a/track1.mp3\n\n/a/track2.mp3\n")
      (should (equal '("/b/track1.mp3" "/b/track2.mp3")
                     (zr-mpv-normalize-files (current-buffer)))))
    ;; Empty input
    (should (null (zr-mpv-normalize-files nil)))
    (should (null (zr-mpv-normalize-files "")))))

(ert-deftest zr-mpv-test-format-playlist ()
  "Test M3U playlist generation."
  (should (equal "#EXTM3U\n/path/1.mp4\n/path/2.mkv\n"
                 (zr-mpv-format-playlist '("/path/1.mp4" "/path/2.mkv"))))
  (should (equal "#EXTM3U\n"
                 (zr-mpv-format-playlist nil))))

;;; Directory Expansion

(ert-deftest zr-mpv-test-expand-directory ()
  "Test recursive media collection and sorting from a directory."
  (let* ((temp-dir (make-temp-file "zr-mpv-test-dir-" t))
         (sub-dir (expand-file-name "sub" temp-dir)))
    (unwind-protect
        (progn
          (make-directory sub-dir t)
          (write-region "" nil (expand-file-name "ep2.mp4" temp-dir) nil 'silent)
          (write-region "" nil (expand-file-name "ep10.mp4" temp-dir) nil 'silent)
          (write-region "" nil (expand-file-name "ep1.mp4" temp-dir) nil 'silent)
          (write-region "" nil (expand-file-name "notes.txt" temp-dir) nil 'silent)
          (write-region "" nil (expand-file-name "ep3.mkv" sub-dir) nil 'silent)
          (let ((expanded (zr-mpv-expand-directory temp-dir)))
            (should (= 4 (length expanded)))
            ;; string-version-lessp sorts ep1, ep2, ep10
            (should (equal (mapcar #'file-name-nondirectory expanded)
                           '("ep1.mp4" "ep2.mp4" "ep10.mp4" "ep3.mkv")))))
      (delete-directory temp-dir t))))

;;; Backend Detection

(ert-deftest zr-mpv-test-detect-backend ()
  "Test environment-based backend auto-detection."
  ;; WezTerm
  (cl-letf (((symbol-function 'getenv)
             (lambda (var &optional _frame)
               (cond ((equal var "TERM_PROGRAM") "WezTerm")
                     (t nil)))))
    (should (eq 'wezterm (zr-mpv-detect-backend))))
  ;; SSH Connection
  (cl-letf (((symbol-function 'getenv)
             (lambda (var &optional _frame)
               (cond ((equal var "SSH_CONNECTION") "192.168.1.1 22 192.168.1.2 55555")
                     (t nil)))))
    (should (eq 'http (zr-mpv-detect-backend))))
  ;; Default / Local
  (cl-letf (((symbol-function 'getenv) (lambda (&rest _) nil)))
    (should (eq 'local (zr-mpv-detect-backend)))))

;;; Local Backend

(ert-deftest zr-mpv-test-play-local-command-and-pipe ()
  "Test local process invocation with arguments, IPC server, and stdin."
  (let ((zr-mpv-program "fake-mpv")
        (zr-mpv-ipc-server "/tmp/fake-mpv.sock")
        (zr-mpv-default-arguments '("--terminal=no"))
        recorded-args
        sent-payload
        eof-called)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (setq recorded-args (plist-get plist :command))
                 'fake-process))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (setq sent-payload string)))
              ((symbol-function 'process-send-eof)
               (lambda (_proc)
                 (setq eof-called t))))
      (let ((res (zr-mpv-play-local '("/path/a.mp4" "/path/b.mkv")
                                    "--speed=1.5 --volume=80")))
        (should (equal 'fake-process res))
        (should (equal '("fake-mpv"
                         "--input-ipc-server=/tmp/fake-mpv.sock"
                         "--terminal=no"
                         "--speed=1.5"
                         "--volume=80"
                         "--playlist=-")
                       recorded-args))
        (should (equal "#EXTM3U\n/path/a.mp4\n/path/b.mkv\n" sent-payload))
        (should eof-called)))
    ;; Error on empty files
    (should-error (zr-mpv-play-local nil) :type 'user-error)))

;;; WezTerm Backend

(ert-deftest zr-mpv-test-play-wezterm ()
  "Test WezTerm backend builds JSON payload and sends to `zr-wezterm-send-json'."
  (let ((zr-mpv-default-arguments '("--terminal=no"))
        sent-json)
    (cl-letf (((symbol-function 'zr-wezterm-send-json)
               (lambda (obj)
                 (setq sent-json obj)
                 t)))
      (zr-mpv-play-wezterm '("/movie/a.mp4" "/movie/b.mp4") "--loop-file")
      (should (equal "mpv" (cdr (assoc 'type sent-json))))
      (should (equal ["--terminal=no" "--loop-file"]
                     (cdr (assoc 'args sent-json))))
      (should (equal "/movie/a.mp4\n/movie/b.mp4"
                     (cdr (assoc 'stdin sent-json)))))))

;;; HTTP Backend

(ert-deftest zr-mpv-test-play-http ()
  "Test HTTP backend request headers and payload."
  (let ((zr-mpv-http-url "http://example.com/mpv/")
        (zr-mpv-http-auth-host "mpv.local")
        (zr-mpv-default-arguments '("--no-audio"))
        url-called
        method-called
        headers-called
        data-called)
    (cl-letf (((symbol-function 'auth-source-user-and-password)
               (lambda (_host) '("alice" "secret123")))
              ((symbol-function 'getenv)
               (lambda (var &rest _)
                 (when (equal var "SSH_CONNECTION") "1.2.3.4 22 5.6.7.8 9999")))
              ((symbol-function 'system-name) (lambda () "testhost"))
              ((symbol-function 'url-retrieve)
               (lambda (url &rest _)
                 (setq url-called url
                       method-called url-request-method
                       headers-called url-request-extra-headers
                       data-called url-request-data))))
      (zr-mpv-play-http '("/video/1.mp4") "--pause")
      (should (equal "http://example.com/mpv/" url-called))
      (should (equal "POST" method-called))
      (should (equal "application/json" (cdr (assoc "Content-Type" headers-called))))
      (should (equal "ssh://testhost" (cdr (assoc "Origin" headers-called))))
      (should (equal (concat "Basic " (base64-encode-string "alice:secret123" t))
                     (cdr (assoc "Authorization" headers-called))))
      (let ((parsed (json-parse-string data-called :object-type 'alist)))
        (should (equal ["--no-audio" "--pause"] (cdr (assoc 'args parsed))))
        (should (equal "/video/1.mp4" (cdr (assoc 'stdin parsed))))))))

;;; Android Playlist Server & Playback

(ert-deftest zr-mpv-test-serve-playlist-and-android-proc ()
  "Test M3U8 temporary server provides valid HTTP response and android am call."
  (let* ((server (zr-mpv-serve-playlist '("http://stream/1.mp4") 10))
         (port (process-contact server :service))
         received-response)
    (unwind-protect
        (let ((client
               (make-network-process
                :name "test-client"
                :host "127.0.0.1"
                :service port
                :filter (lambda (_proc string)
                          (setq received-response
                                (concat received-response string))))))
          (sleep-for 0.2)
          (delete-process client)
          (should (string-prefix-p "HTTP/1.1 200 OK\r\n" received-response))
          (should (string-search "application/vnd.apple.mpegurl" received-response))
          (should (string-search "#EXTM3U\nhttp://stream/1.mp4\n" received-response)))
      (when (process-live-p server)
        (delete-process server))))

  ;; Test zr-mpv-play-android command call
  (let (call-args)
    (cl-letf (((symbol-function 'zr-mpv-serve-playlist)
               (lambda (_files &optional _timeout)
                 (let ((proc (make-network-process
                              :name "fake-srv"
                              :server t
                              :service t
                              :host "127.0.0.1")))
                   proc)))
              ((symbol-function 'call-process)
               (lambda (prog &rest args)
                 (setq call-args (cons prog args))
                 0)))
      (zr-mpv-play-android '("http://stream/1.mp4"))
      (should (equal "termux-am" (car call-args)))
      (should (member "android.intent.action.VIEW" call-args))
      (should (member "is.xyz.mpv.ytdl" call-args)))))

;;; DWIM File Collection

(ert-deftest zr-mpv-test-collect-dwim-files ()
  "Test DWIM collection from region, buffer file, and Dired."
  ;; 1. Active region
  (with-temp-buffer
    (insert "http://example.com/v1.mp4\nhttp://example.com/v2.mp4\n")
    (set-mark (point-min))
    (goto-char (point-max))
    (activate-mark)
    (should (equal '("http://example.com/v1.mp4" "http://example.com/v2.mp4")
                   (zr-mpv-collect-dwim-files))))

  ;; 2. Buffer visiting a file
  (let ((buffer-file-name "/home/user/song.flac"))
    (should (equal '("/home/user/song.flac")
                   (zr-mpv-collect-dwim-files))))

  ;; 3. Dired mode
  (let ((temp-dir (make-temp-file "zr-mpv-dired-test-" t)))
    (unwind-protect
        (let ((file1 (expand-file-name "track1.mp3" temp-dir))
              (file2 (expand-file-name "track2.mp3" temp-dir)))
          (write-region "" nil file1 nil 'silent)
          (write-region "" nil file2 nil 'silent)
          (let ((buf (dired-noselect temp-dir)))
            (unwind-protect
                (with-current-buffer buf
                  (dired-mark-files-regexp "track.*\\.mp3")
                  (let ((files (zr-mpv-collect-dwim-files)))
                    (should (member file1 files))
                    (should (member file2 files))))
              (kill-buffer buf))))
      (delete-directory temp-dir t))))

;;; IPC Commands

(ert-deftest zr-mpv-test-ipc-send ()
  "Test IPC payload generation and send."
  (let ((zr-mpv-ipc-server "/tmp/mock-mpv.sock")
        sent-string
        connected)
    (cl-letf (((symbol-function 'make-network-process)
               (lambda (&rest plist)
                 (setq connected (plist-get plist :service))
                 'fake-ipc-proc))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (setq sent-string string)))
              ((symbol-function 'delete-process) #'ignore))
      (should (zr-mpv-ipc-send '("cycle" "pause")))
      (should (equal "/tmp/mock-mpv.sock" connected))
      (should (equal "{\"command\":[\"cycle\",\"pause\"]}\n" sent-string)))))

;;; Dispatcher

(ert-deftest zr-mpv-test-play-dispatcher ()
  "Test `zr-mpv-play' dispatches to appropriate backend or custom function."
  (let (dispatched)
    (cl-letf (((symbol-function 'zr-mpv-play-local)
               (lambda (f a) (setq dispatched (list 'local f a))))
              ((symbol-function 'zr-mpv-play-wezterm)
               (lambda (f a) (setq dispatched (list 'wezterm f a))))
              ((symbol-function 'zr-mpv-play-http)
               (lambda (f a) (setq dispatched (list 'http f a)))))
      ;; Local
      (zr-mpv-play '("/f.mp4") "-v" 'local)
      (should (equal '(local ("/f.mp4") "-v") dispatched))
      ;; WezTerm
      (zr-mpv-play '("/f.mp4") nil 'wezterm)
      (should (equal '(wezterm ("/f.mp4") nil) dispatched))
      ;; HTTP
      (zr-mpv-play '("/f.mp4") nil 'http)
      (should (equal '(http ("/f.mp4") nil) dispatched))
      ;; Custom function
      (zr-mpv-play '("/f.mp4") nil (lambda (f _a) (setq dispatched (list 'custom f))))
      (should (equal '(custom ("/f.mp4")) dispatched)))))

(provide 'zr-mpv-test)
;;; zr-mpv-test.el ends here
