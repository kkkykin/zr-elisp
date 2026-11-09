;;; nnopds-progress.el --- Progress protocols for nnopds -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Gnus marks remain local.  This module resumes and saves reading locators
;; through a configured KOReader sync server.  Protocol adapters and
;; reading formats share a locator model and a serialized position queue.

;;; Code:

(require 'nnopds)
(require 'gnus-sum)

(autoload 'nnopds-koreader-configure "nnopds-koreader")
(autoload 'nnopds-koreader-authorize "nnopds-koreader")

(defcustom nnopds-progress-sync t
  "Whether OPDS groups resume and save server reading positions.
Synchronization requires an explicit sync URL."
  :type 'boolean :group 'nnopds)

(defcustom nnopds-progress-sync-delay 1.0
  "Seconds to debounce chapter changes before saving a position."
  :type 'number :group 'nnopds)

(defcustom nnopds-progress-device-id (concat "emacs-" (system-name))
  "Device ID used when saving a reading position."
  :type 'string :group 'nnopds)

(defcustom nnopds-progress-device-name (concat "Emacs " (system-name))
  "Device name used when saving a reading position."
  :type 'string :group 'nnopds)

(cl-defstruct (nnopds-progress--state (:constructor nnopds-progress--make-state))
  connection publication buffer timer pending sent in-flight verified suppress closed)

(defvar-local nnopds-progress--state nil)
(defvar nnopds-progress--resuming nil)

(cl-defgeneric nnopds-progress-read (protocol connection endpoint callback)
  "Read an ENDPOINT using PROTOCOL and CONNECTION.
Call CALLBACK with (PROGRESSION ERROR).  Nil progression with nil error
means there is no saved position.  A progression has :locator, :timestamp,
:device and :device_id fields.  :timestamp is Unix time and may be nil.")

(cl-defgeneric nnopds-progress-write (protocol connection endpoint progression callback)
  "Write PROGRESSION to ENDPOINT using PROTOCOL and CONNECTION.
Call CALLBACK with (SUCCESS ERROR); SUCCESS is non-nil after acknowledgement.")

(cl-defgeneric nnopds-progress-initialize (protocol endpoint format data)
  "Return ENDPOINT prepared for reading FORMAT's loaded DATA using PROTOCOL.")

(cl-defgeneric nnopds-progress-local-locator (protocol endpoint locator)
  "Prepare a local LOCATOR for comparison with PROTOCOL's ENDPOINT.")

(defun nnopds-progress-configure (connection)
  "Configure CONNECTION's explicit synchronization settings without HTTP."
  (pcase nnopds-progress-protocol
    ('koreader (when nnopds-koreader-url (nnopds-koreader-configure connection)))
    (_ (error "Unsupported progress protocol: %s" nnopds-progress-protocol))))

(defun nnopds-progress-before-download (connection publication)
  "Authenticate sync before downloading PUBLICATION on CONNECTION.
Calibre only registers downloaded file hashes after KOReader is in use.
A synchronization failure leaves the publication readable locally."
  (when (and nnopds-progress-sync
             (eq (plist-get (nnopds--publication-progress publication) :protocol) 'koreader))
    (condition-case err
        (nnopds-koreader-authorize connection)
      (error
       (setf (nnopds--publication-progress publication) nil)
       (message "nnopds: KOReader authentication failed; reading locally: %s" (error-message-string err))))))

(defun nnopds-progress-loaded (publication)
  "Prepare PUBLICATION's progress adapter after loading its reading data."
  (when-let* ((endpoint (nnopds--publication-progress publication))
              ((not (plist-get endpoint :initialized))))
    (condition-case err
        (progn
          (setq endpoint (nnopds-progress-initialize (plist-get endpoint :protocol) endpoint
                                                     (nnopds--publication-format publication) (nnopds--publication-data publication)))
          (setf (plist-get endpoint :initialized) t
                (nnopds--publication-progress publication) endpoint))
      (error
       (setf (nnopds--publication-progress publication) nil)
       (message "nnopds: Could not prepare progress sync; reading locally: %s" (error-message-string err))))))

(defun nnopds-progress--read (state callback)
  "Read STATE's current server position and call CALLBACK."
  (let ((endpoint (nnopds--publication-progress (nnopds-progress--state-publication state))))
    (nnopds-progress-read (plist-get endpoint :protocol)
                          (nnopds-progress--state-connection state) endpoint callback)))

(defun nnopds-progress--read-now (state)
  "Read STATE's position synchronously.  A failed read signals an error."
  (let (done result failure)
    (nnopds-progress--read state (lambda (progression error)
                                  (setq result progression failure error done t)))
    (while (not done) (accept-process-output nil 0.05))
    (when failure (error "%s" failure))
    result))

(defun nnopds-progress--location (state progression)
  "Locate PROGRESSION in STATE's current reading data."
  (let ((publication (nnopds-progress--state-publication state)))
    (nnopds--locate (nnopds--publication-format publication)
                    (nnopds--publication-data publication) (plist-get progression :locator))))

(defun nnopds-progress--display (state progression)
  "Display PROGRESSION in STATE's summary without saving it again."
  (when-let* ((location (nnopds-progress--location state progression))
              (buffer (nnopds-progress--state-buffer state))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (let ((nnopds-progress--resuming t))
        (gnus-summary-goto-article (car location) nil t)))))

(defun nnopds-progress-prepare ()
  "Install local position hooks in an OPDS summary and resume its book."
  (when (and nnopds-progress-sync
             (string-match-p "\\`nnopds[+:]" gnus-newsgroup-name))
    (let* ((method (gnus-find-method-for-group gnus-newsgroup-name))
           (connection (nnopds--change-server (nth 1 method)))
           (publication (nnopds--get-publication (gnus-group-real-name gnus-newsgroup-name) (nth 1 method) t)))
      (when (nnopds--publication-progress publication)
        (when nnopds-progress--state (nnopds-progress-close nnopds-progress--state))
        (setq-local nnopds-progress--state
                    (nnopds-progress--make-state :connection connection :publication publication
                                                 :buffer (current-buffer)))
        (push (cons (nnopds--publication-group publication) nnopds-progress--state)
              (nnopds--connection-readers connection))
        (add-hook 'gnus-select-article-hook #'nnopds-progress--selected nil t)
        (add-hook 'kill-buffer-hook #'nnopds-progress--killed nil t)
        (condition-case err
            (let ((progression (nnopds-progress--read-now nnopds-progress--state)))
              (setf (nnopds-progress--state-verified nnopds-progress--state) t)
              ;; Initial group selection must not overwrite another reader's
              ;; more precise chapter position, even when Gnus selects again.
              (setf (nnopds-progress--state-suppress nnopds-progress--state)
                    (car (nnopds-progress--location nnopds-progress--state progression)))
              (nnopds-progress--display nnopds-progress--state progression)
              (unless progression (nnopds-progress--selected)))
          (error (message "nnopds: Could not read server position; sync disabled for this book: %s"
                          (error-message-string err))))))))

(defun nnopds-progress--selected ()
  "Queue the displayed article's position; backend prefetch never calls this."
  (when (and nnopds-progress--state nnopds-progress-sync
             (not nnopds-progress--resuming))
    (let* ((state nnopds-progress--state)
           (publication (nnopds-progress--state-publication state))
           (article gnus-current-article))
      (when (and (nnopds-progress--state-verified state)
                 (not (nnopds-progress--state-closed state))
                 (integerp article) (> article 0))
        (if (eq article (nnopds-progress--state-suppress state))
            nil
          (setf (nnopds-progress--state-suppress state) nil)
          (when-let* ((locator (nnopds--locator (nnopds--publication-format publication)
                                               (nnopds--publication-data publication)
                                               (nnopds--chapter publication article))))
            (let ((endpoint (nnopds--publication-progress publication)))
              (setq locator (nnopds-progress-local-locator (plist-get endpoint :protocol) endpoint locator)))
            (if (and (equal locator (nnopds-progress--state-sent state))
                     (not (nnopds-progress--state-in-flight state)))
                (progn
                  (setf (nnopds-progress--state-pending state) nil)
                  (when-let* ((timer (nnopds-progress--state-timer state))) (cancel-timer timer))
                  (setf (nnopds-progress--state-timer state) nil))
              (setf (nnopds-progress--state-pending state)
                    (list :timestamp (float-time)
                          :device nnopds-progress-device-name :device_id nnopds-progress-device-id
                          :locator locator))
              (when-let* ((timer (nnopds-progress--state-timer state))) (cancel-timer timer))
              (setf (nnopds-progress--state-timer state)
                    (run-with-timer (max 0 nnopds-progress-sync-delay) nil #'nnopds-progress--flush state)))))))))

(defun nnopds-progress--ahead-p (state server pending)
  "Whether SERVER is later than PENDING and belongs to another device."
  (when (and server (not (equal (plist-get server :device_id) (plist-get pending :device_id))))
    (let ((remote (nnopds-progress--location state server))
          (local (nnopds-progress--location state pending)))
      (or (not remote) (not local)
          (> (car remote) (car local))
          (and (= (car remote) (car local))
               (let* ((remote-locations (plist-get (plist-get server :locator) :locations))
                      (local-locations (plist-get (plist-get pending :locator) :locations)))
                 (> (plist-get remote-locations :totalProgression) (plist-get local-locations :totalProgression))))))))

(defun nnopds-progress--finished (state pending success message-text)
  "Finish STATE's attempt to save PENDING and drain newer queued work."
  (setf (nnopds-progress--state-in-flight state) nil)
  (when success (setf (nnopds-progress--state-sent state) (plist-get pending :locator)))
  (when message-text (message "nnopds: %s" message-text))
  (if (eq pending (nnopds-progress--state-pending state))
      ;; Retry only on an explicit save or a subsequent reading event.
      (setf (nnopds-progress--state-pending state) nil)
    (nnopds-progress--flush state)))

(defun nnopds-progress--newer-p (state server pending)
  "Whether SERVER's timestamp supersedes STATE's PENDING reading event."
  (when-let* ((stamp (plist-get server :timestamp)))
    ;; KOReader timestamps the write on receipt.  An acknowledged in-flight
    ;; write may therefore be timestamped after the next queued chapter.
    (unless (and (equal (plist-get server :device_id) (plist-get pending :device_id))
                 (equal (plist-get server :locator) (nnopds-progress--state-sent state)))
      (>= stamp (plist-get pending :timestamp)))))

(defun nnopds-progress--flush (state)
  "Save the newest pending position for STATE, one request at a time."
  (when-let* ((timer (nnopds-progress--state-timer state))) (cancel-timer timer))
  (setf (nnopds-progress--state-timer state) nil)
  (when (and nnopds-progress-sync (nnopds-progress--state-verified state)
             (not (nnopds-progress--state-closed state))
             (not (nnopds-progress--state-in-flight state)))
    (when-let* ((pending (nnopds-progress--state-pending state)))
      (setf (nnopds-progress--state-in-flight state) t)
      (condition-case err
          (nnopds-progress--read
           state
           (lambda (server error)
             (condition-case failure
                 (cond
                  ((null (nnopds-progress--state-pending state))
                   (nnopds-progress--finished state pending nil nil))
                  (error (nnopds-progress--finished state pending nil
                                                    (format "Could not check server position; not saved: %s" error)))
                  ((or (nnopds-progress--ahead-p state server pending)
                       (nnopds-progress--newer-p state server pending))
                   (nnopds-progress--finished state pending nil
                                              "Server position is newer or further along; use nnopds-resume to refresh"))
                  (t
                   (let ((endpoint (nnopds--publication-progress (nnopds-progress--state-publication state))))
                     (nnopds-progress-write
                      (plist-get endpoint :protocol) (nnopds-progress--state-connection state)
                      endpoint pending
                      (lambda (success error)
                        (nnopds-progress--finished
                         state pending success (when error (format "Position not saved: %s" error))))))))
               (error (nnopds-progress--finished state pending nil (error-message-string failure))))))
        (error (nnopds-progress--finished state pending nil (error-message-string err)))))))

(defun nnopds-progress--killed ()
  "Start saving a killed summary's pending position."
  (when nnopds-progress--state (nnopds-progress--flush nnopds-progress--state)))

(defun nnopds-progress-close (state)
  "Flush STATE before closing its group and remove its timer and registration."
  (unless (nnopds-progress--state-closed state)
    (nnopds-progress--flush state)
    (unwind-protect
        (while (nnopds-progress--state-in-flight state) (accept-process-output nil 0.05))
      (when-let* ((timer (nnopds-progress--state-timer state))) (cancel-timer timer))
      (setf (nnopds-progress--state-timer state) nil
            (nnopds-progress--state-closed state) t)
      (let ((connection (nnopds-progress--state-connection state)))
        (setf (nnopds--connection-readers connection)
              (cl-delete state (nnopds--connection-readers connection) :key #'cdr :test #'eq))))))

(defun nnopds-progress--current-state ()
  "Return the current OPDS summary's position state."
  (let ((buffer (if (derived-mode-p 'gnus-summary-mode) (current-buffer)
                  (get-buffer gnus-summary-buffer))))
    (or (and buffer (buffer-local-value 'nnopds-progress--state buffer))
        (user-error "This book has no supported progress protocol"))))

;;;###autoload
(defun nnopds-resume ()
  "Refresh and display this OPDS book's saved server chapter."
  (interactive)
  (let ((state (nnopds-progress--current-state)))
    (when-let* ((timer (nnopds-progress--state-timer state))) (cancel-timer timer))
    (setf (nnopds-progress--state-pending state) nil
          (nnopds-progress--state-timer state) nil)
    (while (nnopds-progress--state-in-flight state) (accept-process-output nil 0.05))
    (let ((progression (nnopds-progress--read-now state)))
      (setf (nnopds-progress--state-verified state) t
            (nnopds-progress--state-suppress state) (car (nnopds-progress--location state progression)))
      (unless (nnopds-progress--display state progression)
        (message "nnopds: No matching saved chapter")))))

;;;###autoload
(defun nnopds-save-position ()
  "Save this OPDS book's current chapter now, checking server progress first."
  (interactive)
  (let ((state (nnopds-progress--current-state)))
    (unless (nnopds-progress--state-verified state)
      (nnopds-progress--read-now state)
      (setf (nnopds-progress--state-verified state) t))
    (setf (nnopds-progress--state-suppress state) nil
          (nnopds-progress--state-sent state) nil)
    (with-current-buffer (nnopds-progress--state-buffer state) (nnopds-progress--selected))
    (nnopds-progress--flush state)))

(provide 'nnopds-progress)
;;; nnopds-progress.el ends here
