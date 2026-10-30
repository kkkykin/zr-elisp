;;; zr-termux-test.el --- Tests for zr-termux -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-termux)

(ert-deftest zr-termux-test-tts-utf8-stdin ()
  (let ((cat (executable-find "cat"))
        (text "-n 猫 'quoted' $literal\n二行目")
        (zr-termux-tts-arguments nil)
        process)
    (unless cat (ert-skip "cat is unavailable"))
    (with-current-buffer (get-buffer-create "*zr-termux-tts*") (erase-buffer))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (name) (when (equal name "termux-tts-speak") cat))))
          ;; A real pipe verifies Unicode, leading options and EOF transport.
          (setq process (zr-termux-tts-speak text))
          (let ((deadline (+ (float-time) 5)))
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (should-not (process-live-p process))
          (should (= (process-exit-status process) 0))
          (should (equal (with-current-buffer (process-buffer process) (buffer-string)) text)))
      (when (process-live-p process) (delete-process process))
      (when-let* ((buffer (get-buffer "*zr-termux-tts*"))) (kill-buffer buffer)))))

(ert-deftest zr-termux-test-tts-arguments-and-missing-command ()
  (let ((zr-termux-tts-arguments '("-s" "MUSIC" "-l" "ja" "-r" "0.8"))
        command sent eof)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/termux/termux-tts-speak"))
              ((symbol-function 'make-process)
               (lambda (&rest options)
                 (setq command (plist-get options :command))
                 'tts-process))
              ((symbol-function 'process-send-string)
               (lambda (process text) (setq sent (list process text))))
              ((symbol-function 'process-send-eof) (lambda (process) (setq eof process))))
      (should (eq (zr-termux-tts-speak "猫") 'tts-process)))
    (should (equal command '("/termux/termux-tts-speak" "-s" "MUSIC" "-l" "ja" "-r" "0.8")))
    (should (equal sent '(tts-process "猫")))
    (should (eq eof 'tts-process)))
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-error (zr-termux-tts-speak "猫") :type 'user-error)))

(ert-deftest zr-termux-test-notification-arguments ()
  (let ((args (zr-termux--notification-arguments
               "Title" "Body" '(:replaces-id 42 :urgency critical :led-on 100
                                :suppress-sound t
                                :actions ("Open" "am start foo") :ongoing t))))
    (should (equal (cadr (member "--id" args)) "42"))
    (should (equal (cadr (member "--priority" args)) "high"))
    (should (equal (cadr (member "--button1-action" args)) "am start foo"))
    (should-not (member "--sound" args))
    (should (cl-every #'stringp args))))

(ert-deftest zr-termux-test-timeout-replacement-and-distinct-ids ()
  (let ((zr-termux--notification-timers (make-hash-table :test #'equal))
        calls
        timers
        cancelled)
    (cl-letf (((symbol-function 'zr-termux--call)
               (lambda (&rest args)
                 (push args calls)))
              ((symbol-function 'run-at-time)
               (lambda (delay repeat callback &rest _)
                 (let ((timer (list delay repeat callback)))
                   (push timer timers)
                   timer)))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer cancelled))))
      (zr-termux-notify "a" "b" :replaces-id 42 :timeout 5000)
      (zr-termux-notify "c" "d" :replaces-id "42" :timeout 1000)
      (should (= (length cancelled) 1))
      (should (= (caar timers) 1.0))
      (funcall (nth 2 (car timers)))
      (should (equal (car calls) '("termux-notification-remove" "42")))
      (should-not (equal (zr-termux-notify "a" "b") (zr-termux-notify "a" "b"))))))

(provide 'zr-termux-test)
;;; zr-termux-test.el ends here
