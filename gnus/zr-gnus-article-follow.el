;;; zr-gnus-article-follow.el --- Read Gnus articles in Follow windows -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Enable `zr-gnus-article-follow-mode' in a Gnus article buffer, then split
;; it into columns, manually or with `zr-window-follow-columns'.  Its local
;; keymap makes SPC and DEL page through the entire Follow window group.
;; The paging commands switch articles through Gnus and restore the column
;; layout afterwards.  They can also be called from the article's summary.
;; This works with any Gnus article, including EPUB chapters.

;;; Code:

(require 'follow)
(require 'gnus-art)

(defgroup zr-gnus-article-follow nil
  "Read Gnus articles in Follow windows."
  :group 'gnus-article
  :group 'follow)

(defvar zr-gnus-article-follow-mode)
(defvar-local zr-gnus-article-follow--previous-follow nil)
(defvar shr-width)

(defun zr-gnus-article-follow--window ()
  "Return the current article's visible Follow window, or signal an error."
  (let* ((buffer (if (derived-mode-p 'gnus-article-mode)
                     (current-buffer)
                   (when (derived-mode-p 'gnus-summary-mode)
                     (get-buffer gnus-article-buffer))))
         (window (and buffer
                      (if (eq (window-buffer (selected-window)) buffer)
                          (selected-window)
                        (get-buffer-window buffer (selected-frame))))))
    (unless (and window
                 (buffer-local-value 'zr-gnus-article-follow-mode buffer)
                 (buffer-local-value 'follow-mode buffer))
      (user-error "Enable zr-gnus-article-follow-mode in a visible article buffer"))
    window))

(defun zr-gnus-article-follow--align (&optional end)
  "Align the article's columns from the beginning, or its end with END."
  (let* ((windows (follow-all-followers))
         (anchor (if end (car (last windows)) (car windows))))
    (with-selected-window anchor
      (goto-char (if end (point-max) (point-min)))
      (if end (recenter -1) (set-window-start anchor (point-min)))
      (follow-redisplay windows anchor))
    (dolist (window windows)
      (set-window-point window (window-start window)))))

(defun zr-gnus-article-follow--scroll (function lines)
  "Scroll the entire window group with FUNCTION and optional LINES."
  (select-window (car (follow-all-followers)))
  (funcall function lines)
  (follow-redisplay)
  (dolist (window (follow-all-followers))
    (set-window-point window (window-start window)))
  nil)

(defun zr-gnus-article-follow--next-page (lines)
  "Page forward by LINES, returning non-nil at the end of the article."
  (follow-window-end nil t)
  (let ((last (car (last (follow-all-followers)))))
    (if (pos-visible-in-window-p (point-max) last)
        ;; Let Gnus advance narrowed pages before changing articles.
        (let ((end (with-selected-window last (gnus-article-next-page lines))))
          (unless end (zr-gnus-article-follow--align))
          end)
      (zr-gnus-article-follow--scroll #'follow-scroll-up lines))))

(defun zr-gnus-article-follow--prev-page (lines)
  "Page backward by LINES, returning non-nil at the start of the article."
  (follow-window-end nil t)
  (let ((first (car (follow-all-followers))))
    (if (/= (window-start first) (point-min))
        (zr-gnus-article-follow--scroll #'follow-scroll-down lines)
      (if (= (point-min) (save-restriction (widen) (point-min)))
          t
        (with-selected-window first
          (goto-char (point-min))
          (gnus-article-prev-page lines))
        (zr-gnus-article-follow--align t)
        nil))))

(defun zr-gnus-article-follow--change-article (key)
  "Execute Gnus' summary KEY and restore this article's column layout."
  (let ((configuration (current-window-configuration))
        (buffer (current-buffer))
        (article gnus-article-current)
        (shr-width (or (bound-and-true-p shr-width)
                       (max 1 (1- (window-body-width))))))
    (unwind-protect
        (gnus-article-read-summary-keys nil key)
      (set-window-configuration configuration)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and zr-gnus-article-follow-mode follow-mode)
            (if (equal article gnus-article-current)
                (follow-redisplay)
              (zr-gnus-article-follow--align))))))))

;;;###autoload
(defun zr-gnus-article-follow-next-page (&optional lines)
  "Show the next screen of Follow columns, or select the next Gnus article.
Article selection follows `gnus-summary-goto-unread' in the summary.
With a prefix argument, scroll LINES display lines and stop at the
article boundary.  This command also works in the article's summary
when the visible article has `zr-gnus-article-follow-mode' enabled."
  (interactive "P")
  (with-selected-window (zr-gnus-article-follow--window)
    (when (zr-gnus-article-follow--next-page (when lines (prefix-numeric-value lines)))
      (if lines
          (message "End of article")
        (zr-gnus-article-follow--change-article ?n)))))

;;;###autoload
(defun zr-gnus-article-follow-prev-page (&optional lines)
  "Show the previous screen of Follow columns, or select the previous article.
Article selection follows `gnus-summary-goto-unread' in the summary.
With a prefix argument, scroll LINES display lines and stop at the
article boundary.  This command also works in the article's summary
when the visible article has `zr-gnus-article-follow-mode' enabled."
  (interactive "P")
  (with-selected-window (zr-gnus-article-follow--window)
    (when (zr-gnus-article-follow--prev-page (when lines (prefix-numeric-value lines)))
      (if lines
          (message "Beginning of article")
        (zr-gnus-article-follow--change-article ?p)))))

(defvar-keymap zr-gnus-article-follow-mode-map
  :doc "Local paging commands for Gnus articles in Follow mode."
  "<remap> <gnus-article-goto-next-page>" #'zr-gnus-article-follow-next-page
  "<remap> <gnus-article-goto-prev-page>" #'zr-gnus-article-follow-prev-page
  "<remap> <scroll-up-command>" #'zr-gnus-article-follow-next-page
  "<remap> <scroll-down-command>" #'zr-gnus-article-follow-prev-page)

(defun zr-gnus-article-follow--disable ()
  "Restore Follow state before killing this buffer or changing its major mode."
  (zr-gnus-article-follow-mode -1))

;;;###autoload
(define-minor-mode zr-gnus-article-follow-mode
  "Read a Gnus article using its entire Follow window group.
This enables `follow-mode'; split the article window into as many
columns as desired, for example with `zr-window-follow-columns'.
SPC/C-v and DEL/S-SPC/M-v use the mode's own paging commands.
Disabling the mode restores the previous state of `follow-mode'
and leaves the window layout in place."
  :lighter " Article-Follow"
  :group 'zr-gnus-article-follow
  (if zr-gnus-article-follow-mode
      (progn
        (unless (derived-mode-p 'gnus-article-mode)
          (setq zr-gnus-article-follow-mode nil)
          (user-error "Enable this mode in a Gnus article buffer"))
        (unless (local-variable-p 'zr-gnus-article-follow--previous-follow)
          (setq-local zr-gnus-article-follow--previous-follow follow-mode))
        (unless follow-mode (follow-mode 1))
        (add-hook 'kill-buffer-hook #'zr-gnus-article-follow--disable nil t)
        (add-hook 'change-major-mode-hook #'zr-gnus-article-follow--disable nil t))
    (remove-hook 'kill-buffer-hook #'zr-gnus-article-follow--disable t)
    (remove-hook 'change-major-mode-hook #'zr-gnus-article-follow--disable t)
    (when (local-variable-p 'zr-gnus-article-follow--previous-follow)
      (unless zr-gnus-article-follow--previous-follow (follow-mode -1))
      (kill-local-variable 'zr-gnus-article-follow--previous-follow))))

(provide 'zr-gnus-article-follow)
;;; zr-gnus-article-follow.el ends here
