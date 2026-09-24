;;; zr-face.el --- Fonts, themes and faces -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: faces

;;; Commentary:

;; Fonts, themes and faces for frames and buffers.
;;
;; `zr-face-font-find-available-font' collects the installed families of
;; `zr-face-fonts-list', together with symbol and emoji families, into
;; `zr-face-font-available-alist'.  `zr-face-theme-list-update' sorts the
;; available themes into light and dark ones, remembered across sessions by
;; multisession variables.  `zr-face-font-shuffle-set',
;; `zr-face-theme-shuffle-set' and `zr-face-theme-enable-only' then apply one
;; font or theme.
;;
;; Loading this file neither changes a frame nor installs a hook.  Put
;; `zr-face-setup' wherever it is wanted, e.g.
;;
;;   (add-hook 'window-setup-hook #'zr-face-setup)
;;   (add-hook 'server-after-make-frame-hook #'zr-face-setup)
;;
;; Every helper is a command and may be hooked on its own, e.g.
;;
;;   (add-hook 'after-make-frame-functions #'zr-face-font-shuffle-set)
;;
;; A theme or font can also be changed for a single frame or a single buffer,
;; without touching any other: `zr-face-set-frame-theme' and
;; `zr-face-set-buffer-theme' apply a theme to a frame or buffer,
;; `zr-face-set-frame-font' and `zr-face-set-buffer-font' set the font of the
;; `default' face, and `zr-face-set-buffer-font-fallback' picks a family that
;; covers the glyphs the current one does not.  Choosing `default' resets the
;; theme.  `zr-face-buffer-alist' specifies conditional theme and font rules
;; matched against `buffer-match-p', applied via `zr-face-buffer-setup' or
;; `zr-face-buffer-mode'.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'face-remap)
(require 'multisession)
(require 'seq)
(require 'subr-x)

(declare-function dbus-call-method "dbus")
(declare-function face-spec-set-2 "faces" (face frame face-attrs))
(declare-function set-fontset-font "fontset.c"
                  (name target font-spec &optional frame add))
(declare-function w32-read-registry "w32fns.c" (root key name))
(autoload 'zr-wezterm-send-json "zr-wezterm")

(defvar custom-enabled-themes)
(defvar custom-known-themes)
(defvar zr-face-buffer-alist)

(defgroup zr-face nil
  "Fonts, themes and faces for frames and buffers."
  :group 'faces
  :prefix "zr-")


;;; Fonts

(defun zr-face-font-installed-p (font-name)
  "Check if font with FONT-NAME is available.
Stolen from https://github.com/seagle0128/.emacs.d/blob/c9bd6f1bb72486580f55879cdfd4fdcc852a49a6/lisp/init-funcs.el#L53"
  (find-font (font-spec :name font-name)))

(defcustom zr-face-fonts-list
  '(("LXGW WenKai Mono" #2=(33 14 23) #3="https://github.com/lxgw/LxgwWenKai/releases")
    ("霞鹜文楷等宽"  #2# #3#)
    ("LXGW Bright Code" #2# "https://github.com/lxgw/LxgwBright-Code/releases")
    ("小赖字体 等宽 SC" #5=(33 14 23) #4="https://github.com/lxgw/kose-font/releases")
    ("小賴字體 等寬 SC" #5# #4#)
    ("Sarasa Mono SC" #6=(32 14 22) #7="https://github.com/be5invis/Sarasa-Gothic/releases")
    ("等距更纱黑体 SC" #6# #7#)
    ("Maple Mono NF CN" (32 13 21) "https://github.com/subframe7536/maple-font/releases")
    ("Unifont-JP" #1=(33 14 24) "https://unifoundry.com/unifont/index.html")
    ("UnifontExMono" #1# "https://github.com/stgiga/UnifontEX/releases"))
  "List of font configurations for different display resolutions.
Each entry is a list containing:
- Font family name as a string
- List of pixel sizes for display widths below, equal to, and above 1920
- URL where the font can be downloaded"
  :group 'zr-face
  :type '(repeat (list (string :tag "Family name")
                       (list :tag "Sizes by display width"
                             (integer :tag "Below 1920 pixels")
                             (integer :tag "1920 pixels")
                             (integer :tag "Above 1920 pixels"))
                       (string :tag "Download URL"))))

(defvar zr-face-font-available-alist nil
  "Alist of the fonts of `zr-face-fonts-list' available on this display.
`zr-face-font-find-available-font' sets it to an alist with three keys:
`default', whose value is a list of (FAMILY . SIZE) cons cells, `symbol'
and `emoji', whose values are lists of family names.")

(defun zr-face-font-find-available-font ()
  "Find available font specifications based on screen resolution.
Automatically selects appropriate pixel size based on display width:
- Index 0 for displays < 1920 pixels
- Index 1 for displays = 1920 pixels
- Index 2 for displays > 1920 pixels

Sets `zr-face-font-available-alist' and removes itself from the hooks it was
run from, so that the fonts are only looked up once."
  (interactive)
  (let ((index (pcase (display-pixel-width)
                 ((pred (> 1920)) 0)
                 ((pred (< 1920)) 2)
                 (_ 1)))
        (prefer (mapcar #'car zr-face-fonts-list))
        (installed (font-family-list))
        default symbol emoji)
    (dolist (f installed)
      (cond
       ((cl-position f prefer :test #'string=)
        (cl-pushnew
         (cons f (nth index (car (alist-get f zr-face-fonts-list
                                            nil nil #'string=))))
         default :test #'equal))
       ((string-match-p ".+Symbol" f)
        (cl-pushnew f symbol :test #'string=))
       ((string-match-p "Emoji" f)
        (cl-pushnew f emoji :test #'string=))))
    (when default
      (setq zr-face-font-available-alist `((default . ,default)
                                      (symbol . ,symbol)
                                      (emoji . ,emoji)))))
  (remove-hook 'server-after-make-frame-hook #'zr-face-font-find-available-font))

(defun zr-face-font-shuffle-set (&optional frame)
  "Randomly apply a font from `zr-face-font-available-alist'.
With FRAME non-nil, apply it to that frame only.  This also allows use on
`after-make-frame-functions'.  Otherwise, change the global default font."
  (interactive)
  (with-selected-frame (or frame (selected-frame))
    (when-let* ((fonts (alist-get 'default zr-face-font-available-alist)))
      (let* ((fonts (if (> 2 (length fonts)) fonts
                      (cl-remove (face-attribute 'default :family)
				 fonts :key #'car :test #'string=)))
             (font (seq-random-elt fonts))
             (symbol (alist-get 'symbol zr-face-font-available-alist))
             (emoji (alist-get 'emoji zr-face-font-available-alist)))
	(set-face-attribute 'default frame
                            :font (font-spec :family (car font)
                                             :size (cdr font)))
	(when symbol
          (set-fontset-font t 'symbol
                            (font-spec
                             :family (seq-random-elt symbol)) frame))
	(when emoji
          (set-fontset-font t 'emoji
                            (font-spec
                             :family (seq-random-elt emoji)) frame))))))


;;; Themes

(define-multisession-variable zr-face-theme-light-list '(default)
  "List of available light themes for the current Emacs session.
Persists across multiple Emacs sessions and defaults to built-in
`default' theme."
  :package "zr-face")

(define-multisession-variable zr-face-theme-dark-list nil
  "List of available dark themes for the current Emacs session.
Persists across multiple Emacs sessions and starts empty by default."
  :package "zr-face")

(define-multisession-variable zr-face-theme-last-list '(default)
  "List of most recently used themes in the current Emacs session.
Persists across multiple Emacs sessions and defaults to built-in
`default' theme."
  :package "zr-face")

(defvar zr-face-theme-disabled-list '(light-blue)
  "List of disabled themes. Most of them are obsolete.")

(defvar zr-face-theme-customize
  '((adwaita
     (hl-line ((t (:extend t :background "navajo white")))))
    (whiteboard
     (hl-line ((t (:extend t :background "wheat")))))
    (tango
     (hl-line ((t (:extend t :background "cornsilk"))))))
  "Theme-specific face customizations.
Each entry is an alist mapping theme symbols to face specifications.")


(defun zr-face--read-theme (&optional prompt)
  "Read a theme name with completion using PROMPT."
  (intern
   (completing-read (or prompt "Theme: ")
                    (cons 'default (custom-available-themes))
                    nil t nil nil "default")))

(defun zr-face--theme-ensure-loaded (theme)
  "Ensure THEME is loaded and its custom face specs are applied."
  (unless (memq theme custom-known-themes)
    (load-theme theme t t))
  (when-let* ((custom (alist-get theme zr-face-theme-customize)))
    (apply #'custom-theme-set-faces theme custom)))

(defun zr-face--theme-faces (theme)
  "Return an alist of (FACE . SPEC) for THEME."
  (let (faces)
    (dolist (setting (get theme 'theme-settings))
      (when (eq (car setting) 'theme-face)
        (let ((face (nth 1 setting)))
          (while (get face 'face-alias)
            (setq face (get face 'face-alias)))
          (unless (assq face faces)
            (push (cons face (nth 3 setting)) faces)))))
    (nreverse faces)))

(defun zr-face--spec-attrs (spec &optional frame)
  "Return face attribute plist from SPEC for FRAME."
  (cond
   ((null spec) nil)
   ((keywordp (car spec)) spec)
   (t
    (let ((no-match (make-symbol "no-match")))
      (let ((attrs (face-spec-choose spec frame no-match)))
        (if (not (eq attrs no-match))
            attrs
          (let* ((non-default (cl-remove 'default spec :key #'car))
                 (entry (or (assq t non-default) (car (last non-default)) (car spec)))
                 (val (cdr entry))
                 (res (if (and (consp val) (listp (car val)))
                          (car val)
                        val))
                 (def-entry (assq 'default spec))
                 (def-val (cdr def-entry))
                 (def-attrs (if (and (consp def-val) (listp (car def-val)))
                                (car def-val)
                              def-val)))
            (if def-attrs
                (append res def-attrs)
              res))))))))

(defun zr-face-theme-enable-only (themes &optional tmp)
  "Enable THEMES exclusively, disabling all other active themes.
When called interactively, prompts for a single theme to enable.

THEMES can be a single theme symbol or a list of theme symbols, highest
priority first, as in `custom-enabled-themes'.
With optional TMP non-nil, don't update `zr-face-theme-last-list'.

Loads any unloaded themes and applies custom face specifications
from `zr-face-theme-customize'."
  (interactive (list (zr-face--read-theme)))
  (let* ((themes (ensure-list themes))
         (themes-to-enable (remove 'default themes))
         (unloaded (cl-set-difference themes-to-enable custom-known-themes)))
    (dolist (item custom-enabled-themes)
      (disable-theme item))
    (dolist (theme unloaded)
      (load-theme theme t t))
    (dolist (theme (reverse themes-to-enable))
      (apply #'custom-theme-set-faces theme
             (alist-get theme zr-face-theme-customize))
      (enable-theme theme))
    (unless tmp
      (setf (multisession-value zr-face-theme-last-list) themes))))

(defun zr-face-theme-list-update ()
  "Update the light and dark theme lists based on available themes.
Automatically categorizes newly installed themes as light or dark by
checking their background colors. Updates `zr-face-theme-light-list' and
`zr-face-theme-dark-list' accordingly, and removes itself from the hooks it
was run from."
  (interactive)
  (let ((cur (cons 'default
                   (cl-set-difference (custom-available-themes)
                                      zr-face-theme-disabled-list)))
        (light (multisession-value zr-face-theme-light-list))
        (dark (multisession-value zr-face-theme-dark-list)))
    (unless (seq-set-equal-p cur (append light dark))
      (let (cur-light cur-dark)
        (dolist (theme cur)
          (cond
           ((memq theme light)
            (push theme cur-light))
           ((memq theme dark)
            (push theme cur-dark))
           (t (push theme (if (zr-face-theme-dark-p theme) cur-dark cur-light)))))
        (setf (multisession-value zr-face-theme-light-list) cur-light
              (multisession-value zr-face-theme-dark-list) cur-dark))))
  (remove-hook 'server-after-make-frame-hook #'zr-face-theme-list-update))

(defun zr-face-theme-dark-p (&optional theme)
  "Return non-nil if THEME or current theme has a dark background.
When THEME is provided, temporarily enables it to check its properties.
Restores the previous theme state after checking."
  (if theme
      (let ((enabled (copy-sequence custom-enabled-themes))
            result)
        (unwind-protect
            (progn
              (zr-face-theme-enable-only theme t)
              (setq result (zr-face-theme-dark-p)))
          (zr-face-theme-enable-only enabled t))
        result)
    (color-dark-p (color-name-to-rgb (face-attribute 'default :background)))))

(defun zr-face-system-dark-mode-enabled-p ()
  "Check if system-wide dark mode is enabled.
On terminals, use the background mode already detected by Emacs.
On graphical displays, return non-nil if dark mode is active:
- Windows: Checks registry key for dark app theme
- Linux: Checks DBus interface for dark color scheme
- Other systems: Returns nil

ref: https://github.com/LionyxML/auto-dark-emacs/blob/master/auto-dark.el"
  (if (eq t (framep (selected-frame)))
      (eq 'dark (or (terminal-parameter nil 'background-mode)
                    (frame-parameter nil 'background-mode)))
    (pcase system-type
      ('windows-nt
       (eq 0 (w32-read-registry
              'HKCU
              "SOFTWARE/Microsoft/Windows/CurrentVersion/Themes/Personalize"
              "AppsUseLightTheme")))
      ('gnu/linux
       (when (require 'dbus nil t)
         (let ((value (condition-case nil
                          (dbus-call-method
                           :session
                           "org.freedesktop.portal.Desktop"
                           "/org/freedesktop/portal/desktop"
                           "org.freedesktop.portal.Settings" "Read"
                           "org.freedesktop.appearance" "color-scheme")
                        (error nil))))
           (eq 1 (caar value)))))
      (_ nil))))

(defun zr-face-theme-shuffle-set (&optional themes)
  "Randomly select and enable a theme from appropriate category.
With no prefix arg, selects from light/dark themes based on system theme.
With `-' prefix arg, selects from opposite category.
With other THEMES argument, selects from provided theme list.
Avoids selecting the most recently used theme."
  (interactive "P")
  (let* ((themes (pcase themes
                   ('nil
                    (multisession-value
                     (if (zr-face-system-dark-mode-enabled-p)
                         zr-face-theme-dark-list
                       zr-face-theme-light-list)))
                   ('-
                    (multisession-value
                     (if (zr-face-system-dark-mode-enabled-p)
                         zr-face-theme-light-list
                       zr-face-theme-dark-list)))
                   (_ themes)))
         (last (multisession-value zr-face-theme-last-list))
         (available (cl-set-difference themes last))
         (pool (or available themes))
         (theme (and pool (seq-random-elt pool))))
    (when theme
      (zr-face-theme-enable-only theme)
      (message "Current theme: %S" theme))
    theme))


;;; Appearance

(defcustom zr-face-wezterm-theme "Google (light) (terminal.sexy)"
  "Theme to apply to WezTerm terminal frames.
Can be a theme name string, a function returning a theme name,
or nil to disable WezTerm theme updates."
  :group 'zr-face
  :type '(choice (string :tag "Theme name")
                 (function :tag "Theme generator")
                 (const :tag "Disabled" nil)))

(defvar zr-face-appearance-should-setup-p t
  "Non-nil means graphical appearance still needs initial setup.
Set to nil after the first graphical frame is configured.")

(defun zr-face-appearance-setup (&optional frame)
  "Initialize font and theme configuration for FRAME.
When FRAME is nil, defaults to `selected-frame'.

In a graphical display:
- Configures global font and theme once via `zr-face-font-shuffle-set'
  and `zr-face-theme-shuffle-set'.

In a WezTerm terminal without a graphical display:
- Configures the WezTerm terminal theme via `zr-wezterm-send-json'
  once per terminal connection."
  (interactive)
  (let ((frame (or frame (selected-frame))))
    (if (display-graphic-p frame)
        (when zr-face-appearance-should-setup-p
          (zr-face-font-shuffle-set)
          (zr-face-theme-shuffle-set)
          (setq zr-face-appearance-should-setup-p nil))
      (when (and (equal (or (getenv "TERM_PROGRAM" frame)
                            (getenv "TERM_PROGRAM"))
                        "WezTerm")
                 (not (terminal-parameter frame 'zr-face-wezterm-setup))
                 (fboundp 'zr-wezterm-send-json))
        (with-selected-frame frame
          (when-let* ((theme (if (functionp zr-face-wezterm-theme)
                                 (funcall zr-face-wezterm-theme)
                               zr-face-wezterm-theme)))
            (zr-wezterm-send-json
             `((type . "set_theme")
               (theme . ,theme)))))
        (set-terminal-parameter frame 'zr-face-wezterm-setup t)))))

;;;###autoload
(defun zr-face-setup (&optional frame)
  "Look up fonts and themes, then apply one of each for FRAME.
Run `zr-face-font-find-available-font', `zr-face-theme-list-update' and
`zr-face-appearance-setup'.  Meant for `window-setup-hook',
`server-after-make-frame-hook' or `after-make-frame-functions'; Android
has no server frame, so `window-setup-hook' is the hook to use there."
  (zr-face-font-find-available-font)
  (zr-face-theme-list-update)
  (zr-face-appearance-setup frame)
  (when zr-face-buffer-alist
    (zr-face-buffer-setup-all)))


;;; Commands

(defun zr-face--font-families ()
  "Font families to choose from, those of `zr-face-font-available-alist' first."
  (delete-dups
   (append (mapcar #'car (alist-get 'default zr-face-font-available-alist))
           (font-family-list))))

(defun zr-face--default-font-size (family)
  "Pixel size suggested for font FAMILY."
  (or (cdr (assoc family (alist-get 'default zr-face-font-available-alist)))
      (when-let* ((font (face-font 'default))
                  ((fontp font))
                  (size (font-get font :size)))
        size)
      14))

(defun zr-face--read-font (size-prompt)
  "Read a font family, asking for its size too when SIZE-PROMPT is non-nil.
Return (FAMILY . SIZE)."
  (let ((family (completing-read "Font family: " (zr-face--font-families) nil t)))
    (cons family
          (and size-prompt
               (read-number "Size in pixels: " (zr-face--default-font-size family))))))

;;;###autoload
(defun zr-face-set-frame-font (family size &optional all-frames)
  "Display the `default' face of the selected frame with FAMILY at SIZE.
SIZE is a pixel size; nil means the frame keeps the size it chooses itself.
With ALL-FRAMES non-nil, change every frame instead, which is what a
prefix argument does interactively."
  (interactive (let ((font (zr-face--read-font t)))
                 (list (car font) (cdr font) current-prefix-arg)))
  (set-face-attribute 'default (unless all-frames (selected-frame))
                      :font (font-spec :family family :size size))
  (message "Font is %s%s%s" family
           (if size (format " %s" size) "")
           (if all-frames "" " on this frame")))

(defvar-local zr-face-buffer-font nil
  "Font applied to the current buffer by `zr-face-set-buffer-font'.")

(defvar-local zr-face--buffer-font-cookie nil
  "Cookie for the font remapping applied by `zr-face-set-buffer-font'.")

;;;###autoload
(defun zr-face-set-buffer-font (family &optional size buffer)
  "Display the `default' face of BUFFER with FAMILY at SIZE.
BUFFER defaults to the current buffer.  SIZE is a pixel size;
nil means the buffer keeps the size it chooses itself.  When
both FAMILY and SIZE are nil, remove any font remapping."
  (interactive (let ((font (zr-face--read-font t)))
                 (list (car font) (cdr font))))
  (with-current-buffer (or buffer (current-buffer))
    (when zr-face--buffer-font-cookie
      (face-remap-remove-relative zr-face--buffer-font-cookie)
      (setq zr-face--buffer-font-cookie nil))
    (setq zr-face-buffer-font nil)
    (when (or family size)
      (let ((attrs (cond
                    ((and family size)
                     (list :font (font-spec :family family :size size)))
                    (family
                     (list :font (font-spec :family family)))
                    (size
                     (list :font (font-spec :size size))))))
        (setq zr-face-buffer-font (cons family size))
        (setq zr-face--buffer-font-cookie
              (apply #'face-remap-add-relative 'default attrs))))))

;;;###autoload
(defun zr-face-set-buffer-font-fallback (&optional font buffer)
  "Display the `default' face of BUFFER with FONT.
BUFFER defaults to the current buffer.  FONT is a family name, and
defaults to the first of \"Unifont-JP\" and \"UnifontExMono\" that is
installed, which cover most glyphs a frame font does not.
Interactively, a prefix argument reads the family instead."
  (interactive "P")
  (with-current-buffer (or buffer (current-buffer))
    (let* ((fonts (pcase font
                    ((pred stringp) (list font))
                    ('nil '("Unifont-JP" "UnifontExMono"))
                    ('(4) (list (car (zr-face--read-font nil))))))
           (installed (font-family-list)))
      (when-let* ((family (seq-find (lambda (candidate)
                                      (member candidate installed))
                                    fonts)))
        (face-remap-add-relative 'default :family family)))))

(defvar-local zr-face-buffer-theme nil
  "Theme applied to the current buffer by `zr-face-set-buffer-theme'.")

(defvar-local zr-face--buffer-theme-cookies nil
  "List of face remapping cookies applied by `zr-face-set-buffer-theme'.")

(defun zr-face-frame-theme (&optional frame)
  "Return the theme applied to FRAME by `zr-face-set-frame-theme'."
  (frame-parameter frame 'zr-face-theme))

;;;###autoload
(defun zr-face-set-frame-theme (theme &optional all-frames)
  "Apply THEME to the selected frame.
With ALL-FRAMES non-nil, change every frame instead, which is what a
prefix argument does interactively.  When ALL-FRAMES is a frame object,
change that frame instead.  When THEME is `default', reset the frame's
faces to the global theme.  Interactively, prompt for THEME with
completion."
  (interactive
   (list (zr-face--read-theme)
         current-prefix-arg))
  (let* ((theme (if (stringp theme) (intern theme) theme))
         (frames (cond
                  ((framep all-frames) (list all-frames))
                  (all-frames (frame-list))
                  (t (list (selected-frame))))))
    (unless (memq theme '(default nil))
      (zr-face--theme-ensure-loaded theme))
    (dolist (frame frames)
      (when-let* ((old-faces (frame-parameter frame 'zr-face-theme-faces)))
        (dolist (face old-faces)
          (face-spec-recalc face frame))
        (when (frame-parameter frame 'cursor-color)
          (set-frame-parameter frame 'cursor-color nil))
        (set-frame-parameter frame 'zr-face-theme-faces nil)
        (set-frame-parameter frame 'zr-face-theme nil))
      (unless (memq theme '(default nil))
        (let (modified)
          (dolist (entry (zr-face--theme-faces theme))
            (let* ((face (car entry))
                   (spec (cdr entry))
                   (attrs (zr-face--spec-attrs spec frame)))
              (when (and face attrs (listp attrs))
                (condition-case nil
                    (progn
                      (face-spec-set-2 face frame attrs)
                      (push face modified)
                      (when (and (eq face 'cursor)
                                 (plist-get attrs :background))
                        (set-frame-parameter frame 'cursor-color
                                             (plist-get attrs :background))))
                  (error nil)))))
          (set-frame-parameter frame 'zr-face-theme theme)
          (set-frame-parameter frame 'zr-face-theme-faces modified))))
    (message "Theme is %s%s"
             (or theme 'default)
             (if (and all-frames (not (framep all-frames)))
                 ""
               " on this frame"))
    theme))

;;;###autoload
(defun zr-face-set-buffer-theme (theme &optional buffer)
  "Apply THEME to the current buffer using face remapping.
Only this buffer sees the change.  When optional BUFFER is non-nil,
apply to that buffer instead.  When THEME is `default', reset the
buffer's faces to the default theme.  Interactively, prompt for
THEME with completion."
  (interactive (list (zr-face--read-theme)))
  (with-current-buffer (or buffer (current-buffer))
    (let ((theme (if (stringp theme) (intern theme) theme)))
      (when zr-face--buffer-theme-cookies
        (dolist (cookie zr-face--buffer-theme-cookies)
          (face-remap-remove-relative cookie))
        (setq zr-face--buffer-theme-cookies nil))
      (setq zr-face-buffer-theme nil)
      (unless (memq theme '(default nil))
        (zr-face--theme-ensure-loaded theme)
        (let (cookies)
          (dolist (entry (zr-face--theme-faces theme))
            (let* ((face (car entry))
                   (spec (cdr entry))
                   (attrs (zr-face--spec-attrs spec (selected-frame))))
              (when (and face attrs (listp attrs))
                (condition-case nil
                    (push (face-remap-add-relative face attrs) cookies)
                  (error nil)))))
          (setq zr-face--buffer-theme-cookies cookies)
          (setq zr-face-buffer-theme theme)))
      (message "Theme is %s in %s"
               (or theme 'default)
               (current-buffer))
      theme)))



;;; Buffer Appearance Rules

;;;###autoload
(defcustom zr-face-buffer-alist nil
  "Alist of conditional theme and font settings for buffers.
Each element has the form (CONDITION . ACTION) or (CONDITION &rest ACTION).

CONDITION is passed to `buffer-match-p' along with the buffer to check
if the rule applies.  It can be:
- a regular expression matching the buffer name,
- a predicate function of one argument (the buffer),
- a cons cell `(derived-mode . MODE)', `(major-mode . MODE)',
  `(not . CONDITION)', `(and . CONDITIONS)', or `(or . CONDITIONS)',
- t to match any buffer, or nil to match none.

ACTION specifies the theme and/or font to apply.  It can be a plist
or an alist with the following keys:
- `:theme' (or `theme'): symbol or string naming the theme, or `default'
- `:font' (or `font'): font family name, or a list/cons `(FAMILY . SIZE)'
- `:size' (or `size'): pixel size of the font
- `:fallback' (or `fallback'): fallback font family name or t
- `:func' (or `func'): function or list of functions to call with the buffer

ACTION can also be a function or list of functions called with the
buffer as argument.

Matches are tested in order until the first matching CONDITION is found.
See `zr-face-buffer-setup' and `zr-face-buffer-mode' to apply these settings."
  :group 'zr-face
  :type '(alist :key-type (choice :tag "Condition"
                                  (regexp :tag "Buffer name regexp")
                                  (function :tag "Predicate function")
                                  (sexp :tag "Condition expression"))
                :value-type (choice :tag "Action"
                                    (plist :tag "Property list")
                                    (alist :tag "Association list")
                                    (function :tag "Custom function")
                                    (sexp :tag "Other"))))

(defun zr-face--parse-buffer-action (action)
  "Parse ACTION into a normalized plist.
The returned plist has keys :theme, :family, :size, :fallback,
and :func.  ACTION can be a function, list of functions, plist,
or alist."
  (cond
   ((or (functionp action)
        (and (symbolp action) (fboundp action)))
    (list :func action))
   ((and (consp action)
         (null (cdr action))
         (or (functionp (car action))
             (and (symbolp (car action)) (fboundp (car action)))))
    (list :func (car action)))
   ((and (consp action)
         (not (keywordp (car action)))
         (seq-every-p (lambda (x)
                        (or (functionp x)
                            (and (symbolp x) (fboundp x))))
                      action))
    (list :func action))
   (t
    (let ((act (if (and (consp action)
                        (null (cdr action))
                        (listp (car action)))
                   (car action)
                 action))
          theme font size fallback func)
      (when (and (consp act)
                 (symbolp (car act))
                 (not (keywordp (car act)))
                 (not (listp (cdr act))))
        (setq act (list act)))
      (cond
       ((and (consp act) (keywordp (car act)))
        (setq theme (plist-get act :theme)
              font (or (plist-get act :font) (plist-get act :family))
              size (plist-get act :size)
              fallback (plist-get act :fallback)
              func (plist-get act :func)))
       ((and (consp act) (consp (car act)))
        (setq theme (or (cdr (assq 'theme act)) (cdr (assq :theme act)))
              font (or (cdr (assq 'font act)) (cdr (assq 'family act))
                       (cdr (assq :font act)) (cdr (assq :family act)))
              size (or (cdr (assq 'size act)) (cdr (assq :size act)))
              fallback (or (cdr (assq 'fallback act)) (cdr (assq :fallback act)))
              func (or (cdr (assq 'func act)) (cdr (assq :func act))))))
      (let (family font-reset)
        (cond
         ((consp font)
          (setq family (car font)
                size (or size (if (consp (cdr font)) (cadr font) (cdr font)))))
         ((stringp font)
          (setq family font))
         ((eq font 'default)
          (setq family nil size nil font-reset t)))
        (list :theme theme :family family :size size
              :fallback fallback :func func :font-reset font-reset))))))

(defun zr-face-buffer-match (&optional buffer alist)
  "Return the action from ALIST matching BUFFER.
BUFFER defaults to the current buffer.  ALIST defaults to
`zr-face-buffer-alist'.  Entries are matched in order using
`buffer-match-p'.  Return the matched entry's action (cdr), or nil."
  (when-let* ((buf (cond
                    ((bufferp buffer) buffer)
                    ((windowp buffer) (window-buffer buffer))
                    ((stringp buffer) (get-buffer buffer))
                    (t (current-buffer))))
              ((buffer-live-p buf)))
    (catch 'match
      (dolist (entry (or alist zr-face-buffer-alist))
        (when (buffer-match-p (car entry) buf)
          (throw 'match (cdr entry)))))))

;;;###autoload
(defun zr-face-buffer-setup (&optional buffer)
  "Apply theme and font to BUFFER according to `zr-face-buffer-alist'.
BUFFER defaults to the current buffer.  When called from hooks,
BUFFER may also be a window.  Matches the buffer using
`buffer-match-p' against elements of `zr-face-buffer-alist'.
Returns the matching action if a rule matched, nil otherwise."
  (interactive)
  (when-let* ((buf (cond
                    ((bufferp buffer) buffer)
                    ((windowp buffer) (window-buffer buffer))
                    ((stringp buffer) (get-buffer buffer))
                    (t (current-buffer))))
              ((buffer-live-p buf))
              (action (zr-face-buffer-match buf)))
    (let ((parsed (zr-face--parse-buffer-action action)))
      (with-current-buffer buf
        (when-let* ((theme (plist-get parsed :theme)))
          (zr-face-set-buffer-theme theme buf))
        (when (or (plist-get parsed :family)
                  (plist-get parsed :size)
                  (plist-get parsed :font-reset))
          (zr-face-set-buffer-font (plist-get parsed :family)
                                   (plist-get parsed :size)
                                   buf))
        (when-let* ((fallback (plist-get parsed :fallback)))
          (zr-face-set-buffer-font-fallback (if (eq fallback t) nil fallback) buf))
        (when-let* ((func (plist-get parsed :func)))
          (let ((fns (if (or (functionp func)
                             (and (symbolp func) (fboundp func)))
                         (list func)
                       (ensure-list func))))
            (dolist (fn fns)
              (funcall fn buf)))))
      action)))

;;;###autoload
(defun zr-face-buffer-setup-all ()
  "Apply `zr-face-buffer-alist' to all live buffers."
  (interactive)
  (dolist (buf (buffer-list))
    (zr-face-buffer-setup buf)))

;;;###autoload
(define-minor-mode zr-face-buffer-mode
  "Global minor mode to apply `zr-face-buffer-alist' on major mode changes.
When enabled, `zr-face-buffer-setup' is added to `after-change-major-mode-hook'
and applied to all existing buffers."
  :global t
  :group 'zr-face
  (if zr-face-buffer-mode
      (progn
        (add-hook 'after-change-major-mode-hook #'zr-face-buffer-setup)
        (zr-face-buffer-setup-all))
    (remove-hook 'after-change-major-mode-hook #'zr-face-buffer-setup)))

(provide 'zr-face)
;;; zr-face.el ends here
