;;; zr-network.el --- Local network address inspection -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Inspect configured addresses without contacting external services.
;; Address scope does not establish a default route or Internet connectivity.
;; Interface selection is explicit and independent of platform APIs.

;;; Code:

(require 'cl-lib)

(defconst zr-network--ipv6-public-prefixes
  '(;; More specific exceptions must precede their containing prefixes.
    ([#x64 #xff9b 0 0 0 0] 96 t)           ; Well-known NAT64 prefix.
    ([#x2001 1 0 0 0 0 0 1] 128 t)        ; PCP anycast.
    ([#x2001 1 0 0 0 0 0 2] 128 t)        ; TURN anycast.
    ([#x2001 1 0 0 0 0 0 3] 128 t)        ; DNS-SD registration anycast.
    ([#x2001 3] 32 t)                      ; AMT.
    ([#x2001 4 #x112] 48 t)                ; AS112.
    ([#x2001 #x20] 28 t)                   ; ORCHIDv2.
    ([#x2001 #x30] 28 t)                   ; Drone identity tags.
    ([#x2001 0] 23 nil)                    ; Other IETF assignments / Teredo.
    ([#x2001 #xdb8] 32 nil)                ; Documentation.
    ([#x2002] 16 nil)                      ; 6to4: reachability is conditional.
    ([#x3fff 0] 20 nil)                    ; Documentation.
    ([#x2000] 3 t))                        ; Global unicast allocations.
  "Ordered (PREFIX BITS PUBLIC) rules; unmatched addresses are not public.
PREFIX contains only the leading 16-bit words needed for BITS.
Special assignments follow IANA's Globally Reachable column as of
2026-10-04; entries with indeterminate reachability are excluded.
See https://www.iana.org/assignments/iana-ipv6-special-registry/.")

(defun zr-network--ipv6-prefix-p (address prefix bits)
  "Return t if IPv6 ADDRESS matches the leading BITS of PREFIX.
ADDRESS and PREFIX are vectors of 16-bit words."
  (cl-loop for word across prefix
           for index from 0
           for shift = (min 0 (- bits (* 16 (1+ index))))
           always (= (ash (aref address index) shift) (ash word shift))))

(defun zr-network--public-ipv6-p (address)
  "Return t if ADDRESS is classified as public IPv6.
Accept eight 16-bit words, optionally followed by a port; ignore the port."
  (and (vectorp address)
       (memq (length address) '(8 9))
       (cl-loop for index below 8
                for word = (aref address index)
                always (and (integerp word) (<= 0 word #xffff)))
       (cl-loop for (prefix bits public) in zr-network--ipv6-public-prefixes
                when (zr-network--ipv6-prefix-p address prefix bits)
                return public)))

(defun zr-network-has-public-ipv6-addr-p (&optional interface-predicate)
  "Return t if a selected local interface has a public IPv6 address.
With nil INTERFACE-PREDICATE, inspect all interfaces.  Otherwise call it
with each interface name and inspect only those for which it returns
non-nil.  An empty selection returns nil.

Public means global unicast or an IANA special assignment marked globally
reachable.  Teredo and 6to4 are conservatively excluded.  This inspects
configured addresses only, not interface state, default routes, address
lifetimes or actual connectivity.  Return nil if no addresses are available;
errors from interface enumeration or INTERFACE-PREDICATE propagate.

For example, to inspect Wi-Fi only:
  (zr-network-has-public-ipv6-addr-p
   (lambda (name) (string= name \"wlan0\")))"
  (cl-loop for (name . address) in (network-interface-list nil 'ipv6)
           thereis (and (or (null interface-predicate)
                            (funcall interface-predicate name))
                        (zr-network--public-ipv6-p address))))

(provide 'zr-network)
;;; zr-network.el ends here
