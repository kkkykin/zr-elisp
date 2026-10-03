;;; zr-network-test.el --- Tests for zr-network -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zr-network)

(ert-deftest zr-network-test-public-ipv6-addresses ()
  (dolist (address '([#x2001 #x4860 #x4860 0 0 0 0 #x8888]
                     [#x240e 1 2 3 4 5 6 7]
                     [#x2606 #x4700 #x4700 0 0 0 0 #x1111]
                     [#x64 #xff9b 0 0 0 0 #x808 #x808]
                     [#x2001 1 0 0 0 0 0 1]
                     [#x2001 1 0 0 0 0 0 2]
                     [#x2001 1 0 0 0 0 0 3]
                     [#x2001 3 0 0 0 0 0 1]
                     [#x2001 4 #x112 0 0 0 0 1]
                     [#x2001 #x2f 0 0 0 0 0 1]
                     [#x2001 #x3f 0 0 0 0 0 1]
                     [#x2001 #x200 0 0 0 0 0 1]
                     [#x3fff #x1000 0 0 0 0 0 1]
                     [#x3ffe #xffff 0 0 0 0 0 1]))
    (ert-info ((format "Public: %S" address))
      (should (eq t (zr-network--public-ipv6-p address)))
      ;; The ninth element is a port, not an address word or prefix length.
      (should (eq t (zr-network--public-ipv6-p (vconcat address [443])))))))

(ert-deftest zr-network-test-non-public-ipv6-addresses ()
  (dolist (address '([0 0 0 0 0 0 0 0]                   ; Unspecified.
                     [0 0 0 0 0 0 0 1]                 ; Loopback.
                     [0 0 0 0 0 #xffff #x808 #x808]     ; IPv4-mapped.
                     [0 0 0 0 0 0 #x808 #x808]          ; IPv4-compatible.
                     [#x64 #xff9b 1 0 0 0 0 1]         ; Local-use NAT64.
                     [#x64 #xff9b 0 0 0 1 0 1]         ; Outside NAT64 /96.
                     [#x100 0 0 0 0 0 0 1]             ; Discard-only.
                     [#x100 0 0 1 0 0 0 1]             ; Dummy prefix.
                     [#x2001 0 0 0 0 0 0 1]            ; Teredo.
                     [#x2001 1 0 0 0 0 0 4]            ; Outside anycast /128.
                     [#x2001 1 0 0 0 0 1 1]
                     [#x2001 2 0 0 0 0 0 1]            ; Benchmarking.
                     [#x2001 4 #x113 0 0 0 0 1]        ; Outside AS112 /48.
                     [#x2001 #x1f 0 0 0 0 0 1]         ; Deprecated ORCHID.
                     [#x2001 #x40 0 0 0 0 0 1]         ; Outside DET /28.
                     [#x2001 #x1ff 0 0 0 0 0 1]        ; Last IETF /23 subnet.
                     [#x2001 #xdb8 0 0 0 0 0 1]        ; Documentation.
                     [#x2002 #x808 #x808 0 0 0 0 1]     ; 6to4.
                     [#x3fff #xfff 0 0 0 0 0 1]        ; Documentation /20.
                     [#x4000 0 0 0 0 0 0 1]            ; Outside GUA /3.
                     [#x5f00 0 0 0 0 0 0 1]            ; SRv6 SIDs.
                     [#xfc00 0 0 0 0 0 0 1]            ; Unique local.
                     [#xfdff 0 0 0 0 0 0 1]
                     [#xfe80 0 0 0 0 0 0 1]            ; Link local.
                     [#xfebf 0 0 0 0 0 0 1]
                     [#xfec0 0 0 0 0 0 0 1]            ; Deprecated site local.
                     [#xff0e 0 0 0 0 0 0 1]))          ; Global multicast.
    (ert-info ((format "Not public: %S" address))
      (should-not (zr-network--public-ipv6-p address))
      (should-not (zr-network--public-ipv6-p (vconcat address [0]))))))

(ert-deftest zr-network-test-invalid-addresses ()
  (dolist (address '(nil "2001:4860::1" [127 0 0 1 0] []
                     [#x240e 0 0 0 0 0 1]
                     [#x240e 0 0 0 0 0 0 1 0 0]
                     [#x240e 0 0 0 0 0 0 -1]
                     [#x240e 0 0 0 0 0 0 65536]
                     [#x240e 0 0 0 0 0 0 "1"]
                     [#x240e 0 0 0 0 0 0 1.0]))
    (should-not (zr-network--public-ipv6-p address))))

(ert-deftest zr-network-test-interface-selection ()
  (let ((interfaces '(("rmnet_data0" . [#x240e 0 0 0 0 0 0 1 0])
                      ("wlan0" . [#xfe80 0 0 0 0 0 0 1 0])))
        (wifi-p (lambda (name) (string= name "wlan0"))))
    (cl-letf (((symbol-function 'network-interface-list)
               (lambda (full family)
                 (should-not full)
                 (should (eq family 'ipv6))
                 interfaces)))
      (should (eq t (zr-network-has-public-ipv6-addr-p)))
      (should-not (zr-network-has-public-ipv6-addr-p wifi-p))
      ;; An empty selection must not fall back to the cellular interface.
      (should-not (zr-network-has-public-ipv6-addr-p (lambda (_) nil)))
      ;; Interface names may repeat for different addresses.
      (setq interfaces (append interfaces
                               '(("wlan0" . [#x240e 0 0 0 0 0 0 2 0]))))
      (should (eq t (zr-network-has-public-ipv6-addr-p wifi-p)))
      (setq interfaces nil)
      (should-not (zr-network-has-public-ipv6-addr-p)))))

(ert-deftest zr-network-test-short-circuits ()
  (let (visited)
    (cl-letf (((symbol-function 'network-interface-list)
               (lambda (&rest _)
                 '(("eth0" . [#x240e 0 0 0 0 0 0 1 0])
                   ("eth1" . [#x240e 0 0 0 0 0 0 2 0])))))
      (should (zr-network-has-public-ipv6-addr-p
               (lambda (name) (push name visited) t)))
      (should (equal visited '("eth0"))))))

(provide 'zr-network-test)
;;; zr-network-test.el ends here
