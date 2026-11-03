;;; zr-erc-notifications.el --- ERC relay notifications -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))

;;; Commentary:

;; Enable `erc-zr-notifications-mode' alongside ERC's `match' and
;; `notifications' modules.  Recognize IRCv3 relay senders with Unicode or
;; reserved separators, suppress notifications for our own echoed messages,
;; and configure notification settings with message selectors.
;; Android notifications use a stable group per network, target and urgency.
;; Loading this file does not enable any module.

;;; Code:

(require 'zr-erc-common)
(require 'erc-desktop-notifications)

(defgroup zr-erc-notifications nil
  "ERC notification settings and relay sender recognition."
  :group 'erc)

(defcustom zr-erc-notifications-rules nil
  "Ordered notification settings; later matching rules override earlier ones.
Each rule has an optional :selector understood by
`zr-erc-selector-match-p', :notify, :urgency (low, normal or critical),
:group, :replaces-id and :break.  Only explicitly present settings override
earlier ones.
Non-nil :break stops after a matching rule.
Selectors can match :target for channel or query names, :network, :server,
:sender, :body, :text and :tags.  Sender identities and bodies come from the
original message, before display replacements; :text is the formatted body.
Nil :selector matches every notification.  :notify defaults to t; nil
suppresses matching notifications.  Our own echoes are always suppressed.
Urgency defaults to normal.  Android's default group includes the network
or server, target and urgency.  An explicit :group overrides that name;
use one fixed urgency for each explicit group because Android retains
the group's importance in system settings.
By default each conversation buffer retains its own backend notification ID
for replacement.  An explicit :replaces-id overrides that ID for the rule;
nil requests a new notification each time.  Explicit replacements do not
change the conversation's default replacement ID.
This option supports buffer-local values."
  :type 'sexp
  :group 'zr-erc-notifications)

(defvar zr-erc-notifications--settings nil
  "Settings dynamically bound while sending an ERC notification.
Temporary backend wrappers read this binding so nested sends use their
own settings.")

(defvar-local zr-erc-notifications--last-id nil
  "Last backend notification ID for this conversation's default replacement.")

(defun zr-erc-notifications--parsed-nick (original parsed)
  "Recognize a relay sender in PARSED when ORIGINAL rejects its nickname."
  (or (funcall original parsed)
      (save-match-data
        (when-let* (((erc-response-p parsed))
                    ((member (erc-response.command parsed) '("PRIVMSG" "NOTICE")))
                    (tags (zr-erc-message-tags parsed))
                    ((assoc "relaymsg" tags))
                    (sender (erc-response.sender parsed))
                    ((stringp sender))
                    ((string-match-p
                      "\\`[^!@[:space:][:cntrl:]]+![^@[:space:][:cntrl:]]*@[^[:space:][:cntrl:]]+\\'"
                      sender)))
          ;; ERC's helper returns the entire nick!user@host prefix.
          sender))))

(defun zr-erc-notifications--settings (nick text)
  "Return notification settings for NICK and TEXT in this conversation."
  (let* ((context (zr-erc-context erc--parsed-response text))
         (context (plist-put context :sender (or (plist-get context :sender) nick)))
         (settings (list :notify t :urgency 'normal))
         (network (or (plist-get context :network) (plist-get context :server)))
         (target (or (plist-get context :target) (buffer-name)))
         stopped)
    (cl-loop for rule in zr-erc-notifications-rules
             until stopped
             when (zr-erc-selector-match-p (plist-get rule :selector) context)
             do (dolist (key '(:notify :urgency :group :replaces-id))
                  (when (plist-member rule key)
                    (setq settings (plist-put settings key (plist-get rule key)))))
             and do (setq stopped (plist-get rule :break)))
    (let ((urgency (or (plist-get settings :urgency) 'normal)))
      (setq settings (plist-put settings :urgency urgency))
      (plist-put settings :group
                 (or (plist-get settings :group)
                     (format "ERC %s%s (%s)"
                             (if network (concat network " ") "") target urgency))))))

(defun zr-erc-notifications--skip-p (match)
  "Suppress MATCH when its sender is us or its notification rules disable it."
  (or (when-let* ((nick (erc-match-nick match)))
        (erc-current-nick-p nick))
      (not (plist-get
            (zr-erc-notifications--settings
             (erc-match-nick match) (erc-match-get-message-body match))
            :notify))))

(defun zr-erc-notifications--notify (original &rest args)
  "Call ORIGINAL with ARGS using this conversation's notification settings."
  (let* ((zr-erc-notifications--settings
          (zr-erc-notifications--settings (car args) (cadr args)))
         (custom-id (plist-member zr-erc-notifications--settings :replaces-id))
         (erc-notifications-last-notification
          (if custom-id
              (plist-get zr-erc-notifications--settings :replaces-id)
            zr-erc-notifications--last-id)))
    (when (plist-get zr-erc-notifications--settings :notify)
      (let ((notifications (symbol-function 'notifications-notify))
            (android (symbol-function 'android-notifications-notify)))
        (cl-letf (((symbol-function 'notifications-notify)
                   (lambda (&rest options)
                     (apply notifications (zr-erc-notifications--arguments options))))
                  ((symbol-function 'android-notifications-notify)
                   ;; Keep the native function undefined on non-Android builds.
                   (and android
                        (lambda (&rest options)
                          (apply android (zr-erc-notifications--arguments options t))))))
          (prog1 (apply original args)
            ;; OSC returns t without an ID; failed backends can return nil.
            (when (and (not custom-id)
                       (or (integerp erc-notifications-last-notification)
                           (stringp erc-notifications-last-notification)))
              (setq zr-erc-notifications--last-id erc-notifications-last-notification))))))))

(defun zr-erc-notifications--arguments (options &optional android)
  "Apply the current ERC urgency to OPTIONS, and its group on ANDROID."
  (let ((options (plist-put (copy-sequence options) :urgency
                            (plist-get zr-erc-notifications--settings :urgency))))
    (if android
        (plist-put options :group (plist-get zr-erc-notifications--settings :group))
      options)))

(defconst zr-erc-notifications--advices
  '((erc-get-parsed-vector-nick :around zr-erc-notifications--parsed-nick)
    (erc-notifications-notify :around zr-erc-notifications--notify)))

;;;###autoload (autoload 'erc-zr-notifications-mode "zr-erc-notifications" nil t)
(define-erc-module zr-notifications nil
  "Recognize relay senders, suppress our own echoes and configure notifications.
Use alongside ERC's `match' and `notifications' modules.  Android groups
include the network, conversation and urgency unless overridden by a rule."
  ((add-hook 'erc-desktop-notifications-skip-predicates #'zr-erc-notifications--skip-p)
   (pcase-dolist (`(,function ,where ,advice) zr-erc-notifications--advices)
     (advice-add function where advice)))
  ((remove-hook 'erc-desktop-notifications-skip-predicates #'zr-erc-notifications--skip-p)
   (pcase-dolist (`(,function ,_where ,advice) zr-erc-notifications--advices)
     (advice-remove function advice))))

(provide 'zr-erc-notifications)
;;; zr-erc-notifications.el ends here
