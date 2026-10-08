;;; zr-windows-test.el --- Tests for zr-windows -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-windows)

(ert-deftest zr-windows-test-coding-keeps-remote-behavior ()
  (let ((default-directory "/ssh:example.org:/tmp/")
        calls)
    (cl-letf (((symbol-function 'zr-windows-command-coding)
               (lambda (_)
                 (ert-fail "Local decoding used on remote command"))))
      (should (eq 'result (zr-windows--shell-command
                           (lambda (&rest args)
                             (setq calls args)
                             'result)
                           1 2 "dir")))
      (should (equal calls '(1 2 "dir"))))))

(ert-deftest zr-windows-test-armored-only-normalization ()
  (should (equal (zr-windows--armor "-----BEGIN PGP MESSAGE-----\r\nbody\r\n")
                 "-----BEGIN PGP MESSAGE-----\nbody\n"))
  (should (equal (zr-windows--armor "binary\r\nbytes") "binary\r\nbytes")))

(defmacro zr-windows-test--with-ime-buffers (buffers &rest body)
  "Run BODY with temporary BUFFERS and simulated Windows IME support."
  (declare (indent 1) (debug (sexp body)))
  `(let ((system-type 'windows-nt)
         (after-focus-change-function #'ignore)
         ,@(mapcar (lambda (buffer)
                     `(,buffer (generate-new-buffer ,(format " *%s*" buffer))))
                   buffers))
     (unwind-protect
         (cl-letf (((symbol-function 'w32-set-ime-open-status) #'ignore)
                   ((symbol-function 'frame-focus-state) (lambda (&optional _) t)))
           (save-window-excursion
             (delete-other-windows)
             ,@body))
       (dolist (buffer (list ,@buffers))
         (when (buffer-live-p buffer)
           (kill-buffer buffer))))))

(ert-deftest zr-windows-test-ime-focus-uses-selected-buffer ()
  (zr-windows-test--with-ime-buffers (moyu other)
    (switch-to-buffer moyu)
    (zr-windows-ime-mode 1)
    (let ((window (selected-window)) calls)
      (cl-letf (((symbol-function 'w32-set-ime-open-status)
                 (lambda (status)
                   (push (list (current-buffer) (selected-window) status) calls))))
        ;; Focus notifications can run with an unrelated current buffer.
        (with-current-buffer other
          (funcall after-focus-change-function)
          (should (eq (current-buffer) other)))
        (should (equal calls (list (list moyu window nil))))
        (setq calls nil)
        (switch-to-buffer other)
        (with-current-buffer moyu
          (funcall after-focus-change-function))
        (should-not calls)))))

(ert-deftest zr-windows-test-ime-window-hooks-ignore-background-windows ()
  (zr-windows-test--with-ime-buffers (moyu other)
    (switch-to-buffer other)
    (let ((window (split-window-right)) calls)
      (set-window-buffer window moyu)
      (cl-letf (((symbol-function 'w32-set-ime-open-status)
                 (lambda (status) (push status calls))))
        (with-current-buffer moyu
          (zr-windows-ime-mode 1)
          (run-hook-with-args 'window-buffer-change-functions window)
          (run-hook-with-args 'window-selection-change-functions window))
        (should-not calls)
        (select-window window)
        (run-hook-with-args 'window-selection-change-functions window)
        (should (equal calls '(nil)))
        (setq calls nil)
        (set-window-buffer window other)
        (with-current-buffer moyu
          (run-hook-with-args 'window-buffer-change-functions window))
        (should-not calls)))))

(ert-deftest zr-windows-test-ime-focus-finds-another-focused-frame ()
  (zr-windows-test--with-ime-buffers (moyu other)
    (switch-to-buffer other)
    (with-current-buffer moyu
      (zr-windows-ime-mode 1))
    (let ((original-window (selected-window))
          (moyu-window (split-window-right))
          calls)
      (set-window-buffer moyu-window moyu)
      ;; Model two frames with real windows in a batch Emacs.
      (cl-letf (((symbol-function 'frame-list) (lambda () '(unfocused focused)))
                ((symbol-function 'frame-selected-window)
                 (lambda (&optional frame)
                   (if (eq frame 'focused) moyu-window original-window)))
                ((symbol-function 'frame-focus-state)
                 (lambda (&optional frame) (eq frame 'focused)))
                ((symbol-function 'w32-set-ime-open-status)
                 (lambda (status)
                   (push (list (current-buffer) (selected-window) status) calls))))
        (funcall after-focus-change-function)
        (should (equal calls (list (list moyu moyu-window nil))))
        (should (eq (selected-window) original-window))
        (should (eq (current-buffer) other))))))

(ert-deftest zr-windows-test-ime-requires-known-focus ()
  (zr-windows-test--with-ime-buffers (moyu)
    (switch-to-buffer moyu)
    (zr-windows-ime-mode 1)
    (dolist (focus '(nil unknown))
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) focus))
                ((symbol-function 'w32-set-ime-open-status)
                 (lambda (_status) (ert-fail "IME closed without known focus"))))
        (funcall after-focus-change-function)
        (run-hook-with-args 'window-selection-change-functions (selected-window))))))

(ert-deftest zr-windows-test-ime-rejects-unsupported-systems ()
  (dolist (platform '(gnu/linux windows-nt))
    (let ((system-type platform)
          (after-focus-change-function #'ignore))
      (with-temp-buffer
        (cl-letf (((symbol-function 'w32-set-ime-open-status)
                   (and (eq platform 'gnu/linux) #'ignore)))
          (should-error (zr-windows-ime-mode 1) :type 'user-error)
          (should-not zr-windows-ime-mode)
          (should (eq after-focus-change-function #'ignore))
          (should-not (memq #'zr-windows-ime-close
                            window-selection-change-functions)))))))

(ert-deftest zr-windows-test-ime-shared-hook-lifecycle ()
  (dolist (cleanup '(disable kill change-major-mode))
    (zr-windows-test--with-ime-buffers (first second)
      (setq after-focus-change-function #'ignore)
      (dolist (buffer (list first second))
        (with-current-buffer buffer
          (zr-windows-ime-mode 1)
          (zr-windows-ime-mode 1)
          (should (= (cl-count #'zr-windows-ime-close
                              window-selection-change-functions)
                     1))))
      (dolist (buffer (list first second))
        (should (advice-function-member-p #'zr-windows-ime-close
                                         after-focus-change-function))
        (with-current-buffer buffer
          (pcase cleanup
            ('disable
             (zr-windows-ime-mode -1)
             (zr-windows-ime-mode -1))
            ('kill (kill-buffer buffer))
            ('change-major-mode (fundamental-mode))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (should-not zr-windows-ime-mode)
            (should-not (memq #'zr-windows-ime-close
                              window-selection-change-functions))
            (should-not (memq #'zr-windows-ime-close
                              window-buffer-change-functions)))))
      (should (eq after-focus-change-function #'ignore)))))

(ert-deftest zr-windows-test-ime-quit-hides-buffers-without-killing ()
  (zr-windows-test--with-ime-buffers (first second other)
    (switch-to-buffer other)
    (let* ((original-window (selected-window))
           (first-window (split-window-right))
           (second-window (split-window first-window nil 'below)))
      (set-window-buffer first-window first)
      (set-window-buffer second-window second)
      (dolist (buffer (list first second))
        (with-current-buffer buffer
          (zr-windows-ime-mode 1)))
      (zr-windows-quit-ime-buffers)
      (dolist (buffer (list first second))
        (should (buffer-live-p buffer))
        (should (buffer-local-value 'zr-windows-ime-mode buffer))
        (should-not (get-buffer-window buffer t)))
      (should (window-live-p original-window))
      (should (eq (window-buffer original-window) other)))))

(provide 'zr-windows-test)
;;; zr-windows-test.el ends here
