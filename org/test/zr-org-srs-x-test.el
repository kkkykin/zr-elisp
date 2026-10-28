;;; zr-org-srs-x-test.el --- Tests for Org-srs AnkiConnect capture -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url-util)
(require 'dictionary)
(require 'org-capture)
(require 'zr-test-helpers)
(require 'zr-org-srs-x)
(require 'zr-dictionary-test-helpers)

(defvar dictionary-current-server)

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
          (zr-org-srs-x-default-deck "Default")
          (zr-dictionary-dictionaries nil)
          (zr-dictionary-name-function #'zr-dictionary-format-name)
          (zr-org-srs-x-media-path-function #'identity)
          (zr-org-srs-x-model-alist (default-value 'zr-org-srs-x-model-alist))
          (org-link-parameters (copy-tree org-link-parameters))
          (zr-org-link-mode nil)
          (zr-org-link--saved nil)
          (zr-org-srs-x--server nil)
          (zr-org-srs-x--clients nil)
          (zr-org-srs-x--models (make-hash-table :test #'equal))
          (zr-org-srs-x--last-id 0))
      (unwind-protect
          (progn (zr-org-link-mode 1) ,@body)
        (zr-org-srs-x-stop)
        (zr-org-link-mode -1)
        (org-make-link-regexps)))))

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

(defmacro zr-org-srs-x-test--with-dictionary-results (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (dictionary-mode)
     (zr-dictionary--display
      (zr-dictionary--make-view
       :word "cat & 猫" :dictionaries '((:server "source.example" :port 2628 :dictionary (first second)))
       :strategy "prefix" :name-function #'zr-dictionary-format-name
       :entries '(("First" "First definition. See {other word}.")
                  ("Second" "Second definition. 100% %s %t %? %(error \"literal\") %^{literal}"
                   "Second paragraph.\n* Literal heading\n#+literal: text"))
       :status 'complete))
     ,@body))

(ert-deftest zr-org-srs-x-test-dictionary-capture-point-default-and-links ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (save-window-excursion
     (zr-org-srs-x-test--with-dictionary-results
      (goto-char (point-min))
      (search-forward "Second definition")
      (let ((org-capture-templates nil)
            (org-capture-mode-hook nil)
            (org-capture-after-finalize-hook nil)
            (org-store-link-plist nil))
        (cl-letf (((symbol-function 'zr-dictionary-lookup)
                   (lambda (&rest _) (ert-fail "Capture must reuse displayed definitions"))))
          (call-interactively (key-binding "c"))
          (should org-capture-mode)
          (should (equal (org-get-heading t) "cat & 猫"))
          (should (org-srs-item-exists-p '(card back)))
          (should-not (string-match-p "First definition" (buffer-string)))
          (should (string-match-p (regexp-quote "100% %s %t %? %(error \"literal\")")
                                  (buffer-string)))
          (should (string-match-p "Second paragraph" (buffer-string)))
          (should (string-match-p "^,\\* Literal heading" (buffer-string)))
          (should (string-match-p "^,#\\+literal: text" (buffer-string)))
          (let ((id (zr-org-srs-x--note-id)))
            (should (integerp id))
            (save-excursion
              (re-search-forward "\\[\\[dict:\\([^]\n]+\\)\\]")
              (pcase-let ((`(,word ,dictionaries ,strategy)
                           (zr-org-link--dict-query (match-string 1))))
                (should (equal word "cat & 猫"))
                (should (equal dictionaries '(((:dictionary "first") (:dictionary "second")))))
                (should (equal strategy "prefix"))))
            (org-capture-finalize)
            (should (equal (zr-org-srs-x--find-notes "deck:Default") (list id)))
            (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Default"))
              (should-not (buffer-modified-p))))))))))

(ert-deftest zr-org-srs-x-test-dictionary-capture-region-t-renderer-and-cancel ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (let ((zr-org-srs-x-model-alist
          '((modelofluna . ((name . "Wrong") (front . "Wrong") (back . "Wrong")))
            (t . ((deck . "Words::Selected")
                  (dictionaries . ((:dictionary invalid)))
                  (name . ("Card %s" .word)) (front . ("Prompt %s" .word))
                  (back . ("%s" dictionary)))))))
     (save-window-excursion
       (zr-org-srs-x-test--with-dictionary-results
        (goto-char (point-min))
        (search-forward "First definition")
        (set-mark (point))
        (search-forward "Second definition")
        (let ((transient-mark-mode t) (mark-active t)
              (org-capture-templates (list (zr-org-srs-x-capture-template "s" "Selected dictionaries")))
              (org-capture-mode-hook nil)
              (org-capture-after-finalize-hook nil)
              (org-store-link-plist nil))
          (cl-letf (((symbol-function 'zr-dictionary-lookup)
                     (lambda (&rest _) (ert-fail "Unexpected dictionary lookup"))))
            (org-capture nil "s")
            (should (equal (org-get-heading t) "Card cat & 猫"))
            (should (string-match-p "Prompt cat & 猫" (buffer-string)))
            (should (string-match-p "^\\*\\*\\* First$" (buffer-string)))
            (should (string-match-p "^\\*\\*\\* Second$" (buffer-string)))
            (should (string-match-p "Second paragraph" (buffer-string)))
            (should (string-match-p "See \\[\\[dict:" (buffer-string)))
            (should (= (length (org-map-entries (lambda () (point)) "LEVEL=1")) 1))
            (org-capture-kill)
            (should-not (zr-org-srs-x--find-notes ""))
            (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Words::Selected"))
              (should (string-blank-p (buffer-string)))))))))))

(ert-deftest zr-org-srs-x-test-dictionary-capture-rejects-non-definitions ()
  (zr-org-srs-x-test--with-decks
   (let ((org-capture-templates (list (zr-org-srs-x-capture-template))))
     (with-temp-buffer
       (should-error (org-capture nil "d") :type 'user-error))
     (zr-org-srs-x-test--with-dictionary-results
      (goto-char (point-min))
      (should-error (org-capture nil "d") :type 'user-error)
      (search-forward "First definition")
      (let ((zr-dictionary--matching-p t))
        (should-error (org-capture nil "d") :type 'user-error)))
     (should-not (file-exists-p zr-org-srs-x-directory)))))

(ert-deftest zr-org-srs-x-test-dictionary-capture-edited-duplicate ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-create-card "Existing")
   (save-window-excursion
     (zr-org-srs-x-test--with-dictionary-results
      (goto-char (point-min))
      (search-forward "First definition")
      (let ((org-capture-templates (list (zr-org-srs-x-capture-template)))
            (org-store-link-plist nil))
        (org-capture nil "d")
        (org-edit-headline "Existing")
        (should-error (org-capture-finalize))
        (org-capture-kill)
        (should (= (length (zr-org-srs-x--find-notes "")) 1)))))))

(ert-deftest zr-org-srs-x-test-model-templates-and-fallback ()
  (let* ((fields '(("word" . "猫") ("example_sentence" . "A %s $dictionary \\1 example")
                   ("remarks" . "remark")))
         (variables '((dictionary . "definition %s $audio") (picture . "image")
                      (audio . "sound") (video . "")))
         (zr-org-srs-x-model-alist
          '((modelofluna . ((name . ("%s" .word)) (front . ("%s" .example_sentence))
                           (back . ("%s\n\n%s\n%s %s%s %s $10 %%10"
                                    .remarks dictionary picture audio video .missing))))
            ("other" . ((name . ("Other %s" .word)) (front . ("%s" .remarks)) (back . "")))
            (t . zr-org-srs-x-render-default-note))))
    (should (equal (zr-org-srs-x--render "modelofluna" fields variables)
                   '((name . "猫") (front . "A %s $dictionary \\1 example")
                     (back . "remark\n\ndefinition %s $audio\nimage sound  $10 %10"))))
    (should (equal (zr-org-srs-x--render "other" fields variables)
                   '((name . "Other 猫") (front . "remark") (back . ""))))
    (let ((fallback (zr-org-srs-x--render "unconfigured" fields variables)))
      (should (equal (alist-get 'name fallback) "猫"))
      (should (equal (alist-get 'front fallback) "猫"))
      (should (string-match-p "definition %s \\$audio" (alist-get 'back fallback))))))

(ert-deftest zr-org-srs-x-test-literal-text-and-format-references ()
  (let ((literal "$.word $dictionary $$ 100% %s")
        (fields '(("word" . "猫") ("dictionary" . "field definition")))
        (variables '((dictionary . "lookup definition") (video . ""))))
    (should (equal (zr-org-srs-x--template literal fields variables) literal))
    (should (equal (zr-org-srs-x--template '("%% %s | %s | %s | %s"
                                           .word .dictionary dictionary video)
                                         fields variables)
                   "% 猫 | field definition | lookup definition | "))
    (should (equal (zr-org-srs-x--template '("%s" .missing) fields variables) ""))))

(ert-deftest zr-org-srs-x-test-manual-card-default-model-and-dictionary ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-dictionary-test-with-server
    (setq dictionary-response-function
          (lambda (_command) (zr-dictionary-test-definition "edict" "See {猫}.")))
    (let* ((word "<猫 & dog>")
           (zr-org-srs-x-model-alist
            '((modelofluna . ((name . "Wrong") (front . "") (back . "")))
              (t . ((deck . "Words::Manual") (dictionaries . ((:server t :port t :dictionary edict)))
                    (name . ("%s" .word)) (front . ("%s" .word)) (back . ("%s" dictionary))))))
           (id (zr-org-srs-x-create-card word)))
      (should (integerp id))
      (should (= (hash-table-count zr-org-srs-x--models) 0))
      (should-not zr-org-srs-x--server)
      (should (file-exists-p (zr-org-srs-x--deck-file "Words::Manual")))
      (should (equal (zr-dictionary-test-queries dictionary-commands)
                     (list (format "define edict \"%s\"" word))))
      (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Words::Manual"))
        (goto-char (org-find-property "ID" (number-to-string id)))
        (should (equal (org-get-heading t) word))
        (cl-multiple-value-bind (front back) (org-srs-item-card-regions)
          (should (string-match-p (regexp-quote word)
                                  (buffer-substring-no-properties (car front) (cdr front))))
          (let ((text (zr-org-srs-x-test--card-subtree-text back)))
            (should (string-match-p "See \\[\\[dict:" text))
            (should (string-match-p "\\*\\*\\* \\[edict\\]" text))))
        (should-not (buffer-modified-p)))))))

(ert-deftest zr-org-srs-x-test-manual-interactive-current-deck-and-region ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--call "createDeck" "deck" "Current")
   (save-window-excursion
     (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Current"))
       (goto-char (point-min))
       (search-forward "Current")
       (set-mark (- (point) (length "Current")))
       (let ((transient-mark-mode t) (mark-active t) (current-prefix-arg nil))
         (cl-letf (((symbol-function 'read-string)
                    (lambda (_prompt _initial _history default &rest _)
                      (should (equal default "Current"))
                      "manual phrase"))
                   ((symbol-function 'completing-read)
                    (lambda (&rest _) (ert-fail "Unexpected deck prompt"))))
           (let ((id (call-interactively #'zr-org-srs-x-create-card)))
             (should (equal (zr-org-srs-x--find-notes "deck:Current w:\"manual phrase\"")
                            (list id))))))))))

(ert-deftest zr-org-srs-x-test-model-default-deck-and-explicit-override ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call
    "createModel" "modelName" "other" "inOrderFields" ["word"] "css" ""
    "cardTemplates" (vector (zr-org-srs-x--object "Name" "Card" "Front" "" "Back" "")))
   (let ((zr-org-srs-x-model-alist
          '((modelofluna . ((deck . "Model") (name . ("%s" .word))
                           (front . ("%s" .word)) (back . "")))
            (t . ((deck . "Fallback") (name . ("%s" .word))
                  (front . ("%s" .word)) (back . ""))))))
     (dolist (deck '("Model" "Fallback" "Explicit"))
       (zr-org-srs-x-test--call "createDeck" "deck" deck))
     (let ((note (zr-org-srs-x-test--note "ignored" "model default")))
       (remhash "deckName" note)
       (let ((id (zr-org-srs-x-test--call "addNote" "note" note)))
         (should (equal (zr-org-srs-x--find-notes "deck:Model") (list id)))))
     (let ((id (zr-org-srs-x-test--call "addNote" "note"
                                            (zr-org-srs-x-test--note "Explicit" "override"))))
       (should (equal (zr-org-srs-x--find-notes "deck:Explicit") (list id))))
     (let ((id (zr-org-srs-x-test--call
                "addNote" "note" (zr-org-srs-x--object
                                  "modelName" "other" "fields"
                                  (zr-org-srs-x--object "word" "fallback")))))
       (should (equal (zr-org-srs-x--find-notes "deck:Fallback") (list id))))
     (let ((id (zr-org-srs-x-create-card "manual override" "Explicit")))
       (should (memq id (zr-org-srs-x--find-notes "deck:Explicit")))))))

(ert-deftest zr-org-srs-x-test-dictionaries-local-model-global-priority ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-dictionary-test-with-server
    (let* ((zr-dictionary-dictionaries '((:server t :port t :dictionary globaldb)))
           (renderer '((deck . "Words") (dictionaries . ((:server t :port t :dictionary modeldb)))
                       (name . ("%s" .word)) (front . ("%s" .word)) (back . ("%s" dictionary))))
           (zr-org-srs-x-model-alist (list (cons t renderer)))
           (safe-local-variable-values
            (cons '(zr-dictionary-dictionaries . ((:server t :port t :dictionary localdb))) safe-local-variable-values)))
      (make-directory zr-org-srs-x-directory t)
      (with-temp-file (zr-org-srs-x--deck-file "Words")
        (insert "# -*- zr-dictionary-dictionaries: ((:server t :port t :dictionary localdb)); -*-\n#+title: Words\n"))
      (dolist (case '((localdb localdb) (local-nil nil) (model modeldb)
                      (model-nil globaldb) (model-absent globaldb)))
        (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Words"))
          (pcase (car case)
            ('local-nil (setq-local zr-dictionary-dictionaries nil))
            ('model (kill-local-variable 'zr-dictionary-dictionaries))
            ('model-nil (setf (alist-get 'dictionaries renderer) nil))
            ('model-absent (setq renderer (assq-delete-all 'dictionaries renderer))
                           (setcdr (assq t zr-org-srs-x-model-alist) renderer))))
        (setq dictionary-commands nil)
        (let* ((word (symbol-name (car case)))
               (id (zr-org-srs-x-create-card word))
               (database (cadr case)))
          (should (equal (zr-dictionary-test-queries dictionary-commands)
                         (when database (list (format "define %s \"%s\"" database word)))))
          (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Words"))
            (goto-char (org-find-property "ID" (number-to-string id)))
            (let ((end (save-excursion (org-end-of-subtree t t) (point))))
              (if database
                  (progn
                    (re-search-forward "\\[\\[dict:\\([^]\n]+\\)\\]" end)
                    (should (equal (cadr (zr-org-link--dict-query (match-string 1)))
                                   (list (list (list :dictionary (symbol-name database)))))))
                (should-not (re-search-forward "\\[\\[dict:" end t)))))))
      (zr-org-srs-x-test--create-model)
      (push '(modelofluna . ((deck . "Anki") (dictionaries . ((:server t :port t :dictionary ankidb)))
                            (name . ("%s" .word)) (front . ("%s" .word))
                            (back . ("%s" dictionary))))
            zr-org-srs-x-model-alist)
      (zr-org-srs-x-test--call "createDeck" "deck" "Anki")
      (setq dictionary-commands nil)
      (let ((note (zr-org-srs-x-test--note "ignored" "Anki word")))
        (remhash "deckName" note)
        (zr-org-srs-x-test--call "addNote" "note" note))
      (should (equal (zr-dictionary-test-queries dictionary-commands)
                     '("define ankidb \"Anki word\"")))
      (should (equal zr-dictionary-dictionaries '((:server t :port t :dictionary globaldb))))))))

(ert-deftest zr-org-srs-x-test-back-without-dictionary-skips-lookup ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary (invalid similar)))))
     (cl-letf (((symbol-function 'zr-dictionary-lookup)
                (lambda (&rest _) (ert-fail "Unexpected dictionary lookup"))))
       (dolist (back '("" "dictionary $dictionary %s" ("%s" .word)
                      ("%s" .dictionary) ("dictionary") ("%% %s" .word)))
         (let ((zr-org-srs-x-model-alist
                `((t . ((name . ("%s" .word)) (front . ("%s%s" .word dictionary))
                        (back . ,back))))))
           (should (integerp (zr-org-srs-x-create-card (format "word %S" back) "Words")))))))))

(ert-deftest zr-org-srs-x-test-manual-errors-do-not-save-cards ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (dolist (word '(nil 42 "" " " "two\nlines"))
     (should-error (zr-org-srs-x-create-card word "Words") :type 'user-error))
   (should-error (zr-org-srs-x-create-card "word" "../escape"))
   (should-not (file-exists-p zr-org-srs-x-directory))
   (cl-letf (((symbol-function 'zr-dictionary-lookup)
              (lambda (&rest _) (error "lookup failed"))))
     (should-error (zr-org-srs-x-create-card "word" "Words")))
   (should-not (file-exists-p (zr-org-srs-x--deck-file "Words")))
   (zr-org-srs-x-create-card "word" "Words")
   (let* ((buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Words")))
          (before (with-current-buffer buffer (buffer-string))))
     (should-error (zr-org-srs-x-create-card "word" "Words"))
     (cl-letf (((symbol-function 'zr-org-srs-x--save) (lambda () (error "disk full"))))
       (should-error (zr-org-srs-x-create-card "another" "Words")))
     (should (equal before (with-current-buffer buffer (buffer-string)))))))

(ert-deftest zr-org-srs-x-test-protocol-routing-and-mode-lifecycle ()
  (zr-org-srs-x-test--require-srs)
  (require 'org-protocol)
  (zr-org-srs-x-test--with-decks
   (let* ((sentinel '("other" :protocol "other" :function ignore))
          (org-protocol-protocol-alist (list sentinel))
          (zr-org-srs-x--protocol-entry nil)
          (zr-org-srs-x-protocol-mode nil)
          (zr-org-srs-x-model-alist
           '((t . ((deck . "Protocol") (name . ("%s" .word))
                   (front . ("%s" .word)) (back . "")))))
          (word "猫 & dog?%+中文"))
     (unwind-protect
         (progn
           (zr-org-srs-x-protocol-mode 1)
           (zr-org-srs-x-protocol-mode 1)
           (should (= (length org-protocol-protocol-alist) 2))
           (should-not
            (org-protocol-check-filename-for-protocol
             (concat "org-protocol://srs-card?word=" (url-hexify-string word)
                     "&deck=" (url-hexify-string "Words::日本語")) nil nil))
           (should (= (length (zr-org-srs-x--find-notes "deck:\"Words::日本語\"")) 1))
           (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "Words::日本語"))
             (goto-char (point-min))
             (re-search-forward "^\\* ")
             (should (equal (org-get-heading t) word)))
           (should-not (zr-org-srs-x-protocol-create-card "word=default%20phrase"))
           (should (= (length (zr-org-srs-x--find-notes "deck:Protocol")) 1))
           (should-error (zr-org-srs-x-protocol-create-card '(:deck "Words")) :type 'user-error)
           (should-error (zr-org-srs-x-protocol-create-card '(:word "word" :deck "../escape")))
           (should-not zr-org-srs-x--server))
       (zr-org-srs-x-protocol-mode -1)
       (zr-org-srs-x-protocol-mode -1))
     (should (equal org-protocol-protocol-alist (list sentinel))))))

(ert-deftest zr-org-srs-x-test-model-and-part-render-functions ()
  (let* ((fields '(("word" . "猫")))
         (variables '((dictionary . "definition")))
         (zr-org-srs-x-model-alist
          `((whole . ,(lambda (input values)
                        (should (eq input fields))
                        (should (eq values variables))
                        '((name . "Function") (front . "$.word") (back . "$dictionary"))))
            (part . ((name . ("%s" .word)) (front . "text")
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
          '((modelofluna . ((name . ("%s\n%s" .word .rubytextHtml))
                           (front . ("%s" .example_sentence))
                           (back . ("%s\n\n%s\n\n%s\n\n%s\n\n%s"
                                    .remarks dictionary picture audio video))))))
         (note (zr-org-srs-x-test--note "lunadeck")))
     (dolist (kind '("picture" "audio" "video"))
       (puthash kind
                (vector (zr-org-srs-x--object "filename" (concat kind ".dat") "data" "YWJj"
                                             "fields" ["screenshot"]))
                note))
     (zr-dictionary-test-with-server
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
           '((modelofluna . ((name . ("Directory %s" .word))
                            (front . ("%s" .remarks)) (back . "")))))
          (file-renderers
           '((modelofluna . ((name . ("File %s" .word))
                            (front . ("%s" .example_sentence)) (back . "")))))
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
                       ((name . ("%s" .word)) (front . ("%s" unknown)) (back . "back"))
                       ((name . ("%s" .word)) (front . 42) (back . "back"))
                       ((name . ("%s" .word)) (front . (42 .word)) (back . "back"))
                       ((name . ("%s" .word)) (front . ("%s" . .word)) (back . "back"))
                       ((name . ("%s" .word)) (front . ("%s %s" .word)) (back . "back"))
                       ((name . ("%s" .word)) (front . ("%s" (error "Must not evaluate")))
                        (back . "back"))
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
          (cons '(zr-dictionary-dictionaries . ((:server t :port t :dictionary (dictd-db-eng-zho "gcide" similar))))
                safe-local-variable-values)))
     (with-temp-file file
       (insert "# -*- mode: text; zr-dictionary-dictionaries: ((:server t :port t :dictionary (dictd-db-eng-zho \"gcide\" similar))); -*-\n"
               "#+title: 英語\n"))
     (with-current-buffer (zr-org-srs-x--buffer file)
       (should (derived-mode-p 'org-mode))
       (should (local-variable-p 'zr-dictionary-dictionaries))
       (should (equal zr-dictionary-dictionaries '((:server t :port t :dictionary (dictd-db-eng-zho "gcide" similar)))))
       ;; Reusing a visited deck must keep its current buffer-local settings.
       (setq-local zr-dictionary-dictionaries nil)
       (should (eq (zr-org-srs-x--buffer file) (current-buffer)))
       (should-not zr-dictionary-dictionaries)))))

(ert-deftest zr-org-srs-x-test-directory-locals-and-file-override ()
  (zr-org-srs-x-test--with-decks
   (make-directory zr-org-srs-x-directory t)
   (with-temp-file (expand-file-name ".dir-locals.el" zr-org-srs-x-directory)
     (insert "((org-mode . ((zr-dictionary-dictionaries . ((:server t :port t :dictionary (dictd-db-eng-zho gcide similar)))))))\n"))
   (let ((safe-local-variable-values
          (append '((zr-dictionary-dictionaries . ((:server t :port t :dictionary (dictd-db-eng-zho gcide similar))))
                    (zr-dictionary-dictionaries . ((:server t :port t :dictionary "gcide")))
                    (zr-dictionary-dictionaries . nil))
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
                ("override" "# -*- zr-dictionary-dictionaries: ((:server t :port t :dictionary \"gcide\")); -*-\n")
                ("disabled" "# -*- zr-dictionary-dictionaries: nil; -*-\n")
                (_ ""))
              "#+title: 英語\n")))
         (with-current-buffer (zr-org-srs-x--buffer file (equal deck "new"))
           (should (derived-mode-p 'org-mode))
           (should (local-variable-p 'zr-dictionary-dictionaries))
           (should (equal zr-dictionary-dictionaries
                          (pcase deck
                            ("override" '((:server t :port t :dictionary "gcide")))
                            ("disabled" nil)
                            (_ '((:server t :port t :dictionary (dictd-db-eng-zho gcide similar)))))))))))
   (should-not zr-dictionary-dictionaries)))

(ert-deftest zr-org-srs-x-test-file-local-dictionaries-require-stage-list ()
  (zr-org-srs-x-test--with-decks
   (make-directory zr-org-srs-x-directory t)
   (let ((file (zr-org-srs-x--deck-file "英語"))
         (safe-local-variable-values
          (cons '(zr-dictionary-dictionaries . dictd-db-eng-zho)
                safe-local-variable-values)))
     (with-temp-file file
       (insert "# -*- zr-dictionary-dictionaries: dictd-db-eng-zho; -*-\n"))
     (with-current-buffer (zr-org-srs-x--buffer file)
       (should (eq zr-dictionary-dictionaries 'dictd-db-eng-zho))
       (let ((err (should-error (zr-org-srs-x--dictionary-text "hello"))))
         (should (string-match-p "Expected a list of dictionary search stages"
                                 (error-message-string err))))))))

(ert-deftest zr-org-srs-x-test-real-card-and-dictionaries-by-file-and-directory ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (make-directory zr-org-srs-x-directory t)
   (with-temp-file (expand-file-name ".dir-locals.el" zr-org-srs-x-directory)
     (insert "((org-mode . ((zr-dictionary-dictionaries . ((:server t :port t :dictionary edict))))))\n"))
   (zr-org-srs-x-test--call "createDeck" "deck" "英語")
   (zr-org-srs-x-test--call "createDeck" "deck" "日本語")
   (zr-org-srs-x-test--call "createDeck" "deck" "英語::directory")
   (dolist (deck '("英語" "日本語" "英語::directory"))
     ;; Reopen to apply trusted file and directory settings during capture.
     (let ((file (zr-org-srs-x--deck-file deck)))
       (with-current-buffer (zr-org-srs-x--buffer file)
         (unless (equal deck "英語::directory")
           (goto-char (point-min))
           (insert (format "# -*- zr-dictionary-dictionaries: %S; -*-\n"
                           (if (equal deck "英語") '((:server t :port t :dictionary edict)) '((:server t :port t :dictionary "local")))))
           (zr-org-srs-x--save))
         (kill-buffer (current-buffer)))))
   (zr-dictionary-test-with-server
    (setq dictionary-response-function
          (lambda (command)
            (if (string-prefix-p "define edict " command)
                "150 1 definition\r\n151 \"猫\" edict \"English\"\r\ncat from DICT\r\n.\r\n250 ok\r\n"
              "150 1 definition\r\n151 \"猫\" local \"日本語\"\r\n猫の定義 from DICT\r\n.\r\n250 ok\r\n")))
    (dolist (deck '("英語" "日本語" "英語::directory"))
     (let* ((note (zr-org-srs-x-test--note deck))
            (safe-local-variable-values
             (append '((zr-dictionary-dictionaries . ((:server t :port t :dictionary edict)))
                       (zr-dictionary-dictionaries . ((:server t :port t :dictionary "local"))))
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
    (should (equal zr-dictionary-dictionaries '((:server t :port t :dictionary t)))))))

(ert-deftest zr-org-srs-x-test-nil-dictionary-disables-lookup ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
     (setq-local zr-dictionary-dictionaries nil))
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
   (zr-dictionary-test-with-server
    (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))
    (should (member "define * \"猫\"" dictionary-commands))
    (should-not (cl-some (lambda (command) (string-prefix-p "match " command)) dictionary-commands))
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
   (zr-dictionary-test-with-server
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

(ert-deftest zr-org-srs-x-test-update-dictionaries-current-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-dictionary-test-with-server
    (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck"))
    (let* ((file (zr-org-srs-x--deck-file "lunadeck"))
           (on-disk (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (with-current-buffer (zr-org-srs-x--buffer file)
        (setq-local zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 dict2 similar))))
        (let ((zr-dictionary-name-function
               (lambda (name id _source) (format "%s [%s]" name id)))
              (before (buffer-substring-no-properties
                       (point-min) (save-excursion
                                     (goto-char (point-min))
                                     (re-search-forward "^\\[\\[dict:")
                                     (line-beginning-position)))))
          (setq dictionary-commands nil
                dictionary-response-function
                (lambda (command)
                  (zr-dictionary-test-definition
                   (if (string-prefix-p "define dict1 " command) "dict1" "dict2")
                   "New definition with {猫} and {a\r\n phrase}.\r\n* raw heading\r\n#+begin_src\r\n:END:")))
          ;; The active point can be inside an old dictionary subtree.
          (goto-char (point-min))
          (search-forward "cat from DICT")
          (call-interactively #'zr-org-srs-x-update-dictionaries)
          (should (equal (zr-dictionary-test-queries dictionary-commands)
                         '("define dict1 \"猫\"" "define dict2 \"猫\"")))
          (should (string-prefix-p before (buffer-string)))
          (should-not (string-match-p "from DICT\\|^\\*\\*\\* \\[edict\\]\\|^\\*\\*\\* \\[local\\]"
                                      (buffer-string)))
          (should (string-match-p "^\\*\\*\\* Dictionary dict1 \\[dict1\\]" (buffer-string)))
          (should (string-match-p "^\\*\\*\\* Dictionary dict2 \\[dict2\\]" (buffer-string)))
          (should (string-match-p "^,\\* raw heading" (buffer-string)))
          (should (string-match-p "^,#\\+begin_src" (buffer-string)))
          (should (string-match-p "^,:END:" (buffer-string)))
          ;; Followable query and references preserve the deck's stages.
          (let ((links (org-element-map (org-element-parse-buffer) 'link
                         (lambda (link)
                           (when (equal (org-element-property :type link) "dict")
                             (zr-org-link--dict-query (org-element-property :path link)))))))
            (should (equal links (mapcar (lambda (word)
                                              (list word '(((:dictionary ("dict1" similar))
                                                            (:dictionary ("dict2" similar)))) "."))
                                            '("猫" "猫" "a phrase" "猫" "a phrase")))))
          ;; Reload from text to verify replacement without transient properties.
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (erase-buffer)
            (insert text)
            (goto-char (point-min))
            (search-forward "New definition")
            (zr-org-srs-x-update-dictionaries)
            (should (equal text (buffer-substring-no-properties (point-min) (point-max)))))
          (goto-char (point-min))
          (re-search-forward "^\\* ")
          (org-back-to-heading)
          (should (org-srs-item-exists-p '(card back)))
          (setq-local zr-dictionary-dictionaries nil)
          (zr-org-srs-x-update-dictionaries)
          (should-not (string-match-p "dict:\\|New definition\\|^\\*\\*\\* " (buffer-string)))
          (should (string-prefix-p before (buffer-string)))
          (should (buffer-modified-p)))
        (should (equal on-disk (with-temp-buffer (insert-file-contents file) (buffer-string)))))))))

(ert-deftest zr-org-srs-x-test-update-dictionaries-region ()
  (with-temp-buffer
    (org-mode)
    (dolist (word '("one" "two" "three" "four"))
      (insert "* " word "\n:PROPERTIES:\n:ID: "
              (number-to-string (point)) "\n:END:\n** Front\n" word "\n** Back\nNotes\n")
      ;; Both replacement and appending can insert at the next card's marker.
      (unless (equal word "two")
        (insert "*** [old]\nold definition\n")))
    (let ((outside (save-excursion
                     (goto-char (point-min))
                     (search-forward "* four")
                     (buffer-substring-no-properties (line-beginning-position) (point-max))))
          (words nil)
          (transient-mark-mode t))
      (goto-char (point-min))
      (search-forward "old definition")
      (push-mark (point) t t)
      (search-forward "* four")
      (beginning-of-line)
      (setq mark-active t)
      (cl-letf (((symbol-function 'zr-org-srs-x--dictionary-text)
                 (lambda (word)
                   (push word words)
                   (concat (propertize "*** " 'zr-org-srs-x--dictionary-heading t)
                           "[new]\n" word " definition"))))
        (call-interactively #'zr-org-srs-x-update-dictionaries))
      (should (equal (nreverse words) '("one" "two" "three")))
      (should (= (how-many "^\\*\\*\\* \\[new\\]" (point-min) (point-max)) 3))
      (should (= (how-many "old definition" (point-min) (point-max)) 1))
      (should (string-suffix-p outside (buffer-string))))))

(ert-deftest zr-org-srs-x-test-update-dictionaries-remove-old-definitions ()
  (zr-dictionary-test-with-server
   (dolist (configuration '(nil ((:server t :port t :dictionary dict1))))
     (with-temp-buffer
       (org-mode)
       (insert "* word\n:PROPERTIES:\n:ID: 1\n:END:\n"
               "** Front\nPrompt\n*** [old-front]\nOld front definition\n"
               "** Back\nNotes\n*** [old-back]\nOld back definition\n")
       (setq-local zr-dictionary-dictionaries configuration)
       (setq dictionary-commands nil
             dictionary-response-function (lambda (_command) "552 no match\r\n"))
       (goto-char (point-min))
       (zr-org-srs-x-update-dictionaries)
       (should (equal (buffer-string)
                      (concat "* word\n:PROPERTIES:\n:ID: 1\n:END:\n"
                              "** Front\nPrompt\n** Back\nNotes\n")))
       (should (equal (zr-dictionary-test-queries dictionary-commands)
                      (when configuration '("define dict1 \"word\""))))))))

(ert-deftest zr-org-srs-x-test-update-dictionaries-failure-rolls-back-region ()
  (zr-dictionary-test-with-server
   (with-temp-buffer
     (org-mode)
     (insert "* one\n:PROPERTIES:\n:ID: 1\n:END:\n** Front\nPrompt\n** Back\nNotes\n"
             "*** [old]\nOld one definition\n"
             "* two\n:PROPERTIES:\n:ID: 2\n:END:\n** Front\nPrompt\n** Back\nNotes\n"
             "*** [old]\nOld two definition\n")
     (let ((before (buffer-string)))
       (set-buffer-modified-p nil)
       (setq dictionary-response-function
             (lambda (command)
               (if (string-match-p "\"one\"" command)
                   (zr-dictionary-test-definition "dict1" "New one definition")
                 "500 error\r\n")))
       (should-error (zr-org-srs-x-update-dictionaries (point-min) (point-max)))
       (should (equal before (buffer-string)))
       (should-not (buffer-modified-p))))))

(ert-deftest zr-org-srs-x-test-update-dictionaries-rejects-non-cards ()
  (with-temp-buffer
    (should-error (zr-org-srs-x-update-dictionaries) :type 'user-error)
    (org-mode)
    (insert "Preamble\n* ordinary\n** Back\nNotes\n")
    (goto-char (point-min))
    (should-error (zr-org-srs-x-update-dictionaries) :type 'user-error)
    (search-forward "Notes")
    (should-error (zr-org-srs-x-update-dictionaries) :type 'user-error)
    (should-error (zr-org-srs-x-update-dictionaries (point-min) (point-max)) :type 'user-error)))

(ert-deftest zr-org-srs-x-test-dictionary-names-handle-unknown-and-custom-function ()
  (zr-org-srs-x-test--require-srs)
  (dolist (custom '(nil t))
    (zr-org-srs-x-test--with-decks
     (zr-org-srs-x-test--create-model)
     (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
     (let* ((names nil)
            (zr-dictionary-name-function
             (if custom
                 (lambda (name id _source)
                   (should (equal buffer-file-name (zr-org-srs-x--deck-file "lunadeck")))
                   (push (cons name id) names)
                   (format "%s [%s]" name id))
               #'zr-dictionary-format-name)))
       (zr-dictionary-test-with-server
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

(ert-deftest zr-org-srs-x-test-dictionary-first-match-fills-back-without-changing-word ()
  (zr-org-srs-x-test--require-srs)
  (dolist (database '("dictd-db-eng-zho" "*" "!"))
    (zr-org-srs-x-test--with-decks
     (zr-org-srs-x-test--create-model)
     (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
     (zr-dictionary-test-with-server
      (let ((zr-dictionary-dictionaries (list (list :server t :port t :dictionary (list database 'similar)))))
        (setq dictionary-response-function
              (lambda (command)
                (cond
                 ((equal command (format "define %s \"reserved\"" database)) "552 no match\r\n")
                 ((equal command (format "match %s . \"reserved\"" database))
                  (concat "152 3 matches\r\n"
                          "dictd-db-eng-zho \"reserve\"\r\n"
                          "dictd-db-eng-zho \"reservation\"\r\n"
                          "other \"reserved word\"\r\n.\r\n250 ok\r\n"))
                 ((equal command "define dictd-db-eng-zho \"reserve\"")
                  (concat "150 1 definition\r\n151 \"reserve\" dictd-db-eng-zho \"English-中文\"\r\n"
                          "reserve\r\n保留；储备\r\n.\r\n250 ok\r\n"))
                 (t "500 unexpected command\r\n"))))
        (let* ((window (selected-window))
               (visible-buffer (window-buffer window))
               (id (zr-org-srs-x-test--call "addNote" "note" (zr-org-srs-x-test--note "lunadeck" "reserved"))))
          (should (eq (selected-window) window))
          (should (eq (window-buffer window) visible-buffer))
          (should (equal (reverse (cl-remove-if
                                   (lambda (command) (string-prefix-p "client " command)) dictionary-commands))
                         (list (format "define %s \"reserved\"" database)
                               (format "match %s . \"reserved\"" database)
                               "define dictd-db-eng-zho \"reserve\"")))
          (should (equal (zr-org-srs-x-test--call "findNotes" "query" "deck:\"lunadeck\" w:\"reserved\"")
                         (vector id)))
          (with-current-buffer (zr-org-srs-x--buffer (zr-org-srs-x--deck-file "lunadeck"))
            (goto-char (point-min))
            (re-search-forward "^\\* ")
            (org-back-to-heading)
            (should (equal (org-get-heading t) "reserved"))
            (cl-multiple-value-bind (front back) (org-srs-item-card-regions)
              (should (string-match-p "^reserved$" (zr-org-srs-x-test--card-subtree-text front)))
              (should (string-match-p "^\\*\\*\\* \\[dictd-db-eng-zho\\]\nreserve\n保留；储备"
                                      (zr-org-srs-x-test--card-subtree-text back)))))))))))

(ert-deftest zr-org-srs-x-test-dictionary-timeout-and-protocol-error-do-not-save-card ()
  (zr-org-srs-x-test--require-srs)
  (zr-org-srs-x-test--with-decks
   (zr-org-srs-x-test--create-model)
   (zr-org-srs-x-test--call "createDeck" "deck" "lunadeck")
   (zr-dictionary-test-with-server
    (let* ((file (zr-org-srs-x--deck-file "lunadeck"))
           (buffer (zr-org-srs-x--buffer file))
           (before (with-current-buffer buffer (buffer-string)))
           (zr-dictionary-timeout 0.1))
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
