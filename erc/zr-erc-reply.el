;;; zr-erc-reply.el --- IRCv3 replies for ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;; Keywords: comm

;;; Commentary:

;; (require 'zr-erc-reply)
;; (add-to-list 'erc-modules 'zr-reply)
;; (erc-update-modules)
;;
;; Or use M-x erc-zr-reply-mode, including on existing connections.
;; Put point on a message and use M-x zr-erc-reply to enter a reply in
;; the minibuffer.  Input is literal text, including a leading slash.
;; Reply annotations are buttons: RET or mouse-2 visits the original
;; message.  M-x zr-erc-reply-jump also works anywhere in a reply.
;; The sender and a short excerpt are visible without following the button:
;;   <alice> When shall we meet?
;;   [↪ alice: When shall we meet?] <bob> At ten.
;; No keys are installed in `erc-mode-map'.
;;
;; Implements https://ircv3.net/specs/client-tags/reply using +reply and
;; server-provided msgid tags.  Capability discovery runs after login,
;; independently of ERC's SASL handshake.  With echo-message, outgoing
;; messages are displayed when echoed by the server, so they too have
;; IDs.  Without it, incoming messages can still be replied to.
;; References resolve only in the current conversation's retained text;
;; missing or truncated originals are shown by ID.  No history is fetched.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'text-property-search)
(require 'erc)
(require 'erc-common)
(require 'zr-erc-common)

(defgroup zr-erc-reply nil
  "IRCv3 replies for ERC."
  :group 'erc
  :prefix "zr-erc-reply-")

(defvar erc-zr-reply-mode)
(defvar erc-message-parsed nil)
(defvar erc-server-CAP-functions nil)
(defvar zr-erc-reply--cap-hook nil)
(defvar zr-erc-reply--installed nil)
(defvar zr-erc-reply--outgoing nil
  "Dynamically bound (TARGET . MSGID) while sending a reply.")
(defvar-local zr-erc-reply--caps nil)
(defvar-local zr-erc-reply--pending nil)
(defvar-local zr-erc-reply--offered nil)

(defun zr-erc-reply--escape (value)
  "Encode VALUE for an IRCv3 tag."
  (replace-regexp-in-string
   "[; \\\\\r\n]"
   (lambda (s)
     (pcase s
       (";" "\\:") (" " "\\s") ("\r" "\\r") ("\n" "\\n")
       (_ "\\\\")))
   value t t))

(defun zr-erc-reply--parse-tags (original string)
  "Provide ERC's modern tag representation for STRING.
Honor an explicit legacy format by calling ORIGINAL."
  (if (eq erc-tags-format 'legacy)
      (funcall original string)
    (mapcar (lambda (pair) (cons (intern (car pair)) (cdr pair)))
            (zr-erc-parse-tags string))))

(defun zr-erc-reply--cap-p (name)
  "Return non-nil if NAME is acknowledged on this connection."
  (erc-with-server-buffer (member name zr-erc-reply--caps)))

(defun zr-erc-reply--servers ()
  "Return live ERC server buffers."
  (erc-buffer-list
   (lambda ()
     (and (eq (current-buffer) (erc-server-buffer))
          (erc-server-process-alive)))))

(defun zr-erc-reply--request (cap)
  "Request CAP once in the current server buffer."
  (unless (member cap zr-erc-reply--pending)
    (push cap zr-erc-reply--pending)
    (erc-server-send (concat "CAP REQ :" cap) t)))

(defun zr-erc-reply--negotiate (&rest _)
  "Discover capabilities after registration, without holding up SASL."
  (when erc-zr-reply-mode
    (setq zr-erc-reply--offered nil)
    (erc-server-send "CAP LS 302" t)))

(defun zr-erc-reply--request-offered ()
  "Request advertised reply capabilities in dependency order."
  (dolist (cap '("message-tags" "echo-message"))
    (when (and (member cap zr-erc-reply--offered)
               (not (member cap zr-erc-reply--caps))
               (or (equal cap "message-tags")
                   (member "message-tags" zr-erc-reply--caps)))
      (zr-erc-reply--request cap))))

(defun zr-erc-reply--release ()
  "Release capabilities acquired by this module on this connection."
  (dolist (cap '("echo-message" "message-tags"))
    (when (or (member cap zr-erc-reply--caps)
              (member cap zr-erc-reply--pending))
      (zr-erc-reply--request (concat "-" cap)))))

(defun zr-erc-reply--cap (_process parsed)
  "Observe CAP replies in PARSED without consuming other modules' hooks."
  (let* ((args (erc-response.command-args parsed))
         (subcommand (nth 1 args))
         (caps (split-string (erc-response.contents parsed) " " t)))
    (pcase subcommand
      ((or "LS" "NEW")
       (when erc-zr-reply-mode
         (dolist (cap caps)
           (cl-pushnew (car (split-string cap "=")) zr-erc-reply--offered
                       :test #'equal))
         (unless (equal (nth 2 args) "*")
           (zr-erc-reply--request-offered))))
      ((or "ACK" "NAK" "DEL")
       (dolist (cap caps)
         (let* ((remove (or (equal subcommand "DEL")
                            (string-prefix-p "-" cap)))
                (name (car (split-string (string-remove-prefix "-" cap)
                                         "="))))
           (when (member name '("message-tags" "echo-message"))
             (setq zr-erc-reply--pending
                   (delete cap zr-erc-reply--pending))
             (cond
              ((equal subcommand "NAK") nil)
              (remove
               (setq zr-erc-reply--caps (delete name zr-erc-reply--caps))
               (when (equal subcommand "DEL")
                 (setq zr-erc-reply--offered
                       (delete name zr-erc-reply--offered))))
              (t (cl-pushnew name zr-erc-reply--caps :test #'equal))))))
       (if erc-zr-reply-mode
           (when (and (equal subcommand "ACK") (member "message-tags" caps))
             (zr-erc-reply--request-offered))
         (when (equal subcommand "ACK") (zr-erc-reply--release))
         (zr-erc-reply--maybe-uninstall)))))
  nil)

(defun zr-erc-reply--reset (&rest _)
  "Discard capability state for a closed or newly opened connection."
  (setq zr-erc-reply--caps nil
        zr-erc-reply--pending nil
        zr-erc-reply--offered nil)
  (zr-erc-reply--maybe-uninstall))

(defun zr-erc-reply--local-display (original &rest args)
  "Call local message display ORIGINAL with ARGS unless an echo is due."
  (unless (zr-erc-reply--cap-p "echo-message")
    (apply original args)))

(defun zr-erc-reply--display-message (original parsed type buffer msg &rest args)
  "Suppress locally rendered chat MSG when PARSED will arrive as an echo.
Pass TYPE, BUFFER and ARGS through to ORIGINAL for other messages."
  (unless (and (null parsed)
               (memq msg '(input-chan-privmsg input-query-privmsg
                          input-chan-notice input-query-notice statusmsg-input))
               (zr-erc-reply--cap-p "echo-message"))
    (apply original parsed type buffer msg args)))

(defun zr-erc-reply--send (original string &optional force target)
  "Add the selected reply tag to a matching outgoing STRING.
Pass FORCE and TARGET to ORIGINAL without bypassing ERC's send queue."
  (when (and zr-erc-reply--outgoing
             (string-match "\\`\\(@[^ ]+ \\)?PRIVMSG \\([^ ]+\\) :" string)
             (equal (erc-downcase (match-string 2 string))
                    (erc-downcase (car zr-erc-reply--outgoing))))
    (unless (zr-erc-reply--cap-p "message-tags")
      (user-error "This server has not acknowledged message-tags"))
    (let ((tag (concat "+reply=" (zr-erc-reply--escape
                                 (cdr zr-erc-reply--outgoing)))))
      (setq string (if (string-prefix-p "@" string)
                       (concat "@" tag ";" (substring string 1))
                     (concat "@" tag " " string)))))
  (funcall original string force target))

(defun zr-erc-reply--find (id)
  "Find ID in the current conversation, even outside a narrowed region."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (when-let* ((match (or (text-property-search-forward
                             'zr-erc-reply-msgid id t)
                            (text-property-search-forward
                             'zr-erc-reply-ids id #'member))))
        (prop-match-beginning match)))))

(defun zr-erc-reply--summary (parsed)
  "Return a short, single-line, control-free summary of PARSED."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[[:cntrl:]]" " "
    (concat (car (erc-parse-user (erc-response.sender parsed))) ": "
            (erc-response.contents parsed)))
   72 nil nil "…"))

(defun zr-erc-reply--visit (id)
  "Visit ID in this buffer or explain why it cannot be found."
  (if-let* ((pos (zr-erc-reply--find id)))
      (progn (push-mark) (widen) (goto-char pos))
    (user-error "Original message is no longer in this buffer: %s" id)))

(defun zr-erc-reply--button (button)
  "Visit the original message referred to by BUTTON."
  (zr-erc-reply--visit (button-get button 'zr-erc-reply-parent)))

(defun zr-erc-reply--annotate (parent)
  "Insert a reply button for PARENT in the narrowed message."
  (let* ((pos (zr-erc-reply--find parent))
         (summary (and pos (save-restriction
                             (widen)
                             (get-text-property pos 'zr-erc-reply-summary)))))
    (goto-char (point-min))
    (insert-text-button
     (concat "[↪ "
             (or summary
                 (concat "Original unavailable: "
                         (truncate-string-to-width
                          (replace-regexp-in-string "[[:cntrl:]]" " " parent)
                          40 nil nil "…")))
             "]")
     'action #'zr-erc-reply--button 'follow-link t
     'zr-erc-reply-parent parent
     'help-echo "Visit the original message in this conversation")
    (insert " ")))

(defun zr-erc-reply--insert ()
  "Annotate incoming replies before ERC fills the narrowed message."
  (when (and erc-zr-reply-mode (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed)
                     '("PRIVMSG" "NOTICE")))
    (when-let* ((parent (cdr (assoc "+reply" (zr-erc-message-tags
                                             erc-message-parsed)))))
      (save-excursion (zr-erc-reply--annotate parent)))))

(defun zr-erc-reply--remember ()
  "Retain reply metadata after formatting, even when ERC discards PARSED."
  (when (and erc-zr-reply-mode (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed)
                     '("PRIVMSG" "NOTICE")))
    (let ((tags (zr-erc-message-tags erc-message-parsed)))
      (add-text-properties
       (point-min) (point-max)
       (list 'zr-erc-reply-msgid (cdr (assoc "msgid" tags))
             'zr-erc-reply-ids (zr-erc-message-ids erc-message-parsed)
             'zr-erc-reply-parent (cdr (assoc "+reply" tags))
             'zr-erc-reply-summary (zr-erc-reply--summary erc-message-parsed)
             'rear-nonsticky t)))))

(defun zr-erc-reply--outgoing-insert ()
  "Annotate a locally displayed reply when echo-message is unavailable."
  (when zr-erc-reply--outgoing
    (save-excursion (zr-erc-reply--annotate (cdr zr-erc-reply--outgoing)))
    (put-text-property (point-min) (point-max) 'zr-erc-reply-parent
                       (cdr zr-erc-reply--outgoing))))

;;;###autoload
(defun zr-erc-reply (text)
  "Reply with literal TEXT to the message at point.
Interactively, read TEXT in the minibuffer.  Each line (including lines
split by ERC's length limit) references the same original message."
  (interactive
   (progn
     (zr-erc-reply--check)
     (list (read-string (format "Reply to %s: "
                                (get-text-property (point)
                                                   'zr-erc-reply-summary))))))
  (zr-erc-reply--check)
  (when (string-blank-p text) (user-error "Reply is empty"))
  (let ((zr-erc-reply--outgoing
         (cons (erc-default-target)
               (get-text-property (point) 'zr-erc-reply-msgid)))
        ;; A reply body is text, never an ERC slash command.
        (erc-command-regexp "\\`\\b\\B")
        (inhibit-read-only t))
    (erc-send-input text)))

(defun zr-erc-reply--check ()
  "Check that point and this connection allow replying."
  (unless (and erc-zr-reply-mode (derived-mode-p 'erc-mode))
    (user-error "Enable erc-zr-reply-mode in ERC first"))
  (unless (and (erc-server-process-alive) (erc-default-target))
    (user-error "Reply requires a connected conversation buffer"))
  (unless (zr-erc-reply--cap-p "message-tags")
    (user-error "This server has not acknowledged message-tags"))
  (unless (and (< (point) erc-insert-marker)
               (get-text-property (point) 'zr-erc-reply-msgid))
    (user-error "No server message ID at point")))

;;;###autoload
(defun zr-erc-reply-jump ()
  "Jump from the reply at point to its original message."
  (interactive)
  (if-let* ((id (get-text-property (point) 'zr-erc-reply-parent)))
      (zr-erc-reply--visit id)
    (user-error "No reply at point")))

(defconst zr-erc-reply--advices
  '((erc--parse-message-tags . zr-erc-reply--parse-tags)
    (erc-server-send . zr-erc-reply--send)
    (erc-display-msg . zr-erc-reply--local-display)
    (erc--send-action-display . zr-erc-reply--local-display)
    (erc-display-message . zr-erc-reply--display-message)))

(defconst zr-erc-reply--hooks
  '((erc-after-connect zr-erc-reply--negotiate 0)
    (erc--server-post-connect-hook zr-erc-reply--reset 0)
    (erc-disconnected-hook zr-erc-reply--reset 0)
    (erc-insert-modify-hook zr-erc-reply--insert -90)
    (erc-insert-post-hook zr-erc-reply--remember 90)
    (erc-send-modify-hook zr-erc-reply--outgoing-insert -90)))

(defun zr-erc-reply--install ()
  "Install transport and display integration exactly once."
  (unless zr-erc-reply--installed
    (setq zr-erc-reply--installed t
          zr-erc-reply--cap-hook (or (erc-get-hook "CAP")
                                     'erc-server-CAP-functions))
    (puthash "CAP" zr-erc-reply--cap-hook erc-server-responses)
    (add-hook zr-erc-reply--cap-hook #'zr-erc-reply--cap)
    (pcase-dolist (`(,hook ,function ,depth) zr-erc-reply--hooks)
      (add-hook hook function depth))
    (pcase-dolist (`(,function . ,advice) zr-erc-reply--advices)
      (advice-add function :around advice))))

(defun zr-erc-reply--maybe-uninstall ()
  "Remove integration after capability shutdown has completed.
Keep echo suppression until the server acknowledges shutdown, so
in-flight echoes cannot create duplicate messages when disabling."
  (when (and zr-erc-reply--installed (not erc-zr-reply-mode)
             (not (cl-some
                   (lambda (buffer)
                     (with-current-buffer buffer
                       (or zr-erc-reply--caps zr-erc-reply--pending)))
                   (zr-erc-reply--servers))))
    (remove-hook zr-erc-reply--cap-hook #'zr-erc-reply--cap)
    (when (and (eq zr-erc-reply--cap-hook 'erc-server-CAP-functions)
               (null erc-server-CAP-functions))
      (remhash "CAP" erc-server-responses))
    (pcase-dolist (`(,hook ,function ,_depth) zr-erc-reply--hooks)
      (remove-hook hook function))
    (pcase-dolist (`(,function . ,advice) zr-erc-reply--advices)
      (advice-remove function advice))
    (setq zr-erc-reply--installed nil)))

;;;###autoload (autoload 'erc-zr-reply-mode "zr-erc-reply" nil t)
(define-erc-module zr-reply nil
  "Send IRCv3 replies and navigate their original messages."
  ((zr-erc-reply--install)
   (dolist (buffer (zr-erc-reply--servers))
     (with-current-buffer buffer
       (when erc-server-connected (zr-erc-reply--negotiate)))))
  ((dolist (buffer (zr-erc-reply--servers))
     (with-current-buffer buffer (zr-erc-reply--release)))
   (zr-erc-reply--maybe-uninstall)))

(provide 'zr-erc-reply)
;;; zr-erc-reply.el ends here
