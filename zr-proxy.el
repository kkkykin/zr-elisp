;;; zr-proxy.el --- URL transformations, xget acceleration and proxy management -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, network, hypermedia

;;; Commentary:

;; Provides configurable URL transformation, xget developer resource acceleration,
;; an advice macro for wrapping URL-consuming functions, and an HTTP proxy mode
;; routing requests via `url-proxy-services' and environment variables.
;;
;; Key features:
;; - `zr-proxy-transform-alist': Regex- and predicate-driven URL rewriting rules
;;   inspired by `zr-mpv.el'.
;; - `zr-proxy-xget-transform': Built-in transformation function for the Xget
;;   developer resource acceleration engine (GitHub, npm, PyPI, Crates, AI APIs, etc.).
;; - `zr-proxy-advise-url': Macro to advise existing functions (e.g. `url-retrieve-internal',
;;   `eww', etc.) so their URL argument is transformed according to active rules.
;; - `zr-proxy-http-proxy-mode': Mode routing external requests via HTTP forward proxy
;;   (configured via `url-proxy-services', custom variables, or environment variables).
;;   When this mode is active, URL transformation rules are automatically bypassed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'url-vars)
(require 'url-proxy)

(defgroup zr-proxy nil
  "URL transformation and proxy management."
  :group 'comm
  :prefix "zr-proxy-")

;;; Configuration Variables

(defcustom zr-proxy-transform-alist nil
  "Alist of transformations applied to URLs.
Each element has the form (PATTERN . REPLACEMENT).

PATTERN matches against the URL string and can be:
  - a regexp string (tested with `string-match')
  - `t' (always matches)
  - a predicate function called with (URL) returning non-nil on match.

REPLACEMENT specifies how to produce the transformed URL and can be:
  - a replacement string (supports \\&, \\1, etc. as in `replace-match')
  - a function called with (URL [MATCH-DATA]) returning the transformed string.

Rules are applied sequentially in order.  When HTTP proxy mode is active
\(see `zr-proxy-http-proxy-active-p'), transformations are bypassed."
  :type '(repeat (cons (choice (regexp :tag "Regexp Pattern")
                               (const :tag "Always Match" t)
                               (function :tag "Predicate Function"))
                       (choice (string :tag "Replacement String")
                               (function :tag "Transform Function"))))
  :group 'zr-proxy)

(defcustom zr-proxy-xget-base-url "https://xget.xi-xu.me"
  "Base URL for the Xget acceleration service."
  :type 'string
  :group 'zr-proxy)

(defcustom zr-proxy-http-proxy nil
  "Default HTTP proxy server in \"host:port\" or \"http://host:port\" format.
When nil, `zr-proxy-http-proxy-enable' inspects `url-proxy-services' and
environment variables (http_proxy, HTTP_PROXY, all_proxy, ALL_PROXY)."
  :type '(choice (const :tag "From Environment or url-proxy-services" nil)
                 (string :tag "Proxy Host:Port"))
  :group 'zr-proxy)

(defcustom zr-proxy-https-proxy nil
  "Default HTTPS proxy server in \"host:port\" or \"http://host:port\" format.
When nil, falls back to `zr-proxy-http-proxy' or environment variables
\(https_proxy, HTTPS_PROXY, all_proxy, ALL_PROXY)."
  :type '(choice (const :tag "Same as HTTP Proxy" nil)
                 (string :tag "Proxy Host:Port"))
  :group 'zr-proxy)

(defcustom zr-proxy-no-proxy nil
  "Hosts or domain regex that bypass the proxy.
When nil, falls back to `url-proxy-services' or env (no_proxy, NO_PROXY)."
  :type '(choice (const :tag "From Environment or url-proxy-services" nil)
                 (string :tag "No-proxy Pattern"))
  :group 'zr-proxy)

(defvar zr-proxy-http-proxy-mode nil
  "Non-nil when `zr-proxy-http-proxy-mode' is active.")

(defvar zr-proxy--saved-proxy-services 'unset
  "Saved `url-proxy-services' prior to enabling HTTP proxy mode.")

(defvar zr-proxy--saved-proxy-locator 'unset
  "Saved `url-proxy-locator' prior to enabling HTTP proxy mode.")

(defvar zr-proxy--saved-env-vars 'unset
  "Saved environment variables prior to enabling HTTP proxy mode.")

;;; Xget Platform Catalog

(defconst zr-proxy-xget-platforms
  '(;; Code Repositories & Version Control
    ("https://github.com/Homebrew"           . "homebrew")
    ("https://gist.github.com"               . "gist")
    ("https://github.com"                    . "gh")
    ("https://gitlab.com"                    . "gl")
    ("https://gitea.com"                     . "gitea")
    ("https://codeberg.org"                  . "codeberg")
    ("https://sourceforge.net"               . "sf")
    ("https://android.googlesource.com"      . "aosp")
    ("https://huggingface.co"                . "hf")
    ("https://civitai.com"                   . "civitai")

    ;; Package Registries
    ("https://registry.npmjs.org"            . "npm")
    ("https://pypi.org"                      . "pypi")
    ("https://files.pythonhosted.org"        . "pypi/files")
    ("https://repo.anaconda.com"             . "conda")
    ("https://conda.anaconda.org"            . "conda/community")
    ("https://repo1.maven.org"               . "maven")
    ("https://downloads.apache.org"          . "apache")
    ("https://plugins.gradle.org"            . "gradle")
    ("https://formulae.brew.sh/api"          . "homebrew/api")
    ("https://rubygems.org"                  . "rubygems")
    ("https://cran.r-project.org"            . "cran")
    ("https://www.cpan.org"                  . "cpan")
    ("https://tug.ctan.org"                  . "ctan")
    ("https://proxy.golang.org"              . "golang")
    ("https://api.nuget.org"                 . "nuget")
    ("https://crates.io"                     . "crates")
    ("https://repo.packagist.org"            . "packagist")
    ("https://dl.flathub.org"                . "flathub")

    ;; Linux Distributions
    ("https://deb.debian.org"                . "debian")
    ("https://archive.ubuntu.com"            . "ubuntu")
    ("https://mirrors.kernel.org/fedora"     . "fedora")
    ("https://dl.fedoraproject.org"          . "fedora")
    ("https://download.rockylinux.org"       . "rocky")
    ("https://download.opensuse.org"         . "opensuse")
    ("https://geo.mirror.pkgbuild.com"       . "arch")

    ;; Other Resources
    ("https://arxiv.org"                     . "arxiv")
    ("https://f-droid.org"                   . "fdroid")
    ("https://updates.jenkins.io"            . "jenkins")

    ;; AI Inference Providers (ip-*)
    ("https://api.openai.com"                . "ip/openai")
    ("https://api.anthropic.com"             . "ip/anthropic")
    ("https://generativelanguage.googleapis.com" . "ip/gemini")
    ("https://aiplatform.googleapis.com"     . "ip/vertexai")
    ("https://api.cohere.ai"                 . "ip/cohere")
    ("https://api.mistral.ai"                . "ip/mistralai")
    ("https://api.x.ai"                      . "ip/xai")
    ("https://models.github.ai"              . "ip/githubmodels")
    ("https://integrate.api.nvidia.com"      . "ip/nvidiaapi")
    ("https://api.perplexity.ai"             . "ip/perplexity")
    ("https://api.braintrust.dev"            . "ip/braintrust")
    ("https://api.groq.com"                  . "ip/groq")
    ("https://api.cerebras.ai"               . "ip/cerebras")
    ("https://api.sambanova.ai"              . "ip/sambanova")
    ("https://api.siray.ai"                  . "ip/siray")
    ("https://router.huggingface.co"         . "ip/huggingface")
    ("https://api.together.xyz"              . "ip/together")
    ("https://api.replicate.com"             . "ip/replicate")
    ("https://api.fireworks.ai"              . "ip/fireworks")
    ("https://api.studio.nebius.ai"          . "ip/nebius")
    ("https://api.jina.ai"                   . "ip/jina")
    ("https://api.voyageai.com"              . "ip/voyageai")
    ("https://fal.run"                       . "ip/falai")
    ("https://api.novita.ai"                 . "ip/novita")
    ("https://ai.burncloud.com"              . "ip/burncloud")
    ("https://openrouter.ai"                 . "ip/openrouter")
    ("https://api.poe.com"                   . "ip/poe")
    ("https://api.featherless.ai"            . "ip/featherlessai")
    ("https://api.hyperbolic.xyz"            . "ip/hyperbolic")

    ;; Container Registries (cr-*)
    ("https://registry-1.docker.io"          . "cr/docker")
    ("https://quay.io"                       . "cr/quay")
    ("https://gcr.io"                        . "cr/gcr")
    ("https://mcr.microsoft.com"             . "cr/mcr")
    ("https://public.ecr.aws"                . "cr/ecr")
    ("https://ghcr.io"                       . "cr/ghcr")
    ("https://registry.gitlab.com"           . "cr/gitlab")
    ("https://registry.redhat.io"            . "cr/redhat")
    ("https://container-registry.oracle.com" . "cr/oracle")
    ("https://docker.cloudsmith.io"          . "cr/cloudsmith")
    ("https://registry.digitalocean.com"     . "cr/digitalocean")
    ("https://projects.registry.vmware.com"  . "cr/vmware")
    ("https://registry.k8s.io"               . "cr/k8s")
    ("https://registry.heroku.com"           . "cr/heroku")
    ("https://registry.suse.com"             . "cr/suse")
    ("https://registry.opensuse.org"         . "cr/opensuse")
    ("https://registry.gitpod.io"            . "cr/gitpod"))
  "Mapping of upstream base URLs to Xget platform path prefixes.
Ordered so that more specific prefixes precede general ones.")

;;; Xget Transform Handler

(defun zr-proxy-xget-transform (url &optional _match-data)
  "Transform URL into an Xget-accelerated URL if supported.
Uses `zr-proxy-xget-base-url' and `zr-proxy-xget-platforms'.
If URL is not supported or is already accelerated, returns URL unchanged."
  (if (not (stringp url))
      url
    (let ((base (string-remove-suffix "/" zr-proxy-xget-base-url)))
      (cond
       ;; Already proxied by xget
       ((string-prefix-p base url)
        url)

       ;; raw.githubusercontent.com -> /gh/:user/:repo/raw/:branch/:path
       ((string-match "\\`https?://raw\\.githubusercontent\\.com/\\([^/]+\\)/\\([^/]+\\)/\\(.*\\)\\'" url)
        (format "%s/gh/%s/%s/raw/%s"
                base
                (match-string 1 url)
                (match-string 2 url)
                (match-string 3 url)))

       ;; Match against known platforms
       (t
        (or (cl-loop for (upstream . prefix) in zr-proxy-xget-platforms
                     for upstream-no-scheme = (replace-regexp-in-string "\\`https?://" "" upstream)
                     for re = (concat "\\`https?://"
                                      (regexp-quote upstream-no-scheme)
                                      "\\(?:/\\(.*\\)\\|\\'\\)")
                     when (string-match re url)
                     return
                     (let ((pfx (string-remove-suffix "/" (string-remove-prefix "/" prefix)))
                           (rem (or (match-string 1 url) "")))
                       (if (string-empty-p rem)
                           (format "%s/%s" base pfx)
                         (format "%s/%s/%s" base pfx rem))))
            url))))))

;;; URL Transformation Engine

(defun zr-proxy-transform-url (url)
  "Transform URL according to `zr-proxy-transform-alist'.
If HTTP proxy mode is active (see `zr-proxy-http-proxy-active-p'),
returns URL unchanged.  Otherwise, rules are applied sequentially in order.

For each rule (PATTERN . REPLACEMENT):
  - PATTERN can be a regexp string, `t', or a predicate function.
  - REPLACEMENT can be a string (passed to `replace-match') or a function
    called with (URL [MATCH-DATA])."
  (if (or (not (stringp url))
          (zr-proxy-http-proxy-active-p))
      url
    (let ((result url))
      (dolist (transform zr-proxy-transform-alist result)
        (let ((pattern (car transform))
              (repl (cdr transform)))
          (when (cond
                 ((eq pattern t) t)
                 ((stringp pattern) (string-match pattern result))
                 ((functionp pattern) (funcall pattern result))
                 (t nil))
            (setq result
                  (cond
                   ((stringp repl)
                    (replace-match repl nil nil result))
                   ((functionp repl)
                    (condition-case nil
                        (funcall repl result (match-data))
                      (wrong-number-of-arguments
                       (funcall repl result))))
                   (t result)))))))))

;;; Advice Macro for URL-Consuming Functions

(defun zr-proxy--filter-args-with-url (args arg-spec)
  "Apply `zr-proxy-transform-url' to the URL argument in ARGS.
ARG-SPEC is either an integer position (0-indexed, default 0) or a
keyword (e.g. :url)."
  (cond
   ((null args) nil)
   ((keywordp arg-spec)
    (let ((copy (copy-sequence args)))
      (when-let* ((val (plist-get copy arg-spec))
                  ((stringp val)))
        (setq copy (plist-put copy arg-spec (zr-proxy-transform-url val))))
      copy))
   (t
    (let ((idx (or arg-spec 0))
          (copy (copy-sequence args)))
      (when (and (integerp idx) (< idx (length copy)))
        (let ((val (nth idx copy)))
          (when (stringp val)
            (setf (nth idx copy) (zr-proxy-transform-url val)))))
      copy))))

(defun zr-proxy--normalize-advice-spec (target arg-spec)
  "Normalize TARGET and ARG-SPEC into a list of (FN . SPEC) pairs."
  (cond
   ((and (listp target) (eq (car target) 'quote))
    (zr-proxy--normalize-advice-spec (cadr target) arg-spec))
   ((symbolp target)
    (list (cons target (or arg-spec 0))))
   ((listp target)
    (mapcar (lambda (item)
              (cond
               ((and (listp item) (eq (car item) 'quote))
                (cons (cadr item) (or arg-spec 0)))
               ((consp item)
                (cons (car item) (or (cadr item) (cdr item) 0)))
               ((symbolp item)
                (cons item (or arg-spec 0)))
               (t (error "Invalid advice target: %S" item))))
            target))
   (t (error "Invalid advice target: %S" target))))

;;;###autoload
(defmacro zr-proxy-advise-url (target &optional arg-spec)
  "Advise TARGET function(s) so their URL argument is transformed.
TARGET can be a function symbol, a quoted function symbol, or a list of
functions or (FUNCTION [ARG-SPEC]) specs.

ARG-SPEC specifies which argument is the URL.  It can be:
  - an integer (0-indexed position, defaults to 0)
  - a keyword (e.g. :url, for keyword/plist arguments)

Advice uses `advice-add' with `:filter-args' calling `zr-proxy-transform-url'."
  (let* ((specs (zr-proxy--normalize-advice-spec target arg-spec))
         (forms
          (mapcar
           (lambda (pair)
             (let* ((fn (car pair))
                    (spec (cdr pair))
                    (advice-fn (intern (format "zr-proxy--advice-%s" fn))))
               `(progn
                  (defalias ',advice-fn
                    (lambda (args)
                      (zr-proxy--filter-args-with-url args ,spec)))
                  (advice-add ',fn :filter-args #',advice-fn))))
           specs)))
    (if (= (length forms) 1)
        (car forms)
      `(progn ,@forms))))

(defun zr-proxy-unadvise-url (target)
  "Remove URL transformation advice from TARGET function(s)."
  (let ((specs (zr-proxy--normalize-advice-spec target nil)))
    (dolist (pair specs)
      (let* ((fn (car pair))
             (advice-fn (intern (format "zr-proxy--advice-%s" fn))))
        (advice-remove fn advice-fn)))))

;;; HTTP Proxy Mode

(defun zr-proxy-parse-proxy (proxy)
  "Parse PROXY string into \"host:port\" format expected by `url-proxy-services'.
Strips leading protocol (e.g., http://, https://) and trailing slashes."
  (when (and (stringp proxy) (not (string-blank-p proxy)))
    (let ((trimmed (string-trim proxy)))
      (if (string-match "\\`[a-zA-Z0-9]+://\\(.*?\\)/*\\'" trimmed)
          (match-string 1 trimmed)
        (replace-regexp-in-string "/*\\'" "" trimmed)))))

(defun zr-proxy-http-proxy-active-p ()
  "Return non-nil if HTTP proxy mode is active.
In this mode, requests are routed through `url-proxy-services' and
URL transform rules do not take effect."
  (bound-and-true-p zr-proxy-http-proxy-mode))

(defun zr-proxy-http-proxy-enable (&optional proxy)
  "Enable HTTP proxy mode, routing requests through PROXY or environment settings.
When PROXY is provided, it overrides custom variables and environment.
Otherwise, resolves proxy configuration from:
  1. `zr-proxy-http-proxy' (and `zr-proxy-https-proxy')
  2. existing `url-proxy-services'
  3. environment variables (http_proxy, https_proxy, all_proxy and uppercase)

When active, `zr-proxy-transform-url' returns URLs unchanged."
  (interactive)
  (let* ((http (or (zr-proxy-parse-proxy proxy)
                   (zr-proxy-parse-proxy zr-proxy-http-proxy)
                   (alist-get "http" url-proxy-services nil nil #'equal)
                   (zr-proxy-parse-proxy (or (getenv "http_proxy")
                                             (getenv "HTTP_PROXY")
                                             (getenv "all_proxy")
                                             (getenv "ALL_PROXY")))))
         (https (or (zr-proxy-parse-proxy proxy)
                    (zr-proxy-parse-proxy (or zr-proxy-https-proxy zr-proxy-http-proxy))
                    (alist-get "https" url-proxy-services nil nil #'equal)
                    (zr-proxy-parse-proxy (or (getenv "https_proxy")
                                              (getenv "HTTPS_PROXY")
                                              (getenv "all_proxy")
                                              (getenv "ALL_PROXY")))))
         (no-proxy (or (zr-proxy-parse-proxy zr-proxy-no-proxy)
                       (alist-get "no_proxy" url-proxy-services nil nil #'equal)
                       (getenv "no_proxy")
                       (getenv "NO_PROXY"))))
    (unless (or http https)
      (user-error "No HTTP proxy specified or detected in environment"))
    ;; Save current proxy configuration and environment before modifying
    (unless (bound-and-true-p zr-proxy-http-proxy-mode)
      (setq zr-proxy--saved-proxy-services (copy-alist url-proxy-services)
            zr-proxy--saved-proxy-locator url-proxy-locator
            zr-proxy--saved-env-vars
            (mapcar (lambda (v) (cons v (getenv v)))
                    '("http_proxy" "https_proxy" "all_proxy" "no_proxy"
                      "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" "NO_PROXY"))))
    (when http
      (setf (alist-get "http" url-proxy-services nil nil #'equal) http)
      (let ((url (if (string-match-p "\\`[a-zA-Z0-9]+://" http)
                     http
                   (concat "http://" http))))
        (setenv "http_proxy" url)
        (setenv "HTTP_PROXY" url)))
    (when https
      (setf (alist-get "https" url-proxy-services nil nil #'equal) https)
      (let ((url (if (string-match-p "\\`[a-zA-Z0-9]+://" https)
                     https
                   (concat "http://" https))))
        (setenv "https_proxy" url)
        (setenv "HTTPS_PROXY" url)))
    (when (and http (equal http https))
      (let ((url (if (string-match-p "\\`[a-zA-Z0-9]+://" http)
                     http
                   (concat "http://" http))))
        (setenv "all_proxy" url)
        (setenv "ALL_PROXY" url)))
    (when no-proxy
      (setf (alist-get "no_proxy" url-proxy-services nil nil #'equal) no-proxy)
      (setenv "no_proxy" no-proxy)
      (setenv "NO_PROXY" no-proxy))
    (setq url-proxy-locator #'url-default-find-proxy-for-url
          zr-proxy-http-proxy-mode t)
    (message "zr-proxy: HTTP proxy enabled (HTTP: %s, HTTPS: %s); transform rules bypassed"
             (or http "none") (or https "none"))))

(defun zr-proxy-http-proxy-disable ()
  "Disable HTTP proxy mode and restore previous proxy settings and environment.
Transform rules will resume taking effect."
  (interactive)
  (unless (eq zr-proxy--saved-proxy-services 'unset)
    (setq url-proxy-services zr-proxy--saved-proxy-services
          zr-proxy--saved-proxy-services 'unset))
  (unless (eq zr-proxy--saved-proxy-locator 'unset)
    (setq url-proxy-locator zr-proxy--saved-proxy-locator
          zr-proxy--saved-proxy-locator 'unset))
  (unless (eq zr-proxy--saved-env-vars 'unset)
    (dolist (pair zr-proxy--saved-env-vars)
      (setenv (car pair) (cdr pair)))
    (setq zr-proxy--saved-env-vars 'unset))
  (setq zr-proxy-http-proxy-mode nil)
  (message "zr-proxy: HTTP proxy mode disabled; transform rules active"))

;;;###autoload
(define-minor-mode zr-proxy-http-proxy-mode
  "Global minor mode routing external requests through an HTTP proxy.
When enabled, requests are routed through `url-proxy-services' (configured
via `zr-proxy-http-proxy', `url-proxy-services', or environment variables
http_proxy/https_proxy/all_proxy).
While this mode is active, URL transform rules do not take effect."
  :global t
  :group 'zr-proxy
  (if zr-proxy-http-proxy-mode
      (zr-proxy-http-proxy-enable)
    (zr-proxy-http-proxy-disable)))

(provide 'zr-proxy)
;;; zr-proxy.el ends here
