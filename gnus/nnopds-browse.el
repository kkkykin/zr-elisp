;;; nnopds-browse.el --- Browse OPDS directories with Gnus -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Navigation and pagination load one OPDS page at a time.  Publications
;; use Gnus groups for subscriptions, reading and local article marks.

;;; Code:

(require 'nnopds)
(require 'gnus-srvr)

(defvar-local nnopds-browse--method nil)
(defvar-local nnopds-browse--url nil)
(defvar-local nnopds-browse--page nil)
(defvar-local nnopds-browse--history nil)

(defvar-keymap nnopds-browse-mode-map
  :parent gnus-browse-mode-map
  "RET" #'nnopds-browse-select
  "=" #'nnopds-browse-select
  "SPC" #'nnopds-browse-read
  "u" #'nnopds-browse-subscribe
  "g" #'nnopds-browse-refresh
  "b" #'nnopds-browse-up
  "^" #'nnopds-browse-up
  "DEL" #'nnopds-browse-up
  "n" #'nnopds-browse-next
  "p" #'nnopds-browse-previous
  "q" #'gnus-browse-exit)

(easy-menu-define nnopds-browse-menu nnopds-browse-mode-map
  "OPDS browsing commands."
  '("Browse"
    ["Enter" nnopds-browse-select t]
    ["Read book" nnopds-browse-read t]
    ["Toggle subscription" nnopds-browse-subscribe t]
    ["Back" nnopds-browse-up nnopds-browse--history]
    ["Refresh page" nnopds-browse-refresh t]
    ["Quit" gnus-browse-exit t]))

(define-derived-mode nnopds-browse-mode gnus-browse-mode "OPDS"
  "Browse OPDS directories while retaining Gnus book subscriptions.
\\<nnopds-browse-mode-map>
\\[nnopds-browse-select] enters a directory or selects a book.
\\[nnopds-browse-read] reads a book, \\[nnopds-browse-subscribe] toggles its subscription.
\\[nnopds-browse-up] goes back and \\[nnopds-browse-refresh] refreshes this page."
  (setq-local revert-buffer-function (lambda (&rest _args) (nnopds-browse-refresh))))

(defun nnopds-browse--title (page)
  "Return the display title of PAGE."
  (let ((title (nnepub--header-text (plist-get (plist-get (plist-get page :feed) :metadata) :title))))
    (if (string-empty-p title) "OPDS" title)))

(defun nnopds-browse--link (link base &optional title)
  "Insert a navigable LINK at BASE, optionally displaying TITLE."
  (when (and (not (eq t (plist-get link :templated)))
             (plist-get link :href)
             (member (nnopds--media-type link) '("" "application/opds+json")))
    (let* ((url (nnopds--url (plist-get link :href) base))
           (label (nnepub--header-text (or title (plist-get link :title) url)))
           (start (point)))
      (insert "  " label "\n")
      (add-text-properties start (point) (list 'nnopds-browse-link url 'face 'font-lock-type-face)))))

(defun nnopds-browse--book (entry)
  "Insert publication ENTRY with its Gnus subscription state."
  (let* ((group (nnopds--publication-group entry))
         (name (gnus-group-prefixed-name group nnopds-browse--method))
         (count (or (nnopds--publication-count entry) 1))
         (start (point)))
    (gnus-set-active name (cons 1 count))
    (insert (format "%c%7d: %s\n"
                    (if (<= (gnus-group-level name) gnus-level-subscribed) ?\s ?U)
                    count (nnopds--publication-title entry)))
    (add-text-properties start (point) (list 'gnus-group group 'nnopds-browse-book entry))))

(defun nnopds-browse--render (page)
  "Display PAGE's embedded groups, navigation and publications."
  (let ((inhibit-read-only t)
        (base (plist-get page :url))
        (entries (plist-get page :entries))
        (feed (plist-get page :feed)))
    (erase-buffer)
    (insert (propertize (concat "OPDS — " (nnopds-browse--title page) "\n") 'face 'bold))
    (when nnopds-browse--history
      (insert (mapconcat #'cadr (reverse nnopds-browse--history) " / ") " / " (nnopds-browse--title page) "\n"))
    (insert "RET enter   SPC read   u subscribe   b back   g refresh   q quit\n\n")
    (cl-labels
        ((collection (document root)
           (unless root
             (insert (propertize (concat (nnepub--header-text (plist-get (plist-get document :metadata) :title)) "\n")
                                 'face 'bold)))
           (seq-doseq (link (plist-get document :navigation)) (nnopds-browse--link link base))
           (seq-doseq (publication (plist-get document :publications))
             (when-let* ((entry (gethash publication entries))) (nnopds-browse--book entry)))
           (unless root
             (seq-doseq (link (plist-get document :links))
               (when (nnopds--rel-p link "self") (nnopds-browse--link link base "More…"))))
           (seq-doseq (facet (plist-get document :facets))
             (insert (nnepub--header-text (plist-get (plist-get facet :metadata) :title)) "\n")
             (seq-doseq (link (plist-get facet :links)) (nnopds-browse--link link base)))
           (seq-doseq (group (plist-get document :groups))
             (insert "\n") (collection group nil))))
      (collection feed t))
    (seq-doseq (link (plist-get feed :links))
      (when-let* ((relation (cl-find-if (lambda (rel) (nnopds--rel-p link rel)) '("next" "previous" "prev" "first" "last"))))
        (nnopds-browse--link link base (pcase relation
                                         ("next" "Next page")
                                         ((or "previous" "prev") "Previous page")
                                         ("first" "First page")
                                         ("last" "Last page")))))
    (goto-char (point-min))
    (while (and (not (eobp)) (not (nnopds-browse--entry-p))) (forward-line 1))
    (setq mode-line-buffer-identification (list "OPDS: " (nnopds-browse--title page)))))

(defun nnopds-browse--entry-p ()
  "Whether the current line is a directory or a book."
  (or (get-text-property (line-beginning-position) 'nnopds-browse-link)
      (get-text-property (line-beginning-position) 'nnopds-browse-book)))

(defun nnopds-browse--show (url history &optional force)
  "Load URL with HISTORY, optionally forcing revalidation.
Update the browser only after the requested page has loaded successfully."
  (unless (gnus-check-server nnopds-browse--method) (user-error "OPDS server unavailable"))
  (let* ((connection (nnopds--change-server (cadr nnopds-browse--method)))
         (page (nnopds--catalog-page connection url force)))
    (setq nnopds-browse--url url nnopds-browse--page page nnopds-browse--history history)
    (setq gnus-browse-current-method nnopds-browse--method)
    (nnopds-browse--render page)))

(defun nnopds-browse (server &optional return-buffer)
  "Browse OPDS SERVER's root directory, returning to RETURN-BUFFER on exit."
  (interactive
   (list (list 'nnopds (completing-read "OPDS server: " (nnopds--servers) nil t))))
  (let ((method (gnus-server-to-method server)))
    (unless (eq (car-safe method) 'nnopds) (user-error "Not an OPDS server"))
    (unless (gnus-check-server method) (user-error "OPDS server unavailable"))
    (let* ((connection (nnopds--change-server (cadr method)))
           (url (nnopds--connection-url connection))
           (page (nnopds--catalog-page connection url)))
      (setq gnus-browse-current-method method gnus-browse-return-buffer return-buffer)
      (with-current-buffer (get-buffer-create gnus-browse-buffer)
        (nnopds-browse-mode)
        (setq nnopds-browse--method method nnopds-browse--url url nnopds-browse--page page)
        (nnopds-browse--render page))
      (gnus-configure-windows 'browse)
      (switch-to-buffer gnus-browse-buffer)
      t)))

(defun nnopds-browse--activate (read)
  "Enter the selected directory or book, displaying an article with READ."
  (if-let* ((url (get-text-property (line-beginning-position) 'nnopds-browse-link)))
      (nnopds-browse--show url (cons (list nnopds-browse--url (nnopds-browse--title nnopds-browse--page) (point))
                                     nnopds-browse--history))
    (unless (get-text-property (line-beginning-position) 'nnopds-browse-book) (user-error "No directory or book here"))
    (setq gnus-browse-current-method nnopds-browse--method)
    ;; The catalog only knows a placeholder article count until the EPUB is
    ;; opened.  Update Gnus's range before it chooses which headers to fetch.
    (unless (gnus-activate-group (gnus-browse-group-name))
      (user-error "Could not open OPDS book: %s" (gnus-status-message nnopds-browse--method)))
    (if read
        (progn
          (gnus-browse-read-group)
          (with-current-buffer gnus-summary-buffer
            (unless gnus-current-article
              (gnus-summary-display-article (gnus-summary-article-number)))))
      (gnus-browse-select-group))))

(defun nnopds-browse-select ()
  "Enter the directory or select the book at point."
  (interactive nil nnopds-browse-mode)
  (nnopds-browse--activate nil))

(defun nnopds-browse-read ()
  "Enter the directory or read the book at point."
  (interactive nil nnopds-browse-mode)
  (nnopds-browse--activate t))

(defun nnopds-browse-subscribe ()
  "Toggle the selected book's Gnus subscription."
  (interactive nil nnopds-browse-mode)
  (unless (get-text-property (line-beginning-position) 'nnopds-browse-book) (user-error "Select a book to subscribe"))
  (let ((position (point)))
    (gnus-browse-toggle-subscription-at-point 1)
    (nnopds-browse--render nnopds-browse--page)
    (goto-char (min position (point-max)))))

(defun nnopds-browse-up ()
  "Return to the previous directory or page."
  (interactive nil nnopds-browse-mode)
  (unless nnopds-browse--history (user-error "Already at the root directory"))
  (let ((previous (car nnopds-browse--history)))
    (nnopds-browse--show (car previous) (cdr nnopds-browse--history))
    (goto-char (min (nth 2 previous) (point-max)))))

(defun nnopds-browse-refresh ()
  "Revalidate the current page without following its links."
  (interactive nil nnopds-browse-mode)
  (nnopds-browse--show nnopds-browse--url nnopds-browse--history t))

(defun nnopds-browse-next (&optional n)
  "Move to the next N directory or book rows."
  (interactive "p" nnopds-browse-mode)
  (let* ((n (or n 1)) (step (if (< n 0) -1 1)))
    (dotimes (_ (abs n))
      (when (zerop (forward-line step))
        (while (and (not (nnopds-browse--entry-p)) (zerop (forward-line step))))))))

(defun nnopds-browse-previous (&optional n)
  "Move to the previous N directory or book rows."
  (interactive "p" nnopds-browse-mode)
  (nnopds-browse-next (- (or n 1))))

(defun nnopds-browse--group-name (original)
  "Return only book group names in OPDS buffers, using ORIGINAL elsewhere."
  (if (derived-mode-p 'nnopds-browse-mode)
      (when-let* ((group (get-text-property (line-beginning-position) 'gnus-group)))
        (concat (gnus-method-to-server-name nnopds-browse--method) ":" group))
    (funcall original)))

(advice-add 'gnus-browse-group-name :around #'nnopds-browse--group-name)

(provide 'nnopds-browse)
;;; nnopds-browse.el ends here
