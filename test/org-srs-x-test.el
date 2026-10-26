;;; org-srs-x-test.el --- Tests for Org-srs AnkiConnect capture -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-test-helpers)
(require 'org-srs-x)

(defun org-srs-x-test--require-srs ()
  "Load the installed Org-srs and FSRS packages without personal init files."
  (let* ((elpa (expand-file-name "elpa" user-emacs-directory))
         (load-path (append
                     (when (file-directory-p elpa)
                       (directory-files elpa t "\\`\\(?:org-srs\\|fsrs\\)-"))
                     load-path)))
    (unless (require 'org-srs nil t)
      (ert-skip "org-srs is not installed"))))

(defmacro org-srs-x-test--with-decks (&rest body)
  (declare (indent 0) (debug t))
  `(zr-test-with-temp-directory
     (let ((org-srs-x-directory (expand-file-name "srs"))
           (org-srs-x-dictionaries nil)
           (org-srs-x-media-path-function #'identity)
           (org-srs-x-render-function #'org-srs-x-render-luna-note)
           (org-srs-x--server nil)
           (org-srs-x--clients nil)
           (org-srs-x--last-id 0))
       (unwind-protect
           (progn ,@body)
         (org-srs-x-stop)))))

(defun org-srs-x-test--call (action &rest pairs)
  "Invoke ACTION with parameter PAIRS, returning its successful result."
  (let ((response (org-srs-x-request
                   (org-srs-x--object "action" action "version" 6
                                      "params" (apply #'org-srs-x--object pairs)))))
    (should-not (gethash "error" response))
    (gethash "result" response)))

(defun org-srs-x-test--create-model ()
  (org-srs-x-test--call
   "createModel" "modelName" "modelofluna"
   "inOrderFields" ["word" "rubytextHtml" "example_sentence" "audio_for_word"
                    "audio_for_example_sentence" "screenshot" "remarks"
                    "dictionaryInfo" "dictionaryContent" "user_custom_1"]
   "css" ".card {}" "isCloze" :false
   "cardTemplates" (vector (org-srs-x--object "Name" "LUNACARDTEMPLATE1"
                                             "Front" "{{word}}" "Back" "{{remarks}}"))))

(defun org-srs-x-test--note (deck &optional word)
  "Return a LunaTranslator note for DECK, with two dictionary results."
  (org-srs-x--object
   "deckName" deck "modelName" "modelofluna" "tags" ["日本語" "game:one"]
   "options" (org-srs-x--object "allowDuplicate" t)
   "fields" (org-srs-x--object
             "word" (or word "猫") "rubytextHtml" "ねこ"
             "example_sentence" "<b>猫</b>です。<br>二行目"
             "remarks" "備考 &amp; メモ" "user_custom_1" "extra"
             "dictionaryInfo"
             (org-srs-x--json (vector (org-srs-x--object "dict" "edict" "name" "英和辞典")
                                     (org-srs-x--object "dict" "local" "name" "国語辞典")))
             "dictionaryContent"
             (org-srs-x--json
              (org-srs-x--object "edict" (url-hexify-string "<div>cat; feline</div>")
                                 "local" (url-hexify-string "<p>ネコ科の動物</p><script>SECRET_SCRIPT</script>"))))))

(ert-deftest org-srs-x-test-model-lifecycle-and-persistence ()
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (should (equal (org-srs-x-test--call "modelNames") ["modelofluna"]))
    (should (= (length (org-srs-x-test--call "modelFieldNames" "modelName" "modelofluna")) 10))
    (let ((response (org-srs-x-request
                     (org-srs-x--object "action" "createModel" "params"
                                        (org-srs-x--object "modelName" "modelofluna"
                                                           "inOrderFields" [])))))
      (should (equal (gethash "error" response) "Model name already exists")))
    (org-srs-x-test--call "updateModelStyling" "model"
                         (org-srs-x--object "name" "modelofluna" "css" "new css"))
    (org-srs-x-test--call "updateModelTemplates" "model"
                         (org-srs-x--object
                          "name" "modelofluna" "templates"
                          (org-srs-x--object "LUNACARDTEMPLATE1"
                                             (org-srs-x--object "Front" "new front" "Back" "new back"))))
    (let ((model (gethash "modelofluna" (org-srs-x--load-models))))
      (should (equal (gethash "css" model) "new css"))
      (should (equal (gethash "Back" (aref (gethash "cardTemplates" model) 0)) "new back")))))

(ert-deftest org-srs-x-test-deck-files-and-existing-decks ()
  (org-srs-x-test--with-decks
    (make-directory org-srs-x-directory t)
    (with-temp-file (expand-file-name "已有.org" org-srs-x-directory)
      (insert "#+title: 既存\n* 手工笔记\n正文\n"))
    (let ((first (org-srs-x-test--call "createDeck" "deck" "日本語::ゲーム")))
      (should (integerp first))
      (should (= first (org-srs-x-test--call "createDeck" "deck" "日本語::ゲーム")))
      (should (= first (gethash "日本語::ゲーム" (org-srs-x-test--call "deckNamesAndIds"))))
      (should (file-exists-p (expand-file-name "日本語/ゲーム.org" org-srs-x-directory))))
    (should (member "已有" (append (org-srs-x-test--call "deckNames") nil)))
    (dolist (name '("../escape" ".." "a::..::b" "a::::b" "a\\b" "a\nb"))
      (should-error (org-srs-x--deck-file name)))))

(ert-deftest org-srs-x-test-real-card-and-dictionary-selection-by-file ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "英語")
    (org-srs-x-test--call "createDeck" "deck" "日本語")
    (setq org-srs-x-dictionaries '(("英語.org" "edict") ("日本語.org" "国語辞典")))
    (dolist (deck '("英語" "日本語"))
      (let* ((note (org-srs-x-test--note deck))
             (id (org-srs-x-test--call "addNote" "note" note))
             (file (org-srs-x--deck-file deck)))
        (should (integerp id))
        (with-current-buffer (org-srs-x--buffer file)
          (goto-char (point-min))
          (re-search-forward "^\\* ")
          (org-back-to-heading)
          (should (org-entry-get nil "ID"))
          (should (equal (org-entry-get nil "ANKI_NOTE_ID") (number-to-string id)))
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
          (let ((fields (org-srs-x--parse (org-entry-get nil "ANKI_FIELDS"))))
            (should (= (hash-table-count (org-srs-x--parse (gethash "dictionaryContent" fields))) 1))))))))

(ert-deftest org-srs-x-test-file-keyword-overrides-and-empty-selection ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "lunadeck")
    (setq org-srs-x-dictionaries '(("lunadeck.org" "edict")))
    (with-current-buffer (org-srs-x--buffer (org-srs-x--deck-file "lunadeck"))
      (goto-char (point-min))
      (insert "#+SRS_X_DICTIONARIES: []\n")
      (org-srs-x--save))
    (org-srs-x-test--call "addNote" "note" (org-srs-x-test--note "lunadeck"))
    (with-current-buffer (org-srs-x--buffer (org-srs-x--deck-file "lunadeck"))
      (should-not (string-match-p "cat; feline\\|ネコ科\\|英和辞典\\|国語辞典" (buffer-string)))
      (goto-char (point-min))
      (re-search-forward "^\\* ")
      (org-back-to-heading)
      (let ((fields (org-srs-x--parse (org-entry-get nil "ANKI_FIELDS"))))
        (should (equal (gethash "dictionaryInfo" fields) "[]"))
        (should (equal (gethash "dictionaryContent" fields) "{}"))))))

(ert-deftest org-srs-x-test-unconfigured-file-keeps-multiple-dictionaries ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "lunadeck")
    (org-srs-x-test--call "addNote" "note" (org-srs-x-test--note "lunadeck"))
    (with-current-buffer (org-srs-x--buffer (org-srs-x--deck-file "lunadeck"))
      (should (string-match-p "cat; feline" (buffer-string)))
      (should (string-match-p "ネコ科の動物" (buffer-string))))))

(ert-deftest org-srs-x-test-media-import-with-client-path-mapping ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "lunadeck")
    (let* ((source (expand-file-name "audio.mp3"))
           (bytes (unibyte-string 0 255 128 10))
           (org-srs-x-media-path-function (lambda (path)
                                            (should (equal path "C:\\audio.mp3")) source))
           (note (org-srs-x-test--note "lunadeck")))
      (let ((coding-system-for-write 'no-conversion))
        (write-region bytes nil source nil 'silent))
      (puthash "audio" (vector (org-srs-x--object "filename" "audio.mp3" "path" "C:\\audio.mp3"
                                                 "fields" ["audio_for_word"])) note)
      (puthash "picture" (vector (org-srs-x--object "filename" "../image.png"
                                                   "data" (base64-encode-string bytes t)
                                                   "fields" ["screenshot"])) note)
      (org-srs-x-test--call "addNote" "note" note)
      (let ((medias (directory-files (expand-file-name "lunadeck.media" org-srs-x-directory)
                                      t "\\.\\(?:mp3\\|png\\)\\'")))
        (should (= (length medias) 2))
        (dolist (media medias)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally media)
            (should (equal bytes (buffer-string))))))
      (with-current-buffer (org-srs-x--buffer (org-srs-x--deck-file "lunadeck"))
        (should (string-match-p "\\[\\[file:lunadeck.media/.*mp3\\]\\[Audio\\]\\]" (buffer-string)))
        (should (string-match-p "\\[\\[file:lunadeck.media/.*png\\]\\]" (buffer-string)))))))

(ert-deftest org-srs-x-test-duplicate-find-delete-and-restart-ids ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "lunadeck")
    (let* ((note (org-srs-x-test--note "lunadeck"))
           (first (org-srs-x-test--call "addNote" "note" note)))
      (puthash "options" (org-srs-x--object "allowDuplicate" :false) note)
      (let ((response (org-srs-x-request (org-srs-x--object "action" "addNote" "params"
                                                          (org-srs-x--object "note" note)))))
        (should (equal (gethash "error" response) "cannot create note because it is a duplicate")))
      (should (equal (org-srs-x-test--call "findNotes" "query" "deck:\"lunadeck\" w:\"猫\"")
                     (vector first)))
      (setq org-srs-x--last-id 0)
      (let ((second (org-srs-x-test--call "addNote" "note" (org-srs-x-test--note "lunadeck" "犬"))))
        (should (> second first))
        (org-srs-x-test--call "deleteNotes" "notes" (vector first))
        (should (equal (org-srs-x-test--call "findNotes" "query" "") (vector second)))
        (org-srs-x-test--call "deleteNotes" "notes" (vector second))
        (should (equal (org-srs-x-test--call "findNotes" "query" "") [])))
      (org-srs-x-test--call "addNote" "note" note))))

(ert-deftest org-srs-x-test-save-failure-rolls-back-card ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "lunadeck")
    (let* ((buffer (org-srs-x--buffer (org-srs-x--deck-file "lunadeck")))
           (before (with-current-buffer buffer (buffer-string))))
      (cl-letf (((symbol-function 'org-srs-x--save) (lambda () (error "disk full"))))
        (let ((response (org-srs-x-request
                         (org-srs-x--object "action" "addNote" "params"
                                            (org-srs-x--object "note" (org-srs-x-test--note "lunadeck"))))))
          (should (equal (gethash "error" response) "disk full"))))
      (should (equal before (with-current-buffer buffer (buffer-string)))))))

(ert-deftest org-srs-x-test-content-cannot-create-extra-org-structure ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (org-srs-x-test--create-model)
    (org-srs-x-test--call "createDeck" "deck" "lunadeck")
    (let ((note (org-srs-x-test--note "lunadeck")))
      (puthash "remarks" "<p>* new heading</p><p>#+begin_src emacs-lisp</p><p>:END:</p>"
               (gethash "fields" note))
      (org-srs-x-test--call "addNote" "note" note))
    (with-current-buffer (org-srs-x--buffer (org-srs-x--deck-file "lunadeck"))
      (let ((headings nil))
        (org-map-entries (lambda () (push (org-get-heading t t t t) headings)) nil 'file)
        (should (equal (nreverse headings) '("猫" "Front" "Back"))))
      (should (string-match-p ",#\\+begin_src" (buffer-string)))
      (should (string-match-p ",:END:" (buffer-string))))))

(defun org-srs-x-test--http (parts)
  "Send binary HTTP PARTS to the real server and return the HTTP response."
  (let* ((output "")
         (client (make-network-process
                  :name "org-srs-x-test-client" :host "127.0.0.1"
                  :service (process-contact org-srs-x--server :service)
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

(defun org-srs-x-test--http-json (http)
  (should (string-match "\r\n\r\n" http))
  (org-srs-x--parse (decode-coding-string (substring http (match-end 0)) 'utf-8)))

(ert-deftest org-srs-x-test-real-http-get-post-fragments-and-errors ()
  (org-srs-x-test--require-srs)
  (org-srs-x-test--with-decks
    (let ((org-srs-x-port 0))
      (org-srs-x-start)
      (should (eq (org-srs-x-start) org-srs-x--server))
      (dolist (method '("GET" "POST"))
        (let* ((body (encode-coding-string
                      (org-srs-x--json (org-srs-x--object "action" "createDeck" "version" 6 "params"
                                                         (org-srs-x--object "deck" "日本語"))) 'utf-8))
               (http (org-srs-x-test--http
                      (list (format "%s / HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n" method (length body))
                            "\r\n" (substring body 0 20) (substring body 20 21) (substring body 21)))))
          (should (string-prefix-p "HTTP/1.1 200 OK" http))
          (should (integerp (gethash "result" (org-srs-x-test--http-json http))))))
      (let ((http (org-srs-x-test--http '("GET / HTTP/1.1\r\nContent-Length: 1\r\n\r\n{"))))
        (should (string-prefix-p "HTTP/1.1 400 Bad Request" http))
        (should (stringp (gethash "error" (org-srs-x-test--http-json http)))))
      (let ((org-srs-x-max-request-size 10))
        (should (string-prefix-p "HTTP/1.1 413 Payload Too Large"
                                 (org-srs-x-test--http '("GET / HTTP/1.1\r\nContent-Length: 11\r\n\r\n")))))
      (dolist (headers '("Content-Length: -1\r\n" "Content-Length: 0\r\nContent-Length: 0\r\n"
                         "Transfer-Encoding: chunked\r\n"))
        (should (string-prefix-p "HTTP/1.1 400 Bad Request"
                                 (org-srs-x-test--http (list (concat "GET / HTTP/1.1\r\n" headers "\r\n"))))))
      (should-not org-srs-x--clients)
      (let ((server org-srs-x--server))
        (org-srs-x-stop)
        (should-not (process-live-p server))
        (org-srs-x-stop)))))

(ert-deftest org-srs-x-test-api-errors-have-anki-envelope ()
  (org-srs-x-test--with-decks
    (dolist (request (list (org-srs-x--object "action" "sync")
                          (org-srs-x--object "action" "version" "version" 5)
                          (org-srs-x--object "action" "version" "params" [])
                          []))
      (let ((response (org-srs-x-request request)))
        (should (= (hash-table-count response) 2))
        (should-not (gethash "result" response))
        (should (stringp (gethash "error" response)))))
    (should-not (file-exists-p org-srs-x-directory))))

(provide 'org-srs-x-test)
;;; org-srs-x-test.el ends here

(provide 'org-srs-x-test)
;;; org-srs-x-test.el ends here
