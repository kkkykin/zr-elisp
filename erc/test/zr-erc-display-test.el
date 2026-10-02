;;; zr-erc-display-test.el --- Display name tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'erc-fill)
(require 'erc-stamp)
(require 'zr-erc-display)
(require 'zr-erc-completion)
(require 'zr-erc-reply)

(defconst zr-erc-display-test--rules
  '((:match (:sender "^nichi_bot$")
     :source text :regexp "\\[\\([^]]+\\)\\]" :replace-sender "\\1")))

(defun zr-erc-display-test--message (name)
  "Insert a relay message containing NAME and return its speaker position."
  (insert "<")
  (prog1 (point)
    (insert (propertize "nichi_bot" 'erc--speaker "nichi_bot"
                        'font-lock-face 'erc-nick-default-face)
            "> " (string 3) "11[" name "]" (string 15) " hello\n")))

(ert-deftest zr-erc-display-extraction ()
  (let ((zr-erc-display-rules
         '((:match (:sender "^bot$") :source body
            :regexp "\\[\\([^]|]+\\)|\\([^]]+\\)\\]" :replace-sender "\\2")
           (:source (:tag "+display-name") :replace-sender "\\&"))))
    (should (equal (plist-get (zr-erc-display--match
                    (list :sender "bot" :body (concat (string 3) "11[Name|123]"))) :sender) "123"))
    (should (equal (plist-get (zr-erc-display--match
                    '(:sender "other" :body "[Name|123]"
                      :tags (("+display-name" . "Sydney Dian")))) :sender) "Sydney Dian"))
    (should (equal (plist-get (zr-erc-display--match '(:tags (("+display-name" . "")))) :sender) ""))
    (dolist (name (list "  " "bad\nname" (concat (string 3) "11Name")))
      (should-not (plist-get (zr-erc-display--match
                   (list :tags (list (cons "+display-name" name)))) :sender)))))

(ert-deftest zr-erc-display-toggle-history-and-completion ()
  (let ((erc-modules nil)
        (zr-erc-display-rules zr-erc-display-test--rules)
        (zr-erc-completion-rules
         '((:source text :regexp "^<\\([^>]+\\)>" :groups (1)))))
    (with-temp-buffer
      (erc-mode)
      (let* ((speaker (zr-erc-display-test--message "Sydney Dian"))
             (original (buffer-string)))
        (setq erc-insert-marker (copy-marker (point)))
        (insert "ERC> @ni")
        (setq erc-input-marker (copy-marker (- (point) 3)))
        (let ((candidates (zr-erc-completion--candidates)))
          (should (equal candidates '("nichi_bot")))
          (erc-zr-display-mode 1)
          (should (equal (get-char-property speaker 'display) "Sydney Dian"))
          (should (equal (buffer-substring (point-min) erc-insert-marker) original))
          (should (equal (zr-erc-completion--candidates) candidates))
          (let ((erc-complete-functions '(zr-erc-completion-at-point)))
            (erc-tab 1)
            (should (equal (buffer-substring-no-properties erc-input-marker (point-max))
                           "@nichi_bot")))
          (zr-erc-display-refresh)
          (should (= (length (overlays-at speaker)) 1))
          (with-temp-buffer
            (erc-mode)
            (should-not erc-zr-display-mode)
            (should-not (memq #'zr-erc-display--insert erc-insert-post-hook)))
          (should erc-zr-display-mode)
          (save-restriction
            (narrow-to-region erc-input-marker (point-max))
            (erc-zr-display-mode -1))
          (should-not (get-char-property speaker 'display))
          (should (equal (zr-erc-completion--candidates) candidates))
          (erc-zr-display-mode 1)
          (should (equal (get-char-property speaker 'display) "Sydney Dian")))))))

(ert-deftest zr-erc-display-incoming-metadata ()
  (let ((erc-modules nil)
        (zr-erc-display-rules
         '((:match (:sender "^nichi_bot$") :source body
            :regexp "\\[\\([^]]+\\)\\]" :replace-sender "\\1"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (let* ((body (concat (string 3) "11[Sydney Dian]" (string 15) " hello"))
             (erc-message-parsed
              (make-erc-response :sender "nichi_bot!u@h" :command "PRIVMSG"
                                 :contents body :unparsed ":nichi_bot PRIVMSG #c :hello"))
             (speaker (zr-erc-display-test--message "Rendered differently"))
             (before (zr-erc-context erc-message-parsed
                                      (buffer-substring-no-properties (point-min) (point-max)))))
        (run-hooks 'erc-insert-post-hook)
        (setq erc-insert-marker (copy-marker (point-max)))
        (should (equal (get-char-property speaker 'display) "Sydney Dian"))
        (should (equal (zr-erc-context erc-message-parsed
                                       (buffer-substring-no-properties (point-min) (point-max)))
                       before))
        (should (equal (erc-response.contents erc-message-parsed) body))
        (should (equal (get-text-property speaker 'erc--speaker) "nichi_bot"))
        (should-not (get-text-property speaker 'tags))
        (erc-zr-display-mode -1)
        (erc-zr-display-mode 1)
        (should (equal (get-char-property speaker 'display) "Sydney Dian"))))))

(defun zr-erc-display-test--relay (id name &optional parent)
  "Insert relay message ID from NAME, optionally replying to PARENT."
  (goto-char (point-max))
  (let* ((start (point))
         (erc-message-parsed
          (make-erc-response
           :command "PRIVMSG" :sender "nichi_bot!u@h"
           :contents (concat (string 3) "11[" name "]" (string 15) " hello")
           :unparsed (concat "@msgid=" id
                             (and parent (concat ";+reply=" parent))
                             " :nichi_bot PRIVMSG #c :hello"))))
    (zr-erc-display-test--message name)
    (save-restriction
      (narrow-to-region start (point-max))
      (zr-erc-reply--insert)
      (run-hooks 'erc-insert-post-hook)
      (zr-erc-reply--remember))
    (setq erc-insert-marker (copy-marker (point-max)))
    start))

(ert-deftest zr-erc-display-reply-history-chain-and-navigation ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules zr-erc-display-test--rules))
    (with-temp-buffer
      (erc-mode)
      ;; Receive history before enabling display names.
      (zr-erc-display-test--relay "a" "Sydney Dian")
      (let* ((child (zr-erc-display-test--relay "b" "Other Name" "a"))
             (quoted (+ child (length "[↪ ")))
             (original (buffer-substring-no-properties (point-min) (point-max)))
             (summary (get-text-property child 'zr-erc-reply-summary)))
        (erc-zr-display-mode 1)
        (should (equal (get-char-property quoted 'display) "Sydney Dian"))
        (goto-char child)
        (search-forward "<")
        (should (equal (get-char-property (point) 'display) "Other Name"))
        (should (equal (get-text-property child 'zr-erc-reply-summary) summary))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) original))
        (button-activate (button-at child))
        (should (= (point) (point-min)))
        ;; The next quote uses b's name, never the name in b's quoted prefix.
        (let* ((grandchild (zr-erc-display-test--relay "c" "Third Name" "b"))
               (third-quote (+ grandchild (length "[↪ "))))
          (should (equal (get-char-property third-quote 'display) "Other Name"))
          (goto-char grandchild)
          (search-forward "<")
          (should (equal (get-char-property (point) 'display) "Third Name")))
        (erc-zr-display-mode -1)
        (should-not (get-char-property quoted 'display))
        (erc-zr-display-mode 1)
        (should (equal (get-char-property quoted 'display) "Sydney Dian"))
        ;; Retained reference context survives removal of the original message.
        (delete-region (point-min) child)
        (zr-erc-display-refresh)
        (should (equal (get-char-property (+ (point-min) (length "[↪ ")) 'display)
                       "Sydney Dian"))
        (should-error (button-activate (button-at (point-min))) :type 'user-error)))))

(ert-deftest zr-erc-display-local-reply-and-tag-rules ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules '((:source (:tag "+display-name") :replace-sender "\\&"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (let ((erc-message-parsed
             (make-erc-response :sender "nichi_bot!u@h" :command "PRIVMSG"
                                :contents "[body name] hello"
                                :unparsed "@msgid=a;+display-name=Tag\\sName :nichi_bot PRIVMSG #c :hello")))
        (zr-erc-display-test--message "body name")
        (zr-erc-reply--remember))
      (goto-char (point-max))
      (let ((start (point))
            (zr-erc-reply--outgoing '("#c" . "a")))
        (insert "<me> reply\n")
        (save-restriction
          (narrow-to-region start (point-max))
          (zr-erc-reply--outgoing-insert)
          (run-hooks 'erc-send-post-hook))
        (setq erc-insert-marker (copy-marker (point-max)))
        (let ((quoted (+ start (length "[↪ "))))
          (should (equal (get-char-property quoted 'display) "Tag Name"))
          (should (equal (buffer-substring-no-properties quoted (+ quoted 9)) "nichi_bot"))
          (setq-local zr-erc-display-rules
                      '((:source body :regexp "\\[\\([^]]+\\)\\]" :replace-sender "\\1")))
          (zr-erc-display-refresh)
          (should (equal (get-char-property quoted 'display) "body name"))
          (erc-zr-display-mode -1)
          (should-not (get-char-property quoted 'display))
          (should-not (memq #'zr-erc-display--render-replies erc-send-post-hook)))))))

(ert-deftest zr-erc-display-configured-tags-and-nil-rules ()
  (should-not zr-erc-display-rules)
  (let ((erc-modules nil)
        (zr-erc-display-rules '((:source (:tag "+display-name") :replace-sender "\\&"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (dolist (case '(("+display-name=Primary;+draft/display-name=Draft" . "Primary")
                      ("+draft/display-name=Draft" . "Draft")
                      ("+display-name=;+draft/display-name=Draft" . nil)
                      ("unrelated=value" . nil)))
        (erase-buffer)
        (let* ((erc-message-parsed
                (make-erc-response :sender "nichi_bot!u@h" :command "PRIVMSG"
                                   :contents "hello"
                                   :unparsed (concat "@" (car case)
                                                     " :nichi_bot PRIVMSG #c :hello")))
               (speaker (zr-erc-display-test--message "Body name")))
          (run-hooks 'erc-insert-post-hook)
          (should (equal (get-char-property speaker 'display) (cdr case)))
          (let ((zr-erc-display-rules nil))
            (run-hooks 'erc-insert-post-hook)
            (should-not (get-char-property speaker 'display))))))))

(ert-deftest zr-erc-display-remap-before-rules ()
  (let* ((zr-erc-display-rules '((:source (:tag "+display-name") :replace-sender "\\&")))
         (parsed (make-erc-response
                  :sender "bot!u@h" :command "PRIVMSG" :contents "hello"
                  :unparsed "@+draft/display-name=Sydney\\sDian :bot PRIVMSG #c :hello"))
         (raw (erc-response.unparsed parsed))
         (context (zr-erc-context parsed)))
    (should (equal (plist-get (zr-erc-display--match context) :sender) "Sydney Dian"))
    (should (zr-erc-match-p '(:tags (("+display-name" . "^Sydney Dian$"))) context))
    (should-not (assoc "+draft/display-name" (plist-get context :tags)))
    (should (equal (erc-response.unparsed parsed) raw))
    (let ((zr-erc-message-tag-receive-remap nil))
      (should-not (plist-get (zr-erc-display--match (zr-erc-context parsed)) :sender)))))

(ert-deftest zr-erc-display-load-does-not-enable ()
  (let ((erc-modules nil)
        (file (symbol-file 'zr-erc-display--match 'defun)))
    (with-temp-buffer
      (erc-mode)
      (should-not erc-zr-display-mode)
      (load file nil t)
      (should-not erc-zr-display-mode)
      (should-not (memq #'zr-erc-display--insert erc-insert-post-hook))
      (with-temp-buffer
        (erc-mode)
        (should-not erc-zr-display-mode)))))

(ert-deftest zr-erc-display-hide-body-prefix-and-restore ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source body :regexp "\\(\\[\\([^]]+\\)\\]\\)" :replace-sender "\\2"
            :replace-text "")))
        (zr-erc-completion-rules
         '((:source text :regexp "\\[\\([^]]+\\)\\]" :groups (1)))))
    (with-temp-buffer
      (erc-mode)
      (zr-erc-display-test--relay "a" "nami.yti")
      (goto-char (point-min))
      (search-forward "[")
      (let ((prefix (1- (point)))
            (raw (buffer-substring-no-properties (point-min) (point-max)))
            (summary (get-text-property (point-min) 'zr-erc-reply-summary)))
        (erc-zr-display-mode 1)
        (should (equal (get-char-property 2 'display) "nami.yti"))
        (should (equal (get-char-property prefix 'display) ""))
        (search-forward "]")
        (should-not (get-char-property (point) 'display))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) raw))
        (should (equal (get-text-property (point-min) 'zr-erc-reply-summary) summary))
        (should (equal (zr-erc-completion--candidates) '("nami.yti")))
        (zr-erc-display-refresh)
        (should (= (length (overlays-at prefix)) 1))
        (erc-zr-display-mode -1)
        (should-not (get-char-property prefix 'display))
        (should-not (get-char-property 2 'display))
        (erc-zr-display-mode 1)
        (should (equal (get-char-property prefix 'display) ""))))))

(ert-deftest zr-erc-display-hide-reference-and-current-body ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source body :regexp "\\[\\([^]]+\\)\\]" :replace-text "" :replace-sender "\\1"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (zr-erc-display-test--relay "a" "nami.yti")
      (let ((child (zr-erc-display-test--relay "b" "Other Name" "a")))
        (goto-char child)
        (search-forward "[nami.yti]")
        (let ((quoted (- (point) (length "[nami.yti]"))))
          (should (equal (get-char-property quoted 'display) ""))
          (search-forward "[Other Name]")
          (let ((own (- (point) (length "[Other Name]"))))
            (should (equal (get-char-property own 'display) ""))
            (should (equal (get-char-property (+ child (length "[↪ ")) 'display)
                           "nami.yti"))
            (button-activate (button-at quoted))
            (should (= (point) (point-min)))
            (erc-zr-display-mode -1)
            (should-not (get-char-property quoted 'display))
            (should-not (get-char-property own 'display))))))))

(ert-deftest zr-erc-display-hide-is-optional-and-bounded ()
  (let ((erc-modules nil)
        (zr-erc-display-rules
         '((:source text :regexp "\\[\\([^]]+\\)\\]" :replace-text "" :replace-sender "\\1"))))
    (with-temp-buffer
      (erc-mode)
      (let ((speaker (zr-erc-display-test--message "First")))
        (goto-char (1- (point-max)))
        (insert " [Second]")
        (goto-char (point-max))
        (insert "[Next line]\n")
        (setq erc-insert-marker (copy-marker (point-max)))
        (erc-zr-display-mode 1)
        (goto-char speaker)
        (search-forward "[First]")
        (should (equal (get-char-property (- (point) 7) 'display) ""))
        (search-forward "[Second]")
        (should-not (get-char-property (- (point) 8) 'display))
        (search-forward "[Next line]")
        (should-not (get-char-property (- (point) 11) 'display))
        ;; No successful extraction means no body hiding.
        (setq-local zr-erc-display-rules
                    '((:source (:tag "+missing") :replace-text "" :replace-sender "\\&")))
        (zr-erc-display-refresh)
        (should-not (overlays-in (point-min) (point-max)))
        ;; Without :replace-text only the nickname is replaced.
        (setq-local zr-erc-display-rules
                    '((:source text :regexp "\\[\\([^]]+\\)\\]" :replace-sender "\\1")))
        (zr-erc-display-refresh)
        (should (= (length (overlays-in (point-min) (point-max))) 1))))))

(ert-deftest zr-erc-display-hide-without-renaming ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source body :regexp "\\[[^]]+\\]" :replace-text ""))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (zr-erc-display-test--relay "a" "Hidden")
      (should-not (get-char-property 2 'display))
      (let ((child (zr-erc-display-test--relay "b" "Other" "a")))
        (should-not (get-char-property (+ child (length "[↪ ")) 'display))
        (goto-char child)
        (search-forward "[Hidden]")
        (let ((quoted (- (point) 8)))
          (should (equal (get-char-property quoted 'display) ""))
          (search-forward "<nichi_bot>")
          (should-not (get-char-property (- (point) 10) 'display))
          (search-forward "[Other]")
          (should (equal (get-char-property (- (point) 7) 'display) ""))
          (button-activate (button-at quoted))
          (should (= (point) (point-min)))
          (erc-zr-display-mode -1)
          (should-not (overlays-in (point-min) (point-max))))))))

(ert-deftest zr-erc-display-independent-name-and-hide-actions ()
  (let ((zr-erc-display-rules
         '((:source body :regexp "\\(\\[[^]]+\\]\\)" :replace-sender nil :replace-text "")
           (:source sender :replace-sender "\\&"))))
    (should (equal (zr-erc-display--match '(:body "[Hidden]" :sender "bot"))
                   '(:sender nil :text "" :source body :value "[Hidden]" :begin 0 :end 8))))
  (let ((zr-erc-display-rules
         '((:source body :regexp "\\(\\[[^]]+\\]\\) \\(.*\\)"
            :replace-sender "\\2" :replace-text ""))))
    ;; A whitespace-only name does not prevent text replacement.
    (should (equal (zr-erc-display--match '(:body "[Hidden]   "))
                   '(:sender nil :text "" :source body :value "[Hidden]   " :begin 0 :end 11))))
  (let ((zr-erc-display-rules
         '((:source body :regexp "\\[[^]]+\\]")
           (:source sender :replace-sender "\\&"))))
    ;; Matching without either action does not shadow later effective rules.
    (should (equal (zr-erc-display--match '(:body "[Hidden]" :sender "bot"))
                   '(:sender "bot" :text nil :source sender :value "bot" :begin 0 :end 3)))))

(ert-deftest zr-erc-display-replace-body-and-reply-references ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source body :regexp "\\[[^]]+\\]"
            :replace-text "<relay>"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (zr-erc-display-test--relay "a" "Original")
      (goto-char (point-min))
      (search-forward "[Original]")
      (should (equal (get-char-property (- (point) 10) 'display) "<relay>"))
      (should-not (get-char-property 2 'display))
      (let ((child (zr-erc-display-test--relay "b" "Child" "a")))
        (goto-char child)
        (search-forward "[Original]")
        (should (equal (get-char-property (- (point) 10) 'display) "<relay>"))
        (search-forward "[Child]")
        (should (equal (get-char-property (- (point) 7) 'display) "<relay>"))
        (should (equal (buffer-substring-no-properties (- (point) 7) (point))
                       "[Child]")))
      (goto-char (point-max))
      (let ((start (point))
            (zr-erc-reply--outgoing '("#c" . "a")))
        (insert "<me> reply\n")
        (save-restriction
          (narrow-to-region start (point-max))
          (zr-erc-reply--outgoing-insert)
          (run-hooks 'erc-send-post-hook))
        (setq erc-insert-marker (copy-marker (point-max)))
        (goto-char start)
        (search-forward "[Original]")
        (let ((quoted (- (point) 10)))
          (should (equal (get-char-property quoted 'display) "<relay>"))
          ;; Escape a backslash to produce a literal backreference.
          (setq-local zr-erc-display-rules
                      '((:source body :regexp "\\[[^]]+\\]"
                         :replace-text "\\\\1")))
          (zr-erc-display-refresh)
          (should (equal (get-char-property quoted 'display) "\\1"))
          (button-activate (button-at quoted))
          (should (= (point) (point-min)))
          (erc-zr-display-mode -1)
          (should-not (overlays-in (point-min) (point-max))))))))

(ert-deftest zr-erc-display-replacement-templates ()
  (let ((zr-erc-display-rules
         '((:source body :regexp "\\[\\([^]]+\\)\\] *\\(.*\\)"
            :replace-sender "user: \\1" :replace-text "\\2"))))
    (should (equal (zr-erc-display--match '(:body "[nami.yti] 强大v5"))
                   '(:sender "user: nami.yti" :text "强大v5" :source body :value "[nami.yti] 强大v5" :begin 0 :end 15))))
  (let ((zr-erc-display-rules
         '((:source body :regexp "\\(NAME\\)\\(?:-\\(ID\\)\\)?"
            :replace-sender "\\1/\\2" :replace-text "literal [\\&]"))))
    (should (equal (zr-erc-display--match '(:body "NAME"))
                   '(:sender "NAME/" :text "literal [NAME]" :source body :value "NAME" :begin 0 :end 4))))
  (let ((zr-erc-display-rules
         '((:source sender :replace-sender ""))))
    (should (equal (zr-erc-display--match '(:sender "bot")) '(:sender "" :text nil :source sender :value "bot" :begin 0 :end 3))))
  (let ((zr-erc-display-rules
         '((:source body :regexp "" :replace-text "insert"))))
    (should-not (zr-erc-display--match '(:body "hello")))))

(ert-deftest zr-erc-display-replacement-functions-and-match-data ()
  (let* ((context '(:sender "bot" :body "[Name] body" :tags (("+x" . "tag"))))
         (zr-erc-display-rules
          (list (list
                 :source 'body :regexp "\\[\\([^]]+\\)\\] \\(.*\\)"
                 :replace-sender
                 (lambda (data)
                   (should (eq (plist-get data :source) 'body))
                   (should (equal (plist-get data :value) "[Name] body"))
                   (should (equal (plist-get data :groups) ["[Name] body" "Name" "body"]))
                   ;; Modifying this callback's copy cannot affect the other action.
                   (setf (alist-get "+x" (plist-get data :tags) nil nil #'equal) "changed")
                   (string-match "different" "different")
                   (concat (plist-get data :sender) "/" (aref (plist-get data :groups) 1)))
                 :replace-text
                 (lambda (data)
                   (should (equal (cdr (assoc "+x" (plist-get data :tags))) "tag"))
                   ;; Returned strings are literal, including backslashes.
                   (concat "\\1/" (aref (plist-get data :groups) 2)))))))
    (string-match "\\(outer\\)" "outer")
    (let ((before (match-data)))
      (should (equal (zr-erc-display--match context)
                     '(:sender "bot/Name" :text "\\1/body" :source body :value "[Name] body" :begin 0 :end 11)))
      (should (equal (match-data) before)))
    (should (equal context '(:sender "bot" :body "[Name] body" :tags (("+x" . "tag"))))))
  (let ((zr-erc-display-rules
         (list (list :source 'body :regexp "\\[\\([^]]+\\)\\]"
                     :replace-sender (lambda (_data) (string-match "x" "x") nil)
                     :replace-text "<\\1>"))))
    (should (equal (zr-erc-display--match '(:body "[Name]"))
                   '(:sender nil :text "<Name>" :source body :value "[Name]" :begin 0 :end 6))))
  (let ((zr-erc-display-rules
         (list (list :source 'sender :replace-sender #'ignore :replace-text #'ignore)
               '(:source sender :replace-sender "fallback"))))
    (should (equal (zr-erc-display--match '(:sender "bot")) '(:sender "fallback" :text nil :source sender :value "bot" :begin 0 :end 3)))))

(ert-deftest zr-erc-display-full-match-replacement-and-truncated-reference ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source body :regexp "\\[\\([^]]+\\)\\] \\(.*\\)"
            :replace-sender "\\1" :replace-text "\\2"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      ;; Use a long original body: its full match is absent from the short quote.
      (let* ((body (concat "[Name] " (make-string 100 ?x)))
             (erc-message-parsed
              (make-erc-response :sender "nichi_bot!u@h" :command "PRIVMSG"
                                 :contents body
                                 :unparsed "@msgid=a :nichi_bot PRIVMSG #c :hello")))
        (insert "<" (propertize "nichi_bot" 'erc--speaker "nichi_bot") "> " body "\n")
        (run-hooks 'erc-insert-post-hook)
        (zr-erc-reply--remember)
        (should (equal (get-char-property 13 'display) (make-string 100 ?x))))
      (let ((child (zr-erc-display-test--relay "b" "Other" "a")))
        (should (equal (get-char-property (+ child (length "[↪ ")) 'display) "Name"))
        (goto-char child)
        (search-forward "[Name]")
        (should-not (get-char-property (- (point) 6) 'display))
        (button-activate (button-at child))
        (should (= (point) (point-min)))))))

(defun zr-erc-display-test--formatted (body rendered &optional id)
  "Insert BODY as RENDERED, retaining optional reply ID, and return its start."
  (goto-char (point-max))
  (let ((start (point))
        (erc-message-parsed
         (make-erc-response
          :sender "bot!u@h" :command "PRIVMSG" :contents body
          :unparsed (concat (and id (concat "@msgid=" id " "))
                            ":bot PRIVMSG #c :" body))))
    (insert "<" (propertize "bot" 'erc--speaker "bot") "> " rendered "\n")
    (save-restriction
      (narrow-to-region start (point-max))
      (run-hooks 'erc-insert-post-hook)
      (when id (zr-erc-reply--remember)))
    (setq erc-insert-marker (copy-marker (point-max)))
    start))

(ert-deftest zr-erc-display-offsets-disambiguate-repeated-text-and-replies ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source body :regexp "\\[Same\\]\\'" :replace-text "LAST"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (zr-erc-display-test--formatted "[Same] then [Same]" "[Same] then [Same]" "a")
      (goto-char (point-min))
      (search-forward "[Same]")
      (should-not (get-char-property (- (point) 6) 'display))
      (search-forward "[Same]")
      (should (equal (get-char-property (- (point) 6) 'display) "LAST"))
      (let ((child (zr-erc-display-test--relay "b" "Reply" "a")))
        (goto-char child)
        (search-forward "[Same]")
        (should-not (get-char-property (- (point) 6) 'display))
        (search-forward "[Same]")
        (let ((last (- (point) 6)))
          (should (equal (get-char-property last 'display) "LAST"))
          (erc-zr-display-mode -1)
          (erc-zr-display-mode 1)
          (should (equal (get-char-property last 'display) "LAST")))))))

(ert-deftest zr-erc-display-control-mapping-and-unrelated-fragments ()
  (let ((erc-modules nil)
        (zr-erc-display-rules
         '((:source body :regexp "\\[Name\\]" :replace-text ""))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (let ((body (concat (string 3) "11[Name]" (string 15) " literal 11")))
        (zr-erc-display-test--formatted body (erc-controls-strip body))
        (goto-char (point-min))
        (search-forward "[Name]")
        (should (equal (get-char-property (- (point) 6) 'display) ""))
        ;; A match inside color syntax must not move to the literal digits later.
        (setq-local zr-erc-display-rules
                    '((:source body :regexp "11" :replace-text "wrong")))
        (zr-erc-display-refresh)
        (should-not (overlays-in (point-min) (point-max))))
      (setq-local zr-erc-display-rules
                  '((:source body :regexp "\\[Same\\]" :replace-text "wrong")))
      (let ((start (zr-erc-display-test--formatted
                    "original [Same] tail" "different [Same] tail")))
        (should-not (overlays-in start (point-max)))))))

(ert-deftest zr-erc-display-formatted-text-spans-wrapped-message ()
  (let ((erc-modules nil)
        (zr-erc-display-rules
         '((:source text :regexp "first\n +second" :replace-text "joined"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (zr-erc-display-test--formatted "first second" "first\n    second")
      (goto-char (point-min))
      (search-forward "first")
      (let ((pos (- (point) 5)))
        (should (equal (get-char-property pos 'display) "joined"))
        (erc-zr-display-mode -1)
        (erc-zr-display-mode 1)
        (should (equal (get-char-property pos 'display) "joined")))
      ;; Raw offsets are mapped through verified whitespace changes.
      (setq-local zr-erc-display-rules
                  '((:source body :regexp "second" :replace-text "SECOND")))
      (zr-erc-display-refresh)
      (goto-char (point-min))
      (search-forward "second")
      (should (equal (get-char-property (- (point) 6) 'display) "SECOND")))))

(ert-deftest zr-erc-display-reference-text-offsets ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         '((:source text :regexp "\\[Same\\]\n\\'" :replace-text "unused"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-mode 1)
      (zr-erc-display-test--formatted "[Same] then [Same]" "[Same] then [Same]" "a")
      (let ((child (zr-erc-display-test--relay "b" "Reply" "a")))
        ;; A source-text match including ERC's final newline is outside the body.
        (should-not (overlays-in child (point-max)))
        (setq-local zr-erc-display-rules
                    '((:source text :regexp "\\[Same\\]$" :replace-text "LAST")))
        (zr-erc-display-refresh)
        (goto-char child)
        (search-forward "[Same]")
        (should-not (get-char-property (- (point) 6) 'display))
        (search-forward "[Same]")
        (should (equal (get-char-property (- (point) 6) 'display) "LAST"))))))

(ert-deftest zr-erc-display-filled-relay-body-and-reference ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-rules
         `((:source body :regexp ,(rx "[" (group (+ (not "]"))) "] ")
            :replace-sender "\\1" :replace-text ""))))
    (dolist (controls '(nil t))
      (with-temp-buffer
        (erc-mode)
        (erc-zr-display-mode 1)
        (let* ((body (concat (and controls (string 3))
                             (and controls "11")
                             "[nami.yti] first second third fourth fifth sixth seventh"))
               (rendered (with-temp-buffer
                           (erc-mode)
                           (insert "<bot> " (erc-controls-strip body) "\n")
                           (let ((erc-fill-column 30)) (erc-fill-static))
                           (buffer-substring-no-properties 7 (1- (point-max))))))
          (should (string-match-p "\n" rendered))
          (zr-erc-display-test--formatted body rendered "filled")
          (goto-char (point-min))
          (search-forward "[nami.yti]")
          (let ((pos (- (point) 10)))
            (should (equal (get-char-property pos 'display) ""))
            (erc-zr-display-mode -1)
            (should-not (get-char-property pos 'display))
            (erc-zr-display-mode 1)
            (should (equal (get-char-property pos 'display) "")))
          (let ((child (zr-erc-display-test--relay "child" "Reply" "filled")))
            (goto-char child)
            (search-forward "[nami.yti]")
            (should (equal (get-char-property (- (point) 10) 'display) ""))))))))

(ert-deftest zr-erc-display-filled-mapping-rejects-changed-content ()
  (should-not (zr-erc-display--locate-filled "[Name] first second" 0 7
                                            "<bot> [Name] first\n SECOND\n" 5))
  (should-not (zr-erc-display--locate-filled "[Name]  first second" 0 7
                                            "<bot> [Name]\n first second\n" 5))
  (should (equal (zr-erc-display--locate-filled "[Same] then [Same]" 12 18
                                              "<bot> [Same]\n  then [Same]\n" 5)
                 '(20 . 26))))

(ert-deftest zr-erc-display-body-with-intermittent-right-timestamps ()
  (let ((erc-modules nil)
        (erc-timestamp-only-if-changed-flag t)
        (erc-timestamp-right-column 10)
        (zr-erc-display-rules
         `((:source body :regexp ,(rx "[" (group (+ (not "]"))) "] ")
            :replace-sender "\\1" :replace-text ""))))
    (dolist (erc-timestamp-use-align-to '(t nil 0))
      (with-temp-buffer
        (erc-mode)
        (erc-zr-display-mode 1)
        (let ((stamp "[00:00]"))
          (add-hook 'erc-insert-post-hook
                    (lambda () (erc-insert-timestamp-right (copy-sequence stamp))) 70 t)
          (dolist (entry '(("[00:00]" "我觉得cloudnative-pg最厉害🥹" t)
                           ("[00:00]" "虽然之前看到过有人弄出来了脑裂的bug" nil)
                           ("[00:01]" "下一分钟" t)))
            (setq stamp (car entry))
            (let* ((body (concat (string 3) "09[終🍥] " (cadr entry)))
                   (start (zr-erc-display-test--formatted body (erc-controls-strip body))))
              (goto-char start)
              (search-forward "[終🍥] ")
              (let ((pos (- (point) 5))
                    (original (buffer-substring-no-properties start (point-max))))
                (should (equal (get-char-property (1+ start) 'display) "終🍥"))
                (should (equal (get-char-property pos 'display) ""))
                (erc-zr-display-mode -1)
                (should-not (get-char-property pos 'display))
                (erc-zr-display-mode 1)
                (should (equal (get-char-property pos 'display) ""))
                (should (equal (buffer-substring-no-properties start (point-max)) original))
                (let ((field (text-property-any start (point-max) 'field 'erc-timestamp)))
                  (should (eq (and field t) (nth 2 entry)))
                  (when field
                    (should-not (cl-some (lambda (ov) (overlay-get ov 'zr-erc-display))
                                         (overlays-at field)))))))))))))

(provide 'zr-erc-display-test)
;;; zr-erc-display-test.el ends here
