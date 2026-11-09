;;; zr-nndoc-epub.el --- Read single EPUB files with nndoc -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Require this library, then use G f in the Gnus group buffer to open an
;; EPUB file.  The nndoc document type is guessed automatically.  Chapters,
;; images and footnotes use nnepub's parser and MIME renderer; no library
;; directory or separate reading command is needed.  Extracted resources
;; are removed when nndoc kills its document buffer on leaving the group.

;;; Code:

(require 'nndoc)
(require 'nnepub)

(declare-function gnus-summary-set-local-parameters "gnus-sum" (group))

(defvar-local zr-nndoc-epub--book nil
  "Parsed EPUB owned by this nndoc document buffer.")

(defvar-local zr-nndoc-epub--parameters nil
  "Temporary Gnus rendering parameters for this document's group.")

(defun nndoc-epub-type-p ()
  "Recognize an EPUB ZIP document in the current buffer."
  (and (looking-at "PK\003\004")
       (or (and (stringp nndoc-address)
                (let ((case-fold-search t))
                  (string-match-p "\\.epub\\'" nndoc-address)))
           (save-excursion (search-forward "application/epub+zip" nil t)))
       t))

(defun zr-nndoc-epub--cleanup ()
  "Remove this document's extracted resources and rendering parameters."
  (when zr-nndoc-epub--book
    (nnepub--dispose-book zr-nndoc-epub--book)
    (setq zr-nndoc-epub--book nil))
  (when zr-nndoc-epub--parameters
    (setq gnus-parameters (delete zr-nndoc-epub--parameters gnus-parameters)
          zr-nndoc-epub--parameters nil)))

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
         (book (nnepub--load-book file (nnepub--file-signature file)))
         success)
    (unwind-protect
        (progn
          (setq zr-nndoc-epub--book book)
          (add-hook 'kill-buffer-hook #'zr-nndoc-epub--cleanup nil t)
          ;; The custom generator reads extracted resources rather than
          ;; offsets into the ZIP buffer.  nndoc only needs article keys
          ;; and reverses the dissection result into reading order.
          (setq nndoc-dissection-alist
                (mapcar (lambda (chapter)
                          (list (plist-get chapter :number) nil nil nil nil 0))
                        (reverse (nnepub--book-chapters book))))
          (setq zr-nndoc-epub--parameters
                (list (concat "\\`" (regexp-quote (zr-nndoc-epub--group)) "\\'")
                      '(mm-text-html-renderer 'nnepub--render-html)
                      '(gnus-show-threads nil)
                      '(gnus-article-sort-functions '(gnus-article-sort-by-number))
                      '(gnus-thread-sort-functions '(gnus-thread-sort-by-number))))
          (add-to-list 'gnus-parameters zr-nndoc-epub--parameters)
          ;; A newly opened nndoc file can be parsed after Gnus has
          ;; initialized its summary.  Apply the parameters there too.
          (when-let* ((summary (gnus-buffer-live-p gnus-summary-buffer)))
            (with-current-buffer summary
              (when (equal gnus-newsgroup-name (zr-nndoc-epub--group))
                (gnus-summary-set-local-parameters gnus-newsgroup-name))))
          (setq success t))
      (unless success
        (setq nndoc-dissection-alist nil)
        (zr-nndoc-epub--cleanup)))))

(defun zr-nndoc-epub--generate-head (article)
  "Insert the message headers for EPUB ARTICLE into the current buffer."
  (let ((book (buffer-local-value 'zr-nndoc-epub--book nndoc-current-buffer)))
    (insert (nnepub--article-head book (nnepub--chapter book article)))))

(defun zr-nndoc-epub--generate-article (article)
  "Insert EPUB ARTICLE as a MIME message into the current buffer."
  (let ((book (buffer-local-value 'zr-nndoc-epub--book nndoc-current-buffer)))
    (insert (nnepub--mime book (nnepub--chapter book article)
                          (zr-nndoc-epub--group) t)))
  t)

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
