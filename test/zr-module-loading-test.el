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
  '(zr-android zr-bookmark zr-comint zr-data zr-dired zr-elisp zr-eshell zr-eww
    zr-network zr-notify zr-org zr-org-babel zr-org-export zr-org-link zr-org-protocol
    zr-org-tangle zr-pcmpl zr-process-menu zr-speedbar zr-termux zr-vc
    zr-viper zr-window zr-windows))

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
                              run-with-timer))
                   (require ',module))
                 (princ "module-loaded")))
             (status (call-process invocation-name nil t nil "--batch" "-Q" "-L"
                                   zr-module-loading-test--root
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
                               zr-org-protocol-mode zr-org-tangle-id-mode
                               zr-org-babel-bat-mode))
                 (funcall mode 1)
                 (funcall mode 1)
                 (funcall mode -1)
                 (funcall mode -1))
               (unless (and (not (advice-member-p #'zr-org-tangle--link-id
                                                  'org-babel-tangle--unbracketed-link))
                            (not (assoc "dict" org-link-parameters))
                            (not (fboundp 'pcomplete/7z)))
                 (error "Extension left installed"))))
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

(provide 'zr-module-loading-test)
;;; zr-module-loading-test.el ends here
