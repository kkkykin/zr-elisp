;;; zr-erc-display-name.el --- Local display names for ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Enable `erc-zr-display-name-mode' in a conversation to display extracted
;; names over IRC nicknames.  Overlays leave messages and identities intact.
;;; Code:
(require 'zr-erc-common)
(require 'button)

(defgroup zr-erc-display-name nil "Local ERC display names." :group 'erc)
(defcustom zr-erc-display-name-rules
  '((:source (:tag "+display-name")))
  "Ordered rules for extracting a local display name; first success wins.
Each rule supports :match (a `zr-erc-match-p' selector), :source (sender,
body, text, or (:tag TAG), default text), :regexp, and :group (default 1
with a regexp, otherwise 0).  Without :regexp use the entire source.
Names containing control characters or only whitespace are rejected.
Use text rules for history whose original metadata ERC has already removed.
By default recognize +display-name after `zr-erc-message-tag-receive-remap'.
Nil disables name replacement.  This option supports buffer-local values."
  :type 'sexp :group 'zr-erc-display-name)

(defun zr-erc-display-name--extract (context)
  "Extract the first valid display name from CONTEXT."
  (save-match-data
    (let ((case-fold-search nil))
      (cl-loop
       for rule in zr-erc-display-name-rules
       for source = (or (plist-get rule :source) 'text)
       for value = (if (consp source)
                       (cdr (assoc (cadr source) (plist-get context :tags)))
                     (plist-get context (intern (concat ":" (symbol-name source)))))
       when (and value (zr-erc-match-p (plist-get rule :match) context))
       thereis
       (let* ((regexp (plist-get rule :regexp))
              (name (if regexp
                        (when (string-match regexp value)
                          (match-string (or (plist-get rule :group) 1) value))
                      value)))
         (when (and name (not (string-blank-p name))
                    (not (string-match-p "[[:cntrl:]]" name)))
           (substring-no-properties name)))))))

(defun zr-erc-display-name--clear ()
  "Remove this module's overlays in the accessible region."
  (remove-overlays (point-min) (point-max) 'zr-erc-display-name t))

(defun zr-erc-display-name--overlay (start end context)
  "Display the name extracted from CONTEXT over START to END."
  (when-let* ((name (zr-erc-display-name--extract context)))
    (let ((overlay (make-overlay start end nil t nil)))
      (overlay-put overlay 'zr-erc-display-name t)
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'display name)
      (overlay-put overlay 'help-echo
                   (format "IRC nickname: %s" (plist-get context :sender))))))

(defun zr-erc-display-name--render-replies ()
  "Render reference nicknames using the quoted messages' original contexts."
  (let ((pos (point-min)))
    (while (< pos (point-max))
      (let ((context (get-text-property pos 'zr-erc-reply-speaker-context))
            (end (next-single-property-change
                  pos 'zr-erc-reply-speaker-context nil (point-max))))
        (when context
          (remove-overlays pos end 'zr-erc-display-name t)
          (zr-erc-display-name--overlay pos end context))
        (setq pos end)))))

(defun zr-erc-display-name--render (&optional context)
  "Render speaker names in the accessible region, using CONTEXT if supplied."
  (save-excursion
    (with-silent-modifications
      (zr-erc-display-name--clear)
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let* ((speaker (get-text-property pos 'erc--speaker))
                 (end (next-single-property-change
                       pos 'erc--speaker nil (point-max))))
            (when speaker
              (goto-char pos)
              (let* ((parsed (get-text-property pos 'erc-parsed))
                     (summary (get-text-property pos 'zr-erc-reply-summary))
                     (text (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))
                     (data (or context
                               (get-text-property pos 'zr-erc-display-name-context)
                               (and summary (> (length summary) 0)
                                    (get-text-property
                                     0 'zr-erc-reply-speaker-context summary))
                               (zr-erc-context parsed text))))
                (setq data (plist-put (copy-sequence data) :sender speaker))
                (when (or context parsed)
                  (put-text-property pos end 'zr-erc-display-name-context data))
                (zr-erc-display-name--overlay pos end data)))
            (setq pos end))))
      (zr-erc-display-name--render-replies))))

(defun zr-erc-display-name--insert ()
  "Render the narrowed incoming message after ERC formatting."
  (when (and (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed) '("PRIVMSG" "NOTICE")))
    (zr-erc-display-name--render
     (zr-erc-context erc-message-parsed
                     (buffer-substring-no-properties
                      (if-let* ((button (button-at (point-min)))
                                ((button-get button 'zr-erc-reply-parent)))
                          (min (point-max) (1+ (button-end button)))
                        (point-min))
                      (point-max))))))

;;;###autoload
(defun zr-erc-display-name-refresh ()
  "Refresh retained history after changing display-name rules."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (if (bound-and-true-p erc-zr-display-name-mode)
          (save-restriction
            (when (and (markerp erc-insert-marker) (marker-position erc-insert-marker))
              (narrow-to-region (point-min) erc-insert-marker))
            (zr-erc-display-name--render))
        (zr-erc-display-name--clear)))))

;;;###autoload (autoload 'erc-zr-display-name-mode "zr-erc-display-name" nil t)
(define-erc-module zr-display-name nil
  "Display extracted names in this buffer without changing IRC identities.
Enabling refreshes retained history; disabling restores original nicknames.
No reconnect or channel rejoin is needed."
  ((add-hook 'erc-insert-post-hook #'zr-erc-display-name--insert 85 t)
   (add-hook 'erc-send-post-hook #'zr-erc-display-name--render-replies 85 t)
   (zr-erc-display-name-refresh))
  ((remove-hook 'erc-insert-post-hook #'zr-erc-display-name--insert t)
   (remove-hook 'erc-send-post-hook #'zr-erc-display-name--render-replies t)
   (zr-erc-display-name-refresh))
  t)

(provide 'zr-erc-display-name)
;;; zr-erc-display-name.el ends here
