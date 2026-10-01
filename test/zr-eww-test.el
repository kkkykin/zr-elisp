;;; zr-eww-test.el --- Tests for zr-eww -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-eww)

(ert-deftest zr-eww-test-rules-and-optional-authentication ()
  (let ((zr-eww-url-rules '(("\\`https://www.reddit.com" . "https://old.reddit.com")))
        (zr-eww-auth-patterns '("\\`https://private.example/")))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _)
                 nil)))
      (should
       (equal (zr-eww-transform-url "https://www.reddit.com/r/emacs")
              "https://old.reddit.com/r/emacs"))
      (should
       (equal (zr-eww-transform-url "https://private.example/file")
              "https://private.example/file")))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _)
                 '((:user "me" :secret "secret")))))
      (should
       (equal (zr-eww-transform-url "https://private.example/file")
              "https://me:secret@private.example/file")))))

(ert-deftest zr-eww-test-enable-disable-preserves-existing-rules ()
  (let ((eww-url-transformers '(ignore))
        (eww-after-render-hook '(ignore)))
    (unwind-protect
        (progn
          (zr-eww-mode 1)
          (zr-eww-mode 1)
          (should (= (cl-count #'zr-eww-transform-url eww-url-transformers) 1))
          (zr-eww-mode -1)
          (should (equal eww-url-transformers '(ignore)))
          (should (equal eww-after-render-hook '(ignore))))
      (zr-eww-mode -1))))

(provide 'zr-eww-test)
;;; zr-eww-test.el ends here
