;;; zr-dired-test.el --- Tests for zr-dired -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-dired)
(require 'zr-test-helpers)

(ert-deftest zr-dired-test-duplicate-no-extension-and-directory ()
  (zr-test-with-temp-directory
    (with-temp-file "README"
      (insert "hello"))
    (make-directory "dir.name")
    (with-temp-file "dir.name/item"
      (insert "nested"))
    (let ((buffer (dired-noselect default-directory)))
      (unwind-protect
          (with-current-buffer buffer
            (dired-goto-file (expand-file-name "README"))
            (zr-dired-duplicate 1)
            (should (file-exists-p "README_001"))
            (dired-goto-file (expand-file-name "README"))
            (zr-dired-duplicate 1)
            (should (file-exists-p "README_002"))
            (dired-goto-file (expand-file-name "dir.name"))
            (zr-dired-duplicate 1)
            (should (file-exists-p "dir.name_001/item")))
        (kill-buffer buffer)))))

(ert-deftest zr-dired-test-empty-list-is-useful-error ()
  (zr-test-with-temp-directory
    (let ((buffer (dired-noselect default-directory)))
      (unwind-protect (with-current-buffer buffer
                        (should-error (zr-dired-random-file) :type 'user-error))
        (kill-buffer buffer)))))

(ert-deftest zr-dired-test-pandoc-keeps-stderr-out-of-preview ()
  (let (preview)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) #'identity)
                  ((symbol-function 'dired-get-file-for-visit) (lambda () "source.md"))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (setq preview buffer))))
          (zr-test-with-process-output "* Converted\nBody\n" "[WARNING] Pandoc warning\n" 0
            (zr-dired-pandoc))
          (with-current-buffer preview
            (should (equal (buffer-string) "* Converted\nBody\n"))
            (should (derived-mode-p 'org-mode))
            (should buffer-read-only)
            (should-not (buffer-modified-p))))
      (when (buffer-live-p preview) (kill-buffer preview)))))

(ert-deftest zr-dired-test-pandoc-retains-stderr-on-failure ()
  (zr-test-with-temp-directory
    (let ((temporary-file-directory default-directory))
      (cl-letf (((symbol-function 'executable-find) #'identity)
                ((symbol-function 'dired-get-file-for-visit) (lambda () "source.md")))
        (zr-test-with-process-output "partial output\n" "Pandoc conversion failed\n" 1
          (let ((failure (should-error (zr-dired-pandoc))))
            (should (string-match-p "Pandoc conversion failed" (error-message-string failure)))))
        (should-not (directory-files temporary-file-directory nil "zr-pandoc-stderr-"))))))

(provide 'zr-dired-test)
;;; zr-dired-test.el ends here
