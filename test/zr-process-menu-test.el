;;; zr-process-menu-test.el --- Tests for zr-process-menu -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-process-menu)

(ert-deftest zr-process-menu-test-process-filter-groups-display-only ()
  (with-temp-buffer
    (let ((tabulated-list-entries '((one ["server" "run"]) (two ["worker" "run"])))
          (zr-process-menu-omit-regexp "server")
          (zr-process-menu-group-column 1))
      (zr-process-menu--refresh)
      (should (equal (mapcar #'car tabulated-list-entries) '(two)))
      (should (equal (caar tabulated-list-groups) "* run")))))

(provide 'zr-process-menu-test)
;;; zr-process-menu-test.el ends here
