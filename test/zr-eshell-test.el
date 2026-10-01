;;; zr-eshell-test.el --- Tests for zr-eshell -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-eshell)
(require 'zr-test-helpers)

(ert-deftest zr-eshell-test-history-inclusive-ranges-and-last-word ()
  (with-temp-buffer
    (let ((zr-eshell-mode t))
      (dolist (case '((":1" . "one") (":1-2" . "one two") (":*" . "one two three")
                      (":$" . "three") (":1-$" . "one two three") (":1-" . "one two")
                      ("^" . "one") ("$" . "three") ("*" . "one two three")))
        (should
         (equal
          (car (zr-eshell--word-designator #'ignore "echo one two three" (car case)))
          (cdr case)))))))

(ert-deftest zr-eshell-test-advice-is-buffer-local-in-effect ()
  (let ((first (generate-new-buffer " *zr eshell 1*"))
        (second (generate-new-buffer " *zr eshell 2*")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (zr-eshell-mode 1)
            (zr-eshell-mode 1))
          (with-current-buffer second
            (zr-eshell-mode 1))
          (with-current-buffer first
            (zr-eshell-mode -1))
          (should
           (advice-member-p #'zr-eshell--word-designator
                            'eshell-hist-parse-word-designator))
          (with-temp-buffer
            (should (eq 'original (zr-eshell--word-designator (lambda (&rest _)
                                                                'original)
                                                              "" ""))))
          (kill-buffer second)
          (should-not
           (advice-member-p #'zr-eshell--word-designator
                            'eshell-hist-parse-word-designator)))
      (when (buffer-live-p first)
        (kill-buffer first))
      (when (buffer-live-p second)
        (kill-buffer second)))))

(ert-deftest zr-eshell-test-env-s-quoted-arguments ()
  (zr-test-with-temp-directory
    (with-temp-file "script.py"
      (insert "#!/usr/bin/env -S python -X 'utf8 mode'\nprint(1)\n"))
    (let (seen)
      (cl-letf (((symbol-function 'eshell-parse-command)
                 (lambda (program args)
                   (setq seen (cons program args)))))
        (catch 'eshell-replace-command
          (zr-eshell-script-interpreter "script.py" "a b")))
      (should (equal seen '("python" "-X" "utf8 mode" "script.py" "a b"))))))

(ert-deftest zr-eshell-test-history-real-events-and-modifiers ()
  (with-temp-buffer
    (let ((eshell-history-ring (make-ring 10))
          (eshell-modules-list '(eshell-pred)))
      (ring-insert eshell-history-ring "echo one two three")
      (unwind-protect
          (progn
            (zr-eshell-mode 1)
            (dolist (case '(("!!:1-2" . "one two") ("!!:$" . "three")
                            ("!!:*" . "one two three") ("!!:1-$" . "one two three")
                            ("!!:1-" . "one two")
                            ("!!:s/one/ONE/" . "echo ONE two three")))
              (should (equal (eshell-history-reference (car case)) (cdr case))))
            (zr-eshell-mode -1))))))

(provide 'zr-eshell-test)
;;; zr-eshell-test.el ends here
