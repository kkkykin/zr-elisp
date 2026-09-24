;;; zr-wezterm.el --- Talk to WezTerm -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, terminals

;;; Commentary:

;; Send JSON to WezTerm through the OSC 1337 user variable ZRTransport:
;;
;;   (zr-wezterm-send-json '((type . "set_theme")
;;                           (theme . "Google (light) (terminal.sexy)")))
;;
;; Each transfer consists of one “begin”, one or more “chunk” and one
;; “end” message, all sharing an id.  `zr-wezterm-chunk-size' limits each
;; complete escape sequence, including JSON escaping and Base64 encoding.
;; An error halfway through aborts the transfer and is signalled to the caller.

;;; Code:

(require 'cl-lib)

(defvar org-id-method)
(declare-function org-id-new "org-id")

(defconst zr-wezterm-chunk-size (* 32 1024)
  "Maximum bytes in one OSC 1337 sequence, including Base64 and framing.")

(defun zr-wezterm--encode-osc (json)
  "Encode JSON as an OSC 1337 sequence for the user variable ZRTransport."
  (format "\e]1337;SetUserVar=ZRTransport=%s\a"
          (base64-encode-string
           (encode-coding-string json 'utf-8 t)
           t)))

(defun zr-wezterm--osc (json)
  "Send JSON to WezTerm, enforcing `zr-wezterm-chunk-size'."
  (let ((sequence (zr-wezterm--encode-osc json)))
    (when (> (length sequence) zr-wezterm-chunk-size)
      (error "WezTerm OSC message exceeds `zr-wezterm-chunk-size'"))
    (send-string-to-terminal sequence)))

(defun zr-wezterm--chunks (json id)
  "Split JSON into serialized chunk messages for transfer ID.
Keep character boundaries and fit each complete OSC sequence within
`zr-wezterm-chunk-size', including the envelope, escaping and Base64."
  (let ((limit zr-wezterm-chunk-size)
        (length (length json))
        (start 0)
        (seq 0)
        chunks)
    (unless (and (integerp limit) (> limit 0))
      (error "`zr-wezterm-chunk-size' must be a positive integer"))
    (while (< start length)
      ;; Measure the actual encoded message, since quotes, backslashes,
      ;; UTF-8 characters and sequence numbers all affect its size.
      (let ((low (1+ start))
            (high (min length (+ start limit)))
            (end start)
            message)
        (while (<= low high)
          (let* ((middle (/ (+ low high) 2))
                 (candidate (json-serialize
                             `((op . "chunk") (id . ,id) (seq . ,seq)
                               (data . ,(substring json start middle)))))
                 (bytes (length (zr-wezterm--encode-osc candidate))))
            (if (<= bytes limit)
                (setq end middle
                      message candidate
                      low (1+ middle))
              (setq high (1- middle)))))
        (when (= end start)
          (error "`zr-wezterm-chunk-size' cannot fit a chunk message"))
        (push message chunks)
        (setq start end
              seq (1+ seq))))
    (nreverse chunks)))

;;;###autoload
(defun zr-wezterm-send-json (object)
  "Send OBJECT to WezTerm as JSON.
Return non-nil once the last message has been sent."
  (unless (fboundp 'org-id-new)
    (require 'org-id))
  (let* ((raw-payload (json-serialize object))
         (payload (if (multibyte-string-p raw-payload)
                      raw-payload
                    (decode-coding-string raw-payload 'utf-8)))
         (id (org-id-new))
         (chunks (zr-wezterm--chunks payload id))
         (total (length chunks))
         (ok nil))

    (condition-case err
        (progn
          (zr-wezterm--osc
           (json-serialize
            `((op . "begin")
              (id . ,id)
              (total . ,total))))

          (dolist (chunk chunks)
            (zr-wezterm--osc chunk))

          (zr-wezterm--osc
           (json-serialize
            `((op . "end")
              (id . ,id))))

          (setq ok t))

      (error
       (ignore-errors
         (zr-wezterm--osc
          (json-serialize
           `((op . "abort")
             (id . ,id)))))
       (signal (car err) (cdr err))))

    ok))

(provide 'zr-wezterm)
;;; zr-wezterm.el ends here
