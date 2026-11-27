;;; nnopds-mupdf.el --- Inspect and render downloaded books with MuPDF -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Download a PDF, CBZ or EPUB before creating its page articles.  MuPDF supplies
;; effective page bounds and renders the active reader's pages and neighbors.
;; Page images are cached in resolution tiers; navigation and reading positions
;; are shared with the Divina reader through nnopds-paged.

;;; Code:

(require 'nnopds-paged)

(defgroup nnopds-mupdf nil "MuPDF inspection and rendering for OPDS books." :group 'nnopds)

(defcustom nnopds-mupdf-program "mutool"
  "MuPDF executable used for document inspection and rendering.
The executable must provide the run and draw commands."
  :type 'string :group 'nnopds-mupdf)

(defconst nnopds-mupdf--epub-layout '("450" "600" "12")
  "EPUB page width, height and font size in points, for inspection and rendering.")

(defconst nnopds-mupdf--info-script
  "var doc = Document.openDocument(scriptArgs[0]);
if (doc.isPDF() !== (scriptArgs[1] === 'pdf')) throw new Error('Unexpected document type');
if (doc.needsPassword()) throw new Error('Document requires a password');
if (scriptArgs[1] === 'epub') doc.layout(+scriptArgs[2], +scriptArgs[3], +scriptArgs[4]);
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

(defun nnopds-mupdf--program ()
  "Return the configured MuPDF executable or report a missing dependency."
  (or (executable-find nnopds-mupdf-program)
      (error "Install mutool or set nnopds-mupdf-program")))

(defun nnopds-mupdf--inspect (program file format)
  "Return PROGRAM's effective page sizes for FILE in FORMAT."
  (let ((script (make-temp-file "nnopds-mupdf-" nil ".js"))
        (errors (make-temp-file "nnopds-mupdf-"))
        (coding-system-for-read 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file script (insert nnopds-mupdf--info-script))
          (with-temp-buffer
            (unless (eq 0 (apply #'call-process program nil (list t errors) nil
                                 "run" script file (symbol-name format)
                                 (when (eq format 'epub) nnopds-mupdf--epub-layout)))
              (error "mutool could not open %s: %s" (upcase (symbol-name format))
                     (string-trim (nnopds--read-bytes errors))))
            (goto-char (point-min))
            (json-parse-buffer :array-type 'array)))
      (delete-file script)
      (delete-file errors))))

(defun nnopds-mupdf--valid-sizes-p (sizes)
  "Whether SIZES is a nonempty vector of positive page dimensions."
  (and (vectorp sizes) (> (length sizes) 0)
       (seq-every-p
        (lambda (size)
          (and (vectorp size) (= (length size) 2)
               (numberp (aref size 0)) (> (aref size 0) 0)
               (numberp (aref size 1)) (> (aref size 1) 0)))
        sizes)))

(defun nnopds-mupdf--pdf-fingerprint (file)
  "Validate FILE's PDF signature and return its SHA-256 fingerprint."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (unless (string-match-p "%PDF-[12]\\.[0-9]"
                            (buffer-substring-no-properties (point-min) (min (point-max) 1025)))
      (error "Downloaded content is not a PDF"))
    (secure-hash 'sha256 (current-buffer))))

(defun nnopds-mupdf--index (file format program index-file digest)
  "Return FILE's page index, using PROGRAM for FORMAT and DIGEST."
  (let* ((index (nnopds--read-json index-file))
         (old-digest (plist-get index :digest))
         (sizes (plist-get index :sizes))
         (label (upcase (symbol-name format))))
    (when (and old-digest (not (equal old-digest digest)))
      (error "%s content changed within the same OPDS version" label))
    (unless (and old-digest (nnopds-mupdf--valid-sizes-p sizes))
      (setq sizes (nnopds-mupdf--inspect program file format))
      (unless (nnopds-mupdf--valid-sizes-p sizes) (error "%s has no valid pages" label))
      (setq index (list :digest digest :sizes sizes))
      (nnopds--write-json index-file index))
    index))

(defun nnopds-mupdf--cache-document (connection publication file program)
  "Cache PUBLICATION in FILE on CONNECTION and return its MuPDF page index."
  (let ((format (nnopds--publication-format publication))
        (index-file (expand-file-name "index.json" (file-name-directory file))))
    (nnopds--ensure-download
     connection publication file
     (lambda (candidate)
       (nnopds-mupdf--index candidate format program index-file
                            (if (eq format 'pdf) (nnopds-mupdf--pdf-fingerprint candidate)
                              (zr-epub-file-digest candidate)))))))

(defun nnopds-mupdf--load (connection publication)
  "Prepare page articles for a downloaded PUBLICATION on CONNECTION."
  (let* ((program (nnopds-mupdf--program))
         (file (nnopds--download-file connection publication))
         (format (nnopds--publication-format publication))
         (directory (nnopds-paged--directory connection publication))
         (images (if (eq format 'epub) directory (file-name-directory file)))
         (index (if (eq format 'epub)
                    (nnopds-mupdf--index file format program (expand-file-name "index.json" images)
                                         (plist-get (nnopds--cache-epub connection publication file) :digest))
                  (nnopds-mupdf--cache-document connection publication file program)))
         (media-type (car (alist-get format nnopds--formats))))
    (nnopds-paged--open-book
     'mupdf connection publication
     (vconcat
      (seq-map-indexed
       (lambda (size index)
         (list :number (1+ index) :title (format "Page %d" (1+ index))
               :href (nnopds--publication-acquisition publication) :type media-type
               :width (aref size 0) :height (aref size 1) :measured t :image-type 'png))
       (plist-get index :sizes)))
     directory
     :progression (or (when (nnopds--publication-stream publication)
                        (nnopds-paged--reading-progression
                         (plist-get (nnopds--read-json (expand-file-name "manifest.json" directory)) :manifest)))
                      (nnopds-paged--reading-progression (nnopds--publication-document publication))
                      'ltr)
     :source-data (list :file file :digest (plist-get index :digest) :program program :directory images))))

(defun nnopds-mupdf--render-width (width)
  "Round requested pixel WIDTH up to a power-of-two cache tier."
  (max 256 (expt 2 (ceiling (log (max 1 width) 2)))))

(cl-defmethod nnopds-paged--file ((_source (eql mupdf)) book page width)
  (expand-file-name
   (format "%d-%d.png" (plist-get page :number) (nnopds-mupdf--render-width width))
   (plist-get (nnopds-paged--book-source-data book) :directory)))

(cl-defmethod nnopds-paged--fetch ((_source (eql mupdf)) book page width temporary callback)
  (let* ((data (nnopds-paged--book-source-data book))
         (output (generate-new-buffer " *nnopds-mupdf-render*"))
         process)
    (unwind-protect
        (setq process
              (make-process
               :name "nnopds-mupdf-render" :buffer output :noquery t :connection-type 'pipe
               :coding 'utf-8-unix
               :command (append (list (plist-get data :program) "draw" "-q" "-F" "png" "-c" "rgb"
                                      "-w" (number-to-string (nnopds-mupdf--render-width width)) "-o" temporary)
                                (when (eq (nnopds--publication-format (nnopds-paged--book-publication book)) 'epub)
                                  (cl-mapcan #'list '("-W" "-H" "-S") nnopds-mupdf--epub-layout))
                                (list (plist-get data :file) (number-to-string (plist-get page :number))))
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

(provide 'nnopds-mupdf)
;;; nnopds-mupdf.el ends here
