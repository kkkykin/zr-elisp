;;; zr-notify-test.el --- Tests for zr-notify -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-notify)

(ert-deftest zr-notify-test-dispatch-and-appointment ()
  (let (seen)
    (let ((system-type 'android))
      (cl-letf (((symbol-function 'android-notifications-notify)
                 (lambda (&rest args)
                   (setq seen args)
                   7)))
        (should (= (zr-notify-send "title" "body" :timeout 500) 7))
        (should (equal seen '(:title "title" :body "body" :timeout 500)))))
    (let ((zr-notify-function (lambda (&rest args)
                                (setq seen args))))
      (zr-notify-appointment '("1" "3") nil '("first" "second"))
      (should (equal (seq-take seen 2) '("In 1, 3 minutes" "first\nsecond"))))))

(ert-deftest zr-notify-test-windows-notification-native-api ()
  (let ((system-type 'windows-nt)
        called
        closed
        delay
        callback
        (zr-notify--windows-timers (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'w32-notification-notify)
               (lambda (&rest _)
                 (setq called t)
                 10))
              ((symbol-function 'w32-notification-close)
               (lambda (id)
                 (setq closed id)))
              ((symbol-function 'run-at-time)
               (lambda (seconds _repeat function &rest _)
                 (setq delay seconds
                       callback function)
                 'timer)))
      (zr-notify-send "a" "b" :timeout 3000)
      (should called)
      (should (= delay 3.0))
      (funcall callback)
      (should (= closed 10)))))

(provide 'zr-notify-test)
;;; zr-notify-test.el ends here
