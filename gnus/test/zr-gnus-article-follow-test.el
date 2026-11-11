;;; zr-gnus-article-follow-test.el --- Follow paging tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-gnus-article-follow)
(require 'zr-test-helpers)

(defconst zr-gnus-article-follow-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun zr-gnus-article-follow-test--article ()
  "Return the real Gnus session's selected article number."
  (buffer-local-value 'gnus-current-article (get-buffer gnus-summary-buffer)))

(defun zr-gnus-article-follow-test--end (&optional window _update)
  "Compute a window end without batch Emacs' missing redisplay."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char (window-start window))
        (vertical-motion (window-text-height window) window)
        (point)))))

(defun zr-gnus-article-follow-test--visible (&optional position window _partially)
  "Model complete visibility for the fixture's uniform text lines."
  (let* ((window (or window (selected-window)))
         (position (or position (point)))
         (end (zr-gnus-article-follow-test--end window)))
    (and (<= (window-start window) position)
         (or (< position end)
             (and (= position end (point-max))
                  (save-excursion
                    (goto-char (window-start window))
                    (< (vertical-motion (window-text-height window) window)
                       (window-text-height window))))))))

(defmacro zr-gnus-article-follow-test--with-display (&rest body)
  "Run BODY with window metrics suitable for batch Emacs."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'window-end)
              #'zr-gnus-article-follow-test--end)
             ((symbol-function 'pos-visible-in-window-p)
              #'zr-gnus-article-follow-test--visible)
             ((symbol-function 'follow-calc-win-end)
              (lambda (&optional window)
                (list (zr-gnus-article-follow-test--end window)
                      (zr-gnus-article-follow-test--visible (point-max) window))))
             ((symbol-function 'move-to-window-line)
              (lambda (arg)
                (goto-char (window-start))
                (vertical-motion (if (< arg 0)
                                     (+ (window-text-height) arg)
                                   arg)))))
     ,@body))

(defmacro zr-gnus-article-follow-test--with-columns (count &rest body)
  "Run BODY in COUNT real windows with emulated batch redisplay metrics."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *article-follow-test*"))
           (next-screen-context-lines 0))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (delete-other-windows)
             (dotimes (i 180) (insert (format "Line %03d\n" i)))
             (gnus-article-mode)
             (goto-char (point-min))
             (let ((window (selected-window))
                   (width (/ (window-total-width) ,count)))
               (dotimes (_ (1- ,count))
                 (setq window (split-window window width 'right))))
             ;; Only the display metrics are replaced.  Follow's alignment,
             ;; scrolling, real window state, and Gnus commands run normally.
             (zr-gnus-article-follow-test--with-display
               (zr-gnus-article-follow-mode 1)
               (follow-redisplay)
               ,@body))
         (with-current-buffer buffer
           (zr-gnus-article-follow-mode -1)
           (when follow-mode (follow-mode -1)))
         (kill-buffer buffer)))))

(ert-deftest zr-gnus-article-follow-test-entry-arranges-and-reuses-columns ()
  (zr-gnus-article-follow-test--with-columns 1
    (zr-gnus-article-follow-mode -1)
    (setq-local fill-column 30)
    (set-window-margins nil 3 4)
    (let ((other-buffer (generate-new-buffer " *follow-entry-unrelated*"))
          (other (split-window nil nil 'below)))
      (unwind-protect
          (progn
            (set-window-buffer other other-buffer)
            (zr-gnus-article-follow)
            (should zr-gnus-article-follow-mode)
            (should follow-mode)
            (should (eq (window-buffer other) other-buffer))
            (let* ((windows (follow-all-followers))
                   (widths (mapcar #'window-total-width windows)))
              (should (> (length windows) 1))
              (dolist (window windows)
                (should (>= (window-max-chars-per-line window) fill-column)))
              (should (= (window-end (car windows)) (window-start (cadr windows))))
              ;; Re-entering also preserves the current reading position.
              (zr-gnus-article-follow-next-page)
              (let ((starts (mapcar #'window-start windows)))
                (zr-gnus-article-follow)
                (should (equal windows (follow-all-followers)))
                (should (equal starts (mapcar #'window-start windows)))
                (should (equal widths (mapcar #'window-total-width windows)))))
            (zr-gnus-article-follow '(4))
            (should-not (get-buffer-window other-buffer))
            (should (> (length (follow-all-followers)) 1))
            (should (equal (follow-all-followers) (window-list)))
            (zr-gnus-article-follow-mode -1)
            (should-not follow-mode))
        (kill-buffer other-buffer)))))

(ert-deftest zr-gnus-article-follow-test-entry-narrow-window-and-invalid-width ()
  (with-temp-buffer
    (should-error (zr-gnus-article-follow) :type 'user-error))
  (zr-gnus-article-follow-test--with-columns 1
    (zr-gnus-article-follow-mode -1)
    (setq-local fill-column 0)
    (let ((configuration (window-state-get)))
      (should-error (zr-gnus-article-follow '(4)) :type 'user-error)
      (should-not zr-gnus-article-follow-mode)
      (should-not follow-mode)
      (should (equal configuration (window-state-get))))
    (setq-local fill-column 1000)
    (zr-gnus-article-follow)
    (should zr-gnus-article-follow-mode)
    (should (= (length (follow-all-followers)) 1))))

(ert-deftest zr-gnus-article-follow-test-mode-restores-follow-state ()
  (with-temp-buffer
    (should-error (zr-gnus-article-follow-mode 1) :type 'user-error)
    (should-not zr-gnus-article-follow-mode)
    (should-not follow-mode)
    (gnus-article-mode)
    (dolist (previous '(nil t))
      (when previous (follow-mode 1))
      (zr-gnus-article-follow-mode 1)
      (zr-gnus-article-follow-mode 1)
      (should follow-mode)
      (zr-gnus-article-follow-mode -1)
      (zr-gnus-article-follow-mode -1)
      (should (eq (not (null follow-mode)) previous))
      (should-not (local-variable-p 'zr-gnus-article-follow--previous-follow))
      (when follow-mode (follow-mode -1)))))

(ert-deftest zr-gnus-article-follow-test-three-columns-scroll-one-screen ()
  (zr-gnus-article-follow-test--with-columns 3
    (let* ((windows (follow-all-followers))
           (end (window-end (car (last windows))))
           (starts (mapcar #'window-start windows)))
      ;; Scroll from any column, rather than only the selected one.
      (select-window (cadr windows))
      (should-not (zr-gnus-article-follow-next-page))
      (should (= (window-start (car windows)) end))
      (should-not (zr-gnus-article-follow-prev-page))
      (should (equal (mapcar #'window-start windows) starts)))))

(ert-deftest zr-gnus-article-follow-test-last-column-can-finish-article ()
  (zr-gnus-article-follow-test--with-columns 3
    (let* ((windows (follow-all-followers))
           (first (car windows))
           selected-key)
      (goto-char (point-min))
      (forward-line 130)
      (set-window-start first (point))
      (follow-redisplay windows first)
      (should (< (window-end first) (point-max)))
      (should (pos-visible-in-window-p (point-max) (car (last windows))))
      (cl-letf (((symbol-function 'gnus-article-read-summary-keys)
                 (lambda (_event key) (setq selected-key key))))
        (zr-gnus-article-follow-next-page))
      (should (eq selected-key ?n)))))

(ert-deftest zr-gnus-article-follow-test-first-column-can-start-article ()
  (zr-gnus-article-follow-test--with-columns 3
    (let ((windows (follow-all-followers)) selected-key)
      (select-window (car (last windows)))
      (goto-char (window-start))
      (should-not (bobp))
      (cl-letf (((symbol-function 'gnus-article-read-summary-keys)
                 (lambda (_event key) (setq selected-key key))))
        (zr-gnus-article-follow-prev-page))
      (should (eq selected-key ?p)))))

(ert-deftest zr-gnus-article-follow-test-line-count-and-screen-context ()
  (zr-gnus-article-follow-test--with-columns 2
    (let ((next-screen-context-lines 2)
          (first (car (follow-all-followers))))
      (let ((expected (save-excursion
                        (goto-char (follow-window-end))
                        (vertical-motion -2)
                        (point))))
        (should-not (zr-gnus-article-follow-next-page))
        (should (= (window-start first) expected)))
      ;; The C scrolling commands also need a completed redisplay in batch.
      (cl-letf (((symbol-function 'scroll-up-command)
                 (lambda (lines)
                   (set-window-start nil (save-excursion
                                           (goto-char (window-start))
                                           (vertical-motion lines)
                                           (point)))))
                ((symbol-function 'scroll-down-command)
                 (lambda (lines)
                   (set-window-start nil (save-excursion
                                           (goto-char (window-start))
                                           (vertical-motion (- lines))
                                           (point))))))
        (let* ((start (window-start first))
               (expected (save-excursion
                           (goto-char start)
                           (forward-line 3)
                           (point))))
          (should-not (zr-gnus-article-follow-next-page 3))
          (should (= (window-start first) expected))
          (should-not (zr-gnus-article-follow-prev-page 3))
          (should (= (window-start first) start)))))))

(ert-deftest zr-gnus-article-follow-test-article-change-restores-columns ()
  (zr-gnus-article-follow-test--with-columns 2
    (let* ((buffer (current-buffer))
           (windows (follow-all-followers))
           (other (split-window (cadr windows) nil 'below))
           (other-buffer (generate-new-buffer " *follow-unrelated*")))
      (unwind-protect
          (progn
            (set-window-buffer other other-buffer)
            (zr-gnus-article-follow-next-page)
            (cl-letf (((symbol-function 'gnus-article-read-summary-keys)
                       (lambda (_event _key)
                         (delete-other-windows)
                         (with-current-buffer buffer
                           (let ((inhibit-read-only t))
                             (erase-buffer)
                             (dotimes (i 80) (insert (format "New article %03d\n" i))))
                           (setq-local gnus-article-current '(group . 2))))))
              (zr-gnus-article-follow--change-article ?n))
            (should (= (window-start (car windows)) (point-min)))
            (should (> (window-start (cadr windows)) (point-min)))
            (should (= (window-end (car windows)) (window-start (cadr windows))))
            (should (eq (window-buffer other) other-buffer)))
        (kill-buffer other-buffer)))))

(ert-deftest zr-gnus-article-follow-test-narrowed-pages-stay-in-article ()
  (zr-gnus-article-follow-test--with-columns 2
    (let ((gnus-article-buffer (current-buffer))
          (gnus-visual nil)
          (inhibit-read-only t))
      (erase-buffer)
      (dotimes (i 60) (insert (format "First page %03d\n" i)))
      (insert "\f\n")
      (dotimes (i 60) (insert (format "Second page %03d\n" i)))
      (goto-char (point-min))
      (gnus-narrow-to-page)
      (zr-gnus-article-follow--align)
      (let ((beginning (point-min))
            (end (point-max)))
        (should-not (zr-gnus-article-follow-next-page))
        (should-not (zr-gnus-article-follow-next-page))
        (should (> (point-min) end))
        (should (= (follow-window-start) (point-min)))
        (should-not (zr-gnus-article-follow-prev-page))
        (should (= (point-min) beginning))
        (should (= (point-max) end))
        (should (pos-visible-in-window-p end (car (last (follow-all-followers)))))
        (should (< (window-start (car (last (follow-all-followers)))) end))
        (should (< (follow-window-start) (window-start (car (last (follow-all-followers))))))))))

(ert-deftest zr-gnus-article-follow-test-article-change-error-restores-layout ()
  (zr-gnus-article-follow-test--with-columns 2
    (let ((windows (follow-all-followers)))
      (cl-letf (((symbol-function 'gnus-article-read-summary-keys)
                 (lambda (_event _key)
                   (delete-other-windows)
                   (error "Cannot select article"))))
        (should-error (zr-gnus-article-follow--change-article ?n)))
      (should (equal windows (follow-all-followers))))))

(ert-deftest zr-gnus-article-follow-test-local-keymap-keeps-gnus-functions ()
  (let* ((functions '(gnus-article-next-page gnus-article-prev-page
                      gnus-article-goto-next-page gnus-article-goto-prev-page
                      gnus-configure-windows gnus-article-read-summary-keys))
         (definitions (mapcar #'symbol-function functions)))
    (with-temp-buffer
      (gnus-article-mode)
      (let ((keys '("SPC" "DEL" "S-SPC" "C-v" "M-v"))
            (previous (mapcar (lambda (key) (key-binding (kbd key)))
                              '("SPC" "DEL" "S-SPC" "C-v" "M-v"))))
        (zr-gnus-article-follow-mode 1)
        (should (eq (key-binding (kbd "SPC")) #'zr-gnus-article-follow-next-page))
        (should (eq (key-binding (kbd "C-v")) #'zr-gnus-article-follow-next-page))
        (dolist (key '("DEL" "S-SPC" "M-v"))
          (should (eq (key-binding (kbd key)) #'zr-gnus-article-follow-prev-page)))
        (should (equal definitions (mapcar #'symbol-function functions)))
        (zr-gnus-article-follow-mode -1)
        (should (equal previous (mapcar (lambda (key) (key-binding (kbd key))) keys)))
        (should (equal definitions (mapcar #'symbol-function functions)))))))

(ert-deftest zr-gnus-article-follow-test-command-requires-visible-enabled-article ()
  (with-temp-buffer
    (should-error (zr-gnus-article-follow-next-page) :type 'user-error)
    (gnus-article-mode)
    (should-error (zr-gnus-article-follow-prev-page) :type 'user-error)
    (zr-gnus-article-follow-mode 1)
    (should-error (zr-gnus-article-follow-next-page) :type 'user-error)
    (fundamental-mode)
    (should-not zr-gnus-article-follow-mode)
    (should-not follow-mode)))

(ert-deftest zr-gnus-article-follow-test-gnus-mbox-article-changes ()
  ;; A fresh real Gnus session also exercises its hidden-summary key bridge,
  ;; article preparation, and window restoration without depending on EPUB.
  (zr-test-with-temp-directory
    (let* ((mailbox (expand-file-name "articles.mbox"))
           (root (file-name-directory (directory-file-name
                                       zr-gnus-article-follow-test--directory)))
           (workspace (file-name-directory (directory-file-name root))))
      (with-temp-file mailbox
        (dotimes (article 3)
          (insert (format "From sender@example.org Sat Jan  1 00:00:00 2022\nSubject: Article %d\nFrom: sender@example.org\nDate: Sat, 1 Jan 2022 00:00:00 +0000\nMessage-ID: <%d@example.org>\n\n"
                          (1+ article) (1+ article)))
          (dotimes (line 100) (insert (format "Article %d line %03d\n" (1+ article) line)))
          (insert "\n")))
      (dolist (setting '(never nil t))
        (with-temp-buffer
          (let* ((next (if (eq setting 'never) 2 3))
                 (form
                  `(progn
                     (require 'gnus)
                     (require 'gnus-group)
                     (require 'gnus-sum)
                     (require 'nndoc)
                     (require 'zr-gnus-article-follow-test)
                     (setq gnus-directory ,(expand-file-name "News")
                           gnus-home-directory ,default-directory
                           gnus-startup-file ,(expand-file-name ".newsrc")
                           gnus-init-file nil gnus-site-init-file nil
                           gnus-select-method '(nnnil "")
                           gnus-secondary-select-methods nil
                           gnus-use-dribble-file nil
                           gnus-save-newsrc-file nil
                           gnus-show-threads nil
                           ;; Only the summary's local setting should apply.
                           gnus-summary-goto-unread ',(if (eq setting 'never) t 'never))
                     (setq-default fill-column 30)
                     (gnus-no-server)
                     (gnus-group-read-ephemeral-group
                      "follow-test" '(nndoc ,mailbox (nndoc-article-type mbox)) t)
                     (with-current-buffer gnus-summary-buffer
                       (setq-local gnus-summary-goto-unread ',setting)
                       (gnus-summary-goto-subject 1 t)
                       (save-excursion (gnus-summary-mark-as-read 2 gnus-read-mark)))
                     (select-window (get-buffer-window gnus-summary-buffer))
                     (delete-other-windows)
                     (zr-gnus-article-follow-test--with-display
                       (zr-gnus-article-follow)
                       (should (derived-mode-p 'gnus-article-mode))
                       (should zr-gnus-article-follow-mode)
                       (should (= (zr-gnus-article-follow-test--article) 1))
                       (should (= (length (follow-all-followers)) 2))
                       (should (get-buffer-window gnus-summary-buffer))
                       (zr-gnus-article-follow '(4))
                       (let ((windows (follow-all-followers)))
                         (dotimes (_ 8)
                           (when (= (zr-gnus-article-follow-test--article) 1)
                             (zr-gnus-article-follow-next-page)))
                         (should (= (zr-gnus-article-follow-test--article) ,next))
                         (should (equal windows (follow-all-followers)))
                         (should-not (get-buffer-window gnus-summary-buffer))
                         (should (= (window-start (car windows)) (point-min)))
                         (should (> (window-start (cadr windows)) (point-min)))
                         (with-current-buffer gnus-summary-buffer
                           (unless (eq gnus-summary-goto-unread 'never)
                             (save-excursion
                               (gnus-summary-mark-article 1 gnus-unread-mark))))
                         (zr-gnus-article-follow-prev-page)
                         (should (= (zr-gnus-article-follow-test--article) 1))
                         (should (equal windows (follow-all-followers)))
                         (with-current-buffer gnus-summary-buffer
                           (save-excursion
                             (gnus-summary-mark-article 3 gnus-unread-mark)))
                         ;; Paging from a visible summary uses the same group.
                         (let ((summary-window (split-window (car windows) nil 'below)))
                           (set-window-buffer summary-window gnus-summary-buffer)
                           ;; Selecting another article from the summary keeps
                           ;; the layout but starts the new article at the top.
                           (zr-gnus-article-follow-next-page)
                           (should (> (window-start (car windows)) (point-min)))
                           (select-window summary-window)
                           (gnus-summary-goto-subject 2 t)
                           (zr-gnus-article-follow)
                           (should (= (zr-gnus-article-follow-test--article) 2))
                           (should (equal windows (follow-all-followers)))
                           (should (= (window-start (car windows)) (point-min)))
                           (should (eq (window-buffer summary-window)
                                       (get-buffer gnus-summary-buffer)))
                           (select-window summary-window)
                           (gnus-summary-goto-subject 1 t)
                           (zr-gnus-article-follow)
                           (should (= (zr-gnus-article-follow-test--article) 1))
                           (should (equal windows (follow-all-followers)))
                           (select-window (car windows))
                           (follow-redisplay)
                           (dotimes (_ 12)
                             (when (= (zr-gnus-article-follow-test--article) 1)
                               (with-selected-window summary-window
                                 (zr-gnus-article-follow-next-page))))
                           (should (= (zr-gnus-article-follow-test--article) ,next))
                           (should (equal windows (follow-all-followers (car windows)))))))
                     (princ "article-follow-integration-ok")))
                 (status (call-process invocation-name nil t nil "--batch" "-Q"
                                       "-L" workspace "-L" root
                                       "-L" (expand-file-name "test" workspace)
                                       "-L" zr-gnus-article-follow-test--directory
                                       "--eval" (prin1-to-string form))))
            (ert-info ((format "goto-unread=%S: %s" setting (buffer-string)))
              (should (eq status 0))
              (should (string-match-p "article-follow-integration-ok" (buffer-string))))))))))

(provide 'zr-gnus-article-follow-test)
;;; zr-gnus-article-follow-test.el ends here
