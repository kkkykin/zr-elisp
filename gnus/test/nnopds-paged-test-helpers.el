;;; nnopds-paged-test-helpers.el --- Page reader test helpers -*- lexical-binding: t; -*-

;;; Code:

(require 'nnopds-test-helpers
         (expand-file-name "nnopds-test-helpers.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'nnopds-paged)

(defmacro nnopds-paged-test--with-images (&rest body)
  "Run BODY with image display operations emulated on nox Emacs.
Only the native decoder and frame capabilities are substituted.  Images
are real PNGs downloaded or rendered by mutool, and insert-image, Gnus,
the job queue, cache files, properties and reading events remain real."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'display-images-p) (lambda (&rest _args) t))
             ((symbol-function 'image-type-available-p) (lambda (type) (memq type '(png jpeg gif))))
             ((symbol-function 'create-image)
              (lambda (file &optional type _data-p &rest properties)
                (unless (file-readable-p file) (error "Image file is missing"))
                (append (list 'image :type type :file file) properties)))
             ((symbol-function 'image-size)
              (lambda (image &rest _args)
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally (plist-get (cdr image) :file) nil 0 24)
                  (let ((bytes (buffer-string)))
                    (unless (string-prefix-p "\211PNG\r\n\032\n" bytes) (error "Not a PNG"))
                    (cl-flet ((uint (offset)
                                (+ (ash (aref bytes offset) 24) (ash (aref bytes (+ offset 1)) 16)
                                   (ash (aref bytes (+ offset 2)) 8) (aref bytes (+ offset 3)))))
                      (cons (uint 16) (uint 20)))))))
             ((symbol-function 'image-flush) (lambda (&rest _args)))
             ((symbol-function 'nnopds-paged--viewport) (lambda () '(600 . 800))))
     ,@body))

(defun nnopds-paged-test--shown ()
  "Return the original page numbers in on-screen image order."
  (with-current-buffer gnus-article-buffer
    (let ((position (point-min)) pages)
      (while (< position (point-max))
        (when-let* ((number (get-text-property position 'nnopds-paged-page))) (push number pages))
        (setq position (next-single-property-change position 'nnopds-paged-page nil (point-max))))
      (nreverse pages))))

(defun nnopds-paged-test--settled (reader &optional position)
  "Wait for READER's image queue, optionally requiring committed POSITION."
  (let ((book (nnopds-paged--reader-book reader)))
    (condition-case nil
        (nnopds-test--wait
         (lambda ()
           (and (zerop (hash-table-count (nnopds-paged--book-active book)))
                (null (nnopds-paged--book-queue book))
                (or (null position) (eq position (nnopds-paged--book-position book))))))
      (error (ert-fail (format "Reader did not settle: page=%S queue=%S errors=%S live=%S"
                               (nnopds-paged--book-position book) (nnopds-paged--book-queue book)
                               (nnopds-paged--book-errors book) (nnopds-paged--live-p reader)))))))

(provide 'nnopds-paged-test-helpers)
;;; nnopds-paged-test-helpers.el ends here
