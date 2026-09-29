;;; zr-user-org-test.el --- Org refactoring regression tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'zr-org)
(require 'zr-org-babel)
(require 'zr-org-tangle)
(require 'zr-org-link)
(require 'zr-org-export)
(require 'zr-org-protocol)
(require 'zr-viper)
(defmacro zr-org-test--buffer (text &rest body)
  (declare (indent 1) (debug t))
  `(with-temp-buffer (insert ,text) (org-mode) (goto-char (point-min)) ,@body))

(ert-deftest zr-org-test-speed-mode-restores-buffer-values ()
  (zr-org-test--buffer "* Heading\n- item\n  - nested\n- other\n"
    (let ((original org-speed-commands))
      (zr-org-mode 1) (zr-org-mode 1)
      (should (funcall org-use-speed-commands))
      (forward-line)
      (zr-org-cut-entry)
      (should (equal (buffer-string) "* Heading\n- other\n"))
      (zr-org-mode -1)
      (should (equal org-speed-commands original)))))

(ert-deftest zr-org-test-named-block-and-call-discovery ()
  (zr-org-test--buffer "#+name: source\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n#+name: caller\n#+call: source()\n"
    (should (equal (mapcar #'car (zr-org-babel-blocks)) '("source" "caller")))))

(ert-deftest zr-org-test-babel-respects-confirmation ()
  (zr-org-test--buffer "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"
    (let ((org-confirm-babel-evaluate t) asked)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t) nil)))
        (should-not (zr-org-babel-execute)))
      (should asked)
      (should-not (string-match-p "RESULTS" (buffer-string))))))

(ert-deftest zr-org-test-babel-executes-block-and-call ()
  (zr-org-test--buffer "#+name: source\n#+begin_src emacs-lisp :var x=3 :results silent\n(+ x 2)\n#+end_src\n#+name: caller\n#+call: source(x=5)\n"
    (let ((org-confirm-babel-evaluate nil))
      (should (= (zr-org-babel-execute-named "source") 5))
      (should (= (zr-org-babel-execute-named "caller") 7))
      (should-error (zr-org-babel-execute-named "missing") :type 'user-error))))

(ert-deftest zr-org-test-json-format-is-contained-in-block ()
  (zr-org-test--buffer "* Heading\n#+begin_src json\n{\"a\":1,\"b\":2}\n#+end_src\nAfter\n"
    (forward-line 2)
    (zr-org-babel-format-json)
    (should (string-prefix-p "* Heading\n#+begin_src json\n" (buffer-string)))
    (should (string-suffix-p "#+end_src\nAfter\n" (buffer-string)))
    (should (string-match-p "\n.*\"b\"" (buffer-string)))))

(ert-deftest zr-org-test-invalid-json-does-not-edit ()
  (zr-org-test--buffer "#+begin_src json\n{\"broken\":}\n#+end_src\n"
    (let ((original (buffer-string)))
      (should-error (zr-org-babel-format-json))
      (should (equal original (buffer-string))))))

(ert-deftest zr-org-test-completion-bounds-are-org-buffer-positions ()
  (zr-org-test--buffer "* Heading\n#+begin_src emacs-lisp\n(messa)\n#+end_src\n"
    (search-forward "messa")
    (let ((position (point)))
      (unwind-protect
          (let ((result (zr-org-babel-completion-at-point)))
            (should result)
            (should (= (nth 1 result) position))
            (should (equal (buffer-substring (car result) (cadr result)) "messa"))
            (should (member "message" (all-completions "messa" (nth 2 result)))))
        (zr-org-babel--clear-completion)))))

(ert-deftest zr-org-test-bat-handler-restores-original ()
  (let ((old (and (fboundp 'org-babel-variable-assignments:bat)
                  (symbol-function 'org-babel-variable-assignments:bat))))
    (unwind-protect
        (progn
          (zr-org-babel-bat-mode 1) (zr-org-babel-bat-mode 1)
          (should (equal (org-babel-variable-assignments:bat '((:var . (name . "a b")) )) '("set \"name=a b\"")))
          (zr-org-babel-bat-mode -1)
          (should (equal old (and (fboundp 'org-babel-variable-assignments:bat)
                                 (symbol-function 'org-babel-variable-assignments:bat)))))
      (zr-org-babel-bat-mode -1))))

(ert-deftest zr-org-test-tangle-directory-and-inheritance ()
  (zr-org-test--buffer "* Heading\n:PROPERTIES:\n:TANGLE-DIR: output\n:END:\n#+name: demo.el\n#+begin_src emacs-lisp\n(message \"hi\")\n#+end_src\n"
    (search-forward "(message")
    (should (equal (zr-org-tangle-path) (expand-file-name "output/demo.el")))))

(ert-deftest zr-org-test-three-way-merge-retains-independent-edits ()
  (skip-unless (executable-find "diff3"))
  (let ((result (zr-org-tangle--merge "one\ntwo\nlast\n" "first\ntwo\nlast\n" "first\ntwo\nthree\n")))
    (should (equal (car result) "one\ntwo\nthree\n"))
    (should-not (cdr result))))

(ert-deftest zr-org-test-three-way-conflict-preserved-for-review ()
  (skip-unless (executable-find "diff3"))
  (let ((result (zr-org-tangle--merge "ours\n" "base\n" "theirs\n")))
    (should (cdr result))
    (should (string-match-p "<<<<<<< source" (car result)))
    (should (string-match-p "theirs" (car result)))))

(ert-deftest zr-org-test-detangle-error-does-not-touch-source ()
  (zr-org-test--buffer "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"
    (let ((original (buffer-string)) (org-confirm-babel-evaluate nil))
      (cl-letf (((symbol-function 'zr-org-tangle--merge) (lambda (&rest _) (error "diff3 failed"))))
        (should-error (zr-org-tangle--update-body "(+ 2 3)\n")))
      (should (equal original (buffer-string))))))

(ert-deftest zr-org-test-detangle-updates-body-only-and-keeps-unsaved ()
  (skip-unless (executable-find "diff3"))
  (zr-org-test--buffer "* Heading\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\nAfter\n"
    (search-forward "(+")
    (set-buffer-modified-p nil)
    (let ((zr-org-tangle-confirm nil) (org-confirm-babel-evaluate nil))
      (zr-org-tangle--update-body "(+ 2 3)\n"))
    (should (equal (buffer-string) "* Heading\n#+begin_src emacs-lisp\n(+ 2 3)\n#+end_src\nAfter\n"))
    (should (buffer-modified-p))))

(ert-deftest zr-org-test-named-block-tangle-detangle-roundtrip ()
  (skip-unless (executable-find "diff3"))
  (let* ((directory (make-temp-file "zr-org-roundtrip-" t))
         (source (expand-file-name "source.org" directory))
         (output (expand-file-name "out.el" directory))
         (text "* Heading\n#+name: example\n#+header: :comments link\n#+begin_src emacs-lisp :tangle out.el\n(+ 1 2)\n#+end_src\nAfter\n")
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
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest zr-org-test-merge-error-cleans-temporary-files ()
  (let (files)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/diff3"))
              ((symbol-function 'call-process)
               (lambda (&rest args) (setq files (last args 3)) 2)))
      (should-error (zr-org-tangle--merge "a" "b" "c")))
    (should (= (length files) 3))
    (should-not (cl-some #'file-exists-p files))))

(ert-deftest zr-org-test-link-escapes-html ()
  (let ((html (zr-org-link--export "a&b" "<label>" 'html nil)))
    (should (string-match-p "&lt;label&gt;" html))
    (should (string-match-p "a%26b" html))
    (should-not (string-match-p ">\(<label>\)" html))))

(ert-deftest zr-org-test-link-handler-restoration ()
  (let ((org-link-parameters (copy-tree org-link-parameters)))
    (org-link-set-parameters "dict" :follow #'ignore)
    (zr-org-link-mode 1) (zr-org-link-mode 1)
    (zr-org-link-mode -1)
    (should (eq (org-link-get-parameter "dict" :follow) #'ignore))))

(ert-deftest zr-org-test-latex-path-relative-to-output ()
  (let ((default-directory "/tmp/source/"))
    (should (equal (zr-org-export-latex-image-path "before \\includegraphics[width=2cm]{image.png}" 'latex
                                                  '(:output-file "/tmp/output/report.tex"))
                   "before \\includegraphics[width=2cm]{../source/image.png}\u200b"))
    (should (equal (zr-org-export-latex-image-path "unchanged" 'html nil) "unchanged"))))

(ert-deftest zr-org-test-cookie-path-rejects-traversal-before-io ()
  (cl-letf (((symbol-function 'make-directory) (lambda (&rest _) (ert-fail "Unexpected filesystem access"))))
    (should-error (zr-org-protocol-import-cookies '(:host "../escape" :cookies "text")) :type 'user-error)))

(ert-deftest zr-org-test-cookie-import-and-no-server-client-kill ()
  (let* ((zr-org-protocol-cookie-directory (make-temp-file "zr-cookies-test-" t))
         (url-cookie-file (expand-file-name "url/cookies" zr-org-protocol-cookie-directory)) imported saved)
    (unwind-protect
        (cl-letf (((symbol-function 'url-cookie-parse-file-netscape) (lambda (file &optional _) (setq imported file)))
                  ((symbol-function 'url-cookie-write-file) (lambda () (setq saved t))))
          (zr-org-protocol-import-cookies '(:host "example.org" :cookies "# Netscape HTTP Cookie File\n"))
          (should saved)
          (should (file-exists-p imported))
          (should (= (logand (file-modes imported) #o777) #o600)))
      (delete-directory zr-org-protocol-cookie-directory t))))

(ert-deftest zr-org-test-viper-line-numbers-restored-on-error ()
  ;; Stub require as this test must not activate Viper globally.
  (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
            ((symbol-function 'viper-ex) (lambda (&rest _) (error "Cancelled"))))
    (zr-org-test--buffer ""
      (let ((ex-token-alist nil))
        (should-error (zr-viper-ex))
        (should-not display-line-numbers-mode)))))
;;; zr-user-org-test.el ends here
