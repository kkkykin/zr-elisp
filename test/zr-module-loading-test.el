;;; zr-module-loading-test.el --- Cross-module loading tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-windows)
(require 'zr-android)

(defconst zr-module-loading-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defconst zr-module-loading-test--modules
  '(nnepub nnopds nnopds-progress nnopds-koreader zr-nndoc-epub zr-dictionary zr-org-srs zr-org-srs-capture zr-org-srs-review zr-android zr-bookmark zr-comint zr-data zr-dired zr-elisp zr-eshell zr-eww
    zr-network zr-notify zr-org zr-org-babel zr-org-export zr-org-link zr-org-protocol
    zr-org-tangle zr-pcmpl zr-process-menu zr-speedbar zr-terminal zr-termux zr-vc
    zr-viper zr-wezterm zr-window zr-windows))

(ert-deftest zr-module-loading-test-load-modules-without-external-effects ()
  ;; Fresh Emacs for every library catches dependencies hidden by another load.
  (dolist (module zr-module-loading-test--modules)
    (with-temp-buffer
      (let* ((form
              `(progn
                 (require 'cl-lib)
                 (cl-letf ,(mapcar
                            (lambda (function)
                              `((symbol-function ',function)
                                (lambda (&rest _)
                                  (error "Unexpected side effect: %s" ',function))))
                            '(call-process process-file make-process start-process
                              make-network-process write-region
                              make-directory setenv run-at-time
                              run-with-timer send-string-to-terminal))
                   (require ',module))
                 (princ "module-loaded")))
             (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                   zr-module-loading-test--root
                                   "-L" (expand-file-name "org" zr-module-loading-test--root)
                                   "-L" (expand-file-name "gnus" zr-module-loading-test--root)
                                   "--eval" (prin1-to-string form))))
        (ert-info ((format "%s: %s" module (buffer-string)))
          (should (eq status 0))
          (should (string-match-p "module-loaded" (buffer-string))))))))

(ert-deftest zr-module-loading-test-reverse-load-order-and-global-mode-lifecycle ()
  (with-temp-buffer
    (let* ((form
            `(progn
               (dolist (module ',(reverse zr-module-loading-test--modules))
                 (require module))
               (dolist (mode '(zr-pcmpl-mode zr-org-link-mode zr-org-export-mode
                               zr-org-protocol-mode zr-org-srs-capture-protocol-mode zr-org-tangle-id-mode
                               zr-org-babel-bat-mode))
                 (funcall mode 1)
                 (funcall mode 1)
                 (funcall mode -1)
                 (funcall mode -1))
               (with-temp-buffer
                 (org-mode)
                 (zr-org-srs-review-mode 1)
                 (zr-org-srs-review-mode 1)
                 (zr-org-srs-review-mode -1)
                 (zr-org-srs-review-mode -1)
                 (when (or buffer-read-only zr-org-srs-review-mode
                           (local-variable-p 'org-srs-item-confirm))
                   (error "Review mode left buffer settings installed")))
               (unless (and (not (advice-member-p #'zr-org-tangle--link-id
                                                  'org-babel-tangle--unbracketed-link))
                            (not (assoc "dict" org-link-parameters))
                            (not (fboundp 'pcomplete/7z))
                            (not (cl-find "srs-card" org-protocol-protocol-alist
                                          :key (lambda (entry) (plist-get (cdr entry) :protocol))
                                          :test #'equal)))
                 (error "Extension left installed"))))
           (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                 zr-module-loading-test--root
                                 "-L" (expand-file-name "org" zr-module-loading-test--root)
                                 "-L" (expand-file-name "gnus" zr-module-loading-test--root)
                                 "--eval" (prin1-to-string form))))
      (ert-info ((buffer-string))
        (should (eq status 0))))))

(ert-deftest zr-module-loading-test-org-links-load-dictionary-on-use ()
  (with-temp-buffer
    (let* ((form
            '(progn
               (require 'cl-lib)
               (require 'zr-org-link)
               (zr-org-link-mode 1)
               (with-temp-buffer
                 (insert "[[https://example.com/][Example]]")
                 (org-mode)
                 (goto-char (point-min))
                 (let (sent)
                   (cl-letf (((symbol-function 'getenv)
                              (lambda (&rest _) "ssh-session"))
                             ((symbol-function 'zr-wezterm-send-json)
                              (lambda (payload) (setq sent payload))))
                     (unless (and (zr-org-link-open-at-point)
                                  (equal (alist-get 'uri sent) "https://example.com/"))
                       (error "HTTP link did not open through WezTerm")))))
               (when (or (featurep 'dictionary) (featurep 'zr-dictionary))
                 (error "Org links loaded dictionary support early"))
               (unless (and (string-prefix-p "[[dict:word?" (zr-org-link-dict-link "word"))
                            (featurep 'dictionary)
                            (featurep 'zr-dictionary))
                 (error "Dictionary link did not load its support"))))
           (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                 zr-module-loading-test--root
                                 "-L" (expand-file-name "org" zr-module-loading-test--root)
                                 "--eval" (prin1-to-string form))))
      (ert-info ((buffer-string))
        (should (eq status 0))))))

(ert-deftest zr-module-loading-test-dictionary-autoload-does-not-load-module ()
  ;; The test runner has loaded cl-lib, which hides this startup failure.
  (with-temp-buffer
    (let* ((form
            '(progn
               (require 'loaddefs-gen)
               ;; Compressed sources must not bootstrap jka-compr here.
               (let* ((load-suffixes '(".el"))
                      (definitions
                       (loaddefs-generate--parse-file
                        (locate-library "zr-dictionary")
                        (expand-file-name "zr-loaddefs.el"))))
                 (dolist (definition definitions)
                   (let ((form (nth 2 definition)))
                     (eval (if (stringp form) (car (read-from-string form)) form) t))))
               (when (or (featurep 'cl-lib) (featurep 'dictionary)
                         (featurep 'zr-dictionary))
                 (error "Dictionary autoload generation loaded its dependencies"))
               (unless (and (autoloadp (symbol-function 'zr-dictionary-search))
                            (commandp 'zr-dictionary-search))
                 (error "Dictionary command autoload is missing"))
               (let ((buffer (zr-dictionary-search "word" nil)))
                 (unless (and (buffer-live-p buffer) (featurep 'zr-dictionary))
                   (error "Dictionary command did not load on use"))
                 (kill-buffer buffer))))
           (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                 zr-module-loading-test--root
                                 "--eval" (prin1-to-string form))))
      (ert-info ((buffer-string))
        (should (eq status 0))))))

(ert-deftest zr-module-loading-test-platform-commands-reject-wrong-system ()
  (let ((system-type 'gnu/linux))
    (should-error (zr-windows-shell) :type 'user-error)
    (should-error (zr-windows-encoding-mode 1) :type 'user-error)
    (should-not zr-windows-encoding-mode)
    (should-error (zr-android-toolbar-mode 1) :type 'user-error)
    (should-not zr-android-toolbar-mode)))

(ert-deftest zr-module-loading-test-srs-panel-autoloads-do-not-load-dependencies ()
  (with-temp-buffer
    (let* ((form
            '(progn
               (require 'loaddefs-gen)
               (require 'easy-mmode)
               (let* ((load-suffixes '(".el"))
                      (definitions
                       (loaddefs-generate--parse-file
                        (locate-library "zr-org-srs-review")
                        (expand-file-name "zr-loaddefs.el"))))
                 (dolist (definition definitions)
                   (let ((form (nth 2 definition)))
                     (eval (if (stringp form) (car (read-from-string form)) form) t))))
               (when (or (featurep 'transient) (featurep 'org-srs)
                         (featurep 'zr-org-srs-review))
                 (error "Review panel autoloads loaded dependencies"))
               (dolist (command '(zr-org-srs-review-start zr-org-srs-review-tts
                                   zr-org-srs-review-menu zr-org-srs-review-popup-menu zr-org-srs-review-mode
                                   zr-org-srs-review-auto-tts-mode))
                 (unless (and (autoloadp (symbol-function command)) (commandp command))
                   (error "Missing review panel autoload: %s" command)))))
           (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                 (expand-file-name "org" zr-module-loading-test--root)
                                 "--eval" (prin1-to-string form))))
      (ert-info ((buffer-string))
        (should (eq status 0))))))

(ert-deftest zr-module-loading-test-srs-capture-and-review-are-independent ()
  (dolist (module '(zr-org-srs-capture zr-org-srs-review))
    (with-temp-buffer
      (let* ((form
              `(progn
                 (require ',module)
                 (dolist (dependency ',(if (eq module 'zr-org-srs-capture)
                                          '(org-srs zr-org-srs-review transient)
                                        '(org-srs zr-org-srs-capture zr-dictionary dictionary)))
                   (when (featurep dependency)
                     (error "%s loaded %s" ',module dependency)))))
             (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                   zr-module-loading-test--root
                                   "-L" (expand-file-name "org" zr-module-loading-test--root)
                                   "--eval" (prin1-to-string form))))
        (ert-info ((buffer-string))
          (should (eq status 0)))))))

(provide 'zr-module-loading-test)
;;; zr-module-loading-test.el ends here
