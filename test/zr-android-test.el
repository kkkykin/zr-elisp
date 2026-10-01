;;; zr-android-test.el --- Tests for zr-android -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-android)

(ert-deftest zr-android-test-toolbar-restores-maps ()
  (let* ((secondary-tool-bar-map (make-sparse-keymap))
         (input-decode-map (make-sparse-keymap))
         (original-toolbar secondary-tool-bar-map)
         (original-input input-decode-map)
         (modifier-bar-mode t)
         (modifier-bar-mode-hook nil))
    (unwind-protect
        (cl-letf (((symbol-function 'zr-android--gui) #'ignore))
          (zr-android-toolbar-mode 1)
          (zr-android-toolbar-mode 1)
          (should (lookup-key secondary-tool-bar-map [zr-keyboard]))
          (should (= (cl-count #'zr-android--toolbar modifier-bar-mode-hook) 1))
          (zr-android-toolbar-mode -1)
          (should (eq secondary-tool-bar-map original-toolbar))
          (should (eq input-decode-map original-input)))
      (zr-android-toolbar-mode -1))))

(provide 'zr-android-test)
;;; zr-android-test.el ends here
