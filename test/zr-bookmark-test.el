;;; zr-bookmark-test.el --- Tests for zr-bookmark -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-bookmark)
(require 'zr-test-helpers)

(ert-deftest zr-bookmark-test-bookmarks-first-save-delete-and-separate ()
  (zr-test-with-temp-directory
    (let ((bookmark-default-file (expand-file-name "local"))
          (bookmark-alist
           '(("s/shared" (filename . "/tmp/shared")) ("local" (filename . "/tmp/local"))))
          (bookmark-default-file-alist nil)
          (bookmark-alist-modification-count 1)
          (bookmark-save-flag nil)
          (bookmark-version-control 'never)
          (zr-bookmark-shared-file (expand-file-name "shared"))
          (bookmark-default-file-locally-set t))
      (unwind-protect
          (progn
            (zr-bookmark-shared-mode 1)
            (zr-bookmark-shared-mode 1)
            (bookmark-save)
            (should (file-exists-p zr-bookmark-shared-file))
            (let (bookmark-alist)
              (setq bookmark-alist (with-temp-buffer
                                     (insert-file-contents bookmark-default-file)
                                     (bookmark-alist-from-buffer)))
              (should (equal (mapcar #'car bookmark-alist) '("local"))))
            (let (bookmark-alist)
              (setq bookmark-alist (with-temp-buffer
                                     (insert-file-contents zr-bookmark-shared-file)
                                     (bookmark-alist-from-buffer)))
              (should (equal (mapcar #'car bookmark-alist) '("s/shared"))))
            (setq bookmark-alist (assoc-delete-all "s/shared" bookmark-alist))
            (bookmark-save)
            (let (bookmark-alist)
              (setq bookmark-alist (with-temp-buffer
                                     (insert-file-contents zr-bookmark-shared-file)
                                     (bookmark-alist-from-buffer)))
              (should-not bookmark-alist))
            (should (equal (mapcar #'car bookmark-alist) '("local"))))
        (zr-bookmark-shared-mode -1))
      (should-not (advice-member-p #'zr-bookmark--save 'bookmark-save)))))

(ert-deftest zr-bookmark-test-explicit-export-remains-whole ()
  (let ((bookmark-default-file "/tmp/zr-default")
        seen)
    (zr-bookmark--save (lambda (&rest args)
                         (setq seen args))
                       nil "/tmp/export" t)
    (should (equal seen '(nil "/tmp/export" t)))))

(ert-deftest zr-bookmark-test-failed-write-keeps-dirty-state ()
  (zr-test-with-temp-directory
    (let ((bookmark-default-file (expand-file-name "local"))
          (zr-bookmark-shared-file (expand-file-name "shared"))
          (bookmark-bookmarks-timestamp nil)
          (bookmark-watch-bookmark-file nil)
          (bookmark-alist '(("s/item" (filename . "/tmp/item"))))
          (bookmark-alist-modification-count 2))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (&rest _)
                   (signal 'file-error '("Write failed")))))
        (should-error (zr-bookmark--save #'bookmark-save) :type 'file-error))
      (should (= bookmark-alist-modification-count 2))
      (should-not bookmark-bookmarks-timestamp))))

(ert-deftest zr-bookmark-test-delete-last-local-and-reload-shared ()
  (zr-test-with-temp-directory
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

(provide 'zr-bookmark-test)
;;; zr-bookmark-test.el ends here
