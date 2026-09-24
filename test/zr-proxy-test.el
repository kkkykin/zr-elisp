;;; zr-proxy-test.el --- Tests for zr-proxy -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for `zr-proxy' covering:
;; - URL transformation engine (`zr-proxy-transform-alist', regex, predicate, function).
;; - Built-in Xget transform handler (`zr-proxy-xget-transform', GitHub, npm, AI, etc.).
;; - Advice macro for URL-consuming functions (`zr-proxy-advise-url').
;; - HTTP proxy mode (`zr-proxy-http-proxy-mode', env resolution, transform bypass).

;;; Code:

(require 'ert)
(require 'cl-lib)

(load (expand-file-name
       "../zr-proxy.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

;;; URL Transformation Tests

(ert-deftest zr-proxy-test-transform-string-and-regex ()
  "Test regexp matching and string replacement with backreferences."
  (let ((zr-proxy-transform-alist
         `((,(rx bos "http://" (group (*? nonl)) eos) . "https://\\1")
           (,(rx "github.com/" (group (+ (not "/"))) "/" (group (+ (not "/"))) "/blob/" (group (*? nonl)) eos)
            . "github.com/\\1/\\2/raw/\\3"))))
    ;; Basic replacement with backreference
    (should (equal "https://example.com/api"
                   (zr-proxy-transform-url "http://example.com/api")))
    ;; Blob to raw rewrite
    (should (equal "https://github.com/user/repo/raw/main/README.md"
                   (zr-proxy-transform-url "https://github.com/user/repo/blob/main/README.md")))
    ;; Unmatched URL unchanged
    (should (equal "https://other.com/file"
                   (zr-proxy-transform-url "https://other.com/file")))))

(ert-deftest zr-proxy-test-transform-function-and-match-data ()
  "Test function replacements receiving match-data or url."
  (let ((zr-proxy-transform-alist
         `((,(rx bos "https://nas.lan/" (group (* nonl)))
            . ,(lambda (url md)
                 (format "http://192.168.1.100:8080/%s" (match-string 1 url))))
           (,(rx "localhost")
            . ,(lambda (url)
                 (replace-regexp-in-string "localhost" "127.0.0.1" url))))))
    (should (equal "http://192.168.1.100:8080/share/music.flac"
                   (zr-proxy-transform-url "https://nas.lan/share/music.flac")))
    (should (equal "http://127.0.0.1:3000/app"
                   (zr-proxy-transform-url "http://localhost:3000/app")))))

(ert-deftest zr-proxy-test-transform-predicate-and-always-match ()
  "Test predicate functions and `t' in pattern position."
  (let ((zr-proxy-transform-alist
         `((,(lambda (url) (string-suffix-p ".patch" url))
            . ,(lambda (url) (concat url "?format=diff")))
           (t . ,(lambda (url) (concat url "#v=1"))))))
    (should (equal "https://git.example.com/123.patch?format=diff#v=1"
                   (zr-proxy-transform-url "https://git.example.com/123.patch")))
    (should (equal "https://git.example.com/123#v=1"
                   (zr-proxy-transform-url "https://git.example.com/123")))))

(ert-deftest zr-proxy-test-non-regexp-string-replacement ()
  "Non-regexp rules replace the whole URL without stale match data."
  (save-match-data
    (set-match-data '(2 4))
    (let ((zr-proxy-transform-alist
           '((t . "https://cache/\\&"))))
      (should (equal "https://cache/HTTP://EXAMPLE.COM"
                     (zr-proxy-transform-url "HTTP://EXAMPLE.COM")))
      (should (equal '(2 4) (match-data))))
    (let ((zr-proxy-transform-alist
           `((,(lambda (_url) (string-match "a" "abc"))
              . "https://cache/\\&"))))
      (should (equal "https://cache/https://example.com"
                     (zr-proxy-transform-url "https://example.com"))))))

(ert-deftest zr-proxy-test-transform-cascading-order ()
  "Test that transformation rules cascade sequentially."
  (let ((zr-proxy-transform-alist
         '(("foo" . "bar")
           ("bar" . "baz")
           ("baz" . "qux"))))
    (should (equal "https://qux.com/item"
                   (zr-proxy-transform-url "https://foo.com/item")))))

(ert-deftest zr-proxy-test-transform-edge-cases ()
  "Test non-string, empty, or nil inputs."
  (let ((zr-proxy-transform-alist '((".*" . "http://hijacked.com"))))
    (should (null (zr-proxy-transform-url nil)))
    (should (equal 12345 (zr-proxy-transform-url 12345))))
  (let ((zr-proxy-transform-alist nil))
    (should (equal "https://example.com"
                   (zr-proxy-transform-url "https://example.com")))))

;;; Xget Transform Handler Tests

(ert-deftest zr-proxy-test-xget-github-and-gist ()
  "Test Xget transformations for GitHub and Gist URLs."
  (let ((zr-proxy-xget-base-url "https://xget.xi-xu.me"))
    ;; GitHub repository archive
    (should (equal "https://xget.xi-xu.me/gh/microsoft/vscode/archive/refs/heads/main.zip"
                   (zr-proxy-xget-transform "https://github.com/microsoft/vscode/archive/refs/heads/main.zip")))
    ;; GitHub Gist
    (should (equal "https://xget.xi-xu.me/gist/user/e2ea9db/raw/doc.md"
                   (zr-proxy-xget-transform "https://gist.github.com/user/e2ea9db/raw/doc.md")))
    ;; Homebrew before GitHub general prefix
    (should (equal "https://xget.xi-xu.me/homebrew/brew/releases"
                   (zr-proxy-xget-transform "https://github.com/Homebrew/brew/releases")))))

(ert-deftest zr-proxy-test-xget-raw-githubusercontent ()
  "Test Xget transformation of raw.githubusercontent.com URLs."
  (let ((zr-proxy-xget-base-url "https://xget.xi-xu.me"))
    (should (equal "https://xget.xi-xu.me/gh/torvalds/linux/raw/master/README"
                   (zr-proxy-xget-transform "https://raw.githubusercontent.com/torvalds/linux/master/README")))))

(ert-deftest zr-proxy-test-xget-package-registries ()
  "Test Xget transformations for package managers and AI providers."
  (let ((zr-proxy-xget-base-url "https://xget.xi-xu.me"))
    ;; npm
    (should (equal "https://xget.xi-xu.me/npm/react/-/react-18.2.0.tgz"
                   (zr-proxy-xget-transform "https://registry.npmjs.org/react/-/react-18.2.0.tgz")))
    ;; PyPI
    (should (equal "https://xget.xi-xu.me/pypi/packages/source/r/requests/requests-2.31.0.tar.gz"
                   (zr-proxy-xget-transform "https://pypi.org/packages/source/r/requests/requests-2.31.0.tar.gz")))
    ;; PyPI files
    (should (equal "https://xget.xi-xu.me/pypi/files/packages/py3/pkg.whl"
                   (zr-proxy-xget-transform "https://files.pythonhosted.org/packages/py3/pkg.whl")))
    ;; Crates.io
    (should (equal "https://xget.xi-xu.me/crates/api/v1/crates/serde/1.0.0/download"
                   (zr-proxy-xget-transform "https://crates.io/api/v1/crates/serde/1.0.0/download")))
    ;; AI Inference provider (OpenAI)
    (should (equal "https://xget.xi-xu.me/ip/openai/v1/chat/completions"
                   (zr-proxy-xget-transform "https://api.openai.com/v1/chat/completions")))
    ;; Container registry
    (should (equal "https://xget.xi-xu.me/cr/docker/v2/library/ubuntu/manifests/latest"
                   (zr-proxy-xget-transform "https://registry-1.docker.io/v2/library/ubuntu/manifests/latest")))))

(ert-deftest zr-proxy-test-xget-custom-base-url-and-idempotency ()
  "Test custom base URL with trailing slashes and idempotency on already accelerated URLs."
  (let ((zr-proxy-xget-base-url "https://my-xget.example.com/"))
    (should (equal "https://my-xget.example.com/gh/user/repo"
                   (zr-proxy-xget-transform "https://github.com/user/repo")))
    ;; Already accelerated URL should not be doubled
    (should (equal "https://my-xget.example.com/gh/user/repo"
                   (zr-proxy-xget-transform "https://my-xget.example.com/gh/user/repo"))))
  ;; Unsupported hosts return unchanged
  (should (equal "https://example.com/unknown/path"
                 (zr-proxy-xget-transform "https://example.com/unknown/path"))))

(ert-deftest zr-proxy-test-xget-integrated-with-transform-alist ()
  "Test using `zr-proxy-xget-transform' inside `zr-proxy-transform-alist'."
  (let ((zr-proxy-xget-base-url "https://xget.xi-xu.me")
        (zr-proxy-transform-alist '((t . zr-proxy-xget-transform))))
    (should (equal "https://xget.xi-xu.me/gh/user/repo"
                   (zr-proxy-transform-url "https://github.com/user/repo")))
    (should (equal "https://other.com/foo"
                   (zr-proxy-transform-url "https://other.com/foo")))))

;;; Advice Macro Tests

(defun zr-proxy-test--fetch-one (url &optional headers)
  "Helper function for advice tests."
  (list :url url :headers headers))

(defun zr-proxy-test--fetch-second (id url &optional tag)
  "Helper function where URL is the second argument."
  (list :id id :url url :tag tag))

(defun zr-proxy-test--fetch-plist (&rest plist)
  "Helper function taking keyword arguments."
  plist)

(ert-deftest zr-proxy-test-advice-macro-positional-and-keyword ()
  "Test `zr-proxy-advise-url' for positional and keyword arguments."
  (let ((zr-proxy-xget-base-url "https://xget.xi-xu.me")
        (zr-proxy-transform-alist '((t . zr-proxy-xget-transform))))
    (unwind-protect
        (progn
          ;; Advise default arg 0
          (zr-proxy-advise-url zr-proxy-test--fetch-one)
          (let ((res (zr-proxy-test--fetch-one "https://github.com/user/repo" '(("Auth" . "x")))))
            (should (equal "https://xget.xi-xu.me/gh/user/repo" (plist-get res :url)))
            (should (equal '(("Auth" . "x")) (plist-get res :headers))))

          ;; Advise explicit arg 1
          (zr-proxy-advise-url zr-proxy-test--fetch-second 1)
          (let ((res (zr-proxy-test--fetch-second 42 "https://registry.npmjs.org/express" "test")))
            (should (equal 42 (plist-get res :id)))
            (should (equal "https://xget.xi-xu.me/npm/express" (plist-get res :url)))
            (should (equal "test" (plist-get res :tag))))

          ;; Advise keyword :url
          (zr-proxy-advise-url zr-proxy-test--fetch-plist :url)
          (let ((res (zr-proxy-test--fetch-plist :id 1 :url "https://api.openai.com/v1" :flag t)))
            (should (equal "https://xget.xi-xu.me/ip/openai/v1" (plist-get res :url)))
            (should (equal 1 (plist-get res :id)))
            (should (equal t (plist-get res :flag)))))

      ;; Cleanup advice
      (zr-proxy-unadvise-url 'zr-proxy-test--fetch-one)
      (zr-proxy-unadvise-url 'zr-proxy-test--fetch-second)
      (zr-proxy-unadvise-url 'zr-proxy-test--fetch-plist)))

  ;; Ensure advice was removed cleanly
  (let ((res (zr-proxy-test--fetch-one "https://github.com/user/repo")))
    (should (equal "https://github.com/user/repo" (plist-get res :url)))))

(ert-deftest zr-proxy-test-advice-macro-batch-list ()
  "Test advising multiple functions in a single macro call."
  (let ((zr-proxy-transform-alist '(("http://" . "https://"))))
    (unwind-protect
        (progn
          (zr-proxy-advise-url (zr-proxy-test--fetch-one
                                (zr-proxy-test--fetch-second 1)))
          (should (equal "https://example.com"
                         (plist-get (zr-proxy-test--fetch-one "http://example.com") :url)))
          (should (equal "https://example.com"
                         (plist-get (zr-proxy-test--fetch-second 99 "http://example.com") :url))))
      (zr-proxy-unadvise-url '(zr-proxy-test--fetch-one zr-proxy-test--fetch-second)))))

;;; HTTP Proxy Mode Tests

(ert-deftest zr-proxy-test-parse-proxy-helper ()
  "Test parsing proxy strings into host:port."
  (should (equal "127.0.0.1:7890" (zr-proxy-parse-proxy "127.0.0.1:7890")))
  (should (equal "127.0.0.1:7890" (zr-proxy-parse-proxy "http://127.0.0.1:7890/")))
  (should (equal "proxy.lan:8443" (zr-proxy-parse-proxy "https://proxy.lan:8443")))
  (should (equal "user:pass@proxy.corp:8080" (zr-proxy-parse-proxy "http://user:pass@proxy.corp:8080/")))
  (should (null (zr-proxy-parse-proxy nil)))
  (should (null (zr-proxy-parse-proxy "   "))))

(ert-deftest zr-proxy-test-http-proxy-mode-and-transform-bypass ()
  "Test that HTTP proxy mode configures url-proxy-services and bypasses transform rules."
  (let ((process-environment (copy-sequence process-environment))
        (url-proxy-services nil)
        (url-proxy-locator #'url-default-find-proxy-for-url)
        (zr-proxy-http-proxy "127.0.0.1:7890")
        (zr-proxy-transform-alist '(("https://github.com" . "https://xget.xi-xu.me/gh")))
        (zr-proxy-http-proxy-mode nil))
    ;; Ensure clean initial environment
    (dolist (v '("http_proxy" "https_proxy" "all_proxy" "no_proxy"
                 "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" "NO_PROXY"))
      (setenv v nil))

    ;; Before enabling: transform rule is active
    (should (equal "https://xget.xi-xu.me/gh/user/repo"
                   (zr-proxy-transform-url "https://github.com/user/repo")))
    (should-not (zr-proxy-http-proxy-active-p))

    ;; Enable HTTP proxy mode
    (zr-proxy-http-proxy-enable)
    (should (zr-proxy-http-proxy-active-p))
    (should (equal "127.0.0.1:7890" (alist-get "http" url-proxy-services nil nil #'equal)))
    (should (equal "127.0.0.1:7890" (alist-get "https" url-proxy-services nil nil #'equal)))
    ;; Environment variables set for external processes
    (should (equal "http://127.0.0.1:7890" (getenv "http_proxy")))
    (should (equal "http://127.0.0.1:7890" (getenv "https_proxy")))
    (should (equal "http://127.0.0.1:7890" (getenv "all_proxy")))

    ;; CRUCIAL: In HTTP proxy mode, transform rules must NOT take effect!
    (should (equal "https://github.com/user/repo"
                   (zr-proxy-transform-url "https://github.com/user/repo")))

    ;; Disable HTTP proxy mode
    (zr-proxy-http-proxy-disable)
    (should-not (zr-proxy-http-proxy-active-p))
    (should (null url-proxy-services))
    ;; Environment variables restored
    (should (null (getenv "http_proxy")))
    (should (null (getenv "https_proxy")))
    (should (null (getenv "all_proxy")))

    ;; Transform rules active again
    (should (equal "https://xget.xi-xu.me/gh/user/repo"
                   (zr-proxy-transform-url "https://github.com/user/repo")))))

(ert-deftest zr-proxy-test-http-proxy-environment-detection ()
  "Test resolution of proxy settings from environment variables."
  (let ((process-environment (copy-sequence process-environment))
        (url-proxy-services nil)
        (zr-proxy-http-proxy nil)
        (zr-proxy-https-proxy nil)
        (zr-proxy-no-proxy nil)
        (zr-proxy-http-proxy-mode nil))
    (setenv "all_proxy" "socks5://127.0.0.1:1080")
    (setenv "http_proxy" "http://10.0.0.1:3128")
    (setenv "https_proxy" "http://10.0.0.1:3129")
    (setenv "no_proxy" "localhost,127.0.0.1")
    (zr-proxy-http-proxy-enable)
    (unwind-protect
        (progn
          (should (equal "10.0.0.1:3128" (alist-get "http" url-proxy-services nil nil #'equal)))
          (should (equal "10.0.0.1:3129" (alist-get "https" url-proxy-services nil nil #'equal)))
          (dolist (host '("localhost" "127.0.0.1"))
            (should (equal "DIRECT"
                           (url-default-find-proxy-for-url
                            (url-generic-parse-url (concat "http://" host)) host))))
          (should (equal "localhost,127.0.0.1" (getenv "no_proxy"))))
      (zr-proxy-http-proxy-disable))))

(ert-deftest zr-proxy-test-http-proxy-mode-toggle ()
  "Test `zr-proxy-http-proxy-mode' toggling and transform bypass."
  (let ((process-environment (copy-sequence process-environment))
        (url-proxy-services nil)
        (zr-proxy-http-proxy "127.0.0.1:8080")
        (zr-proxy-transform-alist '((".*" . "http://transformed.org")))
        (zr-proxy-http-proxy-mode nil))
    (unwind-protect
        (progn
          ;; Mode disabled: transform rules apply
          (should-not (zr-proxy-http-proxy-active-p))
          (should (equal "http://transformed.org"
                         (zr-proxy-transform-url "http://original.org")))
          ;; Enable mode: transform rules bypassed
          (zr-proxy-http-proxy-mode 1)
          (should (zr-proxy-http-proxy-active-p))
          (should (equal "http://original.org"
                         (zr-proxy-transform-url "http://original.org")))
          ;; Disable mode: transform rules active again
          (zr-proxy-http-proxy-mode -1)
          (should-not (zr-proxy-http-proxy-active-p))
          (should (equal "http://transformed.org"
                         (zr-proxy-transform-url "http://original.org"))))
      (when zr-proxy-http-proxy-mode
        (zr-proxy-http-proxy-mode -1)))))

(defmacro zr-proxy-test--with-proxy-state (&rest body)
  "Run BODY without changing global proxy configuration or environment."
  (declare (indent 0) (debug t))
  `(let ((process-environment nil)
         (url-proxy-services nil)
         (url-proxy-locator #'ignore)
         (zr-proxy-http-proxy nil)
         (zr-proxy-https-proxy nil)
         (zr-proxy-no-proxy nil)
         (zr-proxy-http-proxy-mode nil)
         (zr-proxy--saved-proxy-services 'unset)
         (zr-proxy--saved-proxy-locator 'unset)
         (zr-proxy--saved-env-vars 'unset))
     ,@body))

(ert-deftest zr-proxy-test-mode-restores-original-state ()
  "Mode entry, repeated enables and disable preserve the initial state."
  (zr-proxy-test--with-proxy-state
    (setq url-proxy-services '(("http" . "old:80") ("no_proxy" . "\\`old\\'"))
          process-environment '("http_proxy=http://old:80" "NO_PROXY=old")
          zr-proxy-http-proxy "new:8080")
    (let ((services (copy-tree url-proxy-services))
          (env (copy-sequence process-environment)))
      (zr-proxy-http-proxy-mode 1)
      (zr-proxy-http-proxy-mode 1)
      (zr-proxy-http-proxy-enable "another:8081")
      (zr-proxy-http-proxy-mode -1)
      (should-not zr-proxy-http-proxy-mode)
      (should (equal services url-proxy-services))
      (should (eq #'ignore url-proxy-locator))
      (should (equal (sort env #'string<)
                     (sort (copy-sequence process-environment) #'string<)))
      (should (eq 'unset zr-proxy--saved-proxy-services)))))

(ert-deftest zr-proxy-test-mode-enable-error-rolls-back ()
  "Missing configuration must not leave transformation bypass enabled."
  (zr-proxy-test--with-proxy-state
    (should-error (zr-proxy-http-proxy-mode 1) :type 'user-error)
    (should-not zr-proxy-http-proxy-mode)
    (should-not url-proxy-services)
    (should-not process-environment)
    (should (eq #'ignore url-proxy-locator))))

(ert-deftest zr-proxy-test-no-proxy-host-list-and-regexp ()
  "Environment lists match host boundaries and remain lists for subprocesses."
  (zr-proxy-test--with-proxy-state
    (setenv "NO_PROXY" " localhost, 127.0.0.1, .example.com ")
    (zr-proxy-http-proxy-enable "proxy:8080")
    (dolist (host '("localhost" "127.0.0.1" "example.com" "sub.example.com"))
      (should (equal "DIRECT"
                     (url-default-find-proxy-for-url
                      (url-generic-parse-url (concat "https://" host)) host))))
    (dolist (host '("notlocalhost" "notexample.com" "example.com.evil" "exampleXcom"))
      (should (equal "PROXY proxy:8080"
                     (url-default-find-proxy-for-url
                      (url-generic-parse-url (concat "https://" host)) host))))
    (should (equal " localhost, 127.0.0.1, .example.com " (getenv "no_proxy")))
    (zr-proxy-http-proxy-disable)
    (setq zr-proxy-no-proxy "\\`internal[0-9]+\\'")
    (zr-proxy-http-proxy-enable "proxy:8080")
    (should (equal zr-proxy-no-proxy
                   (alist-get "no_proxy" url-proxy-services nil nil #'equal)))
    (should (equal " localhost, 127.0.0.1, .example.com " (getenv "no_proxy")))))

(ert-deftest zr-proxy-test-no-proxy-wildcard ()
  "The conventional wildcard bypasses every host."
  (zr-proxy-test--with-proxy-state
    (setenv "no_proxy" "*")
    (zr-proxy-http-proxy-enable "proxy:8080")
    (should (equal "DIRECT"
                   (url-default-find-proxy-for-url
                    (url-generic-parse-url "https://example.com") "example.com")))))

(provide 'zr-proxy-test)
;;; zr-proxy-test.el ends here
