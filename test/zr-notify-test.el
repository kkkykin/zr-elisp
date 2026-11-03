;;; zr-notify-test.el --- Tests for zr-notify -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-notify)
(declare-function notifications-notify "notifications")

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

(ert-deftest zr-notify-test-terminal-backend ()
  "Opting in sends a terminal notification and forwards only its frame."
  (let ((zr-notify-function #'zr-notify-terminal) seen)
    (cl-letf (((symbol-function 'frame-live-p)
               (lambda (_frame) t))
              ((symbol-function 'display-graphic-p)
               (lambda (_frame) nil))
              ((symbol-function 'zr-terminal-notify)
               (lambda (title body frame)
                 (setq seen (list title body frame))
                 t)))
      (should (zr-notify-send "title" "body" :frame 'client-frame
                              :timeout 500 :urgency 'critical :replaces-id 100))
      (should (equal seen '("title" "body" client-frame)))
      (zr-notify-appointment '("1" "3") nil '("first" "second"))
      (should (equal seen (list "In 1, 3 minutes" "first\nsecond"
                               (selected-frame)))))))

(ert-deftest zr-notify-test-terminal-backend-unavailable-frame ()
  "Unusable frames warn once; an explicit TTY still receives notifications."
  (let ((zr-notify-function #'zr-notify-terminal)
        (zr-notify--terminal-warning-issued-p nil)
        seen warnings)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'graphical-frame))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(graphical-frame terminal-frame))))
              ((symbol-function 'display-graphic-p)
               (lambda (frame) (eq frame 'graphical-frame)))
              ((symbol-function 'zr-terminal-notify)
               (lambda (title body frame)
                 (setq seen (list title body frame))
                 t))
              ((symbol-function 'display-warning)
               (lambda (type message level)
                 (push (list type message level) warnings))))
      (should-not (zr-notify-send "title" "body"))
      (should-not (zr-notify-send "title" "body" :frame 'dead-frame))
      (should-not seen)
      (should (= (length warnings) 1))
      (should (eq (caar warnings) 'zr-notify))
      (should (eq (caddar warnings) :warning))
      (should (string-match-p "zr-notify-function" (cadar warnings)))
      (should (zr-notify-send "title" "body" :frame 'terminal-frame))
      (should (equal seen '("title" "body" terminal-frame))))))

(ert-deftest zr-notify-test-terminal-routing-preserves-erc-filling ()
  "An echoed mention finishes ERC insertion when OSC cannot reach a frame."
  (require 'erc-fill)
  (require 'erc-match)
  (require 'erc-desktop-notifications)
  (let ((erc-modules nil)
        (erc-fill-mode t)
        (erc--fill-wrap-scrolltobottom-exempt-p t)
        (erc-fill-wrap-merge nil)
        (erc-insert-modify-hook '(erc-match-message erc-fill))
        (erc-insert-post-hook nil)
        (erc-text-matched-hook '(erc-notifications-notify-on-match))
        (erc-desktop-notifications-skip-predicates nil)
        (zr-notify-function #'zr-notify-terminal)
        (zr-notify--terminal-warning-issued-p nil)
        warned)
    (unwind-protect
        (progn
          (zr-notify-mode 1)
          (with-temp-buffer
            (erc-mode)
            (setq erc-server-current-nick "me"
                  erc--target (erc--target-from-string "#notify-test"))
            (erc--initialize-markers nil nil)
            (erc-fill-wrap-mode 1)
            (let* ((start (marker-position erc-insert-marker))
                   (parsed (make-erc-response
                            :sender "me!u@h" :command "PRIVMSG"
                            :command-args '("#notify-test") :contents "me: hello"
                            :unparsed ":me!u@h PRIVMSG #notify-test :me: hello"))
                   (erc--parsed-response parsed)
                   (erc--msg-prop-overrides
                    '((erc--msg . PRIVMSG) (erc--spkr . "me")
                      (erc--pfx . erc--pfx-skip-spkr-fwd))))
              (cl-letf (((symbol-function 'display-graphic-p)
                         (lambda (&rest _) t))
                        ((symbol-function 'send-string-to-terminal)
                         (lambda (&rest _) (ert-fail "Wrote OSC to a GUI frame")))
                        ((symbol-function 'display-warning)
                         (lambda (&rest _) (setq warned t))))
                (erc-display-message
                 parsed nil (current-buffer)
                 (concat "<" (propertize "me" 'erc--speaker "me") "> me: hello")))
              (should warned)
              (should (get-text-property start 'line-prefix))
              (should (equal (get-text-property start 'wrap-prefix)
                             '(space :width erc-fill--wrap-value)))
              (should (eq (get-text-property start 'erc--msg) 'PRIVMSG))
              (should (equal (buffer-substring-no-properties start erc-insert-marker)
                             "<me> me: hello\n")))))
      (zr-notify-mode -1))))

(ert-deftest zr-notify-test-global-routing-and-lifecycle ()
  (require 'notifications)
  (should-not zr-notify-mode)
  (should-not (advice-member-p #'zr-notify--notifications-notify
                               'notifications-notify))
  (let* ((system-type 'gnu/linux) seen original-calls
         (zr-notify-function (lambda (&rest args) (setq seen args) 7)))
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest args) (push args original-calls) 11)))
      (unwind-protect
          (progn
            (zr-notify-mode 1)
            (zr-notify-mode 1)
            (should (= (notifications-notify :title "title" :body "body"
                                             :bus :session :timeout 500)
                       7))
            (should (equal seen '("title" "body" :timeout 500)))
            (should-not original-calls)
            (zr-notify-mode -1)
            (zr-notify-mode -1)
            (should-not (advice-member-p #'zr-notify--notifications-notify
                                         'notifications-notify))
            (should (= (notifications-notify :title "original") 11))
            (should (equal original-calls '((:title "original")))))
        (zr-notify-mode -1)))))

(ert-deftest zr-notify-test-global-default-does-not-recurse ()
  (require 'notifications)
  (let ((system-type 'gnu/linux) (zr-notify-function nil) calls)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest args) (push args calls) 11)))
      (unwind-protect
          (progn
            (zr-notify-mode 1)
            (should (= (zr-notify-send "title" "body" :timeout 500) 11))
            (should (equal calls '((:title "title" :body "body" :timeout 500))))
            (should (= (notifications-notify :bus :session :body "direct") 11))
            (should (equal (car calls) '(:bus :session :body "direct"))))
        (zr-notify-mode -1)))))

(ert-deftest zr-notify-test-global-native-backends ()
  (require 'notifications)
  (dolist (platform '(android windows-nt))
    (let ((system-type platform) (zr-notify-function nil) seen)
      (cl-letf (((symbol-function 'notifications-notify)
                 (lambda (&rest _) (ert-fail "Called D-Bus notification API")))
                ((symbol-function 'android-notifications-notify)
                 (lambda (&rest args) (setq seen args) 7))
                ((symbol-function 'w32-notification-notify)
                 (lambda (&rest args) (setq seen args) 7)))
        (unwind-protect
            (progn
              (zr-notify-mode 1)
              (should (= (notifications-notify :bus :session :title "title"
                                               :body "body" :urgency 'normal)
                         7))
              (should (equal seen '(:title "title" :body "body" :urgency normal))))
          (zr-notify-mode -1))))))

(ert-deftest zr-notify-test-global-termux-drops-incompatible-actions ()
  (require 'notifications)
  (let ((system-type 'gnu/linux) (zr-notify-function #'zr-termux-notify) seen)
    (cl-letf (((symbol-function 'zr-termux-notify)
               (lambda (&rest args) (setq seen args) "termux-id")))
      (unwind-protect
          (progn
            (zr-notify-mode 1)
            (should (equal
                     (notifications-notify
                      :title "title" :body "body"
                      :actions '("default" "Switch to buffer")
                      :on-action #'ignore :on-close #'ignore
                      :replaces-id "previous" :timeout 500)
                     "termux-id"))
            (should (equal seen '("title" "body" :replaces-id "previous"
                                 :timeout 500))))
        (zr-notify-mode -1)))))

(ert-deftest zr-notify-test-windows-replacement-closes-old-notification ()
  (let ((system-type 'windows-nt) (zr-notify-function nil) events
        (zr-notify--windows-timers (make-hash-table :test #'equal)))
    (puthash 7 'previous-timer zr-notify--windows-timers)
    (cl-letf (((symbol-function 'w32-notification-notify)
               (lambda (&rest _) (push 'notify events) 8))
              ((symbol-function 'w32-notification-close)
               (lambda (id) (push (list 'close id) events)))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (push (list 'cancel timer) events))))
      (should (= (zr-notify-send "title" "body" :replaces-id 7) 8))
      (should (equal (reverse events) '((cancel previous-timer) (close 7) notify)))
      (should-not (gethash 7 zr-notify--windows-timers)))))

(ert-deftest zr-notify-test-global-advice-before-notifications-load ()
  (with-temp-buffer
    (let* ((root (file-name-directory (locate-library "zr-notify")))
           (form
            '(progn
               (require 'zr-notify)
               (when (or (featurep 'notifications) zr-notify-mode)
                 (error "Loading enabled global notifications"))
               (zr-notify-mode 1)
               (let ((features (remq 'dbusbind features)))
                 (require 'erc-desktop-notifications))
               (let ((zr-notify-function
                      (lambda (title body &rest _) (list title body))))
                 (unless (equal (notifications-notify :title "title" :body "body")
                                '("title" "body"))
                   (error "Advice was lost while loading notifications"))
                 (with-temp-buffer
                   (rename-buffer "#notify-test")
                   (cl-letf (((symbol-function 'erc-target)
                              (lambda () "#notify-test")))
                     (unless (equal (erc-notifications-notify "nick" "hello")
                                    '("nick in #notify-test" "hello"))
                       (error "ERC did not route through zr-notify")))))
               (zr-notify-mode -1)
               (when (advice-member-p #'zr-notify--notifications-notify
                                     'notifications-notify)
                 (error "Advice left installed"))))
           (status (call-process invocation-name nil t nil "--batch" "-Q"
                                 "-L" root "--eval" (prin1-to-string form))))
      (ert-info ((buffer-string))
        (should (eq status 0))))))

(provide 'zr-notify-test)
;;; zr-notify-test.el ends here
