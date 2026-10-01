;;; zr-org-link-test.el --- Tests for zr-org-link -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org-link)

(ert-deftest zr-org-link-test-link-escapes-html ()
  (let ((html (zr-org-link--export "a&b" "<label>" 'html nil)))
    (should (string-match-p "&lt;label&gt;" html))
    (should (string-match-p "a%26b" html))
    (should-not (string-match-p ">\(<label>\)" html))))

(ert-deftest zr-org-link-test-link-handler-restoration ()
  (let ((org-link-parameters (copy-tree org-link-parameters)))
    (org-link-set-parameters "dict" :follow #'ignore)
    (zr-org-link-mode 1)
    (zr-org-link-mode 1)
    (zr-org-link-mode -1)
    (should (eq (org-link-get-parameter "dict" :follow) #'ignore))))

(provide 'zr-org-link-test)
;;; zr-org-link-test.el ends here
