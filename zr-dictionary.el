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
(require 'dictionary)

(defvar dictionary-current-server)

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

(defun zr-dictionary--matches (word database)
  "Return (DATABASE . WORD) matches for escaped WORD, or nil.
Use `zr-dictionary-strategy' and consume the entire response."
  (dictionary-send-command
   (concat "match " database " " zr-dictionary-strategy " \""
           (dictionary-encode-charset word database) "\""))
  (let ((reply (dictionary-read-reply-and-split)))
    (cond
     ((dictionary-check-reply reply 552) nil)
     ((dictionary-check-reply reply 152)
      (let* ((lines (split-string (dictionary-read-answer) "\n" t))
             (reply (dictionary-read-reply-and-split)))
        (unless (dictionary-check-reply reply 250)
          (error "Unexpected dictionary reply: %s" (dictionary-reply reply)))
        (mapcar
         (lambda (line)
           (unless (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.+\\)\\'" line)
             (error "Invalid dictionary match: %s" line))
           (let ((database (match-string 1 line)) (word (match-string 2 line)))
             (zr-dictionary--id database)
             (when (string-prefix-p "\"" word)
               (unless (and (> (length word) 1) (string-suffix-p "\"" word))
                 (error "Invalid dictionary match: %s" line))
               (setq word (replace-regexp-in-string
                           (concat (regexp-quote "\\") "\\(.\\)") "\\1" (substring word 1 -1))))
             (cons database (dictionary-decode-charset word database))))
         lines)))
     (t (error "Unexpected dictionary reply: %s" (dictionary-reply reply))))))

(defun zr-dictionary--query-group (word databases &optional similar)
  "Combine definitions for escaped WORD in DATABASES.
When SIMILAR is non-nil, use the first matching word from each database."
  (let (definitions)
    (dolist (database databases)
      (let ((entries
             (if similar
                 (when-let* ((match (car (zr-dictionary--matches word database))))
                   (dictionary-do-search
                    (zr-dictionary--escape-word (cdr match)) (car match)
                    #'zr-dictionary--definitions t))
               (dictionary-do-search word database #'zr-dictionary--definitions t))))
        (dolist (entry entries)
          (if-let* ((previous (assoc (car entry) definitions)))
              (setcdr previous (append (cdr previous) (cdr entry)))
            (push entry definitions)))))
    (nreverse definitions)))

(defun zr-dictionary--call-with-connection (function)
  "Call FUNCTION on an isolated DICT connection, then close it."
  (let ((dictionary-connection nil)
        (dictionary-current-server nil)
        ;; Avoid dictionary.el's automatic server selection prompt.
        (dictionary-server (or dictionary-server "localhost")))
    (unwind-protect
        (with-timeout (zr-dictionary-timeout
                       (error "Dictionary lookup timed out"))
          (zr-dictionary--connect)
          (funcall function))
      (dictionary-connection-close dictionary-connection))))

(cl-defun zr-dictionary-lookup
    (word &optional (dictionaries zr-dictionary-dictionaries)
          (strategy zr-dictionary-strategy))
  "Look up WORD in DICTIONARIES with matching STRATEGY.
Default to the current buffer's configuration.  Return the first successful
stage as (NAME DEFINITION...) groups, or nil when no definitions are found.
Format names with `zr-dictionary-name-function'.  Use a separate connection,
leaving interactive Dictionary buffers, windows and connections untouched."
  (zr-dictionary--string word)
  (let ((zr-dictionary-dictionaries dictionaries)
        (zr-dictionary-strategy (zr-dictionary--id strategy)))
    (if (or (null dictionaries) (string-blank-p word))
        nil
      (let ((stages (zr-dictionary--stages))
            (word (zr-dictionary--escape-word word)))
        (zr-dictionary--call-with-connection
         (lambda ()
           (catch 'definitions
             (dolist (similar (if (memq 'similar stages) '(nil t) '(nil)))
               (dolist (group (remq 'similar stages))
                 (when-let* ((definitions (zr-dictionary--query-group word group similar)))
                   (throw 'definitions definitions)))))))))))

(defvar-local zr-dictionary-word nil
  "Word displayed in the current dictionary result buffer.")

(defvar-local zr-dictionary--matching-p nil
  "Whether the current result displays matching words.")

(defun zr-dictionary--new-search (args &optional _all)
  "Look up the word in native dictionary button ARGS using local stages."
  (zr-dictionary-search (car args)))

(defun zr-dictionary--prompt-search (&rest _)
  "Prompt for a staged search from a native dictionary button."
  (call-interactively #'zr-dictionary-search))

(defun zr-dictionary--lookup-definition ()
  "Look up the word or reference at point using local stages."
  (interactive)
  (zr-dictionary-search (or (dictionary-search-default)
                            (user-error "No word at point"))))

(defun zr-dictionary--lookup-matches (word dictionaries strategy)
  "Return grouped matches for WORD from the first successful dictionary stage."
  (let ((zr-dictionary-dictionaries dictionaries)
        (zr-dictionary-strategy (zr-dictionary--id strategy))
        (word (zr-dictionary--escape-word word)))
    (when (and dictionaries (not (string-blank-p word)))
      (let ((stages (zr-dictionary--stages)))
        (zr-dictionary--call-with-connection
         (lambda ()
           (catch 'matches
             (dolist (group (remq 'similar stages))
               (let (matches)
                 (dolist (database group)
                   (dolist (match (zr-dictionary--matches word database))
                     (if-let* ((entry (assoc (car match) matches)))
                         (setcdr entry (append (cdr entry) (list (cdr match))))
                       (push (list (car match) (cdr match)) matches))))
                 (when matches (throw 'matches (nreverse matches))))))))))))

(defun zr-dictionary--display (word entries dictionaries strategy name-function matching)
  "Render ENTRIES and query settings in the current `dictionary-mode' buffer."
  (setq-local zr-dictionary-word word
              zr-dictionary-dictionaries dictionaries
              zr-dictionary-strategy strategy
              zr-dictionary-name-function name-function
              zr-dictionary--matching-p matching)
  (dictionary-pre-buffer)
  (insert (propertize word 'face 'bold) "\n\n")
  (if entries
      (dolist (entry entries)
        (insert (propertize (car entry) 'face 'dictionary-word-entry-face) "\n\n")
        (dolist (text (cdr entry))
          (if matching
              (progn
                (insert-button text :type 'dictionary-link
                               'callback #'zr-dictionary--new-search
                               'data (cons text (car entry)))
                (insert "\n"))
            ;; Definitions have already been decoded by the data query.
            (let ((dictionary-coding-systems-for-dictionaries nil))
              (dictionary-display-word-definition (encode-coding-string text 'utf-8)
                                                  word "*"))))
        (when matching (insert "\n")))
    (insert (if matching "No matching words found.\n" "No definitions found.\n")))
  ;; Native buttons call their callbacks directly, bypassing command remapping.
  (let ((callbacks '((dictionary-search . zr-dictionary--prompt-search)
                     (dictionary-new-search . zr-dictionary--new-search)
                     (dictionary-match-words . zr-dictionary--match-words)
                     (dictionary-select-dictionary . zr-dictionary--select-dictionaries)
                     (dictionary-select-strategy . zr-dictionary--select-strategy)))
        (position (point-min)))
    (while-let ((button (next-button position)))
      (when-let* ((callback (assq (button-get button 'callback) callbacks)))
        (button-put button 'callback (cdr callback)))
      (setq position (button-end button))))
  (dictionary-post-buffer))

(defun zr-dictionary--show (word entries dictionaries strategy &optional matching)
  "Show ENTRIES for WORD with DICTIONARIES and STRATEGY, recording history."
  (let ((buffer (if (and (derived-mode-p 'dictionary-mode) zr-dictionary-word)
                    (current-buffer)
                  (get-buffer-create "*zr-dictionary*")))
        (configuration (current-window-configuration))
        (window (selected-window))
        (name-function zr-dictionary-name-function))
    (with-current-buffer buffer
      (unless (and (eq major-mode 'dictionary-mode) zr-dictionary-word)
        (dictionary-mode)
        (setq-local dictionary-window-configuration configuration
                    dictionary-selected-window window
                    dictionary-marker nil
                    revert-buffer-function #'zr-dictionary--revert)
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map dictionary-mode-map)
          (dolist (binding '((dictionary-search . zr-dictionary-search)
                             (dictionary-lookup-definition . zr-dictionary--lookup-definition)
                             (dictionary-match-words . zr-dictionary--match-words)
                             (dictionary-select-dictionary . zr-dictionary--select-dictionaries)
                             (dictionary-select-strategy . zr-dictionary--select-strategy)))
            (define-key map (vector 'remap (car binding)) (cdr binding)))
          (use-local-map map))))
    (pop-to-buffer buffer)
    (dictionary-store-positions)
    (let ((args (list word entries dictionaries strategy name-function matching)))
      (apply #'zr-dictionary--display args)
      (dictionary-store-state #'zr-dictionary--display args))))

(defun zr-dictionary--revert (&rest _)
  "Refresh the current definitions or matches without adding a history entry."
  (let ((args (list zr-dictionary-word
                    (if zr-dictionary--matching-p
                        (zr-dictionary--lookup-matches zr-dictionary-word
                                                       zr-dictionary-dictionaries
                                                       zr-dictionary-strategy)
                      (zr-dictionary-lookup zr-dictionary-word))
                    zr-dictionary-dictionaries zr-dictionary-strategy
                    zr-dictionary-name-function zr-dictionary--matching-p)))
    (apply #'zr-dictionary--display args)
    (setq dictionary-current-data (cons #'zr-dictionary--display args))))

(cl-defun zr-dictionary--match-words
    (&optional word (dictionaries zr-dictionary-dictionaries)
               (strategy zr-dictionary-strategy))
  "Display all matches in the first successful stage for WORD."
  (interactive)
  (setq word (or word (read-string "Search pattern: " nil 'dictionary-word-history
                                  (dictionary-search-default))))
  (zr-dictionary--show word (zr-dictionary--lookup-matches word dictionaries strategy)
                       dictionaries strategy t))

(defun zr-dictionary--select-dictionaries (&rest _)
  "Prompt for dictionary stages and repeat the current query."
  (interactive)
  (funcall (if zr-dictionary--matching-p #'zr-dictionary--match-words #'zr-dictionary-search)
           zr-dictionary-word
           (read-minibuffer "Dictionary stages: " (prin1-to-string zr-dictionary-dictionaries))
           zr-dictionary-strategy))

(defun zr-dictionary--select-strategy (&rest _)
  "Prompt for a matching strategy and repeat the current query."
  (interactive)
  (funcall (if zr-dictionary--matching-p #'zr-dictionary--match-words #'zr-dictionary-search)
           zr-dictionary-word zr-dictionary-dictionaries
           (read-string "Matching strategy: " nil nil zr-dictionary-strategy)))

;;;###autoload
(cl-defun zr-dictionary-search
    (word &optional (dictionaries zr-dictionary-dictionaries)
          (strategy zr-dictionary-strategy))
  "Display definitions of WORD using DICTIONARIES and matching STRATEGY.
Interactively, offer the active region or word at point as the default.
With a prefix argument, also prompt for dictionary stages and strategy.
Use `dictionary-mode' with buffer-local staged search commands and native
history, definition formatting and cross references."
  (interactive
   (let* ((default (if (use-region-p)
                       (buffer-substring-no-properties (region-beginning) (region-end))
                     (thing-at-point 'word t)))
          (word (read-string "Dictionary word: " nil 'dictionary-word-history default)))
     (if current-prefix-arg
         (list word
               (read-minibuffer "Dictionary stages: " (prin1-to-string zr-dictionary-dictionaries))
               (read-string "Matching strategy: " nil nil zr-dictionary-strategy))
       (list word))))
  (zr-dictionary--show word (zr-dictionary-lookup word dictionaries strategy)
                       dictionaries strategy))

(provide 'zr-dictionary)
;;; zr-dictionary.el ends here
