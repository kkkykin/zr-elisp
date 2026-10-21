;;; zr-erc-completion-test.el --- Relay completion tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-completion)

(defvar zr-erc-completion-test--rules
  '((:source sender :regexp "\\`\\(.+\\)-\\([0-9]+\\)/onebot\\'" :groups (1 2) :break t)
    (:source text :regexp "^<\\(.+\\)-\\([0-9]+\\)/onebot> " :groups (1 2) :break t)
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

(ert-deftest zr-erc-completion-accumulates-rules-in-order ()
  (let ((zr-erc-completion-rules
         '((:source (:tag "+display-name"))
           (:source sender :regexp "\\`\\(.+\\)-\\([0-9]+\\)/onebot\\'"
            :groups (1 2 1) :break nil)
           (:source body :regexp "@\\([^ ]+\\)" :groups (1))
           (:source (:tag "+display-name")))))
    (string-match "\\(outer\\)" "outer")
    (let ((before (match-data)))
      (should (equal (zr-erc-completion--extract
                      '(:sender "白雪-17225180/onebot" :body "hello @Friend"
                        :tags (("+display-name" . "雪"))))
                     '("雪" "白雪" "17225180" "Friend")))
      (should (equal (match-data) before)))))

(ert-deftest zr-erc-completion-break-keeps-earlier-candidates ()
  (let ((zr-erc-completion-rules
         '((:source (:tag "+display-name"))
           (:source sender :regexp "\\`.+-\\([0-9]+\\)/onebot\\'"
            :groups (1) :break t)
           (:source body))))
    (should (equal (zr-erc-completion--extract
                    '(:sender "白雪-17225180/onebot" :body "fallback"
                      :tags (("+display-name" . "雪"))))
                   '("雪" "17225180")))))

(ert-deftest zr-erc-completion-break-requires-valid-candidates ()
  (dolist (case '(((:source body :regexp "missing" :break t) (:body "hello"))
                  ((:source (:tag "+missing") :break t) nil)
                  ((:match (:sender "^other$") :source body :break t) (:body "name"))
                  ((:source body :break t) (:body ""))
                  ((:source body :break t) (:body "   "))
                  ((:source body :break t) (:body "bad\nname"))
                  ((:source body :regexp "\\(name\\)?id" :groups (1) :break t)
                   (:body "id"))))
    (let ((zr-erc-completion-rules (list (car case) '(:source sender))))
      (should (equal (zr-erc-completion--extract
                      (append (cadr case) '(:sender "fallback")))
                     '("fallback"))))))

(ert-deftest zr-erc-completion-break-on-duplicate-candidates ()
  (let ((zr-erc-completion-rules
         '((:source sender)
           (:source (:tag "+display-name") :break t)
           (:source body))))
    (should (equal (zr-erc-completion--extract
                    '(:sender "白雪" :body "fallback"
                      :tags (("+display-name" . "白雪"))))
                   '("白雪")))))

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
        (zr-erc-completion-rules
         (cons '(:source (:tag "+display-name")) zr-erc-completion-test--rules)))
    (with-temp-buffer
      (erc-mode)
      (let ((erc-message-parsed
             (make-erc-response :sender "白雪-17225180/onebot!u@h" :command "PRIVMSG"
                                :contents "hello"
                                :unparsed "@+display-name=Sydney :relay PRIVMSG #c :hello")))
        (insert "[↪ someone: quoted message] <白雪-17225180/onebot> hello\n")
        (zr-erc-completion--remember))
      (setq erc-insert-marker (copy-marker (point-max)))
      (should (equal (zr-erc-completion--candidates) '("Sydney" "白雪" "17225180")))
      (insert "ERC> ")
      (setq erc-input-marker (copy-marker (point)))
      (insert "@Sy")
      (let ((erc-complete-functions '(zr-erc-completion-at-point)))
        (erc-tab 1)
        (should (equal (buffer-substring-no-properties erc-input-marker (point-max))
                       "@Sydney"))))))

(provide 'zr-erc-completion-test)
;;; zr-erc-completion-test.el ends here
