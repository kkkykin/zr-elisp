;;; zr-erc-completion.el --- Complete relayed names from ERC history -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Enable `erc-zr-completion-mode'.  At @name, TAB completes names extracted
;; from retained messages, including relaymsg senders absent from NAMES.
;; All options are buffer-local-capable; ordinary ERC completion is unchanged.
;;; Code:
(require 'zr-erc-common)

(defgroup zr-erc-completion nil "Complete relayed names." :group 'erc)
(defcustom zr-erc-completion-rules
  '((:source sender :regexp "\\`\\(.+\\)-\\([0-9]+\\)/onebot\\'" :groups (1 2))
    (:source text :regexp "^<\\(.+\\)-\\([0-9]+\\)/onebot> " :groups (1 2))
    (:source text :regexp "^<\\([^>]+\\)> " :groups (1)))
  "Ordered extraction rules; use the first rule that yields candidates.
Each rule supports :match (a `zr-erc-match-p' selector), :source (sender,
body, text, or (:tag TAG)), :regexp, and :groups (capture numbers, default
\=(0)).  Without :regexp, the entire source is group 0.  For example a
tag-only rule is (:source (:tag \"+display-name\")).  Multiple groups let
one relaymsg sender contribute both a display name and a numeric ID."
  :type 'sexp :group 'zr-erc-completion)
(defcustom zr-erc-completion-input-regexp
  "\\(?:\\`\\|[[:space:]]\\)@\\([^[:space:]@]*\\)\\'"
  "Regexp matching the input before point when this module should complete.
Only `zr-erc-completion-input-group' is replaced, so @ stays in the input."
  :type 'regexp :group 'zr-erc-completion)
(defcustom zr-erc-completion-input-group 1
  "Capture group identifying the portion of input to complete."
  :type 'integer :group 'zr-erc-completion)
(defcustom zr-erc-completion-history-limit 100000
  "Maximum number of history characters to examine per completion."
  :type 'integer :group 'zr-erc-completion)
(dolist (option '(zr-erc-completion-rules zr-erc-completion-input-regexp
                  zr-erc-completion-input-group zr-erc-completion-history-limit))
  (make-variable-buffer-local option))

(defun zr-erc-completion--extract (context)
  "Extract candidate names from CONTEXT according to the current rules."
  (save-match-data
    (let ((case-fold-search nil))
      (cl-loop
       for rule in zr-erc-completion-rules
       for source = (or (plist-get rule :source) 'text)
       for value = (if (consp source)
                       (cdr (assoc (cadr source) (plist-get context :tags)))
                     (plist-get context (intern (concat ":" (symbol-name source)))))
       when (and value (zr-erc-match-p (plist-get rule :match) context))
       thereis
       (let ((regexp (plist-get rule :regexp)))
         (when (if regexp (string-match regexp value)
                 (set-match-data (list 0 (length value))) t)
           (delq nil
                 (mapcar (lambda (group)
                           (when-let* ((name (match-string group value))
                                       ((not (string-blank-p name)))
                                       ((not (string-match-p "[[:cntrl:]]" name))))
                             name))
                         (or (plist-get rule :groups) '(0))))))))))

(defun zr-erc-completion--remember ()
  "Retain metadata needed for tag/sender-based completion before ERC drops it."
  (when (and (erc-response-p erc-message-parsed)
             (member (erc-response.command erc-message-parsed) '("PRIVMSG" "NOTICE")))
    (put-text-property
     (point-min) (1+ (point-min)) 'zr-erc-completion-context
     (zr-erc-context erc-message-parsed
                     (buffer-substring-no-properties (point-min) (point-max))))))

(defun zr-erc-completion--candidates ()
  "Collect candidates from this conversation's retained history, newest first."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((end (if (markerp erc-insert-marker) (marker-position erc-insert-marker)
                    (point-min)))
             (begin (max (point-min) (- end zr-erc-completion-history-limit)))
             candidates)
        (goto-char end)
        (while (> (point) begin)
          (forward-line -1)
          (let ((context (or (get-text-property (point) 'zr-erc-completion-context)
                             (zr-erc-context
                              nil (buffer-substring-no-properties
                                   (point) (min end (line-end-position)))))))
            (setq candidates (nconc candidates (zr-erc-completion--extract context)))))
        (delete-dups candidates)))))

(defun zr-erc-completion-at-point ()
  "Complete a configured trigger from history, or defer to ordinary ERC completion."
  (when (and (derived-mode-p 'erc-mode) (markerp erc-input-marker)
             (>= (point) erc-input-marker))
    (let ((input (buffer-substring-no-properties erc-input-marker (point)))
          (case-fold-search nil))
      (when (string-match zr-erc-completion-input-regexp input)
        (when-let* ((start (match-beginning zr-erc-completion-input-group))
                    (end (match-end zr-erc-completion-input-group)))
          (list (+ erc-input-marker start) (+ erc-input-marker end)
                (zr-erc-completion--candidates) :exclusive t))))))

;;;###autoload (autoload 'erc-zr-completion-mode "zr-erc-completion" nil t)
(define-erc-module zr-completion nil
  "Complete relayed names and IDs after a configurable trigger."
  ((add-hook 'erc-complete-functions #'zr-erc-completion-at-point -90)
   (add-hook 'erc-insert-post-hook #'zr-erc-completion--remember 80))
  ((remove-hook 'erc-complete-functions #'zr-erc-completion-at-point)
   (remove-hook 'erc-insert-post-hook #'zr-erc-completion--remember)))

(provide 'zr-erc-completion)
;;; zr-erc-completion.el ends here
