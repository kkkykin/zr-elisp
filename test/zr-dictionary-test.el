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
     (let ((zr-dictionary-dictionaries '("bad database")))
       (should-error (zr-dictionary-lookup "word")))
     (should (= before (length dictionary-commands))))))

(ert-deftest zr-dictionary-test-group-collects-all-hits-before-stopping ()
  (dolist (hits '(((dict1 . "Alpha") (dict2 . "Beta"))
                  ((dict1 . "Alpha"))
                  ((dict2 . "Beta"))))
    (zr-dictionary-test-with-server
     (let ((zr-dictionary-dictionaries '((dict1 "dict2") dict3 similar))
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
   (let ((zr-dictionary-dictionaries '((dict1 dict2)))
         (zr-dictionary-name-function (lambda (_name _id) "Combined")))
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
   (let ((zr-dictionary-dictionaries '((dict1 dict2) dict3 similar)))
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
     (let ((zr-dictionary-dictionaries '((dict1 dict2) "dict3" similar)))
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
   (let ((zr-dictionary-dictionaries '((dict1 dict2) dict3)))
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
           (zr-dictionary-dictionaries '((dict1 dict2) dict3 similar))
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
         (zr-dictionary-dictionaries '("*" similar))
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
   (should (equal (zr-dictionary-lookup "reserved" '(dict1 similar) "prefix")
                  '(("[dict1]" "Definition"))))
   (should (equal (zr-dictionary-test-queries dictionary-commands)
                  '("define dict1 \"reserved\"" "match dict1 prefix \"reserved\""
                    "define dict1 \"reserve\"")))
   (should (equal zr-dictionary-dictionaries '("*" similar)))
   (should (equal zr-dictionary-strategy "."))
   (let ((before (length dictionary-commands)))
     (should-not (zr-dictionary-lookup "reserved" nil))
     (should-error (zr-dictionary-lookup "reserved" '(dict1 similar) "bad strategy"))
     (should-error (zr-dictionary-lookup "reserved" '(dict1 similar) "prefix\r\nQUIT"))
     (should (= before (length dictionary-commands))))))

(ert-deftest zr-dictionary-test-search-and-reference-use-buffer-configuration ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (with-temp-buffer
           (setq-local zr-dictionary-dictionaries '(dict1 similar)
                       zr-dictionary-strategy "prefix")
           (setq dictionary-response-function
                 (lambda (_command)
                   (zr-dictionary-test-definition "dict1" "See {猫} and {a\r\n phrase}.")))
           (zr-dictionary-search "word")
           (should (eq major-mode 'dictionary-mode))
           (should buffer-read-only)
           (should (equal zr-dictionary-word "word"))
           (should (equal zr-dictionary-dictionaries '(dict1 similar)))
           (should (equal zr-dictionary-strategy "prefix"))
           (goto-char (point-min))
           (search-forward "猫")
           (let ((button (button-at (1- (point)))))
             (should button)
             (button-activate button))
           (should (equal zr-dictionary-word "猫"))
           (goto-char (point-min))
           (search-forward "phrase")
           (button-activate (button-at (1- (point))))
           (should (equal zr-dictionary-word "a phrase"))
           (dictionary-previous)
           (should (equal zr-dictionary-word "猫"))
           (should (equal zr-dictionary-dictionaries '(dict1 similar)))
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
             (zr-dictionary-search "word" '((dict1 dict2) similar) "prefix")
             (should (equal (key-binding "s") #'zr-dictionary-search))
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "next")))
               (call-interactively (key-binding "s")))
             (should (equal zr-dictionary-word "next"))
             (goto-char (point-min))
             (search-forward "猫")
             (call-interactively (key-binding "d"))
             (should (equal zr-dictionary-word "猫"))
             (cl-letf (((symbol-function 'read-minibuffer)
                        (lambda (&rest _) '(dict3 similar))))
               (goto-char (point-min))
               (search-forward "[Select dictionary]")
               (button-activate (button-at (1- (point)))))
             (should (equal zr-dictionary-dictionaries '(dict3 similar)))
             (should (member "define dict3 \"猫\"" dictionary-commands))
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "suffix")))
               (call-interactively (key-binding "M")))
             (should (equal zr-dictionary-strategy "suffix"))
             (let ((history (copy-tree dictionary-data-stack)))
               (setq dictionary-response-function
                     (lambda (_command) (zr-dictionary-test-definition "dict3" "Fresh é 猫 %s.")))
               (revert-buffer t t)
               (should (equal history dictionary-data-stack))
               (should (string-match-p "Fresh é 猫 %s" (buffer-string)))
               (should buffer-read-only)
               (should-not (buffer-modified-p)))
             (dictionary-previous)
             (should (equal zr-dictionary-strategy "prefix"))
             (should (equal zr-dictionary-dictionaries '(dict3 similar)))
             (dictionary-previous)
             (should (equal zr-dictionary-dictionaries '((dict1 dict2) similar)))
             (should (string-match-p "See {猫}" (buffer-string)))
             (should (equal native-map dictionary-mode-map)))
         (when-let* ((buffer (get-buffer "*zr-dictionary*")))
           (kill-buffer buffer)))))))

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
             (zr-dictionary-search "word" '((dict1 dict2) dict3 similar) "prefix")
             (setq dictionary-commands nil)
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "word")))
               (goto-char (point-min))
               (search-forward "[Matching words]")
               (button-activate (button-at (1- (point)))))
             (should (equal (zr-dictionary-test-queries dictionary-commands)
                            '("match dict1 prefix \"word\"" "match dict2 prefix \"word\"")))
             (should (string-match-p "猫" (buffer-string)))
             (should (string-match-p "cat" (buffer-string)))
             (goto-char (point-min))
             (search-forward "a\"b\\c")
             (button-activate (button-at (1- (point))))
             (should (equal zr-dictionary-word "a\"b\\c"))
             (should (equal (last (zr-dictionary-test-queries dictionary-commands) 2)
                            '("define dict1 \"a\\\"b\\\\c\"" "define dict2 \"a\\\"b\\\\c\"")))
             (dictionary-previous)
             (should zr-dictionary--matching-p)
             (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "missing")))
               (call-interactively (key-binding "m")))
             (should (string-match-p "No matching words" (buffer-string)))
             (should (member "match dict3 prefix \"missing\"" dictionary-commands))
             (should buffer-read-only)
             (let ((history (copy-tree dictionary-data-stack)))
               (revert-buffer t t)
               (should (equal history dictionary-data-stack))))
         (when-let* ((buffer (get-buffer "*zr-dictionary*")))
           (kill-buffer buffer)))))))

(ert-deftest zr-dictionary-test-search-failure-preserves-visible-result ()
  (zr-dictionary-test-with-server
   (save-window-excursion
     (unwind-protect
         (progn
           (zr-dictionary-search "word" '(dict1 similar) "prefix")
           (let ((text (buffer-string))
                 (history (copy-tree dictionary-data-stack)))
             (setq dictionary-response-function (lambda (_command) "500 error\r\n"))
             (should-error (zr-dictionary-search "failure"))
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
                 (zr-dictionary-search "staged" '(dict1 similar) "prefix")
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

(provide 'zr-dictionary-test)
;;; zr-dictionary-test.el ends here
