;;; zr-erc-stitch.el --- Reassemble clipped ERC messages -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1"))
;;; Commentary:
;; Enable `erc-zr-stitch-mode'.  A fragment ending in " <clipped message>"
;; waits for the same sender's next message in that conversation.  Complete
;; sequences are rendered once through ERC's normal formatting pipeline.
;; Incomplete, interrupted or oversized sequences retain their original
;; messages.  All options can be set buffer-locally (including server buffers).
;;; Code:
(require 'zr-erc-common)

(defgroup zr-erc-stitch nil "Reassemble clipped messages." :group 'erc)
(defcustom zr-erc-stitch-rules
  '((:end " <clipped message>\\'" :start "\\`<clipped message> " :separator ""))
  "Rules identifying split messages, evaluated in order.
Each plist accepts :match (a `zr-erc-match-p' selector), :end (a suffix
regexp removed when another fragment follows), :start (an optional prefix
regexp removed from subsequent fragments), and :separator (default empty).
Instead of :end, :more-tag may be (TAG . REGEXP), matching a tag whose value
indicates another fragment follows.  :group-tag optionally requires the
same tag value across fragments.  Nil rules disable stitching locally."
  :type 'sexp :group 'zr-erc-stitch)
(defcustom zr-erc-stitch-timeout 5
  "Seconds to wait for the next fragment before displaying the originals."
  :type 'number :group 'zr-erc-stitch)
(defcustom zr-erc-stitch-max-fragments 32
  "Maximum fragments in one reconstructed message."
  :type 'integer :group 'zr-erc-stitch)
(defcustom zr-erc-stitch-max-length 65536
  "Maximum character count held for a reconstructed message."
  :type 'integer :group 'zr-erc-stitch)

(cl-defstruct zr-erc-stitch--pending
  process rule context originals parts timer timeout max-fragments max-length)
(defvar-local zr-erc-stitch--pending nil)
(defvar zr-erc-stitch--delivering nil)

(defun zr-erc-stitch--cut (text regexp suffix)
  "Remove REGEXP from TEXT only at the start, or end when SUFFIX is non-nil."
  (let ((case-fold-search nil))
    (if (and regexp (string-match regexp text)
             (if suffix (= (match-end 0) (length text)) (= (match-beginning 0) 0)))
        (if suffix (substring text 0 (match-beginning 0))
          (substring text (match-end 0)))
      text)))

(defun zr-erc-stitch--more-p (rule context)
  "Whether RULE and CONTEXT indicate another fragment follows."
  (or (when-let* ((tag (plist-get rule :more-tag)))
        (zr-erc-match-p (list :tags (list tag)) context))
      (when-let* ((regexp (plist-get rule :end))
                  (text (plist-get context :body)))
        (let ((case-fold-search nil))
          (and (string-match regexp text) (= (match-end 0) (length text)))))))

(defun zr-erc-stitch--deliver (process parsed)
  "Pass PARSED to ERC on PROCESS without intercepting it again."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((zr-erc-stitch--delivering t)) (erc-call-hooks process parsed)))))

(defun zr-erc-stitch--flush (buffer key &optional combined)
  "Flush BUFFER's pending KEY; render a single message when COMBINED."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((pending (and zr-erc-stitch--pending
                                (gethash key zr-erc-stitch--pending))))
        (remhash key zr-erc-stitch--pending)
        (when (timerp (zr-erc-stitch--pending-timer pending))
          (cancel-timer (zr-erc-stitch--pending-timer pending)))
        (let* ((messages (reverse (zr-erc-stitch--pending-originals pending)))
               (last (car (last messages)))
               (process (zr-erc-stitch--pending-process pending)))
          (if (not combined)
              (dolist (parsed messages) (zr-erc-stitch--deliver process parsed))
            (let* ((body (string-join
                          (reverse (zr-erc-stitch--pending-parts pending))
                          (or (plist-get (zr-erc-stitch--pending-rule pending)
                                         :separator) "")))
                   (raw (erc-response.unparsed last))
                   (tag-prefix (and (string-prefix-p "@" raw)
                                    (substring raw 0 (1+ (string-search " " raw)))))
                   (target (car (erc-response.command-args last)))
                   (parsed (make-zr-erc-response
                            :sender (erc-response.sender last)
                            :command (erc-response.command last)
                            :command-args (list target body) :contents body
                            :tags (erc-response.tags last)
                            :unparsed (concat tag-prefix ":" (erc-response.sender last)
                                              " " (erc-response.command last)
                                              " " target " :" body)
                            :ids (delete-dups (mapcan #'zr-erc-message-ids messages)))))
              (zr-erc-stitch--deliver process parsed))))))))

(defun zr-erc-stitch--flush-all (&rest _)
  "Display all pending original messages in this server buffer."
  (when zr-erc-stitch--pending
    (dolist (key (hash-table-keys zr-erc-stitch--pending))
      (zr-erc-stitch--flush (current-buffer) key))))

(defun zr-erc-stitch--compatible-p (pending parsed context)
  "Whether PARSED and CONTEXT can extend PENDING."
  (let ((old (car (zr-erc-stitch--pending-originals pending)))
        (rule (zr-erc-stitch--pending-rule pending))
        (previous (zr-erc-stitch--pending-context pending)))
    (and (equal (erc-response.sender old) (erc-response.sender parsed))
         (equal (erc-response.command old) (erc-response.command parsed))
         (zr-erc-match-p (plist-get rule :match) context)
         (cl-every (lambda (tag)
                     (equal (assoc tag (plist-get previous :tags))
                            (assoc tag (plist-get context :tags))))
                   (delq nil (list "+reply" (plist-get rule :group-tag)))))))

(defun zr-erc-stitch--receive (process parsed)
  "Collect marked fragments on PROCESS; let ERC handle other PARSED messages."
  (unless (or zr-erc-stitch--delivering
              (string-prefix-p "\C-a" (erc-response.contents parsed)))
    (let* ((sender (car (erc-parse-user (erc-response.sender parsed))))
           (target (car (erc-response.command-args parsed)))
           (target (if (erc-current-nick-p target) sender target))
           (key (erc-downcase target))
           (server (current-buffer))
           (buffer (or (erc-get-buffer target process) server))
           (context (with-current-buffer buffer (zr-erc-context parsed)))
           (pending (and zr-erc-stitch--pending
                         (gethash key zr-erc-stitch--pending)))
           (rule (if (and pending (zr-erc-stitch--compatible-p pending parsed context))
                     (zr-erc-stitch--pending-rule pending)
                   (when pending (zr-erc-stitch--flush server key) (setq pending nil))
                   (with-current-buffer buffer
                     (cl-find-if
                      (lambda (candidate)
                        (and (zr-erc-match-p (plist-get candidate :match) context)
                             (zr-erc-stitch--more-p candidate context)))
                      zr-erc-stitch-rules)))))
      (when rule
        (unless zr-erc-stitch--pending
          (setq zr-erc-stitch--pending (make-hash-table :test #'equal)))
        (unless pending
          (setq pending
                (with-current-buffer buffer
                  (make-zr-erc-stitch--pending
                   :process process :rule rule :context context
                   :timeout zr-erc-stitch-timeout
                   :max-fragments zr-erc-stitch-max-fragments
                   :max-length zr-erc-stitch-max-length)))
          (puthash key pending zr-erc-stitch--pending))
        (let* ((more (zr-erc-stitch--more-p rule context))
               (body (erc-response.contents parsed))
               (body (if (zr-erc-stitch--pending-originals pending)
                         (zr-erc-stitch--cut body (plist-get rule :start) nil) body)))
          (push parsed (zr-erc-stitch--pending-originals pending))
          (push (if more (zr-erc-stitch--cut body (plist-get rule :end) t) body)
                (zr-erc-stitch--pending-parts pending))
          (when (timerp (zr-erc-stitch--pending-timer pending))
            (cancel-timer (zr-erc-stitch--pending-timer pending)))
          (cond
           ((or (> (length (zr-erc-stitch--pending-originals pending))
                   (zr-erc-stitch--pending-max-fragments pending))
                (> (apply #'+ (mapcar #'length (zr-erc-stitch--pending-parts pending)))
                   (zr-erc-stitch--pending-max-length pending)))
            (zr-erc-stitch--flush server key))
           ((not more) (zr-erc-stitch--flush server key t))
           (t (setf (zr-erc-stitch--pending-timer pending)
                    (run-at-time (zr-erc-stitch--pending-timeout pending) nil
                                 #'zr-erc-stitch--flush server key)))))
        t))))

;;;###autoload (autoload 'erc-zr-stitch-mode "zr-erc-stitch" nil t)
(define-erc-module zr-stitch nil
  "Reassemble messages split by configurable clipping markers or tags."
  ((add-hook 'erc-server-PRIVMSG-functions #'zr-erc-stitch--receive -90)
   (add-hook 'erc-server-NOTICE-functions #'zr-erc-stitch--receive -90)
   (add-hook 'erc-disconnected-hook #'zr-erc-stitch--flush-all)
   (add-hook 'kill-buffer-hook #'zr-erc-stitch--flush-all))
  ((remove-hook 'erc-server-PRIVMSG-functions #'zr-erc-stitch--receive)
   (remove-hook 'erc-server-NOTICE-functions #'zr-erc-stitch--receive)
   (remove-hook 'erc-disconnected-hook #'zr-erc-stitch--flush-all)
   (remove-hook 'kill-buffer-hook #'zr-erc-stitch--flush-all)
   (erc-buffer-list #'zr-erc-stitch--flush-all)))

(provide 'zr-erc-stitch)
;;; zr-erc-stitch.el ends here
