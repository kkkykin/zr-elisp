;;; zr-org-test.el --- Tests for zr-org -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org)
(require 'zr-test-helpers)

(ert-deftest zr-org-test-speed-mode-restores-buffer-values ()
  (zr-test-with-org-buffer "* Heading\n- item\n  - nested\n- other\n"
    (let ((original org-speed-commands))
      (zr-org-mode 1)
      (zr-org-mode 1)
      (should (funcall org-use-speed-commands))
      (forward-line)
      (zr-org-cut-entry)
      (should (equal (buffer-string) "* Heading\n- other\n"))
      (zr-org-mode -1)
      (should (equal org-speed-commands original)))))

(provide 'zr-org-test)
;;; zr-org-test.el ends here
