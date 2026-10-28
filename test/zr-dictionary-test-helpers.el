;;; zr-dictionary-test-helpers.el --- Local DICT fixtures -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'dictionary)
(require 'zr-dictionary)

(defun zr-dictionary-test-wait (&optional buffer)
  "Wait for BUFFER's asynchronous search to finish, failing if it gets stuck."
  (with-current-buffer (or buffer (current-buffer))
    (let ((deadline (+ (float-time) 3)))
      (while (and zr-dictionary--request (< (float-time) deadline))
        (accept-process-output nil 0.01))
      (should-not zr-dictionary--request))))

(defun zr-dictionary-test-search (&rest args)
  "Start a real search with ARGS and wait before checking its complete result."
  (let ((buffer (apply #'zr-dictionary-search args)))
    (zr-dictionary-test-wait buffer)
    buffer))

(defun zr-dictionary-test-until (predicate)
  "Wait for PREDICATE, failing after three seconds."
  (let ((deadline (+ (float-time) 3)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(defun zr-dictionary-test-server (response-function &optional proxy)
  "Create a local DICT fixture using RESPONSE-FUNCTION of (CLIENT COMMAND).
Store commands and accepted clients on the server process for assertions.
When PROXY is non-nil, require HTTP CONNECT before the DICT greeting."
  (make-network-process
   :name "zr-dictionary-multi-server" :server t :host "127.0.0.1"
   :service t :family 'ipv4 :coding 'binary :noquery t
   :log (lambda (server client _message)
          (process-put client 'server server)
          (process-put server 'clients (cons client (process-get server 'clients)))
          (set-process-query-on-exit-flag client nil)
          (unless proxy (process-send-string client "220 test DICT server\r\n")))
   :filter
   (lambda (client chunk)
     (let ((input (concat (or (process-get client 'input) "") chunk)))
       (while (string-match "\r\n" input)
         (let* ((end (match-beginning 0))
                (command (decode-coding-string (substring input 0 end) 'utf-8))
                (server (process-get client 'server)))
           (setq input (substring input (+ end 2)))
           (process-put server 'commands (cons command (process-get server 'commands)))
           (when-let* ((response
                        (cond
                         ((and proxy (string-prefix-p "CONNECT " command))
                          "HTTP/1.1 200 Connection established\r\n\r\n220 test DICT server\r\n")
                         ((string-empty-p command) nil)
                         ((string-prefix-p "client " command) "250 ok\r\n")
                         (t (funcall response-function client command)))))
             (process-send-string client (encode-coding-string response 'utf-8)))))
       (process-put client 'input input)))))

(defun zr-dictionary-test-stop-server (server)
  "Release SERVER and all of its accepted clients."
  (delete-process server)
  (dolist (client (process-get server 'clients)) (delete-process client)))

(defun zr-dictionary-test-target (server dictionaries)
  "Return an explicit target for DICTIONARIES on fixture SERVER."
  (list :server "127.0.0.1" :port (process-contact server :service) :dictionary dictionaries))

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
          (zr-dictionary-dictionaries '((:server t :port t :dictionary t)))
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
