;;; zr-dictionary-test.el --- Tests for staged DICT searches -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'zr-dictionary-test-helpers)

(defvar dictionary-current-server)

(ert-deftest zr-dictionary-test-first-match-miss-does-not-try-other-candidates ()
  (zr-dictionary-test-with-server
   (setq dictionary-response-function
         (lambda (command)
           (if (string-prefix-p "match " command)
               "152 2 matches\r\nedict \"reserve\"\r\nedict \"reservation\"\r\n.\r\n250 ok\r\n"
             "552 no match\r\n")))
   (let ((before (buffer-string)))
     (should-not (zr-dictionary-lookup "reserved"))
     (should (equal before (buffer-string))))
   (should (equal (reverse (cl-remove-if
                           (lambda (command) (string-prefix-p "client " command)) dictionary-commands))
                  '("define * \"reserved\"" "match * . \"reserved\"" "define edict \"reserve\"")))))

(ert-deftest zr-dictionary-test-first-match-unescapes-quoted-words ()
  (zr-dictionary-test-with-server
   (setq dictionary-response-function
         (lambda (command)
           (cond
            ((equal command "define * \"missing\"") "552 no match\r\n")
            ((equal command "match * . \"missing\"")
             "152 1 match\r\nedict \"a\\\"b\\\\c\"\r\n.\r\n250 ok\r\n")
            ((equal command "define edict \"a\\\"b\\\\c\"")
             "150 1 definition\r\n151 \"word\" edict \"English\"\r\nquoted candidate\r\n.\r\n250 ok\r\n")
            (t "500 unexpected command\r\n"))))
   (should (equal (zr-dictionary-lookup "missing") '(("[edict]" "quoted candidate"))))
   (should (member "define edict \"a\\\"b\\\\c\"" dictionary-commands))))

(ert-deftest zr-dictionary-test-matching-errors-clean-connection ()
  (zr-dictionary-test-with-server
   (let ((zr-dictionary-timeout 0.1)
         (before (buffer-list)))
     (dolist (response '(nil "152 1 match\r\nedict \"reserve\"\r\n.\r\n500 error\r\n"))
       (setq dictionary-response-function
             (lambda (command)
               (if (string-prefix-p "match " command) response "552 no match\r\n")))
       (should-error (zr-dictionary-lookup "reserved"))
       (accept-process-output nil 0.02)
       (should-not (cl-set-difference (buffer-list) before))
       (should-not (cl-some #'process-live-p dictionary-clients))))))

(ert-deftest zr-dictionary-test-missing-word-and-quoted-word ()
  (zr-dictionary-test-with-server
   (setq dictionary-response-function (lambda (_command) "552 no match\r\n"))
   (should-not (zr-dictionary-lookup "a\"b\\c"))
   (should (member "define * \"a\\\"b\\\\c\"" dictionary-commands))
   (should (member "match * . \"a\\\"b\\\\c\"" dictionary-commands))
   (accept-process-output nil 0.02)
   (should-not (cl-some #'process-live-p dictionary-clients))
   (let ((before (length dictionary-commands)))
     (should-error (zr-dictionary-lookup "word\r\nQUIT"))
     (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary "bad database"))))
       (should-error (zr-dictionary-lookup "word")))
     (should (= before (length dictionary-commands))))))

(ert-deftest zr-dictionary-test-group-collects-all-hits-before-stopping ()
  (dolist (hits '(((dict1 . "Alpha") (dict2 . "Beta"))
                  ((dict1 . "Alpha"))
                  ((dict2 . "Beta"))))
    (zr-dictionary-test-with-server
     (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 "dict2")) (:server t :port t :dictionary dict3) similar))
           (dictionary-default-dictionary "interactive"))
       (setq dictionary-response-function
             (lambda (command)
               (if-let* ((database (cond ((equal command "define dict1 \"hamlet\"") 'dict1)
                                        ((equal command "define dict2 \"hamlet\"") 'dict2)))
                         (text (alist-get database hits)))
                   (zr-dictionary-test-definition database text)
                 "552 no match\r\n")))
       (should (equal (zr-dictionary-lookup "hamlet")
                      (mapcar (lambda (entry) (list (format "[%s]" (car entry)) (cdr entry))) hits)))
       (should (equal (zr-dictionary-test-queries dictionary-commands)
                      '("define dict1 \"hamlet\"" "define dict2 \"hamlet\"")))
       (should (equal dictionary-default-dictionary "interactive"))))))

(ert-deftest zr-dictionary-test-group-merges-custom-headings-across-queries ()
  (zr-dictionary-test-with-server
   (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 dict2))))
         (zr-dictionary-name-function (lambda (_name _id _source) "Combined")))
     (setq dictionary-response-function
           (lambda (command)
             (if (equal command "define dict1 \"hamlet\"")
                 (concat "150 2 definitions\r\n"
                         "151 \"hamlet\" dict1 \"First\"\r\nAlpha\r\n.\r\n"
                         "151 \"hamlet\" dict1 \"First\"\r\nMore alpha\r\n.\r\n250 ok\r\n")
               (zr-dictionary-test-definition "dict2" "Beta"))))
     (should (equal (zr-dictionary-lookup "hamlet")
                    '(("Combined" "Alpha" "More alpha" "Beta")))))))

(ert-deftest zr-dictionary-test-empty-group-falls-back-before-similar ()
  (zr-dictionary-test-with-server
   (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 dict2)) (:server t :port t :dictionary dict3) similar)))
     (setq dictionary-response-function
           (lambda (command)
             (if (equal command "define dict3 \"reserved\"")
                 (zr-dictionary-test-definition "dict3" "Gamma")
               "552 no match\r\n")))
     (should (equal (zr-dictionary-lookup "reserved") '(("[dict3]" "Gamma"))))
     (should (equal (zr-dictionary-test-queries dictionary-commands)
                    '("define dict1 \"reserved\"" "define dict2 \"reserved\"" "define dict3 \"reserved\""))))))

(ert-deftest zr-dictionary-test-similar-retries-groups-in-order ()
  (dolist (hits '(((dict1 . "Alpha") (dict2 . "Beta"))
                  ((dict2 . "Beta"))
                  ((dict3 . "Gamma"))
                  nil))
    (zr-dictionary-test-with-server
     (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 dict2)) (:server t :port t :dictionary "dict3") similar)))
       (setq dictionary-response-function
             (lambda (command)
               (cond
                ((string-match "\\`match \\(dict[123]\\) \\. \"reserved\"\\'" command)
                 (let ((database (match-string 1 command)))
                   (format "152 2 matches\r\n%s \"reserve\"\r\n%s \"reservation\"\r\n.\r\n250 ok\r\n"
                           database database)))
                ((string-match "\\`define \\(dict[123]\\) \"reserve\"\\'" command)
                 (let ((database (intern (match-string 1 command))))
                   (if-let* ((text (alist-get database hits)))
                       (zr-dictionary-test-definition database text)
                     "552 no match\r\n")))
                (t "552 no match\r\n"))))
       (should (equal (zr-dictionary-lookup "reserved")
                      (mapcar (lambda (entry) (list (format "[%s]" (car entry)) (cdr entry))) hits)))
       (should (equal (zr-dictionary-test-queries dictionary-commands)
                      (append '("define dict1 \"reserved\"" "define dict2 \"reserved\"" "define dict3 \"reserved\""
                                "match dict1 . \"reserved\"" "define dict1 \"reserve\""
                                "match dict2 . \"reserved\"" "define dict2 \"reserve\"")
                              (unless (or (assq 'dict1 hits) (assq 'dict2 hits))
                                '("match dict3 . \"reserved\"" "define dict3 \"reserve\"")))))))))

(ert-deftest zr-dictionary-test-similar-is-optional-and-nil-disables-lookup ()
  (zr-dictionary-test-with-server
   (setq dictionary-response-function (lambda (_command) "552 no match\r\n"))
   (let ((zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 dict2)) (:server t :port t :dictionary dict3))))
     (should-not (zr-dictionary-lookup "reserved")))
   (should (equal (zr-dictionary-test-queries dictionary-commands)
                  '("define dict1 \"reserved\"" "define dict2 \"reserved\"" "define dict3 \"reserved\"")))
   (let ((before (length dictionary-clients)))
     (let ((zr-dictionary-dictionaries nil))
       (should-not (zr-dictionary-lookup "reserved")))
     (should-not (zr-dictionary-lookup " \t"))
     (should (= before (length dictionary-clients))))))

(ert-deftest zr-dictionary-test-invalid-stages-fail-before-connect ()
  (zr-dictionary-test-with-server
   (dolist (zr-dictionary-dictionaries '(dict1 "dict1" (dict1 . dict2) (nil)
                                      ((dict1 . dict2)) ((dict1 (dict2)))
                                      (similar) (dict1 similar dict2) (dict1 similar similar)
                                      ((dict1 similar)) (dict1 123) ("") ("bad database")
                                      ("dict1\r\nQUIT") ("dict\\1") ("dict\"1")))
     (should-error (zr-dictionary-lookup "reserved")))
   (should-not dictionary-commands)
   (should-not dictionary-clients)))

(ert-deftest zr-dictionary-test-keeps-interactive-connection-and-window ()
  (dolist (dictionary-use-single-buffer '(nil t))
    (zr-dictionary-test-with-server
     (let ((dictionary-connection nil)
           (dictionary-current-server nil)
           (dictionary-display-definition-function nil)
           (before (buffer-list)))
       (save-window-excursion
         (unwind-protect
             (progn
               (dictionary-search "interactive" "*")
               (let* ((interactive-buffer (current-buffer))
                      (interactive-connection dictionary-connection)
                      (text (buffer-string))
                      (position (point))
                      (history (copy-tree dictionary-data-stack))
                      (connection-buffer (dictionary-connection-buffer dictionary-connection))
                      (connection-text (with-current-buffer connection-buffer (buffer-string)))
                      (read-point (dictionary-connection-read-point dictionary-connection))
                      (window (selected-window))
                      (before-capture (buffer-list)))
                 (should (derived-mode-p 'dictionary-mode))
                 (with-temp-buffer
                   (insert "Keep deck text")
                   (should (equal (zr-dictionary-lookup "猫")
                                  '(("[edict]" "cat from DICT") ("[local]" "猫の定義 from DICT"))))
                   (should (equal (buffer-string) "Keep deck text")))
                 (should (eq (current-buffer) interactive-buffer))
                 (should (equal (buffer-string) text))
                 (should (= (point) position))
                 (should buffer-read-only)
                 (should (equal dictionary-data-stack history))
                 (should (equal dictionary-default-dictionary "*"))
                 (should (eq dictionary-connection interactive-connection))
                 (should (eq (dictionary-connection-status interactive-connection) 'up))
                 (should (equal dictionary-current-server dictionary-server))
                 (should (equal (with-current-buffer connection-buffer (buffer-string)) connection-text))
                 (should (= (dictionary-connection-read-point dictionary-connection) read-point))
                 (should (eq (selected-window) window))
                 (should (eq (window-buffer window) interactive-buffer))
                 (should-not (cl-set-difference (buffer-list) before-capture))
                 ;; A subsequent interactive lookup must still use its original connection.
                 (dictionary-search "after capture" "*")
                 (should (eq dictionary-connection interactive-connection))
                 (should (string-match-p "after capture" (buffer-string)))))
           (dolist (buffer (cl-set-difference (buffer-list) before))
             (when (buffer-live-p buffer) (kill-buffer buffer)))
           (dictionary-connection-close dictionary-connection)))
       (should-not (cl-set-difference (buffer-list) before))))))

(ert-deftest zr-dictionary-test-capture-during-interactive-lookup-keeps-replies-separate ()
  (dolist (dictionary-use-single-buffer '(nil t))
    (zr-dictionary-test-with-server
     (let ((dictionary-connection nil)
           (dictionary-current-server nil)
           (dictionary-display-definition-function nil)
           (zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 dict2)) (:server t :port t :dictionary dict3) similar))
           (capture-result nil)
           (before (buffer-list)))
       (setq dictionary-response-function
             (lambda (command)
               (cond
                ((equal command "define * \"pending\"")
                 ;; An HTTP capture may run while dictionary.el is waiting for its reply.
                 (let* ((connection dictionary-connection)
                        (window (selected-window))
                        (visible-buffer (window-buffer window))
                        (text (with-current-buffer visible-buffer (buffer-string))))
                   (with-temp-buffer
                     (setq capture-result (zr-dictionary-lookup "reserved")))
                   (should (eq dictionary-connection connection))
                   (should (eq (dictionary-connection-status connection) 'up))
                   (should (eq (selected-window) window))
                   (should (eq (window-buffer window) visible-buffer))
                   (should (equal (with-current-buffer visible-buffer (buffer-string)) text)))
                 (zr-dictionary-test-definition "interactive" "Interactive definition"))
                ((equal command "match dict1 . \"reserved\"")
                 "152 1 match\r\ndict1 \"reserve\"\r\n.\r\n250 ok\r\n")
                ((equal command "define dict1 \"reserve\"")
                 (zr-dictionary-test-definition "dict1" "Capture definition"))
                (t "552 no match\r\n"))))
       (save-window-excursion
         (unwind-protect
             (progn
               (dictionary-search "pending" "*")
               (should (equal capture-result '(("[dict1]" "Capture definition"))))
               (should (string-match-p "Interactive definition" (buffer-string)))
               (should-not (string-match-p "Capture definition" (buffer-string)))
               (should (equal (zr-dictionary-test-queries dictionary-commands)
                              '("define * \"pending\""
                                "define dict1 \"reserved\"" "define dict2 \"reserved\"" "define dict3 \"reserved\""
                                "match dict1 . \"reserved\"" "define dict1 \"reserve\"" "match dict2 . \"reserved\""))))
           (dolist (buffer (cl-set-difference (buffer-list) before))
             (when (buffer-live-p buffer) (kill-buffer buffer)))
           (dictionary-connection-close dictionary-connection)))
       (should-not (cl-set-difference (buffer-list) before))))))

(ert-deftest zr-dictionary-test-connect-failure-cleans-buffer ()
  (let* ((server (make-network-process :name "zr-org-srs-x-test-closed-dict"
                                       :server t :host "127.0.0.1" :service t :noquery t))
         (dictionary-server "127.0.0.1")
         (dictionary-port (process-contact server :service))
         (dictionary-use-http-proxy nil)
         (zr-dictionary-dictionaries '((:server t :port t :dictionary t)))
         (before-buffers (buffer-list))
         (before-processes (process-list)))
    (delete-process server)
    (should-error (zr-dictionary-lookup "official"))
    (should-not (cl-set-difference (buffer-list) before-buffers))
    (should-not (cl-set-difference (process-list) before-processes))))

(ert-deftest zr-dictionary-test-greeting-timeout-cleans-connection ()
  (zr-dictionary-test-with-server
   (setq dictionary-greeting nil)
   (let ((zr-dictionary-timeout 0.1)
         (before (buffer-list)))
     (should-error (zr-dictionary-lookup "official"))
     (accept-process-output nil 0.02)
     (should-not (cl-set-difference (buffer-list) before))
     (should-not (cl-some #'process-live-p dictionary-clients)))))

(ert-deftest zr-dictionary-test-uses-http-proxy-settings ()
  (zr-dictionary-test-with-server
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
     (should (equal (zr-dictionary-lookup "猫")
                    '(("[edict]" "cat from DICT") ("[local]" "猫の定義 from DICT"))))
     (should (member "CONNECT dict.example:2628 HTTP/1.1" dictionary-commands))
     (should (member "define * \"猫\"" dictionary-commands)))))

(ert-deftest zr-dictionary-test-explicit-stages-and-strategy ()
  (zr-dictionary-test-with-server
   (setq dictionary-response-function
         (lambda (command)
           (cond
            ((equal command "match dict1 prefix \"reserved\"")
             "152 1 match\r\ndict1 \"reserve\"\r\n.\r\n250 ok\r\n")
            ((equal command "define dict1 \"reserve\"")
             (zr-dictionary-test-definition "dict1" "Definition"))
            (t "552 no match\r\n"))))
   (should (equal (zr-dictionary-lookup "reserved" '((:server t :port t :dictionary (dict1 similar))) "prefix")
                  '(("[dict1]" "Definition"))))
   (should (equal (zr-dictionary-test-queries dictionary-commands)
                  '("define dict1 \"reserved\"" "match dict1 prefix \"reserved\""
                    "define dict1 \"reserve\"")))
   (should (equal zr-dictionary-dictionaries '((:server t :port t :dictionary t))))
   (should (equal zr-dictionary-strategy "."))
   (let ((before (length dictionary-commands)))
     (should-not (zr-dictionary-lookup "reserved" nil))
     (should-error (zr-dictionary-lookup "reserved" '((:server t :port t :dictionary (dict1 similar))) "bad strategy"))
     (should-error (zr-dictionary-lookup "reserved" '((:server t :port t :dictionary (dict1 similar))) "prefix\r\nQUIT"))
     (should (= before (length dictionary-commands))))))

(ert-deftest zr-dictionary-test-search-and-reference-use-buffer-configuration ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (with-temp-buffer
           (setq-local zr-dictionary-dictionaries '((:server t :port t :dictionary (dict1 similar)))
                       zr-dictionary-strategy "prefix")
           (setq dictionary-response-function
                 (lambda (_command)
                   (zr-dictionary-test-definition "dict1" "See {猫} and {a\r\n phrase}.")))
           (zr-dictionary-test-search "word")
           (should (eq major-mode 'dictionary-mode))
           (should buffer-read-only)
           (should (equal zr-dictionary-word "word"))
           (should (equal zr-dictionary-dictionaries (zr-dictionary-resolve-dictionaries '((:server t :port t :dictionary (dict1 similar))))))
           (should (equal zr-dictionary-strategy "prefix"))
           (goto-char (point-min))
           (search-forward "猫")
           (let ((button (button-at (1- (point)))))
             (should button)
             (button-activate button))
           (zr-dictionary-test-wait)
           (should (equal zr-dictionary-word "猫"))
           (goto-char (point-min))
           (search-forward "phrase")
           (button-activate (button-at (1- (point))))
           (zr-dictionary-test-wait)
           (should (equal zr-dictionary-word "a phrase"))
           (dictionary-previous)
           (should (equal zr-dictionary-word "猫"))
           (should (equal zr-dictionary-dictionaries (zr-dictionary-resolve-dictionaries '((:server t :port t :dictionary (dict1 similar))))))
           (dictionary-previous)
           (should (equal zr-dictionary-word "word"))
           (should-error (dictionary-previous))
           (should (equal (zr-dictionary-test-queries dictionary-commands)
                          '("define dict1 \"word\"" "define dict1 \"猫\"" "define dict1 \"a phrase\""))))
       (when-let* ((buffer (get-buffer "*zr-dictionary*")))
         (kill-buffer buffer))))))

(ert-deftest zr-dictionary-test-search-controls-and-history ()
  (zr-dictionary-test-with-server
   (let ((dictionary-create-buttons t)
         (native-map (copy-keymap dictionary-mode-map)))
     (save-window-excursion
       (unwind-protect
           (progn
             (setq dictionary-response-function
                   (lambda (_command) (zr-dictionary-test-definition "dict1" "See {猫}.")))
             (zr-dictionary-test-search "word" '((:server t :port t :dictionary (dict1 dict2 similar))) "prefix")
             (should (equal (key-binding "s") #'zr-dictionary-search))
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "next")))
               (call-interactively (key-binding "s")))
             (zr-dictionary-test-wait)
             (should (equal zr-dictionary-word "next"))
             (goto-char (point-min))
             (search-forward "猫")
             (call-interactively (key-binding "d"))
             (zr-dictionary-test-wait)
             (should (equal zr-dictionary-word "猫"))
             (cl-letf (((symbol-function 'read-minibuffer)
                        (lambda (&rest _) '((:server t :port t :dictionary (dict3 similar))))))
               (goto-char (point-min))
               (search-forward "[Select dictionary]")
               (button-activate (button-at (1- (point)))))
             (zr-dictionary-test-wait)
             (should (equal zr-dictionary-dictionaries (zr-dictionary-resolve-dictionaries '((:server t :port t :dictionary (dict3 similar))))))
             (should (member "define dict3 \"猫\"" dictionary-commands))
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "suffix")))
               (call-interactively (key-binding "M")))
             (zr-dictionary-test-wait)
             (should (equal zr-dictionary-strategy "suffix"))
             (let ((history (copy-tree dictionary-data-stack)))
               (setq dictionary-response-function
                     (lambda (_command) (zr-dictionary-test-definition "dict3" "Fresh é 猫 %s.")))
               (revert-buffer t t)
               (zr-dictionary-test-wait)
               (should (equal history dictionary-data-stack))
               (should (string-match-p "Fresh é 猫 %s" (buffer-string)))
               (should buffer-read-only)
               (should-not (buffer-modified-p)))
             (dictionary-previous)
             (should (equal zr-dictionary-strategy "prefix"))
             (should (equal zr-dictionary-dictionaries (zr-dictionary-resolve-dictionaries '((:server t :port t :dictionary (dict3 similar))))))
             (dictionary-previous)
             (should (equal zr-dictionary-dictionaries (zr-dictionary-resolve-dictionaries '((:server t :port t :dictionary (dict1 dict2 similar))))))
             (should (string-match-p "See {猫}" (buffer-string)))
             (should (equal native-map dictionary-mode-map)))
         (when-let* ((buffer (get-buffer "*zr-dictionary*")))
           (kill-buffer buffer)))))))

(ert-deftest zr-dictionary-test-dictionary-navigation-keys ()
  (zr-dictionary-test-with-server
   (let ((native-map (copy-keymap dictionary-mode-map)))
     (save-window-excursion
       (unwind-protect
           (progn
             (zr-dictionary-test-search "word")
             (let ((text (buffer-string)) (commands dictionary-commands)
                   (history dictionary-data-stack))
               (goto-char (point-min))
               (call-interactively (key-binding "j"))
               (should (equal (car (get-text-property (point) 'zr-dictionary-entry)) "[edict]"))
               (should (bolp))
               (let ((first (point)))
                 (should-error (call-interactively (key-binding "k")) :type 'user-error)
                 (should (= (point) first))
                 (call-interactively (key-binding "j"))
                 (should (equal (car (get-text-property (point) 'zr-dictionary-entry)) "[local]"))
                 (search-forward "from DICT")
                 (call-interactively (key-binding "k"))
                 (should (= (point) first))
                 (call-interactively (key-binding "j"))
                 (let ((last (point)))
                   (should-error (call-interactively (key-binding "j")) :type 'user-error)
                   (should (= (point) last))))
               (should (equal text (buffer-string)))
               (should (equal commands dictionary-commands))
               (should (equal history dictionary-data-stack)))
             (should (equal native-map dictionary-mode-map)))
         (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer)))))))

(ert-deftest zr-dictionary-test-group-navigation-fallback-empty-and-history ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (progn
           (setq dictionary-response-function
                 (lambda (command)
                   (let ((database (cadr (split-string command))))
                     (if (member database '("dict2" "dict4"))
                         (zr-dictionary-test-definition database (concat database " result"))
                       "552 no match\r\n"))))
           (zr-dictionary-test-search
            "word" '((:dictionary dict1) (:dictionary dict2) (:dictionary dict3) (:dictionary dict4)) "prefix")
           (should (= (zr-dictionary--view-group-index zr-dictionary--view) 1))
           (let ((configuration zr-dictionary-dictionaries))
             (setq dictionary-commands nil)
             (call-interactively (key-binding "f"))
             (zr-dictionary-test-wait)
             (should (string-match-p "No definitions found" (buffer-string)))
             (should (= (zr-dictionary--view-group-index zr-dictionary--view) 2))
             (should (equal (zr-dictionary-test-queries dictionary-commands) '("define dict3 \"word\"")))
             (call-interactively (key-binding "f"))
             (zr-dictionary-test-wait)
             (should (string-match-p "dict4 result" (buffer-string)))
             (let ((text (buffer-string)) (commands dictionary-commands))
               (should-error (call-interactively (key-binding "f")) :type 'user-error)
               (should (equal text (buffer-string)))
               (should (equal commands dictionary-commands)))
             (dictionary-previous)
             (should (= (zr-dictionary--view-group-index zr-dictionary--view) 2))
             (setq dictionary-commands nil)
             (revert-buffer t t)
             (zr-dictionary-test-wait)
             (should (equal (zr-dictionary-test-queries dictionary-commands) '("define dict3 \"word\"")))
             (call-interactively (key-binding "b"))
             (zr-dictionary-test-wait)
             (should (string-match-p "dict2 result" (buffer-string)))
             (call-interactively (key-binding "b"))
             (zr-dictionary-test-wait)
             (should (string-match-p "No definitions found" (buffer-string)))
             (should (= (zr-dictionary--view-group-index zr-dictionary--view) 0))
             (should-error (call-interactively (key-binding "b")) :type 'user-error)
             (should (equal zr-dictionary-word "word"))
             (should (equal zr-dictionary-strategy "prefix"))
             (should (equal zr-dictionary-dictionaries configuration))))
       (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))))))

(ert-deftest zr-dictionary-test-group-navigation-similar-and-pending ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (progn
           (setq dictionary-response-function
                 (lambda (command)
                   (cond
                    ((string-prefix-p "match dict2 " command)
                     "152 1 match\r\ndict2 \"candidate\"\r\n.\r\n250 ok\r\n")
                    ((equal command "define dict2 \"candidate\"")
                     (zr-dictionary-test-definition "dict2" "Similar result"))
                    (t "552 no match\r\n"))))
           (zr-dictionary-test-search "word" '((:dictionary dict1) (:dictionary dict2) (:dictionary dict3) similar) "prefix")
           (should (string-match-p "Similar result" (buffer-string)))
           (should (= (zr-dictionary--view-group-index zr-dictionary--view) 1))
           (setq dictionary-commands nil)
           (call-interactively (key-binding "f"))
           (zr-dictionary-test-wait)
           (should (equal (zr-dictionary-test-queries dictionary-commands)
                          '("define dict3 \"word\"" "match dict3 prefix \"word\"")))
           (setq dictionary-response-function (lambda (_command) nil))
           (call-interactively (key-binding "b"))
           (let ((query zr-dictionary--request))
             (should query)
             (call-interactively (key-binding "b"))
             (should (zr-dictionary--query-done query))
             (should (= (zr-dictionary--query-group-index zr-dictionary--request) 0))
             (should-error (call-interactively (key-binding "b")) :type 'user-error)
             (should zr-dictionary--request)))
       (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))))))

(ert-deftest zr-dictionary-test-matching-controls-and-candidates ()
  (zr-dictionary-test-with-server
   (let ((dictionary-create-buttons t))
     (save-window-excursion
       (unwind-protect
           (progn
             (setq dictionary-response-function
                   (lambda (command)
                     (cond
                      ((equal command "match dict1 prefix \"word\"")
                       "152 2 matches\r\ndict1 \"猫\"\r\ndict1 \"a\\\"b\\\\c\"\r\n.\r\n250 ok\r\n")
                      ((equal command "match dict2 prefix \"word\"")
                       "152 1 match\r\ndict2 \"cat\"\r\n.\r\n250 ok\r\n")
                      ((string-prefix-p "match " command) "552 no match\r\n")
                      (t (zr-dictionary-test-definition "dict1" "Definition")))))
             (zr-dictionary-test-search "word" '((:server t :port t :dictionary (dict1 dict2)) (:server t :port t :dictionary dict3) similar) "prefix")
             (setq dictionary-commands nil)
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "word")))
               (goto-char (point-min))
               (search-forward "[Matching words]")
               (button-activate (button-at (1- (point)))))
             (zr-dictionary-test-wait)
             (should (equal (zr-dictionary-test-queries dictionary-commands)
                            '("match dict1 prefix \"word\"" "match dict2 prefix \"word\"")))
             (should (string-match-p "猫" (buffer-string)))
             (should (string-match-p "cat" (buffer-string)))
             (goto-char (point-min))
             (search-forward "a\"b\\c")
             (button-activate (button-at (1- (point))))
             (zr-dictionary-test-wait)
             (should (equal zr-dictionary-word "a\"b\\c"))
             (should (equal (last (zr-dictionary-test-queries dictionary-commands) 2)
                            '("define dict1 \"a\\\"b\\\\c\"" "define dict2 \"a\\\"b\\\\c\"")))
             (dictionary-previous)
             (should zr-dictionary--matching-p)
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "missing")))
               (call-interactively (key-binding "m")))
             (zr-dictionary-test-wait)
             (should (string-match-p "No matching words" (buffer-string)))
             (should (member "match dict3 prefix \"missing\"" dictionary-commands))
             (should buffer-read-only)
             (let ((history (copy-tree dictionary-data-stack)))
               (revert-buffer t t)
               (zr-dictionary-test-wait)
               (should (equal history dictionary-data-stack))))
         (when-let* ((buffer (get-buffer "*zr-dictionary*")))
           (kill-buffer buffer)))))))

(ert-deftest zr-dictionary-test-search-error-keeps-history ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (progn
           (zr-dictionary-test-search "word" '((:server t :port t :dictionary (dict1 similar))) "prefix")
           (let ((text (buffer-string))
                 (history (copy-tree dictionary-data-stack)))
             (setq dictionary-response-function (lambda (_command) "500 error\r\n"))
             (zr-dictionary-test-search "failure")
             (should (string-match-p "Error:" (buffer-string)))
             (dictionary-previous)
             (should (equal zr-dictionary-word "word"))
             (should (equal text (buffer-string)))
             (should (equal history dictionary-data-stack))
             (should buffer-read-only)))
       (when-let* ((buffer (get-buffer "*zr-dictionary*")))
         (kill-buffer buffer))))))

(ert-deftest zr-dictionary-test-search-closing-keeps-native-connection ()
  (dolist (close-native-first '(nil t))
    (zr-dictionary-test-with-server
     (let ((dictionary-connection nil)
           (dictionary-current-server nil)
           (dictionary-display-definition-function nil)
           (before (buffer-list)))
       (save-window-excursion
         (unwind-protect
             (progn
               (dictionary-search "native" "*")
               (let ((native-buffer (current-buffer))
                     (connection dictionary-connection)
                     (text (buffer-string))
                     (history (copy-tree dictionary-data-stack)))
                 (zr-dictionary-test-search "staged" '((:server t :port t :dictionary (dict1 similar))) "prefix")
                 (should (eq dictionary-connection connection))
                 (should (equal (with-current-buffer native-buffer (buffer-string)) text))
                 (should (equal (buffer-local-value 'dictionary-data-stack native-buffer) history))
                 (when close-native-first
                   (kill-buffer native-buffer)
                   (pop-to-buffer "*zr-dictionary*"))
                 (call-interactively (key-binding "q"))
                 (should-not (get-buffer "*zr-dictionary*"))
                 (if close-native-first
                     (should-not (eq (dictionary-connection-status connection) 'up))
                   (should (eq (dictionary-connection-status connection) 'up))
                   (should (eq (current-buffer) native-buffer))
                   (dictionary-search "after close" "*")
                   (should (eq dictionary-connection connection)))))
           (dolist (buffer (cl-set-difference (buffer-list) before))
             (when (buffer-live-p buffer) (kill-buffer buffer)))
           (dictionary-connection-close dictionary-connection)))
       (should-not (cl-set-difference (buffer-list) before))))))

(ert-deftest zr-dictionary-test-targets-expand-dictionaries-in-one-stage ()
  (let ((dictionary-server "default.example") (dictionary-port 1234)
        (dictionary-use-http-proxy nil))
    (should (equal
             (zr-dictionary-resolve-dictionaries
              '((:server t :port 4321 :dictionary local)
                ((:server "other.example" :port t :dictionary (a "b"))
                 (:server t :port t :dictionary c)) similar))
             '(((:server "default.example" :port 4321 :dictionary "local" :proxy nil))
               ((:server "other.example" :port 1234 :dictionary "a" :proxy nil)
                (:server "other.example" :port 1234 :dictionary "b" :proxy nil)
                (:server "default.example" :port 1234 :dictionary "c" :proxy nil)) similar)))
    (dolist (target '((:server "" :dictionary a) (:server "bad\nhost" :dictionary a)
                      (:port 0 :dictionary a) (:port 65536 :dictionary a)
                      (:port 1.5 :dictionary a)
                      (:dictionary nil) (:dictionary (a . b)) (:dictionary (a similar b))
                      (:dictionary (a (b))) (:dictionary a :unknown t)
                      (:dictionary a :dictionary b) (:dictionary)))
      (should-error (zr-dictionary-resolve-dictionaries (list target))))))

(ert-deftest zr-dictionary-test-endpoint-defaults ()
  (let ((dictionary-server "default.example") (dictionary-port 1234)
        (dictionary-use-http-proxy nil))
    (dolist (value '(nil t other 4321))
      (let ((target (caar (zr-dictionary-resolve-dictionaries
                          (list (list :server value :port (if (numberp value) nil value)
                                      :dictionary 'a))))))
        (should (equal (plist-get target :server) "default.example"))
        (should (= (plist-get target :port) 1234))))
    (should (equal (zr-dictionary-resolve-dictionaries '((:server nil :port nil :dictionary a)))
                   (zr-dictionary-resolve-dictionaries '((:server t :port t :dictionary a)))))
    (let ((target (caar (zr-dictionary-resolve-dictionaries
                        '((:server "specified.example" :port 4321 :dictionary a))))))
      (should (equal (plist-get target :server) "specified.example"))
      (should (= (plist-get target :port) 4321)))
    (should (= (plist-get (caar (zr-dictionary-resolve-dictionaries
                                '((:port "4321" :dictionary a)))) :port) 1234)))
  (let ((dictionary-server nil) (dictionary-port 2628))
    (should (equal (plist-get (caar (zr-dictionary-resolve-dictionaries
                                    '((:server nil :dictionary a)))) :server) "localhost"))))

(ert-deftest zr-dictionary-test-resolved-proxies-freeze-defaults ()
  (let* ((dictionary-server "dict.example") (dictionary-port 2628)
         (dictionary-use-http-proxy t) (dictionary-proxy-server "proxy.example")
         (dictionary-proxy-port 8080)
         (resolved (zr-dictionary-resolve-dictionaries
                    '(((:dictionary (a b)) (:dictionary c :proxy t)
                       (:dictionary d :proxy nil)
                       (:dictionary (e similar) :proxy "[::1]:8888")) similar))))
    (should (equal (mapcar (lambda (target) (plist-get target :proxy)) (car resolved))
                   '("proxy.example:8080" "proxy.example:8080" "proxy.example:8080" nil "[::1]:8888")))
    (setq dictionary-server "changed.example" dictionary-port 4321
          dictionary-proxy-server "changed.proxy" dictionary-proxy-port 9090)
    (should (equal (zr-dictionary-resolve-dictionaries resolved) resolved))
    (setq dictionary-use-http-proxy nil)
    (should (equal (zr-dictionary-resolve-dictionaries resolved) resolved))))

(ert-deftest zr-dictionary-test-explicit-proxy-keeps-similar-on-its-connection ()
  (let* ((dictionary-use-http-proxy nil) sources
         (dictionary-proxy-server nil) (dictionary-proxy-port nil)
         (zr-dictionary-name-function
          (lambda (name id source) (push source sources) (zr-dictionary-format-name name id source)))
         (proxy (zr-dictionary-test-server
                 (lambda (_client command)
                   (cond
                    ((equal command "match original . \"reserved\"")
                     "152 1 match\r\nactual \"reserve\"\r\n.\r\n250 ok\r\n")
                    ((equal command "define actual \"reserve\"")
                     (zr-dictionary-test-definition "actual" "Through proxy"))
                    (t "552 no match\r\n"))) t))
         (proxy-address (format "127.0.0.1:%s" (process-contact proxy :service)))
         (stages (list (list :server "dict.example" :port 2628
                             :dictionary '(original similar) :proxy proxy-address))))
    (unwind-protect
        (progn
          (should (equal (zr-dictionary-lookup "reserved" stages) '(("[actual]" "Through proxy"))))
          (should (equal (zr-dictionary-test-queries (process-get proxy 'commands))
                         '("CONNECT dict.example:2628 HTTP/1.1" "" "define original \"reserved\""
                           "match original . \"reserved\"" "define actual \"reserve\"")))
          (should (= (length (process-get proxy 'clients)) 1))
          (should (equal (plist-get (car sources) :proxy) proxy-address))
          (should (equal (plist-get (car sources) :dictionary) "actual")))
      (zr-dictionary-test-stop-server proxy))))

(ert-deftest zr-dictionary-test-same-endpoint-can-use-direct-and-distinct-proxies ()
  (let* ((dictionary-use-http-proxy t)
         (dictionary-proxy-server nil) (dictionary-proxy-port nil)
         (direct (zr-dictionary-test-server
                  (lambda (_client _command) (zr-dictionary-test-definition "same" "Direct"))))
         (first (zr-dictionary-test-server
                 (lambda (_client _command) (zr-dictionary-test-definition "same" "First proxy")) t))
         (second (zr-dictionary-test-server
                  (lambda (_client _command) (zr-dictionary-test-definition "same" "Second proxy")) t))
         (first-address (format "127.0.0.1:%s" (process-contact first :service)))
         (second-address (format "127.0.0.1:%s" (process-contact second :service)))
         (stages (list (list (append (zr-dictionary-test-target direct 'same) '(:proxy nil))
                             (append (zr-dictionary-test-target direct '(same extra))
                                     (list :proxy first-address))
                             (append (zr-dictionary-test-target direct 'same)
                                     (list :proxy second-address))))))
    (unwind-protect
        (progn
          (should (equal (zr-dictionary-lookup "word" stages)
                         '(("[same]" "Direct" "First proxy" "First proxy" "Second proxy"))))
          (dolist (server (list direct first second))
            (should (= (length (process-get server 'clients)) 1)))
          (should-not (cl-some (lambda (command) (string-prefix-p "CONNECT " command))
                              (process-get direct 'commands)))
          (dolist (server (list first second))
            (should (member (format "CONNECT 127.0.0.1:%s HTTP/1.1" (process-contact direct :service))
                            (process-get server 'commands)))))
      (dolist (server (list direct first second)) (zr-dictionary-test-stop-server server)))))

(ert-deftest zr-dictionary-test-async-appends-in-arrival-order ()
  (let* ((dictionary-use-http-proxy nil)
         (zr-dictionary-timeout 2)
         slow-client
         (slow (zr-dictionary-test-server
                (lambda (client _command) (setq slow-client client) nil)))
         (fast (zr-dictionary-test-server
                (lambda (_client _command) (zr-dictionary-test-definition "same" "Fast é 猫."))))
         (stages (list (list (zr-dictionary-test-target slow 'same)
                             (zr-dictionary-test-target fast 'same))))
         (source (current-buffer)))
    (save-window-excursion
      (unwind-protect
          (let ((buffer (zr-dictionary-search "word" stages)))
            (should (eq (window-buffer (selected-window)) buffer))
            (should zr-dictionary--request)
            (should-not (string-match-p "Fast" (buffer-string)))
            ;; Callbacks must not take focus back after the user changes buffers.
            (switch-to-buffer source)
            (zr-dictionary-test-until
             (lambda () (string-match-p "Fast é 猫" (with-current-buffer buffer (buffer-string)))))
            (should (eq (current-buffer) source))
            (should (eq (window-buffer (selected-window)) source))
            (with-current-buffer buffer
              (should zr-dictionary--request)
              (should-not (string-match-p "Slow" (buffer-string)))
              (should (string-match-p (format "same@127.0.0.1:%s" (process-contact fast :service))
                                      (buffer-string)))
              (goto-char (point-min))
              (search-forward "Fast")
              (let ((text (buffer-string)) (position (point)))
                (process-send-string slow-client
                                     (encode-coding-string (zr-dictionary-test-definition "same" "Slow result.")
                                                           'utf-8))
                (zr-dictionary-test-wait)
                (should (= position (point)))
                (should (string-prefix-p text (buffer-string)))
                (should (< (string-match "Fast" (buffer-string)) (string-match "Slow" (buffer-string))))
                (should buffer-read-only)
                (should-not (buffer-modified-p)))))
        (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))
        (zr-dictionary-test-stop-server slow)
        (zr-dictionary-test-stop-server fast)))))

(ert-deftest zr-dictionary-test-fallback-waits-for-entire-cross-server-stage ()
  (let* ((dictionary-use-http-proxy nil)
         gate
         (slow (zr-dictionary-test-server (lambda (client _command) (setq gate client) nil)))
         (fast (zr-dictionary-test-server
                (lambda (_client command)
                  (if (equal command "define fallback \"word\"")
                      (zr-dictionary-test-definition "fallback" "Fallback result") "552 no match\r\n"))))
         (stages (list (list (zr-dictionary-test-target slow 'miss)
                             (zr-dictionary-test-target fast 'miss))
                        (zr-dictionary-test-target fast 'fallback))))
    (save-window-excursion
      (unwind-protect
          (progn
            (zr-dictionary-search "word" stages)
            (zr-dictionary-test-until
             (lambda () (and gate (member "define miss \"word\"" (process-get fast 'commands)))))
            (should-not (member "define fallback \"word\"" (process-get fast 'commands)))
            (process-send-string gate "552 no match\r\n")
            (zr-dictionary-test-wait)
            (should (string-match-p "Fallback result" (buffer-string)))
            (should (= (length (process-get fast 'clients)) 1)))
        (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))
        (zr-dictionary-test-stop-server slow)
        (zr-dictionary-test-stop-server fast)))))

(ert-deftest zr-dictionary-test-multi-server-similar-stays-on-origin-server ()
  (let* ((dictionary-use-http-proxy nil)
         (first (zr-dictionary-test-server
                 (lambda (_client command)
                   (cond
                    ((equal command "match original prefix \"reserved\"")
                     "152 2 matches\r\nactual \"reserve\"\r\nactual \"reservation\"\r\n.\r\n250 ok\r\n")
                    ((equal command "define actual \"reserve\"")
                     (zr-dictionary-test-definition "actual" "Correct server"))
                    (t "552 no match\r\n")))))
         (second (zr-dictionary-test-server (lambda (_client _command) "552 no match\r\n")))
         (stages (list (list (zr-dictionary-test-target first '(original extra))
                             (zr-dictionary-test-target second 'original)) 'similar)))
    (unwind-protect
        (let ((result (zr-dictionary-lookup "reserved" stages "prefix")))
          (should (equal result (list (list (format "[actual@127.0.0.1:%s]"
                                                   (process-contact first :service)) "Correct server"))))
          (should (member "define actual \"reserve\"" (process-get first 'commands)))
          (should-not (member "define actual \"reserve\"" (process-get second 'commands)))
          (should-not (member "define actual \"reservation\"" (process-get first 'commands)))
          (should (= (length (process-get first 'clients)) 1))
          (should (= (length (process-get second 'clients)) 1)))
      (zr-dictionary-test-stop-server first)
      (zr-dictionary-test-stop-server second))))

(ert-deftest zr-dictionary-test-async-timeout-keeps-received-results ()
  (let* ((dictionary-use-http-proxy nil)
         (zr-dictionary-timeout 0.2)
         (slow (zr-dictionary-test-server (lambda (_client _command) nil)))
         (fast (zr-dictionary-test-server
                (lambda (_client _command) (zr-dictionary-test-definition "fast" "Keep this result"))))
         (stages (list (list (zr-dictionary-test-target slow 'slow)
                             (zr-dictionary-test-target fast 'fast)))))
    (save-window-excursion
      (unwind-protect
          (progn
            (zr-dictionary-search "word" stages)
            (let ((query zr-dictionary--request))
              (zr-dictionary-test-wait)
              (should (string-match-p "Keep this result" (buffer-string)))
              (should (string-match-p "Error: Dictionary lookup timed out" (buffer-string)))
              (should (eq (zr-dictionary--view-status zr-dictionary--view) 'error))
              (dolist (client (zr-dictionary--query-clients query))
                (should-not (process-live-p (zr-dictionary--client-process (cdr client)))))))
        (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))
        (zr-dictionary-test-stop-server slow)
        (zr-dictionary-test-stop-server fast)))))

(ert-deftest zr-dictionary-test-cancel-keeps-history-and-closes-pending-processes ()
  (let* ((dictionary-use-http-proxy nil)
         (slow (zr-dictionary-test-server (lambda (_client _command) nil)))
         (fast (zr-dictionary-test-server
                (lambda (_client command)
                  (zr-dictionary-test-definition "fast" (if (string-match-p "old" command)
                                                             "Old received result" "New result")))))
         (stages (list (list (zr-dictionary-test-target slow 'slow)
                             (zr-dictionary-test-target fast 'fast)))))
    (save-window-excursion
      (unwind-protect
          (progn
            (zr-dictionary-search "old" stages)
            (zr-dictionary-test-until (lambda () (string-match-p "Old received result" (buffer-string))))
            (let ((old-query zr-dictionary--request))
              (zr-dictionary-test-search "new" (list (zr-dictionary-test-target fast 'fast)))
              (should (zr-dictionary--query-done old-query))
              (should-not (string-match-p "Old received result" (buffer-string)))
              (dolist (entry (zr-dictionary--query-clients old-query))
                (should-not (process-live-p (zr-dictionary--client-process (cdr entry)))))
              (dictionary-previous)
              (should (equal zr-dictionary-word "old"))
              (should (string-match-p "Old received result" (buffer-string)))
              (should (eq (zr-dictionary--view-status zr-dictionary--view) 'cancelled)))
            (zr-dictionary-search "pending" stages)
            (let ((query zr-dictionary--request))
              (call-interactively (key-binding "q"))
              (should-not (get-buffer "*zr-dictionary*"))
              (should (zr-dictionary--query-done query))
              (dolist (entry (zr-dictionary--query-clients query))
                (should-not (process-live-p (zr-dictionary--client-process (cdr entry)))))))
        (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))
        (zr-dictionary-test-stop-server slow)
        (zr-dictionary-test-stop-server fast)))))

(ert-deftest zr-dictionary-test-parses-fragmented-unicode-and-dot-stuffed-response ()
  (let* ((dictionary-use-http-proxy nil)
         client
         (server (zr-dictionary-test-server (lambda (process _command) (setq client process) nil)))
         (bytes (encode-coding-string
                 (zr-dictionary-test-definition "dict" "猫 é\r\n..leading dot") 'utf-8)))
    (save-window-excursion
      (unwind-protect
          (progn
            (zr-dictionary-search "word" (list (zr-dictionary-test-target server 'dict)))
            (zr-dictionary-test-until (lambda () client))
            ;; Feed one byte at a time, including split multibyte characters and CRLF.
            (dotimes (index (1- (length bytes)))
              (process-send-string client (substring bytes index (1+ index)))
              (accept-process-output nil 0.001))
            (should zr-dictionary--request)
            (process-send-string client (substring bytes -1))
            (zr-dictionary-test-wait)
            (should (string-match-p "猫 é\n\\.leading dot" (buffer-string)))
            (should-not (string-match-p "Error:" (buffer-string))))
        (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))
        (zr-dictionary-test-stop-server server)))))

(ert-deftest zr-dictionary-test-sync-waits-for-all-servers-and-merges-in-config-order ()
  (let* ((dictionary-use-http-proxy nil)
         sources timers
         (zr-dictionary-name-function
          (lambda (_name _id source) (push source sources) "Combined"))
         (slow (zr-dictionary-test-server
                (lambda (client _command)
                  (push (run-at-time 0.05 nil
                                     (lambda ()
                                       (when (process-live-p client)
                                         (process-send-string
                                          client (zr-dictionary-test-definition "same" "Slow"))))) timers)
                  nil)))
         (fast (zr-dictionary-test-server
                (lambda (_client _command) (zr-dictionary-test-definition "same" "Fast"))))
         (stages (list (list (zr-dictionary-test-target slow 'same)
                             (zr-dictionary-test-target fast 'same)))))
    (unwind-protect
        (progn
          (should (equal (zr-dictionary-lookup "word" stages) '(("Combined" "Slow" "Fast"))))
          (should (equal (mapcar (lambda (source) (plist-get source :port)) (reverse sources))
                         (list (process-contact fast :service) (process-contact slow :service))))
          (dolist (server (list slow fast))
            (should (= (length (process-get server 'clients)) 1))))
      (dolist (timer timers) (cancel-timer timer))
      (zr-dictionary-test-stop-server slow)
      (zr-dictionary-test-stop-server fast))))

(ert-deftest zr-dictionary-test-invalid-config-preserves-current-result ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (progn
           (zr-dictionary-test-search "word")
           (let ((view zr-dictionary--view) (text (buffer-string)))
             (should-error (zr-dictionary-search "other" '((:server "" :dictionary a))))
             (should (eq view zr-dictionary--view))
             (should (equal text (buffer-string)))))
       (when-let* ((buffer (get-buffer "*zr-dictionary*"))) (kill-buffer buffer))))))

(ert-deftest zr-dictionary-test-safe-local-configuration ()
  (let ((dictionary-server nil) (dictionary-port "invalid default")
        (dictionary-use-http-proxy t) (dictionary-proxy-server nil) (dictionary-proxy-port nil))
    (dolist (value '(nil ((:server t :port t :dictionary t))
                     ((:dictionary (a b similar)))
                     ((:server nil :port nil :dictionary a :proxy nil))
                     ((:server 123 :port t :dictionary t :proxy t))
                     ((:dictionary a :proxy "proxy.example:8080"))
                     ((:dictionary a :proxy "[::1]:8080"))
                     (((:server "first.example" :port 2628 :dictionary a)
                       (:server "second.example" :port t :dictionary (b c))) similar)))
      (should (safe-local-variable-p 'zr-dictionary-dictionaries value)))
    (dolist (value '(t (dict1) ((dict1 dict2) similar)
                     ((:dictionary ((progn (message "must not run")))))
                     ((:port -1 :dictionary a)) ((:dictionary (similar a)))
                     ((:dictionary a :proxy 123)) ((:dictionary a :proxy ""))
                     ((:dictionary a :proxy "proxy.example"))
                     ((:dictionary a :proxy "proxy.example:0"))
                     ((:dictionary a :proxy "proxy.example:65536"))
                     ((:dictionary a :proxy "proxy.example:8080\r\nQUIT"))
                     ((:dictionary a :proxy "bad host:8080"))
                     ((:dictionary (a similar b))) ((:dictionary nil))))
      (should-not (safe-local-variable-p 'zr-dictionary-dictionaries value))))
  (with-temp-buffer
    (insert "# -*- zr-dictionary-dictionaries: ((:server t :port t :dictionary t)); -*-\n")
    (let ((enable-local-variables :safe) (safe-local-variable-values nil))
      (hack-local-variables))
    (should (local-variable-p 'zr-dictionary-dictionaries))
    (should (equal zr-dictionary-dictionaries '((:server t :port t :dictionary t))))))

(ert-deftest zr-dictionary-test-dictionary-t-enables-only-its-own-similar-query ()
  (let* ((dictionary-use-http-proxy nil)
         (first (zr-dictionary-test-server
                 (lambda (_client command)
                   (cond
                    ((equal command "match * . \"reserved\"")
                     "152 1 match\r\nactual \"reserve\"\r\n.\r\n250 ok\r\n")
                    ((equal command "define actual \"reserve\"")
                     (zr-dictionary-test-definition "actual" "Wildcard match"))
                    (t "552 no match\r\n")))))
         (second (zr-dictionary-test-server (lambda (_client _command) "552 no match\r\n")))
         (stages (list (list (zr-dictionary-test-target first t)
                             (zr-dictionary-test-target second 'exact-only)))))
    (unwind-protect
        (progn
          (should (string-match-p "Wildcard match" (cadar (zr-dictionary-lookup "reserved" stages))))
          (should (member "match * . \"reserved\"" (process-get first 'commands)))
          (should-not (cl-some (lambda (command) (string-prefix-p "match " command))
                              (process-get second 'commands))))
      (zr-dictionary-test-stop-server first)
      (zr-dictionary-test-stop-server second))))

(provide 'zr-dictionary-test)
;;; zr-dictionary-test.el ends here
