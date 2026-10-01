;;; zr-pcmpl-test.el --- Command completion tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-pcmpl)

(defun zr-pcmpl-test--candidates (line)
  "Return the actual pcomplete candidates for LINE."
  (with-temp-buffer
    (insert line)
    (let* ((pcomplete-parse-arguments-function #'pcomplete-parse-buffer-arguments)
           (pcomplete-command-completion-function #'ignore)
           (pcomplete-use-paring nil)
           (capf (pcomplete-completions-at-point)))
      (should capf)
      (all-completions (buffer-substring-no-properties (nth 0 capf) (nth 1 capf))
                       (nth 2 capf)))))

(ert-deftest zr-pcmpl-archive-members-after-options ()
  (let* ((directory (make-temp-file "zr-pcmpl-" t))
         (default-directory (file-name-as-directory directory))
         calls)
    (unwind-protect
        (progn
          (write-region "" nil "archive.7z" nil 'silent)
          (zr-pcmpl-mode 1)
          (cl-letf (((symbol-function 'zr-pcmpl--help) #'ignore)
                    ((symbol-function 'zr-pcmpl--lines)
                     (lambda (&rest arguments)
                       (push arguments calls)
                       '("Path = archive.7z" "----------" "Path = inside.txt"))))
            (should (member "inside.txt"
                            (zr-pcmpl-test--candidates "7z e -y archive.7z in")))
            (should (equal (cdar calls) '("l" "-slt" "-p-" "--" "archive.7z")))
            (setq calls nil)
            (should (member "archive.7z" (zr-pcmpl-test--candidates "7zz e ar")))
            (should-not calls)))
      (zr-pcmpl-mode -1)
      (delete-directory directory t))))

(ert-deftest zr-pcmpl-output-directory-and-install-subdirectory ()
  (let* ((directory (make-temp-file "zr-pcmpl-" t))
         (default-directory (file-name-as-directory directory)))
    (unwind-protect
        (progn
          (make-directory "nested/output" t)
          (write-region "" nil "nested/app.apk" nil 'silent)
          (write-region "" nil "nested/ignore.txt" nil 'silent)
          (zr-pcmpl-mode 1)
          (cl-letf (((symbol-function 'zr-pcmpl--help) #'ignore))
            (should (member "output/"
                            (zr-pcmpl-test--candidates "7z x archive.7z -onested/o")))
            (should (member "nested/" (zr-pcmpl-test--candidates "adb install n")))
            (let ((candidates (zr-pcmpl-test--candidates "adb install nested/")))
              (should (member "app.apk" candidates))
              (should-not (member "ignore.txt" candidates)))))
      (zr-pcmpl-mode -1)
      (delete-directory directory t))))

(ert-deftest zr-pcmpl-adb-pull-keeps-device-and-quotes-path ()
  (let (calls)
    (unwind-protect
        (progn
          (zr-pcmpl-mode 1)
          (cl-letf (((symbol-function 'zr-pcmpl--help) #'ignore)
                    ((symbol-function 'zr-pcmpl--lines)
                     (lambda (&rest arguments)
                       (push arguments calls)
                       '("/sdcard/picture.png"))))
            (should (member "/sdcard/picture.png"
                            (zr-pcmpl-test--candidates
                             "adb -H host -s serial pull -a /sdcard/p")))
            (should (equal (cdar calls)
                           '("-H" "host" "-s" "serial" "shell" "-nT" "ls" "-d1p"
                             "--" "'/sdcard/p'*")))
            (zr-pcmpl--adb-paths '("-s" "serial") "/sdcard/a'b;$x")
            (should (equal (car (last (car calls))) "'/sdcard/a'\\''b;$x'*"))))
      (zr-pcmpl-mode -1))))

(ert-deftest zr-pcmpl-disable-restores-existing-handlers ()
  (let ((original (and (fboundp 'pcomplete/7z) (symbol-function 'pcomplete/7z))))
    (unwind-protect
        (progn
          (fset 'pcomplete/7z #'ignore)
          (zr-pcmpl-mode 1)
          (zr-pcmpl-mode 1)
          (should (eq (symbol-function 'pcomplete/7z) 'zr-pcmpl-7z))
          (zr-pcmpl-mode -1)
          (should (eq (symbol-function 'pcomplete/7z) #'ignore)))
      (zr-pcmpl-mode -1)
      (if original
          (fset 'pcomplete/7z original)
        (fmakunbound 'pcomplete/7z)))))

(ert-deftest zr-pcmpl-test-restores-existing-handler ()
  (let ((old (and (fboundp 'pcomplete/7z) (symbol-function 'pcomplete/7z))))
    (unwind-protect
        (progn
          (fset 'pcomplete/7z #'ignore)
          (zr-pcmpl-mode 1)
          (zr-pcmpl-mode 1)
          (should (eq (symbol-function 'pcomplete/7z) #'zr-pcmpl-7z))
          (zr-pcmpl-mode -1)
          (should (eq (symbol-function 'pcomplete/7z) #'ignore)))
      (zr-pcmpl-mode -1)
      (if old
          (fset 'pcomplete/7z old)
        (fmakunbound 'pcomplete/7z)))))

(provide 'zr-pcmpl-test)
;;; zr-pcmpl-test.el ends here
