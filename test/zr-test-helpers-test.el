;;; zr-test-helpers-test.el --- Temporary directory cleanup tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'zr-test-helpers)

(ert-deftest zr-test-helpers-test-buffer-switch-does-not-change-cleanup-directory ()
  (let* ((outside (file-name-as-directory (make-temp-file "zr-cleanup-outside-" t)))
         (sentinel (expand-file-name "keep" outside))
         (buffer (generate-new-buffer " *zr-cleanup-outside*"))
         temporary)
    (unwind-protect
        (progn
          (with-temp-file sentinel (insert "preserve"))
          (with-current-buffer buffer (setq default-directory outside))
          (save-window-excursion
            (zr-test-with-temp-directory
              (setq temporary default-directory)
              (switch-to-buffer buffer)))
          (should (file-exists-p sentinel))
          (should-not (file-exists-p temporary)))
      (kill-buffer buffer)
      (when (file-directory-p outside) (delete-directory outside t))
      (when (and temporary (file-directory-p temporary)) (delete-directory temporary t)))))

(ert-deftest zr-test-helpers-test-only-closes-buffers-from-the-created-directory ()
  (let* ((outside (file-name-as-directory (make-temp-file "zr-cleanup-outside-" t)))
         (file (expand-file-name "keep" outside))
         outside-buffer temporary-buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert "preserve"))
          (setq outside-buffer (find-file-noselect file))
          (save-window-excursion
            (zr-test-with-temp-directory
              (with-temp-file "inside" (insert "temporary"))
              (setq temporary-buffer (find-file-noselect (expand-file-name "inside")))
              (switch-to-buffer outside-buffer)))
          (should-not (buffer-live-p temporary-buffer))
          (should (buffer-live-p outside-buffer))
          (should (file-exists-p file)))
      (when (buffer-live-p outside-buffer) (kill-buffer outside-buffer))
      (when (buffer-live-p temporary-buffer) (kill-buffer temporary-buffer))
      (delete-directory outside t))))

(provide 'zr-test-helpers-test)
;;; zr-test-helpers-test.el ends here
