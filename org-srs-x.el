;;; org-srs-x.el --- AnkiConnect capture for Org-srs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2") (org-srs "0.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `org-srs-x-start' to receive LunaTranslator's AnkiConnect v6
;; requests.  Each deck is an Org file in `org-srs-x-directory'.
;; Dictionary selection can be configured per file with
;; `org-srs-x-dictionaries' or #+SRS_X_DICTIONARIES: ["dictionary-id"].
;; Cards use Org Front/Back subheadings and the installed Org-srs API.
;; Anki HTML/CSS/JavaScript templates are stored, but are not executed.
;; Loading this library does not start the server or load Org-srs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-id)
(require 'dom)
(require 'url-util)

(declare-function org-srs-item-new "org-srs-item" (type &rest args))
(declare-function org-srs-review-start "org-srs-review" (&optional source))

(defgroup org-srs-x nil
  "Capture AnkiConnect notes as Org-srs cards."
  :group 'org
  :prefix "org-srs-x-")

(defcustom org-srs-x-directory (expand-file-name "srs" org-directory)
  "Directory containing deck Org files and .org-srs-x.json model metadata.
The Anki deck A::B corresponds to A/B.org in this directory."
  :type 'directory)

(defcustom org-srs-x-host "127.0.0.1"
  "Address on which the explicitly started HTTP server listens."
  :type 'string)

(defcustom org-srs-x-port 8765
  "AnkiConnect HTTP port.  Restart the server after changing this."
  :type 'integer)

(defcustom org-srs-x-dictionaries nil
  "Dictionary selections keyed by deck Org file names.
Keys are relative to `org-srs-x-directory', or absolute paths.
Values list dictionary IDs or display names to keep.  An absent entry
keeps all dictionaries; an entry with an empty list keeps none.
A file's #+SRS_X_DICTIONARIES keyword, containing a JSON array of
strings, overrides this setting.  Selection happens before saving the
note, including its original Anki fields."
  :type '(alist :key-type file :value-type (repeat string)))

(defcustom org-srs-x-media-path-function #'identity
  "Function translating a client's media path to an Emacs-readable path.
For example, customize this when LunaTranslator runs on Windows and
Emacs reads the same files through a WSL mount."
  :type 'function)

(defcustom org-srs-x-render-function #'org-srs-x-render-luna-note
  "Function converting a field hash table to a (FRONT . BACK) string pair.
Dictionary selection and attachment import run before this function.
The default handles LunaTranslator fields and falls back to the first
field on the front and remaining fields on the back for other models."
  :type 'function)

(defcustom org-srs-x-max-request-size (* 64 1024 1024)
  "Maximum HTTP request body size in bytes."
  :type 'integer)

(defvar org-srs-x--server nil)
(defvar org-srs-x--clients nil)
(defvar org-srs-x--last-id 0)
(defvar org-srs-x--models nil)
(defvar org-srs-x--models-changed nil)

(defun org-srs-x--object (&rest pairs)
  "Return a JSON object from alternating key/value PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) object))
    object))

(defun org-srs-x--get (object key)
  "Get KEY from a JSON OBJECT, rejecting non-objects."
  (unless (hash-table-p object)
    (error "Expected a JSON object"))
  (gethash key object))

(defun org-srs-x--string (value)
  "Validate and return the string VALUE."
  (unless (stringp value)
    (error "Expected a string"))
  value)

(defun org-srs-x--strings (value)
  "Validate and return a JSON array of strings VALUE."
  (unless (and (vectorp value) (cl-every #'stringp value))
    (error "Expected an array of strings"))
  value)

(defun org-srs-x--json (value)
  "Serialize VALUE as text with explicit JSON false and null representations."
  (decode-coding-string
   (json-serialize value :null-object nil :false-object :false) 'utf-8))

(defun org-srs-x--parse (string)
  "Parse JSON STRING without interning user-supplied keys."
  (json-parse-string string :object-type 'hash-table :array-type 'array
                     :null-object nil :false-object :false))

(defun org-srs-x--deck-file (deck)
  "Return the Org file for DECK, rejecting invalid path components."
  (org-srs-x--string deck)
  (let ((parts (split-string deck "::")))
    (dolist (part parts)
      (when (or (string-empty-p part) (member part '("." ".."))
                (string-match-p "[/\\\\:*?\"<>|[:cntrl:]]" part)
                (string-match-p "[ .]\\'" part))
        (error "Invalid deck name: %s" deck)))
    (expand-file-name (concat (string-join parts "/") ".org")
                      org-srs-x-directory)))

(defun org-srs-x--files ()
  "List deck files in `org-srs-x-directory'."
  (when (file-directory-p org-srs-x-directory)
    (directory-files-recursively org-srs-x-directory "\\.org\\'")))

(defun org-srs-x--deck-name (file)
  "Return the Anki deck name corresponding to FILE."
  (string-replace "/" "::"
                  (file-name-sans-extension
                   (file-relative-name file org-srs-x-directory))))

(defun org-srs-x--deck-id (deck)
  "Return a stable integer deck ID for DECK."
  (string-to-number (substring (secure-hash 'sha1 deck) 0 12) 16))

(defun org-srs-x--new-id ()
  "Return a monotonically increasing timestamp-based ID."
  (setq org-srs-x--last-id
        (max (1+ org-srs-x--last-id) (floor (* 1000 (float-time))))))

(defun org-srs-x--buffer (file &optional create)
  "Visit deck FILE, creating its directory when CREATE is non-nil."
  (unless (or create (file-exists-p file))
    (error "Deck was not found: %s" (org-srs-x--deck-name file)))
  (when create
    (make-directory (file-name-directory file) t))
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (org-mode)))
    buffer))

(defun org-srs-x--save ()
  "Save the current deck without interactive prompts."
  (when (verify-visited-file-modtime (current-buffer))
    (let ((coding-system-for-write 'utf-8-unix))
      (save-buffer)))
  (when (buffer-modified-p)
    (error "Deck changed on disk or could not be saved: %s" buffer-file-name)))

(defun org-srs-x--load-models ()
  "Read the persistent model metadata."
  (let ((file (expand-file-name ".org-srs-x.json" org-srs-x-directory)))
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (let ((models (org-srs-x--parse (buffer-string))))
            (unless (hash-table-p models)
              (error "Invalid model metadata: %s" file))
            models))
      (make-hash-table :test #'equal))))

(defun org-srs-x--save-models ()
  "Atomically write changed model metadata."
  (when org-srs-x--models-changed
    (make-directory org-srs-x-directory t)
    (let* ((file (expand-file-name ".org-srs-x.json" org-srs-x-directory))
           (temporary (make-temp-file (concat file "-")))
           (coding-system-for-write 'utf-8-unix))
      (unwind-protect
          (progn
            (with-temp-file temporary
              (insert (org-srs-x--json org-srs-x--models) "\n"))
            (rename-file temporary file t))
        (when (file-exists-p temporary)
          (delete-file temporary))))))

(defun org-srs-x--selection (file)
  "Return (CONFIGURED . DICTIONARIES) for FILE."
  (with-current-buffer (org-srs-x--buffer file)
    (save-restriction
      (widen)
      (if-let* ((keyword (cadr (assoc "SRS_X_DICTIONARIES"
                                    (org-collect-keywords '("SRS_X_DICTIONARIES"))))))
          (cons t (append (org-srs-x--strings (org-srs-x--parse keyword)) nil))
        (let ((entry (cl-find file org-srs-x-dictionaries
                              :test #'equal
                              :key (lambda (it) (expand-file-name (car it)
                                                                 org-srs-x-directory)))))
          (cons (and entry t) (cdr entry)))))))

(defun org-srs-x--select-dictionaries (fields file)
  "Filter LunaTranslator dictionary FIELDS according to FILE's selection."
  (when-let* ((raw-info (gethash "dictionaryInfo" fields))
              (raw-content (gethash "dictionaryContent" fields)))
    (let* ((info (org-srs-x--parse raw-info))
           (content (org-srs-x--parse raw-content))
           (selection (org-srs-x--selection file))
           (kept (make-hash-table :test #'equal))
           (entries nil))
      (unless (and (vectorp info) (hash-table-p content))
        (error "Invalid LunaTranslator dictionary data"))
      (cl-loop for entry across info
               for id = (org-srs-x--get entry "dict")
               for name = (org-srs-x--get entry "name")
               when (or (not (car selection))
                        (member id (cdr selection)) (member name (cdr selection)))
               do (push entry entries)
               and do (when-let* ((html (gethash id content)))
                        (puthash id html kept)))
      (puthash "dictionaryInfo" (org-srs-x--json (vconcat (nreverse entries))) fields)
      (puthash "dictionaryContent" (org-srs-x--json kept) fields))))

(defun org-srs-x--dom-text (node)
  "Convert HTML DOM NODE to Org text without running scripts."
  (if (stringp node)
      (replace-regexp-in-string "[\t\r\n ]+" " " node)
    (let* ((tag (dom-tag node))
           (text (unless (memq tag '(script style head iframe object))
                   (mapconcat #'org-srs-x--dom-text (dom-children node) ""))))
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

(defun org-srs-x--html (html)
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
        (org-srs-x--dom-text (libxml-parse-html-region (point-min) (point-max))))))))

(defun org-srs-x--dictionary-text (fields)
  "Render the selected, percent-encoded LunaTranslator dictionaries in FIELDS."
  (when-let* ((info (gethash "dictionaryInfo" fields))
              (content (gethash "dictionaryContent" fields)))
    (let ((content (org-srs-x--parse content)))
      (mapconcat
       (lambda (entry)
         (let* ((id (org-srs-x--get entry "dict"))
                (name (or (org-srs-x--get entry "name") id))
                (html (gethash id content "")))
           (concat "*" name "*\n"
                   (org-srs-x--html
                    (decode-coding-string (url-unhex-string html) 'utf-8)))))
       (org-srs-x--parse info) "\n\n"))))

(defun org-srs-x-render-luna-note (fields)
  "Return Org (FRONT . BACK) strings for a note's FIELDS hash table.
LunaTranslator's word, example, screenshot and audio form the front.
Reading, remarks, selected dictionaries and extra fields form the back."
  (let* ((front-names (if (gethash "word" fields)
                          '("word" "example_sentence" "audio_for_word"
                            "audio_for_example_sentence" "screenshot")
                        (list (car (hash-table-keys fields)))))
         (ignored (append front-names '("dictionaryInfo" "dictionaryContent")))
         (front nil) (back nil))
    (dolist (name front-names)
      (when-let* ((value (gethash name fields)) ((not (string-empty-p value))))
        (push (org-srs-x--html value) front)))
    (maphash (lambda (name value)
               (unless (or (member name ignored) (string-empty-p value))
                 (push (concat "*" name "*\n" (org-srs-x--html value)) back)))
             fields)
    (when-let* ((dictionaries (org-srs-x--dictionary-text fields))
                ((not (string-empty-p dictionaries))))
      (push dictionaries back))
    (cons (string-join (nreverse front) "\n\n")
          (string-join (nreverse back) "\n\n"))))

(defun org-srs-x--media-bytes (media)
  "Read an Anki MEDIA object's path or base64 data as unibyte content."
  (cond
   ((gethash "data" media)
    (base64-decode-string (org-srs-x--string (gethash "data" media))))
   ((gethash "path" media)
    (let ((path (funcall org-srs-x-media-path-function
                         (org-srs-x--string (gethash "path" media)))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (buffer-string))))
   (t (error "Media requires path or base64 data"))))

(defun org-srs-x--import-media (note fields file)
  "Copy NOTE attachments beside FILE and append references to FIELDS."
  (dolist (kind '("audio" "picture" "video"))
    (let ((medias (gethash kind note [])))
      (unless (vectorp medias)
        (error "Expected a media array"))
      (cl-loop for media across medias do
               (let* ((filename (org-srs-x--string (org-srs-x--get media "filename")))
                      (targets (org-srs-x--strings (org-srs-x--get media "fields")))
                      (bytes (org-srs-x--media-bytes media))
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

(defun org-srs-x--notes (function &optional files)
  "Call FUNCTION at each imported note in FILES, returning non-nil results.
Default FILES is every deck file.  Preserve buffer point and narrowing."
  (let ((results nil))
    (dolist (file (or files (org-srs-x--files)))
      (with-current-buffer (org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (org-map-entries
             (lambda ()
               (when-let* ((id (org-entry-get nil "ANKI_NOTE_ID")))
                 (setq org-srs-x--last-id (max org-srs-x--last-id (string-to-number id)))
                 (when-let* ((value (funcall function (string-to-number id) file)))
                   (push value results))))
             nil 'file)))))
    (nreverse results)))

(defun org-srs-x--body (text)
  "Escape structural Org lines in card TEXT, preserving card subheadings."
  (replace-regexp-in-string
   "^\\([ \t]*\\)\\(\\*+ \\|#\\+\\|:[[:alnum:]_]+:[ \t]*$\\)" "\\1,\\2" text))

(defun org-srs-x--add-note (note)
  "Import one Anki NOTE and return its integer ID."
  (require 'org-srs)
  (let* ((deck (org-srs-x--get note "deckName"))
         (file (org-srs-x--deck-file deck))
         (model-name (org-srs-x--string (org-srs-x--get note "modelName")))
         (model (or (gethash model-name org-srs-x--models)
                    (error "Model was not found: %s" model-name)))
         (input (org-srs-x--get note "fields"))
         (fields (make-hash-table :test #'equal))
         (names (gethash "inOrderFields" model))
         (tags (org-srs-x--strings (gethash "tags" note [])))
         (options (gethash "options" note (org-srs-x--object)))
         (duplicate nil))
    (unless (hash-table-p input)
      (error "Expected note fields"))
    (maphash (lambda (name value)
               (unless (member name (append names nil))
                 (error "Unknown field: %s" name))
               (org-srs-x--string value)) input)
    (cl-loop for name across names do (puthash name (gethash name input "") fields))
    (when (string-blank-p (org-srs-x--html (gethash (aref names 0) fields)))
      (error "cannot create note because it is empty"))
    ;; Scan even when duplicates are allowed, so IDs remain unique after restart.
    (org-srs-x--notes
     (lambda (_id _file)
       (when (and (equal (org-entry-get nil "ANKI_MODEL") model-name)
                  (equal (gethash (aref names 0)
                                  (org-srs-x--parse (org-entry-get nil "ANKI_FIELDS")))
                         (gethash (aref names 0) fields)))
         (setq duplicate t))
       nil))
    (when (and duplicate (not (eq (org-srs-x--get options "allowDuplicate") t)))
      (error "cannot create note because it is a duplicate"))
    (org-srs-x--buffer file)
    (org-srs-x--select-dictionaries fields file)
    (org-srs-x--import-media note fields file)
    (let* ((sides (funcall org-srs-x-render-function fields))
           (id (org-srs-x--new-id))
           (title (replace-regexp-in-string
                   "[\n\r\t]+" " " (org-srs-x--html (gethash (aref names 0) fields)))))
      (unless (and (consp sides) (stringp (car sides)) (stringp (cdr sides)))
        (error "Renderer must return (FRONT . BACK) strings"))
      (with-current-buffer (org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (atomic-change-group
              (goto-char (point-max))
              (unless (bolp) (insert "\n"))
              (insert "\n* " title "\n")
              (let ((position (line-beginning-position 0)))
                (insert "** Front\n" (org-srs-x--body (car sides)) "\n\n"
                        "** Back\n" (org-srs-x--body (cdr sides)) "\n")
                (goto-char position)
                (org-entry-put nil "ID" (org-id-new))
                (org-entry-put nil "ANKI_NOTE_ID" (number-to-string id))
                (org-entry-put nil "ANKI_MODEL" model-name)
                (org-entry-put nil "ANKI_FIELDS" (org-srs-x--json fields))
                (org-entry-put nil "ANKI_TAGS" (org-srs-x--json tags))
                (org-set-tags
                 (delete-dups
                  (mapcar (lambda (tag) (replace-regexp-in-string
                                        "[^[:alnum:]_@#%]" "_" tag))
                          (append tags nil))))
                (org-srs-item-new 'card))
              (org-srs-x--save)))))
      id)))

(defun org-srs-x--find-notes (query)
  "Find note IDs for QUERY, supporting deck and word/w filters.
An empty query returns every imported note.  Other Anki search syntax
is rejected rather than interpreted as an unfiltered query."
  (org-srs-x--string query)
  (let (deck word)
    (unless (string-empty-p query)
      (unless (string-match
               "\\`deck:\\(?:\"\\([^\"]+\\)\"\\|\\([^ \t]+\\)\\)\\(?: +\\(?:w\\|word\\):\"\\([^\"]*\\)\"\\)?\\'"
               query)
        (error "Unsupported note query: %s" query))
      (setq deck (or (match-string 1 query) (match-string 2 query))
            word (match-string 3 query)))
    (org-srs-x--notes
     (lambda (id file)
       (when (and (or (not deck) (equal deck (org-srs-x--deck-name file)))
                  (or (not word)
                      (equal word (gethash "word" (org-srs-x--parse
                                                   (org-entry-get nil "ANKI_FIELDS"))))))
         id)))))

(defun org-srs-x--delete-notes (ids)
  "Delete imported note subtrees with integer IDS, keeping their attachments."
  (unless (and (vectorp ids) (cl-every #'integerp ids))
    (error "Expected an array of note IDs"))
  ;; Delete from the bottom so Org's traversal is not invalidated by edits.
  (let ((locations (org-srs-x--notes
                    (lambda (id _file) (when (member id (append ids nil))
                                        (point-marker))))))
    (dolist (file (org-srs-x--files))
      (with-current-buffer (org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (atomic-change-group
              (dolist (marker (reverse locations))
                (when (eq (marker-buffer marker) (current-buffer))
                  (goto-char marker)
                  (delete-region (point) (save-excursion (org-end-of-subtree t t) (point)))))
              (when (buffer-modified-p) (org-srs-x--save)))))))
    (mapc (lambda (marker) (set-marker marker nil)) locations))
  nil)

(defun org-srs-x--dispatch (action params)
  "Handle one AnkiConnect ACTION with PARAMS."
  (pcase action
    ("version" 6)
    ("deckNames" (vconcat (mapcar #'org-srs-x--deck-name (org-srs-x--files))))
    ("deckNamesAndIds"
     (let ((decks (org-srs-x--object)))
       (dolist (file (org-srs-x--files))
         (let ((name (org-srs-x--deck-name file)))
           (puthash name (org-srs-x--deck-id name) decks)))
       decks))
    ("createDeck"
     (let* ((name (org-srs-x--get params "deck"))
            (file (org-srs-x--deck-file name)))
       (with-current-buffer (org-srs-x--buffer file t)
         (save-excursion
           (save-restriction
             (widen)
             (when (= (point-min) (point-max))
               (atomic-change-group
                 (insert "#+title: " name "\n")
                 (org-srs-x--save))))))
       (org-srs-x--deck-id name)))
    ("modelNames" (vconcat (sort (hash-table-keys org-srs-x--models) #'string<)))
    ("modelFieldNames"
     (gethash "inOrderFields"
              (or (gethash (org-srs-x--get params "modelName") org-srs-x--models)
                  (error "Model was not found"))))
    ("createModel"
     (let* ((name (org-srs-x--string (org-srs-x--get params "modelName")))
            (fields (org-srs-x--strings (org-srs-x--get params "inOrderFields")))
            (templates (org-srs-x--get params "cardTemplates")))
       (when (gethash name org-srs-x--models)
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
         (org-srs-x--string (org-srs-x--get (aref templates 0) key)))
       (org-srs-x--string (org-srs-x--get params "css"))
       (let ((model (copy-hash-table params)))
         (puthash "id" (org-srs-x--new-id) model)
         (puthash name model org-srs-x--models)
         (setq org-srs-x--models-changed t)
         model)))
    ((or "updateModelStyling" "updateModelTemplates")
     (let* ((update (org-srs-x--get params "model"))
            (name (org-srs-x--get update "name"))
            (model (or (gethash name org-srs-x--models) (error "Model was not found"))))
       (if (equal action "updateModelStyling")
           (puthash "css" (org-srs-x--string (org-srs-x--get update "css")) model)
         (let* ((templates (org-srs-x--get update "templates"))
                (template (aref (gethash "cardTemplates" model) 0))
                (sides (org-srs-x--get templates (gethash "Name" template))))
           (dolist (key '("Front" "Back"))
             (puthash key (org-srs-x--string (org-srs-x--get sides key)) template))))
       (setq org-srs-x--models-changed t)
       nil))
    ("addNote" (org-srs-x--add-note (org-srs-x--get params "note")))
    ("findNotes" (vconcat (org-srs-x--find-notes (org-srs-x--get params "query"))))
    ("deleteNotes" (org-srs-x--delete-notes (org-srs-x--get params "notes")))
    (_ (error "Unsupported AnkiConnect action: %s" action))))

(defun org-srs-x-request (request)
  "Handle parsed AnkiConnect REQUEST and return a result/error JSON object.
Only the v6 capture actions documented in org-srs-x.md are supported."
  (condition-case err
      (let* ((action (org-srs-x--string (org-srs-x--get request "action")))
             (version (gethash "version" request 6))
             (params (gethash "params" request (org-srs-x--object)))
             (org-srs-x--models (org-srs-x--load-models))
             (org-srs-x--models-changed nil))
        (unless (eql version 6)
          (error "Only AnkiConnect version 6 is supported"))
        (unless (hash-table-p params)
          (error "Expected a params object"))
        (let ((result (org-srs-x--dispatch action params)))
          (org-srs-x--save-models)
          (org-srs-x--object "result" result "error" nil)))
    (error (org-srs-x--object "result" nil "error" (error-message-string err)))))

(defun org-srs-x--sentinel (process _event)
  "Clean up closed client PROCESS."
  (unless (process-live-p process)
    (when-let* ((timer (process-get process 'org-srs-x-timer)))
      (cancel-timer timer))
    (setq org-srs-x--clients (delq process org-srs-x--clients))))

(defun org-srs-x--accept (_server client _message)
  "Initialize accepted CLIENT and its request timeout."
  (push client org-srs-x--clients)
  (set-process-coding-system client 'binary 'binary)
  (set-process-query-on-exit-flag client nil)
  (process-put client 'org-srs-x-input (encode-coding-string "" 'binary))
  (process-put client 'org-srs-x-timer
               (run-at-time 30 nil (lambda ()
                                    (when (process-live-p client)
                                      (delete-process client))))))

(defun org-srs-x--reply (process response &optional status)
  "Send JSON RESPONSE with HTTP STATUS to PROCESS and close it."
  (let ((body (encode-coding-string (org-srs-x--json response) 'utf-8)))
    (process-send-string
     process (concat "HTTP/1.1 " (or status "200 OK") "\r\n"
                     "Content-Type: application/json; charset=utf-8\r\n"
                     "Connection: close\r\nAllow: GET, POST, OPTIONS\r\n"
                     (format "Content-Length: %d\r\n\r\n" (length body)) body))
    (delete-process process)))

(defun org-srs-x--filter (process chunk)
  "Accumulate binary HTTP CHUNK from PROCESS and dispatch a complete request."
  (when (process-live-p process)
    (condition-case err
        (let* ((input (concat (process-get process 'org-srs-x-input) chunk))
               (case-fold-search t)
               (header-end (and (string-match "\r\n\r\n" input) (match-end 0))))
          (process-put process 'org-srs-x-input input)
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
                 ((> size org-srs-x-max-request-size)
                  (org-srs-x--reply process (org-srs-x--object "result" nil "error" "Request is too large")
                                    "413 Payload Too Large"))
                 ((>= (- (length input) header-end) size)
                  (org-srs-x--reply
                   process
                   (if (or (equal method "OPTIONS") (= size 0))
                       (org-srs-x--object "result" 6 "error" nil)
                     (org-srs-x-request
                      (org-srs-x--parse
                       (decode-coding-string (substring input header-end (+ header-end size))
                                             'utf-8))))))))))))
      (error (when (process-live-p process)
               (org-srs-x--reply process
                                 (org-srs-x--object "result" nil "error" (error-message-string err))
                                 "400 Bad Request"))))))

;;;###autoload
(defun org-srs-x-start ()
  "Start the AnkiConnect capture server.  Return its server process."
  (interactive)
  (require 'org-srs)
  (unless (fboundp 'libxml-parse-html-region)
    (user-error "This Emacs needs libxml support to import HTML"))
  (unless (process-live-p org-srs-x--server)
    (setq org-srs-x--server
          (make-network-process :name "org-srs-x" :server t :host org-srs-x-host
                                :service org-srs-x-port :family 'ipv4 :coding 'binary
                                :noquery t :filter #'org-srs-x--filter
                                :sentinel #'org-srs-x--sentinel :log #'org-srs-x--accept)))
  (when (called-interactively-p 'interactive)
    (message "Org-srs AnkiConnect listening on %s:%s" org-srs-x-host
             (process-contact org-srs-x--server :service)))
  org-srs-x--server)

;;;###autoload
(defun org-srs-x-stop ()
  "Stop the capture server and close its client connections."
  (interactive)
  (dolist (client (copy-sequence org-srs-x--clients))
    (when (process-live-p client) (delete-process client)))
  (when (process-live-p org-srs-x--server) (delete-process org-srs-x--server))
  (setq org-srs-x--server nil org-srs-x--clients nil))

;;;###autoload
(defun org-srs-x-review ()
  "Review Org-srs cards in `org-srs-x-directory'."
  (interactive)
  (require 'org-srs)
  (org-srs-review-start (expand-file-name org-srs-x-directory)))

(provide 'org-srs-x)
;;; org-srs-x.el ends here
