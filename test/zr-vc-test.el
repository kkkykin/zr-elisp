;;; zr-vc-test.el --- Tests for zr-vc -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-vc)

(ert-deftest zr-vc-test-template-without-scope ()
  (with-temp-buffer
    (zr-vc-insert-commit-template "fix" "")
    (should (equal (buffer-string) "fix: "))))

(provide 'zr-vc-test)
;;; zr-vc-test.el ends here
