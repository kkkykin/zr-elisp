;;; zr-user-integration-test.el --- Module loading and platform boundaries -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'zr-notify)
(require 'zr-termux)
(require 'zr-windows)
(require 'zr-android)
(require 'zr-eww)

(defconst zr-integration-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))
(defconst zr-integration-test--modules
  '(zr-android zr-bookmark zr-comint zr-data zr-dired zr-elisp zr-eshell zr-eww
    zr-notify zr-org zr-org-babel zr-org-export zr-org-link zr-org-protocol
    zr-org-tangle zr-pcmpl zr-process-menu zr-speedbar zr-termux zr-vc zr-viper
    zr-window zr-windows))

(ert-deftest zr-integration-load-modules-without-external-effects ()
  ;; Fresh Emacs for every library catches dependencies hidden by another load.
  (dolist (module zr-integration-test--modules)
    (with-temp-buffer
      (let* ((form
              `(progn
                 (require 'cl-lib)
                 (cl-letf ,(mapcar
                            (lambda (function)
                              `((symbol-function ',function)
                                (lambda (&rest _) (error "Unexpected side effect: %s" ',function))))
                            '(call-process process-file make-process start-process
                              make-network-process write-region make-directory setenv run-at-time run-with-timer))
                   (require ',module))
                 (princ "module-loaded")))
             (status (call-process invocation-name nil t nil "--batch" "-Q" "-L" zr-integration-test--root
                                   "--eval" (prin1-to-string form))))
        (ert-info ((format "%s: %s" module (buffer-string)))
          (should (eq status 0))
          (should (string-match-p "module-loaded" (buffer-string))))))))

(ert-deftest zr-integration-termux-notification-arguments ()
  (let ((args (zr-termux--notification-arguments
               "Title" "Body" '(:replaces-id 42 :urgency critical :led-on 100 :suppress-sound t
                                 :actions ("Open" "am start foo") :ongoing t))))
    (should (equal (cadr (member "--id" args)) "42"))
    (should (equal (cadr (member "--priority" args)) "high"))
    (should (equal (cadr (member "--button1-action" args)) "am start foo"))
    (should-not (member "--sound" args))
    (should (cl-every #'stringp args))))

(ert-deftest zr-integration-reverse-load-order-and-global-mode-lifecycle ()
  (with-temp-buffer
    (let* ((form
            `(progn
               (dolist (module ',(reverse zr-integration-test--modules)) (require module))
               (dolist (mode '(zr-pcmpl-mode zr-org-link-mode zr-org-export-mode
                              zr-org-protocol-mode zr-org-tangle-id-mode zr-org-babel-bat-mode))
                 (funcall mode 1) (funcall mode 1) (funcall mode -1) (funcall mode -1))
               (unless (and (not (advice-member-p #'zr-org-tangle--link-id
                                                  'org-babel-tangle--unbracketed-link))
                            (not (assoc "dict" org-link-parameters))
                            (not (fboundp 'pcomplete/7z)))
                 (error "Extension left installed"))))
           (status (call-process invocation-name nil t nil "--batch" "-Q" "-L" zr-integration-test--root
                                 "--eval" (prin1-to-string form))))
      (ert-info ((buffer-string)) (should (eq status 0))))))

(ert-deftest zr-integration-termux-timeout-replacement-and-distinct-ids ()
  (let ((zr-termux--notification-timers (make-hash-table :test #'equal)) calls timers cancelled)
    (cl-letf (((symbol-function 'zr-termux--call) (lambda (&rest args) (push args calls)))
              ((symbol-function 'run-at-time) (lambda (delay repeat callback &rest _)
                                               (let ((timer (list delay repeat callback))) (push timer timers) timer)))
              ((symbol-function 'cancel-timer) (lambda (timer) (push timer cancelled))))
      (zr-termux-notify "a" "b" :replaces-id 42 :timeout 5000)
      (zr-termux-notify "c" "d" :replaces-id "42" :timeout 1000)
      (should (= (length cancelled) 1))
      (should (= (caar timers) 1.0))
      (funcall (nth 2 (car timers)))
      (should (equal (car calls) '("termux-notification-remove" "42")))
      (should-not (equal (zr-termux-notify "a" "b") (zr-termux-notify "a" "b"))))))

(ert-deftest zr-integration-notify-dispatch-and-appointment ()
  (let (seen)
    (let ((system-type 'android))
      (cl-letf (((symbol-function 'android-notifications-notify) (lambda (&rest args) (setq seen args) 7)))
        (should (= (zr-notify-send "title" "body" :timeout 500) 7))
        (should (equal seen '(:title "title" :body "body" :timeout 500)))))
    (let ((zr-notify-function (lambda (&rest args) (setq seen args))))
      (zr-notify-appointment '("1" "3") nil '("first" "second"))
      (should (equal (seq-take seen 2) '("In 1, 3 minutes" "first\nsecond"))))))

(ert-deftest zr-integration-windows-notification-native-api ()
  (let ((system-type 'windows-nt) called closed delay callback
        (zr-notify--windows-timers (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'w32-notification-notify) (lambda (&rest _) (setq called t) 10))
              ((symbol-function 'w32-notification-close) (lambda (id) (setq closed id)))
              ((symbol-function 'run-at-time) (lambda (seconds _repeat function &rest _)
                                               (setq delay seconds callback function) 'timer)))
      (zr-notify-send "a" "b" :timeout 3000)
      (should called)
      (should (= delay 3.0))
      (funcall callback)
      (should (= closed 10)))))

(ert-deftest zr-integration-platform-commands-reject-wrong-system ()
  (let ((system-type 'gnu/linux))
    (should-error (zr-windows-shell) :type 'user-error)
    (should-error (zr-windows-encoding-mode 1) :type 'user-error)
    (should-not zr-windows-encoding-mode)
    (should-error (zr-android-toolbar-mode 1) :type 'user-error)
    (should-not zr-android-toolbar-mode)))

(ert-deftest zr-integration-android-toolbar-restores-maps ()
  (let* ((secondary-tool-bar-map (make-sparse-keymap)) (input-decode-map (make-sparse-keymap))
         (original-toolbar secondary-tool-bar-map) (original-input input-decode-map)
         (modifier-bar-mode t) (modifier-bar-mode-hook nil))
    (unwind-protect
        (cl-letf (((symbol-function 'zr-android--gui) #'ignore))
          (zr-android-toolbar-mode 1) (zr-android-toolbar-mode 1)
          (should (lookup-key secondary-tool-bar-map [zr-keyboard]))
          (should (= (cl-count #'zr-android--toolbar modifier-bar-mode-hook) 1))
          (zr-android-toolbar-mode -1)
          (should (eq secondary-tool-bar-map original-toolbar))
          (should (eq input-decode-map original-input)))
      (zr-android-toolbar-mode -1))))

(ert-deftest zr-integration-windows-coding-keeps-remote-behavior ()
  (let ((default-directory "/ssh:example.org:/tmp/") calls)
    (cl-letf (((symbol-function 'zr-windows-command-coding) (lambda (_) (ert-fail "Local decoding used on remote command"))))
      (should (eq 'result (zr-windows--shell-command
                          (lambda (&rest args) (setq calls args) 'result) 1 2 "dir")))
      (should (equal calls '(1 2 "dir"))))))

(ert-deftest zr-integration-windows-armored-only-normalization ()
  (should (equal (zr-windows--armor "-----BEGIN PGP MESSAGE-----\r\nbody\r\n")
                 "-----BEGIN PGP MESSAGE-----\nbody\n"))
  (should (equal (zr-windows--armor "binary\r\nbytes") "binary\r\nbytes")))

(ert-deftest zr-integration-eww-rules-and-optional-authentication ()
  (let ((zr-eww-url-rules '(("\\`https://www.reddit.com" . "https://old.reddit.com")))
        (zr-eww-auth-patterns '("\\`https://private.example/")))
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
      (should (equal (zr-eww-transform-url "https://www.reddit.com/r/emacs") "https://old.reddit.com/r/emacs"))
      (should (equal (zr-eww-transform-url "https://private.example/file") "https://private.example/file")))
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) '((:user "me" :secret "secret")))))
      (should (equal (zr-eww-transform-url "https://private.example/file") "https://me:secret@private.example/file")))))

(ert-deftest zr-integration-eww-enable-disable-preserves-existing-rules ()
  (let ((eww-url-transformers '(ignore)) (eww-after-render-hook '(ignore)))
    (unwind-protect
        (progn
          (zr-eww-mode 1) (zr-eww-mode 1)
          (should (= (cl-count #'zr-eww-transform-url eww-url-transformers) 1))
          (zr-eww-mode -1)
          (should (equal eww-url-transformers '(ignore)))
          (should (equal eww-after-render-hook '(ignore))))
      (zr-eww-mode -1))))
;;; zr-user-integration-test.el ends here
