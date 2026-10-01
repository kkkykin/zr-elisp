;;; zr-data-test.el --- Tests for zr-data -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-data)
(require 'zr-test-helpers)

(ert-deftest zr-data-test-json-merge-values-and-no-input-mutation ()
  (let* ((first
          (json-parse-string "{\"a\":{\"x\":1},\"list\":[1],\"false\":false,\"nil\":null}"))
         (second
          (json-parse-string "{\"a\":{\"y\":2},\"list\":[2],\"false\":true,\"nil\":0}"))
         (merged (zr-data-merge-json first second)))
    (should (= (gethash "y" (gethash "a" merged)) 2))
    (should-not (gethash "y" (gethash "a" first)))
    (should (equal (gethash "list" merged) [1 2]))
    (should (eq (gethash "false" merged) t))
    (should (= (gethash "nil" merged) 0))))

(ert-deftest zr-data-test-json-parse-failure-preserves-output ()
  (zr-test-with-temp-directory
    (with-temp-file "a"
      (insert "{}"))
    (with-temp-file "b"
      (insert "invalid"))
    (with-temp-file "output"
      (insert "original"))
    (should-error (zr-data-merge-json-files "a" "b" "output"))
    (should (equal (with-temp-buffer
                     (insert-file-contents "output")
                     (buffer-string))
                   "original"))))

(ert-deftest zr-data-test-sops-checks-exit-status ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_)
               "/sops"))
            ((symbol-function 'process-file)
             (lambda (&rest _)
               (insert "not decrypted")
               1)))
    (should-error (zr-data-sops-decrypt "test"))))

(ert-deftest zr-data-test-uuid-is-deterministic-and-well-formed ()
  (let ((id (zr-data-uuid '(example "中文"))))
    (should (equal id (zr-data-uuid '(example "中文"))))
    (should (string-match-p "\\`[0-9a-f-]\\{14\\}3[0-9a-f]\\{3\\}-[89ab]" id))))

(provide 'zr-data-test)
;;; zr-data-test.el ends here
