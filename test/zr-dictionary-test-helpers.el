;;; zr-dictionary-test-helpers.el --- Local DICT fixtures -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'dictionary)
(require 'zr-dictionary)

(defmacro zr-dictionary-test-with-server (&rest body)
  "Run BODY against a local DICT server, using the real dictionary.el client."
  (declare (indent 0) (debug t))
  `(let* ((dictionary-commands nil)
          (dictionary-clients nil)
          (dictionary-greeting "220 test DICT server\r\n")
          (dictionary-response-function
           (lambda (_command)
             (concat "150 2 definitions retrieved\r\n"
                     "151 \"猫\" edict \"英和辞典\"\r\ncat from DICT\r\n.\r\n"
                     "151 \"猫\" local \"国語辞典\"\r\n猫の定義 from DICT\r\n.\r\n"
                     "250 ok\r\n")))
          (dictionary-server "127.0.0.1")
          (dictionary-use-http-proxy nil)
          (dictionary-default-dictionary "*")
          (zr-dictionary-dictionaries '("*" similar))
          (zr-dictionary-timeout 1)
          (zr-dictionary-strategy ".")
          (server
           (make-network-process
            :name "zr-dictionary-test-server" :server t :host "127.0.0.1"
            :service t :family 'ipv4 :coding 'binary :noquery t
            :log (lambda (_server client _message)
                   (push client dictionary-clients)
                   (set-process-query-on-exit-flag client nil)
                   (when dictionary-greeting
                     (process-send-string client dictionary-greeting)))
            :filter
            (lambda (client chunk)
              (let ((input (concat (or (process-get client 'input) "") chunk)))
                (while (string-match "\r\n" input)
                  (let ((command (substring input 0 (match-beginning 0))))
                    (setq input (substring input (match-end 0)))
                    (push (decode-coding-string command 'utf-8) dictionary-commands)
                    (when-let* ((response
                                 (if (string-prefix-p "client " command)
                                     "250 ok\r\n"
                                   (funcall dictionary-response-function
                                            (decode-coding-string command 'utf-8)))))
                      (process-send-string client (encode-coding-string response 'utf-8)))))
                (process-put client 'input input)))))
          (dictionary-port (process-contact server :service)))
     (unwind-protect
         (progn ,@body)
       (delete-process server)
       (dolist (client dictionary-clients)
         (when (process-live-p client) (delete-process client))))))

(defun zr-dictionary-test-definition (database text)
  "Return a DICT definition response for DATABASE containing TEXT."
  (format "150 1 definition\r\n151 \"word\" %s \"Dictionary %s\"\r\n%s\r\n.\r\n250 ok\r\n"
          database database text))

(defun zr-dictionary-test-queries (commands)
  "Return recorded COMMANDS in sending order, excluding client identification."
  (reverse (cl-remove-if (lambda (command) (string-prefix-p "client " command)) commands)))

(provide 'zr-dictionary-test-helpers)
;;; zr-dictionary-test-helpers.el ends here
