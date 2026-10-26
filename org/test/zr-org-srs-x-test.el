;;; zr-org-srs-x-test.el --- Tests for Org-srs AnkiConnect capture -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url-util)
(require 'zr-test-helpers)
(require 'zr-org-srs-x)

(defun zr-org-srs-x-test--require-srs ()
  "Load the installed Org-srs and FSRS packages without personal init files."
  (let* ((elpa (expand-file-name "elpa" user-emacs-directory))
         (load-path (append
                     (when (file-directory-p elpa)
                       (directory-files elpa t "\\`\\(?:org-srs\\|fsrs\\)-"))
                     load-path)))
    (unless (require 'org-srs nil t)
      (ert-skip "org-srs is not installed"))))

(defmacro zr-org-srs-x-test--with-decks (&rest body)
  (declare (indent 0) (debug t))
  `(zr-test-with-temp-directory
    (let ((zr-org-srs-x-directory (expand-file-name "srs"))
          (zr-org-srs-x-dictionaries nil)
          (zr-org-srs-x-media-path-function #'identity)
          (zr-org-srs-x-render-function #'zr-org-srs-x-render-luna-note)
          (zr-org-srs-x--server nil)
          (zr-org-srs-x--clients nil)
          (zr-org-srs-x--last-id 0))
      (unwind-protect
          (progn ,@body)
        (zr-org-srs-x-stop)))))

(defun zr-org-srs-x-test--call (action &rest pairs)
  "Invoke ACTION with parameter PAIRS, returning its successful result."
  (let ((response (zr-org-srs-x-request
                   (zr-org-srs-x--object "action" action "version" 6
                                         "params" (apply #'zr-org-srs-x--object pairs)))))
    (should-not (gethash "error" response))
    (gethash "result" response)))

(defun zr-org-srs-x-test--create-model ()
  (zr-org-srs-x-test--call
   "createModel" "modelName" "modelofluna"
   "inOrderFields" ["word" "rubytextHtml" "example_sentence" "audio_for_word"
                    "audio_for_example_sentence" "screenshot" "remarks"
                    "dictionaryInfo" "dictionaryContent" "user_custom_1"]
   "css" ".card {}" "isCloze" :false
   "cardTemplates" (vector (zr-org-srs-x--object "Name" "LUNACARDTEMPLATE1"
                                                 "Front" "{{word}}" "Back" "{{remarks}}"))))

(defun zr-org-srs-x-test--note (deck &optional word)
  "Return a LunaTranslator note for DECK, with two dictionary results."
  (zr-org-srs-x--object
   "deckName" deck "modelName" "modelofluna" "tags" ["日本語" "game:one"]
   "options" (zr-org-srs-x--object "allowDuplicate" t)
   "fields" (zr-org-srs-x--object
             "word" (or word "猫") "rubytextHtml" "ねこ"
             "example_sentence" "<b>猫</b>です。<br>二行目"
             "remarks" "備考 &amp; メモ" "user_custom_1" "extra"
             "dictionaryInfo"
             (zr-org-srs-x--json (vector (zr-org-srs-x--object "dict" "edict" "name" "英和辞典")
                                         (zr-org-srs-x--object "dict" "local" "name" "国語辞典")))
             "dictionaryContent"
             (zr-org-srs-x--json
              (zr-org-srs-x--object "edict" (url-hexify-string "<div>cat; feline</div>")
                                    "local" (url-hexify-string "<p>ネコ科の動物</p><script>SECRET_SCRIPT</script>"))))))

(ert-deftest zr-org-srs-x-test-model-lifecycle-and-persistence ()
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (should (equal (zr-org-srs-x-test--call "modelNames") ["modelofluna"]))
   (should (= (length (zr-org-srs-x-test--call "modelFieldNames" "modelName" "modelofluna")) 10))
   (let ((response (zr-org-srs-x-request
                    (zr-org-srs-x--object "action" "createModel" "params"
                                          (zr-org-srs-x--object "modelName" "modelofluna"
                                                                "inOrderFields" [])))))
     (should (equal (gethash "error" response) "Model name already exists")))
   (zr-org-srs-x-test--call "updateModelStyling" "model"
                            (zr-org-srs-x--object "name" "modelofluna" "css" "new css"))
   (zr-org-srs-x-test--call "updateModelTemplates" "model"
                            (zr-org-srs-x--object
                             "name" "modelofluna" "templates"
                             (zr-org-srs-x--object "LUNACARDTEMPLATE1"
                                                   (zr-org-srs-x--object "Front" "new front" "Back" "new back"))))
   (let ((model (gethash "modelofluna" (zr-org-srs-x--read-data ".zr-org-srs-x.json"))))
     (should (equal (gethash "templateName" model) "LUNACARDTEMPLATE1"))
     (should-not (gethash "css" model))
     (should-not (gethash "cardTemplates" model))
     (should (= (hash-table-count model) 4)))))

(ert-deftest zr-org-srs-x-test-deck-files-and-existing-decks ()
  (zr-org-srs-x-test--with-decks
   (make-directory zr-org-srs-x-directory t)
   (with-temp-file (expand-file-name "已有.org" zr-org-srs-x-directory)
     (insert "#+title: 既存\n* 手工笔记\n正文\n"))
   (let ((first (zr-org-srs-x-test--call "createDeck" "deck" "日本語::ゲーム")))
     (should (integerp first))
     (should (= first (zr-org-srs-x-test--call "createDeck" "deck" "日本語::ゲーム")))
     (should (= first (gethash "日本語::ゲーム" (zr-org-srs-x-test--call "deckNamesAndIds"))))
     (should (file-exists-p (expand-file-name "日本語/ゲーム.org" zr-org-srs-x-directory))))
   (should (member "已有" (append (zr-org-srs-x-test--call "deckNames") nil)))
   (dolist (name '("../escape" ".." "a::..::b" "a::::b" "a\\b" "a\nb"))
     (should-error (zr-org-srs-x--deck-file name)))))

(ert-deftest zr-org-srs-x-test-real-card-and-dictionary-selection-by-file ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "英語")
   (zr-org-srs-x-test--call "createDeck" "deck" "日本語")
   (setq zr-org-srs-x-dictionaries '(("英語.org" "edict") ("日本語.org" "国語辞典")))
   (dolist (deck '("英語" "日本語"))
     (let* ((note (zr-org-srs-x-test--note deck))
            (id (zr-org-srs-x-test--call "addNote" "note" note))
            (file (zr-org-srs-x--deck-file deck)))
       (should (integerp id))
       (with-current-buffer (zr-org-srs-x--buffer file)
         (goto-char (point-min))
         (re-search-forward "^\\* ")
         (org-back-to-heading)
         (should (org-entry-get nil "ID"))
         (let ((entry (gethash (org-entry-get nil "ID")
                               (zr-org-srs-x--read-data ".zr-org-srs-x-notes.json"))))
           (should (= (gethash "noteId" entry) id))
           (should (equal (gethash "modelName" entry) "modelofluna")))
         (should-not (string-match-p "^:ANKI_" (buffer-string)))
         (should (equal (org-get-tags) '("日本語" "game_one")))
         (should (= (length (org-srs-query-buffer (org-srs-query-predicate-new))) 1))
         (should (org-srs-item-exists-p '(card back)))
         (cl-multiple-value-bind (front back) (org-srs-item-card-regions)
           (let ((front-text (buffer-substring-no-properties (car front) (cdr front)))
                 (back-text (buffer-substring-no-properties (car back) (cdr back))))
             (should (string-match-p "猫.*\n" front-text))
             (should (string-match-p "二行目" front-text))
             (should (string-match-p "ねこ" back-text))
             (should (string-match-p "備考 & メモ" back-text))
             (should (string-match-p "extra" back-text))
             (should-not (string-match-p "SECRET_SCRIPT" back-text))
             (if (equal deck "英語")
                 (progn (should (string-match-p "cat; feline" back-text))
                        (should-not (string-match-p "ネコ科" (buffer-string))))
               (should (string-match-p "ネコ科の動物" back-text))
               (should-not (string-match-p "cat; feline" (buffer-string))))))
         (should (< (file-attribute-size
                     (file-attributes (expand-file-name ".zr-org-srs-x-notes.json"
                                                        zr-org-srs-x-directory)))
                    1024)))))))

(ert-deftest zr-org-srs-x-test-file-keyword-overrides-and-empty-selection ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (setq zr-org-srs-x-dictionaries '(("lunadeck.org" "edict")))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (goto-char (point-min))
     (insert "#+SRS_X_DICTIONARIES: []\n")
     (zr-org-srs-x--save))
   (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (should-not (string-match-p "cat; feline\\|ネコ科\\|英和辞典\\|国語辞典" (buffer-string)))
     (goto-char (point-min))
     (re-search-forward "^\\* ")
     (org-back-to-heading)
     (should-not (string-match-p "^:ANKI_" (buffer-string))))))

(ert-deftest zr-org-srs-x-test-unconfigured-file-keeps-multiple-dictionaries ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (should (string-match-p "cat; feline" (buffer-string)))
     (should (string-match-p "ネコ科の動物" (buffer-string))))))

(ert-deftest zr-org-srs-x-test-media-import-with-client-path-mapping ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((source (expand-file-name "audio.mp3"))
          (bytes (unibyte-string 0 255 128 10))
          (zr-org-srs-x-media-path-function (lambda (path)
                                              (should (equal path "C:\\audio.mp3")) source))
          (note (zr-org-srs-x-test--note "lunadeck")))
     (let ((coding-system-for-write 'no-conversion))
       (write-region bytes nil source nil 'silent))
     (puthash "audio" (vector (zr-org-srs-x--object "filename" "audio.mp3" "path" "C:\\audio.mp3"
                                                    "fields" ["audio_for_word"])) note)
     (puthash "picture" (vector (zr-org-srs-x--object "filename" "../image.png"
                                                      "data" (base64-encode-string bytes t)
                                                      "fields" ["screenshot"])) note)
     (zr-org-srs-x-test--call "addNote" "note" note)
     (let ((medias (directory-files (expand-file-name "lunadeck.media" zr-org-srs-x-directory)
                                    t "\\.\\(?:mp3\\|png\\)\\'")))
       (should (= (length medias) 2))
       (dolist (media medias)
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (insert-file-contents-literally media)
           (should (equal bytes (buffer-string))))))
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
       (should (string-match-p "\\[\\[file:lunadeck.media/.*mp3\\]\\[Audio\\]\\]" (buffer-string)))
       (should (string-match-p "\\[\\[file:lunadeck.media/.*png\\]\\]" (buffer-string)))))))

(ert-deftest zr-org-srs-x-test-duplicate-find-delete-and-restart-ids ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((note (zr-org-srs-x-test--note "lunadeck"))
          (first (zr-org-srs-x-test--call "addNote" "note" note)))
     (puthash "options" (zr-org-srs-x--object "allowDuplicate" :false) note)
     (let ((response (zr-org-srs-x-request (zr-org-srs-x--object "action" "addNote" "params"
                                                                 (zr-org-srs-x--object "note" note)))))
       (should (equal (gethash "error" response) "cannot create note because it is a duplicate")))
     (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"lunadeck\" w:\"猫\"")
                    (vector first)))
     (setq zr-org-srs-x--last-id 0)
     (let ((second (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "犬"))))
       (should (> second first))
       (zr-org-srs-x-test--call "deleteNotes" "notes" (vector first))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") (vector second)))
       (zr-org-srs-x-test--call "deleteNotes" "notes" (vector second))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") []))
       (should (= (hash-table-count (zr-org-srs-x--read-data ".zr-org-srs-x-notes.json")) 0)))
     (zr-org-srs-x-test--call "addNote" "note" note))))

(ert-deftest zr-org-srs-x-test-save-failure-rolls-back-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck")))
          (before (with-current-buffer buffer (buffer-string))))
     (cl-letf (((symbol-function 'zr-org-srs-x--save) (lambda () (error "disk full"))))
       (let ((response (zr-org-srs-x-request
                        (zr-org-srs-x--object "action" "addNote" "params"
                                              (zr-org-srs-x--object "note" (zr-org-srs-x-test--note "lunadeck"))))))
         (should (equal (gethash "error" response) "disk full"))))
     (should (equal before (with-current-buffer buffer (buffer-string))))
     (should (= (hash-table-count (zr-org-srs-x--read-data ".zr-org-srs-x-notes.json")) 0)))))

(ert-deftest zr-org-srs-x-test-index-save-failure-does-not-save-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((file (zr-org-srs-x--deck-file "lunadeck"))
          (buffer (zr-org-srs-x--buffer file))
          (before (with-current-buffer buffer (buffer-string)))
          (write-data (symbol-function 'zr-org-srs-x--write-data)))
     (cl-letf (((symbol-function 'zr-org-srs-x--write-data)
                (lambda (name data)
                  (if (equal name ".zr-org-srs-x-notes.json")
                      (error "index is read-only")
                    (funcall write-data name data)))))
       (let ((response (zr-org-srs-x-request
                        (zr-org-srs-x--object "action" "addNote" "params"
                                              (zr-org-srs-x--object "note" (zr-org-srs-x-test--note "lunadeck"))))))
         (should (equal (gethash "error" response) "index is read-only"))))
     (should (equal before (with-current-buffer buffer (buffer-string))))
     (should (equal before (with-temp-buffer (insert-file-contents file) (buffer-string))))
     (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") [])))))

(ert-deftest zr-org-srs-x-test-large-dictionary-html-is-rendered-and-discarded ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((note (zr-org-srs-x-test--note "lunadeck" "official"))
          (fields (gethash "fields" note))
          (content (zr-org-srs-x--parse (gethash "dictionaryContent" fields))))
     ;; Real dictionary pages include hundreds of KB of styles and scripts.
     (puthash "edict"
              (url-hexify-string
               (concat "<html><head><style>"
                       (apply #'concat (make-list 20000 ".style { color: red; }\n"))
                       "</style></head><body><p>Large-page definition</p>"
                       "<script>" (make-string 100000 ?b) "</script></body></html>"))
              content)
     (puthash "dictionaryContent" (zr-org-srs-x--json content) fields)
     (let ((id (zr-org-srs-x-test--call "addNote" "note" note))
           (file (zr-org-srs-x--deck-file "lunadeck")))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"lunadeck\" w:\"official\"")
                      (vector id)))
       (with-current-buffer (zr-org-srs-x--buffer file)
         (should (string-match-p "Large-page definition" (buffer-string)))
         (should (string-match-p "ネコ科の動物" (buffer-string)))
         (should-not (string-match-p "^:ANKI_\\|dictionaryContent\\|<style>\\|<script>" (buffer-string)))
         (should (< (buffer-size) 8192))
         (should (= (length (org-srs-query-buffer (org-srs-query-predicate-new))) 1)))
       (let ((index (expand-file-name ".zr-org-srs-x-notes.json" zr-org-srs-x-directory)))
         (should (< (file-attribute-size (file-attributes index)) 1024))
         (with-temp-buffer
           (insert-file-contents index)
           (should-not (string-match-p "dictionaryContent\\|Large-page definition\\|SECRET_SCRIPT" (buffer-string)))))))))

(ert-deftest zr-org-srs-x-test-percent-decoding-preserves-unicode-and-newlines ()
  (should
   (equal (zr-org-srs-x--decode-dictionary
           (concat (apply #'concat (make-list 20000 "%E7%8c%AB")) "%0A+%25%zz"))
          (concat (make-string 20000 ?猫) "\n+%%zz"))))

(ert-deftest zr-org-srs-x-test-first-field-duplicates-and-word-search-use-separate-hashes ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--call
    "createModel" "modelName" "custom" "inOrderFields" ["prompt" "word"]
    "css" "" "isCloze" :false
    "cardTemplates" (vector (zr-org-srs-x--object "Name" "Card" "Front" "" "Back" "")))
   (zr-org-srs-x-test--call "createDeck" "deck" "custom")
   (let* ((note (zr-org-srs-x--object "deckName" "custom" "modelName" "custom"
                                      "fields" (zr-org-srs-x--object "prompt" "first prompt" "word" "猫")))
          (first (zr-org-srs-x-test--call "addNote" "note" note)))
     (puthash "word" "犬" (gethash "fields" note))
     (let ((response (zr-org-srs-x-request
                      (zr-org-srs-x--object "action" "addNote" "params"
                                            (zr-org-srs-x--object "note" note)))))
       (should (equal (gethash "error" response) "cannot create note because it is a duplicate")))
     (puthash "prompt" "second prompt" (gethash "fields" note))
     (let ((second (zr-org-srs-x-test--call "addNote" "note" note)))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"custom\" w:\"猫\"")
                      (vector first)))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"custom\" w:\"犬\"")
                      (vector second)))))))

(ert-deftest zr-org-srs-x-test-content-cannot-create-extra-org-structure ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((note (zr-org-srs-x-test--note "lunadeck")))
     (puthash "remarks" "<p>* new heading</p><p>#+begin_src emacs-lisp</p><p>:END:</p>"
              (gethash "fields" note))
     (zr-org-srs-x-test--call "addNote" "note" note))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (let ((headings nil))
       (org-map-entries (lambda () (push (org-get-heading t t t t) headings)) nil 'file)
       (should (equal (nreverse headings) '("猫" "Front" "Back"))))
     (should (string-match-p ",#\\+begin_src" (buffer-string)))
     (should (string-match-p ",:END:" (buffer-string))))))

(defun zr-org-srs-x-test--http (parts)
  "Send binary HTTP PARTS to the real server and return the HTTP response."
  (let* ((output "")
         (client (make-network-process
                  :name "zr-org-srs-x-test-client" :host "127.0.0.1"
                  :service (process-contact zr-org-srs-x--server :service)
                  :coding 'binary :noquery t
                  :filter (lambda (_process chunk) (setq output (concat output chunk)))))
         (deadline (+ (float-time) 5)))
    (unwind-protect
        (progn
          (dolist (part parts)
            (process-send-string client part)
            (accept-process-output nil 0.02))
          (while (and (process-live-p client) (< (float-time) deadline))
            (accept-process-output nil 0.02))
          (should (not (process-live-p client)))
          output)
      (when (process-live-p client) (delete-process client)))))

(defun zr-org-srs-x-test--http-json (http)
  (should (string-match "\r\n\r\n" http))
  (zr-org-srs-x--parse (decode-coding-string (substring http (match-end 0)) 'utf-8)))

(ert-deftest zr-org-srs-x-test-real-http-get-post-fragments-and-errors ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (let ((zr-org-srs-x-port 0))
     (zr-org-srs-x-start)
     (should (eq (zr-org-srs-x-start) zr-org-srs-x--server))
     (dolist (method '("GET" "POST"))
       (let* ((body (encode-coding-string
                     (zr-org-srs-x--json (zr-org-srs-x--object "action" "createDeck" "version" 6 "params"
                                                               (zr-org-srs-x--object "deck" "日本語"))) 'utf-8))
              (http (zr-org-srs-x-test--http
                     (list (format "%s / HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n" method (length body))
                           "\r\n" (substring body 0 20) (substring body 20 21) (substring body 21)))))
         (should (string-prefix-p "HTTP/1.1 200 OK" http))
         (should (integerp (gethash "result" (zr-org-srs-x-test--http-json http))))))
     (let ((http (zr-org-srs-x-test--http '("GET / HTTP/1.1\r\nContent-Length: 1\r\n\r\n{"))))
       (should (string-prefix-p "HTTP/1.1 400 Bad Request" http))
       (should (stringp (gethash "error" (zr-org-srs-x-test--http-json http)))))
     (let ((zr-org-srs-x-max-request-size 10))
       (should (string-prefix-p "HTTP/1.1 413 Payload Too Large"
                                (zr-org-srs-x-test--http '("GET / HTTP/1.1\r\nContent-Length: 11\r\n\r\n")))))
     (dolist (headers '("Content-Length: -1\r\n" "Content-Length: 0\r\nContent-Length: 0\r\n"
                        "Transfer-Encoding: chunked\r\n"))
       (should (string-prefix-p "HTTP/1.1 400 Bad Request"
                                (zr-org-srs-x-test--http (list (concat "GET / HTTP/1.1\r\n" headers "\r\n"))))))
     (should-not zr-org-srs-x--clients)
     (let ((server zr-org-srs-x--server))
       (zr-org-srs-x-stop)
       (should-not (process-live-p server))
       (zr-org-srs-x-stop)))))

(ert-deftest zr-org-srs-x-test-api-errors-have-anki-envelope ()
  (zr-org-srs-x-test--with-decks
   (dolist (request (list (zr-org-srs-x--object "action" "sync")
                          (zr-org-srs-x--object "action" "version" "version" 5)
                          (zr-org-srs-x--object "action" "version" "params" [])
                          []))
     (let ((response (zr-org-srs-x-request request)))
       (should (= (hash-table-count response) 2))
       (should-not (gethash "result" response))
       (should (stringp (gethash "error" response)))))
   (should-not (file-exists-p zr-org-srs-x-directory))))

(provide 'zr-org-srs-x-test)
;;; zr-org-srs-x-test.el ends here

(provide 'zr-org-srs-x-test)
;;; zr-org-srs-x-test.el ends here
