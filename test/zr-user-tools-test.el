;;; zr-user-tools-test.el --- Refactored file and shell behavior -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'zr-dired)
(require 'zr-bookmark)
(require 'zr-comint)
(require 'zr-eshell)
(require 'zr-pcmpl)
(require 'zr-data)
(require 'zr-window)
(require 'zr-process-menu)
(require 'zr-elisp)
(require 'zr-vc)

(defmacro zr-tools-test--directory (&rest body)
  (declare (indent 0) (debug t))
  `(let ((default-directory (file-name-as-directory (make-temp-file "zr-tools-test-" t))))
     (unwind-protect (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-local-value 'buffer-file-name buffer)
                    (string-prefix-p default-directory (buffer-local-value 'buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer)))
       (delete-directory default-directory t))))

(ert-deftest zr-tools-bookmarks-first-save-delete-and-separate ()
  (zr-tools-test--directory
    (let ((bookmark-default-file (expand-file-name "local"))
          (bookmark-alist '(("s/shared" (filename . "/tmp/shared")) ("local" (filename . "/tmp/local"))))
          (bookmark-default-file-alist nil) (bookmark-alist-modification-count 1)
          (bookmark-save-flag nil) (bookmark-version-control 'never)
          (zr-bookmark-shared-file (expand-file-name "shared"))
          (bookmark-default-file-locally-set t))
      (unwind-protect
          (progn
            (zr-bookmark-shared-mode 1)
            (zr-bookmark-shared-mode 1)
            (bookmark-save)
            (should (file-exists-p zr-bookmark-shared-file))
            (let (bookmark-alist)
              (setq bookmark-alist (with-temp-buffer (insert-file-contents bookmark-default-file)
                                                     (bookmark-alist-from-buffer)))
              (should (equal (mapcar #'car bookmark-alist) '("local"))))
            (let (bookmark-alist)
              (setq bookmark-alist (with-temp-buffer (insert-file-contents zr-bookmark-shared-file)
                                                     (bookmark-alist-from-buffer)))
              (should (equal (mapcar #'car bookmark-alist) '("s/shared"))))
            (setq bookmark-alist (assoc-delete-all "s/shared" bookmark-alist))
            (bookmark-save)
            (let (bookmark-alist)
              (setq bookmark-alist (with-temp-buffer (insert-file-contents zr-bookmark-shared-file)
                                                     (bookmark-alist-from-buffer)))
              (should-not bookmark-alist))
            (should (equal (mapcar #'car bookmark-alist) '("local"))))
        (zr-bookmark-shared-mode -1))
      (should-not (advice-member-p #'zr-bookmark--save 'bookmark-save)))))

(ert-deftest zr-tools-bookmark-explicit-export-remains-whole ()
  (let ((bookmark-default-file "/tmp/zr-default") seen)
    (zr-bookmark--save (lambda (&rest args) (setq seen args)) nil "/tmp/export" t)
    (should (equal seen '(nil "/tmp/export" t)))))

(ert-deftest zr-tools-dired-duplicate-no-extension-and-directory ()
  (zr-tools-test--directory
    (with-temp-file "README" (insert "hello"))
    (make-directory "dir.name")
    (with-temp-file "dir.name/item" (insert "nested"))
    (let ((buffer (dired-noselect default-directory)))
      (unwind-protect
          (with-current-buffer buffer
            (dired-goto-file (expand-file-name "README"))
            (zr-dired-duplicate 1)
            (should (file-exists-p "README_001"))
            (dired-goto-file (expand-file-name "README"))
            (zr-dired-duplicate 1)
            (should (file-exists-p "README_002"))
            (dired-goto-file (expand-file-name "dir.name"))
            (zr-dired-duplicate 1)
            (should (file-exists-p "dir.name_001/item")))
        (kill-buffer buffer)))))

(ert-deftest zr-tools-dired-empty-list-is-useful-error ()
  (zr-tools-test--directory
    (let ((buffer (dired-noselect default-directory)))
      (unwind-protect (with-current-buffer buffer (should-error (zr-dired-random-file) :type 'user-error))
        (kill-buffer buffer)))))

(ert-deftest zr-tools-comint-preserves-file-and-sentinel ()
  (zr-tools-test--directory
    (with-temp-buffer
      (comint-mode)
      (let* ((history (expand-file-name "custom/history"))
             (comint-input-ring-file-name history)
             (zr-comint-kill-buffer-on-exit nil)
             (process (make-pipe-process :name "zr-history-test" :buffer (current-buffer) :noquery t))
             (calls 0))
        (unwind-protect
            (cl-letf (((symbol-function 'process-command) (lambda (_) '("custom-program"))))
              (set-process-sentinel process (lambda (_process _event) (setq calls (1+ calls))))
              (zr-comint-history-mode 1)
              (zr-comint-history-mode 1)
              (should (equal comint-input-ring-file-name history))
              (ring-insert comint-input-ring "hello")
              (zr-comint-save-history)
              (should (file-exists-p history))
              (zr-comint-history-mode -1)
              (funcall (process-sentinel process) process "finished\n")
              (should (= calls 1))
              (should-not (advice-function-member-p #'zr-comint--sentinel (process-sentinel process))))
          (delete-process process))))))

(ert-deftest zr-tools-comint-saves-before-original-kills-buffer ()
  (zr-tools-test--directory
    (let ((buffer (generate-new-buffer " *zr history*")) (file (expand-file-name "history")))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local comint-input-ring-file-name file)
            (ring-insert comint-input-ring "last-command")
            (let ((zr-comint-history-mode t))
              (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer))
                        ((symbol-function 'process-status) (lambda (_) 'exit))
                        ((symbol-function 'process-exit-status) (lambda (_) 0)))
                (zr-comint--sentinel (lambda (&rest _) (kill-buffer buffer)) 'fake "finished\n")))
            (should (file-exists-p file)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest zr-tools-eshell-history-inclusive-ranges-and-last-word ()
  (with-temp-buffer
    (let ((zr-eshell-mode t))
      (dolist (case '((":1" . "one") (":1-2" . "one two") (":*" . "one two three")
                      (":$" . "three") (":1-$" . "one two three") (":1-" . "one two")
                      ("^" . "one") ("$" . "three") ("*" . "one two three")))
        (should (equal (car (zr-eshell--word-designator #'ignore "echo one two three" (car case))) (cdr case)))))))

(ert-deftest zr-tools-eshell-advice-is-buffer-local-in-effect ()
  (let ((first (generate-new-buffer " *zr eshell 1*")) (second (generate-new-buffer " *zr eshell 2*")))
    (unwind-protect
        (progn
          (with-current-buffer first (zr-eshell-mode 1) (zr-eshell-mode 1))
          (with-current-buffer second (zr-eshell-mode 1))
          (with-current-buffer first (zr-eshell-mode -1))
          (should (advice-member-p #'zr-eshell--word-designator 'eshell-hist-parse-word-designator))
          (with-temp-buffer (should (eq 'original (zr-eshell--word-designator (lambda (&rest _) 'original) "" ""))))
          (kill-buffer second)
          (should-not (advice-member-p #'zr-eshell--word-designator 'eshell-hist-parse-word-designator)))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second)))))

(ert-deftest zr-tools-eshell-env-s-quoted-arguments ()
  (zr-tools-test--directory
    (with-temp-file "script.py" (insert "#!/usr/bin/env -S python -X 'utf8 mode'\nprint(1)\n"))
    (let (seen)
      (cl-letf (((symbol-function 'eshell-parse-command) (lambda (program args) (setq seen (cons program args)))))
        (catch 'eshell-replace-command (zr-eshell-script-interpreter "script.py" "a b")))
      (should (equal seen '("python" "-X" "utf8 mode" "script.py" "a b"))))))

(ert-deftest zr-tools-pcmpl-restores-existing-handler ()
  (let ((old (and (fboundp 'pcomplete/7z) (symbol-function 'pcomplete/7z))))
    (unwind-protect
        (progn
          (fset 'pcomplete/7z #'ignore)
          (zr-pcmpl-mode 1) (zr-pcmpl-mode 1)
          (should (eq (symbol-function 'pcomplete/7z) #'zr-pcmpl-7z))
          (zr-pcmpl-mode -1)
          (should (eq (symbol-function 'pcomplete/7z) #'ignore)))
      (zr-pcmpl-mode -1)
      (if old (fset 'pcomplete/7z old) (fmakunbound 'pcomplete/7z)))))

(ert-deftest zr-tools-json-merge-values-and-no-input-mutation ()
  (let* ((first (json-parse-string "{\"a\":{\"x\":1},\"list\":[1],\"false\":false,\"nil\":null}"))
         (second (json-parse-string "{\"a\":{\"y\":2},\"list\":[2],\"false\":true,\"nil\":0}"))
         (merged (zr-data-merge-json first second)))
    (should (= (gethash "y" (gethash "a" merged)) 2))
    (should-not (gethash "y" (gethash "a" first)))
    (should (equal (gethash "list" merged) [1 2]))
    (should (eq (gethash "false" merged) t))
    (should (= (gethash "nil" merged) 0))))

(ert-deftest zr-tools-json-parse-failure-preserves-output ()
  (zr-tools-test--directory
    (with-temp-file "a" (insert "{}"))
    (with-temp-file "b" (insert "invalid"))
    (with-temp-file "output" (insert "original"))
    (should-error (zr-data-merge-json-files "a" "b" "output"))
    (should (equal (with-temp-buffer (insert-file-contents "output") (buffer-string)) "original"))))

(ert-deftest zr-tools-sops-checks-exit-status ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/sops"))
            ((symbol-function 'process-file) (lambda (&rest _) (insert "not decrypted") 1)))
    (should-error (zr-data-sops-decrypt "test"))))

(ert-deftest zr-tools-uuid-is-deterministic-and-well-formed ()
  (let ((id (zr-data-uuid '(example "中文"))))
    (should (equal id (zr-data-uuid '(example "中文"))))
    (should (string-match-p "\\`[0-9a-f-]\\{14\\}3[0-9a-f]\\{3\\}-[89ab]" id))))

(ert-deftest zr-tools-source-link-windows-compressed-path ()
  (with-temp-buffer
    (setq buffer-file-name "C:\\Emacs\\lisp\\foo bar.el.gz")
    (should (equal (zr-elisp-source-url) "https://github.com/emacs-mirror/emacs/raw/refs/heads/master/lisp/foo%20bar.el"))))

(ert-deftest zr-tools-vc-template-without-scope ()
  (with-temp-buffer (zr-vc-insert-commit-template "fix" "") (should (equal (buffer-string) "fix: "))))

(ert-deftest zr-tools-process-filter-groups-display-only ()
  (with-temp-buffer
    (let ((tabulated-list-entries '((one ["server" "run"]) (two ["worker" "run"])))
          (zr-process-menu-omit-regexp "server") (zr-process-menu-group-column 1))
      (zr-process-menu--refresh)
      (should (equal (mapcar #'car tabulated-list-entries) '(two)))
      (should (equal (caar tabulated-list-groups) "* run")))))
(ert-deftest zr-tools-bookmark-failed-write-keeps-dirty-state ()
  (zr-tools-test--directory
    (let ((bookmark-default-file (expand-file-name "local"))
          (zr-bookmark-shared-file (expand-file-name "shared"))
          (bookmark-bookmarks-timestamp nil)
          (bookmark-watch-bookmark-file nil)
          (bookmark-alist '(("s/item" (filename . "/tmp/item"))))
          (bookmark-alist-modification-count 2))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (&rest _) (signal 'file-error '("Write failed")))))
        (should-error (zr-bookmark--save #'bookmark-save) :type 'file-error))
      (should (= bookmark-alist-modification-count 2))
      (should-not bookmark-bookmarks-timestamp))))

(ert-deftest zr-tools-bookmark-delete-last-local-and-reload-shared ()
  (zr-tools-test--directory
    (let ((bookmark-default-file (expand-file-name "local"))
          (zr-bookmark-shared-file (expand-file-name "shared"))
          (bookmark-bookmarks-timestamp nil)
          (bookmark-watch-bookmark-file nil)
          (bookmark-version-control 'never)
          (bookmark-alist '(("s/item" (filename . "/tmp/item"))
                            ("local" (filename . "/tmp/local"))))
          (bookmark-alist-modification-count 1))
      (unwind-protect
          (progn
            (zr-bookmark-shared-mode 1)
            (bookmark-save)
            (setq bookmark-alist (assoc-delete-all "local" bookmark-alist))
            (bookmark-save)
            (should-not (with-temp-buffer
                          (insert-file-contents bookmark-default-file)
                          (bookmark-alist-from-buffer)))
            (bookmark-load bookmark-default-file t t)
            (should (equal (mapcar #'car bookmark-alist) '("s/item"))))
        (zr-bookmark-shared-mode -1)))))

(ert-deftest zr-tools-comint-emacs-exit-saves-all-enabled-buffers ()
  (zr-tools-test--directory
    (let ((first (generate-new-buffer " *zr exit 1*"))
          (second (generate-new-buffer " *zr exit 2*"))
          (kill-emacs-hook nil))
      (unwind-protect
          (progn
            (dolist (entry (list (cons first "one") (cons second "two")))
              (with-current-buffer (car entry)
                (comint-mode)
                (setq-local comint-input-ring-file-name (expand-file-name (cdr entry)))
                (zr-comint-history-mode 1)
                (zr-comint-history-mode 1)
                (ring-insert comint-input-ring (cdr entry))))
            (should (= (cl-count #'zr-comint--save-all kill-emacs-hook) 1))
            (run-hooks 'kill-emacs-hook)
            (should (equal (with-temp-buffer (insert-file-contents "one") (buffer-string)) "one\n"))
            (should (equal (with-temp-buffer (insert-file-contents "two") (buffer-string)) "two\n"))
            (with-current-buffer first (zr-comint-history-mode -1))
            (should (memq #'zr-comint--save-all kill-emacs-hook))
            (kill-buffer second)
            (should-not (memq #'zr-comint--save-all kill-emacs-hook)))
        (dolist (buffer (list first second))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest zr-tools-eshell-history-real-events-and-modifiers ()
  (with-temp-buffer
    (let ((eshell-history-ring (make-ring 10))
          (eshell-modules-list '(eshell-pred)))
      (ring-insert eshell-history-ring "echo one two three")
      (unwind-protect
          (progn
            (zr-eshell-mode 1)
            (dolist (case '(("!!:1-2" . "one two") ("!!:$" . "three")
                            ("!!:*" . "one two three") ("!!:1-$" . "one two three")
                            ("!!:1-" . "one two") ("!!:s/one/ONE/" . "echo ONE two three")))
              (should (equal (eshell-history-reference (car case)) (cdr case))))
        (zr-eshell-mode -1))))))
;;; zr-user-tools-test.el ends here
