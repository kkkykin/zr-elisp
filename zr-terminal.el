;;; zr-terminal.el --- Terminal OSC communication -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; Keywords: comm, terminals
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Send OSC sequences to the selected terminal frame, or an explicit FRAME.
;; `zr-terminal-notify' sends an OSC 777 notification on terminals supporting
;; the rxvt notify extension, including WezTerm.  No terminal configuration
;; or notification backend is changed when this library is loaded.

;;; Code:

(defun zr-terminal-encode-osc (code payload)
  "Encode OSC CODE and text PAYLOAD as UTF-8 bytes terminated by BEL.
CODE is a nonnegative integer.  PAYLOAD must not contain control characters."
  (unless (natnump code)
    (signal 'wrong-type-argument (list 'natnump code)))
  ;; Cover Unicode controls and raw C1 bytes in Emacs strings.
  (when (string-match-p "[\0-\x1f\u007f-\u009f\x80-\x9f]" payload)
    (error "OSC payload must not contain control characters"))
  (encode-coding-string (format "\e]%d;%s\a" code payload) 'utf-8 t))

;;;###autoload
(defun zr-terminal-send-osc (code payload &optional frame)
  "Send OSC CODE with text PAYLOAD to FRAME's terminal.
FRAME defaults to the selected frame and must be a live terminal frame.
Return t after writing the sequence; the terminal does not acknowledge it."
  (let ((frame (or frame (selected-frame))))
    (unless (and (frame-live-p frame) (not (display-graphic-p frame)))
      (user-error "OSC requires a live terminal frame"))
    (send-string-to-terminal (zr-terminal-encode-osc code payload) frame)
    t))

;;;###autoload
(defun zr-terminal-notify (title body &optional frame)
  "Send TITLE and BODY as an OSC 777 notification to FRAME's terminal.
FRAME defaults to the selected frame.  The terminal must support the
rxvt notify extension.  Semicolons and control characters in TITLE and
BODY are replaced with spaces because the protocol cannot escape them.
Return t after sending; no notification ID is available."
  (interactive "sTitle: \nsBody: ")
  (zr-terminal-send-osc
   777 (format "notify;%s;%s"
               (replace-regexp-in-string "[;\0-\x1f\u007f-\u009f\x80-\x9f]"
                                         " " title)
               (replace-regexp-in-string "[;\0-\x1f\u007f-\u009f\x80-\x9f]"
                                         " " body))
   frame))

(provide 'zr-terminal)
;;; zr-terminal.el ends here
