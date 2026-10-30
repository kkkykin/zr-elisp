;;; zr-org-tangle-test.el --- Tests for zr-org-tangle -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org-tangle)
(require 'zr-test-helpers)

(ert-deftest zr-org-tangle-test-tangle-directory-and-inheritance ()
  (zr-test-with-org-buffer
      "* Heading\n:PROPERTIES:\n:TANGLE-DIR: output\n:END:\n#+name: demo.el\n#+begin_src emacs-lisp\n(message \"hi\")\n#+end_src\n"
    (search-forward "(message")
    (should (equal (zr-org-tangle-path) (expand-file-name "output/demo.el")))))

(ert-deftest zr-org-tangle-test-three-way-merge-retains-independent-edits ()
  (skip-unless (executable-find "diff3"))
  (let ((result
         (zr-org-tangle--merge "one\ntwo\nlast\n" "first\ntwo\nlast\n"
                               "first\ntwo\nthree\n")))
    (should (equal (car result) "one\ntwo\nthree\n"))
    (should-not (cdr result))))

(ert-deftest zr-org-tangle-test-three-way-conflict-preserved-for-review ()
  (skip-unless (executable-find "diff3"))
  (let ((result (zr-org-tangle--merge "ours\n" "base\n" "theirs\n")))
    (should (cdr result))
    (should (string-match-p "<<<<<<< source" (car result)))
    (should (string-match-p "theirs" (car result)))))

(ert-deftest zr-org-tangle-test-detangle-error-does-not-touch-source ()
  (zr-test-with-org-buffer "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"
    (let ((original (buffer-string))
          (org-confirm-babel-evaluate nil))
      (cl-letf (((symbol-function 'zr-org-tangle--merge)
                 (lambda (&rest _)
                   (error "diff3 failed"))))
        (should-error (zr-org-tangle--update-body "(+ 2 3)\n")))
      (should (equal original (buffer-string))))))

(ert-deftest zr-org-tangle-test-detangle-updates-body-only-and-keeps-unsaved ()
  (skip-unless (executable-find "diff3"))
  (zr-test-with-org-buffer
      "* Heading\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\nAfter\n"
    (search-forward "(+")
    (set-buffer-modified-p nil)
    (let ((zr-org-tangle-confirm nil)
          (org-confirm-babel-evaluate nil))
      (zr-org-tangle--update-body "(+ 2 3)\n"))
    (should
     (equal (buffer-string)
            "* Heading\n#+begin_src emacs-lisp\n(+ 2 3)\n#+end_src\nAfter\n"))
    (should (buffer-modified-p))))

(ert-deftest zr-org-tangle-test-named-block-tangle-detangle-roundtrip ()
  (skip-unless (executable-find "diff3"))
  (let* ((directory (make-temp-file "zr-org-roundtrip-" t))
         (source (expand-file-name "source.org" directory))
         (output (expand-file-name "out.el" directory))
         (text
          "* Heading\n#+name: example\n#+header: :comments link\n#+begin_src emacs-lisp :tangle out.el\n(+ 1 2)\n#+end_src\nAfter\n")
         (org-confirm-babel-evaluate nil)
         (zr-org-tangle-confirm nil)
         buffers)
    (unwind-protect
        (progn
          (write-region text nil source nil 'silent)
          (let ((buffer (find-file-noselect source)))
            (push buffer buffers)
            (with-current-buffer buffer
              (org-babel-tangle)
              (should (file-exists-p output))
              (with-temp-buffer
                (insert-file-contents output)
                (goto-char (point-min))
                (search-forward "(+ 1 2)")
                (replace-match "(+ 3 4)" t t)
                (write-region (point-min) (point-max) output nil 'silent))
              (zr-org-tangle-detangle output)
              (push (get-file-buffer output) buffers)
              (should (equal (buffer-string) (string-replace "(+ 1 2)" "(+ 3 4)" text)))
              (should (buffer-modified-p))))
          (with-temp-buffer
            (insert-file-contents source)
            (should (equal (buffer-string) text))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest zr-org-tangle-test-merge-error-cleans-temporary-files ()
  (let (files)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_)
                 "/diff3"))
              ((symbol-function 'call-process)
               (lambda (&rest args)
                 (setq files (last args 3))
                 2)))
      (should-error (zr-org-tangle--merge "a" "b" "c")))
    (should (= (length files) 3))
    (should-not (cl-some #'file-exists-p files))))

(provide 'zr-org-tangle-test)
;;; zr-org-tangle-test.el ends here
