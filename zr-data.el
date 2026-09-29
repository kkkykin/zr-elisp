;;; zr-data.el --- JSON, SOPS, UUIDs and passwords -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Source: ../emacs.d/user-lisp/init-misc.el (selected functionality).
;;; Commentary:
;; Explicit data operations; no files or external programs are touched on load.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(defvar org-id-method)
(declare-function org-id-new "org-id")
(defgroup zr-data nil "Data utilities." :group 'data)
(defcustom zr-data-sops-program "sops" "SOPS executable." :type 'string)
(defcustom zr-data-password-length 20 "Length of generated passwords." :type 'natnum)
(defun zr-data-read-json (file)
  "Parse JSON FILE into hash tables and vectors."
  (with-temp-buffer (insert-file-contents file) (json-parse-buffer)))
(defun zr-data-merge-json (first second)
  "Merge JSON values FIRST and SECOND without modifying either.
Objects merge recursively, arrays concatenate, other values favor SECOND."
  (cond ((and (hash-table-p first) (hash-table-p second))
         (let ((result (copy-hash-table first)) (missing (make-symbol "missing")))
           (maphash (lambda (key value)
                      (let ((previous (gethash key result missing)))
                        (puthash key (if (eq previous missing) value
                                       (zr-data-merge-json previous value)) result))) second)
           result))
        ((and (vectorp first) (vectorp second)) (vconcat first second))
        (t second)))
(defun zr-data-merge-json-files (first second output)
  "Merge JSON files FIRST and SECOND and write OUTPUT."
  (interactive "fFirst JSON: \nfSecond JSON: \nFOutput: ")
  (let ((data (json-serialize (zr-data-merge-json (zr-data-read-json first) (zr-data-read-json second)))))
    (with-temp-file output (insert data "\n"))))
(defun zr-data-sops-decrypt (file)
  "Return decrypted FILE contents; signal errors on failed decryption."
  (unless (executable-find zr-data-sops-program) (user-error "SOPS is unavailable"))
  (with-temp-buffer
    (let ((status (process-file zr-data-sops-program nil (list t nil) nil "--decrypt" file)))
      (unless (eq status 0) (error "SOPS failed with status %s" status)))
    (buffer-string)))
(defun zr-data-sops-json (file)
  "Decrypt FILE with SOPS and parse its JSON."
  (json-parse-string (zr-data-sops-decrypt file)))
(defun zr-data-uuid (&optional object)
  "Return a UUID, deterministically derived from OBJECT when supplied."
  (interactive)
  (let ((id (if object
                (let ((hash (md5 (prin1-to-string object))))
                  (format "%s-%s-3%s-%x%s-%s" (substring hash 0 8) (substring hash 8 12)
                          (substring hash 13 16) (logior 8 (logand 3 (string-to-number (substring hash 16 17) 16)))
                          (substring hash 17 20) (substring hash 20 32)))
              (progn (require 'org-id) (let ((org-id-method 'uuid)) (org-id-new))))))
    (when (called-interactively-p 'interactive) (kill-new id) (message "%s" id))
    id))
(defun zr-data-generate-password (&optional insert)
  "Generate a password from cryptographic random bytes; copy it or INSERT it.
Requires OpenSSL.  There is deliberately no pseudorandom fallback."
  (interactive "P")
  (unless (and (> zr-data-password-length 0) (executable-find "openssl"))
    (user-error "A positive password length and OpenSSL are required"))
  (let ((password
         (with-temp-buffer
           (unless (eq 0 (call-process "openssl" nil t nil "rand" "-base64"
                                       (number-to-string zr-data-password-length)))
             (error "Password generation failed"))
           (substring (replace-regexp-in-string "[\r\n]" "" (buffer-string)) 0 zr-data-password-length))))
    (if insert (insert password) (kill-new password))
    password))
(provide 'zr-data)
;;; zr-data.el ends here
