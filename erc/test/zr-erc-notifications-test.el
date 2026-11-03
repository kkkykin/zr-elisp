;;; zr-erc-notifications-test.el --- ERC notification tests -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'erc-fill)
(require 'zr-erc-notifications)
(require 'zr-notify)

(defmacro zr-erc-notifications-test--with-module (&rest body)
  "Enable the module for BODY, retaining ERC's existing skip predicates."
  (declare (indent 0) (debug t))
  `(let ((erc-modules nil)
         (erc-desktop-notifications-skip-predicates
          (copy-sequence erc-desktop-notifications-skip-predicates)))
     (unwind-protect
         (progn (erc-zr-notifications-mode 1) ,@body)
       (erc-zr-notifications-mode -1))))

(defmacro zr-erc-notifications-test--with-conversation (target &rest body)
  "Run BODY with a real offline ERC insertion pipeline for TARGET."
  (declare (indent 1) (debug t))
  `(let ((erc-modules nil)
         (erc-fill-mode t)
         (erc--fill-wrap-scrolltobottom-exempt-p t)
         (erc-fill-wrap-merge nil)
         (erc-insert-modify-hook '(erc-match-message erc-fill))
         (erc-insert-post-hook nil)
         (erc-text-matched-hook '(erc-notifications-notify-on-match))
         (erc-match-functions
          (append (default-value 'erc-match-functions)
                  '(erc-desktop-notifications-match-query))))
     (with-temp-buffer
       (erc-mode)
       (setq erc-server-current-nick "me"
             erc-session-server "irc.example"
             erc--target (erc--target-from-string ,target))
       (setq erc-default-recipients (list (erc-target)))
       (erc--initialize-markers nil nil)
       (erc-fill-wrap-mode 1)
       ,@body)))

(defun zr-erc-notifications-test--response (sender body &optional tags command)
  "Create a parsed message from SENDER with BODY, TAGS and COMMAND."
  (let ((command (or command "PRIVMSG"))
        (target (if (erc-query-buffer-p) "me" (or (erc-target) "#c"))))
    (make-erc-response
     :sender sender :command command :command-args (list target body)
     :contents body
     :unparsed (concat (and tags (concat "@" tags " "))
                       ":" sender " " command " " target " :" body))))

(defun zr-erc-notifications-test--insert (nick body &optional tags)
  "Insert a PRIVMSG from NICK with BODY and raw TAGS through ERC."
  (let* ((parsed (zr-erc-notifications-test--response
                  (concat nick "!u@h") body tags))
         (erc--parsed-response parsed)
         (erc--msg-prop-overrides
          `((erc--msg . PRIVMSG) (erc--spkr . ,nick)
            (erc--pfx . erc--pfx-skip-spkr-fwd)))
         (start (marker-position erc-insert-marker)))
    (erc-display-message
     parsed nil (current-buffer)
     (concat "<" (propertize nick 'erc--speaker nick) "> " body))
    ;; Notification handling must let the later fill hook finish insertion.
    (should (get-text-property start 'line-prefix))
    (should (equal (get-text-property start 'wrap-prefix)
                   '(space :width erc-fill--wrap-value)))))

(ert-deftest zr-erc-notifications-module-lifecycle ()
  "Loading is inert; enabling twice preserves native predicates and hooks."
  (should-not erc-zr-notifications-mode)
  (should-not erc-notifications-mode)
  (should-not erc-match-mode)
  (let ((erc-modules nil)
        (erc-desktop-notifications-skip-predicates '(ignore))
        (insert-hook erc-insert-modify-hook)
        (match-hook erc-text-matched-hook)
        (notifications (symbol-function 'notifications-notify))
        (android (symbol-function 'android-notifications-notify)))
    (unwind-protect
        (progn
          (erc-zr-notifications-mode 1)
          (erc-zr-notifications-mode 1)
          (should (memq 'zr-notifications erc-modules))
          (should (memq #'ignore erc-desktop-notifications-skip-predicates))
          (should (= (cl-count #'zr-erc-notifications--skip-p
                               erc-desktop-notifications-skip-predicates) 1))
          (pcase-dolist (`(,function ,_where ,advice) zr-erc-notifications--advices)
            (should (advice-member-p advice function)))
          (should (eq (symbol-function 'notifications-notify) notifications))
          (should (eq (symbol-function 'android-notifications-notify) android))
          (erc-zr-notifications-mode -1)
          (erc-zr-notifications-mode -1)
          (should (equal erc-desktop-notifications-skip-predicates '(ignore)))
          (pcase-dolist (`(,function ,_where ,advice) zr-erc-notifications--advices)
            (should-not (advice-member-p advice function)))
          (should (equal erc-insert-modify-hook insert-hook))
          (should (equal erc-text-matched-hook match-hook))
          (should (eq (symbol-function 'notifications-notify) notifications))
          (should (eq (symbol-function 'android-notifications-notify) android)))
      (erc-zr-notifications-mode -1))))

(ert-deftest zr-erc-notifications-relay-sender-recognition ()
  "Accept tagged Unicode and slash NUHs without changing nickname validation."
  (zr-erc-notifications-test--with-module
    (dolist (tag '("draft/relaymsg=bot" "relaymsg=bot"))
      (dolist (command '("PRIVMSG" "NOTICE"))
        (dolist (sender '("aaaa-123/onebot!u@h" "张三-123/onebot!u@h"))
          (should (equal (erc-get-parsed-vector-nick
                          (zr-erc-notifications-test--response sender "hi" tag command))
                         sender)))))
    (should-not (erc-is-valid-nick-p "张三-123/onebot"))
    (dolist (sender '("server.example" "bad/relay!u" "bad/relay!u@"
                      "bad name/relay!u@h" "bad/relay!u@h\n"))
      (should-not (erc-get-parsed-vector-nick
                   (zr-erc-notifications-test--response sender "hi" "draft/relaymsg=bot"))))
    (should-not (erc-get-parsed-vector-nick
                 (zr-erc-notifications-test--response "张三/onebot!u@h" "hi")))
    (should-not (erc-get-parsed-vector-nick
                 (zr-erc-notifications-test--response
                  "张三/onebot!u@h" "hi" "draft/relaymsg=bot" "JOIN")))
    (should (equal (erc-get-parsed-vector-nick
                    (zr-erc-notifications-test--response "other!u@h" "hi"))
                   "other!u@h"))))

(ert-deftest zr-erc-notifications-mentions-and-self-echoes ()
  "Real mentions notify, self echoes and ordinary messages do not."
  (let (sent)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options) (push options sent) 7)))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "#c"
          (dolist (sample '(("me" "hello" nil)
                            ("ME" "me: hello" nil)
                            ("other" "hello" nil)
                            ("张三/onebot" "hello" "draft/relaymsg=bot")
                            ("张三/onebot" "me: hello" nil)))
            (apply #'zr-erc-notifications-test--insert sample)
            (should-not sent))
          (dolist (sample '(("other" "me: hello" nil)
                            ("aaaa-123/onebot" "me: 你好" "draft/relaymsg=bot")
                            ("张三-123/onebot" "me: 你好" "relaymsg=bot")))
            (apply #'zr-erc-notifications-test--insert sample)
            (should (string-match-p (regexp-quote (car sample))
                                    (plist-get (car sent) :title))))
          (should (= (length sent) 3)))))))

(ert-deftest zr-erc-notifications-queries-and-native-filtering ()
  "Relay private messages notify; native skip predicates still suppress them."
  (let (sent)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options) (push options sent) 7)))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "张三/onebot"
          (zr-erc-notifications-test--insert "张三/onebot" "hello" "draft/relaymsg=bot")
          (should (= (length sent) 1))
          (zr-erc-notifications-test--insert "me" "hello")
          (should (= (length sent) 1))
          (add-hook 'erc-desktop-notifications-skip-predicates (lambda (_) t))
          (zr-erc-notifications-test--insert "张三/onebot" "hello" "draft/relaymsg=bot")
          (should (= (length sent) 1)))))))

(ert-deftest zr-erc-notifications-rule-context-and-overrides ()
  "Channel, sender, network, server, body, rendered text and tags can combine."
  (zr-erc-notifications-test--with-conversation "#catcat"
    (let ((erc--parsed-response
           (zr-erc-notifications-test--response
            "张三-123/onebot!u@h" "me: 原文" "draft/relaymsg=bot;+kind=urgent"))
          (zr-erc-notifications-rules
           '((:urgency low :group "General" :replaces-id 30)
             (:selector (:target "^#catcat$" :sender "^张三-123/onebot$"
                         :network "^TestNet$" :server "^irc\\.example$"
                         :body "原文" :text "显示内容"
                         :tags (("relaymsg") ("+kind" . "^urgent$")))
              :urgency critical :group "Important" :replaces-id 42)
             (:selector (:sender "^other$") :notify nil))))
      (cl-letf (((symbol-function 'erc-network) (lambda () 'TestNet)))
        (let ((settings (zr-erc-notifications--settings "Displayed name" "显示内容")))
          (should (plist-get settings :notify))
          (should (eq (plist-get settings :urgency) 'critical))
          (should (equal (plist-get settings :group) "Important"))
          (should (= (plist-get settings :replaces-id) 42))
          (should (eq (plist-get (zr-erc-notifications--settings "Displayed name" "other")
                                 :urgency)
                      'low))
          (let ((zr-erc-notifications-rules nil))
            (should (equal (plist-get (zr-erc-notifications--settings "other" "hi") :group)
                           "ERC TestNet #catcat (normal)"))))))))

(ert-deftest zr-erc-notifications-rule-break-and-explicit-nil ()
  (zr-erc-notifications-test--with-conversation "#c"
    (let ((zr-erc-notifications-rules
           '((:notify nil :urgency critical :group "First" :replaces-id 42)
             (:selector (:target "^#other$") :break t)
             (:selector (:target "^#c$") :notify t :urgency nil :group nil
              :replaces-id nil :break t)
             (:notify nil :urgency low))))
      (let ((settings (zr-erc-notifications--settings "other" "hi")))
        (should (plist-get settings :notify))
        (should (eq (plist-get settings :urgency) 'normal))
        (should (equal (plist-get settings :group) "ERC irc.example #c (normal)"))
        (should (plist-member settings :replaces-id))
        (should-not (plist-get settings :replaces-id))))))

(ert-deftest zr-erc-notifications-rule-suppression ()
  (let ((zr-erc-notifications-rules
         '((:selector (:sender "/onebot$" :target "^#c$") :notify nil)))
        sent)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options) (push options sent) 7)))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "#c"
          (zr-erc-notifications-test--insert "张三/onebot" "me: hi" "draft/relaymsg=bot")
          (should-not sent)
          (zr-erc-notifications-test--insert "other" "me: hi")
          (should (= (length sent) 1))
          (setq-local zr-erc-notifications-rules '((:notify nil)))
          (erc-notifications-notify "other" "hi")
          (should (= (length sent) 1)))))))

(ert-deftest zr-erc-notifications-urgency-and-routing-order ()
  "Rules reach desktop and routed backends regardless of mode enable order."
  (dolist (routing-first '(nil t))
    (let ((erc-modules nil)
          (zr-erc-notifications-rules '((:urgency critical)))
          (zr-notify-function (lambda (&rest args) args))
          routed)
      (cl-letf (((symbol-function 'notifications-notify)
                 (lambda (&rest options) (setq routed options) 7)))
        (unwind-protect
            (progn
              (funcall (if routing-first #'zr-notify-mode #'erc-zr-notifications-mode) 1)
              (funcall (if routing-first #'erc-zr-notifications-mode #'zr-notify-mode) 1)
              (let ((zr-notify-function
                     (lambda (_title _body &rest options) (setq routed options) 7)))
                (zr-erc-notifications-test--with-conversation "#c"
                  (erc-notifications-notify "other" "me: hi")
                  (should (eq (plist-get routed :urgency) 'critical))))
              (zr-notify-mode -1)
              (zr-erc-notifications-test--with-conversation "#c"
                (erc-notifications-notify "other" "me: hi")
                (should (eq (plist-get routed :urgency) 'critical))))
          (erc-zr-notifications-mode -1)
          (zr-notify-mode -1))))))

(ert-deftest zr-erc-notifications-android-direct-and-routed ()
  "Android gets conversation groups through either ERC's direct or routed API."
  (dolist (direct '(nil t))
    (let ((system-type 'android)
          (zr-notify-function nil)
          (zr-erc-notifications-rules '((:urgency critical)))
          seen)
      (cl-letf (((symbol-value 'features)
                 (if direct (cons 'android features) (remq 'android features)))
                ((symbol-function 'android-notifications-notify)
                 (lambda (&rest options) (setq seen options) 7)))
        (zr-erc-notifications-test--with-module
          (unwind-protect
              (progn
                (unless direct (zr-notify-mode 1))
                (zr-erc-notifications-test--with-conversation "#c"
                  (erc-notifications-notify "other" "hi")
                  (should (eq (plist-get seen :urgency) 'critical))
                  (should (equal (plist-get seen :group) "ERC irc.example #c (critical)"))
                  (setq-local zr-erc-notifications-rules
                              '((:urgency low :group "Quiet IRC")))
                  (erc-notifications-notify "other" "hi")
                  (should (eq (plist-get seen :urgency) 'low))
                  (should (equal (plist-get seen :group) "Quiet IRC")))
                (android-notifications-notify :title "Other" :body "App"
                                              :urgency 'normal :group "Other")
                (should (equal seen '(:title "Other" :body "App"
                                     :urgency normal :group "Other"))))
            (zr-notify-mode -1)))))))

(ert-deftest zr-erc-notifications-backend-bindings-restored-on-error ()
  "Temporary bindings restore defined and undefined backends after an error."
  (dolist (native '(nil t))
    (let* ((zr-erc-notifications-rules '((:urgency critical :group "ERC alerts")))
           seen
           (notifications (lambda (&rest options) (push options seen) 7))
           (android (and native (lambda (&rest options) (push options seen) 8))))
      (cl-letf (((symbol-function 'notifications-notify) notifications)
                ((symbol-function 'android-notifications-notify) android))
        (zr-erc-notifications-test--with-module
          (should-error
           (zr-erc-notifications--notify
            (lambda (&rest _)
              (notifications-notify :title "ERC" :body "desktop")
              (when native
                (android-notifications-notify :title "ERC" :body "Android"))
              (error "Sending failed"))
            "other" "hello")
           :type 'error)
          (should (eq (symbol-function 'notifications-notify) notifications))
          (should (eq (symbol-function 'android-notifications-notify) android))
          (should (cl-every (lambda (options)
                              (eq (plist-get options :urgency) 'critical))
                            seen))
          (when native
            (should (equal (plist-get (car seen) :group) "ERC alerts")))
          (notifications-notify :title "Other" :body "App")
          (should (equal (car seen) '(:title "Other" :body "App"))))))))

(ert-deftest zr-erc-notifications-android-unavailable-keeps-termux-fallback ()
  "Temporarily binding backends must not make an absent native API available."
  (let ((system-type 'android)
        (zr-notify-function nil)
        (zr-erc-notifications-rules '((:urgency critical)))
        seen)
    (cl-letf (((symbol-value 'features) (remq 'android features))
              ((symbol-function 'android-notifications-notify) nil)
              ((symbol-function 'zr-termux-notify)
               (lambda (&rest args) (setq seen args) "termux-id")))
      (zr-erc-notifications-test--with-module
        (unwind-protect
            (progn
              (zr-notify-mode 1)
              (zr-erc-notifications-test--with-conversation "#c"
                (erc-notifications-notify "other" "hello")
                (should (eq (plist-get (cddr seen) :urgency) 'critical))
                (should-not (plist-member (cddr seen) :actions))
                (should (equal zr-erc-notifications--last-id "termux-id"))
                (should-not (fboundp 'android-notifications-notify))))
          (zr-notify-mode -1))))))

(ert-deftest zr-erc-notifications-nested-sends-use-inner-settings ()
  "A notification arriving during another send uses its own conversation rules."
  (let ((zr-erc-notifications-rules
         '((:urgency critical)
           (:selector (:target "^#inner$") :urgency low)))
        (next-id 0)
        seen)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options)
                 (push options seen)
                 (when (equal (plist-get options :body) "outer")
                   (zr-erc-notifications-test--with-conversation "#inner"
                     (erc-notifications-notify "other" "inner")))
                 (cl-incf next-id))))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "#outer"
          (erc-notifications-notify "other" "outer")
          (should (equal (mapcar (lambda (options) (plist-get options :urgency))
                                (reverse seen))
                         '(critical low))))))))

(ert-deftest zr-erc-notifications-replacement-per-conversation ()
  "Channels retain separate IDs; native ERC's global ID is left alone."
  (let ((erc-notifications-last-notification 900)
        (next-id 0)
        replacements)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options)
                 (push (plist-get options :replaces-id) replacements)
                 (cl-incf next-id))))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "#one"
          (erc-notifications-notify "other" "first")
          (should (= zr-erc-notifications--last-id 1))
          (zr-erc-notifications-test--with-conversation "#two"
            (erc-notifications-notify "other" "first")
            (erc-notifications-notify "other" "second")
            (should (= zr-erc-notifications--last-id 3)))
          (erc-notifications-notify "another" "second")
          (should (= zr-erc-notifications--last-id 4)))
        (should (equal (reverse replacements) '(nil nil 2 1)))
        (should (= erc-notifications-last-notification 900))))))

(ert-deftest zr-erc-notifications-custom-replacement-preserves-default ()
  "An explicit nil or ID bypasses and preserves the default conversation ID."
  (let ((next-id 0) replacements)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options)
                 (push (plist-get options :replaces-id) replacements)
                 (cl-incf next-id))))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "#c"
          (erc-notifications-notify "other" "first")
          (dolist (custom '(42 nil))
            (let ((zr-erc-notifications-rules (list (list :replaces-id custom))))
              (erc-notifications-notify "other" "custom")
              (should (= zr-erc-notifications--last-id 1))))
          (erc-notifications-notify "other" "default again")
          (should (= zr-erc-notifications--last-id 4))
          (should (equal (reverse replacements) '(nil 42 nil 1))))))))

(ert-deftest zr-erc-notifications-replacement-backend-results ()
  "String IDs work; boolean OSC success and backend failure are not cached."
  (let ((results '(t nil "termux-id" t nil "termux-id")) replacements)
    (cl-letf (((symbol-function 'notifications-notify)
               (lambda (&rest options)
                 (push (plist-get options :replaces-id) replacements)
                 (pop results))))
      (zr-erc-notifications-test--with-module
        (zr-erc-notifications-test--with-conversation "#c"
          (dotimes (_ 6) (erc-notifications-notify "other" "hi"))
          (should (equal zr-erc-notifications--last-id "termux-id"))
          (should (equal (reverse replacements)
                         '(nil nil nil "termux-id" "termux-id" "termux-id"))))))))

(provide 'zr-erc-notifications-test)
;;; zr-erc-notifications-test.el ends here
