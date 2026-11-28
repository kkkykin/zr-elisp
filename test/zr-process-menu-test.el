;;; zr-process-menu-test.el --- Tests for zr-process-menu -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-process-menu)

(ert-deftest zr-process-menu-test-process-filter-groups-display-only ()
  (with-temp-buffer
    (let ((tabulated-list-entries '((one ["server" "run"]) (two ["worker" "run"])))
          (zr-process-menu-omit-regexp "server")
          (zr-process-menu-group-column 1))
      (should (equal (caar (zr-process-menu--groups)) "* run"))
      (should (equal (mapcar #'car tabulated-list-entries) '(two))))))

(ert-deftest zr-process-menu-test-initial-listing-refresh-and-mode-lifecycle ()
  (let* ((shown (make-pipe-process :name "zr-process-menu-shown" :noquery t))
         (hidden (make-pipe-process :name "zr-process-menu-hidden" :noquery t))
         (first (generate-new-buffer " *zr processes 1*"))
         (second (generate-new-buffer " *zr processes 2*"))
         (process-menu-mode-hook
          (list (lambda ()
                  (setq zr-process-menu-omit-regexp (regexp-quote (process-name hidden))
                        zr-process-menu-group-column 2)
                  (zr-process-menu-mode 1)))))
    (unwind-protect
        (progn
          (list-processes nil first)
          (with-current-buffer first
            (should (assq shown tabulated-list-entries))
            (should-not (assq hidden tabulated-list-entries))
            (should (string-match-p
                     (regexp-quote (concat "* " (symbol-name (process-status shown))))
                     (buffer-string)))
            (should-not (string-match-p (regexp-quote (process-name hidden))
                                        (buffer-string)))
            (setq zr-process-menu-group-column nil)
            (revert-buffer)
            (should (assq shown tabulated-list-entries))
            (should-not (assq hidden tabulated-list-entries))
            (should-not (string-match-p "^\\* " (buffer-string))))
          (let ((process-menu-mode-hook nil))
            (list-processes nil second))
          (with-current-buffer second
            (should (assq hidden tabulated-list-entries))
            (should-not tabulated-list-groups))
          (with-current-buffer first
            (zr-process-menu-mode -1)
            (should (assq hidden tabulated-list-entries))
            (zr-process-menu-mode 1)
            (zr-process-menu-mode 1)
            (should-not (assq hidden tabulated-list-entries))
            (fundamental-mode)
            (should-not tabulated-list-groups)
            (should-not zr-process-menu-mode)))
      (delete-process shown)
      (delete-process hidden)
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest zr-process-menu-test-exit-query-shows-omitted-processes ()
  (let* ((queried (make-pipe-process :name "zr-process-menu-ispell" :buffer nil))
         (background (make-pipe-process :name "zr-process-menu-server" :buffer nil :noquery t))
         (buffer (generate-new-buffer " *zr exit processes*"))
         (process-menu-mode-hook
          (list (lambda ()
                  (setq zr-process-menu-omit-regexp (regexp-quote (process-name queried)))
                  (zr-process-menu-mode 1)))))
    (unwind-protect
        (progn
          (list-processes nil buffer)
          (with-current-buffer buffer
            (should-not (assq queried tabulated-list-entries))
            (should (assq background tabulated-list-entries)))
          ;; `save-buffers-kill-emacs' uses this listing before its query.
          (list-processes t buffer)
          (with-current-buffer buffer
            (should (assq queried tabulated-list-entries))
            (should-not (assq background tabulated-list-entries))
            (should (string-match-p (regexp-quote (process-name queried)) (buffer-string)))
            (revert-buffer)
            (should (assq queried tabulated-list-entries))
            (should (equal zr-process-menu-omit-regexp (regexp-quote (process-name queried)))))
          (list-processes nil buffer)
          (with-current-buffer buffer
            (should-not (assq queried tabulated-list-entries)))
          (should (process-query-on-exit-flag queried))
          (should-not (process-query-on-exit-flag background)))
      (delete-process queried)
      (delete-process background)
      (kill-buffer buffer))))

(provide 'zr-process-menu-test)
;;; zr-process-menu-test.el ends here
