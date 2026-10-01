;;; zr-test-helpers.el --- Shared test fixtures -*- lexical-binding: t; -*-

;;; Commentary:

;; Temporary directories and Org buffers for module behavior tests.

;;; Code:

(require 'cl-lib)

(defmacro zr-test-with-temp-directory (&rest body)
  (declare (indent 0) (debug t))
  `(let ((default-directory (file-name-as-directory (make-temp-file "zr-tools-test-" t))))
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-local-value 'buffer-file-name buffer)
                    (string-prefix-p default-directory
                                     (buffer-local-value 'buffer-file-name buffer)))
           (with-current-buffer buffer
             (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory default-directory t))))

(defmacro zr-test-with-org-buffer (text &rest body)
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(provide 'zr-test-helpers)
;;; zr-test-helpers.el ends here
