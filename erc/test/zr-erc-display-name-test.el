;;; zr-erc-display-name-test.el --- Display name tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-display-name)
(require 'zr-erc-completion)
(require 'zr-erc-reply)

(defconst zr-erc-display-name-test--rules
  '((:match (:sender "^nichi_bot$")
     :source text :regexp "\\[\\([^]]+\\)\\]")))

(defun zr-erc-display-name-test--message (name)
  "Insert a relay message containing NAME and return its speaker position."
  (insert "<")
  (prog1 (point)
    (insert (propertize "nichi_bot" 'erc--speaker "nichi_bot"
                        'font-lock-face 'erc-nick-default-face)
            "> " (string 3) "11[" name "]" (string 15) " hello\n")))

(ert-deftest zr-erc-display-name-extraction ()
  (let ((zr-erc-display-name-rules
         '((:match (:sender "^bot$") :source body
            :regexp "\\[\\([^]|]+\\)|\\([^]]+\\)\\]" :group 2)
           (:source (:tag "+display-name")))))
    (should (equal (zr-erc-display-name--extract
                    (list :sender "bot" :body (concat (string 3) "11[Name|123]"))) "123"))
    (should (equal (zr-erc-display-name--extract
                    '(:sender "other" :body "[Name|123]"
                      :tags (("+display-name" . "Sydney Dian")))) "Sydney Dian"))
    (dolist (name (list "" "  " "bad\nname" (concat (string 3) "11Name")))
      (should-not (zr-erc-display-name--extract
                   (list :tags (list (cons "+display-name" name))))))))

(ert-deftest zr-erc-display-name-toggle-history-and-completion ()
  (let ((erc-modules nil)
        (zr-erc-display-name-rules zr-erc-display-name-test--rules)
        (zr-erc-completion-rules
         '((:source text :regexp "^<\\([^>]+\\)>" :groups (1)))))
    (with-temp-buffer
      (erc-mode)
      (let* ((speaker (zr-erc-display-name-test--message "Sydney Dian"))
             (original (buffer-string)))
        (setq erc-insert-marker (copy-marker (point)))
        (insert "ERC> @ni")
        (setq erc-input-marker (copy-marker (- (point) 3)))
        (let ((candidates (zr-erc-completion--candidates)))
          (should (equal candidates '("nichi_bot")))
          (erc-zr-display-name-mode 1)
          (should (equal (get-char-property speaker 'display) "Sydney Dian"))
          (should (equal (buffer-substring (point-min) erc-insert-marker) original))
          (should (equal (zr-erc-completion--candidates) candidates))
          (let ((erc-complete-functions '(zr-erc-completion-at-point)))
            (erc-tab 1)
            (should (equal (buffer-substring-no-properties erc-input-marker (point-max))
                           "@nichi_bot")))
          (zr-erc-display-name-refresh)
          (should (= (length (overlays-at speaker)) 1))
          (with-temp-buffer
            (erc-mode)
            (should-not erc-zr-display-name-mode)
            (should-not (memq #'zr-erc-display-name--insert erc-insert-post-hook)))
          (should erc-zr-display-name-mode)
          (save-restriction
            (narrow-to-region erc-input-marker (point-max))
            (erc-zr-display-name-mode -1))
          (should-not (get-char-property speaker 'display))
          (should (equal (zr-erc-completion--candidates) candidates))
          (erc-zr-display-name-mode 1)
          (should (equal (get-char-property speaker 'display) "Sydney Dian")))))))

(ert-deftest zr-erc-display-name-incoming-metadata ()
  (let ((erc-modules nil)
        (zr-erc-display-name-rules
         '((:match (:sender "^nichi_bot$") :source body
            :regexp "\\[\\([^]]+\\)\\]"))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-name-mode 1)
      (let* ((body (concat (string 3) "11[Sydney Dian]" (string 15) " hello"))
             (erc-message-parsed
              (make-erc-response :sender "nichi_bot!u@h" :command "PRIVMSG"
                                 :contents body :unparsed ":nichi_bot PRIVMSG #c :hello"))
             (speaker (zr-erc-display-name-test--message "Rendered differently"))
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
        (erc-zr-display-name-mode -1)
        (erc-zr-display-name-mode 1)
        (should (equal (get-char-property speaker 'display) "Sydney Dian"))))))

(defun zr-erc-display-name-test--relay (id name &optional parent)
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
    (zr-erc-display-name-test--message name)
    (save-restriction
      (narrow-to-region start (point-max))
      (zr-erc-reply--insert)
      (run-hooks 'erc-insert-post-hook)
      (zr-erc-reply--remember))
    (setq erc-insert-marker (copy-marker (point-max)))
    start))

(ert-deftest zr-erc-display-name-reply-history-chain-and-navigation ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-name-rules zr-erc-display-name-test--rules))
    (with-temp-buffer
      (erc-mode)
      ;; Receive history before enabling display names.
      (zr-erc-display-name-test--relay "a" "Sydney Dian")
      (let* ((child (zr-erc-display-name-test--relay "b" "Other Name" "a"))
             (quoted (+ child (length "[↪ ")))
             (original (buffer-substring-no-properties (point-min) (point-max)))
             (summary (get-text-property child 'zr-erc-reply-summary)))
        (erc-zr-display-name-mode 1)
        (should (equal (get-char-property quoted 'display) "Sydney Dian"))
        (goto-char child)
        (search-forward "<")
        (should (equal (get-char-property (point) 'display) "Other Name"))
        (should (equal (get-text-property child 'zr-erc-reply-summary) summary))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) original))
        (button-activate (button-at child))
        (should (= (point) (point-min)))
        ;; The next quote uses b's name, never the name in b's quoted prefix.
        (let* ((grandchild (zr-erc-display-name-test--relay "c" "Third Name" "b"))
               (third-quote (+ grandchild (length "[↪ "))))
          (should (equal (get-char-property third-quote 'display) "Other Name"))
          (goto-char grandchild)
          (search-forward "<")
          (should (equal (get-char-property (point) 'display) "Third Name")))
        (erc-zr-display-name-mode -1)
        (should-not (get-char-property quoted 'display))
        (erc-zr-display-name-mode 1)
        (should (equal (get-char-property quoted 'display) "Sydney Dian"))
        ;; Retained reference context survives removal of the original message.
        (delete-region (point-min) child)
        (zr-erc-display-name-refresh)
        (should (equal (get-char-property (+ (point-min) (length "[↪ ")) 'display)
                       "Sydney Dian"))
        (should-error (button-activate (button-at (point-min))) :type 'user-error)))))

(ert-deftest zr-erc-display-name-local-reply-and-tag-rules ()
  (let ((erc-modules nil)
        (erc-zr-reply-mode t)
        (zr-erc-display-name-rules '((:source (:tag "+display-name")))))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-name-mode 1)
      (let ((erc-message-parsed
             (make-erc-response :sender "nichi_bot!u@h" :command "PRIVMSG"
                                :contents "[body name] hello"
                                :unparsed "@msgid=a;+display-name=Tag\\sName :nichi_bot PRIVMSG #c :hello")))
        (zr-erc-display-name-test--message "body name")
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
          (setq-local zr-erc-display-name-rules
                      '((:source body :regexp "\\[\\([^]]+\\)\\]")))
          (zr-erc-display-name-refresh)
          (should (equal (get-char-property quoted 'display) "body name"))
          (erc-zr-display-name-mode -1)
          (should-not (get-char-property quoted 'display))
          (should-not (memq #'zr-erc-display-name--render-replies erc-send-post-hook)))))))

(ert-deftest zr-erc-display-name-default-tags-and-nil-rules ()
  (let ((erc-modules nil))
    (with-temp-buffer
      (erc-mode)
      (erc-zr-display-name-mode 1)
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
               (speaker (zr-erc-display-name-test--message "Body name")))
          (run-hooks 'erc-insert-post-hook)
          (should (equal (get-char-property speaker 'display) (cdr case)))
          (let ((zr-erc-display-name-rules nil))
            (run-hooks 'erc-insert-post-hook)
            (should-not (get-char-property speaker 'display))))))))

(ert-deftest zr-erc-display-name-remap-before-rules ()
  (let* ((parsed (make-erc-response
                  :sender "bot!u@h" :command "PRIVMSG" :contents "hello"
                  :unparsed "@+draft/display-name=Sydney\\sDian :bot PRIVMSG #c :hello"))
         (raw (erc-response.unparsed parsed))
         (context (zr-erc-context parsed)))
    (should (equal (zr-erc-display-name--extract context) "Sydney Dian"))
    (should (zr-erc-match-p '(:tags (("+display-name" . "^Sydney Dian$"))) context))
    (should-not (assoc "+draft/display-name" (plist-get context :tags)))
    (should (equal (erc-response.unparsed parsed) raw))
    (let ((zr-erc-message-tag-receive-remap nil))
      (should-not (zr-erc-display-name--extract (zr-erc-context parsed))))))

(ert-deftest zr-erc-display-name-load-does-not-enable ()
  (let ((erc-modules nil)
        (file (symbol-file 'zr-erc-display-name--extract 'defun)))
    (with-temp-buffer
      (erc-mode)
      (should-not erc-zr-display-name-mode)
      (load file nil t)
      (should-not erc-zr-display-name-mode)
      (should-not (memq #'zr-erc-display-name--insert erc-insert-post-hook))
      (with-temp-buffer
        (erc-mode)
        (should-not erc-zr-display-name-mode)))))

(provide 'zr-erc-display-name-test)
;;; zr-erc-display-name-test.el ends here
