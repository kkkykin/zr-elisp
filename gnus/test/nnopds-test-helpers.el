;;; nnopds-test-helpers.el --- Shared OPDS test fixtures -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nnopds)
(require 'nnopds-progress)
(require 'nnopds-koreader)
(require 'nnopds-browse)
(require 'gnus-cache)
(require 'zr-test-helpers)

(defconst nnopds-test--directory (file-name-directory (or load-file-name buffer-file-name)))
(defconst nnopds-test--load-path (file-name-directory (directory-file-name nnopds-test--directory)))
(defvar nnopds-test--server-definitions nil)

(defun nnopds-test--wait (predicate)
  "Wait up to ten seconds for PREDICATE, yielding process output."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro nnopds-test--with-server (&rest body)
  "Run BODY with a local OPDS server, connection and isolated cache."
  (declare (indent 0) (debug t))
  `(progn
     (unless (and (executable-find "python3") (executable-find "curl"))
       (ert-skip "Requires Python and curl"))
     (zr-test-with-temp-directory
       (let* ((opds-root default-directory)
              (output (generate-new-buffer " *opds-test-http*"))
              (process (make-process :name "opds-test-server" :buffer output :noquery t
                                     :command (list "python3" (expand-file-name "opds-server.py" nnopds-test--directory)
                                                    opds-root)))
              (nnoo-state-alist (copy-tree nnoo-state-alist))
              (nnoo-definition-alist (copy-tree nnoo-definition-alist))
              (nnopds-url nil) (nnopds-address nil) (nnopds-user nil) (nnopds-password nil) (nnopds-headers nil)
              (nnopds-auth-method 'basic)
              (nnopds-progress-protocol 'koreader)
              (nnopds-koreader-url nil) (nnopds-koreader-user nil) (nnopds-koreader-password nil)
              (nnopds--connection nil) (nnopds--group nil)
              (gnus-cache-directory (expand-file-name "cache" opds-root))
              (nnopds-request-timeout 2)
              (nnopds-catalog-cache-ttl nil)
              (nnopds-progress-sync-delay 60)
              (nntp-server-buffer (generate-new-buffer " *opds-test-server*")))
         (unwind-protect
             (progn
               (nnopds-test--wait (lambda () (file-readable-p (expand-file-name "port.txt" opds-root))))
               (let* ((opds-url (format "http://127.0.0.1:%s/catalog"
                                        (nnopds--read-bytes (expand-file-name "port.txt" opds-root))))
                      (connection (progn
                                    (should (nnopds-open-server "library"
                                                               `((nnopds-url ,opds-url)
                                                                 (nnopds-headers (("X-API-Key" . "test-key"))))))
                                    nnopds--connection)))
                 ,@body))
           (nnopds-request-close)
           (when (process-live-p process) (delete-process process))
           (kill-buffer output)
           (kill-buffer nntp-server-buffer))))))

(defun nnopds-test--requests (root &optional method)
  "Return recorded HTTP requests from ROOT, optionally filtering METHOD."
  (let ((file (expand-file-name "requests.jsonl" root)))
    (when (file-readable-p file)
      (cl-remove-if-not
       (lambda (request) (or (null method) (equal (plist-get request :method) method)))
       (mapcar (lambda (line) (json-parse-string line :object-type 'plist :array-type 'list
                                                :null-object nil :false-object nil))
               (split-string (nnopds--read-bytes file) "\n" t))))))

(defun nnopds-test--write (root name text)
  "Write fixture control TEXT to NAME in ROOT."
  (with-temp-file (expand-file-name name root) (insert text)))

(defun nnopds-test--publication (connection &optional number)
  "Load publication NUMBER from CONNECTION through the Gnus interface."
  (unless (and (or (executable-find "7zz") (executable-find "7z")) (libxml-available-p))
    (ert-skip "Requires 7-Zip and libxml"))
  (let* ((page (nnopds--catalog-page connection (nnopds--connection-url connection)))
         (entries (plist-get page :entries))
         (publications (delq nil (seq-mapcat
                                  (lambda (collection)
                                    (seq-map (lambda (document) (gethash document entries))
                                             (plist-get collection :publications)))
                                  (nnopds--collections (plist-get page :feed)))))
         (group (nnopds--publication-group (nth (or number 0) publications))))
    (should (nnopds-request-group group (nnopds--connection-name connection)))
    (gethash group (nnopds--connection-publications connection))))

(defmacro nnopds-test--with-browser (&rest body)
  "Run BODY in a Gnus OPDS browser using the enclosing fixture server."
  (declare (indent 0) (debug t))
  `(let ((gnus-directory (expand-file-name "News" opds-root))
         (gnus-home-directory opds-root) (gnus-startup-file (expand-file-name ".newsrc" opds-root))
         (gnus-init-file nil) (gnus-site-init-file nil) (gnus-use-dribble-file nil)
         (gnus-select-method '(nnnil "")) (gnus-save-newsrc-file nil) (gnus-check-new-newsgroups nil)
         (shr-use-fonts nil)
         (gnus-opened-servers nil) (gnus-server-alist nil) (gnus-server-method-cache nil)
         (gnus-ephemeral-servers nil)
         (gnus-newsrc-alist nil) (gnus-newsrc-hashtb nil)
         (gnus-cache-active-file (expand-file-name "active" gnus-cache-directory))
         (gnus-cache-active-hashtb nil) (gnus-cache-total-fetched-hashtb nil)
         (gnus-cache-active-altered nil)
         (gnus-group-buffer (generate-new-buffer-name " *opds-group*"))
         (gnus-browse-buffer (generate-new-buffer-name " *opds-browser*"))
         (gnus-browse-current-method nil) (gnus-browse-return-buffer nil)
         (gnus-secondary-select-methods
          (list (append (list 'nnopds "library")
                        (or nnopds-test--server-definitions
                            (list (list 'nnopds-url opds-url)
                                  '(nnopds-headers (("X-API-Key" . "test-key")))))))))
     (save-window-excursion
       (unwind-protect
           (progn
             (gnus)
             (should-not (nnopds-test--requests opds-root))
             (should (gnus-group-browse-foreign-server (car gnus-secondary-select-methods)))
             (setq connection nnopds--connection)
             ,@body)
         (gnus-close-backends)
         (when (get-buffer gnus-browse-buffer) (kill-buffer gnus-browse-buffer))
         (when (get-buffer gnus-group-buffer) (kill-buffer gnus-group-buffer))))))

(defun nnopds-test--at-link (url)
  "Move to the browser row linking to URL."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal url (get-text-property (point) 'nnopds-browse-link))))
    (forward-line 1))
  (should-not (eobp)))

(defun nnopds-test--at-book ()
  "Move to the first book row in the browser."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (get-text-property (point) 'nnopds-browse-book))) (forward-line 1))
  (should-not (eobp)))

(provide 'nnopds-test-helpers)
;;; nnopds-test-helpers.el ends here
