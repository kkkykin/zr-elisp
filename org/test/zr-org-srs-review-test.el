;;; zr-org-srs-review-test.el --- Tests for the Org-srs keyboard panel -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org-srs-review)

(defun zr-org-srs-review-test--require-srs ()
  "Load installed Org-srs dependencies without personal init files."
  (let* ((elpa (expand-file-name "elpa" user-emacs-directory))
         (load-path (append
                     (when (file-directory-p elpa)
                       (directory-files elpa t "\\`\\(?:org-srs\\|fsrs\\)-"))
                     load-path)))
    (unless (require 'org-srs nil t)
      (ert-skip "org-srs is not installed"))))

(defun zr-org-srs-review-test--insert-card (card id)
  "Insert a real Org-srs CARD with ID in the current buffer."
  (let ((start (point)))
    (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\n** Front\n%s\n** Back\n%s\n"
                    (alist-get 'name card) id
                    (alist-get 'front card) (alist-get 'back card)))
    (goto-char start)
    (org-srs-item-new 'card)))

(defun zr-org-srs-review-test--card (buffer id)
  "Create a real Org-srs card with ID in BUFFER."
  (with-current-buffer buffer
    (org-mode)
    (zr-org-srs-review-test--insert-card
     `((name . ,id) (front . "Question") (back . "Answer")) id)))

(defmacro zr-org-srs-review-test--with-review (&rest body)
  "Run BODY with two card buffers and a deterministic review queue.
Only queue selection and child-frame geometry are replaced; commands,
confirmation, scheduling, undo history and transient key dispatch are real."
  (declare (indent 0) (debug t))
  `(progn
     (zr-org-srs-review-test--require-srs)
     (save-window-excursion
       (let ((first (generate-new-buffer " *srs-first*"))
             (second (generate-new-buffer " *srs-second*"))
             (org-srs-item-confirm #'org-srs-item-confirm-read-key)
             (org-srs-review-start-hook (copy-sequence org-srs-review-start-hook))
             (zr-org-srs-review-menu-mode nil)
             (transient-show-popup t)
             pending)
         (cl-letf (((symbol-function 'org-srs-review-pending-items)
                    (lambda (&optional _source)
                      (prog1 pending (setq pending (cdr pending)))))
                   ((symbol-function 'org-srs-ui-mouse-mode-update-panels) #'ignore))
           (unwind-protect
               (progn
                 (zr-org-srs-review-test--card first "first")
                 (zr-org-srs-review-test--card second "second")
                 (setq pending (list (list '(card back) "first" first)
                                     (list '(card back) "second" second)))
                 (switch-to-buffer first)
                 (zr-org-srs-review-menu-mode 1)
                 ,@body)
             (zr-org-srs-review-menu-mode -1)
             (when transient--prefix (transient--emergency-exit))
             (dolist (buffer (list first second))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (org-srs-reviewing-p) (org-srs-review-quit))
                   (set-buffer-modified-p nil))
                 (kill-buffer buffer)))))))))

(defun zr-org-srs-review-test--panel-p ()
  "Return non-nil when the keyboard panel is active."
  (and transient--prefix
       (eq (oref transient--prefix command) 'zr-org-srs-review-menu)))

(ert-deftest zr-org-srs-review-test-reveal-rate-switch-and-finish ()
  (zr-org-srs-review-test--with-review
    (should (eq org-srs-item-confirm #'org-srs-item-confirm-command))
    (org-srs-review-start 'fixture)
    (should (zr-org-srs-review-test--panel-p))
    (should (eq (window-buffer) first))
    (should (org-srs-item-confirm-pending-p))
    (should (oref (transient-suffix-object 'zr-org-srs-review-rate-good) inapt))
    (let ((contents (buffer-string)))
      (execute-kbd-macro (kbd "3"))
      (should (equal (buffer-string) contents)))
    (execute-kbd-macro (kbd "SPC"))
    (should-not (org-srs-item-confirm-pending-p))
    (should-not (oref (transient-suffix-object 'zr-org-srs-review-rate-good) inapt))
    (execute-kbd-macro (kbd "3"))
    (should (eq (current-buffer) second))
    (should (eq (window-buffer) second))
    (should (zr-org-srs-review-test--panel-p))
    (should (org-srs-item-confirm-pending-p))
    (with-current-buffer first
      (should-not (org-srs-reviewing-p))
      (should-not (buffer-narrowed-p)))
    ;; The user's finish hook opens history; the panel must let that buffer
    ;; remain selected after the final rating.
    (let ((org-srs-review-finish-hook
           (cons (lambda () (switch-to-buffer first)) org-srs-review-finish-hook)))
      (execute-kbd-macro (kbd "SPC 4")))
    (should (eq (current-buffer) first))
    (should-not (org-srs-reviewing-p))
    (should-not (zr-org-srs-review-test--panel-p))
    (should-not overriding-terminal-local-map)))

(ert-deftest zr-org-srs-review-test-hide-edit-reopen-and-quit ()
  (zr-org-srs-review-test--with-review
    (org-srs-review-start 'fixture)
    (execute-kbd-macro (kbd "q"))
    (should (org-srs-reviewing-p))
    (should-not (zr-org-srs-review-test--panel-p))
    (should-not overriding-terminal-local-map)
    (zr-org-srs-review-menu)
    (execute-kbd-macro (kbd "Q"))
    (should-not (org-srs-reviewing-p))
    (should-not (buffer-narrowed-p))
    (should-not (zr-org-srs-review-test--panel-p))
    (should-error (zr-org-srs-review-menu) :type 'user-error)))

(ert-deftest zr-org-srs-review-test-undo-redo-across-decks ()
  (zr-org-srs-review-test--with-review
    (org-srs-review-start 'fixture)
    (should (oref (transient-suffix-object 'zr-org-srs-review-undo) inapt))
    (let ((original (buffer-string)))
      (execute-kbd-macro (kbd "SPC 3"))
      (should (eq (current-buffer) second))
      (should-not (oref (transient-suffix-object 'zr-org-srs-review-undo) inapt))
      (let ((rated (with-current-buffer first (buffer-string))))
        (should-not (equal original rated))
        (setq pending (list (list '(card back) "first" first)))
        (execute-kbd-macro (kbd "u"))
        (should (eq (current-buffer) first))
        (should (equal (buffer-string) original))
        (should (zr-org-srs-review-test--panel-p))
        (should-not (oref (transient-suffix-object 'zr-org-srs-review-redo) inapt))
        (setq pending (list (list '(card back) "second" second)))
        (execute-kbd-macro (kbd "U"))
        (should (eq (current-buffer) second))
        (should (zr-org-srs-review-test--panel-p))
        (with-current-buffer first (should (equal (buffer-string) rated)))))))

(ert-deftest zr-org-srs-review-test-postpone-cancel-and-suspend-at-subheading ()
  (zr-org-srs-review-test--with-review
    (org-srs-review-start 'fixture)
    (let ((contents (buffer-string)))
      (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) (signal 'quit nil))))
        (condition-case nil (execute-kbd-macro (kbd "p")) (quit nil)))
      (should (equal (buffer-string) contents))
      (should (zr-org-srs-review-test--panel-p)))
    (cl-letf (((symbol-function 'org-read-date)
               (lambda (&rest _)
                 (time-convert (org-srs-time+ (org-srs-time-now) 2 :day) 'list))))
      (execute-kbd-macro (kbd "p")))
    (should (eq (current-buffer) second))
    (should (zr-org-srs-review-test--panel-p))
    (goto-char (point-max))
    (execute-kbd-macro (kbd "s"))
    (should-not (org-srs-reviewing-p))
    (should-not (zr-org-srs-review-test--panel-p))
    (goto-char (point-min))
    (should (org-in-commented-heading-p))
    (should (looking-at "\\* COMMENT second"))))

(ert-deftest zr-org-srs-review-test-repeated-confirmation ()
  (zr-org-srs-review-test--with-review
    ;; A pending confirmation may register another step before rating is
    ;; allowed, as with custom review methods.
    (org-srs-review-start 'fixture)
    (org-srs-item-add-hook-once
     'org-srs-item-after-confirm-hook
     (lambda (&rest args) (apply #'org-srs-item-confirm-command args)) 80)
    (execute-kbd-macro (kbd "SPC"))
    (should (org-srs-item-confirm-pending-p))
    (should (oref (transient-suffix-object 'zr-org-srs-review-rate-good) inapt))
    (execute-kbd-macro (kbd "SPC"))
    (should-not (org-srs-item-confirm-pending-p))
    (should-not (oref (transient-suffix-object 'zr-org-srs-review-rate-good) inapt))))

(ert-deftest zr-org-srs-review-test-cloze-reveal-and-rate ()
  (zr-org-srs-review-test--with-review
    (erase-buffer)
    (insert "* Cloze\n:PROPERTIES:\n:ID: cloze\n:END:\n{{1}{answer}{hint}}\n")
    (goto-char (point-min))
    (org-srs-item-new '(cloze 1))
    (setq pending (list (list '(cloze 1) "cloze" first)))
    (org-srs-review-start 'fixture)
    (let ((overlay (cl-find 'org-srs-item-cloze (overlays-in (point-min) (point-max))
                            :key (lambda (it) (overlay-get it 'category)))))
      (should overlay)
      (should (equal (overlay-get overlay 'display) "[...hint]"))
      (execute-kbd-macro (kbd "SPC"))
      (should (equal (overlay-get overlay 'display) "[answer]"))
      (should-not (org-srs-item-confirm-pending-p))
      (execute-kbd-macro (kbd "2"))
      (should-not (overlay-buffer overlay))
      (should-not (zr-org-srs-review-test--panel-p)))))

(ert-deftest zr-org-srs-review-test-tts-name-front-and-review-item ()
  (zr-org-srs-review-test--require-srs)
  (with-temp-buffer
    (org-mode)
    (zr-org-srs-review-test--insert-card
     '((name . "猫") (front . "猫です。\n[[file:screen.png]]\n[[https://example.org][例文]]")
       (back . "Answer must not be spoken")) 1)
    (goto-char (point-max))
    (zr-org-srs-review-test--insert-card '((name . "犬") (front . "犬です。") (back . "dog")) 2)
    (search-forward "dog")
    (let* ((position (point)) spoken
           (zr-org-srs-review-tts-function (lambda (text) (push text spoken))))
      (zr-org-srs-review-tts)
      (should (equal spoken '("犬")))
      (should (= (point) position))
      ;; The review item, rather than a moved point, selects the card.
      (setq-local org-srs-review-item (list '(card back) "1" (current-buffer)))
      (org-narrow-to-subtree)
      (let ((start (point-min)) (end (point-max)) (current-prefix-arg '(4)))
        (call-interactively #'zr-org-srs-review-tts)
        (should (equal (car spoken) "猫です。\n\n例文"))
        (should (= (point-min) start))
        (should (= (point-max) end)))
      (zr-org-srs-review-tts)
      (should (equal (car spoken) "猫")))))

(ert-deftest zr-org-srs-review-test-tts-empty-front-does-not-start-playback ()
  (zr-org-srs-review-test--require-srs)
  (with-temp-buffer
    (org-mode)
    (zr-org-srs-review-test--insert-card
     '((name . "猫") (front . "[[attachment:screen.png]]") (back . "cat")) 1)
    (let ((zr-org-srs-review-tts-function (lambda (_) (ert-fail "Empty text must not play"))))
      (should-error (zr-org-srs-review-tts t) :type 'user-error)
      (goto-char (point-min))
      (search-forward "[[attachment:screen.png]]")
      (replace-match "")
      (should-error (zr-org-srs-review-tts t) :type 'user-error))))

(ert-deftest zr-org-srs-review-test-tts-platform-dispatch ()
  (dolist (termux '("/termux/termux-tts-speak" nil))
    (let (spoken)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name) (when (equal name "termux-tts-speak") termux)))
                ((symbol-function 'zr-termux-tts-speak)
                 (lambda (text) (setq spoken (list 'termux text)) 'tts-process))
                ((symbol-function 'zr-windows-tts-speak)
                 (lambda (text) (setq spoken (list 'windows text)) 'tts-process)))
        (should (eq (zr-org-srs-review--tts-speak "猫") 'tts-process)))
      (should (equal spoken (list (if termux 'termux 'windows) "猫"))))))

(ert-deftest zr-org-srs-review-test-tts-works-with-ordinary-org-srs-ids ()
  (zr-org-srs-review-test--require-srs)
  (with-temp-buffer
    (org-mode)
    (zr-org-srs-review-test--insert-card
     '((name . "猫") (front . "猫です。") (back . "cat"))
     "3d4e6e45-781e-49b0-9498-3c405fef8fb3")
    (goto-char (point-max))
    (let* (spoken (zr-org-srs-review-tts-function (lambda (text) (push text spoken))))
      (zr-org-srs-review-tts)
      (zr-org-srs-review-tts t)
      (should (equal spoken '("猫です。" "猫"))))))

(ert-deftest zr-org-srs-review-test-panel-tts-keeps-review-active ()
  (zr-org-srs-review-test--with-review
    (let* (spoken (zr-org-srs-review-tts-function (lambda (text) (push text spoken))))
      (org-srs-review-start 'fixture)
      (execute-kbd-macro (kbd "t T"))
      (should (equal spoken '("Question" "first")))
      (should (org-srs-item-confirm-pending-p))
      (should (zr-org-srs-review-test--panel-p)))))

(ert-deftest zr-org-srs-review-test-start-uses-shared-directory ()
  (zr-org-srs-review-test--require-srs)
  (let ((zr-org-srs-directory "~/srs-shared"))
    (cl-letf (((symbol-function 'org-srs-review-start)
               (lambda (&optional source)
                 (should (equal source (expand-file-name zr-org-srs-directory))))))
      (zr-org-srs-review-start))))

(ert-deftest zr-org-srs-review-test-tool-bar-switch-quit-and-finish ()
  (zr-org-srs-review-test--with-review
    (require 'tool-bar)
    (zr-org-srs-review-menu-mode -1)
    (let ((global-tool-bar (default-value 'tool-bar-map))
          (local-tool-bar (make-sparse-keymap))
          finished)
      (with-current-buffer second
        (setq-local tool-bar-map local-tool-bar)
        (define-key tool-bar-map [existing] #'ignore))
      (let ((org-srs-review-finish-hook
             (cons (lambda () (setq finished t)) org-srs-review-finish-hook)))
        (org-srs-review-start 'fixture)
        (should (local-variable-p 'tool-bar-map))
        (should (eq (lookup-key tool-bar-map [zr-org-srs-review-tts]) #'zr-org-srs-review-tts))
        (should-not (lookup-key global-tool-bar [zr-org-srs-review-tts]))
        (org-srs-review-next)
        (should (eq (current-buffer) second))
        (should (eq (lookup-key tool-bar-map [existing]) #'ignore))
        (should (eq (lookup-key tool-bar-map [zr-org-srs-review-tts]) #'zr-org-srs-review-tts))
        (with-current-buffer first (should-not (local-variable-p 'tool-bar-map)))
        (org-srs-review-quit)
        (should (eq tool-bar-map local-tool-bar))
        (should-not zr-org-srs-review--tool-bar)
        (should-not finished)
        (setq pending (list (list '(card back) "first" first)))
        (org-srs-review-start 'fixture)
        (org-srs-review-next)
        (should finished)
        (should-not (local-variable-p 'tool-bar-map))
        (should (eq tool-bar-map global-tool-bar))))))

(provide 'zr-org-srs-review-test)
;;; zr-org-srs-review-test.el ends here
