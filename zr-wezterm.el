;;; zr-wezterm.el --- Talk to WezTerm -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, terminals

;;; Commentary:

;; Send JSON to WezTerm through the OSC 1337 user variable ZRTransport:
;;
;;   (zr-wezterm-send-json '((type . "set_theme")
;;                           (theme . "Google (light) (terminal.sexy)")))
;;
;; A payload longer than `zr-wezterm-chunk-size' is sent as one “begin”,
;; several “chunk” and one “end” message, all sharing an id, because a
;; single escape sequence that long is not delivered reliably.  An error
;; halfway through aborts the transfer and is signalled to the caller.

;;; Code:

(require 'cl-lib)

(defvar org-id-method)
(declare-function org-id-new "org-id")

(defconst zr-wezterm-chunk-size (* 32 1024)
  "Maximum number of JSON bytes sent in one OSC 1337 sequence.")

(defun zr-wezterm--osc (json)
  "Send JSON to WezTerm in the user variable ZRTransport."
  (send-string-to-terminal
   (format "\e]1337;SetUserVar=ZRTransport=%s\a"
           (base64-encode-string
            (encode-coding-string json 'utf-8 t)
            t))))

(defun zr-wezterm--chunks (json)
  "Split JSON into strings no larger than `zr-wezterm-chunk-size' bytes.
Keep each chunk on a character boundary so it remains valid JSON text when
it is serialized into a chunk message."
  (let ((limit zr-wezterm-chunk-size)
        (length (length json))
        (start 0)
        chunks)
    (unless (and (integerp limit) (> limit 0))
      (error "`zr-wezterm-chunk-size' must be a positive integer"))
    (while (< start length)
      ;; Binary search the largest character boundary whose UTF-8 encoding
      ;; fits in LIMIT.  This avoids treating multibyte characters as bytes.
      (let ((low (1+ start))
            (high (min length (+ start limit)))
            (end start))
        (while (<= low high)
          (let* ((middle (/ (+ low high) 2))
                 (bytes (length
                         (encode-coding-string
                          (substring json start middle) 'utf-8 t))))
            (if (<= bytes limit)
                (setq end middle
                      low (1+ middle))
              (setq high (1- middle)))))
        ;; A limit smaller than one UTF-8 character cannot be honored, but
        ;; still make progress and keep that character intact.
        (when (= end start)
          (setq end (1+ start)))
        (push (substring json start end) chunks)
        (setq start end)))
    (nreverse chunks)))

;;;###autoload
(defun zr-wezterm-send-json (object)
  "Send OBJECT to WezTerm as JSON.
Return non-nil once the last message has been sent."
  (unless (fboundp 'org-id-new)
    (require 'org-id))
  (let* ((payload (json-serialize object))
         (chunks (zr-wezterm--chunks payload))
         (id (org-id-new))
         (total (length chunks))
         (ok nil))

    (condition-case err
        (progn
          (zr-wezterm--osc
           (json-serialize
            `((op . "begin")
              (id . ,id)
              (total . ,total))))

          (cl-loop for chunk in chunks
                   for i from 0
                   do (zr-wezterm--osc
                       (json-serialize
                        `((op . "chunk")
                          (id . ,id)
                          (seq . ,i)
                          (data . ,chunk)))))

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
