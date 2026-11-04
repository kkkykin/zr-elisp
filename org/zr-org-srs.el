;;; zr-org-srs.el --- Shared settings for Org-srs tools -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `zr-org-srs-directory' is shared by card capture and directory review.

;;; Code:

(require 'org)

(defgroup zr-org-srs nil
  "Capture and review Org-srs cards."
  :group 'org
  :prefix "zr-org-srs-")

(defcustom zr-org-srs-directory (expand-file-name "srs" org-directory)
  "Directory containing deck Org files and capture media.
Capture maps the Anki deck A::B to A/B.org in this directory.
`zr-org-srs-review-start' reviews the same directory."
  :type 'directory
  :group 'zr-org-srs)

(provide 'zr-org-srs)
;;; zr-org-srs.el ends here
