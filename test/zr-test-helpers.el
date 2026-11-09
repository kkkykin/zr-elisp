;;; zr-test-helpers.el --- Shared test fixtures -*- lexical-binding: t; -*-

;;; Commentary:

;; Subprocess output, temporary directories and Org buffers for behavior tests.

;;; Code:

(require 'cl-lib)

(defmacro zr-test-with-process-output (stdout stderr status &rest body)
  "Run BODY with real synchronous subprocesses emitting STDOUT and STDERR.
Each subprocess exits with STATUS instead of running the requested program."
  (declare (indent 3) (debug (form form form body)))
  (let ((command (make-symbol "command"))
        (original (make-symbol "call-process"))
        (runner (make-symbol "runner")))
    `(let ((,original (symbol-function 'call-process))
           (,command
            (list (expand-file-name invocation-name invocation-directory)
                  "--batch" "-Q" "--eval"
                  (prin1-to-string
                   `(progn
                      (princ ,,stderr 'external-debugging-output)
                      (princ ,,stdout)
                      (kill-emacs ,,status))))))
       (cl-labels ((,runner (_program _infile destination _display &rest _args)
                     (apply ,original (car ,command) nil destination nil (cdr ,command))))
         (cl-letf (((symbol-function 'call-process) #',runner)
                   ((symbol-function 'process-file) #',runner))
           ,@body)))))

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
