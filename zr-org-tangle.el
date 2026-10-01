;;; zr-org-tangle.el --- Tangle paths and reviewed detangling -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).

;;; Commentary:

;; Detangling merges raw source against its expansion and the edited output.
;; Changes remain in source buffers for review and saving.  No global override
;; of Org's detangler is installed.  Enable custom-ID support separately.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ob-tangle)
(require 'org-id)
(require 'smerge-mode)

(defgroup zr-org-tangle nil
  "Tangle and detangle helpers."
  :group 'org-babel)

(defcustom zr-org-tangle-directory "_tangle"
  "Default tangle directory."
  :type 'directory)

(defcustom zr-org-tangle-diff3-program "diff3"
  "Three-way merge executable."
  :type 'string)

(defcustom zr-org-tangle-confirm t
  "Ask before applying detangled changes."
  :type 'boolean)

(defun zr-org-tangle-path (&optional name no-inherit)
  "Resolve NAME in the TANGLE-DIR property or `zr-org-tangle-directory'.
NAME defaults to the current source block name.  NO-INHERIT ignores parents.
Lisp-valued directory properties are evaluated only after confirmation."
  (let* ((name (or name (org-element-property :name (org-element-context))))
         (directory
          (or (org-entry-get nil "TANGLE-DIR" (not no-inherit)) zr-org-tangle-directory)))
    (unless name
      (user-error "Name the block or supply an output name"))
    (when (string-match-p "\\`[ \t]*['`]?[(]" directory)
      (unless (y-or-n-p "Evaluate the TANGLE-DIR Lisp expression? ")
        (user-error "Cancelled"))
      (setq directory (eval (read directory) t)))
    (unless (stringp directory)
      (user-error "TANGLE-DIR must resolve to a directory"))
    (expand-file-name name directory)))

(defun zr-org-tangle-custom-id (&optional create)
  "Return the current heading's CUSTOM_ID, creating one if CREATE."
  (or (org-entry-get nil "CUSTOM_ID")
      (when create
        (unless (org-before-first-heading-p)
          (let ((id (org-id-new)))
            (org-entry-put nil "CUSTOM_ID" id)
            id)))))

(defun zr-org-tangle--link-id (parameters)
  "Ensure an ID when PARAMETERS request source links."
  (unless (member (cdr (assq :comments parameters)) '(nil "no"))
    (zr-org-tangle-custom-id t)))

(define-minor-mode zr-org-tangle-id-mode
  "Create CUSTOM_IDs when tangling with link comments."
  :global t
  (if zr-org-tangle-id-mode
      (advice-add 'org-babel-tangle--unbracketed-link :before #'zr-org-tangle--link-id)
    (advice-remove 'org-babel-tangle--unbracketed-link #'zr-org-tangle--link-id)))

(defun zr-org-tangle--merge (raw expanded incoming)
  "Return (TEXT . CONFLICTS) after merging RAW, EXPANDED and INCOMING.
Exit codes zero and one are success; other results signal without editing."
  (unless (executable-find zr-org-tangle-diff3-program)
    (user-error "diff3 is unavailable"))
  (let (files)
    (unwind-protect
        (progn
          (dolist (text (list raw expanded incoming))
            (push (make-temp-file "zr-detangle-" nil nil text) files))
          (setq files (nreverse files))
          (with-temp-buffer
            (let ((status (apply #'call-process zr-org-tangle-diff3-program nil
                                 (list t nil) nil
                                 "-m" "-L" "source" "-L" "expanded" "-L" "tangled" files)))
              (unless (memq status '(0 1))
                (error "diff3 failed with status %s" status))
              (cons (buffer-string) (= status 1)))))
      (dolist (file files)
        (when (file-exists-p file)
          (delete-file file))))))

(defun zr-org-tangle--prepare-body (incoming)
  "Compute a proposed change for INCOMING without editing the source.
Return (BEGIN END RAW MERGED CONFLICTS), with buffer markers as bounds."
  (let ((element (org-element-context)))
    (unless (eq (org-element-type element) 'src-block)
      (user-error "Not in a source block"))
    (save-excursion
      (let* ((area (org-src--contents-area element))
             (begin (car area))
             (end (cadr area))
             (raw (buffer-substring-no-properties begin end))
             (expanded (org-element-normalize-string (org-babel-expand-src-block)))
             (incoming (org-element-normalize-string incoming)))
        (unless (equal expanded incoming)
          (let ((merged (zr-org-tangle--merge raw expanded incoming)))
            (list (copy-marker begin) (copy-marker end t) raw
                  (car merged) (cdr merged))))))))

(defun zr-org-tangle--apply-changes (changes)
  "Apply prepared CHANGES together, and return markers for conflicts.
Roll back all source buffers if applying any change fails."
  (when (and changes
             (or (not zr-org-tangle-confirm)
                 (y-or-n-p
                  (format "Apply detangled changes to %d source blocks? "
                          (length changes)))))
    (let (groups conflicts accepted)
      ;; Validate every source before editing any buffer.
      (dolist (change changes)
        (pcase-let ((`(,begin ,end ,raw . ,_) change))
          (with-current-buffer (marker-buffer begin)
            (barf-if-buffer-read-only)
            (unless (equal raw (buffer-substring-no-properties begin end))
              (user-error "Source changed while preparing detangle")))))
      (dolist (buffer (delete-dups (mapcar (lambda (change)
                                             (marker-buffer (car change)))
                                           changes)))
        (setq groups (nconc (prepare-change-group buffer) groups)))
      (unwind-protect
          (progn
            (activate-change-group groups)
            (dolist (change changes)
              (pcase-let ((`(,begin ,end ,_raw ,text ,conflict) change))
                (with-current-buffer (marker-buffer begin)
                  (save-excursion
                    (goto-char begin)
                    (delete-region begin end)
                    (insert text)
                    (when conflict
                      (goto-char begin)
                      (re-search-forward "^<<<<<<< " end t)
                      (push (copy-marker (line-beginning-position)) conflicts))))))
            (accept-change-group groups)
            (setq accepted t))
        (unless accepted
          (cancel-change-group groups)
          (dolist (marker conflicts)
            (set-marker marker nil))))
      (dolist (marker conflicts)
        (with-current-buffer (marker-buffer marker)
          (smerge-mode 1)))
      (nreverse conflicts))))

(defun zr-org-tangle--show-conflicts (markers)
  "Visit the first conflict in MARKERS and release the markers."
  (unwind-protect
      (when markers
        (pop-to-buffer (marker-buffer (car markers)))
        (goto-char (car markers)))
    (dolist (marker markers)
      (set-marker marker nil))))

(defun zr-org-tangle--release-changes (changes)
  "Release buffer markers in CHANGES."
  (dolist (change changes)
    (set-marker (car change) nil)
    (set-marker (cadr change) nil)))

(defun zr-org-tangle--update-body (incoming)
  "Merge INCOMING into one source block, leaving changes unsaved."
  (let ((changes (delq nil (list (zr-org-tangle--prepare-body incoming)))))
    (unwind-protect
        (zr-org-tangle--show-conflicts (zr-org-tangle--apply-changes changes))
      (zr-org-tangle--release-changes changes))))

(defun zr-org-tangle-detangle (&optional file block-only)
  "Merge edits from tangled FILE into Org source buffers for review.
Interactively, C-u restricts the operation to the linked block at point."
  (interactive (list nil current-prefix-arg))
  (let (changes conflicts count)
    (unwind-protect
        (progn
          (save-window-excursion
            (with-current-buffer (if file
                                     (find-file-noselect file)
                                   (current-buffer))
              (save-excursion
                (save-restriction
                  (when block-only
                    (end-of-line)
                    (unless (re-search-backward org-link-bracket-re nil t)
                      (user-error "No source link before point"))
                    (let ((begin (line-beginning-position))
                          (label (match-string-no-properties 2)))
                      (unless (and label
                                   (re-search-forward
                                    (concat " " (regexp-quote label) " ends here") nil t))
                        (user-error "No closing tangle comment"))
                      (narrow-to-region begin (line-end-position))))
                  (cl-letf (((symbol-function 'org-babel-update-block-body)
                             (lambda (incoming)
                               (when-let*
                                   ((change (zr-org-tangle--prepare-body incoming)))
                                 (push change changes)))))
                    (setq count (org-babel-detangle)))))))
          (setq changes (nreverse changes)
                conflicts (zr-org-tangle--apply-changes changes))
          (zr-org-tangle--show-conflicts conflicts)
          count)
      (zr-org-tangle--release-changes changes))))

(provide 'zr-org-tangle)
;;; zr-org-tangle.el ends here
