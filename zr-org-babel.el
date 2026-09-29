;;; zr-org-babel.el --- Babel execution, expansion and completion -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2024
;; Author:  <kkky@KKSBOW>
;; Source: ../emacs.d/user-lisp/init-org.el (selected functionality).
;;; Commentary:
;; Commands preserve Org's evaluation confirmation policy.  Enable the local
;; completion mode explicitly.  Bat/AHK header defaults belong in init.el.
;;; Code:
(require 'org)
(require 'ob)
(require 'ob-lob)
(require 'org-src)
(require 'org-element)
(require 'subr-x)
(defgroup zr-org-babel nil "Babel helpers." :group 'org-babel)
(defun zr-org-babel--info ()
  "Return (ELEMENT INFO) for the executable Babel element at point."
  (let* ((element (org-element-context)) (type (org-element-type element)))
    (list element
          (pcase type
            ((or 'src-block 'inline-src-block) (org-babel-get-src-block-info))
            ((or 'babel-call 'inline-babel-call) (org-babel-lob-get-info element))
            (_ (user-error "No Babel block or call at point"))))))
(defun zr-org-babel-execute (&optional parameters)
  "Execute the source block or call at point with PARAMETERS."
  (interactive)
  (pcase-let ((`(,element ,info) (zr-org-babel--info)))
    (org-babel-execute-src-block nil info parameters (org-element-type element))))
(defun zr-org-babel-blocks ()
  "Return named source blocks and calls as (NAME . POSITION) pairs."
  (org-element-map (org-element-parse-buffer) '(src-block babel-call)
    (lambda (element)
      (when-let* ((name (org-element-property :name element)))
        (cons name (org-element-property :begin element))))))
(defun zr-org-babel-execute-named (name &optional parameters)
  "Execute the named block or call NAME with PARAMETERS."
  (interactive (list (completing-read "Block or call: " (zr-org-babel-blocks) nil t)))
  (save-excursion
    (save-restriction
      (widen)
      (let ((position (cdr (assoc name (zr-org-babel-blocks)))))
        (unless position (user-error "No block named %s" name))
        (goto-char position)
        (zr-org-babel-execute parameters)))))
(defun zr-org-babel--execute-here ()
  "Open a link or execute a Babel element at point, returning non-nil if found."
  (if (derived-mode-p 'org-mode)
      (pcase (org-element-type (org-element-context))
        ('link (org-open-at-point) t)
        ((or 'src-block 'inline-src-block 'babel-call 'inline-babel-call)
         (zr-org-babel-execute) t))
    (when (org-in-regexp org-link-any-re)
      (org-open-at-point-global) t)))
(defun zr-org-babel-execute-nearby (&optional argument file)
  "Open a link or execute nearby Babel, optionally in FILE.
Negative ARGUMENT searches backward; C-u searches from the buffer start."
  (interactive "P")
  (with-current-buffer (if file (find-file-noselect file) (current-buffer))
    (save-excursion
      (when (equal argument '(4)) (goto-char (point-min)))
      (unless (zr-org-babel--execute-here)
        (let ((count (if (equal argument '-) -1 (if (numberp argument) argument 1)))
              (regexp (if (derived-mode-p 'org-mode)
                          (concat org-link-any-re "\\|^[ \t]*#\\+\\(?:begin_src\\|call:\\)\\|\\_<\\(?:src_\\|call_\\)")
                        org-link-any-re))
              (case-fold-search t))
          (unless (re-search-forward regexp nil t count) (user-error "No link or Babel element found"))
          (goto-char (match-beginning 0))
          (unless (zr-org-babel--execute-here) (user-error "No executable element found")))))))
(defun zr-org-babel-expand ()
  "Display expanded source for a block or a named block call."
  (interactive)
  (pcase-let ((`(,element ,info) (zr-org-babel--info)))
    (save-excursion
      (when-let* ((name (org-element-property :call element))) (org-babel-goto-named-src-block name))
      (setf (nth 2 info) (org-babel-process-params (nth 2 info)))
      (funcall-interactively #'org-babel-expand-src-block nil info))))
(defun zr-org-babel-display-result (&optional rerun)
  "Display inline image results of the current block, optionally RERUN it."
  (interactive "P")
  (save-excursion
    (unless (org-babel-get-src-block-info 'light) (user-error "No source block"))
    (when (or rerun (not (org-babel-where-is-src-block-result))) (zr-org-babel-execute))
    (when-let* ((position (org-babel-where-is-src-block-result)))
      (goto-char position)
      (forward-line)
      (skip-chars-forward " \t\n")
      (when (looking-at org-link-bracket-re)
        (org-display-inline-images nil t (match-beginning 0) (match-end 0))))))
(defun zr-org-babel-format-json (&optional name)
  "Format the JSON source block at point, or the block NAME."
  (interactive)
  (save-excursion
    (when name (org-babel-goto-named-src-block name))
    (let ((element (org-element-context)))
      (unless (and (eq (org-element-type element) 'src-block)
                   (equal (org-element-property :language element) "json"))
        (user-error "Not a JSON source block"))
      (pcase-let* ((`(,begin ,end ,body) (org-src--contents-area element))
                   (indent (save-excursion (goto-char begin) (current-indentation)))
                   (formatted
                    (with-temp-buffer
                      (insert body)
                      ;; Formatting happens before touching the source.  This
                      ;; also validates JSON without requiring a major mode.
                      (json-pretty-print-buffer)
                      (indent-rigidly (point-min) (point-max) indent)
                      (org-element-normalize-string (buffer-string)))))
        (atomic-change-group
          (delete-region begin end)
          (goto-char begin)
          (insert formatted))))))
(defvar-local zr-org-babel--completion-buffer nil)
(defun zr-org-babel--clear-completion ()
  "Dispose of this Org buffer's language completion context."
  (when (buffer-live-p zr-org-babel--completion-buffer)
    (kill-buffer zr-org-babel--completion-buffer))
  (setq zr-org-babel--completion-buffer nil))
(defun zr-org-babel-completion-at-point ()
  "Complete source text in its own major mode and translate bounds back to Org."
  (when (org-in-src-block-p t)
    (let* ((element (org-element-context))
           (area (org-src--contents-area element))
           (begin (car area))
           (text (buffer-substring-no-properties begin (cadr area)))
           (offset (- (point) begin))
           (mode (org-src-get-lang-mode (org-element-property :language element))))
      (unless (buffer-live-p zr-org-babel--completion-buffer)
        (setq zr-org-babel--completion-buffer (generate-new-buffer " *zr source completion*")))
      (let ((buffer zr-org-babel--completion-buffer))
        (with-current-buffer buffer
          (unless (eq major-mode mode) (funcall mode))
          (erase-buffer)
          (insert text)
          (goto-char (1+ offset))
          (when-let* ((result (run-hook-with-args-until-success 'completion-at-point-functions))
                      ((consp result)))
            (let ((table (nth 2 result)))
              (list (+ begin (1- (nth 0 result))) (+ begin (1- (nth 1 result)))
                    (lambda (string predicate action)
                      (with-current-buffer buffer
                        (complete-with-action action table string predicate)))
                    :exclusive 'no))))))))
(define-minor-mode zr-org-babel-mode
  "Enable Babel source completion in the current Org buffer."
  :lighter nil
  (if zr-org-babel-mode
      (progn
        (add-hook 'completion-at-point-functions #'zr-org-babel-completion-at-point nil t)
        (add-hook 'kill-buffer-hook #'zr-org-babel--clear-completion nil t)
        (add-hook 'change-major-mode-hook #'zr-org-babel--clear-completion nil t))
    (remove-hook 'completion-at-point-functions #'zr-org-babel-completion-at-point t)
    (remove-hook 'kill-buffer-hook #'zr-org-babel--clear-completion t)
    (remove-hook 'change-major-mode-hook #'zr-org-babel--clear-completion t)
    (zr-org-babel--clear-completion)))
(defun zr-org-babel-bat-assignments (parameters)
  "Produce quoted batch variable assignments from Babel PARAMETERS."
  (mapcar (lambda (entry) (format "set \"%s=%s\"" (car entry) (cdr entry)))
          (org-babel--get-vars parameters)))
(defvar zr-org-babel--bat-original nil)
(define-minor-mode zr-org-babel-bat-mode
  "Register batch variable expansion explicitly."
  :global t
  (if zr-org-babel-bat-mode
      (unless zr-org-babel--bat-original
        (setq zr-org-babel--bat-original
              (list (and (fboundp 'org-babel-variable-assignments:bat)
                         (symbol-function 'org-babel-variable-assignments:bat))))
        (defalias 'org-babel-variable-assignments:bat #'zr-org-babel-bat-assignments))
    (when (eq (symbol-function 'org-babel-variable-assignments:bat) #'zr-org-babel-bat-assignments)
      (if (car zr-org-babel--bat-original)
          (fset 'org-babel-variable-assignments:bat (car zr-org-babel--bat-original))
        (fmakunbound 'org-babel-variable-assignments:bat)))
    (setq zr-org-babel--bat-original nil)))
(defun zr-org-babel-save-source ()
  "Save an Org edit buffer, confirming saves of expanded previews."
  (interactive)
  (when (or (not (string-prefix-p "*Org-Babel Preview " (buffer-name)))
            (y-or-n-p "Save expanded preview back to its source? "))
    (org-edit-src-save)))
(provide 'zr-org-babel)
;;; zr-org-babel.el ends here
