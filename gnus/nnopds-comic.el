;;; nnopds-comic.el --- Stream Divina comics in Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Divina manifests provide original page order and image links.  Images are
;; downloaded only for an active nnopds-paged reader, sharing its navigation,
;; layouts, request queue and local reading position.

;;; Code:

(require 'nnopds-paged)

(defconst nnopds-comic--image-types
  '(("image/jpeg" . jpeg) ("image/png" . png) ("image/gif" . gif)
    ("image/webp" . webp) ("image/avif" . avif) ("image/jxl" . jpeg-xl)
    ("image/svg+xml" . svg) ("image/tiff" . tiff) ("image/bmp" . bmp)))

(defun nnopds-comic--link (resource base)
  "Choose RESOURCE's supported image representation and resolve it at BASE."
  (let* ((links (cons resource (append (plist-get resource :alternate) nil)))
         (link (or (cl-find-if
                    (lambda (candidate)
                      (when-let* ((type (cdr (assoc (nnopds--media-type candidate)
                                                    nnopds-comic--image-types))))
                        (image-type-available-p type))) links)
                   ;; A terminal can still browse and cache a manifest.
                   (cl-find-if (lambda (candidate)
                                 (member (nnopds--media-type candidate)
                                         '("image/jpeg" "image/png" "image/gif" "image/webp"))) links)
                   resource))
         (type (nnopds--media-type link)))
    (unless (string-prefix-p "image/" type)
      (error "Divina reading order contains a non-image resource"))
    (list :href (nnopds--url (plist-get link :href) base) :type type :measured nil
          :image-type (cdr (assoc type nnopds-comic--image-types))
          :width (plist-get resource :width) :height (plist-get resource :height))))

(cl-defmethod nnopds--load-publication ((_format (eql comic)) connection publication)
  (let* ((directory (nnopds--cache-file
                     connection
                     (concat (secure-hash 'sha256 (nnopds--publication-group publication)) ".comic/")))
         (manifest-file (expand-file-name "manifest.json" directory))
         (cached (nnopds--read-json manifest-file))
         (response (unless cached
                     (nnopds--request
                      connection "GET" (nnopds--publication-acquisition publication) nil nil
                      '(("Accept" . "application/divina+json, application/opds-publication+json;q=0.9, application/webpub+json;q=0.8")))))
         (manifest (if cached (plist-get cached :manifest) (nnopds--json response)))
         (base (or (and cached (plist-get cached :url)) (plist-get response :url)
                   (nnopds--publication-acquisition publication)))
         (pages (vconcat
                 (seq-map-indexed
                  (lambda (resource index)
                    (append (list :number (1+ index) :title (format "Page %d" (1+ index)))
                            (nnopds-comic--link resource base)))
                  (plist-get manifest :readingOrder)))))
    (unless (and (plist-get manifest :metadata) (> (length pages) 0))
      (error "Not a Divina comic manifest with page images"))
    (unless cached (nnopds--write-json manifest-file (list :url base :manifest manifest)))
    (nnopds-paged--open-book
     'comic connection publication pages directory
     :progression (if (equal (plist-get (plist-get manifest :metadata) :readingProgression) "rtl") 'rtl 'ltr)
     :cover nnopds-paged-cover-single :landscape nnopds-paged-landscape-single)))

(cl-defmethod nnopds-paged--file ((_source (eql comic)) book page _width)
  (expand-file-name (secure-hash 'sha256 (plist-get page :href))
                    (nnopds-paged--book-directory book)))

(cl-defmethod nnopds-paged--fetch ((_source (eql comic)) book page _width temporary callback)
  (let ((state (nnopds--request
                (nnopds-paged--book-connection book) "GET" (plist-get page :href) nil
                (lambda (response failure)
                  (funcall callback
                           (or failure
                               (unless (= (plist-get response :status) 200)
                                 (format "HTTP %s" (plist-get response :status))))))
                (list (cons "Accept" (concat (plist-get page :type) ", application/octet-stream;q=0.5")))
                nil temporary)))
    (lambda ()
      (when-let* ((request (nnopds--request-state-request state)))
        (zr-http-cancel request)))))

(provide 'nnopds-comic)
;;; nnopds-comic.el ends here
