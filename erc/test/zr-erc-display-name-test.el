;;; zr-erc-display-name-test.el --- Display name tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-display-name)
(require 'zr-erc-completion)

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

(provide 'zr-erc-display-name-test)
;;; zr-erc-display-name-test.el ends here
