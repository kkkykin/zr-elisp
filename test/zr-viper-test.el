;;; zr-viper-test.el --- Tests for zr-viper -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-viper)

(ert-deftest zr-viper-test-line-numbers-restored-on-error ()
  ;; Stub require as this test must not activate Viper globally.
  (cl-letf (((symbol-function 'require)
             (lambda (&rest _)
               t))
            ((symbol-function 'viper-ex)
             (lambda (&rest _)
               (error "Cancelled"))))
    (with-temp-buffer
      (let ((ex-token-alist nil))
        (should-error (zr-viper-ex))
        (should-not display-line-numbers-mode)))))

(provide 'zr-viper-test)
;;; zr-viper-test.el ends here
