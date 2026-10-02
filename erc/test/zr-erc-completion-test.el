;;; zr-erc-completion-test.el --- Relay completion tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-completion)

(defvar zr-erc-completion-test--rules
  '((:source sender :regexp "\\`\\(.+\\)-\\([0-9]+\\)/onebot\\'" :groups (1 2))
    (:source text :regexp "^<\\(.+\\)-\\([0-9]+\\)/onebot> " :groups (1 2))
    (:source text :regexp "^<\\([^>]+\\)> " :groups (1))))

(ert-deftest zr-erc-completion-relay-sender-and-custom-groups ()
  (should-not zr-erc-completion-rules)
  (should-not (zr-erc-completion--extract '(:sender "白雪-17225180/onebot")))
  (let ((zr-erc-completion-rules zr-erc-completion-test--rules))
    (should (equal (zr-erc-completion--extract '(:sender "白雪-17225180/onebot"))
                   '("白雪" "17225180"))))
  (let ((zr-erc-completion-rules
         '((:source body :regexp "^\\[\\([^|]+\\)|\\([^]]+\\)\\]" :groups (2)))))
    (should (equal (zr-erc-completion--extract '(:body "[白雪|17225180] hello"))
                   '("17225180")))))

(ert-deftest zr-erc-completion-tags-and-selectors ()
  (let ((zr-erc-completion-rules
         '((:match (:tags (("+bridge" . "^onebot$")))
            :source (:tag "+name") :regexp "^\\([^/]+\\)/" :groups (1)))))
    (should (equal (zr-erc-completion--extract
                    '(:tags (("+bridge" . "onebot") ("+name" . "白雪/onebot"))))
                   '("白雪")))
    (should-not (zr-erc-completion--extract '(:tags (("+name" . "白雪/onebot")))))))

(ert-deftest zr-erc-completion-history-tab-and-isolation ()
  (let ((erc-modules nil))
    (with-temp-buffer
      (erc-mode)
      (insert "<白雪-17225180/onebot> 倒是你，凌晨一点修仙到现在才消停，这味儿怕是比我大多\n"
              "                 了喵 🐾\n"
              "<白雪-17225180/onebot> 今晚我给自己画的第三张：提着小灯，看人家放烟花。右下\n"
              "                 角那个位置，给你留着，喵\n")
      (setq erc-insert-marker (copy-marker (point)))
      (insert "ERC> ")
      (setq erc-input-marker (copy-marker (point)))
      (insert "@17")
      (let ((erc-complete-functions '(zr-erc-completion-at-point)))
        (erc-tab 1)
        (should (equal (buffer-substring-no-properties erc-input-marker (point-max))
                       "@17"))
        (let ((zr-erc-completion-rules zr-erc-completion-test--rules))
          (erc-tab 1)
          (should (equal (buffer-substring-no-properties erc-input-marker (point-max))
                         "@17225180"))))
      (delete-region erc-input-marker (point-max))
      (insert "hi @白")
      (let ((erc-complete-functions '(zr-erc-completion-at-point))
            (zr-erc-completion-rules zr-erc-completion-test--rules))
        (erc-tab 1)
        (should (equal (buffer-substring-no-properties erc-input-marker (point-max))
                       "hi @白雪")))
      (delete-region erc-input-marker (point-max))
      (insert "normal")
      (let ((zr-erc-completion-rules zr-erc-completion-test--rules))
        (should-not (zr-erc-completion-at-point))
        (should (equal (zr-erc-completion--candidates) '("白雪" "17225180")))
        (let ((inhibit-read-only t)) (delete-region (point-min) erc-insert-marker))
        (should-not (zr-erc-completion--candidates))))))

(ert-deftest zr-erc-completion-metadata-survives-formatting ()
  (let ((erc-modules nil)
        (zr-erc-completion-rules zr-erc-completion-test--rules))
    (with-temp-buffer
      (erc-mode)
      (let ((erc-message-parsed
             (make-erc-response :sender "白雪-17225180/onebot!u@h" :command "PRIVMSG"
                                :contents "hello" :unparsed ":relay PRIVMSG #c :hello")))
        (insert "[↪ someone: quoted message] <白雪-17225180/onebot> hello\n")
        (zr-erc-completion--remember))
      (setq erc-insert-marker (copy-marker (point-max)))
      (should (equal (zr-erc-completion--candidates) '("白雪" "17225180"))))))

(provide 'zr-erc-completion-test)
;;; zr-erc-completion-test.el ends here
