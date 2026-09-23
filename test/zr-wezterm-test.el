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
  "Chunk limits apply to UTF-8 bytes without splitting characters."
  (let ((zr-wezterm-chunk-size 4)
        (json "a中文😀b"))
    (let ((chunks (zr-wezterm--chunks json)))
      (should (equal json (string-join chunks "")))
      (dolist (chunk chunks)
        (should (<= (length (encode-coding-string chunk 'utf-8 t)) 4))))))

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
  (should (zr-wezterm-test--send '((type . "ping")) 4))
  (let* ((messages zr-wezterm-test--messages)
         (chunks (seq-filter
                  (lambda (message) (equal "chunk" (plist-get message :op)))
                  messages)))
    (should (equal "begin" (plist-get (car messages) :op)))
    (should (equal 4 (plist-get (car messages) :total)))
    (should (equal "test-id" (plist-get (car messages) :id)))
    (should (equal '(0 1 2 3) (mapcar (lambda (c) (plist-get c :seq)) chunks)))
    (should (equal zr-wezterm-test--payload
                   (string-join (mapcar (lambda (c) (plist-get c :data))
                                        chunks))))
    (should (equal "end" (plist-get (car (last messages)) :op)))))

(ert-deftest zr-wezterm-test-send-json-aborts ()
  "A failure halfway through aborts the transfer and is signalled."
  (should-error (zr-wezterm-test--send '((type . "ping")) 4 t))
  (let ((last (car (last zr-wezterm-test--messages))))
    (should (equal "abort" (plist-get last :op)))
    (should (equal "test-id" (plist-get last :id)))))

(provide 'zr-wezterm-test)
;;; zr-wezterm-test.el ends here
