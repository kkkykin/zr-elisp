;;; zr-wezterm-test.el --- Tests for zr-wezterm -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the chunked transfer of `zr-wezterm-send-json'.  The OSC
;; sequence itself is replaced, so nothing is written to a terminal.
;; Whatever was sent, successfully or not, ends up in
;; `zr-wezterm-test--messages'.

;;; Code:

(require 'ert)
(require 'cl-lib)

(load (expand-file-name
       "../zr-wezterm.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(declare-function zr-wezterm-send-json "zr-wezterm")

(defvar zr-wezterm-chunk-size)

(defvar zr-wezterm-test--messages nil
  "Messages of the last `zr-wezterm-test--send', as plists.")

(defvar zr-wezterm-test--payload nil
  "JSON sent by the last `zr-wezterm-test--send'.")

(ert-deftest zr-wezterm-test-osc-encodes-utf8-json ()
  "The OSC payload is base64-encoded UTF-8, including non-ASCII text."
  (let ((json "{\"text\":\"中文😀\"}") sent)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (string) (setq sent string))))
      (zr-wezterm--osc json))
    (let* ((prefix "\e]1337;SetUserVar=ZRTransport=")
           (encoded (substring sent (length prefix) -1)))
      (should (equal json
                     (decode-coding-string
                      (base64-decode-string encoded) 'utf-8 t))))))

(ert-deftest zr-wezterm-test-chunks-count-utf8-bytes ()
  "Encoded chunks respect their byte limit and preserve Unicode text."
  (let* ((zr-wezterm-chunk-size 128)
         (json (apply #'concat (make-list 40 "a中文😀\\\"b")))
         (chunks (zr-wezterm--chunks json "test-id")))
    (should (> (length chunks) 1))
    (should (equal json
                   (mapconcat (lambda (chunk)
                                (plist-get (json-parse-string chunk :object-type 'plist)
                                           :data))
                              chunks "")))
    (dolist (chunk chunks)
      (should (<= (length (zr-wezterm--encode-osc chunk)) zr-wezterm-chunk-size)))))

(defun zr-wezterm-test--send (object chunk-size &optional fail-p)
  "Send OBJECT in chunks of CHUNK-SIZE, returning non-nil on success.
With FAIL-P, fail while sending the second chunk."
  (let ((chunks 0)
        sent)
    (setq zr-wezterm-test--payload (json-serialize object))
    (cl-letf (((symbol-function 'zr-wezterm--osc)
               (lambda (json)
                 (let ((message (json-parse-string json :object-type 'plist)))
                   (when (and fail-p
                              (equal "chunk" (plist-get message :op))
                              (= 1 chunks))
                     (error "Broken pipe"))
                   (when (equal "chunk" (plist-get message :op))
                     (setq chunks (1+ chunks)))
                   (push json sent))))
              ((symbol-function 'org-id-new) (lambda () "test-id"))
              (zr-wezterm-chunk-size chunk-size))
      (unwind-protect
          (zr-wezterm-send-json object)
        (setq zr-wezterm-test--messages
              (mapcar (lambda (json)
                        (json-parse-string json :object-type 'plist))
                      (nreverse sent)))))))

(ert-deftest zr-wezterm-test-send-json-chunks ()
  "A payload longer than the chunk size is sent as chunks."
  (should (zr-wezterm-test--send `((text . ,(make-string 256 ?x))) 128))
  (let* ((messages zr-wezterm-test--messages)
         (chunks (seq-filter
                  (lambda (message) (equal "chunk" (plist-get message :op)))
                  messages)))
    (should (equal "begin" (plist-get (car messages) :op)))
    (should (> (length chunks) 1))
    (should (equal (length chunks) (plist-get (car messages) :total)))
    (should (equal "test-id" (plist-get (car messages) :id)))
    (should (equal (number-sequence 0 (1- (length chunks)))
                   (mapcar (lambda (c) (plist-get c :seq)) chunks)))
    (should (equal zr-wezterm-test--payload
                   (string-join (mapcar (lambda (c) (plist-get c :data))
                                        chunks))))
    (should (equal "end" (plist-get (car (last messages)) :op)))))

(ert-deftest zr-wezterm-test-send-json-non-ascii-unibyte ()
  "Payloads containing non-ASCII text serialize correctly even when
the underlying `json-serialize' returns a unibyte string (as in Emacs 30)."
  (let ((orig-json-serialize (symbol-function 'json-serialize)))
    (cl-letf (((symbol-function 'json-serialize)
               (lambda (obj &rest args)
                 ;; Emulate Emacs 30: return unibyte string with UTF-8 bytes
                 (let ((res (apply orig-json-serialize obj args)))
                   (if (and (consp obj) (assq 'op obj))
                       ;; Outer chunk envelope
                       res
                     ;; Inner payload: force unibyte UTF-8
                     (encode-coding-string res 'utf-8 t))))))
      (should (zr-wezterm-test--send
               '((type . "mpv")
                 (stdin . "/path/to/菲比珂莱塔 - V.mp4"))
               128)))))

(ert-deftest zr-wezterm-test-send-json-aborts ()
  "A failure halfway through aborts the transfer and is signalled."
  (should-error (zr-wezterm-test--send `((text . ,(make-string 256 ?x))) 128 t))
  (let ((last (car (last zr-wezterm-test--messages))))
    (should (equal "abort" (plist-get last :op)))
    (should (equal "test-id" (plist-get last :id)))))

(ert-deftest zr-wezterm-test-wire-size-and-round-trip ()
  "Every actual OSC fits the limit and reassembles to the original object."
  (dolist (limit '(160 32768))
    (let* ((zr-wezterm-chunk-size limit)
           (object `((text . ,(apply #'concat
                                    (make-list (if (= limit 160) 100 10000)
                                               "中文😀\"\\\n")))))
           messages)
      (cl-letf (((symbol-function 'org-id-new)
                 (lambda () "12345678-1234-1234-1234-123456789012"))
                ((symbol-function 'send-string-to-terminal)
                 (lambda (sequence)
                   (should (<= (string-bytes sequence) limit))
                   (push (json-parse-string
                          (decode-coding-string
                           (base64-decode-string
                            (substring sequence (length "\e]1337;SetUserVar=ZRTransport=") -1))
                           'utf-8)
                          :object-type 'plist)
                         messages))))
        (should (zr-wezterm-send-json object)))
      (setq messages (nreverse messages))
      (let ((chunks (seq-filter (lambda (msg) (equal (plist-get msg :op) "chunk"))
                                messages)))
        (should (> (length chunks) 1))
        (should (= (length chunks) (plist-get (car messages) :total)))
        (should (equal (number-sequence 0 (1- (length chunks)))
                       (mapcar (lambda (msg) (plist-get msg :seq)) chunks)))
        (should (equal object
                       (json-parse-string
                        (mapconcat (lambda (msg) (plist-get msg :data)) chunks "")
                        :object-type 'alist)))))))

(ert-deftest zr-wezterm-test-too-small-limit-sends-nothing ()
  "An impossible limit fails instead of sending an oversized character."
  (let ((zr-wezterm-chunk-size 4)
        sent)
    (cl-letf (((symbol-function 'org-id-new) (lambda () "test-id"))
              ((symbol-function 'send-string-to-terminal)
               (lambda (_) (setq sent t))))
      (should-error (zr-wezterm-send-json '((text . "中"))))
      (should-not sent))))

(provide 'zr-wezterm-test)
;;; zr-wezterm-test.el ends here
