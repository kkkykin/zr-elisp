;;; zr-org-export-test.el --- Tests for zr-org-export -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-org-export)

(ert-deftest zr-org-export-test-latex-path-relative-to-output ()
  (let ((default-directory "/tmp/source/"))
    (should (equal (zr-org-export-latex-image-path
                    "before \\includegraphics[width=2cm]{image.png}" 'latex
                    '(:output-file
                      "/tmp/output/report.tex"))
                   "before \\includegraphics[width=2cm]{../source/image.png}\u200b"))
    (should (equal (zr-org-export-latex-image-path "unchanged" 'html nil) "unchanged"))))

(provide 'zr-org-export-test)
;;; zr-org-export-test.el ends here
