;;; zr-comint-test.el --- Tests for zr-comint -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-comint)
(require 'zr-test-helpers)

(ert-deftest zr-comint-test-preserves-file-and-sentinel ()
  (zr-test-with-temp-directory
    (with-temp-buffer
      (comint-mode)
      (let* ((history (expand-file-name "custom/history"))
             (comint-input-ring-file-name history)
             (zr-comint-kill-buffer-on-exit nil)
             (process
              (make-pipe-process :name "zr-history-test" :buffer (current-buffer)
                                 :noquery t))
             (calls 0))
        (unwind-protect
            (cl-letf (((symbol-function 'process-command)
                       (lambda (_)
                         '("custom-program"))))
              (set-process-sentinel process (lambda (_process _event)
                                              (setq calls (1+ calls))))
              (zr-comint-history-mode 1)
              (zr-comint-history-mode 1)
              (should (equal comint-input-ring-file-name history))
              (ring-insert comint-input-ring "hello")
              (zr-comint-save-history)
              (should (file-exists-p history))
              (zr-comint-history-mode -1)
              (funcall (process-sentinel process) process "finished\n")
              (should (= calls 1))
              (should-not
               (advice-function-member-p #'zr-comint--sentinel
                                         (process-sentinel process))))
          (delete-process process))))))

(ert-deftest zr-comint-test-saves-before-original-kills-buffer ()
  (zr-test-with-temp-directory
    (let ((buffer (generate-new-buffer " *zr history*"))
          (file (expand-file-name "history")))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local comint-input-ring-file-name file)
            (ring-insert comint-input-ring "last-command")
            (let ((zr-comint-history-mode t))
              (cl-letf (((symbol-function 'process-buffer)
                         (lambda (_)
                           buffer))
                        ((symbol-function 'process-status)
                         (lambda (_)
                           'exit))
                        ((symbol-function 'process-exit-status)
                         (lambda (_)
                           0)))
                (zr-comint--sentinel (lambda (&rest _)
                                       (kill-buffer buffer))
                                     'fake "finished\n")))
            (should (file-exists-p file)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest zr-comint-test-emacs-exit-saves-all-enabled-buffers ()
  (zr-test-with-temp-directory
    (let ((first (generate-new-buffer " *zr exit 1*"))
          (second (generate-new-buffer " *zr exit 2*"))
          (kill-emacs-hook nil))
      (unwind-protect
          (progn
            (dolist (entry (list (cons first "one") (cons second "two")))
              (with-current-buffer (car entry)
                (comint-mode)
                (setq-local comint-input-ring-file-name (expand-file-name (cdr entry)))
                (zr-comint-history-mode 1)
                (zr-comint-history-mode 1)
                (ring-insert comint-input-ring (cdr entry))))
            (should (= (cl-count #'zr-comint--save-all kill-emacs-hook) 1))
            (run-hooks 'kill-emacs-hook)
            (should (equal (with-temp-buffer
                             (insert-file-contents "one")
                             (buffer-string))
                           "one\n"))
            (should (equal (with-temp-buffer
                             (insert-file-contents "two")
                             (buffer-string))
                           "two\n"))
            (with-current-buffer first
              (zr-comint-history-mode -1))
            (should (memq #'zr-comint--save-all kill-emacs-hook))
            (kill-buffer second)
            (should-not (memq #'zr-comint--save-all kill-emacs-hook)))
        (dolist (buffer (list first second))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(provide 'zr-comint-test)
;;; zr-comint-test.el ends here
