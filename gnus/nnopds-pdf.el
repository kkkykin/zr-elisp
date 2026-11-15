;;; nnopds-pdf.el --- Read downloaded PDFs in Gnus with mutool -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Download a PDF before creating its page articles.  MuPDF supplies effective
;; page bounds and renders only the active reader's pages and bounded neighbors.
;; Page images are cached in resolution tiers; navigation and reading positions
;; are shared with the Divina reader through nnopds-paged.

;;; Code:

(require 'nnopds-paged)

(defgroup nnopds-pdf nil "PDF publications in Gnus." :group 'nnopds)

(defcustom nnopds-pdf-mutool-program "mutool"
  "MuPDF executable used for PDF inspection and rendering.
The executable must provide the run and draw commands."
  :type 'string :group 'nnopds-pdf)

(defconst nnopds-pdf--info-script
  "var doc = Document.openDocument(scriptArgs[0]);
if (!doc.isPDF()) throw new Error('Not a PDF document');
if (doc.needsPassword()) throw new Error('PDF requires a password');
var sizes = [];
for (var i = 0, n = doc.countPages(); i < n; ++i) {
    var page = doc.loadPage(i);
    var box = page.getBounds ? page.getBounds() : page.bound();
    sizes.push([box[2] - box[0], box[3] - box[1]]);
    if ((i + 1) % 32 === 0) gc();
}
print(JSON.stringify(sizes));
"
  "MuPDF script returning page sizes after crop, rotation and UserUnit.
MuPDF renamed Page.bound to Page.getBounds; both executable APIs are accepted.")

(defun nnopds-pdf--program ()
  "Return the configured MuPDF executable or report a missing dependency."
  (or (executable-find nnopds-pdf-mutool-program)
      (error "Install mutool or set nnopds-pdf-mutool-program")))

(defun nnopds-pdf--inspect (program file)
  "Return PROGRAM's effective PDF page sizes for FILE."
  (let ((script (make-temp-file "nnopds-pdf-" nil ".js"))
        (errors (make-temp-file "nnopds-pdf-"))
        (coding-system-for-read 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file script (insert nnopds-pdf--info-script))
          (with-temp-buffer
            (unless (eq 0 (call-process program nil (list t errors) nil "run" script file))
              (error "mutool could not open PDF: %s"
                     (string-trim (nnopds--read-bytes errors))))
            (goto-char (point-min))
            (json-parse-buffer :array-type 'array)))
      (delete-file script)
      (delete-file errors))))

(defun nnopds-pdf--valid-sizes-p (sizes)
  "Whether SIZES is a nonempty vector of positive PDF page dimensions."
  (and (vectorp sizes) (> (length sizes) 0)
       (seq-every-p
        (lambda (size)
          (and (vectorp size) (= (length size) 2)
               (numberp (aref size 0)) (> (aref size 0) 0)
               (numberp (aref size 1)) (> (aref size 1) 0)))
        sizes)))

(defun nnopds-pdf--fingerprint (file)
  "Validate FILE's PDF signature and return its SHA-256 fingerprint."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (unless (string-match-p "%PDF-[12]\\.[0-9]"
                            (buffer-substring-no-properties (point-min) (min (point-max) 1025)))
      (error "Downloaded content is not a PDF"))
    (secure-hash 'sha256 (current-buffer))))

(cl-defmethod nnopds--load-publication ((_format (eql pdf)) connection publication)
  (let* ((program (nnopds-pdf--program))
         (directory (nnopds--cache-file
                     connection
                     (concat (secure-hash 'sha256 (nnopds--publication-group publication)) ".pdf/")))
         (file (expand-file-name "book.pdf" directory))
         (index-file (expand-file-name "index.json" directory))
         (index (nnopds--read-json index-file))
         (temporary (unless (file-readable-p file) (nnopds--temporary-file file)))
         digest sizes)
    (unwind-protect
        (progn
          (when temporary
            (message "nnopds: Downloading %s..." (nnopds--publication-title publication))
            (let ((response (nnopds--request
                             connection "GET" (nnopds--publication-acquisition publication) nil nil
                             '(("Accept" . "application/pdf, application/octet-stream;q=0.9, */*;q=0.1"))
                             nil temporary)))
              (unless (= (plist-get response :status) 200)
                (error "PDF download: HTTP %s" (plist-get response :status)))))
          (setq digest (nnopds-pdf--fingerprint (or temporary file)))
          (when (and (plist-get index :digest) (not (equal digest (plist-get index :digest))))
            (error "PDF content changed within the same OPDS version"))
          (setq sizes (if (and (equal digest (plist-get index :digest))
                               (nnopds-pdf--valid-sizes-p (plist-get index :sizes)))
                          (plist-get index :sizes)
                        (nnopds-pdf--inspect program (or temporary file))))
          (unless (nnopds-pdf--valid-sizes-p sizes) (error "PDF has no valid pages"))
          ;; Commit the complete, verified download before page rendering.
          (unless (equal index (list :digest digest :sizes sizes))
            (nnopds--write-json index-file (list :digest digest :sizes sizes)))
          (when temporary (rename-file temporary file t))
          (nnopds-paged--open-book
           'pdf connection publication
           (vconcat
            (seq-map-indexed
             (lambda (size index)
               (list :number (1+ index) :title (format "Page %d" (1+ index))
                     :href (nnopds--publication-acquisition publication) :type "application/pdf"
                     :width (aref size 0) :height (aref size 1) :measured t :image-type 'png))
             sizes))
           directory
           :progression (if (equal (plist-get (plist-get (nnopds--publication-document publication) :metadata)
                                              :readingProgression) "rtl") 'rtl 'ltr)
           :source-data (list :file file :digest digest :program program)))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(defun nnopds-pdf--render-width (width)
  "Round requested pixel WIDTH up to a power-of-two cache tier."
  (max 256 (expt 2 (ceiling (log (max 1 width) 2)))))

(cl-defmethod nnopds-paged--file ((_source (eql pdf)) book page width)
  (expand-file-name
   (format "%d-%d.png" (plist-get page :number) (nnopds-pdf--render-width width))
   (nnopds-paged--book-directory book)))

(cl-defmethod nnopds-paged--fetch ((_source (eql pdf)) book page width temporary callback)
  (let* ((data (nnopds-paged--book-source-data book))
         (output (generate-new-buffer " *nnopds-pdf-render*"))
         process)
    (unwind-protect
        (setq process
              (make-process
               :name "nnopds-pdf-render" :buffer output :noquery t :connection-type 'pipe
               :coding 'utf-8-unix
               :command (list (plist-get data :program) "draw" "-q" "-F" "png" "-c" "rgb"
                              "-w" (number-to-string (nnopds-pdf--render-width width))
                              "-o" temporary (plist-get data :file)
                              (number-to-string (plist-get page :number)))
               :sentinel
               (lambda (child _event)
                 (when (memq (process-status child) '(exit signal))
                   (unwind-protect
                       (funcall callback
                                (unless (and (eq (process-status child) 'exit)
                                             (= (process-exit-status child) 0))
                                  (format "mutool draw: %s"
                                          (with-current-buffer output
                                            (string-trim (buffer-string))))))
                     (when (buffer-live-p output) (kill-buffer output)))))))
      (unless process (kill-buffer output)))
    (lambda ()
      (when (process-live-p process) (delete-process process)))))

(provide 'nnopds-pdf)
;;; nnopds-pdf.el ends here
