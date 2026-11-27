;;; zr-shadowfile-test.el --- Tests for zr-shadowfile -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'shadowfile)
(require 'zr-shadowfile)
(require 'zr-test-helpers)
(require 'zr-tramp-webdav)

(defconst zr-shadowfile-test--server-file
  (expand-file-name "webdav-server.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro zr-shadowfile-test--with-state (&rest body)
  "Run BODY with isolated shadow information, hooks and temporary files."
  (declare (indent 0) (debug t))
  `(zr-test-with-temp-directory
     (let* ((shadow-system-name "/WINPC:")
            (shadow-homedir default-directory)
            (shadow-info-file (expand-file-name "shadows"))
            (shadow-todo-file (expand-file-name "shadow_todo"))
            (shadow-hashtable (make-hash-table :test #'equal))
            (shadow-clusters nil)
            (shadow-literal-groups nil)
            (shadow-regexp-groups nil)
            (shadow-files-to-copy nil)
            (shadow-info-buffer nil)
            (shadow-todo-buffer nil)
            (shadow-inhibit-message t)
            (shadow-noquery t)
            (after-save-hook nil)
            (kill-emacs-query-functions nil)
            (zr-shadowfile-mode nil)
            (zr-shadowfile--active nil)
            (zr-shadowfile-copy-on-exit t)
            (create-lockfiles nil)
            (backup-inhibited t))
       (unwind-protect
           (progn (zr-shadowfile-mode 1) ,@body)
         (zr-shadowfile-mode -1)))))

(defmacro zr-shadowfile-test--with-webdav (&rest body)
  "Run BODY against a real local WebDAV server, binding `remote-root'."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (and (executable-find "python3") (executable-find "curl")))
     (let* ((server-buffer (generate-new-buffer " *zr-shadowfile-server*"))
            (server (make-process
                     :name "zr-shadowfile-server" :buffer server-buffer
                     :command (list "python3" "-u" zr-shadowfile-test--server-file)
                     :connection-type 'pipe :coding 'utf-8-unix :noquery t))
            (deadline (+ (float-time) 5))
            (auth-sources nil)
            (auth-source-do-cache nil)
            (zr-http-default-options '(:proxy nil :timeout 3))
            (zr-tramp-webdav-http-options nil)
            (zr-tramp-webdav--passwords (make-hash-table :test #'equal))
            (zr-tramp-webdav--connected (make-hash-table :test #'equal))
            (tramp-cache-data (make-hash-table :test #'equal))
            (tramp-verbose 0)
            port remote-root)
       (unwind-protect
           (progn
             (while (and (not port) (process-live-p server) (< (float-time) deadline))
               (accept-process-output server 0.05)
               (with-current-buffer server-buffer
                 (goto-char (point-min))
                 (when (re-search-forward "PORT \\([0-9]+\\)" nil t)
                   (setq port (match-string 1)))))
             (unless port
               (error "WebDAV server did not start: %s"
                      (with-current-buffer server-buffer (buffer-string))))
             (setq remote-root (format "/webdav:127.0.0.1#%s:/dav/shadows/" port))
             (make-directory remote-root)
             ,@body)
         (dolist (buffer (buffer-list))
           (when (and remote-root (buffer-local-value 'buffer-file-name buffer)
                      (string-prefix-p remote-root
                                       (buffer-local-value 'buffer-file-name buffer)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (when (process-live-p server) (delete-process server))
         (kill-buffer server-buffer)))))

(defun zr-shadowfile-test--bytes (file)
  "Read FILE without changing its bytes or line endings."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun zr-shadowfile-test--todo ()
  "Read the pending-copy list from the saved information file."
  (let (shadow-files-to-copy)
    (with-temp-buffer
      (setq-local lexical-binding t)
      (insert-file-contents shadow-todo-file)
      (eval-buffer))
    shadow-files-to-copy))

(ert-deftest zr-shadowfile-paths-roundtrip-with-drive-letters-and-unc ()
  (zr-shadowfile-test--with-state
    (dolist (path '("C:/Users/user/a.el" "D:/工作/中文 文件.el" "C:\\Users\\user\\a.el"
                    "//server/share/notes.txt" "/tmp/object:name.el"))
      (let* ((full (shadow-make-fullname (shadow-parse-name path)))
             (vec (shadow-parse-name full)))
        (should (equal full (concat shadow-system-name path)))
        (should (equal (tramp-file-name-host vec) "WINPC"))
        (should-not (tramp-file-name-method vec))
        (should (equal (tramp-file-name-localname vec) path))
        (should (equal (shadow-local-file full) path))
        (should (equal (shadow-expand-cluster-in-file-name full) path))))
    (should-not (shadow-parse-name nil))
    (should-not (shadow-local-file nil))))

(ert-deftest zr-shadowfile-tramp-paths-keep-method-user-port-and-hop ()
  (zr-shadowfile-test--with-state
    (dolist (file '("/sshx:alice@linux#2222:/srv/object:name.txt"
                    "/ssh:jump|ssh:alice@linux#2222:/srv/a.el"))
      (should (equal (shadow-parse-name file) (tramp-dissect-file-name file)))
      (should-not (shadow-local-file file))
      (should (equal (shadow-expand-cluster-in-file-name file) file))
      (let ((replaced (shadow-replace-name-component file "/srv/new:name.txt")))
        (should (equal (file-remote-p replaced) (file-remote-p file)))
        (should (equal (file-local-name replaced) "/srv/new:name.txt"))))))

(ert-deftest zr-shadowfile-clusters-preserve-colons-and-locality ()
  (zr-shadowfile-test--with-state
    (shadow-set-cluster "local" shadow-system-name (regexp-quote shadow-system-name))
    (shadow-set-cluster "remote" "/sshx:alice@linux#2222:"
                        (regexp-quote "/sshx:alice@linux#2222:"))
    (let ((local "/local:C:/Users/user/中文.el")
          (remote "/remote:/srv/object:name.txt"))
      (should (equal (shadow-local-file local) "C:/Users/user/中文.el"))
      (should (equal (shadow-local-file (shadow-parse-name local))
                     "C:/Users/user/中文.el"))
      (should (equal (shadow-expand-cluster-in-file-name local) "C:/Users/user/中文.el"))
      (should-not (shadow-local-file remote))
      (should-not (shadow-local-file (shadow-parse-name remote)))
      (should (equal (shadow-expand-cluster-in-file-name remote)
                     "/sshx:alice@linux#2222:/srv/object:name.txt"))
      (should (equal (shadow-contract-file-name "/WINPC:C:/Users/user/中文.el") local))
      (should (equal (shadow-contract-file-name
                      "/sshx:alice@linux#2222:/srv/object:name.txt") remote))
      (should (shadow-file-match remote "/sshx:alice@linux#2222:/srv/object:name.txt"))
      (should-not (shadow-file-match remote "C:/srv/object:name.txt")))))

(ert-deftest zr-shadowfile-contraction-does-not-query-a-foreign-home-directory ()
  (zr-shadowfile-test--with-state
    (let ((shadow-homedir "C:/Users/user/"))
      (cl-letf (((symbol-function 'tramp-handle-expand-file-name)
                 (lambda (&rest _) (ert-fail "Unexpected home directory lookup"))))
        (should (equal (shadow-contract-file-name "/sshx:alice@linux:/home/alice/a.el")
                       "/sshx:alice@linux:/home/alice/a.el"))))))

(ert-deftest zr-shadowfile-literal-groups-match-in-both-directions ()
  (zr-shadowfile-test--with-state
    (let* ((local "/WINPC:C:/Users/user/a.el")
           (remote "/sshx:alice@linux:/home/alice/a.el")
           (groups (list (list local remote))))
      (should (equal (shadow-shadows-of-1 local groups nil) (list remote)))
      (should (equal (shadow-shadows-of-1 remote groups nil) (list local))))))

(ert-deftest zr-shadowfile-regexp-groups-preserve-the-destination-site ()
  (zr-shadowfile-test--with-state
    (let* ((regexp "\\`C:/work/.*\\.el\\'")
           (groups (list (list (concat shadow-system-name regexp)
                               (concat "/sshx:alice@remote:" regexp))))
           (local "/WINPC:C:/work/中文.el")
           (remote "/sshx:alice@remote:C:/work/中文.el"))
      (should (equal (shadow-shadows-of-1 local groups t) (list remote)))
      (should (equal (shadow-shadows-of-1 remote groups t) (list local)))
      (should-not (shadow-shadows-of-1 "/WINPC:C:/work/a.txt" groups t)))))

(ert-deftest zr-shadowfile-sites-distinguish-local-files-methods-and-ports ()
  (zr-shadowfile-test--with-state
    (should-not (shadow-same-site "C:/work/a.el" "/ssh:WINPC:C:/work/a.el"))
    (should-not (shadow-same-site "/ssh:alice@host#2222:/a"
                                 "/ssh:alice@host#2223:/a"))
    (should-not (shadow-same-site "/ssh:alice@host:/a" "/sshx:alice@host:/a"))
    (should-not (shadow-same-site "/ssh:alice@host:/a" "/ssh:bob@host:/a"))
    (should (shadow-same-site "/ssh:host:/a" "/ssh:alice@host:/a"))))

(ert-deftest zr-shadowfile-cluster-membership-uses-the-full-site-identification ()
  (zr-shadowfile-test--with-state
    (shadow-set-cluster "shared" "/sshx:alice@primary:"
                        "\\`/sshx:alice@\\(?:primary\\|secondary\\):\\'")
    (should (shadow-same-site "/shared:/srv/a" "/sshx:alice@secondary:/srv/a"))
    (should (shadow-file-match "/shared:/srv/a" "/sshx:alice@secondary:/srv/a"))
    (should-not (shadow-same-site "/shared:/srv/a" "/sshx:bob@secondary:/srv/a"))
    (should-not (shadow-file-match "/shared:/srv/a" "/sshx:alice@secondary:/srv/b"))))

(ert-deftest zr-shadowfile-matching-follows-local-filesystem-case-rules ()
  (zr-shadowfile-test--with-state
    (cl-letf (((symbol-function 'file-name-case-insensitive-p) (lambda (_) t)))
      (should (shadow-file-match "/WINPC:C:/WORK/A.EL" "c:/work/a.el"))
      (should (shadow-file-match "/WINPC:C:/WORK/.*\\.EL" "c:/work/a.el" t))
      (should-not (shadow-file-match "/sshx:alice@linux:/srv/A.el"
                                    "/sshx:alice@linux:/srv/a.el")))
    (cl-letf (((symbol-function 'file-name-case-insensitive-p) (lambda (_) nil)))
      (should-not (shadow-file-match "/WINPC:C:/WORK/A.EL" "C:/work/a.el")))))

(ert-deftest zr-shadowfile-literal-definition-expands-paths-on-the-selected-site ()
  (zr-shadowfile-test--with-state
    (let ((sites '("WINPC" "/sshx:alice@linux:" nil))
          (names '("~/a.el" "~/a.el"))
          expanded)
      (with-temp-buffer
        (setq buffer-file-name "C:/Users/user/a.el")
        (cl-letf (((symbol-function 'shadow-read-site) (lambda () (pop sites)))
                  ((symbol-function 'read-string) (lambda (&rest _) (pop names)))
                  ((symbol-function 'shadow-expand-file-name)
                   (lambda (name &optional _)
                     (push name expanded)
                     (if (equal name "~/a.el")
                         "C:/Users/user/a.el"
                       "/sshx:alice@linux:/home/alice/a.el"))))
          (shadow-define-literal-group)))
      (should (equal (nreverse expanded) '("~/a.el" "/sshx:alice@linux:~/a.el")))
      (should (equal shadow-literal-groups
                     '(("/sshx:alice@linux:/home/alice/a.el" "/WINPC:C:/Users/user/a.el")))))))

(ert-deftest zr-shadowfile-mode-is-idempotent-and-restores-hooks-and-functions ()
  (let ((original (symbol-function 'shadow-parse-name))
        (key (lookup-key ctl-x-4-map "s")))
    (zr-shadowfile-test--with-state
      (setq shadow-files-to-copy '(("C:/source" . "/sshx:alice@linux:/target")))
      (zr-shadowfile-mode 1)
      (should shadow-files-to-copy)
      (should (= (cl-count #'zr-shadowfile--after-save after-save-hook) 1))
      (should (= (cl-count #'zr-shadowfile--query-exit kill-emacs-query-functions) 1))
      (should-not (memq #'shadow-add-to-todo write-file-functions))
      (should-not (advice-member-p #'shadow--save-buffers-kill-emacs 'save-buffers-kill-emacs))
      (with-temp-buffer
        ;; Terminal-wide transient maps also apply to fresh buffers.
        (let ((overriding-terminal-local-map nil))
          (should (eq (key-binding (kbd "C-x 4 s")) #'shadow-copy-files))))
      (should (equal (lookup-key ctl-x-4-map "s") key))
      (zr-shadowfile-mode -1)
      (zr-shadowfile-mode -1)
      (should-not (memq #'zr-shadowfile--after-save after-save-hook))
      (should-not (memq #'zr-shadowfile--query-exit kill-emacs-query-functions)))
    (should (eq (symbol-function 'shadow-parse-name) original))
    (should (equal (lookup-key ctl-x-4-map "s") key))))

(ert-deftest zr-shadowfile-initialization-failure-removes-the-adapters ()
  (zr-shadowfile-test--with-state
    (zr-shadowfile-mode -1)
    (cl-letf (((symbol-function 'shadow-read-files) (lambda () nil)))
      (should-error (zr-shadowfile-mode 1) :type 'user-error))
    (should-not zr-shadowfile-mode)
    (should-not zr-shadowfile--active)
    (should-not (memq #'zr-shadowfile--after-save after-save-hook))
    (dolist (entry zr-shadowfile--adapters)
      (should-not (advice-member-p (cdr entry) (car entry))))))

(ert-deftest zr-shadowfile-real-tramp-copy-roundtrip-preserves-crlf-and-pending-state ()
  (zr-shadowfile-test--with-state
    (zr-shadowfile-test--with-webdav
      (let* ((local (expand-file-name "中文 notes.txt"))
             (remote (concat remote-root "notes.txt"))
             (local-buffer (find-file-noselect local)))
        (setq shadow-literal-groups (list (list (concat shadow-system-name local) remote)))
        (with-current-buffer local-buffer
          (setq buffer-file-coding-system 'utf-8-dos)
          (insert "第一行\nsecond\n")
          (save-buffer))
        (should (equal shadow-files-to-copy (list (cons local remote))))
        (should (equal (zr-shadowfile-test--todo) shadow-files-to-copy))
        (let ((zr-shadowfile-copy-on-exit nil))
          (should (zr-shadowfile--query-exit)))
        (should shadow-files-to-copy)
        (shadow-copy-files t)
        (should-not shadow-files-to-copy)
        (should-not (zr-shadowfile-test--todo))
        (should (equal (zr-shadowfile-test--bytes local)
                       (zr-shadowfile-test--bytes remote)))
        (should (string-match-p "\r\n" (zr-shadowfile-test--bytes remote)))
        (with-current-buffer (find-file-noselect remote)
          (erase-buffer)
          (insert "远端修改\n")
          (save-buffer))
        (should (equal shadow-files-to-copy
                       (list (cons remote (concat shadow-system-name local)))))
        (should (zr-shadowfile--query-exit))
        (should-not shadow-files-to-copy)
        (should (equal (zr-shadowfile-test--bytes local)
                       (zr-shadowfile-test--bytes remote)))))))

(ert-deftest zr-shadowfile-failed-tramp-copies-stay-pending-and-retry ()
  (zr-shadowfile-test--with-state
    (zr-shadowfile-test--with-webdav
      (let* ((local (expand-file-name "source.txt"))
             (remote (concat remote-root "missing/target.txt")))
        (setq shadow-literal-groups (list (list (concat shadow-system-name local) remote)))
        (with-current-buffer (find-file-noselect local)
          (insert "retry me\n")
          (save-buffer))
        (shadow-copy-files t)
        (should (equal shadow-files-to-copy (list (cons local remote))))
        (should (equal (zr-shadowfile-test--todo) shadow-files-to-copy))
        (make-directory (concat remote-root "missing/"))
        (shadow-copy-files t)
        (should-not shadow-files-to-copy)
        (should-not (zr-shadowfile-test--todo))
        (should (equal (zr-shadowfile-test--bytes local)
                       (zr-shadowfile-test--bytes remote)))))))

(ert-deftest zr-shadowfile-failed-save-does-not-queue-a-copy ()
  (zr-shadowfile-test--with-state
    (let* ((local (expand-file-name "missing/source.txt"))
           (remote "/sshx:alice@linux:/srv/a.el"))
      (setq shadow-literal-groups (list (list (concat shadow-system-name local) remote)))
      (with-temp-buffer
        (setq buffer-file-name local)
        (insert "unsaved")
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (should-error (save-buffer)))
        (set-buffer-modified-p nil))
      (should-not shadow-files-to-copy))))

(provide 'zr-shadowfile-test)
;;; zr-shadowfile-test.el ends here
