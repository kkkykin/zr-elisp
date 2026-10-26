;;; zr-org-srs-x.el --- AnkiConnect capture for Org-srs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2") (org-srs "0.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `zr-org-srs-x-start' to receive LunaTranslator's AnkiConnect v6
;; requests.  Each deck is an Org file in `zr-org-srs-x-directory'.
;; Definitions come from Emacs's dictionary.el, using the deck buffer's
;; `dictionary-default-dictionary'.  LunaTranslator dictionaries are ignored.
;; Cards use Org Front/Back subheadings and the installed Org-srs API.
;; Original fields and Anki HTML/CSS/JavaScript templates are discarded.
;; Loading this library does not start the server or load Org-srs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-id)
(require 'dom)

(declare-function org-srs-item-new "org-srs-item" (type &rest args))
(declare-function org-srs-review-start "org-srs-review" (&optional source))
(declare-function dictionary-do-search "dictionary" (word dictionary function &optional nomatching))
(declare-function dictionary-read-reply "dictionary" ())
(declare-function dictionary-read-reply-and-split "dictionary" ())
(declare-function dictionary-check-reply "dictionary" (reply code))
(declare-function dictionary-reply-list "dictionary" (reply))
(declare-function dictionary-reply "dictionary" (reply))
(declare-function dictionary-read-answer "dictionary" ())
(declare-function dictionary-decode-charset "dictionary" (text dictionary))
(declare-function dictionary-check-initial-reply "dictionary" ())
(declare-function dictionary-send-command "dictionary" (string))
(declare-function dictionary-connection-create-data "dictionary-connection" (buffer process point))
(declare-function dictionary-connection-buffer "dictionary-connection" (connection))
(declare-function dictionary-connection-process "dictionary-connection" (connection))
(declare-function dictionary-connection-set-process "dictionary-connection" (connection process))
(declare-function dictionary-connection-close "dictionary-connection" (connection))

(defvar dictionary-server)
(defvar dictionary-port)
(defvar dictionary-default-dictionary)
(defvar dictionary-connection)
(defvar dictionary-current-server)
(defvar dictionary-identification)
(defvar dictionary-use-http-proxy)
(defvar dictionary-proxy-server)
(defvar dictionary-proxy-port)

(defgroup zr-org-srs-x nil
  "Capture AnkiConnect notes as Org-srs cards."
  :group 'org
  :prefix "zr-org-srs-x-")

(defcustom zr-org-srs-x-directory (expand-file-name "srs" org-directory)
  "Directory containing deck Org files and capture metadata.
Models live in .zr-org-srs-x.json; note IDs and hashes in
.zr-org-srs-x-notes.json.
The Anki deck A::B corresponds to A/B.org in this directory."
  :type 'directory)

(defcustom zr-org-srs-x-host "127.0.0.1"
  "Address on which the explicitly started HTTP server listens."
  :type 'string)

(defcustom zr-org-srs-x-port 8765
  "AnkiConnect HTTP port.  Restart the server after changing this."
  :type 'integer)

(defcustom zr-org-srs-x-dictionary-timeout 10
  "Maximum seconds spent looking up a card's word through dictionary.el."
  :type 'number)

(defcustom zr-org-srs-x-media-path-function #'identity
  "Function translating a client's media path to an Emacs-readable path.
For example, customize this when LunaTranslator runs on Windows and
Emacs reads the same files through a WSL mount."
  :type 'function)

(defcustom zr-org-srs-x-render-function #'zr-org-srs-x-render-luna-note
  "Function converting FIELDS and DEFINITIONS to (FRONT . BACK) strings.
FIELDS is a hash table; DEFINITIONS is dictionary.el's text in Org format.
Dictionary lookup and attachment import run before this function.
The default handles LunaTranslator fields and falls back to the first
field on the front and remaining fields on the back for other models."
  :type 'function)

(defcustom zr-org-srs-x-max-request-size (* 64 1024 1024)
  "Maximum HTTP request body size in bytes."
  :type 'integer)

(defvar zr-org-srs-x--server nil)
(defvar zr-org-srs-x--clients nil)
(defvar zr-org-srs-x--last-id 0)
(defvar zr-org-srs-x--models nil)
(defvar zr-org-srs-x--models-changed nil)
(defvar zr-org-srs-x--note-index nil)

(defun zr-org-srs-x--object (&rest pairs)
  "Return a JSON object from alternating key/value PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) object))
    object))

(defun zr-org-srs-x--get (object key)
  "Get KEY from a JSON OBJECT, rejecting non-objects."
  (unless (hash-table-p object)
    (error "Expected a JSON object"))
  (gethash key object))

(defun zr-org-srs-x--string (value)
  "Validate and return the string VALUE."
  (unless (stringp value)
    (error "Expected a string"))
  value)

(defun zr-org-srs-x--strings (value)
  "Validate and return a JSON array of strings VALUE."
  (unless (and (vectorp value) (cl-every #'stringp value))
    (error "Expected an array of strings"))
  value)

(defun zr-org-srs-x--json (value)
  "Serialize VALUE as text with explicit JSON false and null representations."
  (decode-coding-string
   (json-serialize value :null-object nil :false-object :false) 'utf-8))

(defun zr-org-srs-x--parse (string)
  "Parse JSON STRING without interning user-supplied keys."
  (json-parse-string string :object-type 'hash-table :array-type 'array
                     :null-object nil :false-object :false))

(defun zr-org-srs-x--deck-file (deck)
  "Return the Org file for DECK, rejecting invalid path components."
  (zr-org-srs-x--string deck)
  (let ((parts (split-string deck "::")))
    (dolist (part parts)
      (when (or (string-empty-p part) (member part '("." ".."))
                (string-match-p "[/\\\\:*?\"<>|[:cntrl:]]" part)
                (string-match-p "[ .]\\'" part))
        (error "Invalid deck name: %s" deck)))
    (expand-file-name (concat (string-join parts "/") ".org")
                      zr-org-srs-x-directory)))

(defun zr-org-srs-x--files ()
  "List deck files in `zr-org-srs-x-directory'."
  (when (file-directory-p zr-org-srs-x-directory)
    (directory-files-recursively zr-org-srs-x-directory "\\.org\\'")))

(defun zr-org-srs-x--deck-name (file)
  "Return the Anki deck name corresponding to FILE."
  (string-replace "/" "::"
                  (file-name-sans-extension
                   (file-relative-name file zr-org-srs-x-directory))))

(defun zr-org-srs-x--deck-id (deck)
  "Return a stable integer deck ID for DECK."
  (string-to-number (substring (secure-hash 'sha1 deck) 0 12) 16))

(defun zr-org-srs-x--new-id ()
  "Return a monotonically increasing timestamp-based ID."
  (setq zr-org-srs-x--last-id
        (max (1+ zr-org-srs-x--last-id) (floor (* 1000 (float-time))))))

(defun zr-org-srs-x--buffer (file &optional create)
  "Visit deck FILE, creating its directory when CREATE is non-nil."
  (unless (or create (file-exists-p file))
    (error "Deck was not found: %s" (zr-org-srs-x--deck-name file)))
  (when create
    (make-directory (file-name-directory file) t))
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (org-mode)))
    buffer))

(defun zr-org-srs-x--save ()
  "Save the current deck without interactive prompts."
  (when (verify-visited-file-modtime (current-buffer))
    (let ((coding-system-for-write 'utf-8-unix))
      (save-buffer)))
  (when (buffer-modified-p)
    (error "Deck changed on disk or could not be saved: %s" buffer-file-name)))

(defun zr-org-srs-x--read-data (name)
  "Read the JSON object in metadata file NAME, or return an empty object."
  (let ((file (expand-file-name name zr-org-srs-x-directory)))
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (let ((data (zr-org-srs-x--parse (buffer-string))))
            (unless (hash-table-p data)
              (error "Invalid metadata: %s" file))
            data))
      (make-hash-table :test #'equal))))

(defun zr-org-srs-x--write-data (name data)
  "Atomically write DATA to metadata file NAME."
  (make-directory zr-org-srs-x-directory t)
  (let* ((file (expand-file-name name zr-org-srs-x-directory))
         (temporary (make-temp-file (concat file "-")))
         (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert (zr-org-srs-x--json data) "\n"))
          (rename-file temporary file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun zr-org-srs-x--dom-text (node)
  "Convert HTML DOM NODE to Org text without running scripts."
  (if (stringp node)
      (replace-regexp-in-string "[\t\r\n ]+" " " node)
    (let* ((tag (dom-tag node))
           (text (unless (memq tag '(script style head iframe object))
                   (mapconcat #'zr-org-srs-x--dom-text (dom-children node) ""))))
      (pcase tag
        ((or 'script 'style 'head 'iframe 'object) "")
        ('br "\n")
        ((or 'p 'div 'section 'article 'tr 'h1 'h2 'h3 'h4 'blockquote)
         (concat "\n" text "\n"))
        ('li (concat "\n- " (string-trim text) "\n"))
        ((or 'td 'th) (concat text " | "))
        ((or 'b 'strong) (if (string-blank-p text) text (concat "*" text "*")))
        ((or 'i 'em) (if (string-blank-p text) text (concat "/" text "/")))
        ('rt (concat "（" text "）"))
        ('rp "")
        ('a (if-let* ((url (dom-attr node 'href))
                      ((not (string-match-p "\\`\\(?:javascript\\|data\\):" url))))
                (org-link-make-string url (string-trim text))
              text))
        ('img (if-let* ((src (dom-attr node 'src)))
                  (org-link-make-string
                   (if (string-match-p "\\`\\(?:https?\\|file\\):" src)
                       src (concat "file:" src)))
                ""))
        (_ text)))))

(defun zr-org-srs-x--html (html)
  "Convert HTML and Anki sound references to readable Org content."
  (unless (fboundp 'libxml-parse-html-region)
    (error "This Emacs needs libxml support to import HTML"))
  (let ((html (replace-regexp-in-string
               "\\[sound:\\([^]\n]+\\)\\]"
               (lambda (match)
                 (format "<a href=\"file:%s\">Audio</a>" (substring match 7 -1)))
               html t t)))
    (with-temp-buffer
      (insert "<html><body>" html "</body></html>")
      (string-trim
       (replace-regexp-in-string
        "\n[ \t]*\n\\(?:[ \t]*\n\\)+" "\n\n"
        (zr-org-srs-x--dom-text (libxml-parse-html-region (point-min) (point-max))))))))

(defun zr-org-srs-x--dictionary-connect ()
  "Open the capture connection using dictionary.el's server and proxy settings.
Allocate the connection before opening the stream, so its caller can clean
up the buffer even when connecting fails or times out."
  (setq dictionary-current-server dictionary-server
        dictionary-connection
        (dictionary-connection-create-data
         (generate-new-buffer " *zr-org-srs-x-dictionary*") nil 1))
  (let ((coding-system-for-read 'raw-text)
        (coding-system-for-write 'raw-text))
    (dictionary-connection-set-process
     dictionary-connection
     (open-network-stream
      "zr-org-srs-x-dictionary" (dictionary-connection-buffer dictionary-connection)
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

(defun zr-org-srs-x--dictionary-text (word)
  "Look up WORD with dictionary.el in the current deck's configuration.
Return all definitions as Org text.  Use a separate connection so capture
does not consume replies belonging to an interactive Dictionary buffer."
  (require 'dictionary)
  (if (or (null dictionary-default-dictionary) (string-blank-p word))
      ""
    (unless (and (stringp dictionary-default-dictionary)
                 (string-match-p "\\`[^ \t\r\n\"\\\\]+\\'" dictionary-default-dictionary))
      (error "Invalid dictionary-default-dictionary: %S; expected nil or a DICT database name string"
             dictionary-default-dictionary))
    (when (string-match-p "[\r\n]" word)
      (error "Dictionary word must be on one line"))
    (let ((dictionary-connection nil)
          (dictionary-current-server nil)
          ;; Automatic server selection normally asks before falling back to
          ;; dict.org.  HTTP capture uses localhost without that prompt.
          (dictionary-server (or dictionary-server "localhost"))
          (word (replace-regexp-in-string
                 "[\"\\\\]" (lambda (match) (concat "\\" match)) word t t)))
      (unwind-protect
          (with-timeout (zr-org-srs-x-dictionary-timeout
                         (error "Dictionary lookup timed out"))
            (zr-org-srs-x--dictionary-connect)
            (or (dictionary-do-search
                 word dictionary-default-dictionary
                 (lambda (_reply)
                   (let ((reply (dictionary-read-reply-and-split)) definitions)
                     (while (dictionary-check-reply reply 151)
                       (let* ((parts (dictionary-reply-list reply))
                              (database (nth 2 parts))
                              (description (dictionary-decode-charset (nth 3 parts) database))
                              (text (string-trim
                                     (dictionary-decode-charset (dictionary-read-answer) database))))
                         (push (concat "*" description " [" database "]*\n" text) definitions))
                       (setq reply (dictionary-read-reply-and-split)))
                     (unless (dictionary-check-reply reply 250)
                       (error "Unexpected dictionary reply: %s" (dictionary-reply reply)))
                     (string-join (nreverse definitions) "\n\n")))
                 t)
                ""))
        (dictionary-connection-close dictionary-connection)))))

(defun zr-org-srs-x-render-luna-note (fields definitions)
  "Return Org (FRONT . BACK) strings for a note's FIELDS hash table.
LunaTranslator's word, example, screenshot and audio form the front.
Reading, remarks, dictionary.el DEFINITIONS and extra fields form the back."
  (let* ((front-names (if (gethash "word" fields)
                          '("word" "example_sentence" "audio_for_word"
                            "audio_for_example_sentence" "screenshot")
                        (list (car (hash-table-keys fields)))))
         (ignored (append front-names '("dictionaryInfo" "dictionaryContent")))
         (front nil) (back nil))
    (dolist (name front-names)
      (when-let* ((value (gethash name fields)) ((not (string-empty-p value))))
        (push (zr-org-srs-x--html value) front)))
    (maphash (lambda (name value)
               (unless (or (member name ignored) (string-empty-p value))
                 (push (concat "*" name "*\n" (zr-org-srs-x--html value)) back)))
             fields)
    (unless (string-empty-p definitions)
      (push definitions back))
    (cons (string-join (nreverse front) "\n\n")
          (string-join (nreverse back) "\n\n"))))

(defun zr-org-srs-x--media-bytes (media)
  "Read an Anki MEDIA object's path or base64 data as unibyte content."
  (cond
   ((gethash "data" media)
    (base64-decode-string (zr-org-srs-x--string (gethash "data" media))))
   ((gethash "path" media)
    (let ((path (funcall zr-org-srs-x-media-path-function
                         (zr-org-srs-x--string (gethash "path" media)))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (buffer-string))))
   (t (error "Media requires path or base64 data"))))

(defun zr-org-srs-x--import-media (note fields file)
  "Copy NOTE attachments beside FILE and append references to FIELDS."
  (dolist (kind '("audio" "picture" "video"))
    (let ((medias (gethash kind note [])))
      (unless (vectorp medias)
        (error "Expected a media array"))
      (cl-loop for media across medias do
               (let* ((filename (zr-org-srs-x--string (zr-org-srs-x--get media "filename")))
                      (targets (zr-org-srs-x--strings (zr-org-srs-x--get media "fields")))
                      (bytes (zr-org-srs-x--media-bytes media))
                      (directory (concat (file-name-sans-extension file) ".media/"))
                      (name (concat (substring (secure-hash 'sha256 bytes) 0 16) "-"
                                    (replace-regexp-in-string
                                     "[^[:alnum:]_.-]" "_" (file-name-nondirectory filename))))
                      (destination (expand-file-name name directory))
                      (relative (file-relative-name destination (file-name-directory file)))
                      (reference (if (equal kind "picture")
                                     (format "<img src=\"%s\">" relative)
                                   (format "[sound:%s]" relative))))
                 (cl-loop for target across targets do
                          (unless (gethash target fields)
                            (error "Unknown media field: %s" target)))
                 (make-directory directory t)
                 (unless (file-exists-p destination)
                   (let ((coding-system-for-write 'no-conversion))
                     (write-region bytes nil destination nil 'silent)))
                 (cl-loop for target across targets do
                          (puthash target (concat (gethash target fields) reference) fields)))))))

(defun zr-org-srs-x--notes (function &optional files)
  "Call FUNCTION at each imported note in FILES, returning non-nil results.
FUNCTION receives the numeric note ID, deck file and index entry.
Default FILES is every deck file.  Preserve buffer point and narrowing."
  (let ((results nil))
    (dolist (file (or files (zr-org-srs-x--files)))
      (with-current-buffer (zr-org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (org-map-entries
             (lambda ()
               (when-let* ((org-id (org-entry-get nil "ID"))
                           (entry (gethash org-id zr-org-srs-x--note-index))
                           (id (gethash "noteId" entry)))
                 (setq zr-org-srs-x--last-id (max zr-org-srs-x--last-id id))
                 (when-let* ((value (funcall function id file entry)))
                   (push value results))))
             nil 'file)))))
    (nreverse results)))

(defun zr-org-srs-x--body (text)
  "Escape structural Org lines in card TEXT, preserving card subheadings."
  (replace-regexp-in-string
   "^\\([ \t]*\\)\\(\\*+ \\|#\\+\\|:[[:alnum:]_]+:[ \t]*$\\)" "\\1,\\2" text))

(defun zr-org-srs-x--check-duplicate (model-name field-hash options)
  "Reject duplicates of MODEL-NAME and FIELD-HASH unless OPTIONS allow them."
  (let (duplicate)
    ;; Scan even when duplicates are allowed, to keep IDs unique after restart.
    (zr-org-srs-x--notes
     (lambda (_id _file entry)
       (when (and (equal (gethash "modelName" entry) model-name)
                  (equal (gethash "fieldHash" entry) field-hash))
         (setq duplicate t))
       nil))
    (when (and duplicate (not (eq (zr-org-srs-x--get options "allowDuplicate") t)))
      (error "cannot create note because it is a duplicate"))))

(defun zr-org-srs-x--add-note (note)
  "Import one Anki NOTE and return its integer ID."
  (require 'org-srs)
  (let* ((deck (zr-org-srs-x--get note "deckName"))
         (file (zr-org-srs-x--deck-file deck))
         (model-name (zr-org-srs-x--string (zr-org-srs-x--get note "modelName")))
         (model (or (gethash model-name zr-org-srs-x--models)
                    (error "Model was not found: %s" model-name)))
         (input (zr-org-srs-x--get note "fields"))
         (fields (make-hash-table :test #'equal))
         (names (gethash "inOrderFields" model))
         (tags (zr-org-srs-x--strings (gethash "tags" note [])))
         (options (gethash "options" note (zr-org-srs-x--object))))
    (unless (hash-table-p input)
      (error "Expected note fields"))
    (maphash (lambda (name value)
               (unless (member name (append names nil))
                 (error "Unknown field: %s" name))
               (zr-org-srs-x--string value)) input)
    (cl-loop for name across names do (puthash name (gethash name input "") fields))
    (when (string-blank-p (zr-org-srs-x--html (gethash (aref names 0) fields)))
      (error "cannot create note because it is empty"))
    (let ((field-hash (secure-hash 'sha256 (gethash (aref names 0) fields)))
          (word-hash (when-let* ((word (gethash "word" fields)))
                       (secure-hash 'sha256 word))))
      (zr-org-srs-x--check-duplicate model-name field-hash options)
      (zr-org-srs-x--buffer file)
      ;; The client's dictionary pages are deliberately neither parsed nor saved.
      (remhash "dictionaryInfo" fields)
      (remhash "dictionaryContent" fields)
      (zr-org-srs-x--import-media note fields file)
      (let* ((definitions (with-current-buffer (zr-org-srs-x--buffer file)
                            (zr-org-srs-x--dictionary-text
                             (zr-org-srs-x--html (gethash "word" fields
                                                          (gethash (aref names 0) fields))))))
             (sides (funcall zr-org-srs-x-render-function fields definitions))
             (id (zr-org-srs-x--new-id))
             (org-id (org-id-new))
             (entry (zr-org-srs-x--object "noteId" id "modelName" model-name
                                          "fieldHash" field-hash "wordHash" word-hash))
             (title (replace-regexp-in-string
                     "[\n\r\t]+" " " (zr-org-srs-x--html (gethash (aref names 0) fields)))))
        (unless (and (consp sides) (stringp (car sides)) (stringp (cdr sides)))
          (error "Renderer must return (FRONT . BACK) strings"))
        ;; Dictionary waits can dispatch another capture request.  Refresh the
        ;; index and duplicate check before committing this card.
        (setq zr-org-srs-x--note-index (zr-org-srs-x--read-data ".zr-org-srs-x-notes.json"))
        (zr-org-srs-x--check-duplicate model-name field-hash options)
        (with-current-buffer (zr-org-srs-x--buffer file)
          (save-excursion
            (save-restriction
              (widen)
              (atomic-change-group
                (goto-char (point-max))
                (unless (bolp) (insert "\n"))
                (insert "\n* " title "\n")
                (let ((position (line-beginning-position 0)))
                  (insert "** Front\n" (zr-org-srs-x--body (car sides)) "\n\n"
                          "** Back\n" (zr-org-srs-x--body (cdr sides)) "\n")
                  (goto-char position)
                  (org-entry-put nil "ID" org-id)
                  (org-set-tags
                   (delete-dups
                    (mapcar (lambda (tag) (replace-regexp-in-string
                                           "[^[:alnum:]_@#%]" "_" tag))
                            (append tags nil))))
                  (org-srs-item-new 'card))
                ;; Persist the index before the deck, so an index write failure
                ;; cannot leave an untracked saved card.  Traversal ignores index
                ;; entries whose Org ID is absent from the deck files.
                (puthash org-id entry zr-org-srs-x--note-index)
                (condition-case err
                    (progn
                      (zr-org-srs-x--write-data ".zr-org-srs-x-notes.json" zr-org-srs-x--note-index)
                      (zr-org-srs-x--save))
                  (error
                   (remhash org-id zr-org-srs-x--note-index)
                   (ignore-errors
                     (zr-org-srs-x--write-data ".zr-org-srs-x-notes.json" zr-org-srs-x--note-index))
                   (signal (car err) (cdr err))))))))
        id))))

(defun zr-org-srs-x--find-notes (query)
  "Find note IDs for QUERY, supporting deck and word/w filters.
An empty query returns every imported note.  Other Anki search syntax
is rejected rather than interpreted as an unfiltered query."
  (zr-org-srs-x--string query)
  (let (deck word)
    (unless (string-empty-p query)
      (unless (string-match
               "\\`deck:\\(?:\"\\([^\"]+\\)\"\\|\\([^ \t]+\\)\\)\\(?: +\\(?:w\\|word\\):\"\\([^\"]*\\)\"\\)?\\'"
               query)
        (error "Unsupported note query: %s" query))
      (setq deck (or (match-string 1 query) (match-string 2 query))
            word (match-string 3 query)))
    (zr-org-srs-x--notes
     (lambda (id file entry)
       (when (and (or (not deck) (equal deck (zr-org-srs-x--deck-name file)))
                  (or (not word)
                      (equal (secure-hash 'sha256 word) (gethash "wordHash" entry))))
         id)))))

(defun zr-org-srs-x--delete-notes (ids)
  "Delete imported note subtrees with integer IDS, keeping their attachments."
  (unless (and (vectorp ids) (cl-every #'integerp ids))
    (error "Expected an array of note IDs"))
  ;; Delete from the bottom so Org's traversal is not invalidated by edits.
  (let ((locations (zr-org-srs-x--notes
                    (lambda (id _file _entry) (when (member id (append ids nil))
                                                (point-marker))))))
    (dolist (file (zr-org-srs-x--files))
      (with-current-buffer (zr-org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (atomic-change-group
              (dolist (marker (reverse locations))
                (when (eq (marker-buffer marker) (current-buffer))
                  (goto-char marker)
                  (delete-region (point) (save-excursion (org-end-of-subtree t t) (point)))))
              (when (buffer-modified-p) (zr-org-srs-x--save)))))))
    (mapc (lambda (marker) (set-marker marker nil)) locations)
    (when locations
      (dolist (org-id (hash-table-keys zr-org-srs-x--note-index))
        (when (member (gethash "noteId" (gethash org-id zr-org-srs-x--note-index))
                      (append ids nil))
          (remhash org-id zr-org-srs-x--note-index)))
      (zr-org-srs-x--write-data ".zr-org-srs-x-notes.json" zr-org-srs-x--note-index)))
  nil)

(defun zr-org-srs-x--dispatch (action params)
  "Handle one AnkiConnect ACTION with PARAMS."
  (pcase action
    ("version" 6)
    ("deckNames" (vconcat (mapcar #'zr-org-srs-x--deck-name (zr-org-srs-x--files))))
    ("deckNamesAndIds"
     (let ((decks (zr-org-srs-x--object)))
       (dolist (file (zr-org-srs-x--files))
         (let ((name (zr-org-srs-x--deck-name file)))
           (puthash name (zr-org-srs-x--deck-id name) decks)))
       decks))
    ("createDeck"
     (let* ((name (zr-org-srs-x--get params "deck"))
            (file (zr-org-srs-x--deck-file name)))
       (with-current-buffer (zr-org-srs-x--buffer file t)
         (save-excursion
           (save-restriction
             (widen)
             (when (= (point-min) (point-max))
               (atomic-change-group
                 (insert "#+title: " name "\n")
                 (zr-org-srs-x--save))))))
       (zr-org-srs-x--deck-id name)))
    ("modelNames" (vconcat (sort (hash-table-keys zr-org-srs-x--models) #'string<)))
    ("modelFieldNames"
     (gethash "inOrderFields"
              (or (gethash (zr-org-srs-x--get params "modelName") zr-org-srs-x--models)
                  (error "Model was not found"))))
    ("createModel"
     (let* ((name (zr-org-srs-x--string (zr-org-srs-x--get params "modelName")))
            (fields (zr-org-srs-x--strings (zr-org-srs-x--get params "inOrderFields")))
            (templates (zr-org-srs-x--get params "cardTemplates")))
       (when (gethash name zr-org-srs-x--models)
         (error "Model name already exists"))
       (unless (and (> (length fields) 0)
                    (= (length fields) (length (delete-dups (append fields nil))))
                    (cl-every (lambda (field) (not (string-empty-p field))) fields))
         (error "Model requires unique, nonempty fields"))
       (when (eq (gethash "isCloze" params) t)
         (error "Cloze models are not supported"))
       (unless (and (vectorp templates) (= (length templates) 1))
         (error "Models must have exactly one card template"))
       (dolist (key '("Name" "Front" "Back"))
         (zr-org-srs-x--string (zr-org-srs-x--get (aref templates 0) key)))
       (zr-org-srs-x--string (zr-org-srs-x--get params "css"))
       (let ((model (zr-org-srs-x--object
                     "modelName" name "inOrderFields" fields
                     "templateName" (gethash "Name" (aref templates 0))
                     "id" (zr-org-srs-x--new-id))))
         (puthash name model zr-org-srs-x--models)
         (setq zr-org-srs-x--models-changed t)
         model)))
    ((or "updateModelStyling" "updateModelTemplates")
     (let* ((update (zr-org-srs-x--get params "model"))
            (name (zr-org-srs-x--get update "name"))
            (model (or (gethash name zr-org-srs-x--models) (error "Model was not found"))))
       (if (equal action "updateModelStyling")
           (zr-org-srs-x--string (zr-org-srs-x--get update "css"))
         (let* ((templates (zr-org-srs-x--get update "templates"))
                (sides (zr-org-srs-x--get templates (gethash "templateName" model))))
           (dolist (key '("Front" "Back"))
             (zr-org-srs-x--string (zr-org-srs-x--get sides key)))))
       nil))
    ("addNote" (zr-org-srs-x--add-note (zr-org-srs-x--get params "note")))
    ("findNotes" (vconcat (zr-org-srs-x--find-notes (zr-org-srs-x--get params "query"))))
    ("deleteNotes" (zr-org-srs-x--delete-notes (zr-org-srs-x--get params "notes")))
    (_ (error "Unsupported AnkiConnect action: %s" action))))

(defun zr-org-srs-x-request (request)
  "Handle parsed AnkiConnect REQUEST and return a result/error JSON object.
Only the v6 capture actions documented in org/README.md are supported."
  (condition-case err
      (let* ((action (zr-org-srs-x--string (zr-org-srs-x--get request "action")))
             (version (gethash "version" request 6))
             (params (gethash "params" request (zr-org-srs-x--object)))
             (zr-org-srs-x--models (zr-org-srs-x--read-data ".zr-org-srs-x.json"))
             (zr-org-srs-x--note-index (zr-org-srs-x--read-data ".zr-org-srs-x-notes.json"))
             (zr-org-srs-x--models-changed nil))
        (unless (eql version 6)
          (error "Only AnkiConnect version 6 is supported"))
        (unless (hash-table-p params)
          (error "Expected a params object"))
        (let ((result (zr-org-srs-x--dispatch action params)))
          (when zr-org-srs-x--models-changed
            (zr-org-srs-x--write-data ".zr-org-srs-x.json" zr-org-srs-x--models))
          (zr-org-srs-x--object "result" result "error" nil)))
    (error (zr-org-srs-x--object "result" nil "error" (error-message-string err)))))

(defun zr-org-srs-x--sentinel (process _event)
  "Clean up closed client PROCESS."
  (unless (process-live-p process)
    (when-let* ((timer (process-get process 'zr-org-srs-x-timer)))
      (cancel-timer timer))
    (setq zr-org-srs-x--clients (delq process zr-org-srs-x--clients))))

(defun zr-org-srs-x--accept (_server client _message)
  "Initialize accepted CLIENT and its request timeout."
  (push client zr-org-srs-x--clients)
  (set-process-coding-system client 'binary 'binary)
  (set-process-query-on-exit-flag client nil)
  (process-put client 'zr-org-srs-x-input (encode-coding-string "" 'binary))
  (process-put client 'zr-org-srs-x-timer
               (run-at-time 30 nil (lambda ()
                                     (when (process-live-p client)
                                       (delete-process client))))))

(defun zr-org-srs-x--reply (process response &optional status)
  "Send JSON RESPONSE with HTTP STATUS to PROCESS and close it."
  (let ((body (encode-coding-string (zr-org-srs-x--json response) 'utf-8)))
    (process-send-string
     process (concat "HTTP/1.1 " (or status "200 OK") "\r\n"
                     "Content-Type: application/json; charset=utf-8\r\n"
                     "Connection: close\r\nAllow: GET, POST, OPTIONS\r\n"
                     (format "Content-Length: %d\r\n\r\n" (length body)) body))
    (delete-process process)))

(defun zr-org-srs-x--filter (process chunk)
  "Accumulate binary HTTP CHUNK from PROCESS and dispatch a complete request."
  (when (process-live-p process)
    (condition-case err
        (let* ((input (concat (process-get process 'zr-org-srs-x-input) chunk))
               (case-fold-search t)
               (header-end (and (string-match "\r\n\r\n" input) (match-end 0))))
          (process-put process 'zr-org-srs-x-input input)
          (cond
           ((and (not header-end) (> (length input) 16384))
            (error "HTTP headers are too large"))
           (header-end
            (let* ((headers (substring input 0 (- header-end 2)))
                   (method (and (string-match "\\`\\([A-Z]+\\) /[^ \r\n]* HTTP/1\\.[01]\r\n" headers)
                                (upcase (match-string 1 headers))))
                   (lengths nil))
              (unless (member method '("GET" "POST" "OPTIONS"))
                (error "Expected an HTTP GET, POST or OPTIONS request"))
              (when (string-match-p "\r\nTransfer-Encoding:" headers)
                (error "Transfer-Encoding is not supported; use Content-Length"))
              (let ((start 0))
                (while (string-match "\r\nContent-Length:[ \t]*\\([^\r\n]*\\)\r\n" headers start)
                  (push (match-string 1 headers) lengths)
                  (setq start (- (match-end 0) 2))))
              (when (or (> (length lengths) 1)
                        (and lengths (not (string-match-p "\\`[0-9]+[ \t]*\\'" (car lengths)))))
                (error "Invalid Content-Length"))
              (let ((size (if lengths (string-to-number (car lengths)) 0)))
                (cond
                 ((> size zr-org-srs-x-max-request-size)
                  (zr-org-srs-x--reply process (zr-org-srs-x--object "result" nil "error" "Request is too large")
                                       "413 Payload Too Large"))
                 ((>= (- (length input) header-end) size)
                  (zr-org-srs-x--reply
                   process
                   (if (or (equal method "OPTIONS") (= size 0))
                       (zr-org-srs-x--object "result" 6 "error" nil)
                     (zr-org-srs-x-request
                      (zr-org-srs-x--parse
                       (decode-coding-string (substring input header-end (+ header-end size))
                                             'utf-8))))))))))))
      (error (when (process-live-p process)
               (zr-org-srs-x--reply process
                                    (zr-org-srs-x--object "result" nil "error" (error-message-string err))
                                    "400 Bad Request"))))))

;;;###autoload
(defun zr-org-srs-x-start ()
  "Start the AnkiConnect capture server.  Return its server process."
  (interactive)
  (require 'org-srs)
  (unless (fboundp 'libxml-parse-html-region)
    (user-error "This Emacs needs libxml support to import HTML"))
  (unless (process-live-p zr-org-srs-x--server)
    (setq zr-org-srs-x--server
          (make-network-process :name "zr-org-srs-x" :server t :host zr-org-srs-x-host
                                :service zr-org-srs-x-port :family 'ipv4 :coding 'binary
                                :noquery t :filter #'zr-org-srs-x--filter
                                :sentinel #'zr-org-srs-x--sentinel :log #'zr-org-srs-x--accept)))
  (when (called-interactively-p 'interactive)
    (message "Org-srs AnkiConnect listening on %s:%s" zr-org-srs-x-host
             (process-contact zr-org-srs-x--server :service)))
  zr-org-srs-x--server)

;;;###autoload
(defun zr-org-srs-x-stop ()
  "Stop the capture server and close its client connections."
  (interactive)
  (dolist (client (copy-sequence zr-org-srs-x--clients))
    (when (process-live-p client) (delete-process client)))
  (when (process-live-p zr-org-srs-x--server) (delete-process zr-org-srs-x--server))
  (setq zr-org-srs-x--server nil zr-org-srs-x--clients nil))

;;;###autoload
(defun zr-org-srs-x-review ()
  "Review Org-srs cards in `zr-org-srs-x-directory'."
  (interactive)
  (require 'org-srs)
  (org-srs-review-start (expand-file-name zr-org-srs-x-directory)))

(provide 'zr-org-srs-x)
;;; zr-org-srs-x.el ends here
