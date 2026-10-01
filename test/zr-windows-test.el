;;; zr-windows-test.el --- Tests for zr-windows -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-windows)

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

(provide 'zr-windows-test)
;;; zr-windows-test.el ends here
