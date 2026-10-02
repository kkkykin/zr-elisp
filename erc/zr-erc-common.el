;;; zr-erc-common.el --- Message metadata for ERC modules -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Shared, side-effect-free metadata and rule helpers.  Selectors match
;; regular expressions against :sender, :body, :text, :target, :server,
;; :network, or :tags ((TAG . REGEXP) ...).  A nil tag regexp means presence.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'erc)
(require 'erc-common)

(defvar erc-message-parsed nil)

(cl-defstruct (zr-erc-response (:include erc-response))
  "A reconstructed message retaining all original fragment IDs."
  ids)

(defun zr-erc-tag-unescape (value)
  "Decode an IRCv3 tag VALUE."
  (replace-regexp-in-string
   "\\\\\\(.\\|$\\)"
   (lambda (s)
     (pcase s
       ("\\:" ";") ("\\s" " ") ("\\r" "\r") ("\\n" "\n")
       (_ (substring s 1))))
   value t t))

(defun zr-erc-parse-tags (string)
  "Parse raw tag STRING into an alist, keeping the last duplicate."
  (let (tags)
    (dolist (item (split-string string ";" t) tags)
      (let* ((sep (string-search "=" item))
             (key (if sep (substring item 0 sep) item))
             (value (and sep (zr-erc-tag-unescape (substring item (1+ sep))))))
        (setf (alist-get key tags nil nil #'equal)
              (unless (equal value "") value))))))

(defun zr-erc-message-tags (parsed)
  "Extract tags from PARSED independently of `erc-tags-format'."
  (when-let* ((raw (and parsed (erc-response.unparsed parsed)))
              ((string-prefix-p "@" raw)))
    (zr-erc-parse-tags (substring raw 1 (string-search " " raw)))))

(defun zr-erc-message-ids (parsed)
  "Return all server message IDs associated with PARSED."
  (if (zr-erc-response-p parsed)
      (zr-erc-response-ids parsed)
    (when-let* ((id (cdr (assoc "msgid" (zr-erc-message-tags parsed)))))
      (list id))))

(defun zr-erc-context (&optional parsed text)
  "Return a rule context for PARSED and optionally rendered TEXT."
  (list :sender (and parsed (car (erc-parse-user (erc-response.sender parsed))))
        :body (and parsed (erc-response.contents parsed))
        :text text :tags (zr-erc-message-tags parsed)
        :target (or (erc-default-target)
                    (and parsed (car (erc-response.command-args parsed))))
        :server erc-session-server
        :network (let ((network (erc-network)))
                   (and network (format "%s" network)))))

(defun zr-erc-match-p (selector context)
  "Return non-nil if every condition in SELECTOR matches CONTEXT.
String fields use Emacs regexps.  :tags is an alist of tag names and
regexps; nil requires only that the tag be present.  Nil SELECTOR matches
everything.  Matching does not disturb the caller's match data."
  (save-match-data
    (let ((case-fold-search nil) (match t))
      (while (and match selector)
        (let ((key (pop selector)) (pattern (pop selector)))
          (setq match
                (if (eq key :tags)
                    (cl-every
                     (lambda (entry)
                       (let ((tag (assoc (car entry) (plist-get context :tags))))
                         (and tag (or (null (cdr entry))
                                      (and (cdr tag)
                                           (string-match-p (cdr entry) (cdr tag)))))))
                     pattern)
                  (when-let* ((value (plist-get context key)))
                    (string-match-p pattern value))))))
      match)))

(provide 'zr-erc-common)
;;; zr-erc-common.el ends here
