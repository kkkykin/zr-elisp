;;; zr-terminal-test.el --- Tests for zr-terminal -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-terminal)

(ert-deftest zr-terminal-test-notify-sends-utf8-to-selected-frame ()
  "Notification text is written as UTF-8 bytes to the selected terminal."
  (let (sent target)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (string frame) (setq sent string target frame))))
      (should (zr-terminal-notify "任务完成" "中文😀")))
    (should (eq target (selected-frame)))
    (should-not (multibyte-string-p sent))
    (should (equal sent
                   (encode-coding-string "\e]777;notify;任务完成;中文😀\a"
                                         'utf-8 t)))))

(ert-deftest zr-terminal-test-notify-sanitizes-protocol-delimiters ()
  "Text cannot introduce another field, terminate OSC, or cancel it."
  (let (sent)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (string _frame) (setq sent string))))
      (zr-terminal-notify "a;b\a" "x\ny\e]52;clipboard\x18\x9c\u009c"))
    (should (equal sent "\e]777;notify;a b ;x y ]52 clipboard   \a"))))

(ert-deftest zr-terminal-test-send-uses-explicit-frame ()
  "An explicit client terminal is used without selecting its frame."
  (let ((selected (selected-frame)) target)
    (cl-letf (((symbol-function 'frame-live-p)
               (lambda (frame) (and (eq frame 'client-frame) t)))
              ((symbol-function 'display-graphic-p)
               (lambda (frame) (not (eq frame 'client-frame))))
              ((symbol-function 'send-string-to-terminal)
               (lambda (_string frame) (setq target frame))))
      (should (zr-terminal-notify "title" "body" 'client-frame)))
    (should (eq target 'client-frame))
    (should (eq selected (selected-frame)))))

(ert-deftest zr-terminal-test-send-rejects-graphical-or-dead-frame ()
  "Unusable targets fail before any bytes are sent."
  (let (sent)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (&rest _) (setq sent t))))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (should-error (zr-terminal-send-osc 777 "notify;a;b") :type 'user-error))
      (should-error (zr-terminal-send-osc 777 "notify;a;b" 'dead-frame)
                    :type 'user-error))
    (should-not sent)))

(ert-deftest zr-terminal-test-send-rejects-invalid-osc-before-writing ()
  "Invalid codes and embedded controls cannot reach the terminal."
  (let (sent)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (&rest _) (setq sent t))))
      (dolist (code '(-1 "777" nil))
        (should-error (zr-terminal-send-osc code "text") :type 'wrong-type-argument))
      (dolist (payload '("a\ab" "a\eb" "a\nb" "a\u0018b" "a\u009cb"))
        (should-error (zr-terminal-send-osc 0 payload)))
      (should-error (zr-terminal-send-osc 0 (unibyte-string 156))))
    (should-not sent)))

(ert-deftest zr-terminal-test-send-propagates-write-error ()
  "A failed write must not be reported as a sent notification."
  (cl-letf (((symbol-function 'send-string-to-terminal)
             (lambda (&rest _) (error "Broken pipe"))))
    (should-error (zr-terminal-notify "title" "body"))))

(provide 'zr-terminal-test)
;;; zr-terminal-test.el ends here
