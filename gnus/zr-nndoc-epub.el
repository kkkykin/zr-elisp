;;; zr-nndoc-epub.el --- Read single EPUB files with nndoc -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Require this library, then use G f in the Gnus group buffer to open an
;; EPUB file.  The nndoc document type is guessed automatically.  Chapters,
;; images and footnotes use the shared EPUB parser and MIME renderer; no library
;; directory or separate reading command is needed.  Extracted resources
;; are removed when nndoc kills its document buffer on leaving the group.

;;; Code:

(require 'nndoc)
(require 'zr-gnus-epub)

(declare-function gnus-summary-set-local-parameters "gnus-sum" (group))

(defvar-local zr-nndoc-epub--book nil
  "Parsed EPUB owned by this nndoc document buffer.")

(defvar-local zr-nndoc-epub--identity nil
  "Identity used in the document's chapter Message-IDs.")

(defun nndoc-epub-type-p ()
  "Recognize an EPUB ZIP document in the current buffer."
  (and (looking-at "PK\003\004")
       (or (and (stringp nndoc-address)
                (let ((case-fold-search t))
                  (string-match-p "\\.epub\\'" nndoc-address)))
           (save-excursion (search-forward "application/epub+zip" nil t)))
       t))

(defun zr-nndoc-epub--cleanup ()
  "Remove this document's extracted resources."
  (when zr-nndoc-epub--book
    (zr-epub-close zr-nndoc-epub--book)
    (setq zr-nndoc-epub--book nil zr-nndoc-epub--identity nil)))

(defun zr-nndoc-epub--group ()
  "Return the prefixed group name of the current nndoc document."
  (gnus-group-prefixed-name
   (car (rassq nndoc-current-buffer nndoc-group-alist))
   (list 'nndoc (nnoo-current-server 'nndoc))))

(defun zr-nndoc-epub--dissect ()
  "Parse the EPUB file and index its spine for nndoc."
  (unless (and (stringp nndoc-address) (not (file-remote-p nndoc-address)))
    (error "EPUB documents must be local files"))
  (zr-nndoc-epub--cleanup)
  (let* ((file (file-truename nndoc-address))
         (identity (concat "book." (secure-hash 'sha256 file) "." (zr-epub-file-digest file)))
         (book (zr-epub-open file))
         success)
    (unwind-protect
        (progn
          (setq zr-nndoc-epub--book book zr-nndoc-epub--identity identity)
          (add-hook 'kill-buffer-hook #'zr-nndoc-epub--cleanup nil t)
          ;; The custom generator reads extracted resources rather than
          ;; offsets into the ZIP buffer.  nndoc only needs article keys
          ;; and reverses the dissection result into reading order.
          (setq nndoc-dissection-alist
                (mapcar (lambda (chapter)
                          (list (plist-get chapter :number) nil nil nil nil 0))
                        (reverse (zr-epub-book-chapters book))))
          (setq success t))
      (unless success
        (setq nndoc-dissection-alist nil)
        (zr-nndoc-epub--cleanup)))))

(defun zr-nndoc-epub--generate-head (article)
  "Insert the message headers for EPUB ARTICLE into the current buffer."
  (let ((book (buffer-local-value 'zr-nndoc-epub--book nndoc-current-buffer))
        (identity (buffer-local-value 'zr-nndoc-epub--identity nndoc-current-buffer)))
    (insert (zr-gnus-epub-article-head (zr-gnus-epub-header book (zr-epub-chapter book article) identity)))))

(defun zr-nndoc-epub--generate-article (article)
  "Insert EPUB ARTICLE as a MIME message into the current buffer."
  (let* ((book (buffer-local-value 'zr-nndoc-epub--book nndoc-current-buffer))
         (identity (buffer-local-value 'zr-nndoc-epub--identity nndoc-current-buffer))
         (chapter (zr-epub-chapter book article)))
    (insert (zr-gnus-epub-article book chapter (zr-nndoc-epub--group)
                                 (zr-gnus-epub-header book chapter identity))))
  t)

(defun zr-nndoc-epub--prepare-summary ()
  "Enable chapter order and link rendering for EPUB documents only."
  (when (and (eq (car gnus-current-select-method) 'nndoc)
             (buffer-live-p nndoc-current-buffer)
             (buffer-local-value 'zr-nndoc-epub--book nndoc-current-buffer)
             (equal gnus-newsgroup-name (zr-nndoc-epub--group)))
    (zr-gnus-epub-summary-defaults)
    (zr-gnus-epub-prepare-summary)))

(add-hook 'gnus-select-group-hook #'zr-nndoc-epub--prepare-summary)

;; Preserve ZIP bytes when nndoc opens an EPUB.  Its text-document hook
;; would otherwise remove carriage returns before type detection.
(let ((epub "\\.[eE][pP][uU][bB]\\'"))
  (unless (string-match-p (regexp-quote epub) nndoc-binary-file-names)
    (setq nndoc-binary-file-names
          (concat "\\(?:" nndoc-binary-file-names "\\|" epub "\\)"))))

(nndoc-add-type
 '(epub
   (dissection-function . zr-nndoc-epub--dissect)
   (generate-head-function . zr-nndoc-epub--generate-head)
   (generate-article-function . zr-nndoc-epub--generate-article))
 'first)

(provide 'zr-nndoc-epub)
;;; zr-nndoc-epub.el ends here
