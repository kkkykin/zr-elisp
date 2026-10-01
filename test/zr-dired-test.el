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

(provide 'zr-dired-test)
;;; zr-dired-test.el ends here
