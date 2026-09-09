;;; zr-rclone-test.el --- RC and Virtual Dired tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Pure UI/path tests always run.  Integration tests use an isolated local
;; rcd when rclone is available, or RCLONE_TEST_PROGRAM names its executable.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../zr-rclone.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defvar zr-rclone-test--connection nil)
(defvar zr-rclone-test--root nil)
(defvar zr-rclone-test--serial 0)

(defun zr-rclone-test--stop ()
  "Stop only the isolated test daemon and remove its fixtures."
  (when zr-rclone-test--connection
    (when (zr-rclone-connection-timer zr-rclone-test--connection)
      (cancel-timer (zr-rclone-connection-timer zr-rclone-test--connection)))
    (when (process-live-p (zr-rclone-connection-process zr-rclone-test--connection))
      (delete-process (zr-rclone-connection-process zr-rclone-test--connection)))
    (dolist (buffer (list (zr-rclone-connection-buffer zr-rclone-test--connection)
                          (zr-rclone-connection-job-buffer zr-rclone-test--connection)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (setq zr-rclone-test--connection nil))
  (when (and zr-rclone-test--root (file-directory-p zr-rclone-test--root))
    (delete-directory zr-rclone-test--root t))
  (setq zr-rclone-test--root nil))

(add-hook 'kill-emacs-hook #'zr-rclone-test--stop)

(defun zr-rclone-test--start ()
  "Start the shared isolated rcd fixture if necessary."
  (let ((program (or (getenv "RCLONE_TEST_PROGRAM") (executable-find "rclone"))))
    (unless program (ert-skip "Set RCLONE_TEST_PROGRAM or install rclone"))
    (unless (and zr-rclone-test--connection
                 (process-live-p (zr-rclone-connection-process zr-rclone-test--connection)))
      (setq zr-rclone-test--root (make-temp-file "zr-rclone-test-" t))
      (let* ((socket (make-network-process :name "zr-rclone-test-port" :server t
                                           :host "127.0.0.1" :family 'ipv4
                                           :service t :noquery t))
             (port (process-contact socket :service))
             (zr-rclone-program program)
             (zr-rclone-config-file (expand-file-name "rclone.conf" zr-rclone-test--root))
             (zr-rclone-rcd-arguments
              (list "--rc-serve" "--cache-dir"
                    (expand-file-name "cache" zr-rclone-test--root))))
        (delete-process socket)
        (with-temp-file zr-rclone-config-file
          (insert "[fixture]\ntype = alias\nremote = " zr-rclone-test--root "\n"))
        (save-window-excursion
          (setq zr-rclone-test--connection
                (zr-rclone-start-daemon (format "127.0.0.1:%s" port))))))
    zr-rclone-test--connection))

(defmacro zr-rclone-test--with-server (&rest body)
  "Run BODY with a real authenticated CONNECTION and isolated directory."
  (declare (indent 0) (debug body))
  `(let* ((zr-rclone-program (or (getenv "RCLONE_TEST_PROGRAM") "rclone"))
          (zr-rclone-timeout 5)
          (zr-rclone-poll-interval 0.05)
          (url-proxy-services '(("no_proxy" . ".*")))
          (auth-sources nil)
          (connection (zr-rclone-test--start))
          (name (format "case-%d" (cl-incf zr-rclone-test--serial)))
          (local (expand-file-name name zr-rclone-test--root))
          (remote (concat "fixture:" name)))
     (make-directory local)
     (setf (zr-rclone-connection-transport connection) 'http)
     (with-current-buffer (zr-rclone--buffer connection)
       (setq zr-rclone-current-path remote zr-rclone-target-path nil
             zr-rclone-call-options nil zr-rclone-bisync-options nil
             zr-rclone-dry-run nil)
       ,@body)))

(defun zr-rclone-test--wait (job connection)
  "Wait for JOB on CONNECTION to finish."
  (let ((deadline (+ (float-time) 15)))
    (while (and (not (plist-get job :finished)) (< (float-time) deadline))
      (zr-rclone--poll-jobs connection)
      (accept-process-output nil 0.05))
    (should (plist-get job :finished))
    job))

(ert-deftest zr-rclone-json-options-preserve-arrays ()
  (let ((input "{\"_filter\":{\"IncludeRule\":[\"*.mkv\"],\"ExcludeRule\":[]},\"_config\":{\"DryRun\":false}}"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) input)))
      (let* ((options (zr-rclone--read-json "Options: " nil))
             (encoded (zr-rclone--json options))
             (filter (alist-get '_filter (zr-rclone--parse-json encoded))))
        (should (equal (alist-get 'IncludeRule filter) ["*.mkv"]))
        (should (equal (alist-get 'ExcludeRule filter) []))
        (should (eq (alist-get 'DryRun (alist-get '_config options)) :false))))))

(ert-deftest zr-rclone-paths-preserve-server-namespace ()
  (dolist (case '(("drive:music/live" "drive:" "music/live")
                  ("drive:/music/live" "drive:/" "music/live")
                  ("/srv/music" "/" "srv/music")
                  ("C:/Music/live" "C:/" "Music/live")
                  ("C:\\Music\\live" "C:/" "Music/live")
                  ("//host/share/music" "//host/share/" "music")
                  ("\\\\host\\share\\music" "//host/share/" "music")
                  (":webdav,url='https://host:8443/dav':music"
                   ":webdav,url='https://host:8443/dav':" "music")))
    (should (equal (zr-rclone--split-path (car case))
                   (cons (cadr case) (caddr case)))))
  (should (equal (zr-rclone--resolve-path "../other" "drive:music/live")
                 "drive:music/other"))
  (should (equal (zr-rclone--parent "drive:/music") "drive:/"))
  (should-not (zr-rclone--parent "drive:/"))
  (should-not (zr-rclone--relative-to "drive:music2/a" "drive:music"))
  (should (equal (zr-rclone--relative-to "drive:music/a" "drive:music") "a"))
  (should-error (zr-rclone--resolve-path "relative")))

(ert-deftest zr-rclone-command-quoting-is-not-shell-evaluation ()
  (should (equal (zr-rclone--command-words
                  "copy '源 file' \"target file\" --include='*.mkv' '' a\\ b")
                 '("copy" "源 file" "target file" "--include=*.mkv" "" "a b")))
  (should (equal (zr-rclone--command-words "lsjson \"C:\\Music\"")
                 '("lsjson" "C:\\Music")))
  (should-error (zr-rclone--command-words "copy a | cat"))
  (should-error (zr-rclone--command-words "ls 'unfinished"))
  (should-error (zr-rclone--command-words "ls unfinished\\")))

(ert-deftest zr-rclone-virtual-dired-keeps-original-entries-and-order ()
  (with-temp-buffer
    (zr-rclone-dired-mode)
    (setq zr-rclone--entries
          (mapcar (lambda (name) (list :fs "drive:dir" :path name :name name :size 7))
                  '("a space.txt" "b\nnewline.txt" "c\\backslash.txt")))
    (cl-letf (((symbol-function 'insert-directory)
               (lambda (&rest _) (ert-fail "Virtual listing read a filesystem"))))
      (zr-rclone--render)
      (should (derived-mode-p 'dired-mode))
      (dired-mark 2)
      (should (equal (mapcar (lambda (entry) (plist-get entry :path))
                             (zr-rclone--selected))
                     '("a space.txt" "b\nnewline.txt")))
      (should (equal (zr-rclone--display-name "c\\backslash.txt") "c\\\\backslash.txt"))
      (let ((saved (zr-rclone--marks)))
        (zr-rclone--render saved)
        (should (= (length (zr-rclone--selected)) 2)))
      (should (eq revert-buffer-function #'zr-rclone-refresh))
      (should (eq (lookup-key (current-local-map) (kbd "C")) #'zr-rclone-copy))
      (should-not (lookup-key (current-local-map) (kbd "Z"))))))

(ert-deftest zr-rclone-directory-failure-preserves-state ()
  (with-temp-buffer
    (zr-rclone-dired-mode)
    (setq zr-rclone--connection (zr-rclone--make-connection :connected t)
          zr-rclone-current-path "drive:old"
          zr-rclone-target-path "backup:target")
    (cl-letf (((symbol-function 'zr-rclone--list-entries)
               (lambda (&rest _) (error "Directory unavailable"))))
      (should-error (zr-rclone-cd "drive:missing"))
      (should (equal zr-rclone-current-path "drive:old"))
      (should (equal zr-rclone-target-path "backup:target")))))

(ert-deftest zr-rclone-webdav-url-mapping-and-tramp-names ()
  (let ((mapping '(:root "drive:media" :url "https://host:8443/dav/")))
    (should (equal (zr-rclone--mapping-url mapping "drive:media/中文 %?#.mkv")
                   "https://host:8443/dav/%E4%B8%AD%E6%96%87%20%25%3F%23.mkv"))
    (should-not (zr-rclone--mapping-url mapping "drive:media-other/a"))
    (should (equal (zr-rclone--webdav-name
                    (zr-rclone--mapping-url mapping "drive:media/中文 %?#.mkv") "alice")
                   "/webdavs:alice@host#8443:/dav/中文 %?#.mkv"))))

(ert-deftest zr-rclone-real-authenticated-transports ()
  (zr-rclone-test--with-server
    (should (zr-rclone-connection-local-p connection))
    (dolist (transport '(http cli))
      (setf (zr-rclone-connection-transport connection) transport)
      (ert-info ((format "Transport %s" transport))
        (let* ((params '((text . "中文 %?#") (enabled . t) (disabled . :false)
                         (nested . ((list . [1 "two"])))))
               (result (zr-rclone--call connection "rc/noop" params)))
          (should (equal (alist-get 'text result) "中文 %?#"))
          (should (eq (alist-get 'disabled result) :false))
          (should (equal (alist-get 'list (alist-get 'nested result)) [1 "two"])))
        (should-error (zr-rclone--call connection "operations/list"))
        (let ((password (zr-rclone-connection-password connection)))
          (unwind-protect
              (progn
                (setf (zr-rclone-connection-password connection) "wrong-test-password")
                (should-error (zr-rclone--call connection "rc/noop")))
            (setf (zr-rclone-connection-password connection) password)))))))

(ert-deftest zr-rclone-real-copy-move-delete-and-completion ()
  (zr-rclone-test--with-server
    (let* ((name "中文 file %?#.txt")
           (destination (concat remote "/destination"))
           (local-destination (expand-file-name "destination" local)))
      (write-region "original bytes" nil (expand-file-name name local) nil 'silent)
      (make-directory local-destination)
      (zr-rclone-refresh)
      (should (member (concat remote "/destination/")
                      (zr-rclone--path-completions connection (concat remote "/d") nil t)))
      (dolist (transport '(http cli))
        (setf (zr-rclone-connection-transport connection) transport)
        (let* ((entry (cl-find name zr-rclone--entries :test #'equal
                               :key (lambda (entry) (plist-get entry :name))))
               (copy-name (concat destination "/" (symbol-name transport) ".txt"))
               (plan (zr-rclone--transfer-plan entry copy-name nil))
               (job (zr-rclone--submit (car plan) (cadr plan) "test copy")))
          (should (equal (plist-get (zr-rclone-test--wait job connection) :state) "done"))
          (should (equal (with-temp-buffer
                           (insert-file-contents (expand-file-name
                                                 (concat (symbol-name transport) ".txt")
                                                 local-destination))
                           (buffer-string)) "original bytes"))))
      (let* ((entry (list :fs destination :path "http.txt" :name "http.txt"))
             (plan (zr-rclone--transfer-plan entry (concat destination "/renamed.txt") t)))
        (zr-rclone-test--wait (zr-rclone--submit (car plan) (cadr plan) "test rename")
                              connection))
      (should-not (file-exists-p (expand-file-name "http.txt" local-destination)))
      (should (file-exists-p (expand-file-name "renamed.txt" local-destination)))
      (zr-rclone-test--wait
       (zr-rclone--submit "operations/deletefile"
                          (list (cons 'fs destination) '(remote . "renamed.txt"))
                          "test delete") connection)
      (should-not (file-exists-p (expand-file-name "renamed.txt" local-destination))))))

(ert-deftest zr-rclone-real-json-listing-and-filter-options ()
  (zr-rclone-test--with-server
    (let ((source (expand-file-name "source" local))
          (target (expand-file-name "target" local)))
      (make-directory source)
      (write-region "included" nil (expand-file-name "keep.mkv" source) nil 'silent)
      (write-region "excluded" nil (expand-file-name "skip.txt" source) nil 'silent)
      (setq zr-rclone-current-path (concat remote "/source")
            zr-rclone-target-path (concat remote "/target"))
      (save-window-excursion
        (let ((listing (zr-rclone-list-json)))
          (unwind-protect
              (with-current-buffer listing
                (let ((entries (alist-get 'list (zr-rclone--parse-json (buffer-string)))))
                  (should (vectorp entries))
                  (should (equal (sort (mapcar (lambda (entry) (alist-get 'Name entry))
                                               entries)
                                       #'string-lessp)
                                 '("keep.mkv" "skip.txt")))))
            (kill-buffer listing))))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "{\"_filter\":{\"IncludeRule\":[\"*.mkv\"]}}"))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (zr-rclone-set-call-options)
        (let ((job (zr-rclone-sync)))
          (zr-rclone-test--wait job connection)
          (should (equal (plist-get job :state) "done"))))
      (should (file-exists-p (expand-file-name "keep.mkv" target)))
      (should-not (file-exists-p (expand-file-name "skip.txt" target))))))

(ert-deftest zr-rclone-real-dry-run-and-temporary-command-results ()
  (zr-rclone-test--with-server
    (let* ((file (expand-file-name "preserved.txt" local))
           (zr-rclone-dry-run t))
      (write-region "keep" nil file nil 'silent)
      (zr-rclone-test--wait
       (zr-rclone--submit "operations/deletefile"
                          (list (cons 'fs remote) '(remote . "preserved.txt"))
                          "dry-run delete") connection)
      (should (file-exists-p file))
      (let* ((job (zr-rclone-command (format "lsjson '%s'" remote)))
             (output (plist-get (zr-rclone-test--wait job connection) :output)))
        (should (equal (plist-get job :state) "done"))
        (should (string-match-p "preserved.txt" (alist-get 'result output))))
      (let ((job (zr-rclone-command "not-an-rclone-command")))
        (zr-rclone-test--wait job connection)
        (should (equal (plist-get job :state) "failed"))
        (should (stringp (plist-get job :error)))))))

(ert-deftest zr-rclone-real-sync-and-bisync ()
  (zr-rclone-test--with-server
    (let ((source (expand-file-name "source" local))
          (target (expand-file-name "target" local)))
      (make-directory source)
      (make-directory target)
      (write-region "source" nil (expand-file-name "a.txt" source) nil 'silent)
      (write-region "obsolete" nil (expand-file-name "old.txt" target) nil 'silent)
      (setq zr-rclone-current-path (concat remote "/source")
            zr-rclone-target-path (concat remote "/target")
            zr-rclone-bisync-options
            (list (cons 'workdir (expand-file-name "bisync-state" local))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (let ((job (zr-rclone-sync)))
          (zr-rclone-test--wait job connection)
          (should (equal (plist-get job :state) "done")))
        (should (file-exists-p (expand-file-name "a.txt" target)))
        (should-not (file-exists-p (expand-file-name "old.txt" target)))
        (let ((job (zr-rclone-bisync t)))
          (zr-rclone-test--wait job connection)
          (should (equal (plist-get job :state) "done")))
        (write-region "new from source" nil (expand-file-name "from-source.txt" source)
                      nil 'silent)
        (write-region "new from target" nil (expand-file-name "from-target.txt" target)
                      nil 'silent)
        (let ((job (zr-rclone-bisync)))
          (zr-rclone-test--wait job connection)
          (should (equal (plist-get job :state) "done")))
        (should (file-exists-p (expand-file-name "from-source.txt" target)))
        (should (file-exists-p (expand-file-name "from-target.txt" source)))))))

(ert-deftest zr-rclone-real-job-cancellation ()
  (zr-rclone-test--with-server
    (let ((source (expand-file-name "large.bin" local)))
      (write-region (make-string 65536 ?x) nil source nil 'silent)
      (let* ((job (zr-rclone-command
                   (format
                    "copyto '%s/large.bin' '%s/slow-copy.bin' --bwlimit=1k --disable=Copy --multi-thread-streams=0"
                    remote remote)))
             (jobs-buffer (generate-new-buffer " *zr-rclone-cancel-test*")))
        (unwind-protect
            (with-current-buffer jobs-buffer
              (zr-rclone-jobs-mode)
              (setq zr-rclone--connection connection)
              (cl-letf (((symbol-function 'zr-rclone--job-at-point) (lambda () job)))
                (zr-rclone-cancel-job))
              (zr-rclone-test--wait job connection)
              (should (equal (plist-get job :state) "failed")))
          (kill-buffer jobs-buffer))))))

(defun zr-rclone-test--get (url credentials &optional range)
  "Fetch URL with CREDENTIALS and optional RANGE, returning (STATUS . BODY)."
  (let* ((url-request-method "GET")
         (url-request-extra-headers
          (append (when credentials
                    (list (cons "Authorization" (zr-rclone--basic-header credentials))))
                  (when range (list (cons "Range" range)))))
         (url-show-status nil)
         (buffer (url-retrieve-synchronously url t t 5)))
    (unless buffer (ert-fail "No HTTP response"))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (should (re-search-forward "\r?\n\r?\n" nil t))
          (cons url-http-response-status
                (buffer-substring-no-properties (point) (point-max))))
      (kill-buffer buffer))))

(ert-deftest zr-rclone-real-webdav-and-http-playback-urls ()
  (zr-rclone-test--with-server
    (require 'zr-tramp-webdav)
    (let ((name "中 文 %?#.txt")
          (zr-tramp-webdav-extra-headers nil)
          (zr-rclone--webdav-auth nil)
          (zr-rclone--previous-webdav-headers nil)
          (zr-tramp-webdav-backend 'curl))
      (write-region "0123456789" nil (expand-file-name name local) nil 'silent)
      (zr-rclone-refresh)
      (zr-rclone-serve-webdav)
      (let* ((mapping (car (zr-rclone-connection-mappings connection)))
             (entry (car zr-rclone--entries))
             (media (zr-rclone--media connection entry nil))
             (rc-media (zr-rclone--media connection entry t)))
        (unwind-protect
            (progn
              (should (equal (zr-rclone-test--get (car media) (cdr media) "bytes=2-5")
                             '(206 . "2345")))
              (should (equal (zr-rclone-test--get (car rc-media) (cdr rc-media))
                             '(200 . "0123456789")))
              (save-window-excursion
                (save-current-buffer
                  (zr-rclone-open-current-webdav)
                  (let ((dav-buffer (current-buffer)))
                    (unwind-protect
                        (progn
                          (should (derived-mode-p 'dired-mode))
                          (should (member name (directory-files default-directory)))
                          (let ((file (concat default-directory name)))
                            (with-temp-buffer
                              (insert-file-contents file)
                              (should (equal (buffer-string) "0123456789")))
                            (write-region "saved via WebDAV" nil file nil 'silent)))
                      (kill-buffer dav-buffer)))))
              (should (equal (with-temp-buffer
                               (insert-file-contents (expand-file-name name local))
                               (buffer-string))
                             "saved via WebDAV")))
          (zr-rclone--call connection "serve/stop" (list (cons 'id (plist-get mapping :id))))
          (zr-rclone--forget-webdav mapping)
          (setf (zr-rclone-connection-mappings connection) nil))))))

(ert-deftest zr-rclone-webdav-auth-stays-with-origin-root-and-user ()
  (require 'zr-tramp-webdav)
  (let ((zr-tramp-webdav-extra-headers '(("X-Test" . "preserved")))
        (zr-rclone--webdav-auth nil)
        (zr-rclone--previous-webdav-headers nil)
        (mapping '(:root "drive:" :url "https://host/dav/")))
    (zr-rclone--install-webdav-credentials mapping '("alice" . "test-secret"))
    (should (assoc "Authorization"
                   (zr-rclone--webdav-headers "/webdavs:alice@host:/dav/file")))
    (dolist (file '("/webdavs:bob@host:/dav/file" "/webdavs:alice@elsewhere:/dav/file"
                    "/webdav:alice@host:/dav/file" "/webdavs:alice@host:/dav-other/file"))
      (should (equal (zr-rclone--webdav-headers file) '(("X-Test" . "preserved")))))
    (zr-rclone--forget-webdav mapping)
    (should-not zr-rclone--webdav-auth)))

(ert-deftest zr-rclone-mpv-receives-playlist-and-private-auth ()
  (unless (executable-find "python3") (ert-skip "Python 3 is required"))
  (let* ((directory (make-temp-file "zr-rclone-mpv-test-" t))
         (program (expand-file-name "fake mpv" directory))
         (capture (expand-file-name "capture.json" directory))
         (zr-rclone-mpv-program program)
         (zr-rclone-mpv-arguments nil)
         process)
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/usr/bin/env python3\nimport sys,json,os\n"
                    "config=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--include='))\n"
                    "data={'argv':sys.argv,'playlist':sys.stdin.read(),'config':config,"
                    "'mode':os.stat(config).st_mode & 511,"
                    "'basic': 'Authorization: Basic ' in open(config).read()}\n"
                    (format "with open(%S,'w') as out: json.dump(data,out)\n" capture)))
          (set-file-modes program #o700)
          (setq process
                (zr-rclone--launch-mpv
                 '(("https://host/a%20b.mkv" "alice" . "test-secret")
                   ("https://host/c.mkv" "alice" . "test-secret"))))
          (let ((deadline (+ (float-time) 5)))
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (should (= (process-exit-status process) 0))
          (let ((data (with-temp-buffer
                        (insert-file-contents capture)
                        (zr-rclone--parse-json (buffer-string)))))
            (should (equal (alist-get 'playlist data)
                           "#EXTM3U\nhttps://host/a%20b.mkv\nhttps://host/c.mkv\n"))
            (should (= (alist-get 'mode data) #o600))
            (should (eq (alist-get 'basic data) t))
            (should-not (string-match-p "test-secret"
                                        (string-join (alist-get 'argv data) " ")))
            (should-not (file-exists-p (alist-get 'config data)))))
      (when (process-live-p process) (delete-process process))
      (delete-directory directory t))))

(ert-deftest zr-rclone-http-timeout-and-cancel-complete-once ()
  (let* ((clients nil)
         (server (make-network-process
                  :name "zr-rclone-timeout-server" :server t :host "127.0.0.1"
                  :family 'ipv4 :service t :noquery t :filter #'ignore
                  :log (lambda (_server client _message) (push client clients))))
         (connection (zr-rclone--make-connection
                      :url (format "http://127.0.0.1:%s/" (process-contact server :service))))
         (zr-rclone-timeout 0.1)
         (url-proxy-services '(("no_proxy" . ".*")))
         (auth-sources nil))
    (unwind-protect
        (dolist (cancel-p '(nil t))
          (let ((count 0) failure
                (deadline (+ (float-time) 2)))
            (let ((cancel (zr-rclone--request
                           connection "rc/noop" nil
                           (lambda (_result error) (cl-incf count) (setq failure error)))))
              (when cancel-p (funcall cancel))
              (while (and (zerop count) (< (float-time) deadline))
                (accept-process-output nil 0.05))
              (should (= count 1))
              (should (string-match-p (if cancel-p "cancelled" "timed out") failure))
              (funcall cancel)
              (should (= count 1)))))
      (mapc #'delete-process clients)
      (delete-process server))))

(ert-deftest zr-rclone-mount-reads-path-on-the-correct-machine ()
  (dolist (local-p '(nil t))
    (with-temp-buffer
      (zr-rclone-dired-mode)
      (setq zr-rclone--connection (zr-rclone--make-connection
                                   :connected t :local-p local-p)
            zr-rclone-current-path "drive:music"
            zr-rclone-mount-options '((vfsOpt . ((CacheMode . "writes")))))
      (let (reader request)
        (cl-letf (((symbol-function 'read-directory-name)
                   (lambda (&rest _) (setq reader 'local) "/mnt/local path"))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) (setq reader 'server) "/mnt/server path"))
                  ((symbol-function 'zr-rclone--submit)
                   (lambda (method params &rest _) (setq request (cons method params)))))
          (zr-rclone-mount))
        (should (eq reader (if local-p 'local 'server)))
        (should (equal (car request) "mount/mount"))
        (should (equal (alist-get 'fs (cdr request)) "drive:music"))
        (should (equal (alist-get 'mountPoint (cdr request))
                       (if local-p "/mnt/local path" "/mnt/server path")))))))

(ert-deftest zr-rclone-cancel-does-not-overwrite-a-concurrent-completion ()
  (with-temp-buffer
    (zr-rclone-jobs-mode)
    (let* ((connection (zr-rclone--make-connection :connected t))
           (job (list :id 1 :instance "instance" :finished nil :state "running")))
      (setq zr-rclone--connection connection)
      (cl-letf (((symbol-function 'zr-rclone--job-at-point) (lambda () job))
                ((symbol-function 'zr-rclone--server-instance)
                 (lambda (_connection)
                   (setf (plist-get job :finished) t (plist-get job :state) "done")
                   "instance"))
                ((symbol-function 'zr-rclone--call)
                 (lambda (&rest _) (ert-fail "Tried to stop a completed job"))))
        (zr-rclone-cancel-job)
        (should (equal (plist-get job :state) "done"))))))

(ert-deftest zr-rclone-cancel-refuses-a-restarted-server ()
  (with-temp-buffer
    (zr-rclone-jobs-mode)
    (let ((job (list :id 1 :instance "old" :finished nil)))
      (setq zr-rclone--connection (zr-rclone--make-connection :connected t))
      (cl-letf (((symbol-function 'zr-rclone--job-at-point) (lambda () job))
                ((symbol-function 'zr-rclone--server-instance) (lambda (_) "new"))
                ((symbol-function 'zr-rclone--call)
                 (lambda (&rest _) (ert-fail "Sent stop to the wrong server instance"))))
        (should-error (zr-rclone-cancel-job))))))

(ert-deftest zr-rclone-stop-refuses-an-unowned-daemon ()
  (with-temp-buffer
    (zr-rclone-dired-mode)
    (setq zr-rclone--connection (zr-rclone--make-connection :connected t))
    (cl-letf (((symbol-function 'zr-rclone--call)
               (lambda (&rest _) (ert-fail "Attempted to stop an unowned daemon"))))
      (should-error (zr-rclone-stop-daemon)))))

(ert-deftest zr-rclone-connections-isolate-path-and-option-state ()
  (let* ((a (zr-rclone--make-connection :url "http://one.invalid/"))
         (b (zr-rclone--make-connection :url "http://two.invalid/"))
         (first (zr-rclone--buffer a))
         (second (zr-rclone--buffer b)))
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq zr-rclone-current-path "one:source"
                  zr-rclone-target-path "one:target" zr-rclone-dry-run t))
          (with-current-buffer second
            (should-not zr-rclone-current-path)
            (should-not zr-rclone-target-path)
            (should-not zr-rclone-dry-run)
            (setq zr-rclone-current-path "two:source"))
          (with-current-buffer first
            (should (equal zr-rclone-current-path "one:source"))
            (should (equal zr-rclone-target-path "one:target"))
            (should zr-rclone-dry-run)))
      (kill-buffer first)
      (kill-buffer second))))

(provide 'zr-rclone-test)
;;; zr-rclone-test.el ends here
