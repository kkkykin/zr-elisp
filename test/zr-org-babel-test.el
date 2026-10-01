;;; zr-org-babel-test.el --- Tests for zr-org-babel -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org-babel)
(require 'zr-test-helpers)

(ert-deftest zr-org-babel-test-named-block-and-call-discovery ()
  (zr-test-with-org-buffer
      "#+name: source\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n#+name: caller\n#+call: source()\n"
    (should (equal (mapcar #'car (zr-org-babel-blocks)) '("source" "caller")))))

(ert-deftest zr-org-babel-test-babel-respects-confirmation ()
  (zr-test-with-org-buffer "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"
    (let ((org-confirm-babel-evaluate t)
          asked)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _)
                   (setq asked t)
                   nil)))
        (should-not (zr-org-babel-execute)))
      (should asked)
      (should-not (string-match-p "RESULTS" (buffer-string))))))

(ert-deftest zr-org-babel-test-babel-executes-block-and-call ()
  (zr-test-with-org-buffer
      "#+name: source\n#+begin_src emacs-lisp :var x=3 :results silent\n(+ x 2)\n#+end_src\n#+name: caller\n#+call: source(x=5)\n"
    (let ((org-confirm-babel-evaluate nil))
      (should (= (zr-org-babel-execute-named "source") 5))
      (should (= (zr-org-babel-execute-named "caller") 7))
      (should-error (zr-org-babel-execute-named "missing") :type 'user-error))))

(ert-deftest zr-org-babel-test-json-format-is-contained-in-block ()
  (zr-test-with-org-buffer
      "* Heading\n#+begin_src json\n{\"a\":1,\"b\":2}\n#+end_src\nAfter\n"
    (forward-line 2)
    (zr-org-babel-format-json)
    (should (string-prefix-p "* Heading\n#+begin_src json\n" (buffer-string)))
    (should (string-suffix-p "#+end_src\nAfter\n" (buffer-string)))
    (should (string-match-p "\n.*\"b\"" (buffer-string)))))

(ert-deftest zr-org-babel-test-invalid-json-does-not-edit ()
  (zr-test-with-org-buffer "#+begin_src json\n{\"broken\":}\n#+end_src\n"
    (let ((original (buffer-string)))
      (should-error (zr-org-babel-format-json))
      (should (equal original (buffer-string))))))

(ert-deftest zr-org-babel-test-completion-bounds-are-org-buffer-positions ()
  (zr-test-with-org-buffer "* Heading\n#+begin_src emacs-lisp\n(messa)\n#+end_src\n"
    (search-forward "messa")
    (let ((position (point)))
      (unwind-protect
          (let ((result (zr-org-babel-completion-at-point)))
            (should result)
            (should (= (nth 1 result) position))
            (should (equal (buffer-substring (car result) (cadr result)) "messa"))
            (should (member "message" (all-completions "messa" (nth 2 result)))))
        (zr-org-babel--clear-completion)))))

(ert-deftest zr-org-babel-test-bat-handler-restores-original ()
  (let ((old (and (fboundp 'org-babel-variable-assignments:bat)
                  (symbol-function 'org-babel-variable-assignments:bat))))
    (unwind-protect
        (progn
          (zr-org-babel-bat-mode 1)
          (zr-org-babel-bat-mode 1)
          (should
           (equal (org-babel-variable-assignments:bat '((:var . (name . "a b")) ))
                  '("set \"name=a b\"")))
          (zr-org-babel-bat-mode -1)
          (should (equal old (and (fboundp 'org-babel-variable-assignments:bat)
                                  (symbol-function 'org-babel-variable-assignments:bat)))))
      (zr-org-babel-bat-mode -1))))

(provide 'zr-org-babel-test)
;;; zr-org-babel-test.el ends here
