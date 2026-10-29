;;; zr-org-srs-x.el --- AnkiConnect capture for Org-srs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2") (org-srs "0.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `zr-org-srs-x-start' to receive LunaTranslator's AnkiConnect v6
;; requests.  Each deck is an Org file in `zr-org-srs-x-directory'.
;; Definitions come from zr-dictionary.el, using the deck buffer's
;; `zr-dictionary-dictionaries'.  LunaTranslator dictionaries are ignored.
;; Cards use Org Front/Back subheadings and the installed Org-srs API.
;; `zr-org-srs-x-create-card' captures a word manually; enable
;; `zr-org-srs-x-protocol-mode' for org-protocol://srs-card requests.
;; Add `zr-org-srs-x-capture-template' to `org-capture-templates' to capture
;; selected dictionaries from a zr-dictionary result buffer as one card.
;; Original fields and Anki HTML/CSS/JavaScript templates are discarded.
;; Loading this library does not start the server or load Org-srs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-id)
(require 'dom)
(require 'thingatpt)
(require 'zr-dictionary)
(require 'zr-org-link)

(declare-function org-srs-item-new "org-srs-item" (type &rest args))
(declare-function org-srs-review-start "org-srs-review" (&optional source))
(declare-function org-protocol-parse-parameters "org-protocol"
                  (info &optional new-style default-order))
(declare-function org-capture-get "org-capture" (property &optional local))
(declare-function org-capture-put "org-capture" (&rest elements))
(defvar org-protocol-protocol-alist)
(defvar org-capture-entry)
(defgroup zr-org-srs-x nil
  "Capture AnkiConnect notes as Org-srs cards."
  :group 'org
  :prefix "zr-org-srs-x-")

(defcustom zr-org-srs-x-directory (expand-file-name "srs" org-directory)
  "Directory containing deck Org files and capture media.
The Anki deck A::B corresponds to A/B.org in this directory."
  :type 'directory)

(defcustom zr-org-srs-x-default-deck "Default"
  "Fallback deck when no explicit or model-configured deck is supplied.
Manual capture also falls back to the current deck before this value."
  :type 'string)

(defcustom zr-org-srs-x-host "127.0.0.1"
  "Address on which the explicitly started HTTP server listens."
  :type 'string)

(defcustom zr-org-srs-x-port 8765
  "AnkiConnect HTTP port.  Restart the server after changing this."
  :type 'integer)

(defcustom zr-org-srs-x-media-path-function #'identity
  "Function translating a client's media path to an Emacs-readable path.
For example, customize this when LunaTranslator runs on Windows and
Emacs reads the same files through a WSL mount."
  :type 'function)

(defcustom zr-org-srs-x-model-alist
  '((modelofluna
     (name "%s" .word)
     (front "%s\n%s" .example_sentence .screenshot)
     (back "%s\n%s" .remarks dictionary))
    (TampermonkeyWord
     (name "%s" .word)
     (front "%s" .sentence)
     (back "%s\n%s" .translation dictionary))
    (t . zr-org-srs-x-render-default-note))
  "Renderers selected by an Anki note's modelName.
Keys are model names as strings or symbols; t supplies the fallback and
handles manual, dictionary and Org protocol capture, which have no model name.
A renderer is an alist of name/front/back templates, or a function.
The template alist can also supply deck, a default deck name overridden
by an explicit capture destination, and dictionaries, a dictionary stage
list.  Dictionary configuration uses the target deck's buffer-local
`zr-dictionary-dictionaries' first, then a non-nil dictionaries entry,
then the global variable.  Nil or an absent dictionaries entry inherits
the global configuration.  Back format templates trigger lookup only
when their arguments include dictionary; functions receive dictionary results.
A template is literal text, a (FORMAT REFERENCE...) list, or a function.
Format lists call `format' with resolved references: .FIELD selects a field,
and dictionary, picture, audio and video select definitions and media links.
References are symbols and are not evaluated.  Missing fields and absent
media become empty strings.  Use %% for a literal percent in FORMAT;
literal string templates are used unchanged.
Each template may also be a function of (FIELDS VARIABLES) returning text.
A model renderer function receives the same arguments and returns an alist
of name/front/back Org strings, which are used without template expansion.
FIELDS is an ordered alist from field names to Org strings, following the
model's field order.  Manual, dictionary and protocol capture supply only
a word field.
VARIABLES uses the symbols dictionary, picture,
audio and video as keys.
Render in the deck buffer after dictionary lookup and attachment import."
  :type '(alist :key-type (choice string symbol)
                :value-type
                (choice function
                        (alist :key-type (choice (const name) (const front) (const back)
                                                 (const deck) (const dictionaries))
                               :value-type (choice string function
                                                   (cons :tag "Format template"
                                                         string (repeat symbol))
                                                   (repeat :tag "Dictionary stages" sexp))))))

(defcustom zr-org-srs-x-max-request-size (* 64 1024 1024)
  "Maximum HTTP request body size in bytes."
  :type 'integer)

(defvar zr-org-srs-x--server nil)
(defvar zr-org-srs-x--clients nil)
(defvar zr-org-srs-x--models (make-hash-table :test #'equal))
(defvar zr-org-srs-x--last-id nil)
(defvar zr-org-srs-x--protocol-entry nil)

(defun zr-org-srs-x--new-id ()
  "Generate a strictly monotonic integer ID compatible with Anki."
  (let* ((now (let ((org-id-method 'ts)
                    (org-id-ts-format "%s%3N")
                    (org-id-prefix nil)
                    (org-id-include-domain nil))
                (string-to-number (org-id-new 'none))))
         (id (if (and zr-org-srs-x--last-id (>= zr-org-srs-x--last-id now))
                 (1+ zr-org-srs-x--last-id)
               now)))
    (setq zr-org-srs-x--last-id id)))

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
    (cl-remove-if-not #'file-regular-p
                      (directory-files-recursively zr-org-srs-x-directory "\\.org\\'"))))

(defun zr-org-srs-x--deck-name (file)
  "Return the Anki deck name corresponding to FILE."
  (string-replace "/" "::"
                  (file-name-sans-extension
                   (file-relative-name file zr-org-srs-x-directory))))

(defun zr-org-srs-x--deck-id (deck)
  "Return a stable integer deck ID for DECK."
  (string-to-number (substring (secure-hash 'sha1 deck) 0 12) 16))

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

(defun zr-org-srs-x--dictionary-text (word &optional definitions)
  "Render WORD's `zr-dictionary-lookup' results as Org definitions.
Use supplied DEFINITIONS instead of looking up WORD when non-nil.
Omit server endpoints from dictionary headings.
Put a query link before the first dictionary heading and turn brace-marked
words and phrases into dict links using the current query configuration."
  (let ((zr-dictionary-dictionaries
         (zr-dictionary-resolve-dictionaries zr-dictionary-dictionaries)))
    (if-let* ((definitions (or definitions (zr-dictionary-lookup word))))
	(concat
	 (zr-org-link-dict-link word)
	 "\n\n"
	 (mapconcat
	  (lambda (entry)
            (concat
             (propertize "*** " 'zr-org-srs-x--dictionary-heading t)
             (replace-regexp-in-string
              "\\(\\`\\[.*\\)@[^]\n]+:[0-9]+\\]\\'" "\\1]" (car entry) t)
             "\n"
             (replace-regexp-in-string
              "{\\([^{}]+\\)}"
              (lambda (match)
		(zr-org-link-dict-link
		 (string-trim (replace-regexp-in-string
                               "[ \t\r\n]+" " " (substring match 1 -1)))))
              (string-join (cdr entry) "\n\n") t t)))
	  definitions "\n\n"))
      "")))

(defun zr-org-srs-x-render-default-note (fields variables)
  "Render FIELDS and VARIABLES with the first field as name and front.
Put remaining fields and dictionary definitions on the back."
  (let* ((name (cdar fields))
         (definitions (alist-get 'dictionary variables))
         (back nil))
    (dolist (field (cdr fields))
      (unless (string-empty-p (cdr field))
        (push (concat "*" (car field) "*\n" (cdr field)) back)))
    (unless (string-empty-p definitions)
      (push definitions back))
    `((name . ,name) (front . ,name)
      (back . ,(string-join (nreverse back) "\n\n")))))

(defun zr-org-srs-x--template (template fields variables)
  "Render TEMPLATE with Org FIELDS and VARIABLES.
Use string templates literally and call function templates directly.
For (FORMAT REFERENCE...) lists, resolve .FIELD from FIELDS and bare
symbols from VARIABLES, then call `format'.  Never evaluate references."
  (cond
   ((functionp template) (funcall template fields variables))
   ((stringp template) template)
   ((and (consp template) (proper-list-p template) (stringp (car template)))
    (apply #'format
           (car template)
           (mapcar
            (lambda (reference)
              (unless (symbolp reference)
                (error "Expected a field or variable reference: %S" reference))
              (let ((name (symbol-name reference)))
                (if (string-prefix-p "." name)
                    (alist-get (substring name 1) fields "" nil #'equal)
                  (if-let* ((entry (assq reference variables)))
                      (cdr entry)
                    (error "Unknown card template variable: %S" reference)))))
            (cdr template))))
   (t (error "Card template must be text, a format list or a function: %S" template))))

(defun zr-org-srs-x--model-renderer (model-name)
  "Return MODEL-NAME's renderer, using the t entry as fallback."
  (cdr (or (and model-name (assoc-string model-name zr-org-srs-x-model-alist))
           (assq t zr-org-srs-x-model-alist)
           (error "No card renderer for model: %s" model-name))))

(defun zr-org-srs-x--default-deck (model-name &optional fallback)
  "Return MODEL-NAME's configured deck, FALLBACK or the global default."
  (let ((renderer (zr-org-srs-x--model-renderer model-name)))
    (or (and (not (functionp renderer)) (alist-get 'deck renderer))
        fallback zr-org-srs-x-default-deck)))

(defun zr-org-srs-x--dictionaries (renderer)
  "Choose dictionaries from deck locals, RENDERER or the global variable."
  (let ((dictionaries (and (not (functionp renderer))
                           (alist-get 'dictionaries renderer))))
    (cond
     ((local-variable-p 'zr-dictionary-dictionaries) zr-dictionary-dictionaries)
     (dictionaries dictionaries)
     (t (default-value 'zr-dictionary-dictionaries)))))

(defun zr-org-srs-x--uses-dictionary-p (renderer)
  "Whether RENDERER needs dictionary results for its back.
Functions receive results; format templates must reference dictionary
as an argument.  Literal text and .dictionary refer to no lookup results."
  (or (functionp renderer)
      (let ((back (alist-get 'back renderer)))
        (or (functionp back)
            (and (consp back) (proper-list-p back) (stringp (car back))
                 (memq 'dictionary (cdr back)))))))

(defun zr-org-srs-x--render (model-name fields variables)
  "Render MODEL-NAME using Org FIELDS and VARIABLES in the current deck.
Return an alist of name/front/back strings."
  (let* ((renderer (zr-org-srs-x--model-renderer model-name))
         (parts (if (functionp renderer)
                    (funcall renderer fields variables)
                  (mapcar (lambda (key)
                            (cons key (zr-org-srs-x--template
                                       (alist-get key renderer) fields variables)))
                          '(name front back)))))
    (unless (listp parts)
      (error "Card renderer must supply a name/front/back alist"))
    (let ((card
           (mapcar
            (lambda (key)
              (let ((text (alist-get key parts)))
                (unless (stringp text)
                  (error "Card renderer must supply an Org string for %s" key))
                (cons key (string-trim text))))
            '(name front back))))
      (when (string-empty-p (alist-get 'name card))
        (error "Card renderer produced an empty name"))
      card)))

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
  "Copy NOTE attachments beside FILE and append Org links to FIELDS.
FIELDS is an ordered alist of Org strings, updated in place.
Return an alist of audio/picture/video Org links for card templates."
  (let (variables)
    (dolist (kind '(audio picture video))
      (let ((medias (gethash (symbol-name kind) note [])) links)
        (unless (vectorp medias)
          (error "Expected a media array"))
        (cl-loop for media across medias do
                 (let* ((filename (zr-org-srs-x--string (zr-org-srs-x--get media "filename")))
                        (targets (mapcar
                                  (lambda (name)
                                    (or (assoc name fields)
                                        (error "Unknown media field: %s" name)))
                                  (zr-org-srs-x--strings (zr-org-srs-x--get media "fields"))))
                        (bytes (zr-org-srs-x--media-bytes media))
                        (directory (concat (file-name-sans-extension file) ".media/"))
                        (name (concat (substring (secure-hash 'sha256 bytes) 0 16) "-"
                                      (replace-regexp-in-string
                                       "[^[:alnum:]_.-]" "_" (file-name-nondirectory filename))))
                        (destination (expand-file-name name directory))
                        (relative (file-relative-name destination (file-name-directory file)))
                        (reference (org-link-make-string
                                    (concat "file:" relative)
                                    (unless (eq kind 'picture) (capitalize (symbol-name kind))))))
                   (make-directory directory t)
                   (unless (file-exists-p destination)
                     (let ((coding-system-for-write 'no-conversion))
                       (write-region bytes nil destination nil 'silent)))
                   (push reference links)
                   (dolist (target targets)
                     (setcdr target (concat (cdr target) reference)))))
        (push (cons kind (string-join (nreverse links) "\n\n")) variables)))
    (nreverse variables)))

(defun zr-org-srs-x--body (text)
  "Escape structural Org lines in card TEXT, preserving dictionary headings."
  (replace-regexp-in-string
   "^\\([ \t]*\\)\\(\\*+ \\|#\\+\\|:[[:alnum:]_]+:[ \t]*$\\)"
   (lambda (line)
     (save-match-data
       (let ((start (string-match "[^ \t]" line)))
         (if (get-text-property start 'zr-org-srs-x--dictionary-heading line)
             line
           (concat (substring line 0 start) "," (substring line start))))))
   text t t))

(defun zr-org-srs-x--note-id ()
  "Return the current entry's canonical positive integer ID, or nil."
  (when-let* ((id (org-entry-get nil "ID"))
              ((string-match-p "\\`[1-9][0-9]*\\'" id)))
    (string-to-number id)))

(defun zr-org-srs-x--check-duplicate (title options &optional exclude-id)
  "Reject note when TITLE already exists unless OPTIONS allow duplicates.
Ignore the card with EXCLUDE-ID when finalizing its capture.
Always scan existing Org headings to keep `zr-org-srs-x--last-id'
strictly increasing."
  (let (duplicate)
    (dolist (file (zr-org-srs-x--files))
      (with-current-buffer (zr-org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (org-map-entries
             (lambda ()
               (when-let* ((id (zr-org-srs-x--note-id)))
                 (setq zr-org-srs-x--last-id (max (or zr-org-srs-x--last-id 0) id)))
               (when (and (equal (org-get-heading t) title)
                          (not (and exclude-id
                                    (equal (org-entry-get nil "ID") exclude-id))))
                 (setq duplicate t)))
             "LEVEL=1" 'file)))))
    (when (and duplicate (not (and (hash-table-p options) (eq (gethash "allowDuplicate" options) t))))
      (error "cannot create note because it is a duplicate"))))

(defun zr-org-srs-x--insert-card (card id &optional tags)
  "Insert rendered CARD with integer ID and TAGS at point as an Org-srs card."
  (let ((position (point)))
    (insert "* " (replace-regexp-in-string
                  "[\n\r\t]+" " " (alist-get 'name card)) "\n"
            "** Front\n" (zr-org-srs-x--body (alist-get 'front card)) "\n\n"
            "** Back\n" (zr-org-srs-x--body (alist-get 'back card)) "\n")
    (goto-char position)
    (org-entry-put nil "ID" (number-to-string id))
    (org-set-tags
     (delete-dups
      (mapcar (lambda (tag) (replace-regexp-in-string
                             "[^[:alnum:]_@#%]" "_" tag))
              (append tags nil))))
    (org-srs-item-new 'card)))

(defun zr-org-srs-x--create-card (buffer model-name fields &optional note)
  "Create a card in BUFFER from Org FIELDS and return its integer ID.
Render with MODEL-NAME, or the t renderer when nil.  An optional Anki NOTE
supplies attachments, tags and duplicate options."
  (require 'org-srs)
  (with-current-buffer buffer
    (let* ((file buffer-file-name)
           (note (or note (zr-org-srs-x--object)))
           (tags (zr-org-srs-x--strings (gethash "tags" note [])))
           (options (gethash "options" note (zr-org-srs-x--object)))
           (renderer (zr-org-srs-x--model-renderer model-name))
           (zr-dictionary-dictionaries (zr-org-srs-x--dictionaries renderer))
           (definitions (if (zr-org-srs-x--uses-dictionary-p renderer)
                            (zr-org-srs-x--dictionary-text
                             (alist-get "word" fields (cdar fields) nil #'equal))
                          ""))
           (variables (cons (cons 'dictionary definitions)
                            (zr-org-srs-x--import-media note fields file)))
           (card (zr-org-srs-x--render model-name fields variables))
           (title (replace-regexp-in-string
                   "[\n\r\t]+" " " (alist-get 'name card)))
           (id (progn
                 ;; Dictionary waits may dispatch another capture request.
                 ;; Refresh existing IDs before allocating this card's ID.
                 (zr-org-srs-x--check-duplicate title options)
                 (zr-org-srs-x--new-id))))
      (save-excursion
        (save-restriction
          (widen)
          (atomic-change-group
            (goto-char (point-max))
            (when (= (point-min) (point-max))
              (insert "#+title: " (zr-org-srs-x--deck-name file) "\n"))
            (unless (bolp) (insert "\n"))
            (insert "\n")
            (zr-org-srs-x--insert-card card id tags)
            (zr-org-srs-x--save))))
      id)))

(defun zr-org-srs-x--add-note (note)
  "Import one Anki NOTE and return its integer ID."
  (require 'org-srs)
  (let* ((model-name (zr-org-srs-x--string (zr-org-srs-x--get note "modelName")))
         (deck (or (zr-org-srs-x--get note "deckName")
                   (zr-org-srs-x--default-deck model-name)))
         (file (zr-org-srs-x--deck-file deck))
         (model (or (gethash model-name zr-org-srs-x--models)
                    (error "Model was not found: %s" model-name)))
         (input (zr-org-srs-x--get note "fields"))
         (names (gethash "inOrderFields" model)))
    (unless (hash-table-p input)
      (error "Expected note fields"))
    (maphash (lambda (name value)
               (unless (member name (append names nil))
                 (error "Unknown field: %s" name))
               (zr-org-srs-x--string value))
             input)
    (when (string-blank-p (zr-org-srs-x--html (gethash (aref names 0) input "")))
      (error "cannot create note because it is empty"))
    ;; Discard the client's dictionary pages before HTML conversion.
    (zr-org-srs-x--create-card
     (zr-org-srs-x--buffer file) model-name
     (cl-loop for name across names
              unless (member name '("dictionaryInfo" "dictionaryContent"))
              collect (cons name (zr-org-srs-x--html (gethash name input ""))))
     note)))

(defun zr-org-srs-x--find-notes (query)
  "Find integer note IDs for QUERY, supporting deck and word/w filters.
Word filters match the complete heading, excluding tags but preserving
TODO keywords, priorities and COMMENT.  An empty query returns every
canonical positive integer note ID.  Other Anki search syntax
is rejected rather than interpreted as an unfiltered query."
  (zr-org-srs-x--string query)
  (let (deck word (results nil))
    (unless (string-empty-p query)
      (unless (string-match
               "\\`deck:\\(?:\"\\([^\"]+\\)\"\\|\\([^ \t]+\\)\\)\\(?: +\\(?:w\\|word\\):\"\\([^\"]*\\)\"\\)?\\'"
               query)
        (error "Unsupported note query: %s" query))
      (setq deck (or (match-string 1 query) (match-string 2 query))
            word (match-string 3 query)))
    (dolist (file (if deck (list (zr-org-srs-x--deck-file deck)) (zr-org-srs-x--files)))
      (when (file-exists-p file)
        (with-current-buffer (zr-org-srs-x--buffer file)
          (save-excursion
            (save-restriction
              (widen)
              (org-map-entries
               (lambda ()
                 (when-let* ((id (zr-org-srs-x--note-id)))
                   (setq zr-org-srs-x--last-id (max (or zr-org-srs-x--last-id 0) id))
                   (when (or (not word)
                             (equal (org-get-heading t) word))
                     (push id results))))
               "LEVEL=1" 'file))))))
    (nreverse results)))

(defun zr-org-srs-x--delete-notes (ids)
  "Delete note subtrees matching integer IDS."
  (unless (and (vectorp ids) (cl-every #'integerp ids))
    (error "Expected an array of note IDs"))
  (let ((id-strings (mapcar #'number-to-string (append ids nil))))
    (dolist (file (zr-org-srs-x--files))
      (with-current-buffer (zr-org-srs-x--buffer file)
        (save-excursion
          (save-restriction
            (widen)
            (let ((markers nil))
              (org-map-entries
               (lambda ()
                 (when-let* ((id (org-entry-get nil "ID"))
                             ((member id id-strings)))
                   (push (point-marker) markers)))
               "LEVEL=1" 'file)
              (when markers
                (atomic-change-group
                  (dolist (marker markers)
                    (goto-char marker)
                    (delete-region (point) (save-excursion (org-end-of-subtree t t) (point)))
                    (set-marker marker nil))
                  (when (buffer-modified-p)
                    (zr-org-srs-x--save))))))))))
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
             (params (gethash "params" request (zr-org-srs-x--object))))
        (unless (eql version 6)
          (error "Only AnkiConnect version 6 is supported"))
        (unless (hash-table-p params)
          (error "Expected a params object"))
        (let ((result (zr-org-srs-x--dispatch action params)))
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

(defun zr-org-srs-x--current-deck ()
  "Return the current buffer's deck name, or nil outside a deck Org file."
  (when (and buffer-file-name (derived-mode-p 'org-mode)
             (equal (file-name-extension buffer-file-name) "org")
             (file-in-directory-p buffer-file-name zr-org-srs-x-directory))
    (zr-org-srs-x--deck-name buffer-file-name)))

;;;###autoload
(defun zr-org-srs-x-capture-template (&optional key description)
  "Return an Org capture template for selected dictionary results.
KEY defaults to \"d\" and DESCRIPTION to \"Dictionary card\".  Add the result
to `org-capture-templates'.  Capture the complete dictionary at point, or
all dictionaries intersecting the active region, as one card.  Use the t
entry in `zr-org-srs-x-model-alist' and its deck, falling back to
`zr-org-srs-x-default-deck'.  Reuse displayed definitions without lookup;
dict links retain the source query's dictionary stages and strategy."
  (list (or key "d") (or description "Dictionary card") 'entry
        '(file zr-org-srs-x--capture-file)
        '(function zr-org-srs-x--capture-prepare)
        :empty-lines 1 :hook #'zr-org-srs-x--capture-insert
        :before-finalize #'zr-org-srs-x--capture-check-duplicate))

;;;###autoload
(defun zr-org-srs-x-capture-dictionary ()
  "Capture dictionaries at point or in the region as one Org-srs card."
  (interactive)
  (require 'org-capture)
  (let ((org-capture-entry (zr-org-srs-x-capture-template)))
    (org-capture)))

(define-key dictionary-mode-map "c" #'zr-org-srs-x-capture-dictionary)

(defun zr-org-srs-x--capture-file ()
  "Return the prepared capture file or the t renderer's default deck file."
  (let ((file (or (org-capture-get :zr-org-srs-x-file)
                  (zr-org-srs-x--deck-file (zr-org-srs-x--default-deck nil)))))
    (zr-org-srs-x--buffer file t)
    file))

(defun zr-org-srs-x--capture-prepare ()
  "Prepare a card from the source buffer and return a capture placeholder."
  (let* ((entries (zr-dictionary-selected-entries))
         (fields (list (cons "word" zr-dictionary-word)))
         (definitions (zr-org-srs-x--dictionary-text zr-dictionary-word entries))
         (file (zr-org-srs-x--deck-file (zr-org-srs-x--default-deck nil)))
         (buffer (zr-org-srs-x--buffer file t))
         (text
          (with-current-buffer buffer
            (require 'org-srs)
            (let* ((card (zr-org-srs-x--render
                          nil fields `((dictionary . ,definitions)
                                       (picture . "") (audio . "") (video . ""))))
                   (title (replace-regexp-in-string
                           "[\n\r\t]+" " " (alist-get 'name card)))
                   (id (progn (zr-org-srs-x--check-duplicate title nil)
                              (zr-org-srs-x--new-id))))
              (with-temp-buffer
                (org-mode)
                (org-clone-local-variables buffer "\\`org-srs-")
                (zr-org-srs-x--insert-card card id)
                (buffer-string))))))
    (org-capture-put :zr-org-srs-x-file file :zr-org-srs-x-card text)
    "* %?\n"))

(defun zr-org-srs-x--capture-insert ()
  "Replace the capture placeholder with the prepared card's literal text."
  ;; Insert after template expansion so definitions and URL escapes stay literal.
  (delete-region (point-min) (point-max))
  (insert (org-capture-get :zr-org-srs-x-card t))
  (goto-char (point-min)))

(defun zr-org-srs-x--capture-check-duplicate ()
  "Check the edited capture heading for duplicates before saving."
  (save-excursion
    (goto-char (org-capture-get :begin-marker t))
    (unless (org-at-heading-p) (outline-next-heading))
    (zr-org-srs-x--check-duplicate
     (org-get-heading t) nil (org-entry-get nil "ID"))))

;;;###autoload
(defun zr-org-srs-x-create-card (word &optional deck)
  "Create and save a card for WORD in DECK, returning its integer ID.
Use the t entry in `zr-org-srs-x-model-alist' with a single word field
and definitions from the deck's dictionary configuration.
Default DECK to the t entry's deck, the current deck, or
`zr-org-srs-x-default-deck', in that order.
Interactively, suggest the region or word at point.  Outside a deck,
prompt for the deck; with a prefix argument, always prompt for it.
Create the deck if needed, and display the new card after manual capture."
  (interactive
   (let* ((word (read-string
                 "Card word: " nil nil
                 (if (use-region-p)
                     (buffer-substring-no-properties (region-beginning) (region-end))
                   (thing-at-point 'word t))))
          (current-deck (zr-org-srs-x--current-deck))
          (default-deck (zr-org-srs-x--default-deck nil current-deck)))
     (list word
           (if (and current-deck (not current-prefix-arg))
               default-deck
             (completing-read
              "Deck: " (mapcar #'zr-org-srs-x--deck-name (zr-org-srs-x--files))
              nil nil nil nil default-deck)))))
  (unless (and (stringp word) (not (string-blank-p word))
               (not (string-match-p "[\r\n]" word)))
    (user-error "Card word must be nonempty and on one line"))
  (require 'org-srs)
  (let* ((deck (or deck (zr-org-srs-x--default-deck nil (zr-org-srs-x--current-deck))))
         (buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file deck) t))
         (id (zr-org-srs-x--create-card buffer nil (list (cons "word" (string-trim word))))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer)
      (goto-char (org-find-property "ID" (number-to-string id)))
      (org-fold-show-context)
      (org-fold-show-subtree)
      (message "Created card %s in %s" id deck))
    id))

(defun zr-org-srs-x-protocol-create-card (info)
  "Create a card from Org protocol INFO containing :word and optional :deck.
Use the t entry's deck or `zr-org-srs-x-default-deck' when :deck is absent.
Return nil so the request is consumed instead of being treated as a filename."
  (require 'org-protocol)
  (let* ((parameters (org-protocol-parse-parameters info t))
         (deck (or (plist-get parameters :deck) (zr-org-srs-x--default-deck nil)))
         (id (zr-org-srs-x-create-card (plist-get parameters :word) deck)))
    (message "Created card %s in %s" id deck))
  nil)

;;;###autoload
(define-minor-mode zr-org-srs-x-protocol-mode
  "Register org-protocol://srs-card?word=WORD&deck=DECK capture."
  :global t
  (if zr-org-srs-x-protocol-mode
      (progn
        (require 'org-protocol)
        (unless zr-org-srs-x--protocol-entry
          (setq zr-org-srs-x--protocol-entry
                '("zr srs card" :protocol "srs-card"
                  :function zr-org-srs-x-protocol-create-card :kill-client t))
          (push zr-org-srs-x--protocol-entry org-protocol-protocol-alist)))
    (when zr-org-srs-x--protocol-entry
      (setq org-protocol-protocol-alist
            (delq zr-org-srs-x--protocol-entry org-protocol-protocol-alist)
            zr-org-srs-x--protocol-entry nil))))

(defun zr-org-srs-x--update-card-dictionaries ()
  "Replace dictionary subheadings in the card at point.
Use the card title and the current buffer's dictionary configuration.
Level-three subheadings under Front and Back contain the definitions."
  (save-restriction
    (org-narrow-to-subtree)
    (let ((word (org-get-heading t)) back regions)
      (org-map-entries
       (lambda ()
         (when (member (org-get-heading t) '("Front" "Back"))
           (when (equal (org-get-heading t) "Back")
             (setq back (point)))
           (let ((end (save-excursion (org-end-of-subtree t t) (point))))
             (when (re-search-forward "^\\*\\*\\* " end t)
               (let ((start (line-beginning-position)))
                 (goto-char start)
                 (skip-chars-backward "\n \t")
                 (beginning-of-line)
                 (when (looking-at-p "\\[\\[dict:[^\n]+\\]\\][ \t]*$")
                   (setq start (point)))
                 (push (cons start end) regions))))))
       "LEVEL=2")
      (unless back
        (user-error "Card has no Back heading"))
      (let ((definitions (zr-org-srs-x--body (zr-org-srs-x--dictionary-text word))))
        (if regions
            ;; Work backwards so earlier region boundaries stay valid.
            (dolist (region regions)
              (goto-char (car region))
              (delete-region (point) (cdr region))
              (unless (string-empty-p definitions)
                (insert definitions "\n")))
          (unless (string-empty-p definitions)
            (goto-char back)
            (org-end-of-subtree t t)
            (unless (bolp) (insert "\n"))
            (insert "\n" definitions "\n")))))))

;;;###autoload
(defun zr-org-srs-x-update-dictionaries (&optional beg end)
  "Overwrite dictionaries in the current card or cards intersecting BEG END.
Interactively, use the active region when present, otherwise the card at
point, including when point is in a Front, Back or dictionary subheading.
Look up each card's title using the current `zr-dictionary-dictionaries'.
Replace its level-three dictionary subheadings; if absent, append to Back.
Nil configuration or no definitions removes the old dictionaries.
Preserve other card content and review logs.  Leave the buffer unsaved.
Roll back all changes if any lookup or update fails."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "This command requires an Org buffer"))
  (barf-if-buffer-read-only)
  (save-excursion
    (save-restriction
      (widen)
      (let ((cards
             (if (and beg end)
                 (delq nil
                       (org-map-entries
                        (lambda ()
                          (when (and (< (point) end)
                                     (> (save-excursion (org-end-of-subtree t t) (point)) beg)
                                     (zr-org-srs-x--note-id))
                            (copy-marker (point) t)))
                        "LEVEL=1"))
               (unless (org-before-first-heading-p)
                 (org-back-to-heading t)
                 (while (org-up-heading-safe))
                 (when (and (= (org-outline-level) 1) (zr-org-srs-x--note-id))
                   (list (copy-marker (point) t)))))))
        (unless cards
          (user-error "No zr-org-srs-x card found"))
        (unwind-protect
            (atomic-change-group
              (dolist (card cards)
                (goto-char card)
                (zr-org-srs-x--update-card-dictionaries)))
          (dolist (card cards) (set-marker card nil)))
        (when (called-interactively-p 'interactive)
          (message "Updated dictionaries in %d card(s)" (length cards)))))))

(provide 'zr-org-srs-x)
;;; zr-org-srs-x.el ends here
