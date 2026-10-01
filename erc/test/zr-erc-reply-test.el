;;; zr-erc-reply-test.el --- Tests for ERC replies -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests run without a server.  Set ZR_ERC_REPLY_TEST_PORT to run the
;; live test against an isolated local Ergo with two real ERC clients:
;; ZR_ERC_REPLY_TEST_PORT=6667 make test TEST_FILE=erc/test/zr-erc-reply-test.el

;;; Code:

(require 'ert)
(require 'cl-lib)
(eval-and-compile
  (load (expand-file-name "../zr-erc-reply.el"
                          (file-name-directory
                           (or load-file-name
                               (bound-and-true-p byte-compile-current-file)
                               buffer-file-name)))
        nil 'nomessage))

(ert-deftest zr-erc-reply-tag-codec ()
  (should (equal (zr-erc-reply--escape "a;b c\\d\r\n")
                 "a\\:b\\sc\\\\d\\r\\n"))
  (should (equal (zr-erc-reply--unescape "a\\:b\\sc\\\\d\\r\\n\\z\\")
                 "a;b c\\d\r\nz"))
  (should (equal (zr-erc-reply--tags "msgid=first;empty=;flag;msgid=a=b\\:c")
                 '(("flag") ("empty") ("msgid" . "a=b;c"))))
  (let ((erc-tags-format nil))
    (should (equal (zr-erc-reply--parse-tags #'ignore "+reply=a\\sb;msgid=c")
                   '((msgid . "c") (+reply . "a b")))))
  (let ((erc-tags-format 'legacy))
    (should (equal (zr-erc-reply--parse-tags #'erc--parse-tags "msgid=abc")
                   '(("msgid" "abc"))))))

(defun zr-erc-reply-test--cap (command capabilities &optional continued)
  "Deliver a CAP COMMAND listing CAPABILITIES, optionally CONTINUED."
  (zr-erc-reply--cap
   nil (make-erc-response :command "CAP"
                          :command-args (append (list "nick" command)
                                                (and continued '("*"))
                                                (list capabilities))
                          :contents capabilities)))

(ert-deftest zr-erc-reply-capability-negotiation ()
  (with-temp-buffer
    (let ((erc-zr-reply-mode t) sent)
      (cl-letf (((symbol-function 'erc-server-send)
                 (lambda (line &rest _) (push line sent))))
        (zr-erc-reply--negotiate)
        (should (equal sent '("CAP LS 302")))
        (zr-erc-reply-test--cap "LS" "echo-message sasl=PLAIN" t)
        (should (= (length sent) 1))
        (zr-erc-reply-test--cap "LS" "message-tags")
        (should (equal (car sent) "CAP REQ :message-tags"))
        (should-not zr-erc-reply--caps)
        (zr-erc-reply-test--cap "ACK" "message-tags")
        (should (equal (car sent) "CAP REQ :echo-message"))
        (zr-erc-reply-test--cap "NAK" "echo-message")
        (should (equal zr-erc-reply--caps '("message-tags")))
        (should-not zr-erc-reply--pending)
        (zr-erc-reply-test--cap "DEL" "message-tags")
        (should-not zr-erc-reply--caps)
        (zr-erc-reply-test--cap "NEW" "message-tags")
        (should (equal (car sent) "CAP REQ :message-tags"))
        (zr-erc-reply--reset)
        (should-not zr-erc-reply--pending)
        (should-not zr-erc-reply--offered)))))

(ert-deftest zr-erc-reply-unsupported-server ()
  (with-temp-buffer
    (let ((erc-zr-reply-mode t) sent)
      (cl-letf (((symbol-function 'erc-server-send)
                 (lambda (line &rest _) (push line sent))))
        (zr-erc-reply-test--cap "LS" "echo-message sasl")
        (should-not sent)
        (should-not zr-erc-reply--caps)))))

(ert-deftest zr-erc-reply-send-tags-and-target-scope ()
  (let ((zr-erc-reply--outgoing '("#Chat" . "a; b\\c")))
    (cl-letf (((symbol-function 'zr-erc-reply--cap-p) (lambda (_) t)))
      (should (equal (zr-erc-reply--send #'list "PRIVMSG #chat :hello" nil "#chat")
                     '("@+reply=a\\:\\sb\\\\c PRIVMSG #chat :hello" nil "#chat")))
      (should (equal (car (zr-erc-reply--send #'list "@+x=y PRIVMSG #Chat :hello"))
                     "@+reply=a\\:\\sb\\\\c;+x=y PRIVMSG #Chat :hello"))
      (should (equal (car (zr-erc-reply--send #'list "PRIVMSG #other :hello"))
                     "PRIVMSG #other :hello"))
      (should (equal (car (zr-erc-reply--send #'list "PONG :token")) "PONG :token")))
    (cl-letf (((symbol-function 'zr-erc-reply--cap-p) #'ignore))
      (should-error (zr-erc-reply--send #'ignore "PRIVMSG #chat :hello")
                    :type 'user-error))))

(defun zr-erc-reply-test--insert (id text &optional parent command)
  "Insert a formatted test message with ID, TEXT, PARENT and COMMAND."
  (let* ((erc-zr-reply-mode t)
         (erc-message-parsed
          (make-erc-response
           :command (or command "PRIVMSG") :sender "alice!u@host"
           :contents text
           :unparsed (concat "@msgid=" id
                              (and parent (concat ";+reply=" parent))
                              " :alice!u@host PRIVMSG #test :" text)))
         (start (point-max)))
    (goto-char start)
    (insert "<alice> " text "\n")
    (save-restriction
      (narrow-to-region start (point))
      (zr-erc-reply--insert)
      (zr-erc-reply--remember))))

(ert-deftest zr-erc-reply-visible-parent-and-navigation ()
  (with-temp-buffer
    (zr-erc-reply-test--insert "first" "明天几点开会？")
    (zr-erc-reply-test--insert "second" "十点" "first")
    (should (string-match-p "\\[↪ alice: 明天几点开会？\\] <alice> 十点"
                            (buffer-string)))
    (goto-char (zr-erc-reply--find (copy-sequence "second")))
    (should (button-at (point)))
    (zr-erc-reply-jump)
    (should (= (point) (point-min)))
    (goto-char (zr-erc-reply--find "second"))
    (button-activate (button-at (point)))
    (should (= (point) (point-min)))
    ;; Buffer truncation must never redirect a stale reference elsewhere.
    (delete-region (point-min) (zr-erc-reply--find "second"))
    (goto-char (point-min))
    (should-error (zr-erc-reply-jump) :type 'user-error)))

(ert-deftest zr-erc-reply-missing-parent-and-buffer-isolation ()
  (with-temp-buffer
    (zr-erc-reply-test--insert "same-id" "another conversation")
    (with-temp-buffer
      (zr-erc-reply-test--insert "reply" "body" "same-id" "NOTICE")
      (should (string-match-p "Original unavailable: same-id" (buffer-string)))
      (should-not (zr-erc-reply--find "same-id"))
      (goto-char (point-min))
      (should-error (zr-erc-reply-jump) :type 'user-error))))

(ert-deftest zr-erc-reply-echo-suppression ()
  (cl-letf (((symbol-function 'zr-erc-reply--cap-p) (lambda (_) t)))
    (should-not (zr-erc-reply--local-display #'list "outgoing"))
    (should-not (zr-erc-reply--display-message #'list nil nil nil
                                              'input-chan-privmsg))
    (should (zr-erc-reply--display-message #'list 'parsed nil nil
                                           'input-chan-privmsg))
    (should (zr-erc-reply--display-message #'list nil 'notice nil "status")))
  (cl-letf (((symbol-function 'zr-erc-reply--cap-p) #'ignore))
    (should (zr-erc-reply--local-display #'list "outgoing"))))

(ert-deftest zr-erc-reply-module-lifecycle ()
  (let ((erc-modules nil))
    (unwind-protect
        (progn
          (erc-zr-reply-mode 1)
          (erc-zr-reply-mode 1)
          (should (memq 'zr-reply erc-modules))
          (should (advice-member-p #'zr-erc-reply--send 'erc-server-send))
          (erc-zr-reply-mode -1)
          (should-not zr-erc-reply--installed)
          (should-not (advice-member-p #'zr-erc-reply--send 'erc-server-send)))
      (erc-zr-reply-mode -1))))

(defun zr-erc-reply-test--wait (predicate)
  "Wait at most ten seconds for PREDICATE while processing network input."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun zr-erc-reply-test--position (buffer text)
  "Find literal TEXT in BUFFER, returning its start."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward text nil t) (- (point) (length text))))))

(defun zr-erc-reply-test--input (text)
  "Submit TEXT through ERC's prompt, just like typing RET."
  (goto-char (point-max))
  (insert text)
  (let ((erc-accidental-paste-threshold-seconds nil))
    (erc-send-current-line)))

(ert-deftest zr-erc-reply-live-ergo ()
  (skip-unless (getenv "ZR_ERC_REPLY_TEST_PORT"))
  (let ((erc-modules '(networks button fill stamp))
        (erc-server-auto-reconnect nil)
        (erc-flood-protect nil)
        (erc-server-flood-penalty 0)
        (erc-prompt-for-password nil)
        (erc-kill-buffer-on-part nil)
        (erc-debug-irc-protocol t)
        (port (string-to-number (getenv "ZR_ERC_REPLY_TEST_PORT")))
        (old-buffers (buffer-list))
        alice bob a b ap bp)
    (unwind-protect
        (progn
          (erc-zr-reply-mode 1)
          (setq alice (erc :server "127.0.0.1" :port port :nick "zr-alice"
                           :full-name "ERC reply test")
                bob (erc :server "127.0.0.1" :port port :nick "zr-bob"
                         :full-name "ERC reply test")
                ap (buffer-local-value 'erc-server-process alice)
                bp (buffer-local-value 'erc-server-process bob))
          (zr-erc-reply-test--wait
           (lambda ()
             (and (with-current-buffer alice (zr-erc-reply--cap-p "echo-message"))
                  (with-current-buffer bob (zr-erc-reply--cap-p "echo-message")))))
          (with-current-buffer alice (erc-cmd-JOIN "#zr-replies"))
          (with-current-buffer bob (erc-cmd-JOIN "#zr-replies"))
          (zr-erc-reply-test--wait
           (lambda ()
             (and (setq a (erc-get-buffer "#zr-replies" ap))
                  (setq b (erc-get-buffer "#zr-replies" bp)))))
          (with-current-buffer a (zr-erc-reply-test--input "明天几点开会？"))
          (zr-erc-reply-test--wait
           (lambda () (zr-erc-reply-test--position b "明天几点开会？")))
          (let ((original (with-current-buffer b
                            (goto-char (zr-erc-reply-test--position b "明天几点开会？"))
                            (get-text-property (point) 'zr-erc-reply-msgid))))
            (should original)
            (with-current-buffer b (zr-erc-reply "十点开会"))
            (zr-erc-reply-test--wait
             (lambda () (and (zr-erc-reply-test--position a "十点开会")
                             (zr-erc-reply-test--position b "十点开会"))))
            (dolist (buffer (list a b))
              (with-current-buffer buffer
                (should (zr-erc-reply-test--position buffer "↪ zr-alice: 明天几点开会？"))
                (goto-char (zr-erc-reply-test--position buffer "十点开会"))
                (should (equal (get-text-property (point) 'zr-erc-reply-parent) original))
                (should (get-text-property (point) 'zr-erc-reply-msgid))
                (should-not (get-text-property (point) 'erc-parsed))
                (zr-erc-reply-jump)
                (should (equal (get-text-property (point) 'zr-erc-reply-msgid) original)))))
          ;; Own echoed messages are replyable, and displayed only once.
          (with-current-buffer a
            (goto-char (zr-erc-reply-test--position a "明天几点开会？"))
            (zr-erc-reply "/literal reply, not a command"))
          (zr-erc-reply-test--wait
           (lambda () (zr-erc-reply-test--position b "/literal reply, not a command")))
          (dolist (buffer (list a b))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should (= 1 (how-many "十点开会" (point-min) (point-max))))))
          ;; Ordinary /ME should also appear once while echo-message is active.
          (with-current-buffer a (zr-erc-reply-test--input "/me waves-test"))
          (zr-erc-reply-test--wait
           (lambda () (zr-erc-reply-test--position a "waves-test")))
          (with-current-buffer a
            (should (= 1 (how-many "waves-test" (point-min) (point-max)))))
          ;; Every fragment of a multiline/long reply keeps its reference.
          (let ((body (concat (make-string 700 ?x) "\nlast-fragment-test")) original)
            (with-current-buffer b
              (goto-char (zr-erc-reply-test--position b "明天几点开会？"))
              (setq original (get-text-property (point) 'zr-erc-reply-msgid))
              (zr-erc-reply body))
            (zr-erc-reply-test--wait
             (lambda () (zr-erc-reply-test--position a "last-fragment-test")))
            (with-current-buffer a
              (goto-char (point-min))
              (while (re-search-forward "x\\{10,\\}\\|last-fragment-test" nil t)
                (should (equal (get-text-property (match-beginning 0)
                                                  'zr-erc-reply-parent)
                               original)))))
          ;; Private conversations use the same references and echo handling.
          (with-current-buffer a (zr-erc-reply-test--input "/msg zr-bob private-original-test"))
          (let (qa qb)
            (zr-erc-reply-test--wait
             (lambda () (and (setq qa (erc-get-buffer "zr-bob" ap))
                             (setq qb (erc-get-buffer "zr-alice" bp))
                             (zr-erc-reply-test--position qb "private-original-test"))))
            (with-current-buffer qb
              (goto-char (zr-erc-reply-test--position qb "private-original-test"))
              (zr-erc-reply "private-reply-test"))
            (zr-erc-reply-test--wait
             (lambda () (and (zr-erc-reply-test--position qa "private-reply-test")
                             (zr-erc-reply-test--position qb "private-reply-test"))))
            (dolist (buffer (list qa qb))
              (should (zr-erc-reply-test--position buffer "↪ zr-alice: private-original-test"))))
          ;; A server without echo-message still supports incoming references.
          (with-current-buffer bob (erc-server-send "CAP REQ :-echo-message" t))
          (zr-erc-reply-test--wait
           (lambda () (not (with-current-buffer bob
                            (zr-erc-reply--cap-p "echo-message")))))
          (with-current-buffer b
            (goto-char (zr-erc-reply-test--position b "明天几点开会？"))
            (zr-erc-reply "no-echo-reply-test")
            (should (= 1 (how-many "no-echo-reply-test" (point-min) (point-max))))
            (goto-char (zr-erc-reply-test--position b "no-echo-reply-test"))
            (should (get-text-property (point) 'zr-erc-reply-parent))
            (should-not (get-text-property (point) 'zr-erc-reply-msgid)))
          (zr-erc-reply-test--wait
           (lambda () (zr-erc-reply-test--position a "no-echo-reply-test")))
          ;; Shutdown must remove all integration after the negative CAP ACKs.
          (erc-zr-reply-mode -1)
          (zr-erc-reply-test--wait (lambda () (not zr-erc-reply--installed)))
          (with-current-buffer a
            (zr-erc-reply-test--input "after-disable-test"))
          (zr-erc-reply-test--wait
           (lambda () (zr-erc-reply-test--position b "after-disable-test")))
          (with-current-buffer a
            (should (= 1 (how-many "after-disable-test" (point-min) (point-max)))))
          ;; Enabling on already registered connections negotiates afresh.
          (erc-zr-reply-mode 1)
          (zr-erc-reply-test--wait
           (lambda () (and (with-current-buffer alice (zr-erc-reply--cap-p "echo-message"))
                           (with-current-buffer bob (zr-erc-reply--cap-p "echo-message")))))
          (when-let* ((file (getenv "ZR_ERC_REPLY_TEST_TRANSCRIPT")))
            (with-current-buffer a (write-region (point-min) (point-max) file nil 'silent))))
      (dolist (process (list ap bp))
        (when (process-live-p process) (delete-process process)))
      (erc-zr-reply-mode -1)
      (dolist (buffer (cl-set-difference (buffer-list) old-buffers))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'zr-erc-reply-test)
;;; zr-erc-reply-test.el ends here
