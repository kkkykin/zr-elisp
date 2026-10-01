;;; zr-erc-stitch-test.el --- Stitching tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'zr-erc-stitch)
(require 'zr-erc-reply)

(defun zr-erc-stitch-test--message (body &optional nick target tags)
  (make-erc-response
   :sender (concat (or nick "alice") "!u@host") :command "PRIVMSG"
   :command-args (list (or target "#test") body) :contents body
   :unparsed (concat (and tags (concat "@" tags " "))
                     ":" (or nick "alice") "!u@host PRIVMSG "
                     (or target "#test") " :" body)))

(defmacro zr-erc-stitch-test--with-server (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (let* ((erc-server-process (make-pipe-process :name "stitch-test" :buffer (current-buffer)
                                                   :noquery t))
            (erc-server-current-nick "me")
            (erc-session-server "test")
            delivered)
       (unwind-protect
           (cl-letf (((symbol-function 'zr-erc-stitch--deliver)
                      (lambda (_process message) (push message delivered))))
             ,@body)
         (zr-erc-stitch--flush-all)
         (delete-process erc-server-process)))))

(ert-deftest zr-erc-stitch-clipped-sequence-and-reply-ids ()
  (zr-erc-stitch-test--with-server
    (should (zr-erc-stitch--receive erc-server-process
                                    (zr-erc-stitch-test--message "你好 <clipped message>"
                                                                 nil nil "msgid=a")))
    (should-not delivered)
    (should (zr-erc-stitch--receive erc-server-process
                                    (zr-erc-stitch-test--message "<clipped message> 世界"
                                                                 nil nil "msgid=b")))
    (should (= 1 (length delivered)))
    (let ((message (car delivered)))
      (should (equal (erc-response.contents message) "你好世界"))
      (should (equal (zr-erc-message-ids message) '("a" "b")))
      (with-temp-buffer
        (insert "<alice> 你好世界\n")
        (let ((erc-zr-reply-mode t) (erc-message-parsed message))
          (zr-erc-reply--remember))
        (should (= 1 (zr-erc-reply--find "a")))
        (should (= 1 (zr-erc-reply--find "b")))))))

(ert-deftest zr-erc-stitch-tags-and-conversation-isolation ()
  (zr-erc-stitch-test--with-server
    (let ((zr-erc-stitch-rules '((:more-tag ("+more" . "^1$")
                                :group-tag "+group" :separator "\n"))))
      (zr-erc-stitch--receive erc-server-process
                              (zr-erc-stitch-test--message "one" nil nil "+more=1;+group=x"))
      (should-not (zr-erc-stitch--receive erc-server-process
                                         (zr-erc-stitch-test--message "other channel" nil "#other")))
      (zr-erc-stitch--receive erc-server-process
                              (zr-erc-stitch-test--message "two" nil nil "+group=x"))
      (should (equal (erc-response.contents (car delivered)) "one\ntwo")))))

(ert-deftest zr-erc-stitch-interruption-and-limits-retain-originals ()
  (zr-erc-stitch-test--with-server
    (let ((first (zr-erc-stitch-test--message "one <clipped message>")))
      (zr-erc-stitch--receive erc-server-process first)
      (should-not (zr-erc-stitch--receive erc-server-process
                                         (zr-erc-stitch-test--message "hello" "bob")))
      (should (eq (car delivered) first)))
    (let ((zr-erc-stitch-max-fragments 1))
      (zr-erc-stitch--receive erc-server-process
                              (zr-erc-stitch-test--message "one <clipped message>"))
      (zr-erc-stitch--receive erc-server-process (zr-erc-stitch-test--message "two"))
      (should (equal (mapcar #'erc-response.contents (reverse delivered))
                     '("one <clipped message>" "one <clipped message>" "two"))))))

(ert-deftest zr-erc-stitch-timeout-retains-original ()
  (zr-erc-stitch-test--with-server
    (let ((zr-erc-stitch-timeout 0.01))
      (zr-erc-stitch--receive erc-server-process
                              (zr-erc-stitch-test--message "unfinished <clipped message>"))
      (let ((deadline (+ (float-time) 1)))
        (while (and (not delivered) (< (float-time) deadline))
          (accept-process-output nil 0.02)))
      (should (equal (erc-response.contents (car delivered)) "unfinished <clipped message>"))
      (should (= 0 (hash-table-count zr-erc-stitch--pending))))))

(ert-deftest zr-erc-stitch-rule-selectors ()
  (should (zr-erc-match-p '(:sender "onebot$" :tags (("+relay" . "^yes$")))
                          '(:sender "bridge-onebot" :tags (("+relay" . "yes")))))
  (should-not (zr-erc-match-p '(:tags (("+relay"))) '(:tags nil)))
  (zr-erc-stitch-test--with-server
    (let ((zr-erc-stitch-rules '((:match (:sender "^bridge$") :end " END\\'"))))
      (should-not (zr-erc-stitch--receive erc-server-process
                                         (zr-erc-stitch-test--message "one END")))
      (zr-erc-stitch--receive erc-server-process
                              (zr-erc-stitch-test--message "one END" "bridge"))
      (zr-erc-stitch--receive erc-server-process
                              (zr-erc-stitch-test--message "two" "bridge"))
      (should (equal (erc-response.contents (car delivered)) "onetwo")))))

(provide 'zr-erc-stitch-test)
;;; zr-erc-stitch-test.el ends here
