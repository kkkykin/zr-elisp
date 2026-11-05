;;; zr-org-srs-review.el --- Review commands and keyboard panel for Org-srs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1") (org-srs "0.1") (transient "0.7"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `zr-org-srs-review-menu' during an Org-srs review to open a
;; persistent keyboard panel.  SPC reveals the answer; 1/2/3/4 rate it
;; Easy/Good/Hard/Again.  Rating is disabled while confirmation is pending,
;; including intermediate steps of cloze items.  Review actions reopen
;; the panel on the next item, even when it belongs to another buffer.
;; q hides the panel for ordinary Org editing; Q ends the review.
;; Enable `zr-org-srs-review-menu-mode' to open it when a review starts.
;; The mode sets command-based confirmation automatically.
;; `zr-org-srs-review-start' reviews `zr-org-srs-directory'.
;; TTS speaks the title or Front through Termux or Windows, with a
;; buffer-local context menu during review.  Enable
;; `zr-org-srs-review-auto-tts-mode' in a deck buffer to speak card text
;; automatically after confirming review items (titles by default).
;; Loading this library does not load Org-srs or change its configuration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'zr-org-srs)

(autoload 'zr-termux-tts-speak "zr-termux" nil t)
(autoload 'zr-windows-tts-speak "zr-windows" nil t)

(declare-function org-srs-reviewing-p "org-srs-review" ())
(declare-function org-srs-item-confirm-pending-p "org-srs-item" (&optional command))
(declare-function org-srs-item-marker "org-srs-item" (item &optional id buffer))
(declare-function org-srs-item-confirm-command "org-srs-item" (&rest args))
(declare-function org-srs-review-rate-again "org-srs-review-rate" ())
(declare-function org-srs-review-rate-hard "org-srs-review-rate" ())
(declare-function org-srs-review-rate-good "org-srs-review-rate" ())
(declare-function org-srs-review-rate-easy "org-srs-review-rate" ())
(declare-function org-srs-review-postpone "org-srs-review" (&optional time &rest args))
(declare-function org-srs-review-suspend "org-srs-review" ())
(declare-function org-srs-review-quit "org-srs-review" ())
(declare-function org-srs-review-undo "org-srs-review-undo" (&optional history))
(declare-function org-srs-review-undo-redo "org-srs-review-undo" (&optional history))
(declare-function org-srs-review-undo-history-undo "org-srs-review-undo" (history))
(declare-function org-srs-review-undo-history-redo "org-srs-review-undo" (history))
(declare-function org-srs-review-start "org-srs-review" (&optional source))
(declare-function org-srs-review-add-hook-once "org-srs-review"
                  (hook function &optional depth local))
(declare-function org-srs-item-card-regions "org-srs-item-card" ())

(defvar org-srs-review-item)
(defvar org-srs-review-undo-history)
(defvar org-srs-review-start-hook)
(defvar org-srs-item-confirm)
(defvar org-srs-item-after-confirm-hook)

(defgroup zr-org-srs-review nil
  "Review commands, TTS and keyboard panel for Org-srs items."
  :group 'zr-org-srs
  :prefix "zr-org-srs-review-")

(defcustom zr-org-srs-review-tts-function #'zr-org-srs-review--tts-speak
  "Function called with card text by `zr-org-srs-review-tts'.
The default calls `zr-termux-tts-speak' when termux-tts-speak is available,
otherwise `zr-windows-tts-speak', which also supports WSL."
  :type 'function)

(defcustom zr-org-srs-review-auto-tts-function #'zr-org-srs-review-tts
  "Function called without arguments after confirming a review item.
Used by `zr-org-srs-review-auto-tts-mode'.  The default speaks the title;
use `zr-org-srs-review-tts-front' to speak Front instead.
Can be set buffer-locally to select a different action for each deck."
  :type '(choice (function-item :tag "Title" zr-org-srs-review-tts)
                 (function-item :tag "Front" zr-org-srs-review-tts-front)
                 (function :tag "Custom function")))

;;;###autoload
(defun zr-org-srs-review-start ()
  "Review Org-srs cards in `zr-org-srs-directory'."
  (interactive)
  (require 'org-srs)
  (org-srs-review-start (expand-file-name zr-org-srs-directory)))

(defun zr-org-srs-review--tts-speak (text)
  "Speak TEXT through the available platform TTS backend."
  (if (executable-find "termux-tts-speak")
      (zr-termux-tts-speak text)
    (zr-windows-tts-speak text)))

;;;###autoload
(defun zr-org-srs-review-tts (&optional front)
  "Speak the current card's name, or its Front body when FRONT is non-nil.
Interactively, a prefix argument selects Front.  During review, use the
review item even if point has moved within the buffer."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "This command requires an Org buffer"))
  (require 'org-srs-item-card)
  (let ((text
         (save-excursion
           (save-restriction
             (widen)
             (when (bound-and-true-p org-srs-review-item)
               (goto-char (apply #'org-srs-item-marker org-srs-review-item)))
             (org-back-to-heading t)
             (while (and (not (org-entry-get nil "ID")) (org-up-heading-safe)))
             (unless (org-entry-get nil "ID")
               (user-error "No Org-srs card found"))
             (if front
                 (let ((region (cl-nth-value 0 (org-srs-item-card-regions))))
                   (narrow-to-region (car region) (cdr region))
                   (goto-char (point-min))
                   (when (org-at-heading-p)
                     (forward-line 1)
                     (org-end-of-meta-data t))
                   (buffer-substring-no-properties (point) (point-max)))
               (org-get-heading t))))))
    (setq text
          (string-trim
           (org-link-display-format
            (replace-regexp-in-string
             "\\[\\[\\(?:file\\|attachment\\):[^]\n]*\\]\\]" "" text))))
    (when (string-empty-p text)
      (user-error "Card %s has no text to speak" (if front "Front" "name")))
    (funcall zr-org-srs-review-tts-function text)))

(defun zr-org-srs-review--context-menu (menu _click)
  "Add the Org-srs TTS submenu to context MENU."
  (when (bound-and-true-p org-srs-review-item)
    (define-key-after menu [org-srs]
      '(menu-item "org-srs"
                  (keymap
                   (tts-title menu-item "TTS title" zr-org-srs-review-tts)
                   (tts-front menu-item "TTS front" zr-org-srs-review-tts-front)
                   (auto-tts menu-item "Auto TTS" zr-org-srs-review-auto-tts-mode
                             :button (toggle . zr-org-srs-review-auto-tts-mode))))))
  menu)

(defun zr-org-srs-review--context-menu-remove ()
  "Remove the Org-srs context menu from the current review buffer."
  (remove-hook 'context-menu-functions #'zr-org-srs-review--context-menu t))

(defun zr-org-srs-review--context-menu-add (&rest _)
  "Add the TTS context menu to the current review buffer."
  (when (and (bound-and-true-p org-srs-review-item)
             (not (memq #'zr-org-srs-review--context-menu context-menu-functions)))
    (add-hook 'context-menu-functions #'zr-org-srs-review--context-menu nil t)
    ;; A session can move between deck buffers; quitting skips finish-hook.
    (org-srs-review-add-hook-once
     'org-srs-review-continue-hook #'zr-org-srs-review--context-menu-remove 30)))

(with-eval-after-load 'org-srs-review
  (add-hook 'org-srs-review-start-hook #'zr-org-srs-review--context-menu-add)
  (add-hook 'org-srs-item-before-review-hook #'zr-org-srs-review--context-menu-add)
  (add-hook 'org-srs-review-finish-hook #'zr-org-srs-review--context-menu-remove))

;;;###autoload
(define-minor-mode zr-org-srs-review-auto-tts-mode
  "Speak the current card after confirmation in this buffer.
`zr-org-srs-review-auto-tts-function' selects what to speak (default: title).
Only this buffer's `org-srs-item-after-confirm-hook' is changed.
Playback errors are reported without interrupting the review."
  :lighter " SRS-TTS"
  :group 'zr-org-srs-review
  (if zr-org-srs-review-auto-tts-mode
      (add-hook 'org-srs-item-after-confirm-hook #'zr-org-srs-review--auto-tts nil t)
    (remove-hook 'org-srs-item-after-confirm-hook #'zr-org-srs-review--auto-tts t)))

;;;###autoload
(put 'zr-org-srs-review-auto-tts-mode 'safe-local-variable #'booleanp)

(defun zr-org-srs-review--auto-tts (&rest _)
  "Speak the current review card without interrupting confirmation."
  (when (and zr-org-srs-review-auto-tts-mode
             (derived-mode-p 'org-mode)
             (bound-and-true-p org-srs-review-item)
             (org-srs-reviewing-p))
    (condition-case err
        (funcall zr-org-srs-review-auto-tts-function)
      (error (message "Org-srs TTS: %s" (error-message-string err))))))

(defun zr-org-srs-review--ensure-review ()
  "Load Org-srs and require an active review in the current Org buffer."
  (require 'org-srs)
  (unless (and (derived-mode-p 'org-mode)
               (bound-and-true-p org-srs-review-item)
               (org-srs-reviewing-p))
    (user-error "Start an Org-srs review first")))

(defun zr-org-srs-review--confirm-pending-p ()
  "Return non-nil while the current item awaits confirmation."
  (org-srs-item-confirm-pending-p))

(defun zr-org-srs-review--undo-empty-p ()
  "Return non-nil when there is no rating to undo."
  (not (and (bound-and-true-p org-srs-review-undo-history)
            (org-srs-review-undo-history-undo org-srs-review-undo-history))))

(defun zr-org-srs-review--redo-empty-p ()
  "Return non-nil when there is no rating to redo."
  (not (and (bound-and-true-p org-srs-review-undo-history)
            (org-srs-review-undo-history-redo org-srs-review-undo-history))))

(defun zr-org-srs-review--call (command &optional rating)
  "Call review COMMAND and reopen the panel if review remains active.
When RATING is non-nil, require the answer to have been revealed first.
Suffixes exit the old transient before calling this function so a finished
review, an error, or a switch of deck buffers cannot leave a stale panel."
  (zr-org-srs-review--ensure-review)
  (unwind-protect
      (progn
        (when (and rating (zr-org-srs-review--confirm-pending-p))
          (user-error "Reveal the answer before rating"))
        ;; Suspending comments the heading at point, unlike rating commands
        ;; which locate the item themselves.  Point may be on a subheading.
        (when (eq command #'org-srs-review-suspend)
          (goto-char (apply #'org-srs-item-marker org-srs-review-item))
          (org-back-to-heading t))
        (call-interactively command))
    (when (and (bound-and-true-p org-srs-review-item)
               (org-srs-reviewing-p))
      (zr-org-srs-review-menu))))

(transient-define-suffix zr-org-srs-review-confirm ()
  "Reveal the answer or advance one step of the current review item."
  (interactive)
  (zr-org-srs-review--ensure-review)
  (unless (zr-org-srs-review--confirm-pending-p)
    (user-error "The answer is already revealed"))
  (zr-org-srs-review--call #'org-srs-item-confirm-command))

(transient-define-suffix zr-org-srs-review-rate-again ()
  "Rate the current item Again and keep reviewing with the panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-rate-again t))

(transient-define-suffix zr-org-srs-review-rate-hard ()
  "Rate the current item Hard and keep reviewing with the panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-rate-hard t))

(transient-define-suffix zr-org-srs-review-rate-good ()
  "Rate the current item Good and keep reviewing with the panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-rate-good t))

(transient-define-suffix zr-org-srs-review-rate-easy ()
  "Rate the current item Easy and keep reviewing with the panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-rate-easy t))

(transient-define-suffix zr-org-srs-review-undo ()
  "Undo the previous rating and reopen the review panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-undo))

(transient-define-suffix zr-org-srs-review-redo ()
  "Redo the previous rating and reopen the review panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-undo-redo))

(transient-define-suffix zr-org-srs-review-postpone ()
  "Choose a later due date and continue reviewing with the panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-postpone))

(transient-define-suffix zr-org-srs-review-suspend ()
  "Suspend the current item and continue reviewing with the panel."
  (interactive)
  (zr-org-srs-review--call #'org-srs-review-suspend))

(transient-define-suffix zr-org-srs-review-tts-front ()
  "Speak the current card's Front text."
  :transient t
  (interactive)
  (zr-org-srs-review-tts t))

;;;###autoload (autoload 'zr-org-srs-review-menu "zr-org-srs-review" "Open the Org-srs keyboard review panel." t)
(transient-define-prefix zr-org-srs-review-menu ()
  "Open the single-key command panel for the current Org-srs review.
SPC reveals the answer; 1/2/3/4 rate it Easy/Good/Hard/Again.
q hides the panel so the card can be edited; Q quits the review."
  :transient-suffix 'transient--do-exit
  :refresh-suffixes t
  [["Answer / rating"
    ("SPC" "Reveal / continue" zr-org-srs-review-confirm
     :inapt-if-not zr-org-srs-review--confirm-pending-p)
    ("1" "Easy" zr-org-srs-review-rate-easy :inapt-if zr-org-srs-review--confirm-pending-p)
    ("2" "Good" zr-org-srs-review-rate-good :inapt-if zr-org-srs-review--confirm-pending-p)
    ("3" "Hard" zr-org-srs-review-rate-hard :inapt-if zr-org-srs-review--confirm-pending-p)
    ("4" "Again" zr-org-srs-review-rate-again :inapt-if zr-org-srs-review--confirm-pending-p)]
   ["Review"
    ("u" "Undo rating" zr-org-srs-review-undo :inapt-if zr-org-srs-review--undo-empty-p)
    ("U" "Redo rating" zr-org-srs-review-redo :inapt-if zr-org-srs-review--redo-empty-p)
    ("p" "Postpone" zr-org-srs-review-postpone)
    ("s" "Suspend item" zr-org-srs-review-suspend)]
   ["Card"
    ("t" "Speak title" zr-org-srs-review-tts :transient t)
    ("T" "Speak Front" zr-org-srs-review-tts-front)
    ("v" "Scroll down" scroll-up-command :transient t)
    ("V" "Scroll up" scroll-down-command :transient t)]
   ["Panel"
    ("q" "Hide / edit card" transient-quit-one)
    ("Q" "Quit review" org-srs-review-quit)]]
  (interactive)
  (zr-org-srs-review--ensure-review)
  (transient-setup 'zr-org-srs-review-menu))

;;;###autoload
(define-minor-mode zr-org-srs-review-menu-mode
  "Open the keyboard panel automatically when an Org-srs review starts.
This global mode sets `org-srs-item-confirm' to
`org-srs-item-confirm-command' and installs a review hook."
  :global t
  :group 'zr-org-srs-review
  (if zr-org-srs-review-menu-mode
      (progn
        (setq org-srs-item-confirm #'org-srs-item-confirm-command)
        (add-hook 'org-srs-review-start-hook #'zr-org-srs-review-menu 90))
    (remove-hook 'org-srs-review-start-hook #'zr-org-srs-review-menu)))

(provide 'zr-org-srs-review)
;;; zr-org-srs-review.el ends here
