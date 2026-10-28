;;; zr-dictionary.el --- Staged DICT searches -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Query dictionary.el's server with grouped dictionaries and optional matching.
;; `zr-dictionary-lookup' returns definitions without changing windows or buffers.
;; `zr-dictionary-search' displays them with clickable cross references.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'thingatpt)

(declare-function dictionary-do-search "dictionary" (word dictionary function &optional nomatching))
(declare-function dictionary-read-reply "dictionary" ())
(declare-function dictionary-read-reply-and-split "dictionary" ())
(declare-function dictionary-check-reply "dictionary" (reply code))
(declare-function dictionary-reply-list "dictionary" (reply))
(declare-function dictionary-reply "dictionary" (reply))
(declare-function dictionary-read-answer "dictionary" ())
(declare-function dictionary-decode-charset "dictionary" (text dictionary))
(declare-function dictionary-encode-charset "dictionary" (text dictionary))
(declare-function dictionary-check-initial-reply "dictionary" ())
(declare-function dictionary-send-command "dictionary" (string))
(declare-function dictionary-connection-create-data "dictionary-connection" (buffer process point))
(declare-function dictionary-connection-buffer "dictionary-connection" (connection))
(declare-function dictionary-connection-process "dictionary-connection" (connection))
(declare-function dictionary-connection-set-process "dictionary-connection" (connection process))
(declare-function dictionary-connection-close "dictionary-connection" (connection))

(defvar dictionary-server)
(defvar dictionary-port)
(defvar dictionary-connection)
(defvar dictionary-current-server)
(defvar dictionary-identification)
(defvar dictionary-use-http-proxy)
(defvar dictionary-proxy-server)
(defvar dictionary-proxy-port)

(defgroup zr-dictionary nil
  "Staged dictionary lookups."
  :group 'dictionary
  :prefix "zr-dictionary-")

(defcustom zr-dictionary-timeout 10
  "Maximum seconds for one dictionary lookup, including all stages."
  :type 'number)

(defcustom zr-dictionary-dictionaries '("*" similar)
  "Ordered dictionary search stages.
Each stage is a dictionary ID (string or symbol), or a nonempty list of IDs.
Query every dictionary in a group and combine its definitions.  Continue to
the next stage only when the entire group has no definitions.
An optional final `similar' stage retries the preceding groups in order
using `zr-dictionary-strategy' and the first matching word from each dictionary.
Nil disables lookup.
For example, ((dict1 dict2) dict3 similar) tries dict1 and dict2 together,
then dict3, then matching words in those same groups."
  :type '(repeat (choice (const :tag "Similar words" similar)
                         (string :tag "Dictionary ID (string)")
                         (symbol :tag "Dictionary ID (symbol)")
                         (repeat :tag "Dictionary group" (choice string symbol)))))

(defcustom zr-dictionary-strategy "."
  "DICT matching strategy for the final `similar' stage.
The string \".\" uses the server's default strategy.  Exact searches always
run first; omit `similar' from `zr-dictionary-dictionaries' to skip matching."
  :type 'string)

(defun zr-dictionary-format-name (name id)
  "Format dictionary NAME and ID for display.
Prefer [ID], falling back to NAME when ID is unknown."
  (if (string-equal-ignore-case id "unknown")
      name
    (concat "[" id "]")))

(defcustom zr-dictionary-name-function #'zr-dictionary-format-name
  "Function formatting dictionary headings from (NAME ID).
NAME is the decoded full description; ID is the DICT database identifier.
Return nonempty, single-line display text.
Definitions with the same resulting heading are grouped together."
  :type 'function)

(defun zr-dictionary--string (value)
  "Validate and return string VALUE."
  (unless (stringp value)
    (error "Expected a string"))
  value)

(defun zr-dictionary--connect ()
  "Open a separate connection using dictionary.el's server and proxy settings.
Allocate the connection before opening the stream, so its caller can clean
up the buffer even when connecting fails or times out."
  (setq dictionary-current-server dictionary-server
        dictionary-connection
        (dictionary-connection-create-data
         (generate-new-buffer " *zr-dictionary*") nil 1))
  (let ((coding-system-for-read 'raw-text)
        (coding-system-for-write 'raw-text))
    (dictionary-connection-set-process
     dictionary-connection
     (open-network-stream
      "zr-dictionary" (dictionary-connection-buffer dictionary-connection)
      (if dictionary-use-http-proxy dictionary-proxy-server dictionary-server)
      (if dictionary-use-http-proxy dictionary-proxy-port dictionary-port))))
  (set-process-query-on-exit-flag (dictionary-connection-process dictionary-connection) nil)
  (when dictionary-use-http-proxy
    (dictionary-send-command (format "CONNECT %s:%d HTTP/1.1" dictionary-server dictionary-port))
    (dictionary-send-command "")
    (let ((reply (dictionary-read-reply-and-split)))
      (unless (equal (nth 1 (dictionary-reply-list reply)) "200")
        (error "Bad reply from dictionary proxy: %s" (dictionary-reply reply))))
    (while (not (equal (dictionary-read-reply) ""))))
  (dictionary-check-initial-reply)
  (dictionary-send-command (concat "client " dictionary-identification))
  (let ((reply (dictionary-read-reply-and-split)))
    (unless (dictionary-check-reply reply 250)
      (error "Unexpected dictionary reply: %s" (dictionary-reply reply)))))

(defun zr-dictionary--escape-word (word)
  "Quote WORD for a DICT command, rejecting line breaks."
  (zr-dictionary--string word)
  (when (string-match-p "[\r\n]" word)
    (error "Dictionary word must be on one line"))
  (replace-regexp-in-string
   "[\"\\\\]" (lambda (match) (concat "\\" match)) word t t))

(defun zr-dictionary--id (id)
  "Validate dictionary ID and return it as a string."
  (let ((name (cond ((stringp id) id)
                    ((and id (symbolp id) (not (eq id 'similar))) (symbol-name id)))))
    (unless (and name (string-match-p "\\`[^ \t\r\n\"\\\\]+\\'" name))
      (error "Invalid dictionary ID: %S" id))
    name))

(defun zr-dictionary--stages ()
  "Validate `zr-dictionary-dictionaries' and normalize its ID groups."
  (unless (proper-list-p zr-dictionary-dictionaries)
    (error "Expected a list of dictionary search stages"))
  (when (or (eq (car zr-dictionary-dictionaries) 'similar)
            (memq 'similar (butlast zr-dictionary-dictionaries)))
    (error "Similar must be the final stage after at least one dictionary group"))
  (mapcar
   (lambda (stage)
     (if (eq stage 'similar)
         stage
       (let ((group (if (listp stage) stage (list stage))))
         (unless (and (consp group) (proper-list-p group))
           (error "Expected a nonempty dictionary group: %S" stage))
         (mapcar #'zr-dictionary--id group))))
   zr-dictionary-dictionaries))

(defun zr-dictionary--definitions (_reply)
  "Read a successful DICT response as (NAME DEFINITION...) groups."
  (let ((reply (dictionary-read-reply-and-split)) definitions)
    (while (dictionary-check-reply reply 151)
      (let* ((parts (dictionary-reply-list reply))
             (database (nth 2 parts))
             (description (dictionary-decode-charset (nth 3 parts) database))
             (name (zr-dictionary--string
                    (funcall zr-dictionary-name-function description database)))
             (text (string-trim
                    (dictionary-decode-charset (dictionary-read-answer) database))))
        (when (or (string-blank-p name) (string-match-p "[\r\n]" name))
          (error "Dictionary name must be nonempty and on one line"))
        (if-let* ((entry (assoc name definitions)))
            (push text (cdr entry))
          (push (list name text) definitions)))
      (setq reply (dictionary-read-reply-and-split)))
    (unless (dictionary-check-reply reply 250)
      (error "Unexpected dictionary reply: %s" (dictionary-reply reply)))
    (mapcar (lambda (entry) (cons (car entry) (nreverse (cdr entry))))
            (nreverse definitions))))

(defun zr-dictionary--first-match (word database)
  "Return the first (DATABASE . WORD) matching escaped WORD, or nil.
Use `zr-dictionary-strategy' and consume the entire response."
  (dictionary-send-command
   (concat "match " database " " zr-dictionary-strategy " \""
           (dictionary-encode-charset word database) "\""))
  (let ((reply (dictionary-read-reply-and-split)))
    (cond
     ((dictionary-check-reply reply 552) nil)
     ((dictionary-check-reply reply 152)
      (let* ((line (car (split-string (dictionary-read-answer) "\n" t)))
             (reply (dictionary-read-reply-and-split)))
        (unless (dictionary-check-reply reply 250)
          (error "Unexpected dictionary reply: %s" (dictionary-reply reply)))
        (when line
          (unless (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.+\\)\\'" line)
            (error "Invalid dictionary match: %s" line))
          (let ((database (match-string 1 line)) (word (match-string 2 line)))
            (zr-dictionary--id database)
            (when (string-prefix-p "\"" word)
              (unless (and (> (length word) 1) (string-suffix-p "\"" word))
                (error "Invalid dictionary match: %s" line))
              (setq word (replace-regexp-in-string
                          (concat (regexp-quote "\\") "\\(.\\)") "\\1" (substring word 1 -1))))
            (cons database (dictionary-decode-charset word database))))))
     (t (error "Unexpected dictionary reply: %s" (dictionary-reply reply))))))

(defun zr-dictionary--query-group (word databases &optional similar)
  "Combine definitions for escaped WORD in DATABASES.
When SIMILAR is non-nil, use the first matching word from each database."
  (let (definitions)
    (dolist (database databases)
      (let ((entries
             (if similar
                 (when-let* ((match (zr-dictionary--first-match word database)))
                   (dictionary-do-search
                    (zr-dictionary--escape-word (cdr match)) (car match)
                    #'zr-dictionary--definitions t))
               (dictionary-do-search word database #'zr-dictionary--definitions t))))
        (dolist (entry entries)
          (if-let* ((previous (assoc (car entry) definitions)))
              (setcdr previous (append (cdr previous) (cdr entry)))
            (push entry definitions)))))
    (nreverse definitions)))

(cl-defun zr-dictionary-lookup
    (word &optional (dictionaries zr-dictionary-dictionaries)
          (strategy zr-dictionary-strategy))
  "Look up WORD in DICTIONARIES with matching STRATEGY.
Default to the current buffer's configuration.  Return the first successful
stage as (NAME DEFINITION...) groups, or nil when no definitions are found.
Format names with `zr-dictionary-name-function'.  Use a separate connection,
leaving interactive Dictionary buffers, windows and connections untouched."
  (require 'dictionary)
  (zr-dictionary--string word)
  (let ((zr-dictionary-dictionaries dictionaries)
        (zr-dictionary-strategy (zr-dictionary--id strategy)))
    (if (or (null dictionaries) (string-blank-p word))
        nil
      (let ((stages (zr-dictionary--stages))
            (dictionary-connection nil)
            (dictionary-current-server nil)
            ;; Avoid dictionary.el's automatic server selection prompt.
            (dictionary-server (or dictionary-server "localhost"))
            (word (zr-dictionary--escape-word word)))
	(unwind-protect
            (with-timeout (zr-dictionary-timeout
                           (error "Dictionary lookup timed out"))
              (zr-dictionary--connect)
              (catch 'definitions
                (dolist (similar (if (memq 'similar stages) '(nil t) '(nil)))
                  (dolist (group (remq 'similar stages))
                    (when-let* ((definitions (zr-dictionary--query-group word group similar)))
                      (throw 'definitions definitions))))))
          (dictionary-connection-close dictionary-connection))))))

(defvar-local zr-dictionary-word nil
  "Word displayed in the current dictionary result buffer.")

(define-derived-mode zr-dictionary-mode special-mode "ZR Dictionary"
  "Display dictionary definitions and follow their cross references."
  (setq-local revert-buffer-function
              (lambda (&rest _) (zr-dictionary-search zr-dictionary-word))))

(defun zr-dictionary--follow-reference (button)
  "Look up the word stored on BUTTON using the result buffer's settings."
  (zr-dictionary-search (button-get button 'zr-dictionary-word)))

;;;###autoload
(cl-defun zr-dictionary-search
    (word &optional (dictionaries zr-dictionary-dictionaries)
          (strategy zr-dictionary-strategy))
  "Display definitions of WORD using DICTIONARIES and matching STRATEGY.
Interactively, offer the active region or word at point as the default.
With a prefix argument, also prompt for dictionary stages and strategy.
Words or phrases enclosed in braces become clickable cross references."
  (interactive
   (let* ((default (if (use-region-p)
                       (buffer-substring-no-properties (region-beginning) (region-end))
                     (thing-at-point 'word t)))
          (word (read-string "Dictionary word: " nil nil default)))
     (if current-prefix-arg
         (list word
               (read-minibuffer "Dictionary stages: " (prin1-to-string zr-dictionary-dictionaries))
               (read-string "Matching strategy: " nil nil zr-dictionary-strategy))
       (list word))))
  (let ((definitions (zr-dictionary-lookup word dictionaries strategy))
        (name-function zr-dictionary-name-function)
        (buffer (get-buffer-create "*zr-dictionary*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zr-dictionary-mode)
        (setq-local zr-dictionary-word word
                    zr-dictionary-dictionaries dictionaries
                    zr-dictionary-strategy strategy
                    zr-dictionary-name-function name-function)
        (insert (propertize word 'face 'bold) "\n\n")
        (if definitions
            (dolist (entry definitions)
              (insert (propertize (car entry) 'face 'bold) "\n"
                      (string-join (cdr entry) "\n\n") "\n\n"))
          (insert "No definitions found.\n"))
        (goto-char (point-min))
        (while (re-search-forward "{\\([^{}]+\\)}" nil t)
          (make-text-button (match-beginning 1) (match-end 1)
                            'zr-dictionary-word (replace-regexp-in-string
                                                 "[ \t\r\n]+" " " (match-string-no-properties 1))
                            'action #'zr-dictionary--follow-reference 'follow-link t))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(provide 'zr-dictionary)
;;; zr-dictionary.el ends here
