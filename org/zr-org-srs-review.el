;;; zr-org-srs-review.el --- Review mode and menus for Org-srs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1") (org-srs "0.1") (transient "0.7"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `zr-org-srs-review-menu' during an Org-srs review to open a
;; persistent keyboard panel.  SPC reveals the answer; 1/2/3/4 rate it
;; Easy/Good/Hard/Again.  Rating is disabled while confirmation is pending,
;; including intermediate steps of cloze items.  Review actions reopen
;; the panel on the next item, even when it belongs to another buffer.
;; q hides the panel and makes the card writable; Q ends the review.
;; Enable `zr-org-srs-review-mode' to protect the buffer from edits and
;; show a clickable SRS lighter.  Its native popup menu shares the panel's
;; review, card and panel actions.  The mode follows the current card
;; across deck buffers, without opening the keyboard panel automatically.
;; It selects command-based confirmation buffer-locally.
;; `zr-org-srs-review-start' reviews `zr-org-srs-directory'.
;; Org buffers have a context menu toggle for the review mode.
;; TTS speaks the title or Front through Termux or Windows.  Enable
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
(defvar zr-org-srs-review-mode)
(defvar zr-org-srs-review--following nil
  "Non-nil while a review operation or continuation carries review mode.")

(defvar-local zr-org-srs-review--saved-state nil
  "Read-only state and local confirmation setting before review mode.")

(defvar-local zr-org-srs-review--continue-hook nil
  "One-shot hook that leaves this card and prepares to follow the next.")

(defgroup zr-org-srs-review nil
  "Review mode, commands, TTS and menus for Org-srs items."
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
  ;; A directory review can start in a different deck from this buffer.
  (let ((zr-org-srs-review--following zr-org-srs-review-mode))
    (when zr-org-srs-review-mode (zr-org-srs-review-mode -1))
    (unwind-protect
        (org-srs-review-start (expand-file-name zr-org-srs-directory))
      (zr-org-srs-review--clear-following))))

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
  "Add a review mode toggle to context MENU."
  (define-key-after menu [zr-org-srs-review-mode]
    '(menu-item "SRS review mode" zr-org-srs-review-mode
                :button (toggle . zr-org-srs-review-mode)))
  menu)

(defun zr-org-srs-review--context-menu-setup ()
  "Register the review context menu callback in the current Org buffer."
  (add-hook 'context-menu-functions #'zr-org-srs-review--context-menu nil t))

(add-hook 'org-mode-hook #'zr-org-srs-review--context-menu-setup)

;; The library may be loaded after deck buffers have entered Org mode.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'org-mode)
      (zr-org-srs-review--context-menu-setup))))

;;;###autoload
(define-minor-mode zr-org-srs-review-auto-tts-mode
  "Speak the current card after confirmation in this buffer.
`zr-org-srs-review-auto-tts-function' selects what to speak (default: title).
Only this buffer's `org-srs-item-after-confirm-hook' is changed.
Playback errors are reported without interrupting the review."
  :lighter nil
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

(defun zr-org-srs-review--active-p ()
  "Return non-nil while this buffer has an active review item."
  (and (bound-and-true-p org-srs-review-item) (org-srs-reviewing-p)))

(defun zr-org-srs-review--call-writable (function &rest args)
  "Call FUNCTION with ARGS allowing review writes, then restore protection.
Undo and redo can also write a previous deck, so allow those writes with
`inhibit-read-only'.  Restore the origin after the dynamic binding ends:
the command may have disabled or transferred its review mode meanwhile."
  (let ((buffer (current-buffer))
        (read-only (if zr-org-srs-review-mode
                       (car zr-org-srs-review--saved-state)
                     buffer-read-only)))
    (unwind-protect
        (let ((buffer-read-only nil)
              (inhibit-read-only t)
              (zr-org-srs-review--following
               (or zr-org-srs-review--following zr-org-srs-review-mode)))
          (apply function args))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (if zr-org-srs-review-mode
              (progn
                (setcar zr-org-srs-review--saved-state read-only)
                (setq buffer-read-only t))
            (setq buffer-read-only read-only))))
      (zr-org-srs-review--clear-following))))

(defun zr-org-srs-review--rate (function &rest args)
  "Allow Org-srs rating FUNCTION with ARGS to write in review mode.
This also covers Org-srs mouse buttons and its own rating commands."
  (if zr-org-srs-review-mode
      (apply #'zr-org-srs-review--call-writable function args)
    (apply function args)))

(with-eval-after-load 'org-srs-review-rate
  (advice-add 'org-srs-review-rate :around #'zr-org-srs-review--rate))

(defun zr-org-srs-review--clear-following ()
  "Clear pending review mode transfer, including after command errors."
  (setq zr-org-srs-review--following nil)
  (remove-hook 'pre-command-hook #'zr-org-srs-review--clear-following)
  (remove-hook 'post-command-hook #'zr-org-srs-review--clear-following))

(defun zr-org-srs-review--finish ()
  "Clear transfer state and restore an empty review buffer."
  (zr-org-srs-review--clear-following)
  (when (and zr-org-srs-review-mode
             (not (bound-and-true-p org-srs-review-item)))
    (zr-org-srs-review-mode -1)))

(with-eval-after-load 'org-srs-review
  (add-hook 'org-srs-item-before-review-hook #'zr-org-srs-review--prepare -90)
  (add-hook 'org-srs-review-finish-hook #'zr-org-srs-review--finish -90))

(defun zr-org-srs-review--call (command &optional rating)
  "Call review COMMAND, reopening the panel when invoked from it.
When RATING is non-nil, require the answer to have been revealed first.
Suffixes exit the old transient before calling this function so a finished
review, an error, or a switch of deck buffers cannot leave a stale panel."
  (zr-org-srs-review--ensure-review)
  (let ((panel (eq transient-current-command 'zr-org-srs-review-menu)))
    (unwind-protect
        (progn
          (when (and rating (zr-org-srs-review--confirm-pending-p))
            (user-error "Reveal the answer before rating"))
          ;; Suspending comments the heading at point, unlike rating commands
          ;; which locate the item themselves.  Point may be on a subheading.
          (when (eq command #'org-srs-review-suspend)
            (goto-char (apply #'org-srs-item-marker org-srs-review-item))
            (org-back-to-heading t))
          (zr-org-srs-review--call-writable #'call-interactively command))
      (when (and panel (zr-org-srs-review--active-p))
        (zr-org-srs-review-menu)))))

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

(transient-define-suffix zr-org-srs-review-edit ()
  "Hide the keyboard panel and make the current card writable."
  :transient 'transient--do-quit-one
  (interactive)
  (setq buffer-read-only nil))

(transient-define-suffix zr-org-srs-review-quit ()
  "End the current Org-srs review, allowing pending cleanup writes."
  (interactive)
  (zr-org-srs-review--ensure-review)
  (zr-org-srs-review--call-writable #'org-srs-review-quit))

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
    ("a" "Auto TTS" zr-org-srs-review-auto-tts-mode :transient t)]
   ["Panel"
    ("q" "Hide / edit card" zr-org-srs-review-edit)
    ("Q" "Quit review" zr-org-srs-review-quit)]]
  (interactive)
  (zr-org-srs-review--ensure-review)
  (when zr-org-srs-review-mode (setq buffer-read-only t))
  (transient-setup 'zr-org-srs-review-menu))

(defun zr-org-srs-review--popup-menu-map ()
  "Build a native menu from the keyboard panel's non-rating groups."
  (let ((menu (make-sparse-keymap "Org-srs"))
        (active (zr-org-srs-review--active-p)))
    (dolist (group (cdr (aref (transient-get-suffix 'zr-org-srs-review-menu '(0)) 2)))
      (dolist (suffix (aref group 2))
        (let* ((args (cdr suffix))
               (command (plist-get args :command))
               (inapt (plist-get args :inapt-if))
               (enabled (and active (not (and inapt (funcall inapt))))))
          (define-key-after menu (vector command)
            `(menu-item ,(plist-get args :description) ,command
                        :enable ,enabled
                        ,@(when (eq command 'zr-org-srs-review-auto-tts-mode)
                            '(:button (toggle . zr-org-srs-review-auto-tts-mode))))))))
    menu))

;;;###autoload
(defun zr-org-srs-review-popup-menu (&optional event)
  "Open the native review menu at EVENT, or at point.
For a mode-line click, operate on the clicked window's buffer."
  (interactive (list last-input-event))
  (when (mouse-event-p event)
    (let ((window (posn-window (event-start event))))
      (when (windowp window) (select-window window))))
  (popup-menu (zr-org-srs-review--popup-menu-map)
              (if (mouse-event-p event) event (posn-at-point))))

;; Apply properties during rendering to override the enclosing minor-mode
;; defaults, which would overwrite properties on a pre-propertized string.
(defconst zr-org-srs-review--lighter
  (list :propertize " SRS"
        'mouse-face 'mode-line-highlight
        'help-echo "mouse-1: Org-srs review menu"
        'local-map (let ((map (make-sparse-keymap)))
                     (define-key map [mode-line down-mouse-1] #'zr-org-srs-review-popup-menu)
                     (define-key map [mode-line mouse-1] #'ignore)
                     map))
  "Clickable review mode lighter construct.")

;; Mode-line symbol values otherwise discard the lighter's mouse properties.
(put 'zr-org-srs-review--lighter 'risky-local-variable t)

(defun zr-org-srs-review--continue ()
  "Leave this card before Org-srs starts the next item at depth 50."
  (let ((following (and zr-org-srs-review-mode (org-srs-reviewing-p))))
    (setq zr-org-srs-review--continue-hook nil)
    (when zr-org-srs-review-mode (zr-org-srs-review-mode -1))
    (when following
      (setq zr-org-srs-review--following t)
      ;; Normally the next item or finish hook clears this immediately.
      ;; Command boundaries also clear it if queue selection signals.
      (add-hook 'pre-command-hook #'zr-org-srs-review--clear-following)
      (add-hook 'post-command-hook #'zr-org-srs-review--clear-following))))

(defun zr-org-srs-review--prepare (&rest _)
  "Protect this review item and arrange to follow the next card."
  (when (and (or zr-org-srs-review-mode zr-org-srs-review--following)
             (bound-and-true-p org-srs-review-item))
    (zr-org-srs-review--clear-following)
    (unless zr-org-srs-review-mode (zr-org-srs-review-mode 1))
    (setq buffer-read-only t)
    (unless zr-org-srs-review--continue-hook
      (setq zr-org-srs-review--continue-hook
            (org-srs-review-add-hook-once
             'org-srs-review-continue-hook #'zr-org-srs-review--continue 30)))))

;;;###autoload
(define-minor-mode zr-org-srs-review-mode
  "Protect the current Org review buffer and show a clickable SRS lighter.
The lighter opens a native menu; the keyboard panel remains available
through `zr-org-srs-review-menu'.  Cards are read-only until the panel's
Hide / edit card action is used.  Rating commands allow temporary writes.
The mode follows the current card across buffers within a review session,
restoring each buffer's previous settings when leaving it or disabling.
Command-based confirmation is selected only in this buffer."
  :lighter zr-org-srs-review--lighter
  :group 'zr-org-srs-review
  (if zr-org-srs-review-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (setq zr-org-srs-review-mode nil)
          (user-error "This mode requires an Org buffer"))
        (unless zr-org-srs-review--saved-state
          (setq zr-org-srs-review--saved-state
                (list buffer-read-only
                      (local-variable-p 'org-srs-item-confirm)
                      (bound-and-true-p org-srs-item-confirm))))
        (setq buffer-read-only t)
        (setq-local org-srs-item-confirm #'org-srs-item-confirm-command)
        (zr-org-srs-review--prepare))
    (when (and zr-org-srs-review--continue-hook
               (local-variable-p 'org-srs-review-continue-hook))
      (remove-hook 'org-srs-review-continue-hook zr-org-srs-review--continue-hook t))
    (setq zr-org-srs-review--continue-hook nil)
    (when zr-org-srs-review--saved-state
      (setq buffer-read-only (nth 0 zr-org-srs-review--saved-state))
      (if (nth 1 zr-org-srs-review--saved-state)
          (setq-local org-srs-item-confirm (nth 2 zr-org-srs-review--saved-state))
        (kill-local-variable 'org-srs-item-confirm))
      (setq zr-org-srs-review--saved-state nil))))

(provide 'zr-org-srs-review)
;;; zr-org-srs-review.el ends here
