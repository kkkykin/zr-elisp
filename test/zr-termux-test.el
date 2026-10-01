;;; zr-termux-test.el --- Tests for zr-termux -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-termux)

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
