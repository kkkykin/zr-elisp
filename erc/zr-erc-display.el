;;; zr-erc-display.el --- Local message display rules for ERC -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Enable `erc-zr-display-mode' to rename speakers or replace captured text.
;; Overlays leave messages and identities intact.
;;; Code:
(require 'zr-erc-common)
(require 'button)

(defgroup zr-erc-display nil "Local ERC message display." :group 'erc)
(defcustom zr-erc-display-rules nil
  "Ordered display rules; the first rule yielding a name or text replacements wins.
Each rule supports :match (a `zr-erc-match-p' selector), :source (sender,
body, text, or (:tag TAG), default text), and an optional :regexp.
:replace-sender and :replace-text are optional strings or functions.
Strings use `replace-match' backreferences, with case preserved.  Functions
receive the original context plus :source, :value and a :groups vector
(group 0 is the full match), and return a literal string or nil.
Nil leaves that part unchanged; an empty string hides it.  :replace-text
replaces the entire regexp match using its original source offsets.
Text changes require a verified correspondence with the displayed body or
message; they never locate a match by searching for the captured fragment.
Tag and sender sources support nickname replacement only.  Without :regexp,
the entire source is group 0.  Empty matches cannot replace text.
Nonempty sender replacements containing controls or only whitespace are
rejected.  Sender and text replacements work independently.
Use text rules for history whose original metadata ERC has already removed.
Tag sources use values after `zr-erc-message-tag-receive-remap'.
Nil disables display changes.  This option supports buffer-local values."
  :type 'sexp :group 'zr-erc-display)

(defun zr-erc-display--replacement (replacement context value)
  "Evaluate REPLACEMENT using CONTEXT and match data for VALUE."
  (save-match-data
    (let ((result (cond ((null replacement) nil)
                        ((stringp replacement)
                         (match-substitute-replacement replacement t nil value))
                        ((functionp replacement)
                         (funcall replacement (copy-tree context t)))
                        (t (error "Invalid display replacement: %S" replacement)))))
      (unless (or (null result) (stringp result))
        (error "Display replacement must return a string or nil: %S" result))
      (and result (substring-no-properties result)))))

(defun zr-erc-display--match (context)
  "Return a replacement plist with source offsets for the first effective rule."
  (save-match-data
    (let ((case-fold-search nil))
      (cl-loop
       for rule in zr-erc-display-rules
       for source = (or (plist-get rule :source) 'text)
       for value = (if (consp source)
                       (cdr (assoc (cadr source) (plist-get context :tags)))
                     (plist-get context (intern (concat ":" (symbol-name source)))))
       when (and value (zr-erc-match-p (plist-get rule :match) context))
       thereis
       (let ((regexp (plist-get rule :regexp)))
         (when (if regexp (string-match regexp value)
                 (set-match-data (list 0 (length value))) t)
           (let* ((groups (vconcat
                           (cl-loop for group below
                                    (max (/ (length (match-data)) 2)
                                         (if regexp (1+ (regexp-opt-depth regexp)) 1))
                                    collect (match-string-no-properties group value))))
                  (data (append (list :source source :value (substring-no-properties value)
                                      :groups groups)
                                context))
                  (begin (match-beginning 0))
                  (end (match-end 0))
                  (name (zr-erc-display--replacement
                         (plist-get rule :replace-sender) data value))
                  (text (zr-erc-display--replacement
                         (plist-get rule :replace-text) data value)))
             (setq name (and name
                             (or (string-empty-p name) (not (string-blank-p name)))
                             (not (string-match-p "[[:cntrl:]]" name)) name))
             (when (= begin end) (setq text nil))
             (when (or name text)
               (list :sender name :text text :source source :value value
                     :begin begin :end end)))))))))

(defun zr-erc-display--clear ()
  "Remove this module's overlays in the accessible region."
  (remove-overlays (point-min) (point-max) 'zr-erc-display t))

(defun zr-erc-display--overlay (start end text &optional sender)
  "Display TEXT over START to END, optionally identifying SENDER."
  (let ((overlay (make-overlay start end nil t nil)))
    (overlay-put overlay 'zr-erc-display t)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'display text)
    (when sender
      (overlay-put overlay 'help-echo (format "IRC nickname: %s" sender)))))

(defun zr-erc-display--content-end (text)
  "Return the end of TEXT before ERC's trailing newline, if present."
  (- (length text) (if (string-suffix-p "\n" text) 1 0)))

(defun zr-erc-display--body-range (result context)
  "Translate RESULT's source offsets to raw body offsets using CONTEXT.
Text matches can be translated only when the complete raw body is a suffix
of the original rendered message.  Other source types have no body range."
  (let ((body (plist-get context :body))
        (value (plist-get result :value))
        (begin (plist-get result :begin))
        (end (plist-get result :end)))
    (pcase (plist-get result :source)
      ('body (list value begin end))
      ('text
       (when body
         (let* ((content-end (zr-erc-display--content-end value))
                (offset (- content-end (length body))))
           (when (and (<= 0 offset begin end content-end)
                      (string= body (substring value offset content-end)))
             (list body (- begin offset) (- end offset)))))))))

(defun zr-erc-display--mapped-body (range transform)
  "Map (BODY BEGIN END) in RANGE through TRANSFORM without split controls."
  (pcase-let* ((`(,body ,begin ,end) range)
               (whole (funcall transform body))
               (prefix (funcall transform (substring body 0 begin)))
               (matched (funcall transform (substring body begin end)))
               (suffix (funcall transform (substring body end))))
    (when (and (not (string-empty-p matched))
               (string= whole (concat prefix matched suffix)))
      (list whole (length prefix) (+ (length prefix) (length matched))))))

(defun zr-erc-display--filled-regexp (text)
  "Quote TEXT, allowing ERC filling to change whitespace runs."
  (mapconcat (lambda (part)
               (if (string-match-p "\\`[ \t\n]+\\'" part)
                   "[ \t\n]+"
                 (regexp-quote part)))
             (let ((start 0) parts)
               (while (string-match "[ \t\n]+" text start)
                 (push (substring text start (match-beginning 0)) parts)
                 (push (match-string 0 text) parts)
                 (setq start (match-end 0)))
               (nreverse (cons (substring text start) parts)))
             ""))

(defun zr-erc-display--locate-filled (body begin end shown minimum)
  "Map BODY's BEGIN..END into SHOWN after MINIMUM, allowing filling.
Verify the complete body as a suffix.  Boundaries inside whitespace runs
are ambiguous after filling and are left unchanged."
  (save-match-data
    (unless (cl-some (lambda (pos)
                       (and (< 0 pos (length body))
                            (string-match-p "\\`[ \t\n]+\\'"
                                            (substring body (1- pos) (1+ pos)))))
                     (list begin end))
      (let* ((case-fold-search nil)
             (regexp (concat
                      (zr-erc-display--filled-regexp (substring body 0 begin))
                      "\\(" (zr-erc-display--filled-regexp (substring body begin end)) "\\)"
                      (zr-erc-display--filled-regexp (substring body end))
                      "\\'"))
             (content (substring shown 0 (zr-erc-display--content-end shown))))
        (when (string-match regexp content minimum)
          (cons (match-beginning 1) (match-end 1)))))))

(defun zr-erc-display--reference-text (text)
  "Apply the control-character conversion used in reply excerpts to TEXT."
  (replace-regexp-in-string "[[:cntrl:]]" " " text))

(defun zr-erc-display--body-display-text (start end)
  "Return message text in START..END without ERC's trailing timestamp.
Use the timestamp field, including its padding, rather than its appearance.
Keep the final newline so raw body offsets retain their usual meaning."
  (let* ((text (buffer-substring-no-properties start end))
         (content-end (+ start (zr-erc-display--content-end text))))
    (if (and (> content-end start)
             (eq (get-text-property (1- content-end) 'field) 'erc-timestamp))
        (concat (buffer-substring-no-properties
                 start (previous-single-property-change content-end 'field nil start))
                (buffer-substring-no-properties content-end end))
      text)))

(defun zr-erc-display--locate (result context start end sender-end reference)
  "Locate RESULT within START..END using its original offsets.
SENDER-END bounds body changes.  REFERENCE means the range is a reply body.
Require a whole-message correspondence, or a verified prefix for excerpts;
never search for a repeated match fragment."
  (let ((shown (if (and (not reference) (eq (plist-get result :source) 'body))
                   (zr-erc-display--body-display-text start end)
                 (buffer-substring-no-properties start end))))
    (if (and (not reference) (eq (plist-get result :source) 'text))
        (when (and (string= shown (plist-get result :value))
                   (<= sender-end (+ start (plist-get result :begin))))
          (cons (+ start (plist-get result :begin))
                (+ start (plist-get result :end))))
      (when-let* ((range (zr-erc-display--body-range result context)))
        (cl-loop
         for transform in (if reference '(zr-erc-display--reference-text)
                            '(identity erc-controls-strip))
         for mapped = (zr-erc-display--mapped-body range transform)
         when mapped thereis
         (pcase-let ((`(,body ,begin ,finish) mapped))
           (if reference
               (let ((visible (if (and (string-suffix-p "…" shown)
                                       (not (string= shown body)))
                                  (substring shown 0 -1) shown)))
                 (when (and (string-prefix-p visible body) (<= finish (length visible)))
                   (cons (+ start begin) (+ start finish))))
             (let* ((content-end (zr-erc-display--content-end shown))
                    (offset (- content-end (length body))))
               (if (and (<= (- sender-end start) offset)
                        (string= body (substring shown offset content-end)))
                   (cons (+ start offset begin) (+ start offset finish))
                 (when-let* ((filled (zr-erc-display--locate-filled
                                      body begin finish shown (- sender-end start))))
                   (cons (+ start (car filled)) (+ start (cdr filled)))))))))))))

(defun zr-erc-display--apply (speaker-start speaker-end context start end &optional reference)
  "Apply CONTEXT to the speaker and its START..END message or REFERENCE body."
  (when-let* ((result (zr-erc-display--match context)))
    (when-let* ((name (plist-get result :sender)))
      (zr-erc-display--overlay speaker-start speaker-end name (plist-get context :sender)))
    (when-let* ((text (plist-get result :text))
                (range (zr-erc-display--locate
                        result context start end speaker-end reference)))
      (zr-erc-display--overlay (car range) (cdr range) text))))

(defun zr-erc-display--render-replies ()
  "Render reply references using the quoted messages' original contexts."
  (let ((pos (point-min)))
    (while (< pos (point-max))
      (let ((context (get-text-property pos 'zr-erc-reply-speaker-context))
            (end (next-single-property-change
                  pos 'zr-erc-reply-speaker-context nil (point-max))))
        (when context
          (let* ((button (button-at pos))
                 (limit (if button (1- (button-end button)) end)))
            (remove-overlays pos (max end limit) 'zr-erc-display t)
            (zr-erc-display--apply
             pos end context
             (if (and button (<= (+ end 2) limit)
                      (string= (buffer-substring-no-properties end (+ end 2)) ": "))
                 (+ end 2) limit)
             limit t)))
        (setq pos end)))))

(defun zr-erc-display--message-start (start)
  "Skip a reply reference button at message START."
  (if-let* ((button (button-at start))
            ((button-get button 'zr-erc-reply-parent)))
      (min (point-max) (1+ (button-end button)))
    start))

(defun zr-erc-display--render ()
  "Render speakers and bodies within retained message boundaries."
  (save-excursion
    (with-silent-modifications
      (zr-erc-display--clear)
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let* ((speaker (get-text-property pos 'erc--speaker))
                 (end (next-single-property-change pos 'erc--speaker nil (point-max))))
            (when speaker
              (goto-char pos)
              (let* ((stored (get-text-property pos 'zr-erc-display-context))
                     (summary (get-text-property pos 'zr-erc-reply-summary))
                     (property (cond (stored 'zr-erc-display-context)
                                     (summary 'zr-erc-reply-summary)))
                     (start (if property
                                (previous-single-property-change (1+ pos) property nil (point-min))
                              (line-beginning-position)))
                     (limit (if property
                                (next-single-property-change pos property nil (point-max))
                              (min (point-max) (1+ (line-end-position)))))
                     (start (zr-erc-display--message-start start))
                     (data (or stored
                               (and summary (> (length summary) 0)
                                    (get-text-property 0 'zr-erc-reply-speaker-context summary))
                               (zr-erc-context
                                (get-text-property pos 'erc-parsed)
                                (buffer-substring-no-properties start limit)))))
                (setq data (plist-put (copy-sequence data) :sender speaker))
                (zr-erc-display--apply pos end data start limit)))
            (setq pos end))))
      (zr-erc-display--render-replies))))

(defun zr-erc-display--insert ()
  "Render the narrowed incoming message after ERC formatting."
  (when (and (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed) '("PRIVMSG" "NOTICE")))
    (with-silent-modifications
      (put-text-property
       (point-min) (point-max) 'zr-erc-display-context
       (zr-erc-context erc-message-parsed
                       (buffer-substring-no-properties
                        (zr-erc-display--message-start (point-min)) (point-max)))))
    (zr-erc-display--render)))

;;;###autoload
(defun zr-erc-display-refresh ()
  "Refresh retained history after changing display rules."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (if (bound-and-true-p erc-zr-display-mode)
          (save-restriction
            (when (and (markerp erc-insert-marker) (marker-position erc-insert-marker))
              (narrow-to-region (point-min) erc-insert-marker))
            (zr-erc-display--render))
        (zr-erc-display--clear)))))

;;;###autoload (autoload 'erc-zr-display-mode "zr-erc-display" nil t)
(define-erc-module zr-display nil
  "Apply name and text replacements in this buffer using overlays.
Enabling refreshes retained history; disabling restores the original display.
No reconnect or channel rejoin is needed."
  ((add-hook 'erc-insert-post-hook #'zr-erc-display--insert 85 t)
   (add-hook 'erc-send-post-hook #'zr-erc-display--render-replies 85 t)
   (zr-erc-display-refresh))
  ((remove-hook 'erc-insert-post-hook #'zr-erc-display--insert t)
   (remove-hook 'erc-send-post-hook #'zr-erc-display--render-replies t)
   (zr-erc-display-refresh))
  t)

(provide 'zr-erc-display)
;;; zr-erc-display.el ends here
