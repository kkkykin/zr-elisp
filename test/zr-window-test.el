;;; zr-window-test.el --- Tests for Follow columns -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-window)

(defmacro zr-window-test--with-buffer (&rest body)
  "Run BODY with a temporary buffer displayed in a single real window."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (with-temp-buffer
       (unwind-protect
           (progn
             (switch-to-buffer (current-buffer))
             (delete-other-windows)
             (dotimes (i 100) (insert (format "Line %03d\n" i)))
             (goto-char (point-min))
             ,@body)
         (when follow-mode (follow-mode -1))))))

(ert-deftest zr-window-test-invalid-fill-column-preserves-layout ()
  (zr-window-test--with-buffer
    (split-window-right)
    (let ((configuration (window-state-get)))
      (dolist (value '(0 -1 nil))
        (setq-local fill-column value)
        (should-error (zr-window-follow-columns '(4)) :type 'user-error)
        (should (equal configuration (window-state-get)))
        (should-not follow-mode)))))

(ert-deftest zr-window-test-failed-split-restores-layout ()
  (zr-window-test--with-buffer
    (split-window-right)
    (setq-local fill-column 20)
    (let ((configuration (window-state-get))
          (split (symbol-function 'split-window))
          (calls 0))
      (cl-letf (((symbol-function 'split-window)
                 (lambda (&rest args)
                   (if (= (cl-incf calls) 2)
                       (error "Cannot split this window")
                     (apply split args)))))
        (should-error (zr-window-follow-columns '(4))))
      (should (= calls 2))
      (should (equal configuration (window-state-get)))
      (should-not follow-mode))))

(ert-deftest zr-window-test-measures-text-width-with-margins ()
  (zr-window-test--with-buffer
    (set-window-margins nil 3 4)
    (setq-local fill-column (ceiling (window-max-chars-per-line) 2))
    ;; Two columns fit by total width, but their repeated margins do not.
    (should (= (length (zr-window-arrange-follow-columns)) 1))
    (setq-local fill-column (/ (window-max-chars-per-line) 3))
    (let ((windows (zr-window-arrange-follow-columns)))
      (should (= (length windows) 2))
      (dolist (window windows)
        (should (>= (window-max-chars-per-line window) fill-column)))
      (should-not follow-mode))))

(ert-deftest zr-window-test-distributes-width-and-keeps-narrow-window ()
  (zr-window-test--with-buffer
    (setq-local fill-column 25)
    (let* ((windows (zr-window-arrange-follow-columns))
           (widths (mapcar #'window-total-width windows)))
      (should (= (length windows) 3))
      (should (<= (- (apply #'max widths) (apply #'min widths)) 1))
      (dolist (window windows)
        (should (>= (window-max-chars-per-line window) fill-column))))
    (setq-local fill-column 1000)
    (should (= (length (zr-window-arrange-follow-columns '(4))) 1))
    (should-not follow-mode)))

(ert-deftest zr-window-test-reuses-columns-and-prefix-rebuilds-layout ()
  (zr-window-test--with-buffer
    (let ((other-buffer (generate-new-buffer " *window-follow-unrelated*"))
          (other (split-window nil nil 'below))
          (enabled 0))
      (unwind-protect
          (progn
            (set-window-buffer other other-buffer)
            (split-window-right)
            (setq-local fill-column 5)
            (let ((windows (follow-all-followers))
                  (configuration (window-state-get)))
              (should (equal windows (zr-window-arrange-follow-columns)))
              (should (equal configuration (window-state-get)))
              (let ((follow-mode-hook (list (lambda () (cl-incf enabled)))))
                (zr-window-follow-columns)
                (zr-window-follow-columns))
              (should follow-mode)
              (should (= enabled 1))
              (should (equal windows (follow-all-followers)))
              (should (eq (window-buffer other) other-buffer)))
            (setq-local fill-column 25)
            (zr-window-follow-columns '(4))
            (should-not (get-buffer-window other-buffer))
            (should (= (length (follow-all-followers)) 3)))
        (kill-buffer other-buffer)))))

(provide 'zr-window-test)
;;; zr-window-test.el ends here
