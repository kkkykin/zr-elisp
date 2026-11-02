;;; zr-windows-test.el --- Tests for zr-windows -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-windows)

(ert-deftest zr-windows-test-shortcut-requires-native-windows-and-powershell ()
  (let ((system-type 'gnu/linux))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) (ert-fail "Looked for PowerShell off Windows"))))
      (should-error (zr-windows-register-emacs-shortcut) :type 'user-error)))
  (let ((system-type 'windows-nt))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should-error (zr-windows-register-emacs-shortcut) :type 'user-error))))

(ert-deftest zr-windows-test-shortcut-path-encoding-and-launcher-selection ()
  (let* ((directory (make-temp-file "zr-windows-shortcut-" t))
         (invocation-directory (expand-file-name "Emacs' tools/" directory))
         (invocation-name "emacs.exe")
         (shortcut (expand-file-name "猫's $literal `text/Emacs.lnk"
                                     directory))
         (launcher-present t)
         commands)
    (unwind-protect
        (progn
          (make-directory invocation-directory t)
          (write-region "" nil (expand-file-name "runemacs.exe" invocation-directory) nil 'silent)
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (name) (when (equal name "powershell") "/windows/powershell")))
                    ((symbol-function 'call-process)
                     (lambda (program _infile _destination _display &rest args)
                       (push (cons program args) commands)
                       (insert (decode-coding-string
                                (json-serialize (list :shortcut shortcut
                                                      :created (if launcher-present t :false)))
                                'utf-8))
                       0)))
            (let ((system-type 'windows-nt))
              (should (equal (zr-windows-register-emacs-shortcut shortcut) shortcut)))
            (delete-file (expand-file-name "runemacs.exe" invocation-directory))
            (setq launcher-present nil)
            (let ((system-type 'windows-nt))
              (should (equal (zr-windows-register-emacs-shortcut) shortcut))))
          (should (= (length commands) 2))
          (dolist (command commands)
            (should (equal (cl-subseq command 0 4)
                           '("/windows/powershell" "-NoProfile" "-NonInteractive" "-EncodedCommand"))))
          (let ((creation (decode-coding-string (base64-decode-string (nth 4 (cadr commands)))
                                                'utf-16le))
                (repair (decode-coding-string (base64-decode-string (nth 4 (car commands)))
                                              'utf-16le)))
            (should (string-suffix-p
                     (format "\n} '%s/猫''s $literal `text/Emacs.lnk' '%s/Emacs'' tools/runemacs.exe'"
                             directory directory)
                     creation))
            (should (string-suffix-p
                     (format "\n} $null '%s/Emacs'' tools/emacs.exe'" directory)
                     repair))))
      (delete-directory directory t))))

(ert-deftest zr-windows-test-shortcut-reports-process-errors-and-rejects-remote-paths ()
  (let ((system-type 'windows-nt))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/windows/powershell.exe")))
      (dolist (status '(1 "terminated"))
        (cl-letf (((symbol-function 'call-process)
                   (lambda (&rest _) (insert "AppID verification failed") status)))
          (let ((failure (should-error (zr-windows-register-emacs-shortcut))))
            (should (string-match-p "AppID verification failed"
                                    (error-message-string failure))))))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest _) (ert-fail "Launched PowerShell for a remote shortcut"))))
        (should-error (zr-windows-register-emacs-shortcut "/ssh:example.org:/tmp/Emacs.lnk")
                      :type 'user-error)))))

(ert-deftest zr-windows-test-shortcut-native-creation-and-repair ()
  (skip-unless (eq system-type 'windows-nt))
  (let ((program (or (executable-find "powershell.exe") (executable-find "powershell"))))
    (skip-unless program)
    (let* ((directory (make-temp-file "zr-windows-shortcut-" t))
           (shortcut (expand-file-name "猫's folder/Emacs.lnk" directory))
           (target (expand-file-name invocation-name invocation-directory)))
      (cl-labels
          ((powershell-json
             (script)
             (with-temp-buffer
               (let* ((coding-system-for-read 'utf-8-unix)
                      (status
                       (call-process
                        program nil t nil "-NoProfile" "-NonInteractive" "-EncodedCommand"
                        (base64-encode-string
                         (encode-coding-string
                          (concat "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n"
                                  "$ErrorActionPreference = 'Stop'\n" script)
                          'utf-16le) t))))
                 (ert-info ((buffer-string)) (should (eq status 0)))
                 (json-parse-string (buffer-string) :object-type 'plist)))))
        (unwind-protect
            (progn
              (should (equal (zr-windows-register-emacs-shortcut shortcut)
                             (subst-char-in-string ?\\ ?/ shortcut)))
              (should (file-exists-p shortcut))
              (let* ((open
                      (format "$path = %s\n$wscript = New-Object -ComObject WScript.Shell\n$link = $wscript.CreateShortcut($path)\n"
                              (zr-windows--powershell-string shortcut)))
                     (snapshot
                      "$shell = New-Object -ComObject Shell.Application
$folder = $shell.Namespace([IO.Path]::GetDirectoryName($path))
$item = $folder.ParseName([IO.Path]::GetFileName($path))
[pscustomobject]@{
    target = $link.TargetPath; arguments = $link.Arguments
    directory = $link.WorkingDirectory; icon = $link.IconLocation
    appId = $item.ExtendedProperty('System.AppUserModel.ID')
} | ConvertTo-Json -Compress")
                     (before
                      (powershell-json
                       (concat open
                               (format "$link.TargetPath = %s\n$link.Arguments = '--debug-init'\n$link.WorkingDirectory = %s\n$link.IconLocation = %s\n$link.Save()\n"
                                       (zr-windows--powershell-string target)
                                       (zr-windows--powershell-string directory)
                                       (zr-windows--powershell-string (concat target ",0")))
                               snapshot))))
                (zr-windows-register-emacs-shortcut shortcut)
                (let ((after (powershell-json (concat open snapshot))))
                  (should (equal (plist-get after :appId) "GNU.Emacs"))
                  (dolist (property '(:target :arguments :directory :icon))
                    (should (equal (plist-get after property) (plist-get before property)))))))
          (delete-directory directory t))))))

(ert-deftest zr-windows-test-tts-unicode-and-literal-quotes ()
  (let ((system-type 'gnu/linux)
        (zr-windows-tts-voice "Voice's name") command)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name) (when (equal name "powershell.exe") "/windows/powershell.exe")))
              ((symbol-function 'make-process)
               (lambda (&rest options) (setq command (plist-get options :command)))))
      (zr-windows-tts-speak "猫'); throw 'injected\n$literal `text"))
    (should (equal (cl-subseq command 0 4)
                   '("/windows/powershell.exe" "-NoProfile" "-NonInteractive" "-EncodedCommand")))
    (let ((script (decode-coding-string (base64-decode-string (nth 4 command)) 'utf-16le)))
      (should (string-suffix-p
               "\n} '猫''); throw ''injected\n$literal `text' 'Voice''s name'" script)))))

(ert-deftest zr-windows-test-tts-native-powershell-and-unavailable-backend ()
  (let ((zr-windows-tts-voice nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name) (when (equal name "powershell") "/windows/powershell"))))
      (let ((system-type 'windows-nt) command)
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest options)
                     (setq command (plist-get options :command))
                     'tts-process)))
          (should (eq (zr-windows-tts-speak "猫") 'tts-process)))
        (should (equal (car command) "/windows/powershell"))
        (should (string-suffix-p
                 "\n} '猫' $null"
                 (decode-coding-string (base64-decode-string (nth 4 command))
                                       'utf-16le))))
      ;; Linux PowerShell cannot supply Windows System.Speech.
      (let ((system-type 'gnu/linux))
        (should-error (zr-windows-tts-speak "猫") :type 'user-error))))
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-error (zr-windows-tts-speak "猫") :type 'user-error)))

(ert-deftest zr-windows-test-coding-keeps-remote-behavior ()
  (let ((default-directory "/ssh:example.org:/tmp/")
        calls)
    (cl-letf (((symbol-function 'zr-windows-command-coding)
               (lambda (_)
                 (ert-fail "Local decoding used on remote command"))))
      (should (eq 'result (zr-windows--shell-command
                           (lambda (&rest args)
                             (setq calls args)
                             'result)
                           1 2 "dir")))
      (should (equal calls '(1 2 "dir"))))))

(ert-deftest zr-windows-test-armored-only-normalization ()
  (should (equal (zr-windows--armor "-----BEGIN PGP MESSAGE-----\r\nbody\r\n")
                 "-----BEGIN PGP MESSAGE-----\nbody\n"))
  (should (equal (zr-windows--armor "binary\r\nbytes") "binary\r\nbytes")))

(defmacro zr-windows-test--with-ime-buffers (buffers &rest body)
  "Run BODY with temporary BUFFERS and simulated Windows IME support."
  (declare (indent 1) (debug (sexp body)))
  `(let ((system-type 'windows-nt)
         (after-focus-change-function #'ignore)
         ,@(mapcar (lambda (buffer)
                     `(,buffer (generate-new-buffer ,(format " *%s*" buffer))))
                   buffers))
     (unwind-protect
         (cl-letf (((symbol-function 'w32-set-ime-open-status) #'ignore)
                   ((symbol-function 'frame-focus-state) (lambda (&optional _) t)))
           (save-window-excursion
             (delete-other-windows)
             ,@body))
       (dolist (buffer (list ,@buffers))
         (when (buffer-live-p buffer)
           (kill-buffer buffer))))))

(ert-deftest zr-windows-test-ime-focus-uses-selected-buffer ()
  (zr-windows-test--with-ime-buffers (moyu other)
    (switch-to-buffer moyu)
    (zr-windows-ime-mode 1)
    (let ((window (selected-window)) calls)
      (cl-letf (((symbol-function 'w32-set-ime-open-status)
                 (lambda (status)
                   (push (list (current-buffer) (selected-window) status) calls))))
        ;; Focus notifications can run with an unrelated current buffer.
        (with-current-buffer other
          (funcall after-focus-change-function)
          (should (eq (current-buffer) other)))
        (should (equal calls (list (list moyu window nil))))
        (setq calls nil)
        (switch-to-buffer other)
        (with-current-buffer moyu
          (funcall after-focus-change-function))
        (should-not calls)))))

(ert-deftest zr-windows-test-ime-window-hooks-ignore-background-windows ()
  (zr-windows-test--with-ime-buffers (moyu other)
    (switch-to-buffer other)
    (let ((window (split-window-right)) calls)
      (set-window-buffer window moyu)
      (cl-letf (((symbol-function 'w32-set-ime-open-status)
                 (lambda (status) (push status calls))))
        (with-current-buffer moyu
          (zr-windows-ime-mode 1)
          (run-hook-with-args 'window-buffer-change-functions window)
          (run-hook-with-args 'window-selection-change-functions window))
        (should-not calls)
        (select-window window)
        (run-hook-with-args 'window-selection-change-functions window)
        (should (equal calls '(nil)))
        (setq calls nil)
        (set-window-buffer window other)
        (with-current-buffer moyu
          (run-hook-with-args 'window-buffer-change-functions window))
        (should-not calls)))))

(ert-deftest zr-windows-test-ime-focus-finds-another-focused-frame ()
  (zr-windows-test--with-ime-buffers (moyu other)
    (switch-to-buffer other)
    (with-current-buffer moyu
      (zr-windows-ime-mode 1))
    (let ((original-window (selected-window))
          (moyu-window (split-window-right))
          calls)
      (set-window-buffer moyu-window moyu)
      ;; Model two frames with real windows in a batch Emacs.
      (cl-letf (((symbol-function 'frame-list) (lambda () '(unfocused focused)))
                ((symbol-function 'frame-selected-window)
                 (lambda (&optional frame)
                   (if (eq frame 'focused) moyu-window original-window)))
                ((symbol-function 'frame-focus-state)
                 (lambda (&optional frame) (eq frame 'focused)))
                ((symbol-function 'w32-set-ime-open-status)
                 (lambda (status)
                   (push (list (current-buffer) (selected-window) status) calls))))
        (funcall after-focus-change-function)
        (should (equal calls (list (list moyu moyu-window nil))))
        (should (eq (selected-window) original-window))
        (should (eq (current-buffer) other))))))

(ert-deftest zr-windows-test-ime-requires-known-focus ()
  (zr-windows-test--with-ime-buffers (moyu)
    (switch-to-buffer moyu)
    (zr-windows-ime-mode 1)
    (dolist (focus '(nil unknown))
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) focus))
                ((symbol-function 'w32-set-ime-open-status)
                 (lambda (_status) (ert-fail "IME closed without known focus"))))
        (funcall after-focus-change-function)
        (run-hook-with-args 'window-selection-change-functions (selected-window))))))

(ert-deftest zr-windows-test-ime-rejects-unsupported-systems ()
  (dolist (platform '(gnu/linux windows-nt))
    (let ((system-type platform)
          (after-focus-change-function #'ignore))
      (with-temp-buffer
        (cl-letf (((symbol-function 'w32-set-ime-open-status)
                   (and (eq platform 'gnu/linux) #'ignore)))
          (should-error (zr-windows-ime-mode 1) :type 'user-error)
          (should-not zr-windows-ime-mode)
          (should (eq after-focus-change-function #'ignore))
          (should-not (memq #'zr-windows-ime-close
                            window-selection-change-functions)))))))

(ert-deftest zr-windows-test-ime-shared-hook-lifecycle ()
  (dolist (cleanup '(disable kill change-major-mode))
    (zr-windows-test--with-ime-buffers (first second)
      (setq after-focus-change-function #'ignore)
      (dolist (buffer (list first second))
        (with-current-buffer buffer
          (zr-windows-ime-mode 1)
          (zr-windows-ime-mode 1)
          (should (= (cl-count #'zr-windows-ime-close
                              window-selection-change-functions)
                     1))))
      (dolist (buffer (list first second))
        (should (advice-function-member-p #'zr-windows-ime-close
                                         after-focus-change-function))
        (with-current-buffer buffer
          (pcase cleanup
            ('disable
             (zr-windows-ime-mode -1)
             (zr-windows-ime-mode -1))
            ('kill (kill-buffer buffer))
            ('change-major-mode (fundamental-mode))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (should-not zr-windows-ime-mode)
            (should-not (memq #'zr-windows-ime-close
                              window-selection-change-functions))
            (should-not (memq #'zr-windows-ime-close
                              window-buffer-change-functions)))))
      (should (eq after-focus-change-function #'ignore)))))

(ert-deftest zr-windows-test-ime-quit-hides-buffers-without-killing ()
  (zr-windows-test--with-ime-buffers (first second other)
    (switch-to-buffer other)
    (let* ((original-window (selected-window))
           (first-window (split-window-right))
           (second-window (split-window first-window nil 'below)))
      (set-window-buffer first-window first)
      (set-window-buffer second-window second)
      (dolist (buffer (list first second))
        (with-current-buffer buffer
          (zr-windows-ime-mode 1)))
      (zr-windows-quit-ime-buffers)
      (dolist (buffer (list first second))
        (should (buffer-live-p buffer))
        (should (buffer-local-value 'zr-windows-ime-mode buffer))
        (should-not (get-buffer-window buffer t)))
      (should (window-live-p original-window))
      (should (eq (window-buffer original-window) other)))))

(provide 'zr-windows-test)
;;; zr-windows-test.el ends here
