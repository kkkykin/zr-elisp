;;; zr-elisp-test.el --- Tests for zr-elisp -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-elisp)

(ert-deftest zr-elisp-test-source-link-windows-compressed-path ()
  (with-temp-buffer
    (setq buffer-file-name "C:\\Emacs\\lisp\\foo bar.el.gz")
    (should
     (equal (zr-elisp-source-url)
            "https://github.com/emacs-mirror/emacs/raw/refs/heads/master/lisp/foo%20bar.el"))))

(provide 'zr-elisp-test)
;;; zr-elisp-test.el ends here
