;;; zr-org-protocol-test.el --- Tests for zr-org-protocol -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org-protocol)

(ert-deftest zr-org-protocol-test-cookie-path-rejects-traversal-before-io ()
  (cl-letf (((symbol-function 'make-directory)
             (lambda (&rest _)
               (ert-fail "Unexpected filesystem access"))))
    (should-error (zr-org-protocol-import-cookies '(:host "../escape" :cookies "text"))
                  :type 'user-error)))

(ert-deftest zr-org-protocol-test-cookie-import-and-no-server-client-kill ()
  (let* ((zr-org-protocol-cookie-directory (make-temp-file "zr-cookies-test-" t))
         (url-cookie-file
          (expand-file-name "url/cookies" zr-org-protocol-cookie-directory))
         imported
         saved)
    (unwind-protect
        (cl-letf (((symbol-function 'url-cookie-parse-file-netscape)
                   (lambda (file &optional _)
                     (setq imported file)))
                  ((symbol-function 'url-cookie-write-file)
                   (lambda ()
                     (setq saved t))))
          (zr-org-protocol-import-cookies
           '(:host "example.org" :cookies "# Netscape HTTP Cookie File\n"))
          (should saved)
          (should (file-exists-p imported))
          (should (= (logand (file-modes imported) #o777) #o600)))
      (delete-directory zr-org-protocol-cookie-directory t))))

(provide 'zr-org-protocol-test)
;;; zr-org-protocol-test.el ends here
