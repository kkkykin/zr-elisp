;;; zr-dictionary.el --- Staged DICT searches -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Query grouped DICT servers with optional matching.
;; `zr-dictionary-lookup' returns definitions without changing windows or buffers.
;; `zr-dictionary-search' appends asynchronous results in arrival order.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'thingatpt)
(require 'dictionary)

(defgroup zr-dictionary nil
  "Staged dictionary lookups."
  :group 'dictionary
  :prefix "zr-dictionary-")

(defcustom zr-dictionary-timeout 10
  "Maximum seconds for one dictionary lookup, including all stages."
  :type 'number)

(defcustom zr-dictionary-dictionaries '((:server t :port t :dictionary t))
  "Ordered dictionary search stages.
Each stage is a target plist, or a nonempty group of target plists.
:server and :port default to t, meaning `dictionary-server' and
`dictionary-port' independently.  Use a string server and integer port
to specify an endpoint.  :dictionary is an ID or nonempty list of IDs;
t means querying all dictionaries, then similar words.
A final similar in a dictionary list enables
matching for those IDs after all exact stages miss.
Targets on different servers in one group run concurrently.
Query every dictionary in a group and combine its definitions.  Continue to
the next stage only when the entire group has no definitions.
An optional final `similar' stage retries the preceding groups in order
using `zr-dictionary-strategy' and the first matching word from each dictionary.
Nil disables lookup.
Only plist targets are accepted; bare dictionary stages are invalid."
  :type '(repeat sexp))

(defcustom zr-dictionary-strategy "."
  "DICT matching strategy for the final `similar' stage.
The string \".\" uses the server's default strategy.  Exact searches always
run first; omit similar markers and use explicit IDs to skip matching."
  :type 'string)

(defvar zr-dictionary--multiple-servers nil)

(defun zr-dictionary-format-name (name id source)
  "Format dictionary NAME and ID from SOURCE for display.
SOURCE contains the resolved :server, :port and :dictionary.
Include the endpoint when the query spans multiple servers."
  (let ((title (if (string-equal-ignore-case id "unknown") name id)))
    (if zr-dictionary--multiple-servers
        (format "[%s@%s:%s]" title (plist-get source :server) (plist-get source :port))
      (if (string-equal-ignore-case id "unknown") title (concat "[" title "]")))))

(defcustom zr-dictionary-name-function #'zr-dictionary-format-name
  "Function formatting dictionary headings from (NAME ID SOURCE).
NAME is the decoded full description; ID is the DICT database identifier.
SOURCE is a plist with the resolved :server, :port and :dictionary.
Return nonempty, single-line display text.
Returned definitions with the same heading are merged.  The result buffer
appends each response as it arrives, keeping previously displayed text."
  :type 'function)

(defun zr-dictionary--string (value)
  "Validate and return string VALUE."
  (unless (stringp value)
    (error "Expected a string"))
  value)

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

(defun zr-dictionary--endpoint (server port)
  "Validate and return SERVER and PORT as an endpoint cons."
  (unless (and (stringp server) (not (string-blank-p server))
               (not (string-match-p "[ \t\r\n]" server)))
    (error "Invalid dictionary server: %S" server))
  (unless (and (integerp port) (<= 1 port 65535))
    (error "Invalid dictionary port: %S" port))
  (cons server port))

(defun zr-dictionary--targets (target)
  "Expand TARGET into resolved single-dictionary target plists."
  (unless (and (consp target) (keywordp (car target))
               (proper-list-p target) (zerop (% (length target) 2)))
    (error "Invalid dictionary target: %S" target))
  (let ((rest target) seen)
    (while rest
      (let ((key (pop rest)))
        (unless (and (memq key '(:server :port :dictionary)) (not (memq key seen)))
          (error "Invalid dictionary target key: %S" key))
        (push key seen)
        (pop rest))))
  (let* ((server (if (plist-member target :server) (plist-get target :server) t))
         (port (if (plist-member target :port) (plist-get target :port) t))
         (dictionaries (plist-get target :dictionary))
         (ids (cond ((eq dictionaries t) '("*" similar))
                    ((listp dictionaries) dictionaries)
                    (t (list dictionaries)))))
    (when (eq server t) (setq server (or dictionary-server "localhost")))
    (when (eq port t) (setq port dictionary-port))
    (zr-dictionary--endpoint server port)
    (unless (and (consp ids) (proper-list-p ids)
                 (not (eq (car ids) 'similar))
                 (not (memq 'similar (butlast ids))))
      (error "Expected dictionary IDs with an optional final similar: %S" target))
    (let ((similar (eq (car (last ids)) 'similar)))
      (mapcar (lambda (id)
                (let ((id (zr-dictionary--id id)))
                  (list :server server :port port :dictionary (if similar (list id 'similar) id))))
              (remq 'similar ids)))))

(defun zr-dictionary--target-id (target)
  "Return the single database ID in resolved TARGET."
  (let ((dictionary (plist-get target :dictionary)))
    (if (consp dictionary) (car dictionary) dictionary)))

(defun zr-dictionary-resolve-dictionaries (dictionaries)
  "Resolve DICTIONARIES into stage groups of explicit server targets.
Expand :dictionary lists within their stage.  Preserve a final `similar'.
Use this representation to save queries independently of server defaults."
  (unless (proper-list-p dictionaries)
    (error "Expected a list of dictionary search stages"))
  (when (or (eq (car dictionaries) 'similar)
            (memq 'similar (butlast dictionaries)))
    (error "Similar must be the final stage after at least one dictionary group"))
  (mapcar
   (lambda (stage)
     (if (eq stage 'similar)
         stage
       (let ((group (if (and (consp stage) (not (keywordp (car stage))))
                        stage (list stage))))
         (unless (and (consp group) (proper-list-p group))
           (error "Expected a nonempty dictionary group: %S" stage))
         (apply #'append (mapcar #'zr-dictionary--targets group)))))
   dictionaries))

(defun zr-dictionary-dictionaries-p (value)
  "Whether VALUE is a valid, declarative dictionary stage configuration.
Validate syntax without connecting or depending on the user's server defaults."
  (condition-case nil
      (let ((dictionary-server "localhost") (dictionary-port 2628))
        (zr-dictionary-resolve-dictionaries value)
        t)
    (error nil)))

(put 'zr-dictionary-dictionaries 'safe-local-variable #'zr-dictionary-dictionaries-p)

(cl-defstruct (zr-dictionary--query (:constructor zr-dictionary--make-query))
  word strategy plan (group-index 0) pending stage-results clients timer done results error
  on-result on-done name-function multiple-servers buffer proxy identification timeout)

(cl-defstruct (zr-dictionary--client (:constructor zr-dictionary--make-client))
  query endpoint process (input "") (state 'greeting) queue job entries lines source name)

(defun zr-dictionary--merge-entries (chunks)
  "Merge CHUNKS with equal headings without modifying their entries."
  (let (result)
    (dolist (entries chunks)
      (dolist (entry entries)
        (if-let* ((previous (assoc (car entry) result)))
            (setcdr previous (append (cdr previous) (cdr entry)))
          (push (copy-sequence entry) result))))
    (nreverse result)))

(defun zr-dictionary--cancel-query (query)
  "Cancel QUERY and release all of its processes and timer."
  (when query
    (setf (zr-dictionary--query-done query) t)
    (when-let* ((timer (zr-dictionary--query-timer query))) (cancel-timer timer))
    (dolist (entry (zr-dictionary--query-clients query))
      (when-let* ((process (zr-dictionary--client-process (cdr entry))))
        (delete-process process)))))

(defun zr-dictionary--complete (query results &optional error-data)
  "Complete QUERY with RESULTS or ERROR-DATA and notify its caller."
  (unless (zr-dictionary--query-done query)
    (setf (zr-dictionary--query-results query) results
          (zr-dictionary--query-error query) error-data)
    (zr-dictionary--cancel-query query)
    (when-let* ((callback (zr-dictionary--query-on-done query)))
      (funcall callback results error-data))))

(defun zr-dictionary--send (client command)
  "Send COMMAND to CLIENT using DICT line endings."
  (process-send-string (zr-dictionary--client-process client)
                       (concat command "\r\n")))

(defun zr-dictionary--expect (line code)
  "Require status CODE in LINE."
  (unless (= (string-to-number line) code)
    (error "Unexpected dictionary reply: %s" line)))

(defun zr-dictionary--client-next (client)
  "Start the next queued job on an idle CLIENT."
  (when (and (eq (zr-dictionary--client-state client) 'idle)
             (not (zr-dictionary--query-done (zr-dictionary--client-query client)))
             (zr-dictionary--client-queue client))
    (let* ((job (pop (zr-dictionary--client-queue client)))
           (query (zr-dictionary--client-query client))
           (target (nth 2 job))
           (database (zr-dictionary--target-id target))
           (word (zr-dictionary--escape-word (zr-dictionary--query-word query))))
      (setf (zr-dictionary--client-job client) job
            (zr-dictionary--client-entries client) nil
            (zr-dictionary--client-source client) target)
      (if (eq (nth 1 job) 'define)
          (zr-dictionary--send-definition client word database)
        (setf (zr-dictionary--client-state client) 'match-status)
        (zr-dictionary--send
         client (concat "match " database " " (zr-dictionary--query-strategy query)
                        " \"" (dictionary-encode-charset word database) "\""))))))

(defun zr-dictionary--send-definition (client word database)
  "Start a definition request for escaped WORD in DATABASE on CLIENT."
  (setf (zr-dictionary--client-state client) 'define-status)
  (zr-dictionary--send client (concat "define " database " \""
                                     (dictionary-encode-charset word database) "\"")))

(defun zr-dictionary--client-finish (client entries)
  "Finish CLIENT's job with ENTRIES and advance its query when ready."
  (let* ((query (zr-dictionary--client-query client))
         (index (car (zr-dictionary--client-job client))))
    (setf (zr-dictionary--client-job client) nil
          (zr-dictionary--client-state client) 'idle)
    (when entries
      (push (cons index entries) (zr-dictionary--query-stage-results query))
      (when-let* ((callback (zr-dictionary--query-on-result query)))
        (funcall callback entries)))
    (cl-decf (zr-dictionary--query-pending query))
    (unless (zr-dictionary--query-done query)
      (when (zerop (zr-dictionary--query-pending query))
        (if-let* ((chunks (zr-dictionary--query-stage-results query)))
            (zr-dictionary--complete
             query (zr-dictionary--merge-entries
                    (mapcar #'cdr (sort chunks (lambda (a b) (< (car a) (car b)))))))
          (zr-dictionary--advance query)))
      (zr-dictionary--client-next client))))

(defun zr-dictionary--parse-match (line)
  "Decode a DICT match LINE into (DATABASE . WORD)."
  (unless (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.+\\)\\'" line)
    (error "Invalid dictionary match: %s" line))
  (let ((database (zr-dictionary--id (match-string 1 line)))
        (word (match-string 2 line)))
    (when (string-prefix-p "\"" word)
      (unless (and (> (length word) 1) (string-suffix-p "\"" word))
        (error "Invalid dictionary match: %s" line))
      (setq word (replace-regexp-in-string
                  (concat (regexp-quote "\\") "\\(.\\)") "\\1" (substring word 1 -1))))
    (cons database (dictionary-decode-charset word database))))

(defun zr-dictionary--source (client database)
  "Return CLIENT's endpoint with the actual response DATABASE."
  (list :server (car (zr-dictionary--client-endpoint client))
        :port (cdr (zr-dictionary--client-endpoint client)) :dictionary database))

(defun zr-dictionary--heading (client description database &optional matching)
  "Format CLIENT's DESCRIPTION and DATABASE, or a MATCHING result heading."
  (let* ((query (zr-dictionary--client-query client))
         (zr-dictionary--multiple-servers (zr-dictionary--query-multiple-servers query))
         (function (if matching #'zr-dictionary-format-name
                     (zr-dictionary--query-name-function query)))
         (name (with-current-buffer (if (buffer-live-p (zr-dictionary--query-buffer query))
                                        (zr-dictionary--query-buffer query) (current-buffer))
                 (zr-dictionary--string
                  (funcall function description database (zr-dictionary--source client database))))))
    (when (or (string-blank-p name) (string-match-p "[\r\n]" name))
      (error "Dictionary name must be nonempty and on one line"))
    name))

(defun zr-dictionary--consume-line (client line)
  "Consume one protocol LINE from CLIENT's incremental response."
  (pcase (zr-dictionary--client-state client)
    ('http-status
     (unless (string-match-p "\\`HTTP/[0-9.]+ 200\\(?: \\|\\'\\)" line)
       (error "Bad reply from dictionary proxy: %s" line))
     (setf (zr-dictionary--client-state client) 'http-headers))
    ('http-headers
     (when (string-empty-p line) (setf (zr-dictionary--client-state client) 'greeting)))
    ('greeting
     (zr-dictionary--expect line 220)
     (setf (zr-dictionary--client-state client) 'identified)
     (zr-dictionary--send client (concat "client " (zr-dictionary--query-identification
                                                   (zr-dictionary--client-query client)))))
    ('identified
     (zr-dictionary--expect line 250)
     (setf (zr-dictionary--client-state client) 'idle)
     (zr-dictionary--client-next client))
    ('define-status
     (if (= (string-to-number line) 552)
         (zr-dictionary--client-finish client nil)
       (zr-dictionary--expect line 150)
       (setf (zr-dictionary--client-state client) 'definition-header)))
    ('definition-header
     (if (= (string-to-number line) 250)
         (zr-dictionary--client-finish client (zr-dictionary--client-entries client))
       (zr-dictionary--expect line 151)
       (let* ((parts (dictionary-split-string line))
              (database (zr-dictionary--id (nth 2 parts)))
              (description (dictionary-decode-charset (zr-dictionary--string (nth 3 parts)) database)))
         (setf (zr-dictionary--client-source client) (zr-dictionary--source client database)
               (zr-dictionary--client-name client) (zr-dictionary--heading client description database)
               (zr-dictionary--client-lines client) nil
               (zr-dictionary--client-state client) 'definition-body))))
    ('definition-body
     (if (equal line ".")
         (let* ((database (plist-get (zr-dictionary--client-source client) :dictionary))
                (text (string-trim
                       (dictionary-decode-charset
                        (string-join (nreverse (zr-dictionary--client-lines client)) "\n") database)))
                (entry (list (zr-dictionary--client-name client) text)))
           (setf (zr-dictionary--client-entries client)
                 (zr-dictionary--merge-entries (list (zr-dictionary--client-entries client) (list entry)))
                 (zr-dictionary--client-state client) 'definition-header))
       (push (if (string-prefix-p ".." line) (substring line 1) line)
             (zr-dictionary--client-lines client))))
    ('match-status
     (if (= (string-to-number line) 552)
         (zr-dictionary--client-finish client nil)
       (zr-dictionary--expect line 152)
       (setf (zr-dictionary--client-lines client) nil
             (zr-dictionary--client-state client) 'match-body)))
    ('match-body
     (if (equal line ".")
         (setf (zr-dictionary--client-state client) 'match-complete)
       (push line (zr-dictionary--client-lines client))))
    ('match-complete
     (zr-dictionary--expect line 250)
     (let ((matches (mapcar #'zr-dictionary--parse-match
                           (nreverse (zr-dictionary--client-lines client)))))
       (if (eq (nth 1 (zr-dictionary--client-job client)) 'similar)
           (if-let* ((match (car matches)))
               ;; Matching replies refer to databases on this same server.
               (zr-dictionary--send-definition client (zr-dictionary--escape-word (cdr match)) (car match))
             (zr-dictionary--client-finish client nil))
         (zr-dictionary--client-finish
          client (zr-dictionary--merge-entries
                  (mapcar (lambda (match)
                            (list (list (zr-dictionary--heading client (car match) (car match) t)
                                        (cdr match)))) matches))))))
    (_ (error "Unexpected dictionary reply: %s" line))))

(defun zr-dictionary--filter (client chunk)
  "Parse complete lines in CLIENT's binary CHUNK without waiting."
  (let ((query (zr-dictionary--client-query client)))
    (unless (zr-dictionary--query-done query)
      (condition-case err
          (progn
            (setf (zr-dictionary--client-input client)
                  (concat (zr-dictionary--client-input client) chunk))
            (while (and (not (zr-dictionary--query-done query))
                        (string-match "\n" (zr-dictionary--client-input client)))
              (let* ((input (zr-dictionary--client-input client))
                     (end (match-beginning 0))
                     (line (substring input 0 end)))
                (setf (zr-dictionary--client-input client) (substring input (1+ end)))
                (zr-dictionary--consume-line client (string-remove-suffix "\r" line)))))
        (error (zr-dictionary--complete
                query nil (list (car err) (format "%s:%s: %s"
                                                 (car (zr-dictionary--client-endpoint client))
                                                 (cdr (zr-dictionary--client-endpoint client))
                                                 (error-message-string err)))))))))

(defun zr-dictionary--open-client (query endpoint)
  "Open QUERY's nonblocking connection to ENDPOINT, honoring proxy settings."
  (let* ((proxy (zr-dictionary--query-proxy query))
         (client (zr-dictionary--make-client :query query :endpoint endpoint
                                             :state (if proxy 'http-status 'greeting))))
    (push (cons endpoint client) (zr-dictionary--query-clients query))
    (setf (zr-dictionary--client-process client)
          (make-network-process
           :name "zr-dictionary" :host (if proxy (car proxy) (car endpoint))
           :service (if proxy (cdr proxy) (cdr endpoint)) :nowait t :coding 'binary :noquery t
           :filter (lambda (_process chunk) (zr-dictionary--filter client chunk))
           :sentinel
           (lambda (process _event)
             (setf (zr-dictionary--client-process client) process)
             (unless (zr-dictionary--query-done query)
               (pcase (process-status process)
                 ('open
                  (when proxy
                    (let ((server (car endpoint)))
                      (when (string-match-p ":" server) (setq server (concat "[" server "]")))
                      (zr-dictionary--send client (format "CONNECT %s:%s HTTP/1.1\r\n"
                                                         server (cdr endpoint))))))
                 ((or 'closed 'failed 'exit 'signal)
                  (zr-dictionary--complete
                   query nil (list 'error (format "Dictionary connection to %s:%s closed"
                                                 (car endpoint) (cdr endpoint))))))))))
    client))

(defun zr-dictionary--advance (query)
  "Start QUERY's next stage after the entire preceding stage misses."
  (unless (zr-dictionary--query-done query)
    (if-let* ((stage (pop (zr-dictionary--query-plan query))))
        (condition-case err
            (pcase-let ((`(,kind ,group-index ,targets) stage)
                        (index 0))
              (setf (zr-dictionary--query-group-index query) group-index
                    (zr-dictionary--query-pending query) (length targets)
                    (zr-dictionary--query-stage-results query) nil)
              (dolist (target targets)
                (unless (zr-dictionary--query-done query)
                  (let* ((endpoint (cons (plist-get target :server) (plist-get target :port)))
                         (client (or (cdr (assoc endpoint (zr-dictionary--query-clients query)))
                                     (zr-dictionary--open-client query endpoint))))
                    (setf (zr-dictionary--client-queue client)
                          (nconc (zr-dictionary--client-queue client) (list (list index kind target))))
                    (cl-incf index)
                    (zr-dictionary--client-next client)))))
          (error (zr-dictionary--complete query nil err)))
      (zr-dictionary--complete query nil))))

(defun zr-dictionary--prepare-query (word dictionaries strategy on-result on-done &optional matching group-index)
  "Validate and prepare a query, optionally restricted to GROUP-INDEX."
  (zr-dictionary--escape-word word)
  (let* ((stages (zr-dictionary-resolve-dictionaries dictionaries))
         (groups (remq 'similar stages))
         (endpoints (delete-dups (mapcar (lambda (target)
                                         (cons (plist-get target :server) (plist-get target :port)))
                                       (apply #'append groups))))
         (proxy (when dictionary-use-http-proxy
                  (zr-dictionary--endpoint dictionary-proxy-server dictionary-proxy-port)))
         (plan
          (append
           (cl-loop for group in groups for index from 0
                    collect (list (if matching 'match 'define) index group))
           (unless matching
             (cl-loop for group in groups for index from 0
                      for targets = (if (memq 'similar stages) group
                                      (cl-remove-if-not
                                       (lambda (target) (consp (plist-get target :dictionary))) group))
                      when targets collect (list 'similar index targets))))))
    (zr-dictionary--make-query
     :word word :strategy (zr-dictionary--id strategy)
     :group-index (or group-index 0)
     :plan (unless (string-blank-p word)
             (if group-index
                 (cl-remove-if-not (lambda (stage) (= (cadr stage) group-index)) plan)
               plan))
     :on-result on-result :on-done on-done :name-function zr-dictionary-name-function
     :multiple-servers (> (length endpoints) 1) :buffer (current-buffer)
     :proxy proxy :identification dictionary-identification :timeout zr-dictionary-timeout)))

(defun zr-dictionary--start-query (query)
  "Start prepared QUERY and its overall timeout."
  (setf (zr-dictionary--query-timer query)
        (run-at-time (zr-dictionary--query-timeout query) nil
                     (lambda () (zr-dictionary--complete query nil '(error "Dictionary lookup timed out")))))
  (zr-dictionary--advance query)
  query)

(defun zr-dictionary--wait-query (query)
  "Wait for QUERY to finish and return its complete merged result."
  (unwind-protect
      (progn
        (zr-dictionary--start-query query)
        (while (not (zr-dictionary--query-done query)) (accept-process-output nil 0.01))
        (if-let* ((err (zr-dictionary--query-error query)))
            (signal (car err) (cdr err))
          (zr-dictionary--query-results query)))
    (zr-dictionary--cancel-query query)))

(cl-defun zr-dictionary-lookup
    (word &optional (dictionaries zr-dictionary-dictionaries)
          (strategy zr-dictionary-strategy))
  "Return WORD's complete first successful stage as (NAME DEFINITION...) groups.
Resolve DICTIONARIES across servers and use STRATEGY for a final `similar'.
Wait for every target in a successful group and merge in configuration order.
Connections are isolated from native Dictionary buffers and always closed."
  (zr-dictionary--wait-query (zr-dictionary--prepare-query word dictionaries strategy nil nil)))

(defvar-local zr-dictionary-word nil
  "Word displayed in the current dictionary result buffer.")
(defvar-local zr-dictionary--matching-p nil)
(defvar-local zr-dictionary--request nil)
(defvar-local zr-dictionary--view nil)

(cl-defstruct (zr-dictionary--view (:constructor zr-dictionary--make-view))
  word dictionaries strategy name-function matching (group-index 0) selected-group
  entries (status 'pending) error)

(defun zr-dictionary--cancel ()
  "Cancel the result buffer's active request, keeping its received entries."
  (when zr-dictionary--request
    (setf (zr-dictionary--view-group-index zr-dictionary--view)
          (zr-dictionary--query-group-index zr-dictionary--request))
    (zr-dictionary--cancel-query zr-dictionary--request)
    (setq zr-dictionary--request nil)
    (when (eq (zr-dictionary--view-status zr-dictionary--view) 'pending)
      (setf (zr-dictionary--view-status zr-dictionary--view) 'cancelled))))

(defun zr-dictionary--new-search (args &optional _all)
  "Look up the word in native dictionary button ARGS using local stages."
  (zr-dictionary-search (car args)))

(defun zr-dictionary--prompt-search (&rest _)
  "Prompt for a staged search from a native dictionary button."
  (call-interactively #'zr-dictionary-search))

(defun zr-dictionary--lookup-definition ()
  "Look up the word or reference at point using local stages."
  (interactive)
  (zr-dictionary-search (or (dictionary-search-default) (user-error "No word at point"))))

(defconst zr-dictionary--commands
  '((dictionary-search . zr-dictionary--prompt-search)
    (dictionary-new-search . zr-dictionary--new-search)
    (dictionary-lookup-definition . zr-dictionary--lookup-definition)
    (dictionary-match-words . zr-dictionary--match-words)
    (dictionary-select-dictionary . zr-dictionary--select-dictionaries)
    (dictionary-select-strategy . zr-dictionary--select-strategy)))

(defun zr-dictionary--adapt-buttons (start)
  "Redirect native buttons at or after START to the staged commands."
  (let ((position start))
    (while-let ((button (next-button position)))
      (when-let* ((callback (assq (button-get button 'callback) zr-dictionary--commands)))
        (button-put button 'callback (cdr callback)))
      (setq position (button-end button)))))

(defun zr-dictionary--insert-entries (entries)
  "Insert ENTRIES at point using the current view's native definition styles."
  (let ((start (point)))
    (dolist (entry entries)
      (let ((entry-start (point)))
        (insert (propertize (car entry) 'face 'dictionary-word-entry-face) "\n\n")
        (dolist (text (cdr entry))
          (if zr-dictionary--matching-p
              (progn
                (insert-button text :type 'dictionary-link
                               'callback #'zr-dictionary--new-search 'data (cons text (car entry)))
                (insert "\n"))
            ;; The native renderer expects bytes, while query results are decoded.
            (let ((dictionary-coding-systems-for-dictionaries nil))
              (dictionary-display-word-definition (encode-coding-string text 'utf-8)
                                                  zr-dictionary-word "*"))))
        (when zr-dictionary--matching-p (insert "\n"))
        (add-text-properties entry-start (point) (list 'zr-dictionary-entry entry))
        (put-text-property (1- (point)) (point) 'rear-nonsticky t)))
    (zr-dictionary--adapt-buttons start)))

(defun zr-dictionary-selected-entries ()
  "Return complete definitions for dictionaries at point or in the region.
Select every dictionary section intersecting the active region, preserving
display order and merging sections with the same name.  Matching-word lists
are not definitions."
  (unless (and (derived-mode-p 'dictionary-mode) zr-dictionary-word
               (not zr-dictionary--matching-p))
    (user-error "Select definitions in a zr-dictionary result buffer"))
  (let* ((region (use-region-p))
         (position (if region (region-beginning) (point)))
         (end (if region (region-end) (min (1+ position) (point-max))))
         entries)
    (while (< position end)
      (when-let* ((entry (get-text-property position 'zr-dictionary-entry)))
        (push entry entries))
      (setq position (next-single-property-change
                      position 'zr-dictionary-entry nil end)))
    (unless entries
      (user-error "No dictionary definitions selected"))
    (zr-dictionary--merge-entries (list (nreverse entries)))))

(defun zr-dictionary--move-dictionary (backward)
  "Move to the adjacent dictionary heading, going BACKWARD when non-nil."
  (unless (and (derived-mode-p 'dictionary-mode) zr-dictionary-word)
    (user-error "This command requires a zr-dictionary result buffer"))
  (let ((position (point-min)) previous current next)
    (while (< position (point-max))
      (when (get-text-property position 'zr-dictionary-entry)
        (cond
         ((<= position (point)) (setq previous current current position))
         ((not next) (setq next position))))
      (setq position (next-single-property-change
                      position 'zr-dictionary-entry nil (point-max))))
    (let ((target (if backward
                      (if (get-text-property (point) 'zr-dictionary-entry) previous current)
                    next)))
      (unless target
        (user-error "No %s dictionary" (if backward "previous" "next")))
      (goto-char target))))

(defun zr-dictionary-next-dictionary ()
  "Move to the next dictionary in the current result."
  (interactive)
  (zr-dictionary--move-dictionary nil))

(defun zr-dictionary-previous-dictionary ()
  "Move to the previous dictionary in the current result."
  (interactive)
  (zr-dictionary--move-dictionary t))

(defun zr-dictionary--change-group (step)
  "Query the group STEP places away from the current dictionary group."
  (unless (and (derived-mode-p 'dictionary-mode) zr-dictionary--view)
    (user-error "This command requires a zr-dictionary result buffer"))
  (let* ((current (if zr-dictionary--request
                      (zr-dictionary--query-group-index zr-dictionary--request)
                    (zr-dictionary--view-group-index zr-dictionary--view)))
         (index (+ current step))
         (groups (remq 'similar zr-dictionary-dictionaries)))
    (unless (and (>= index 0) (< index (length groups)))
      (user-error "No %s dictionary group" (if (> step 0) "next" "previous")))
    (zr-dictionary--show zr-dictionary-word zr-dictionary-dictionaries
                         zr-dictionary-strategy zr-dictionary--matching-p nil index)))

(defun zr-dictionary-next-group ()
  "Query the same word in the next configured dictionary group."
  (interactive)
  (zr-dictionary--change-group 1))

(defun zr-dictionary-previous-group ()
  "Query the same word in the previous configured dictionary group."
  (interactive)
  (zr-dictionary--change-group -1))

(defun zr-dictionary--status ()
  "Update the current view's status without moving point or existing results."
  (setq header-line-format
        (pcase (zr-dictionary--view-status zr-dictionary--view)
          ('pending "Searching dictionaries…")
          ('cancelled "Dictionary search cancelled")
          ('error (concat "Dictionary error: " (error-message-string
                                               (zr-dictionary--view-error zr-dictionary--view)))))))

(defun zr-dictionary--insert-end ()
  "Insert a final message for an empty or failed current view."
  (cond
   ((eq (zr-dictionary--view-status zr-dictionary--view) 'error)
    (insert "Error: " (error-message-string (zr-dictionary--view-error zr-dictionary--view)) "\n"))
   ((and (eq (zr-dictionary--view-status zr-dictionary--view) 'complete)
         (not (zr-dictionary--view-entries zr-dictionary--view)))
    (insert (if zr-dictionary--matching-p "No matching words found.\n" "No definitions found.\n")))))

(defun zr-dictionary--display (view)
  "Restore VIEW's received entries and configuration in `dictionary-mode'."
  (zr-dictionary--cancel)
  (setq-local zr-dictionary--view view
              zr-dictionary-word (zr-dictionary--view-word view)
              zr-dictionary-dictionaries (zr-dictionary--view-dictionaries view)
              zr-dictionary-strategy (zr-dictionary--view-strategy view)
              zr-dictionary-name-function (zr-dictionary--view-name-function view)
              zr-dictionary--matching-p (zr-dictionary--view-matching view))
  (dictionary-pre-buffer)
  (insert (propertize zr-dictionary-word 'face 'bold) "\n\n")
  (zr-dictionary--insert-entries (zr-dictionary--view-entries view))
  (zr-dictionary--insert-end)
  (zr-dictionary--adapt-buttons (point-min))
  (zr-dictionary--status)
  (dictionary-post-buffer))

(defun zr-dictionary--receive (buffer view entries)
  "Append newly received ENTRIES to BUFFER only while it still displays VIEW."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq zr-dictionary--view view)
        (setf (zr-dictionary--view-entries view)
              (append (zr-dictionary--view-entries view) entries))
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (zr-dictionary--insert-entries entries)))
        (set-buffer-modified-p nil)))))

(defun zr-dictionary--finish-view (buffer view error-data)
  "Finalize BUFFER's current VIEW after its asynchronous query ends."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq zr-dictionary--view view)
        (setq zr-dictionary--request nil)
        (setf (zr-dictionary--view-status view) (if error-data 'error 'complete)
              (zr-dictionary--view-error view) error-data)
        (let ((inhibit-read-only t))
          (save-excursion (goto-char (point-max)) (zr-dictionary--insert-end)))
        (zr-dictionary--status)
        (set-buffer-modified-p nil)))))

(defun zr-dictionary--show (word dictionaries strategy &optional matching refresh group-index)
  "Open WORD's buffer immediately and append results as they arrive.
Use DICTIONARIES and STRATEGY.  MATCHING lists candidates.
REFRESH skips history.  GROUP-INDEX restricts lookup to that configured group."
  (let* ((dictionaries (zr-dictionary-resolve-dictionaries dictionaries))
         (view (zr-dictionary--make-view :word word :dictionaries dictionaries :strategy strategy
                                         :name-function zr-dictionary-name-function :matching matching
                                         :group-index (or group-index 0) :selected-group group-index))
         ;; Validate before changing buffers or cancelling a previous search.
         (query (zr-dictionary--prepare-query word dictionaries strategy nil nil matching group-index))
         (buffer (if (and (derived-mode-p 'dictionary-mode) zr-dictionary-word)
                     (current-buffer) (get-buffer-create "*zr-dictionary*")))
         (configuration (current-window-configuration))
         (window (selected-window)))
    (with-current-buffer buffer
      (unless (and (eq major-mode 'dictionary-mode) zr-dictionary-word)
        (dictionary-mode)
        (setq-local dictionary-window-configuration configuration
                    dictionary-selected-window window dictionary-marker nil
                    revert-buffer-function #'zr-dictionary--revert)
        (add-hook 'kill-buffer-hook #'zr-dictionary--cancel nil t)
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map dictionary-mode-map)
          (dolist (binding zr-dictionary--commands)
            (define-key map (vector 'remap (car binding))
                        (if (eq (car binding) 'dictionary-search) #'zr-dictionary-search (cdr binding))))
          (define-key map "j" #'zr-dictionary-next-dictionary)
          (define-key map "k" #'zr-dictionary-previous-dictionary)
          (define-key map "f" #'zr-dictionary-next-group)
          (define-key map "b" #'zr-dictionary-previous-group)
          (use-local-map map))))
    (pop-to-buffer buffer)
    (unless refresh (dictionary-store-positions))
    (zr-dictionary--display view)
    (if refresh
        (setq dictionary-current-data (list #'zr-dictionary--display view))
      (dictionary-store-state #'zr-dictionary--display (list view)))
    (setf (zr-dictionary--query-on-result query)
          (lambda (entries)
            (setf (zr-dictionary--view-group-index view) (zr-dictionary--query-group-index query))
            (zr-dictionary--receive buffer view entries))
          (zr-dictionary--query-on-done query)
          (lambda (_results err)
            (setf (zr-dictionary--view-group-index view) (zr-dictionary--query-group-index query))
            (zr-dictionary--finish-view buffer view err)))
    (setq zr-dictionary--request query)
    (zr-dictionary--start-query query)
    buffer))

(defun zr-dictionary--revert (&rest _)
  "Restart the current search without adding a history entry."
  (zr-dictionary--show zr-dictionary-word zr-dictionary-dictionaries
                       zr-dictionary-strategy zr-dictionary--matching-p t
                       (zr-dictionary--view-selected-group zr-dictionary--view)))

(cl-defun zr-dictionary--match-words
    (&optional word (dictionaries zr-dictionary-dictionaries) (strategy zr-dictionary-strategy))
  "Asynchronously display all matches in the first successful stage for WORD."
  (interactive)
  (setq word (or word (read-string "Search pattern: " nil 'dictionary-word-history
                                  (dictionary-search-default))))
  (zr-dictionary--show word dictionaries strategy t))

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
  "Display WORD asynchronously using DICTIONARIES and matching STRATEGY.
Open the result buffer immediately and append responses in arrival order.
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
  (zr-dictionary--show word dictionaries strategy))

(provide 'zr-dictionary)
;;; zr-dictionary.el ends here
