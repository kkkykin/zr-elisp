;;; zr-org-srs-x-test.el --- Tests for Org-srs AnkiConnect capture -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url-util)
(require 'dictionary)
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
          (dictionary-default-dictionary nil)
          (zr-org-srs-x-dictionary-name-function #'zr-org-srs-x-format-dictionary-name)
          (zr-org-srs-x-media-path-function #'identity)
          (zr-org-srs-x-model-alist (default-value 'zr-org-srs-x-model-alist))
          (zr-org-srs-x--server nil)
          (zr-org-srs-x--clients nil)
          (zr-org-srs-x--models (make-hash-table :test #'equal))
          (zr-org-srs-x--last-id 0))
      (unwind-protect
          (progn ,@body)
        (zr-org-srs-x-stop)))))

(defmacro zr-org-srs-x-test--with-dictionary (&rest body)
  "Run BODY against a local DICT server, using the real dictionary.el client."
  (declare (indent 0) (debug t))
  `(let* ((dictionary-commands nil)
          (dictionary-clients nil)
          (dictionary-greeting "220 test DICT server\r\n")
          (dictionary-response-function
           (lambda (_command)
             (concat "150 2 definitions retrieved\r\n"
                     "151 \"猫\" edict \"英和辞典\"\r\ncat from DICT\r\n.\r\n"
                     "151 \"猫\" local \"国語辞典\"\r\n猫の定義 from DICT\r\n.\r\n"
                     "250 ok\r\n")))
          (dictionary-server "127.0.0.1")
          (dictionary-use-http-proxy nil)
          (dictionary-default-dictionary "*")
          (zr-org-srs-x-dictionary-timeout 1)
          (server
           (make-network-process
            :name "zr-org-srs-x-test-dict" :server t :host "127.0.0.1"
            :service t :family 'ipv4 :coding 'binary :noquery t
            :log (lambda (_server client _message)
                   (push client dictionary-clients)
                   (set-process-query-on-exit-flag client nil)
                   (when dictionary-greeting
                     (process-send-string client dictionary-greeting)))
            :filter
            (lambda (client chunk)
              (let ((input (concat (or (process-get client 'input) "") chunk)))
                (while (string-match "\r\n" input)
                  (let ((command (substring input 0 (match-beginning 0))))
                    (setq input (substring input (match-end 0)))
                    (push (decode-coding-string command 'utf-8) dictionary-commands)
                    (when-let* ((response
                                 (if (string-prefix-p "client " command)
                                     "250 ok\r\n"
                                   (funcall dictionary-response-function
                                            (decode-coding-string command 'utf-8)))))
                      (process-send-string client (encode-coding-string response 'utf-8)))))
                (process-put client 'input input)))))
          (dictionary-port (process-contact server :service)))
     (unwind-protect
         (progn ,@body)
       (delete-process server)
       (dolist (client dictionary-clients)
         (when (process-live-p client) (delete-process client))))))

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

(defun zr-org-srs-x-test--card-subtree-text (region)
  "Return the text of heading REGION, including its child subheadings."
  (buffer-substring-no-properties
   (car region)
   (save-excursion
     (goto-char (car region))
     (org-end-of-subtree t t)
     (point))))

(ert-deftest zr-org-srs-x-test-model-templates-and-fallback ()
  (let* ((fields '(("word" . "猫") ("example_sentence" . "A $dictionary \\1 example")
                   ("remarks" . "remark")))
         (variables '((dictionary . "definition $audio") (picture . "image")
                      (audio . "sound") (video . "")))
         (zr-org-srs-x-model-alist
          '((modelofluna . ((name . "$.word") (front . "$.example_sentence")
                           (back . "$.remarks\n\n$dictionary\n$picture $audio$video $.missing $$10")))
            ("other" . ((name . "Other $.word") (front . "$.remarks") (back . "")))
            (t . zr-org-srs-x-render-default-note))))
    (should (equal (zr-org-srs-x--render "modelofluna" fields variables)
                   '((name . "猫") (front . "A $dictionary \\1 example")
                     (back . "remark\n\ndefinition $audio\nimage sound  $10"))))
    (should (equal (zr-org-srs-x--render "other" fields variables)
                   '((name . "Other 猫") (front . "remark") (back . ""))))
    (let ((fallback (zr-org-srs-x--render "unconfigured" fields variables)))
      (should (equal (alist-get 'name fallback) "猫"))
      (should (equal (alist-get 'front fallback) "猫"))
      (should (string-match-p "definition \\$audio" (alist-get 'back fallback))))))

(ert-deftest zr-org-srs-x-test-model-and-part-render-functions ()
  (let* ((fields '(("word" . "猫")))
         (variables '((dictionary . "definition")))
         (zr-org-srs-x-model-alist
          `((whole . ,(lambda (input values)
                        (should (eq input fields))
                        (should (eq values variables))
                        '((name . "Function") (front . "$.word") (back . "$dictionary"))))
            (part . ((name . "$.word") (front . "text")
                     (back . ,(lambda (input values)
                                (concat (cdr (assoc "word" input)) " "
                                        (alist-get 'dictionary values) " $audio"))))))))
    (should (equal (zr-org-srs-x--render "whole" fields variables)
                   '((name . "Function") (front . "$.word") (back . "$dictionary"))))
    (should (equal (zr-org-srs-x--render "part" fields variables)
                   '((name . "猫") (front . "text") (back . "猫 definition $audio"))))))

(ert-deftest zr-org-srs-x-test-model-template-dictionary-and-media-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((zr-org-srs-x-model-alist
          '((modelofluna . ((name . "$.word\n$.rubytextHtml")
                           (front . "$.example_sentence")
                           (back . "$.remarks\n\n$dictionary\n\n$picture\n\n$audio\n\n$video")))))
         (note (zr-org-srs-x-test--note "lunadeck")))
     (dolist (kind '("picture" "audio" "video"))
       (puthash kind
                (vector (zr-org-srs-x--object "filename" (concat kind ".dat") "data" "YWJj"
                                             "fields" ["screenshot"]))
                note))
     (zr-org-srs-x-test--with-dictionary
      (zr-org-srs-x-test--call "addNote" "note" note)
      (should (member "define * \"猫\"" dictionary-commands)))
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
       (goto-char (point-min))
       (re-search-forward "^\\* ")
       (org-back-to-heading)
       (should (equal (org-get-heading t t t t) "猫 ねこ"))
       (cl-multiple-value-bind (front back) (org-srs-item-card-regions)
         (let ((front-text (buffer-substring-no-properties (car front) (cdr front)))
               (back-text (zr-org-srs-x-test--card-subtree-text back)))
           (should (string-match-p "二行目" front-text))
           (should-not (string-match-p "file:\\|from DICT\\|備考" front-text))
           (should (string-match-p "備考 & メモ" back-text))
           (should (string-match-p "cat from DICT" back-text))
           (should (string-match-p "猫の定義 from DICT" back-text))
           (dolist (kind '("picture" "audio" "video"))
             (should (= (cl-count-if
                         (lambda (line) (string-match-p (concat kind "\\.dat") line))
                         (split-string back-text "\n"))
                        1)))))))))

(ert-deftest zr-org-srs-x-test-model-alist-file-and-directory-local ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (let* ((directory-renderers
           '((modelofluna . ((name . "Directory $.word") (front . "$.remarks") (back . "")))))
          (file-renderers
           '((modelofluna . ((name . "File $.word") (front . "$.example_sentence") (back . "")))))
          (safe-local-variable-values
           (append (list (cons 'zr-org-srs-x-model-alist directory-renderers)
                         (cons 'zr-org-srs-x-model-alist file-renderers))
                   safe-local-variable-values)))
     (make-directory zr-org-srs-x-directory t)
     (with-temp-file (expand-file-name ".dir-locals.el" zr-org-srs-x-directory)
       (prin1 `((org-mode . ((zr-org-srs-x-model-alist . ,directory-renderers)))) (current-buffer)))
     (with-temp-file (zr-org-srs-x--deck-file "override")
       (insert (format "# -*- zr-org-srs-x-model-alist: %S; -*-\n" file-renderers)))
     (zr-org-srs-x-test--call "createDeck" "deck" "directory")
     ;; Capture runs outside either deck buffer.
     (with-temp-buffer
       (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "directory"))
       (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "override")))
     (dolist (deck '("directory" "override"))
       (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file deck))
         (goto-char (point-min))
         (re-search-forward "^\\* ")
         (org-back-to-heading)
         (should (equal (org-get-heading t t t t)
                        (if (equal deck "directory") "Directory 猫" "File 猫")))))
     (should (equal zr-org-srs-x-model-alist (default-value 'zr-org-srs-x-model-alist))))))

(ert-deftest zr-org-srs-x-test-model-render-function-runs-in-deck ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((zr-org-srs-x-model-alist
          `((modelofluna . ,(lambda (fields variables)
                             (should (equal buffer-file-name (zr-org-srs-x--deck-file "lunadeck")))
                             (should (derived-mode-p 'org-mode))
                             (should (equal (caar fields) "word"))
                             (should (equal (cdr (assoc "remarks" fields)) "備考 & メモ"))
                             (should-not (assoc "dictionaryContent" fields))
                             (should (equal (alist-get 'audio variables) ""))
                             '((name . "Function") (front . "front") (back . "back")))))))
     (should (integerp (zr-org-srs-x-test--call "addNote" "note"
                                              (zr-org-srs-x-test--note "lunadeck")))))))

(ert-deftest zr-org-srs-x-test-invalid-model-renderer-does-not-save-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (dolist (renderer '(((front . "front") (back . "back"))
                       ((name . " ") (front . "front") (back . "back"))
                       ((name . "$.word") (front . "$unknown") (back . "back"))
                       ((name . "$.word") (front . 42) (back . "back"))
                       (lambda (_fields _variables) [invalid])
                       (lambda (_fields _variables)
                         '((name . "name") (front . 42) (back . "back")))))
     (let* ((zr-org-srs-x-model-alist (list (cons 'modelofluna renderer)))
            (response (zr-org-srs-x-request
                       (zr-org-srs-x--object "action" "addNote" "params"
                                             (zr-org-srs-x--object "note" (zr-org-srs-x-test--note "lunadeck"))))))
       (should (gethash "error" response))
       (should-not (gethash "result" response))))
   (let ((zr-org-srs-x-model-alist nil))
     (should-error (zr-org-srs-x--render "missing" nil nil)
                   :type 'error))
   (should-not (file-exists-p (expand-file-name ".zr-org-srs-x-notes.json" zr-org-srs-x-directory)))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (should-not (string-match-p "^\\* " (buffer-string)))
     (should-not (buffer-modified-p)))))

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
   (let ((model (gethash "modelofluna" zr-org-srs-x--models)))
     (should (equal (gethash "templateName" model) "LUNACARDTEMPLATE1"))
     (should-not (gethash "css" model))
     (should-not (gethash "cardTemplates" model))
     (should (= (hash-table-count model) 4)))
   (should-not (file-exists-p (expand-file-name ".zr-org-srs-x.json" zr-org-srs-x-directory)))))

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

(ert-deftest zr-org-srs-x-test-file-locals-survive-org-mode-selection ()
  (zr-org-srs-x-test--with-decks
   (make-directory zr-org-srs-x-directory t)
   (let ((file (zr-org-srs-x--deck-file "英語"))
         (safe-local-variable-values
          (cons '(dictionary-default-dictionary . "dictd-db-eng-zho")
                safe-local-variable-values)))
     (with-temp-file file
       (insert "# -*- mode: text; dictionary-default-dictionary: \"dictd-db-eng-zho\"; -*-\n"
               "#+title: 英語\n"))
     (with-current-buffer (zr-org-srs-x--buffer file)
       (should (derived-mode-p 'org-mode))
       (should (local-variable-p 'dictionary-default-dictionary))
       (should (equal dictionary-default-dictionary "dictd-db-eng-zho"))
       ;; Reusing a visited deck must keep its current buffer-local settings.
       (setq-local dictionary-default-dictionary nil)
       (should (eq (zr-org-srs-x--buffer file) (current-buffer)))
       (should-not dictionary-default-dictionary)))))

(ert-deftest zr-org-srs-x-test-directory-locals-and-file-override ()
  (zr-org-srs-x-test--with-decks
   (make-directory zr-org-srs-x-directory t)
   (with-temp-file (expand-file-name ".dir-locals.el" zr-org-srs-x-directory)
     (insert "((org-mode . ((dictionary-default-dictionary . \"dictd-db-eng-zho\"))))\n"))
   (let ((safe-local-variable-values
          (append '((dictionary-default-dictionary . "dictd-db-eng-zho")
                    (dictionary-default-dictionary . "gcide")
                    (dictionary-default-dictionary . nil))
                  safe-local-variable-values)))
     ;; Include a new deck and a deck whose automatic mode is not Org.
     (dolist (deck '("new" "existing" "fallback" "override" "disabled"))
       (let ((file (zr-org-srs-x--deck-file (concat "英語::" deck)))
             (auto-mode-alist (unless (equal deck "fallback") auto-mode-alist)))
         (unless (equal deck "new")
           (make-directory (file-name-directory file) t)
           (with-temp-file file
             (insert
              (pcase deck
                ("override" "# -*- dictionary-default-dictionary: \"gcide\"; -*-\n")
                ("disabled" "# -*- dictionary-default-dictionary: nil; -*-\n")
                (_ ""))
              "#+title: 英語\n")))
         (with-current-buffer (zr-org-srs-x--buffer file (equal deck "new"))
           (should (derived-mode-p 'org-mode))
           (should (local-variable-p 'dictionary-default-dictionary))
           (should (equal dictionary-default-dictionary
                          (pcase deck
                            ("override" "gcide")
                            ("disabled" nil)
                            (_ "dictd-db-eng-zho"))))))))
   (should-not dictionary-default-dictionary)))

(ert-deftest zr-org-srs-x-test-file-local-dictionary-requires-string ()
  (zr-org-srs-x-test--with-decks
   (make-directory zr-org-srs-x-directory t)
   (let ((file (zr-org-srs-x--deck-file "英語"))
         (safe-local-variable-values
          (cons '(dictionary-default-dictionary . dictd-db-eng-zho)
                safe-local-variable-values)))
     (with-temp-file file
       (insert "# -*- dictionary-default-dictionary: dictd-db-eng-zho; -*-\n"))
     (with-current-buffer (zr-org-srs-x--buffer file)
       (should (eq dictionary-default-dictionary 'dictd-db-eng-zho))
       (let ((err (should-error (zr-org-srs-x--dictionary-text "hello"))))
         (should (string-match-p "dictd-db-eng-zho.*DICT database name string"
                                 (error-message-string err))))))))

(ert-deftest zr-org-srs-x-test-real-card-and-dictionary-default-by-file-and-directory ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (make-directory zr-org-srs-x-directory t)
   (with-temp-file (expand-file-name ".dir-locals.el" zr-org-srs-x-directory)
     (insert "((org-mode . ((dictionary-default-dictionary . \"edict\"))))\n"))
   (zr-org-srs-x-test--call "createDeck" "deck" "英語")
   (zr-org-srs-x-test--call "createDeck" "deck" "日本語")
   (zr-org-srs-x-test--call "createDeck" "deck" "英語::directory")
   (dolist (deck '("英語" "日本語" "英語::directory"))
     ;; Reopen to apply trusted file and directory settings during capture.
     (let ((file (zr-org-srs-x--deck-file deck)))
       (with-current-buffer (zr-org-srs-x--buffer file)
         (unless (equal deck "英語::directory")
           (goto-char (point-min))
           (insert (format "# -*- dictionary-default-dictionary: %S; -*-\n"
                           (if (equal deck "英語") "edict" "local")))
           (zr-org-srs-x--save))
         (kill-buffer (current-buffer)))))
   (zr-org-srs-x-test--with-dictionary
    (setq dictionary-response-function
          (lambda (command)
            (if (string-prefix-p "define edict " command)
                "150 1 definition\r\n151 \"猫\" edict \"English\"\r\ncat from DICT\r\n.\r\n250 ok\r\n"
              "150 1 definition\r\n151 \"猫\" local \"日本語\"\r\n猫の定義 from DICT\r\n.\r\n250 ok\r\n")))
    (dolist (deck '("英語" "日本語" "英語::directory"))
     (let* ((note (zr-org-srs-x-test--note deck))
            (safe-local-variable-values
             (append '((dictionary-default-dictionary . "edict")
                       (dictionary-default-dictionary . "local"))
                     safe-local-variable-values))
            (id (zr-org-srs-x-test--call "addNote" "note" note))
            (file (zr-org-srs-x--deck-file deck)))
       (should (integerp id))
       (with-current-buffer (zr-org-srs-x--buffer file)
         (goto-char (point-min))
         (re-search-forward "^\\* ")
         (org-back-to-heading)
         (should (equal (org-entry-get nil "ID") (number-to-string id)))
         (should-not (string-match-p "^:ANKI_" (buffer-string)))
         (should (equal (org-get-tags) '("日本語" "game_one")))
         (should (= (length (org-srs-query-buffer (org-srs-query-predicate-new))) 1))
         (should (org-srs-item-exists-p '(card back)))
         (cl-multiple-value-bind (front back) (org-srs-item-card-regions)
           (let ((front-text (buffer-substring-no-properties (car front) (cdr front)))
                 (back-text (zr-org-srs-x-test--card-subtree-text back)))
             (should (string-match-p "猫.*\n" front-text))
             (should (string-match-p "二行目" front-text))
             (should-not (string-match-p "備考 & メモ\\|from DICT" front-text))
             (should (string-match-p "ねこ" back-text))
             (should (string-match-p "備考 & メモ" back-text))
             (should (string-match-p "extra" back-text))
             (should-not (string-match-p "SECRET_SCRIPT\\|cat; feline\\|ネコ科" (buffer-string)))
             (if (not (equal deck "日本語"))
                 (progn (should (string-match-p "cat from DICT" back-text))
                        (should (string-match-p "^\\*\\*\\* \\[edict\\]$" back-text))
                        (should-not (string-match-p "猫の定義" back-text)))
               (should (string-match-p "猫の定義 from DICT" back-text))
               (should (string-match-p "^\\*\\*\\* \\[local\\]$" back-text))
               (should-not (string-match-p "cat from DICT" back-text)))))
         (should-not (file-exists-p (expand-file-name ".zr-org-srs-x-notes.json"
                                                    zr-org-srs-x-directory))))))
    (should (member "define edict \"猫\"" dictionary-commands))
    (should (member "define local \"猫\"" dictionary-commands))
    (should (equal dictionary-default-dictionary "*")))))

(ert-deftest zr-org-srs-x-test-nil-dictionary-disables-lookup ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (setq-local dictionary-default-dictionary nil))
   (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (should-not (string-match-p "cat; feline\\|ネコ科\\|英和辞典\\|国語辞典" (buffer-string)))
     (goto-char (point-min))
     (re-search-forward "^\\* ")
     (org-back-to-heading)
     (should-not (string-match-p "^:ANKI_" (buffer-string))))))

(ert-deftest zr-org-srs-x-test-unconfigured-file-uses-default-and-all-definitions ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-org-srs-x-test--with-dictionary
    (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))
    (should (member "define * \"猫\"" dictionary-commands))
    (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
      (should (string-match-p "^\\*\\*\\* \\[edict\\]\ncat from DICT" (buffer-string)))
      (should (string-match-p "^\\*\\*\\* \\[local\\]\n猫の定義 from DICT" (buffer-string)))
      (should-not (string-match-p "英和辞典\\|国語辞典" (buffer-string)))
      (should-not (string-match-p "cat; feline\\|ネコ科" (buffer-string)))))))

(ert-deftest zr-org-srs-x-test-dictionary-headings-group-definitions-and-preserve-card-regions ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-org-srs-x-test--with-dictionary
    (setq dictionary-response-function
          (lambda (_command)
            (concat "150 3 definitions\r\n"
                    "151 \"hamlet\" dictd-db-eng-zho \"English-中文 FreeDict+WikDict ver. 2025.11.23\"\r\n"
                    "hamlet //ˈhæm.lət//\r\n村\r\nA small village or a group of houses.\r\n.\r\n"
                    "151 \"hamlet\" dict-db-wordnet-542 \"WordNet (r) 2.1 (2005)\"\r\n"
                    "hamlet\r\n    n 1: a community of people smaller than a village\r\n.\r\n"
                    "151 \"hamlet\" dictd-db-eng-zho \"English-中文 FreeDict+WikDict ver. 2025.11.23\"\r\n"
                    "Another definition.\r\n* raw heading\r\n*** [dictd-db-eng-zho]\r\n"
                    "#+begin_src emacs-lisp\r\n:END:\r\n.\r\n250 ok\r\n")))
    (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "hamlet")))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (let (headings)
       (org-map-entries (lambda () (push (cons (org-outline-level) (org-get-heading t)) headings)) nil 'file)
       (should (equal (nreverse headings)
                      '((1 . "hamlet") (2 . "Front") (2 . "Back")
                        (3 . "[dictd-db-eng-zho]") (3 . "[dict-db-wordnet-542]")))))
     (goto-char (point-min))
     (re-search-forward "^\\* ")
     (org-back-to-heading)
     (cl-multiple-value-bind (front back) (org-srs-item-card-regions)
       (let ((front-text (buffer-substring-no-properties (car front) (cdr front)))
             (back-text (zr-org-srs-x-test--card-subtree-text back)))
         (should-not (string-match-p "dictd-db-eng-zho\\|Another definition" front-text))
         (should (string-match-p "hamlet //ˈhæm.lət//\n村" back-text))
         (should (string-match-p (regexp-quote "A small village or a group of houses.\n\nAnother definition.")
                                 back-text))
         (should (string-match-p "^,\\* raw heading" back-text))
         (should (string-match-p "^,\\*\\*\\* \\[dictd-db-eng-zho\\]" back-text))
         (should (string-match-p "^,#\\+begin_src" back-text))
         (should (string-match-p "^,:END:" back-text))
         (should (string-match-p "n 1: a community" back-text))
         (should-not (string-match-p "FreeDict\\|WikDict\\|WordNet (r)" back-text))))
     (let ((definition (save-excursion
                         (search-forward "A small village")
                         (point))))
       (org-srs-item-card-hide :back)
       (should (invisible-p definition))
       (org-srs-item-card-show)
       (should-not (invisible-p definition)))
     (should (= (length (org-srs-query-buffer (org-srs-query-predicate-new))) 1))
     (should (equal (org-element-map (org-element-parse-buffer) 'node-property
                      (lambda (property) (org-element-property :key property)))
                    '("ID")))
     ;; Generated headings and escaped source lines must survive saving.
     (should (equal (buffer-substring-no-properties (point-min) (point-max))
                    (with-temp-buffer
                      (insert-file-contents (zr-org-srs-x--deck-file "lunadeck"))
                      (buffer-string)))))))

(ert-deftest zr-org-srs-x-test-dictionary-names-handle-unknown-and-custom-function ()
  (zr-org-srs-x-test--require-srs)
  (dolist (custom '(nil t))
    (zr-org-srs-x-test--with-decks
     (zr-org-srs-x-test--create-model)
     (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
     (let* ((names nil)
            (zr-org-srs-x-dictionary-name-function
             (if custom
                 (lambda (name id)
                   (should (equal buffer-file-name (zr-org-srs-x--deck-file "lunadeck")))
                   (push (cons name id) names)
                   (format "%s [%s]" name id))
               #'zr-org-srs-x-format-dictionary-name)))
       (zr-org-srs-x-test--with-dictionary
        (setq dictionary-response-function
              (lambda (_command)
                (concat "150 4 definitions\r\n"
                        "151 \"word\" unknown \"甲词典\"\r\nAlpha definition.\r\n.\r\n"
                        "151 \"word\" known \"Known Dictionary\"\r\nKnown definition.\r\n.\r\n"
                        "151 \"word\" unknown \"乙词典\"\r\nBeta definition.\r\n.\r\n"
                        "151 \"word\" unknown \"甲词典\"\r\nMore alpha.\r\n.\r\n250 ok\r\n")))
        (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "word")))
       (when custom
         (should (equal (nreverse names)
                        '(("甲词典" . "unknown") ("Known Dictionary" . "known")
                          ("乙词典" . "unknown") ("甲词典" . "unknown")))))
       (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
         (let (headings)
           (org-map-entries (lambda () (push (org-get-heading t) headings)) "LEVEL=3" 'file)
           (should (equal (nreverse headings)
                          (if custom
                              '("甲词典 [unknown]" "Known Dictionary [known]" "乙词典 [unknown]")
                            '("甲词典" "[known]" "乙词典")))))
         (should (string-match-p (regexp-quote "Alpha definition.\n\nMore alpha.") (buffer-string)))
         (should (string-match-p "Known definition" (buffer-string)))
         (should (string-match-p "Beta definition" (buffer-string))))))))

(ert-deftest zr-org-srs-x-test-media-import-with-client-path-mapping ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((source (expand-file-name "audio.mp3"))
          (bytes (unibyte-string 0 255 128 10))
          (note (zr-org-srs-x-test--note "lunadeck")))
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
       (setq-local zr-org-srs-x-media-path-function
                   (lambda (path)
                     (should (equal path "C:\\audio.mp3"))
                     (should (equal buffer-file-name (zr-org-srs-x--deck-file "lunadeck")))
                     source)))
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
       (should-not (file-exists-p (expand-file-name ".zr-org-srs-x-notes.json" zr-org-srs-x-directory))))
     (zr-org-srs-x-test--call "addNote" "note" note))))

(ert-deftest zr-org-srs-x-test-restart-and-clock-rollback-keep-ids-unique-across-decks ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (let ((now "2000000000000"))
     (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) now)))
       (zr-org-srs-x-test--create-model)
       (zr-org-srs-x-test--call "createDeck" "deck" "cats")
       (zr-org-srs-x-test--call "createDeck" "deck" "dogs")
       (let ((first (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "cats" "猫"))))
         ;; A fresh Emacs must recover the maximum ID from the Org files.
         (setq zr-org-srs-x--last-id nil
               zr-org-srs-x--models (make-hash-table :test #'equal)
               now "1999999999999")
         (zr-org-srs-x-test--create-model)
         (let ((second (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "dogs" "犬"))))
           (should (> second first))
           (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") (vector first second)))
           (zr-org-srs-x-test--call "deleteNotes" "notes" (vector second))
           (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") (vector first)))))))))

(ert-deftest zr-org-srs-x-test-word-query-matches-only-complete-heading ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((cat (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "猫"))))
     ;; All notes' example sentences contain 猫, regardless of their word.
     (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "犬"))
     (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "野良猫"))
     (dolist (filter '("w" "word"))
       (should (equal (zr-org-srs-x-test--call
                       "findNotes" "query" (format "deck:\"lunadeck\" %s:\"猫\"" filter))
                      (vector cat))))
     (let ((upper (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "CAT"))))
       (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "cat"))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"lunadeck\" w:\"CAT\"")
                      (vector upper)))))))

(ert-deftest zr-org-srs-x-test-heading-keywords-are-preserved-for-duplicates-and-search ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "study"))
   (dolist (title '("TODO study" "[#A] study" "COMMENT study"))
     (let ((note (zr-org-srs-x-test--note "lunadeck" title)))
       (puthash "options" (zr-org-srs-x--object "allowDuplicate" :false) note)
       (let ((id (zr-org-srs-x-test--call "addNote" "note" note))
             (response (zr-org-srs-x-request
                        (zr-org-srs-x--object "action" "addNote" "params"
                                              (zr-org-srs-x--object "note" note)))))
         (should (equal (gethash "error" response) "cannot create note because it is a duplicate"))
         (should (equal (zr-org-srs-x-test--call
                         "findNotes" "query" (format "deck:\"lunadeck\" w:\"%s\"" title))
                        (vector id))))))))

(ert-deftest zr-org-srs-x-test-noncanonical-org-ids-are-ignored ()
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((invalid-ids '("12345678-abcd-4cde-8f90-123456789abc"
                        "99999999999999999999-abcd-4cde-8f90-123456789abc"
                        "2e30" "3.5" "0" "012345678" "-10")))
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
       (goto-char (point-max))
       (dolist (id (cons "12345678" invalid-ids))
         (insert "\n* Note " id "\n:PROPERTIES:\n:ID: " id "\n:END:\n"))
       (zr-org-srs-x--save))
     (setq zr-org-srs-x--last-id nil)
     (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") [12345678]))
     (should (= zr-org-srs-x--last-id 12345678))
     ;; Capture's scan must ignore the same invalid IDs as findNotes.
     (setq zr-org-srs-x--last-id nil)
     (zr-org-srs-x--check-duplicate "New card" (zr-org-srs-x--object))
     (should (= zr-org-srs-x--last-id 12345678))
     (zr-org-srs-x-test--call "deleteNotes" "notes" [12345678])
     (should (equal (zr-org-srs-x-test--call "findNotes" "query" "") []))
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
       (dolist (id invalid-ids)
         (should (string-match-p (regexp-quote (concat ":ID: " id "\n")) (buffer-string))))))))

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
     (should (equal before (with-current-buffer buffer (buffer-string)))))))

(ert-deftest zr-org-srs-x-test-zero-disk-json-files-created ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((id (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))))
     (should (integerp id))
     (should (file-exists-p (expand-file-name "lunadeck.org" zr-org-srs-x-directory)))
     (should-not (directory-files-recursively zr-org-srs-x-directory "\\.json\\'")))))

(ert-deftest zr-org-srs-x-test-large-and-malformed-luna-dictionaries-are-discarded ()
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
     ;; Neither source field should need to contain valid dictionary JSON.
     (puthash "dictionaryInfo" "{malformed Luna dictionary metadata" fields)
     (let ((id (zr-org-srs-x-test--call "addNote" "note" note))
           (file (zr-org-srs-x--deck-file "lunadeck")))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"lunadeck\" w:\"official\"")
                      (vector id)))
       (with-current-buffer (zr-org-srs-x--buffer file)
         (should (string-match-p "備考 & メモ" (buffer-string)))
         (should-not (string-match-p "^:ANKI_\\|dictionaryContent\\|<style>\\|<script>\\|Large-page definition\\|ネコ科"
                                     (buffer-string)))
         (should (< (buffer-size) 8192))
         (should (= (length (org-srs-query-buffer (org-srs-query-predicate-new))) 1)))
       (should-not (file-exists-p (expand-file-name ".zr-org-srs-x-notes.json" zr-org-srs-x-directory)))))))

(ert-deftest zr-org-srs-x-test-dictionary-missing-word-and-quoted-word ()
  (zr-org-srs-x-test--with-dictionary
   (setq dictionary-response-function (lambda (_command) "552 no match\r\n"))
   (should (equal (zr-org-srs-x--dictionary-text "a\"b\\c") ""))
   (should (member "define * \"a\\\"b\\\\c\"" dictionary-commands))
   (should-not (cl-some (lambda (command) (string-prefix-p "match " command))
                        dictionary-commands))
   (accept-process-output nil 0.02)
   (should-not (cl-some #'process-live-p dictionary-clients))
   (let ((before (length dictionary-commands)))
     (should-error (zr-org-srs-x--dictionary-text "word\r\nQUIT"))
     (let ((dictionary-default-dictionary "bad database"))
       (should-error (zr-org-srs-x--dictionary-text "word")))
     (should (= before (length dictionary-commands))))))

(ert-deftest zr-org-srs-x-test-dictionary-keeps-interactive-connection-and-window ()
  (zr-org-srs-x-test--with-dictionary
   (let* ((dictionary-connection (dictionary-connection-open dictionary-server dictionary-port))
          (interactive-connection dictionary-connection)
          (dictionary-current-server "interactive")
          (window (selected-window))
          (visible-buffer (window-buffer window))
          (before (buffer-list)))
     (unwind-protect
         (with-temp-buffer
           (insert "Keep deck text")
           (should (string-match-p "cat from DICT" (zr-org-srs-x--dictionary-text "猫")))
           (should (equal (buffer-string) "Keep deck text"))
           (should (eq dictionary-connection interactive-connection))
           (should (eq (dictionary-connection-status interactive-connection) 'up))
           (should (equal dictionary-current-server "interactive"))
           (should (eq (selected-window) window))
           (should (eq (window-buffer window) visible-buffer)))
       (dictionary-connection-close interactive-connection))
     (should-not (cl-set-difference (buffer-list) before)))))

(ert-deftest zr-org-srs-x-test-dictionary-connect-failure-cleans-buffer ()
  (let* ((server (make-network-process :name "zr-org-srs-x-test-closed-dict"
                                       :server t :host "127.0.0.1" :service t :noquery t))
         (dictionary-server "127.0.0.1")
         (dictionary-port (process-contact server :service))
         (dictionary-use-http-proxy nil)
         (dictionary-default-dictionary "*")
         (before-buffers (buffer-list))
         (before-processes (process-list)))
    (delete-process server)
    (should-error (zr-org-srs-x--dictionary-text "official"))
    (should-not (cl-set-difference (buffer-list) before-buffers))
    (should-not (cl-set-difference (process-list) before-processes))))

(ert-deftest zr-org-srs-x-test-dictionary-greeting-timeout-cleans-connection ()
  (zr-org-srs-x-test--with-dictionary
   (setq dictionary-greeting nil)
   (let ((zr-org-srs-x-dictionary-timeout 0.1)
         (before (buffer-list)))
     (should-error (zr-org-srs-x--dictionary-text "official"))
     (accept-process-output nil 0.02)
     (should-not (cl-set-difference (buffer-list) before))
     (should-not (cl-some #'process-live-p dictionary-clients)))))

(ert-deftest zr-org-srs-x-test-dictionary-uses-http-proxy-settings ()
  (zr-org-srs-x-test--with-dictionary
   (let ((dictionary-use-http-proxy t)
         (dictionary-proxy-server dictionary-server)
         (dictionary-proxy-port dictionary-port)
         (dictionary-server "dict.example")
         (dictionary-port 2628)
         (definitions dictionary-response-function))
     (setq dictionary-greeting nil
           dictionary-response-function
           (lambda (command)
             (cond
              ((string-prefix-p "CONNECT " command)
               "HTTP/1.1 200 Connection established\r\nProxy-Agent: test\r\n\r\n220 test DICT server\r\n")
              ((string-empty-p command) nil)
              (t (funcall definitions command)))))
     (should (string-match-p "猫の定義 from DICT" (zr-org-srs-x--dictionary-text "猫")))
     (should (member "CONNECT dict.example:2628 HTTP/1.1" dictionary-commands))
     (should (member "define * \"猫\"" dictionary-commands)))))

(ert-deftest zr-org-srs-x-test-dictionary-timeout-and-protocol-error-do-not-save-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-org-srs-x-test--with-dictionary
    (let* ((file (zr-org-srs-x--deck-file "lunadeck"))
           (buffer (zr-org-srs-x--buffer file))
           (before (with-current-buffer buffer (buffer-string)))
           (zr-org-srs-x-dictionary-timeout 0.1))
      (dolist (response '(nil "150 1 definition\r\n151 \"猫\" edict \"English\"\r\n"
                         "150 1 definition\r\n151 \"猫\" edict \"English\"\r\ndefinition\r\n.\r\n500 error\r\n"))
        (setq dictionary-response-function (lambda (_command) response))
        (let ((result (zr-org-srs-x-request
                       (zr-org-srs-x--object "action" "addNote" "params"
                                             (zr-org-srs-x--object "note" (zr-org-srs-x-test--note "lunadeck"))))))
          (should-not (gethash "result" result))
          (should (string-match-p "Dictionary lookup timed out\\|Unexpected dictionary reply"
                                  (gethash "error" result))))
        (should (equal before (with-current-buffer buffer (buffer-string))))
        (should (equal before (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should-not (file-exists-p (expand-file-name ".zr-org-srs-x-notes.json" zr-org-srs-x-directory)))
        (accept-process-output nil 0.02)
        (should-not (cl-some #'process-live-p dictionary-clients)))))))

(ert-deftest zr-org-srs-x-test-capture-during-lookup-preserves-index-and-duplicates ()
  (zr-org-srs-x-test--require-srs)
  (dolist (same-word '(nil t))
    (zr-org-srs-x-test--with-decks
     (zr-org-srs-x-test--create-model)
     (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
     (let ((first-lookup t)
           (note (zr-org-srs-x-test--note "lunadeck" "猫")))
       (puthash "options" (zr-org-srs-x--object "allowDuplicate" :false) note)
       (cl-letf (((symbol-function 'zr-org-srs-x--dictionary-text)
                  (lambda (_word)
                    ;; A DICT wait can run another HTTP request's process filter.
                    (when first-lookup
                      (setq first-lookup nil)
                      (zr-org-srs-x-test--call "addNote" "note"
                                               (zr-org-srs-x-test--note "lunadeck"
                                                                        (if same-word "猫" "犬"))))
                    "")))
         (let ((response (zr-org-srs-x-request
                          (zr-org-srs-x--object "action" "addNote" "params"
                                                (zr-org-srs-x--object "note" note)))))
           (if same-word
               (should (equal (gethash "error" response) "cannot create note because it is a duplicate"))
             (should (integerp (gethash "result" response))))))
       (should (= (length (zr-org-srs-x-test--call "findNotes" "query" ""))
                  (if same-word 1 2)))
       (should-not (file-exists-p (expand-file-name ".zr-org-srs-x-notes.json" zr-org-srs-x-directory)))))))

(ert-deftest zr-org-srs-x-test-custom-model-duplicates-and-search-use-heading ()
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
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "custom"))
       (goto-char (point-min))
       (re-search-forward "^\\* ")
       (org-back-to-heading)
       (should (equal (org-get-heading t t t t) "first prompt")))
     (puthash "word" "犬" (gethash "fields" note))
     (let ((response (zr-org-srs-x-request
                      (zr-org-srs-x--object "action" "addNote" "params"
                                            (zr-org-srs-x--object "note" note)))))
       (should (equal (gethash "error" response) "cannot create note because it is a duplicate")))
     (puthash "prompt" "second prompt" (gethash "fields" note))
     (let ((second (zr-org-srs-x-test--call "addNote" "note" note)))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"custom\" w:\"first prompt\"")
                      (vector first)))
       (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"custom\" w:\"second prompt\"")
                      (vector second)))
       (dolist (word '("猫" "犬"))
         (should (equal (zr-org-srs-x-test--call
                         "findNotes" "query" (format "deck:\"custom\" w:\"%s\"" word))
                        [])))))))

(ert-deftest zr-org-srs-x-test-content-cannot-create-extra-org-structure ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let ((note (zr-org-srs-x-test--note "lunadeck")))
     (puthash "remarks" "<p>* new heading</p><p>*** [edict]</p><p>#+begin_src emacs-lisp</p><p>:END:</p>"
              (gethash "fields" note))
     (zr-org-srs-x-test--call "addNote" "note" note))
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (let ((headings nil))
       (org-map-entries (lambda () (push (org-get-heading t t t t) headings)) nil 'file)
       (should (equal (nreverse headings) '("猫" "Front" "Back"))))
     (should (string-match-p ",#\\+begin_src" (buffer-string)))
     (should (string-match-p "^,\\*\\*\\* \\[edict\\]" (buffer-string)))
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

(ert-deftest zr-org-srs-x-test-numeric-timestamp-id-in-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (let* ((note (zr-org-srs-x-test--note "lunadeck" "テスト"))
          (id (zr-org-srs-x-test--call "addNote" "note" note)))
     (should (integerp id))
     (should (> id 1000000000000))
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
       (goto-char (point-min))
       (re-search-forward "^\\* ")
       (org-back-to-heading)
       (should (equal (org-entry-get nil "ID") (number-to-string id)))
       (should (equal (org-element-map (org-element-parse-buffer) 'node-property
                        (lambda (property) (org-element-property :key property)))
                      '("ID")))
       (should (string-match-p (format "#\\+NAME: srsitem:%d::card::back" id) (buffer-string)))))))

(provide 'zr-org-srs-x-test)
;;; zr-org-srs-x-test.el ends here
