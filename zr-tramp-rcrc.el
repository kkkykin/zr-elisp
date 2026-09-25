;;; zr-tramp-rcrc.el --- TRAMP file access through rclone rc -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, files

;;; Commentary:

;; File access through an rclone remote-control daemon (rcd), without a
;; mount, FUSE or a remote shell:
;;
;;   (require 'zr-tramp-rcrc)
;;   (dired "/rcrc:127.0.0.1#5572:/")
;;   (find-file "/rcrc:127.0.0.1#5572:/drive:/notes/todo.org")
;;
;; HOST#PORT selects the rcd.  The local name is a view of rclone paths
;; on that daemon:
;;
;;   /                  configured remotes (NAME:) and the rcd machine's root
;;   /NAME:/dir/file    NAME:dir/file
;;   /srv/dir/file      /srv/dir/file on the rcd machine
;;   /C:/dir/file       C:/dir/file on a Windows rcd
;;
;; NAME:/dir is shown as NAME:dir, which is equivalent for most backends.
;; UNC shares and connection strings (:backend,opt=value:) have no rcrc
;; name.
;;
;; RC requests are JSON over HTTP.  File contents are read from the
;; daemon's object server, so rcd must run with --rc-serve.  The daemon
;; URL (including any reverse proxy path or https) and credentials are set
;; with `zr-tramp-rcrc-register-endpoint'.  An unregistered HOST#PORT uses
;; http://HOST:PORT/ and Basic credentials from auth-source, for example:
;;   machine 127.0.0.1 port 5572 login zr-rclone password SECRET
;;
;; Supports visiting and saving files, completion, Dired, creating and
;; deleting directories, and copying or renaming.  Within one rcd,
;; copies and renames run on the server (copyfile, movefile, sync/move);
;; transfers to or from other file systems are staged locally.  Modes
;; and ownership are synthetic; setting them or file times is a no-op.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'subr-x)
(require 'tramp)
(require 'url)
(require 'url-http)
(defvar url-http-response-status)

(defgroup zr-tramp-rcrc nil
  "TRAMP file access through rclone rc."
  :group 'tramp)

(defcustom zr-tramp-rcrc-timeout 60
  "Maximum number of seconds to wait for one RC or object request."
  :type 'number)

(defvar zr-tramp-rcrc--endpoints (make-hash-table :test #'equal)
  "Registered rcd endpoints, keyed by \"HOST#PORT\".
Each value is a plist with :url, :user and :password.")

;;; Rclone paths and file names

(defun zr-tramp-rcrc-split (path)
  "Split absolute rclone PATH into (ROOT . RELATIVE), or return nil.
Preserve remote: versus remote:/ and support Windows drives, UNC
shares, and quoted connection-string parameters."
  (cond
   ((string-prefix-p "\\\\" path)
    (zr-tramp-rcrc-split (replace-regexp-in-string "\\\\" "/" path t t)))
   ((string-match "\\`\\([[:alpha:]]:\\)[/\\\\]" path)
    (cons (concat (match-string 1 path) "/")
          (replace-regexp-in-string "\\\\" "/" (substring path 3) t t)))
   ((string-match "\\`//[^/]+/[^/]+\\(?:/\\|\\'\\)" path)
    (let ((end (match-end 0)))
      (cons (concat (string-remove-suffix "/" (substring path 0 end)) "/")
            (substring path end))))
   ((string-prefix-p "/" path) (cons "/" (substring path 1)))
   (t
    (let ((index (if (string-prefix-p ":" path) 1 0)) quote end stop)
      (while (and (< index (length path)) (not end) (not stop))
        (let ((char (aref path index)))
          (cond
           (quote (when (= char quote) (setq quote nil)))
           ((memq char '(?\' ?\")) (setq quote char))
           ((= char ?:) (setq end (1+ index)))
           ((= char ?/) (setq stop t))))
        (setq index (1+ index)))
      (when end
        (when (and (< end (length path)) (= (aref path end) ?/))
          (setq end (1+ end)))
        (cons (substring path 0 end) (substring path end)))))))

(defun zr-tramp-rcrc--localname (path)
  "Convert absolute rclone PATH, or nil for the top level, to a local name."
  (if (not path) "/"
    (let* ((parts (or (zr-tramp-rcrc-split path)
                      (user-error "Not an absolute rclone path: %s" path)))
           (root (car parts)))
      (concat
       (cond ((equal root "/") "/")
             ;; A second colon would make TRAMP parse the local name itself.
             ((string-match "\\`\\([^/:]+:\\)/?\\'" root)
              (concat "/" (match-string 1 root) "/"))
             (t (user-error "%s has no rcrc file name" path)))
       (cdr parts)))))

(defun zr-tramp-rcrc--fs (localname)
  "Return (FS . REMOTE) for rcrc LOCALNAME, or nil for the top level."
  (when-let* ((parts (split-string localname "/" t)))
    (let ((first (car parts)) (rest (string-join (cdr parts) "/")))
      (cond ((string-match-p "\\`[[:alpha:]]:\\'" first) (cons (concat first "/") rest))
            ((string-match-p "\\`[^:]+:\\'" first) (cons first rest))
            (t (cons "/" (string-join parts "/")))))))

(defun zr-tramp-rcrc--host-port (url)
  "Return (HOST . PORT) of rcd URL as used in file names."
  (let ((parsed (url-generic-parse-url url)))
    (cons (string-trim (url-host parsed) "\\[" "\\]")
          (number-to-string (url-port parsed)))))

(defun zr-tramp-rcrc-file-name (url path)
  "Return the rcrc file name of rclone PATH on the rcd at URL.
PATH nil names the top level.  A trailing slash is preserved."
  (let ((address (zr-tramp-rcrc--host-port url)))
    (tramp-make-tramp-file-name
     (make-tramp-file-name :method "rcrc" :host (car address) :port (cdr address)
                           :localname (zr-tramp-rcrc--localname path)))))

(defun zr-tramp-rcrc-rclone-path (file)
  "Return the rclone path named by rcrc FILE, or nil for the top level.
A trailing slash is preserved below the root of a file system."
  (let ((fs (zr-tramp-rcrc--fs
             (tramp-file-name-unquote-localname
              (tramp-dissect-file-name (expand-file-name file))))))
    (when fs
      (concat (car fs) (cdr fs)
              (when (and (not (string-empty-p (cdr fs))) (directory-name-p file))
                "/")))))

(defun zr-tramp-rcrc--object-path (fs remote)
  "Return the --rc-serve path of REMOTE in file system FS."
  (concat (url-hexify-string (format "[%s]" fs)) "/"
          (mapconcat #'url-hexify-string (split-string remote "/") "/")))

(defun zr-tramp-rcrc-object-url (url fs remote)
  "Return the --rc-serve URL of REMOTE in file system FS on the rcd at URL."
  (concat url (zr-tramp-rcrc--object-path fs remote)))

;;; Endpoints and requests

(defun zr-tramp-rcrc-register-endpoint (url &optional user password)
  "Use rcd URL with USER and PASSWORD for file names of its HOST#PORT.
URL may include https and a reverse proxy path.  Without USER and
PASSWORD, credentials come from auth-source.  A later registration of
the same HOST#PORT replaces the earlier one."
  (let ((address (zr-tramp-rcrc--host-port url)))
    (puthash (format "%s#%s" (downcase (car address)) (cdr address))
             (list :url (concat (string-remove-suffix "/" url) "/")
                   :user user :password password)
             zr-tramp-rcrc--endpoints)))

(defun zr-tramp-rcrc-credentials (url &optional user password)
  "Return (USER . PASSWORD) for rcd URL, looking up auth-source if needed."
  (if (and user password)
      (cons user password)
    (let ((parsed (url-generic-parse-url url)))
      (when-let* ((entry (car (auth-source-search
                              :host (url-host parsed)
                              :port (number-to-string (url-port parsed))
                              :user (or user t) :require '(:user :secret)
                              :max 1)))
                  (secret (plist-get entry :secret)))
        (cons (plist-get entry :user)
              (if (functionp secret) (funcall secret) secret))))))

(defun zr-tramp-rcrc-basic-header (credentials)
  "Build a Basic authorization header from CREDENTIALS, or return nil."
  (when credentials
    (concat "Basic "
            (base64-encode-string
             (encode-coding-string
              (concat (car credentials) ":" (cdr credentials)) 'utf-8) t))))

(defun zr-tramp-rcrc--endpoint (vec)
  "Return the endpoint plist for TRAMP vector VEC."
  (let ((host (tramp-file-name-host vec))
        (port (format "%s" (tramp-file-name-port-or-default vec))))
    (or (gethash (format "%s#%s" (downcase host) port) zr-tramp-rcrc--endpoints)
        (list :url (format "http://%s:%s/"
                           (if (string-search ":" host) (concat "[" host "]") host)
                           port)))))

(defun zr-tramp-rcrc--http (vec method path &optional headers data)
  "Send METHOD for PATH below VEC's rcd URL with HEADERS and byte DATA.
Return (STATUS . BODY), where BODY holds the response bytes."
  (when non-essential (throw 'zr-tramp-rcrc--non-essential nil))
  (let* ((endpoint (zr-tramp-rcrc--endpoint vec))
         (url (concat (plist-get endpoint :url) path))
         (user (or (tramp-file-name-user vec) (plist-get endpoint :user)))
         (credentials (zr-tramp-rcrc-credentials
                       (plist-get endpoint :url) user
                       (and (equal user (plist-get endpoint :user))
                            (plist-get endpoint :password))))
         (default-directory temporary-file-directory)
         (url-request-method method)
         ;; An explicit empty field keeps url-http from prompting for auth.
         (url-request-extra-headers
          (cons (cons "Authorization" (or (zr-tramp-rcrc-basic-header credentials) ""))
                headers))
         (url-request-data data)
         (url-request-noninteractive t)
         (url-show-status nil)
         (url-max-redirections 0)
         (url-http-attempt-keepalives nil)
         (url-mime-encoding-string nil)
         (url-automatic-caching nil)
         (coding-system-for-read 'no-conversion)
         (coding-system-for-write 'no-conversion)
         (deadline (+ (float-time) zr-tramp-rcrc-timeout))
         buffer done)
    (unwind-protect
        (progn
          (setq buffer (url-retrieve url (lambda (_status) (setq done t)) nil t t))
          (unless (buffer-live-p buffer)
            (signal 'file-error (list "Cannot connect to rcd" url)))
          (while (and (not done) (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (unless done (signal 'file-error (list "rcd request timed out" url)))
          (with-current-buffer buffer
            (goto-char (point-min))
            (unless (re-search-forward "\r?\n\r?\n" nil t)
              (signal 'file-error (list "Incomplete rcd response" url)))
            (cons (or url-http-response-status 0)
                  (buffer-substring-no-properties (point) (point-max)))))
      (when (buffer-live-p buffer)
        (when-let* ((process (get-buffer-process buffer)))
          (delete-process process))
        (kill-buffer buffer)))))

(defun zr-tramp-rcrc--result (method response)
  "Decode the RC METHOD RESPONSE, signaling a file error on failure."
  (let ((result (ignore-errors
                  (json-parse-string (decode-coding-string (cdr response) 'utf-8)
                                     :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil))))
    (unless (<= 200 (car response) 299)
      (signal (if (= (car response) 404) 'file-missing 'file-error)
              (list (format "rclone %s failed" method)
                    (or (alist-get 'error result) (format "HTTP %s" (car response))))))
    result))

(defun zr-tramp-rcrc--call (vec method &optional params)
  "Call RC METHOD with alist PARAMS on VEC's rcd and return the result."
  (zr-tramp-rcrc--result
   method
   (zr-tramp-rcrc--http
    vec "POST" method '(("Content-Type" . "application/json"))
    (encode-coding-string
     (json-serialize (or params (make-hash-table)) :null-object nil :false-object :false)
     'utf-8))))

(defun zr-tramp-rcrc--location (file)
  "Return (VEC FS . REMOTE) for FILE, which must name a path below the top."
  (let* ((vec (tramp-dissect-file-name (expand-file-name file)))
         (fs (zr-tramp-rcrc--fs (tramp-file-name-unquote-localname vec))))
    (unless fs (signal 'file-error (list "Not a file on the rcd" file)))
    (cons vec fs)))

(defun zr-tramp-rcrc--params (file &optional prefix)
  "Return fs and remote parameters for FILE, optionally named with PREFIX."
  (let ((location (zr-tramp-rcrc--location file)))
    (if prefix
        (list (cons (intern (concat prefix "Fs")) (cadr location))
              (cons (intern (concat prefix "Remote")) (cddr location)))
      (list (cons 'fs (cadr location)) (cons 'remote (cddr location))))))

;;; Metadata

(defconst zr-tramp-rcrc--directory '(:directory t :size 0)
  "Metadata of synthetic directories: the top level and file system roots.")

(defun zr-tramp-rcrc-file-name-p (file)
  "Whether FILE, a TRAMP vector or file name, uses this backend."
  (when-let* ((vec (tramp-ensure-dissected-file-name file)))
    (equal (tramp-file-name-method vec) "rcrc")))

(defun zr-tramp-rcrc--entry (item)
  "Convert an rclone list or stat ITEM to a metadata plist."
  (list :directory (eq (alist-get 'IsDir item) t)
        :size (max 0 (or (alist-get 'Size item) 0))
        :mtime (ignore-errors (date-to-time (alist-get 'ModTime item)))))

(defun zr-tramp-rcrc--stat (file &optional fresh)
  "Return metadata for FILE, or nil if missing; FRESH bypasses the cache."
  (with-parsed-tramp-file-name (expand-file-name file) nil
    (let ((remote-file-name-inhibit-cache (or fresh remote-file-name-inhibit-cache)))
      (with-tramp-file-property v localname "zr-rcrc-stat"
        (let ((fs (zr-tramp-rcrc--fs localname)))
          (if (or (not fs) (string-empty-p (cdr fs)))
              zr-tramp-rcrc--directory
            (when-let* ((item (alist-get 'item (zr-tramp-rcrc--call
                                               v "operations/stat"
                                               (zr-tramp-rcrc--params file)))))
              (zr-tramp-rcrc--entry item))))))))

(defun zr-tramp-rcrc--list (vec fs remote)
  "Return (NAME . METADATA) pairs of directory REMOTE in FS on VEC's rcd."
  (mapcar (lambda (item) (cons (alist-get 'Name item) (zr-tramp-rcrc--entry item)))
          (alist-get 'list (zr-tramp-rcrc--call
                            vec "operations/list"
                            (list (cons 'fs fs) (cons 'remote remote)
                                  '(opt . ((noMimeType . t))))))))

(defun zr-tramp-rcrc--top (vec)
  "Return the configured remotes and machine roots of VEC's rcd."
  (append
   (mapcar (lambda (name) (cons (concat name ":") zr-tramp-rcrc--directory))
           (alist-get 'remotes (zr-tramp-rcrc--call vec "config/listremotes")))
   (if (equal (alist-get 'os (zr-tramp-rcrc--call vec "core/version")) "windows")
       (delete-dups
        (delq nil (mapcar (lambda (disk)
                            (when (string-match "\\`[[:alpha:]]:" disk)
                              (cons (upcase (match-string 0 disk)) zr-tramp-rcrc--directory)))
                          (alist-get 'disks (zr-tramp-rcrc--call vec "core/disks")))))
     (zr-tramp-rcrc--list vec "/" ""))))

(defun zr-tramp-rcrc--directory-entries (directory)
  "Return (NAME . METADATA) pairs for DIRECTORY, including . and .."
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (with-parsed-tramp-file-name directory nil
    (with-tramp-file-property v localname "directory-rcrc"
      (let* ((fs (zr-tramp-rcrc--fs localname))
             (entries (if fs (zr-tramp-rcrc--list v (car fs) (cdr fs))
                        (zr-tramp-rcrc--top v))))
        (dolist (entry entries)
          (tramp-set-file-property
           v (concat (file-name-as-directory localname) (car entry))
           "zr-rcrc-stat" (cdr entry)))
        (append (list (cons "." zr-tramp-rcrc--directory)
                      (cons ".." zr-tramp-rcrc--directory))
                entries)))))

(defun zr-tramp-rcrc--attributes (entry file id-format)
  "Convert metadata ENTRY for FILE to file attributes in ID-FORMAT."
  (when entry
    (let ((directory (plist-get entry :directory))
          (unknown (if (eq id-format 'string) "unknown" -1))
          (mtime (or (plist-get entry :mtime) '(0 0))))
      (list directory 1 unknown unknown mtime mtime mtime (plist-get entry :size)
            (if directory "drwx------" "-rw-------") nil
            (abs (sxhash-equal (directory-file-name (expand-file-name file))))
            (cons -1 (abs (sxhash-equal (file-remote-p file))))))))

(defun zr-tramp-rcrc--file-attributes (file &optional id-format)
  "Implement `file-attributes' for FILE and ID-FORMAT."
  (zr-tramp-rcrc--attributes (zr-tramp-rcrc--stat file) file id-format))

(defun zr-tramp-rcrc--directory-files-and-attributes
    (directory &optional full match nosort id-format count)
  "Implement `directory-files-and-attributes' with its usual arguments."
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (let (result)
    (dolist (entry (zr-tramp-rcrc--directory-entries directory))
      (when (or (not match) (string-match-p match (car entry)))
        (let ((file (concat directory (car entry))))
          (push (cons (if full file (car entry))
                      (zr-tramp-rcrc--attributes (cdr entry) file id-format))
                result))))
    (setq result (if nosort (nreverse result)
                   (sort result (lambda (a b) (string< (car a) (car b))))))
    (if (natnump count) (seq-take result count) result)))

(defun zr-tramp-rcrc--directory-files (directory &optional full match nosort count)
  "Implement `directory-files' with its usual arguments."
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (let (result)
    (dolist (entry (zr-tramp-rcrc--directory-entries directory))
      (when (or (not match) (string-match-p match (car entry)))
        (push (if full (concat directory (car entry)) (car entry)) result)))
    (setq result (if nosort (nreverse result) (sort result #'string<)))
    (if (natnump count) (seq-take result count) result)))

(defun zr-tramp-rcrc--all-completions (file directory)
  "Return completions for FILE in DIRECTORY."
  (tramp-skeleton-file-name-all-completions file directory
    (let ((completion-ignore-case read-file-name-completion-ignore-case))
      (all-completions
       file (mapcar (lambda (entry)
                      (if (plist-get (cdr entry) :directory)
                          (file-name-as-directory (car entry)) (car entry)))
                    (zr-tramp-rcrc--directory-entries directory))))))

(defun zr-tramp-rcrc--file-exists-p (file)
  "Whether FILE exists.  Preserve transport and permission errors."
  (and (zr-tramp-rcrc--stat file) t))

(defun zr-tramp-rcrc--file-writable-p (file)
  "Estimate whether FILE can be written; the server has the final say."
  (or (zr-tramp-rcrc--file-exists-p file)
      (file-directory-p (file-name-directory (directory-file-name (expand-file-name file))))))

(defun zr-tramp-rcrc--remote-id (_vec id-format)
  "Return the synthetic owner ID in ID-FORMAT."
  (if (eq id-format 'string) "unknown" -1))

(defun zr-tramp-rcrc--verify-visited-file-modtime (&optional buffer)
  "Check BUFFER's visited modification time against the rcd."
  (with-current-buffer (or buffer (current-buffer))
    (let ((modtime (visited-file-modtime)))
      (if (or (not buffer-file-name) (equal modtime 0)) t
        (let ((entry (zr-tramp-rcrc--stat buffer-file-name t)))
          (cond ((not entry) (time-equal-p modtime tramp-time-doesnt-exist))
                ;; Both times come from the same rclone metadata.
                ((plist-get entry :mtime) (time-equal-p (plist-get entry :mtime) modtime))
                (t t)))))))

;;; Contents and mutations

(defun zr-tramp-rcrc--flush (file)
  "Invalidate FILE, its descendants and its parent's directory listing."
  (with-parsed-tramp-file-name (expand-file-name file) nil
    (tramp-flush-directory-properties v localname)))

(defun zr-tramp-rcrc--mutate (file method &optional params)
  "Run RC METHOD for FILE with extra PARAMS, then invalidate its cache."
  (unwind-protect
      (zr-tramp-rcrc--call (car (zr-tramp-rcrc--location file)) method
                           (append (zr-tramp-rcrc--params file) params))
    (zr-tramp-rcrc--flush file)))

(defun zr-tramp-rcrc--read-bytes (file)
  "Read local FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun zr-tramp-rcrc--write-bytes (data file)
  "Write byte string DATA to local FILE without conversion."
  (let ((coding-system-for-write 'no-conversion)
        (file-name-handler-alist nil)
        (write-region-annotate-functions nil)
        (write-region-post-annotation-function nil)
        (create-lockfiles nil))
    (write-region data nil file nil 'silent)))

(defun zr-tramp-rcrc--download (file local)
  "Copy the contents of rcrc FILE to LOCAL file."
  (let* ((location (zr-tramp-rcrc--location file))
         (response (zr-tramp-rcrc--http
                    (car location) "GET"
                    (zr-tramp-rcrc--object-path (cadr location) (cddr location)))))
    (unless (= (car response) 200)
      (cond ((/= (car response) 404)
             (signal 'file-error (list (format "Cannot read: HTTP %s" (car response)) file)))
            ;; Not a file error: TRAMP reports those as missing files.
            ((zr-tramp-rcrc--stat file t)
             (user-error "rcd does not serve objects; start it with --rc-serve: %s" file))
            (t (signal 'file-missing (list "No such file" file)))))
    (zr-tramp-rcrc--write-bytes (cdr response) local)))

(defun zr-tramp-rcrc--upload (local file)
  "Replace rcrc FILE with the contents of LOCAL file."
  (let* ((location (zr-tramp-rcrc--location file))
         (remote (cddr location))
         (slash (string-match "/[^/]*\\'" remote))
         (name (substring remote (if slash (1+ slash) 0)))
         (boundary (format "zr-rcrc-%x-%x" (random most-positive-fixnum) (emacs-pid)))
         (body (concat "--" boundary "\r\n"
                       "Content-Disposition: form-data; name=\"file0\"; "
                       "filename*=utf-8''" (url-hexify-string name) "\r\n"
                       "Content-Type: application/octet-stream\r\n\r\n"
                       (zr-tramp-rcrc--read-bytes local)
                       "\r\n--" boundary "--\r\n")))
    (when (string-empty-p name)
      (signal 'file-error (list "Cannot write the root of a file system" file)))
    (unwind-protect
        (zr-tramp-rcrc--result
         "operations/uploadfile"
         (zr-tramp-rcrc--http
          (car location) "POST"
          (format "operations/uploadfile?fs=%s&remote=%s"
                  (url-hexify-string (cadr location))
                  (url-hexify-string (if slash (substring remote 0 slash) "")))
          (list (cons "Content-Type" (concat "multipart/form-data; boundary=" boundary)))
          body))
      (zr-tramp-rcrc--flush file))))

(defun zr-tramp-rcrc--make-directory (directory &optional parents)
  "Create DIRECTORY, optionally creating PARENTS."
  (setq directory (directory-file-name (expand-file-name directory)))
  (let ((entry (zr-tramp-rcrc--stat directory t)))
    (if entry
        (unless (and parents (plist-get entry :directory))
          (signal 'file-already-exists (list "File exists" directory)))
      (unless (or parents (file-directory-p (file-name-directory directory)))
        (signal 'file-missing (list "Parent directory does not exist" directory)))
      (zr-tramp-rcrc--mutate directory "operations/mkdir"))
    (and entry t)))

(defun zr-tramp-rcrc--delete-file (file &optional trash)
  "Delete FILE; refuse an unsupported TRASH request."
  (when (and trash delete-by-moving-to-trash)
    (signal 'file-error '("rcrc does not support trash")))
  (when (file-directory-p file)
    (signal 'file-error (list "File is a directory" file)))
  (zr-tramp-rcrc--mutate file "operations/deletefile")
  nil)

(defun zr-tramp-rcrc--delete-directory (directory &optional recursive trash)
  "Delete DIRECTORY, including its contents if RECURSIVE; honor TRASH."
  (when (and trash delete-by-moving-to-trash)
    (signal 'file-error '("rcrc does not support trash")))
  (setq directory (directory-file-name (expand-file-name directory)))
  (when (string-empty-p (cddr (zr-tramp-rcrc--location directory)))
    (signal 'file-error (list "Refusing to delete the root of a file system" directory)))
  (unless (file-directory-p directory)
    (signal 'file-error (list "Not a directory" directory)))
  (zr-tramp-rcrc--mutate directory (if recursive "operations/purge" "operations/rmdir"))
  nil)

(defun zr-tramp-rcrc--destination (file newname)
  "Expand NEWNAME, appending the base name of FILE for a directory name."
  (setq newname (expand-file-name newname))
  (if (directory-name-p newname)
      (concat newname (file-name-nondirectory (directory-file-name file)))
    newname))

(defun zr-tramp-rcrc--check-destination (file newname okay &optional directory)
  "Check a copy/move from FILE to NEWNAME with overwrite option OKAY.
DIRECTORY permits replacing an empty directory."
  (when (equal (expand-file-name file) (expand-file-name newname))
    (signal 'file-error (list "Source and destination are the same file" file)))
  (let* ((remote-file-name-inhibit-cache t)
         (exists (file-exists-p newname)))
    (when (and exists
               (or (not okay)
                   (and (integerp okay)
                        (not (y-or-n-p (format "File %s exists; overwrite? " newname))))))
      (signal 'file-already-exists (list "File exists" newname)))
    (when (and exists (file-directory-p newname)
               (or (not directory)
                   (directory-files newname nil directory-files-no-dot-files-regexp)))
      (signal 'file-error (list "Cannot overwrite a directory" newname)))
    (when (and exists directory (not (file-directory-p newname)))
      (signal 'file-error (list "Cannot replace a file with a directory" newname)))))

(defun zr-tramp-rcrc--same-rcd-p (file newname)
  "Whether FILE and NEWNAME are on the same rcd."
  (and (zr-tramp-rcrc-file-name-p file) (zr-tramp-rcrc-file-name-p newname)
       (tramp-equal-remote file newname)))

(defun zr-tramp-rcrc--transfer (file newname move &optional keep-time)
  "Copy, or MOVE, regular FILE to NEWNAME; KEEP-TIME for local targets."
  (cond
   ((zr-tramp-rcrc--same-rcd-p file newname)
    (unwind-protect
        (zr-tramp-rcrc--call
         (car (zr-tramp-rcrc--location file))
         (if move "operations/movefile" "operations/copyfile")
         (append (zr-tramp-rcrc--params file "src")
                 (zr-tramp-rcrc--params newname "dst")))
      (zr-tramp-rcrc--flush file)
      (zr-tramp-rcrc--flush newname)))
   ((zr-tramp-rcrc-file-name-p file)
    (let* ((local (not (file-remote-p newname)))
           (temp (if local newname (tramp-compat-make-temp-file file))))
      (unwind-protect
          (progn
            (zr-tramp-rcrc--download file temp)
            (when keep-time
              (set-file-times temp (file-attribute-modification-time
                                    (file-attributes file))))
            (unless local (copy-file temp newname t keep-time)))
        (unless local (delete-file temp))))
    (when move (delete-file file)))
   (t
    (let ((temp (file-local-copy file)))
      (unwind-protect (zr-tramp-rcrc--upload (or temp file) newname)
        (when temp (delete-file temp))))
    (when move (delete-file file)))))

(defun zr-tramp-rcrc--copy-file
    (file newname &optional okay keep-time _preserve-uid-gid _preserve-permissions)
  "Implement `copy-file' for FILE, NEWNAME, OKAY and KEEP-TIME."
  (setq file (expand-file-name file)
        newname (zr-tramp-rcrc--destination file newname))
  (when (file-directory-p file)
    (signal 'file-error (list "Cannot copy a directory with copy-file" file)))
  (zr-tramp-rcrc--check-destination file newname okay)
  (zr-tramp-rcrc--transfer file newname nil keep-time)
  nil)

(defun zr-tramp-rcrc--rename-file (file newname &optional okay)
  "Rename FILE to NEWNAME, honoring overwrite option OKAY."
  (setq file (expand-file-name file)
        newname (zr-tramp-rcrc--destination file newname))
  (let ((directory (file-directory-p file)))
    (zr-tramp-rcrc--check-destination file newname okay directory)
    (cond
     ((not directory) (zr-tramp-rcrc--transfer file newname t))
     ((zr-tramp-rcrc--same-rcd-p file newname)
      (unwind-protect
          (zr-tramp-rcrc--call
           (car (zr-tramp-rcrc--location file)) "sync/move"
           (list (cons 'srcFs (zr-tramp-rcrc-rclone-path (directory-file-name file)))
                 (cons 'dstFs (zr-tramp-rcrc-rclone-path (directory-file-name newname)))
                 '(createEmptySrcDirs . t) '(deleteEmptySrcDirs . t)))
        (zr-tramp-rcrc--flush file)
        (zr-tramp-rcrc--flush newname)))
     (t
      (copy-directory file newname t t t)
      (delete-directory file t))))
  nil)

(defun zr-tramp-rcrc--unsupported (&rest _args)
  "Report an operation that rclone rc cannot provide."
  (signal 'file-error '("Operation is not supported by rcrc")))

(defconst zr-tramp-rcrc-file-name-handler-alist
  '((access-file . tramp-handle-access-file)
    (add-name-to-file . zr-tramp-rcrc--unsupported)
    (copy-directory . tramp-handle-copy-directory)
    (copy-file . zr-tramp-rcrc--copy-file)
    (delete-directory . zr-tramp-rcrc--delete-directory)
    (delete-file . zr-tramp-rcrc--delete-file)
    (directory-file-name . tramp-handle-directory-file-name)
    (directory-files . zr-tramp-rcrc--directory-files)
    (directory-files-and-attributes . zr-tramp-rcrc--directory-files-and-attributes)
    (dired-compress-file . zr-tramp-rcrc--unsupported)
    (dired-uncache . tramp-handle-dired-uncache)
    (exec-path . ignore)
    (expand-file-name . tramp-handle-expand-file-name)
    (file-accessible-directory-p . tramp-handle-file-accessible-directory-p)
    (file-acl . ignore)
    (file-attributes . zr-tramp-rcrc--file-attributes)
    (file-directory-p . tramp-handle-file-directory-p)
    (file-equal-p . tramp-handle-file-equal-p)
    (file-executable-p . tramp-handle-file-directory-p)
    (file-exists-p . zr-tramp-rcrc--file-exists-p)
    (file-in-directory-p . tramp-handle-file-in-directory-p)
    (file-local-copy . tramp-handle-file-local-copy)
    (file-locked-p . ignore)
    (file-modes . tramp-handle-file-modes)
    (file-name-all-completions . zr-tramp-rcrc--all-completions)
    (file-name-as-directory . tramp-handle-file-name-as-directory)
    (file-name-case-insensitive-p . ignore)
    (file-name-completion . tramp-handle-file-name-completion)
    (file-name-directory . tramp-handle-file-name-directory)
    (file-name-nondirectory . tramp-handle-file-name-nondirectory)
    (file-newer-than-file-p . tramp-handle-file-newer-than-file-p)
    (file-notify-add-watch . tramp-handle-file-notify-add-watch)
    (file-notify-rm-watch . ignore)
    (file-notify-valid-p . ignore)
    (file-ownership-preserved-p . ignore)
    (file-readable-p . zr-tramp-rcrc--file-exists-p)
    (file-regular-p . tramp-handle-file-regular-p)
    (file-remote-p . tramp-handle-file-remote-p)
    (file-selinux-context . tramp-handle-file-selinux-context)
    (file-symlink-p . ignore)
    (file-system-info . ignore)
    (file-truename . tramp-handle-expand-file-name)
    (file-writable-p . zr-tramp-rcrc--file-writable-p)
    (find-backup-file-name . tramp-handle-find-backup-file-name)
    (insert-directory . tramp-handle-insert-directory)
    (insert-file-contents . tramp-handle-insert-file-contents)
    (list-system-processes . zr-tramp-rcrc--unsupported)
    (load . tramp-handle-load)
    (lock-file . ignore)
    (make-auto-save-file-name . tramp-handle-make-auto-save-file-name)
    (make-directory . zr-tramp-rcrc--make-directory)
    (make-directory-internal . zr-tramp-rcrc--make-directory)
    (make-lock-file-name . tramp-handle-make-lock-file-name)
    (make-nearby-temp-file . tramp-handle-make-nearby-temp-file)
    (make-process . zr-tramp-rcrc--unsupported)
    (make-symbolic-link . zr-tramp-rcrc--unsupported)
    (memory-info . zr-tramp-rcrc--unsupported)
    (process-attributes . zr-tramp-rcrc--unsupported)
    (process-file . zr-tramp-rcrc--unsupported)
    (rename-file . zr-tramp-rcrc--rename-file)
    (set-file-acl . ignore)
    (set-file-modes . ignore)
    (set-file-selinux-context . ignore)
    (set-file-times . ignore)
    (set-visited-file-modtime . tramp-handle-set-visited-file-modtime)
    (shell-command . zr-tramp-rcrc--unsupported)
    (start-file-process . zr-tramp-rcrc--unsupported)
    (substitute-in-file-name . tramp-handle-substitute-in-file-name)
    (temporary-file-directory . tramp-handle-temporary-file-directory)
    (tramp-get-home-directory . ignore)
    (tramp-get-remote-gid . zr-tramp-rcrc--remote-id)
    (tramp-get-remote-groups . ignore)
    (tramp-get-remote-uid . zr-tramp-rcrc--remote-id)
    (tramp-set-file-uid-gid . ignore)
    (unhandled-file-name-directory . ignore)
    (unlock-file . ignore)
    (vc-registered . ignore)
    (verify-visited-file-modtime . zr-tramp-rcrc--verify-visited-file-modtime)
    (write-region . tramp-handle-write-region))
  "File operations provided by the rclone rc backend.")

(defun zr-tramp-rcrc-file-name-handler (operation &rest args)
  "Dispatch TRAMP OPERATION with ARGS to the rclone rc implementation."
  (save-match-data
    ;; Background completion must not start synchronous requests or cache
    ;; their absence; see `zr-tramp-rcrc--http'.
    (catch 'zr-tramp-rcrc--non-essential
      (if-let* ((handler (alist-get operation zr-tramp-rcrc-file-name-handler-alist)))
          (apply handler args)
        (tramp-run-real-handler operation args)))))

;;;###autoload
(defun zr-tramp-rcrc-clear-cache ()
  "Forget cached rcrc file metadata."
  (interactive)
  (dolist (key (hash-table-keys tramp-cache-data))
    (when (and (tramp-file-name-p key) (zr-tramp-rcrc-file-name-p key))
      (remhash key tramp-cache-data))))

(add-to-list 'tramp-methods '("rcrc" (tramp-default-port 5572)))

(tramp-register-foreign-file-name-handler
 #'zr-tramp-rcrc-file-name-p #'zr-tramp-rcrc-file-name-handler)

(provide 'zr-tramp-rcrc)
;;; zr-tramp-rcrc.el ends here
