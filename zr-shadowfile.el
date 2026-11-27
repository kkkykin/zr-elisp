;;; zr-shadowfile.el --- Cross-platform file shadowing with TRAMP -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Enable `zr-shadowfile-mode', then use `shadow-define-literal-group',
;; `shadow-define-regexp-group', `shadow-define-cluster', and `shadow-cancel'.
;; Saving a grouped file records its pending copies.  `C-x 4 s' or
;; `shadow-copy-files' copies them through TRAMP.  Copies are also offered
;; when exiting, unless `zr-shadowfile-copy-on-exit' is nil.
;;
;; Literal groups can map a Windows path such as C:/Users/me/notes.txt to
;; /home/me/notes.txt on another host.  Enter each site's own filename;
;; ~/ is expanded on that site.  Regexp groups require identical filenames
;; on their sites.  Destination directories must already exist, and the
;; chosen TRAMP method must work independently of shadowfile.
;;
;; Configuration and pending copies use the built-in `shadow-*' variables
;; and information files.  Failed copies remain pending.  As in shadowfile,
;; copying overwrites the destination without merging concurrent changes.
;;
;; Shadowfile has no replaceable filename functions.  This mode installs
;; overrides for those functions and literal-group construction while
;; enabled.  Save and exit handling uses hooks; use this mode in place of
;; `shadow-initialize'.  Shadowfile and TRAMP are loaded on activation.
;; Loading the library does not enable shadowing.

;;; Code:

(require 'cl-lib)

(declare-function make-tramp-file-name "tramp" (&rest arguments))
(declare-function tramp-file-name-p "tramp" (object))
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-file-name-method "tramp" (file))
(declare-function tramp-file-name-host "tramp" (file))
(declare-function tramp-file-name-localname "tramp" (file))
(declare-function tramp-file-name-port "tramp" (file))
(declare-function tramp-file-name-hop "tramp" (file))
(declare-function tramp-file-name-user "tramp" (file))
(declare-function tramp-file-name-domain "tramp" (file))
(declare-function shadow-site-name "shadowfile" (site))
(declare-function shadow-name-site "shadowfile" (name))
(declare-function shadow-get-cluster "shadowfile" (name))
(declare-function shadow-site-cluster "shadowfile" (site))
(declare-function shadow-cluster-primary "shadowfile" (cluster))
(declare-function shadow-cluster-name "shadowfile" (cluster))
(declare-function shadow-cluster-regexp "shadowfile" (cluster))
(declare-function shadow-make-fullname "shadowfile" (hup &optional host name))
(declare-function shadow-read-site "shadowfile" ())
(declare-function shadow-read-files "shadowfile" ())
(declare-function shadow-expand-file-name "shadowfile" (file &optional default))
(declare-function shadow-write-info-file "shadowfile" ())
(declare-function shadow-add-to-todo "shadowfile" ())
(declare-function shadow-save-todo-file "shadowfile" ())
(declare-function shadow-copy-files "shadowfile" (&optional arg))
(declare-function shadow-invalidate-hashtable "shadowfile" ())

(defvar shadow-system-name)
(defvar shadow-homedir)
(defvar shadow-info-file)
(defvar shadow-todo-file)
(defvar shadow-literal-groups)
(defvar shadow-files-to-copy)
(defvar shadow-todo-buffer)
(defvar shadow-inhibit-message)

(defgroup zr-shadowfile nil
  "Cross-platform file shadowing with TRAMP."
  :group 'shadow)

(defcustom zr-shadowfile-copy-on-exit t
  "Whether to offer pending shadow copies when exiting Emacs.
The usual `shadow-noquery' setting controls confirmation.  Pending copies
are saved after each successful file save, including when this is nil."
  :type 'boolean
  :group 'zr-shadowfile)

(defvar zr-shadowfile-mode)
(defvar zr-shadowfile--active nil)
(defvar zr-shadowfile--saving-todo nil)

(defun zr-shadowfile--site-file (name)
  "Return (SITE . FILE) for a known shadow identification in NAME.
The file component may contain colons, including a Windows drive letter."
  (save-match-data
    (when (and (stringp name) (string-match "\\`/\\([^:/]+\\):" name))
      (let ((site (match-string 1 name))
            (file (substring name (match-end 0)))
            (local (shadow-site-name shadow-system-name)))
        (cond
         ((string-equal-ignore-case site local) (cons local file))
         ((shadow-get-cluster site) (cons site file)))))))

(defun zr-shadowfile--parse-name (name)
  "Parse NAME, recognizing shadow identifications before TRAMP syntax."
  (let ((parts (zr-shadowfile--site-file name)))
    (cond
     ((null name) nil)
     ((tramp-file-name-p name) name)
     (parts (make-tramp-file-name :host (car parts) :localname (cdr parts)))
     ((file-remote-p name) (tramp-dissect-file-name name))
     (t (make-tramp-file-name
         :host (shadow-site-name shadow-system-name) :localname name)))))

(defun zr-shadowfile--local-file (file)
  "Return FILE's local path when it identifies this machine."
  (cond
   ((null file) nil)
   ((tramp-file-name-p file)
    (when (null (tramp-file-name-method file))
      (let* ((host (tramp-file-name-host file))
             (cluster (shadow-get-cluster host)))
        (when (or (string-equal-ignore-case
                   host (shadow-site-name shadow-system-name))
                  (and cluster
                       (equal (shadow-cluster-primary cluster) shadow-system-name)))
          (tramp-file-name-localname file)))))
   ((zr-shadowfile--site-file file)
    (zr-shadowfile--local-file (zr-shadowfile--parse-name file)))
   ((not (file-remote-p file)) file)))

(defun zr-shadowfile--expand-cluster-in-file-name (file)
  "Expand FILE's cluster identification, returning bare local paths."
  (when (stringp file)
    (or (zr-shadowfile--local-file file)
        (when-let* ((parts (zr-shadowfile--site-file file))
                    (cluster (shadow-get-cluster (car parts))))
          (concat (shadow-cluster-primary cluster) (cdr parts)))
        file)))

(defun zr-shadowfile--replace-name-component (fullname newname)
  "Replace FULLNAME's path with NEWNAME, preserving its site."
  (shadow-make-fullname (zr-shadowfile--parse-name fullname) nil newname))

(defun zr-shadowfile--contract-file-name (file)
  "Replace FILE's site with a matching cluster, retaining its path.
Absolute paths stay absolute.  Do not use this machine's home directory
to resolve filenames belonging to another operating system."
  (when-let* ((hup (zr-shadowfile--parse-name file)))
    (if-let* ((cluster (shadow-site-cluster (shadow-make-fullname hup nil ""))))
        (shadow-make-fullname
         (make-tramp-file-name :host (shadow-cluster-name cluster)
                               :localname (tramp-file-name-localname hup)))
      (shadow-make-fullname hup))))

(defun zr-shadowfile--primary (hup)
  "Return HUP's site vector, resolving a cluster to its primary site."
  (if-let* ((cluster (and (null (tramp-file-name-method hup))
                         (shadow-get-cluster (tramp-file-name-host hup)))))
      (zr-shadowfile--parse-name (shadow-cluster-primary cluster))
    hup))

(defun zr-shadowfile--same-site (pattern file)
  "Whether PATTERN includes FILE's site, preserving TRAMP connection identity."
  (let ((pattern (zr-shadowfile--parse-name pattern))
        (file (zr-shadowfile--parse-name file)))
    (when (and pattern file)
      (let ((cluster (and (null (tramp-file-name-method pattern))
                          (shadow-get-cluster (tramp-file-name-host pattern))))
            (primary (zr-shadowfile--primary file)))
        (or (and cluster
                 (string-match-p (shadow-cluster-regexp cluster)
                                 (shadow-make-fullname primary nil "")))
            (let ((pattern (zr-shadowfile--primary pattern)))
              (and (equal (tramp-file-name-method pattern)
                          (tramp-file-name-method primary))
                   (string-equal-ignore-case (tramp-file-name-host pattern)
                                             (tramp-file-name-host primary))
                   (equal (tramp-file-name-port pattern) (tramp-file-name-port primary))
                   (equal (tramp-file-name-hop pattern) (tramp-file-name-hop primary))
                   (or (null (tramp-file-name-user pattern))
                       (equal (tramp-file-name-user pattern) (tramp-file-name-user primary)))
                   (or (null (tramp-file-name-domain pattern))
                       (equal (tramp-file-name-domain pattern)
                              (tramp-file-name-domain primary))))))))))

(defun zr-shadowfile--file-match (pattern file &optional regexp)
  "Match PATTERN against FILE, respecting local filesystem case rules.
With REGEXP non-nil, PATTERN's path component is a regular expression."
  (let ((pattern (zr-shadowfile--parse-name pattern))
        (file (zr-shadowfile--parse-name file)))
    (when (and pattern file (zr-shadowfile--same-site pattern file))
      (let* ((local (zr-shadowfile--local-file file))
             (case-fold-search (and local (file-name-case-insensitive-p local)))
             (pattern-name (tramp-file-name-localname pattern))
             (file-name (tramp-file-name-localname file)))
        (if regexp
            (and (string-match-p pattern-name file-name) t)
          (if case-fold-search
              (string-equal-ignore-case pattern-name file-name)
            (string-equal pattern-name file-name)))))))

(defun zr-shadowfile--define-literal-group ()
  "Define a literal shadow group, expanding each filename on its own site."
  (interactive)
  (unless (buffer-file-name) (user-error "Visit a file before defining its shadow group"))
  (let ((name (file-local-name (buffer-file-name)))
        site group)
    (while (setq site (shadow-read-site))
      (let* ((path (read-string "Filename: " name))
             (hup (zr-shadowfile--parse-name (shadow-name-site site)))
             (fullname (shadow-make-fullname hup nil path))
             (true (shadow-expand-file-name
                    (zr-shadowfile--expand-cluster-in-file-name fullname))))
        (setq name (file-local-name true))
        (push (zr-shadowfile--contract-file-name true) group)))
    (when group
      (push group shadow-literal-groups)
      (shadow-write-info-file))))

(defconst zr-shadowfile--adapters
  '((shadow-parse-name . zr-shadowfile--parse-name)
    (shadow-local-file . zr-shadowfile--local-file)
    (shadow-expand-cluster-in-file-name . zr-shadowfile--expand-cluster-in-file-name)
    (shadow-replace-name-component . zr-shadowfile--replace-name-component)
    (shadow-contract-file-name . zr-shadowfile--contract-file-name)
    (shadow-same-site . zr-shadowfile--same-site)
    (shadow-file-match . zr-shadowfile--file-match)
    (shadow-define-literal-group . zr-shadowfile--define-literal-group))
  "Shadowfile entry points with cross-platform replacements.")

(defun zr-shadowfile--after-save ()
  "Queue a successfully saved file and persist pending copies."
  (when (and (not zr-shadowfile--saving-todo) (buffer-file-name)
             (not (eq (current-buffer) shadow-todo-buffer)))
    (let ((zr-shadowfile--saving-todo t)
          (before (copy-sequence shadow-files-to-copy))
          (quiet shadow-inhibit-message)
          (shadow-inhibit-message t))
      (shadow-add-to-todo)
      (shadow-save-todo-file)
      (when (and (not quiet)
                 (not (equal before shadow-files-to-copy)) shadow-files-to-copy)
        (message "%s" (substitute-command-keys
                       "Use \\[shadow-copy-files] to update shadows."))))))

(defun zr-shadowfile--query-exit ()
  "Offer pending copies before exiting, keeping unsuccessful copies on disk."
  (when zr-shadowfile-copy-on-exit (shadow-copy-files))
  (shadow-save-todo-file)
  t)

(defun zr-shadowfile--disable ()
  "Remove this mode's hooks and shadowfile replacements."
  (remove-hook 'after-save-hook #'zr-shadowfile--after-save)
  (remove-hook 'kill-emacs-query-functions #'zr-shadowfile--query-exit)
  (when (featurep 'shadowfile)
    (dolist (entry zr-shadowfile--adapters)
      (advice-remove (car entry) (cdr entry)))
    (shadow-invalidate-hashtable))
  (setq zr-shadowfile--active nil))

;;;###autoload
(define-minor-mode zr-shadowfile-mode
  "Enable cross-platform shadowfile groups and pending copies globally.
Use this instead of `shadow-initialize'.  The `shadow-*' commands and
configuration variables remain the public interface.  Saves record and
persist copies; `shadow-copy-files' or C-x 4 s performs them.  Exiting
also offers copies when `zr-shadowfile-copy-on-exit' is non-nil.
Disabling removes the filename replacements, hooks and key binding."
  :global t
  :group 'zr-shadowfile
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-x 4 s") #'shadow-copy-files)
            map)
  (if zr-shadowfile-mode
      (unless zr-shadowfile--active
        (condition-case err
            (progn
              (require 'shadowfile)
              (dolist (entry zr-shadowfile--adapters)
                (advice-add (car entry) :override (cdr entry)))
              (setq shadow-homedir (file-name-as-directory
                                    (shadow-expand-file-name shadow-homedir))
                    shadow-info-file (shadow-expand-file-name shadow-info-file)
                    shadow-todo-file (shadow-expand-file-name shadow-todo-file))
              (unless (shadow-read-files)
                (user-error "Shadowfile information files are locked by another Emacs"))
              (add-hook 'after-save-hook #'zr-shadowfile--after-save)
              (add-hook 'kill-emacs-query-functions #'zr-shadowfile--query-exit)
              (setq zr-shadowfile--active t))
          (error
           (setq zr-shadowfile-mode nil)
           (zr-shadowfile--disable)
           (signal (car err) (cdr err)))))
    (zr-shadowfile--disable)))

(defun zr-shadowfile-unload-function ()
  "Disable shadowing before unloading this library."
  (zr-shadowfile-mode -1)
  nil)

(provide 'zr-shadowfile)
;;; zr-shadowfile.el ends here
