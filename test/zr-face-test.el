;;; zr-face-test.el --- Tests for zr-face -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for font, theme and appearance commands, and for the
;; completion data they are driven by.  Nothing here needs a display.

;;; Code:

(require 'ert)
(require 'cl-lib)

(load (expand-file-name
       "../zr-face.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(declare-function zr-face--font-families "zr-face")
(declare-function zr-face--default-font-size "zr-face")
(declare-function zr-face--read-theme "zr-face")
(declare-function zr-face--spec-attrs "zr-face")
(declare-function zr-face-set-buffer-font "zr-face")
(declare-function zr-face-set-buffer-font-fallback "zr-face")
(declare-function zr-face-set-buffer-theme "zr-face")
(declare-function zr-face-set-frame-theme "zr-face")
(declare-function zr-face-frame-theme "zr-face")
(declare-function zr-face-buffer-match "zr-face")
(declare-function zr-face-buffer-setup "zr-face")
(declare-function zr-face-buffer-setup-all "zr-face")
(declare-function zr-face-buffer-mode "zr-face")

(defvar zr-face-font-available-alist)
(defvar zr-face-buffer-theme)
(defvar zr-face-buffer-font)
(defvar zr-face-buffer-alist)
(defvar zr-face-buffer-mode)

(ert-deftest zr-face-test-system-dark-mode-is-safe-in-terminal ()
  "Dark-mode detection returns a boolean without terminal capabilities."
  (let ((xterm-extra-capabilities nil))
    (should (booleanp (zr-face-system-dark-mode-enabled-p)))))

(ert-deftest zr-face-test-font-families-prefer-available ()
  "Fonts of `zr-face-font-available-alist' are offered before the rest."
  (let ((zr-face-font-available-alist '((default . (("Zr Preferred" . 14))))))
    (should (equal "Zr Preferred" (car (zr-face--font-families))))
    (should (equal 14 (zr-face--default-font-size "Zr Preferred"))))
  (let ((zr-face-font-available-alist nil))
    (should (equal 14 (zr-face--default-font-size "Zr Other")))))

(ert-deftest zr-face-test-set-buffer-font ()
  "The buffer font variant remaps the font of the `default' face."
  (with-temp-buffer
    (zr-face-set-buffer-font "Zr Mono" 14)
    (let* ((spec (car (alist-get 'default face-remapping-alist)))
           (font (plist-get spec :font)))
      (should (equal "Zr Mono" (format "%s" (font-get font :family))))
      (should (equal 14 (font-get font :size))))))

(ert-deftest zr-face-test-buffer-font-fallback-keeps-preference-order ()
  "The configured fallback order wins over the font-list order."
  (cl-letf (((symbol-function 'font-family-list)
             (lambda () '("UnifontExMono" "Unifont-JP"))))
    (with-temp-buffer
      (zr-face-set-buffer-font-fallback)
      (should (equal "Unifont-JP"
                     (plist-get (car (alist-get 'default face-remapping-alist))
                                :family))))))

(ert-deftest zr-face-test-terminal-appearance-setup-runs-once ()
  "A successful WezTerm update does not repeat on later hook calls."
  (let ((zr-face-appearance-should-setup-p t)
        (zr-face-appearance-wezterm-setup-p nil)
        (calls 0))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil))
              ((symbol-function 'getenv)
               (lambda (name) (and (equal name "TERM_PROGRAM") "WezTerm")))
              ((symbol-function 'zr-wezterm-send-json)
               (lambda (_) (setq calls (1+ calls)))))
      (zr-face-appearance-setup)
      (zr-face-appearance-setup))
    (should (= 1 calls))))

(ert-deftest zr-face-test-spec-attrs ()
  "Extracting attributes handles plists and display conditions."
  (should (equal '(:foreground "red")
                 (zr-face--spec-attrs '(:foreground "red"))))
  (should (equal '(:foreground "blue")
                 (zr-face--spec-attrs '((t (:foreground "blue"))))))
  (should (equal '(:inherit font-lock-comment-face :foreground "green")
                 (zr-face--spec-attrs '((default :inherit font-lock-comment-face)
                                        (t (:foreground "green")))))))

(ert-deftest zr-face-test-set-buffer-theme ()
  "Buffer theme remaps faces, switches cleanly, and resets."
  (with-temp-buffer
    (zr-face-set-buffer-theme 'adwaita)
    (should (eq zr-face-buffer-theme 'adwaita))
    (should (equal "#EDEDED"
                   (plist-get (car (alist-get 'default face-remapping-alist))
                              :background)))
    (zr-face-set-buffer-theme "wombat")
    (should (eq zr-face-buffer-theme 'wombat))
    (should (equal "#242424"
                   (plist-get (car (alist-get 'default face-remapping-alist))
                              :background)))
    (zr-face-set-buffer-font "Zr Mono" 14)
    (should (plist-get (car (alist-get 'default face-remapping-alist)) :font))
    (zr-face-set-buffer-theme 'default)
    (should (null zr-face-buffer-theme))
    (should (plist-get (car (alist-get 'default face-remapping-alist)) :font))))

(ert-deftest zr-face-test-set-frame-theme ()
  "Frame theme applies to frame, switches cleanly, and resets."
  (let ((frame (selected-frame)))
    (unwind-protect
        (progn
          (zr-face-set-frame-theme 'adwaita frame)
          (should (eq (zr-face-frame-theme frame) 'adwaita))
          (should (equal "#EDEDED" (face-attribute 'default :background frame)))
          (zr-face-set-frame-theme "wombat" frame)
          (should (eq (zr-face-frame-theme frame) 'wombat))
          (should (equal "#242424" (face-attribute 'default :background frame)))
          (zr-face-set-frame-theme 'default frame)
          (should (null (zr-face-frame-theme frame))))
      (zr-face-set-frame-theme 'default frame))))

(ert-deftest zr-face-test-read-theme-candidates ()
  "Theme completion candidates include default and available themes."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt collection &rest _args)
               (should (member 'default collection))
               (should (member 'adwaita collection))
               "adwaita")))
    (should (eq 'adwaita (zr-face--read-theme)))))

(ert-deftest zr-face-test-buffer-match-conditions ()
  "Buffer match supports regexps, derived-mode, functions, and precedence."
  (let ((zr-face-buffer-alist
         `((,(rx bos "*test-scratch*" eos) :theme adwaita)
           ((derived-mode . emacs-lisp-mode) :theme wombat)
           ((lambda (b) (string-prefix-p " *temp" (buffer-name b))) :theme tango))))
    (with-temp-buffer
      (rename-buffer "*test-scratch*")
      (should (equal '(:theme adwaita) (zr-face-buffer-match))))
    (with-temp-buffer
      (rename-buffer "foo.el")
      (emacs-lisp-mode)
      (should (equal '(:theme wombat) (zr-face-buffer-match))))
    (with-temp-buffer
      (rename-buffer " *temp-buf*")
      (text-mode)
      (should (equal '(:theme tango) (zr-face-buffer-match))))
    (with-temp-buffer
      (rename-buffer "unmatched-buf")
      (text-mode)
      (should (null (zr-face-buffer-match))))))

(ert-deftest zr-face-test-buffer-setup-plist ()
  "Buffer setup applies theme and font from plist configuration."
  (let ((zr-face-buffer-alist
         '(("test-plist" :theme adwaita :font "Zr Test Font" :size 15))))
    (with-temp-buffer
      (rename-buffer "test-plist")
      (zr-face-buffer-setup)
      (should (eq zr-face-buffer-theme 'adwaita))
      (let* ((spec (car (alist-get 'default face-remapping-alist)))
             (font (plist-get spec :font)))
        (should (equal "Zr Test Font" (format "%s" (font-get font :family))))
        (should (= 15 (font-get font :size)))))))

(ert-deftest zr-face-test-buffer-setup-alist ()
  "Buffer setup applies theme and font from alist configuration."
  (let ((zr-face-buffer-alist
         '(("test-alist" (theme . wombat) (font . ("Zr Alist Font" . 13))))))
    (with-temp-buffer
      (rename-buffer "test-alist")
      (zr-face-buffer-setup)
      (should (eq zr-face-buffer-theme 'wombat))
      (let* ((spec (car (alist-get 'default face-remapping-alist)))
             (font (plist-get spec :font)))
        (should (equal "Zr Alist Font" (format "%s" (font-get font :family))))
        (should (= 13 (font-get font :size)))))))

(ert-deftest zr-face-test-buffer-setup-custom-function ()
  "Buffer setup supports custom action functions."
  (let* ((called nil)
         (custom-fn (lambda (b) (setq called b)))
         (zr-face-buffer-alist
          `(("test-fn" . ,custom-fn))))
    (with-temp-buffer
      (rename-buffer "test-fn")
      (zr-face-buffer-setup)
      (should (eq called (current-buffer))))))

(ert-deftest zr-face-test-buffer-setup-all-and-mode ()
  "Buffer setup all updates all buffers, and minor mode manages hooks."
  (let ((zr-face-buffer-alist
         '(("test-all-1" :theme adwaita)
           ("test-all-2" :theme wombat))))
    (let ((buf1 (generate-new-buffer "test-all-1"))
          (buf2 (generate-new-buffer "test-all-2")))
      (unwind-protect
          (progn
            (zr-face-buffer-setup-all)
            (with-current-buffer buf1
              (should (eq zr-face-buffer-theme 'adwaita)))
            (with-current-buffer buf2
              (should (eq zr-face-buffer-theme 'wombat))))
        (kill-buffer buf1)
        (kill-buffer buf2))))
  (unwind-protect
      (progn
        (zr-face-buffer-mode 1)
        (should (memq #'zr-face-buffer-setup after-change-major-mode-hook))
        (zr-face-buffer-mode -1)
        (should-not (memq #'zr-face-buffer-setup after-change-major-mode-hook)))
    (zr-face-buffer-mode -1)))

(ert-deftest zr-face-test-buffer-setup-font-tuple-and-reset ()
  "Buffer setup handles (FAMILY SIZE) font format and theme reset."
  (let ((zr-face-buffer-alist
         '(("test-tuple" :theme adwaita :font ("Zr Tuple Font" 16)))))
    (with-temp-buffer
      (rename-buffer "test-tuple")
      (zr-face-buffer-setup)
      (should (eq zr-face-buffer-theme 'adwaita))
      (let* ((spec (car (alist-get 'default face-remapping-alist)))
             (font (plist-get spec :font)))
        (should (equal "Zr Tuple Font" (format "%s" (font-get font :family))))
        (should (= 16 (font-get font :size)))))
    (let ((zr-face-buffer-alist
           '(("test-tuple" :theme default :font default))))
      (with-temp-buffer
        (rename-buffer "test-tuple")
        (zr-face-set-buffer-theme 'adwaita)
        (zr-face-set-buffer-font "Zr Tuple Font" 16)
        (zr-face-buffer-setup)
        (should (null zr-face-buffer-theme))
        (should (null (plist-get (car (alist-get 'default face-remapping-alist)) :font)))))))

(ert-deftest zr-face-test-buffer-setup-window-arg ()
  "Buffer setup accepts a window as its buffer argument."
  (let ((zr-face-buffer-alist
         '(("test-win" :theme adwaita)))
        (buf (generate-new-buffer "test-win")))
    (unwind-protect
        (let ((win (selected-window)))
          (set-window-buffer win buf)
          (zr-face-buffer-setup win)
          (with-current-buffer buf
            (should (eq zr-face-buffer-theme 'adwaita))))
      (kill-buffer buf))))

(provide 'zr-face-test)
;;; zr-face-test.el ends here
