# ERC modules

Requires Emacs 30.1 or newer. Add this directory to `load-path` before
loading a module. Loading a file does not enable its module.

```elisp
(add-to-list 'load-path "/path/to/zr-elisp/erc")
(require 'zr-erc-reply)
(erc-zr-reply-mode 1)
```

`zr-erc-reply` implements the IRCv3 `+reply` tag. Put point on a message
and run `M-x zr-erc-reply`. Replies show the original sender and an excerpt;
click the excerpt or run `M-x zr-erc-reply-jump` to visit the original.

From the repository root:

```sh
make test TEST_FILE=erc/test/zr-erc-reply-test.el
make check-parens byte-compile FILE=erc/zr-erc-reply.el
```

The reply test also exercises two ERC clients on an isolated local Ergo
when `ZR_ERC_REPLY_TEST_PORT` names its listening port. The integration test
also sends a Unicode `RELAYMSG`: configure the isolated Ergo with
`server.casemapping: permissive` and `server.relaymsg.available-to-chanops: true`.

## Clipped messages

```elisp
(require 'zr-erc-stitch)
(erc-zr-stitch-mode 1)
;; These options also support setq-local in an ERC buffer.
(setq zr-erc-stitch-rules
      '((:match (:sender "bridge\\|onebot")
         :end " <clipped message>\\'"
         :start "\\`<clipped message> " :separator "")))
```

`zr-erc-stitch-rules` defaults to nil. Rules without `:match` work for any sender.
`:match` optionally selects a sender, target, server, network, body, or tags.
For example, `:match (:tags (("+bridge" . "^onebot$")))` requires that tag value.
`:more-tag ("+continued" . "^1$")` can replace `:end`; `:group-tag "+group"`
prevents merging different groups from the same sender.

Fragments wait up to `zr-erc-stitch-timeout` seconds (default 5).
Interruption by another speaker, timeout, disabling the module, or exceeding
`zr-erc-stitch-max-fragments` / `zr-erc-stitch-max-length` displays the originals.
Complete sequences preserve all original message IDs for reply navigation.
CTCP actions are not collected.

## Relay name completion

```elisp
(require 'zr-erc-completion)
(erc-zr-completion-mode 1)
;; These options also support setq-local in an ERC buffer.
(setq zr-erc-completion-rules
      '((:source sender
         :regexp "\\`\\(.+\\)-\\([0-9]+\\)/onebot\\'" :groups (1 2))
        (:source text :regexp "^<\\(.+\\)-\\([0-9]+\\)/onebot> " :groups (1 2))
        (:source text :regexp "^<\\([^>]+\\)> " :groups (1))))
```

`zr-erc-completion-rules` defaults to nil. With rules configured, for
`<白雪-17225180/onebot> ...`, typing `@白 TAB` completes `@白雪`;
`@17 TAB` completes `@17225180`. Other input uses ordinary ERC completion.
Candidates come from this buffer's retained history, including history that
predates enabling the module. Wrapped continuation lines do not add candidates.

All parts are configurable with buffer-local options:

```elisp
(setq-local zr-erc-completion-rules
            '((:source sender
               :regexp "\\`\\(.+\\)-\\([0-9]+\\)/onebot\\'" :groups (1 2))
              (:source (:tag "+display-name"))
              (:source text :regexp "^<\\([^>]+\\)> " :groups (1))))
```

The first successful rule wins. `:groups (2)` would offer only the numeric ID.
`:source body` extracts from the message body; `:match` accepts the same
selectors as stitching. `zr-erc-completion-input-regexp` and
`zr-erc-completion-input-group` control the trigger and the portion replaced.
`zr-erc-completion-history-limit` bounds the amount of history scanned.

## Local display names

```elisp
(require 'zr-erc-display-name)
;; Evaluate in the conversation buffer; no rejoin is needed.
(setq-local zr-erc-display-name-rules
            '((:match (:sender "\\`nichi_bot\\'")
               :source text :regexp "\\[\\([^]]+\\)\\]" :group 1)))
(erc-zr-display-name-mode 1)
```

This buffer-local mode displays `Sydney Dian` over the IRC nickname in
`<nichi_bot> [Sydney Dian] hello`. The bracketed name in the body is retained.
IRC formatting controls outside the brackets do not affect this rule.
Toggle with `M-x erc-zr-display-name-mode`; disabling immediately restores
original nicknames. Enabling also refreshes retained history. After changing
rules, run `M-x zr-erc-display-name-refresh` to refresh existing messages.

Names use display overlays only. Original text, sender identity, message tags
and shared rule contexts remain unchanged: completion, replies, stitching
and media keep matching the actual message. No synthetic `+display-name`
tag is added, and copying/logging buffer text retains the original nickname.
Hovering over a replaced nickname shows its IRC nickname.

Rules default to nil. The first successful rule wins; `:match` uses the same
selectors as the other modules. `:source` accepts `text` (default), `body`,
`sender`, or `(:tag "+display-name")`. With `:regexp`, `:group` defaults to 1;
without a regexp, the whole source is used. Empty, whitespace-only and
control-containing names are rejected. Metadata for messages received while
the mode is enabled is retained for later refreshes. For older history whose
metadata ERC has already discarded, only the original speaker and rendered
text are available, so use a `text` rule as above. History without ERC speaker
properties cannot be renamed.

## Images and downloads

```elisp
(require 'zr-erc-media)
(erc-zr-media-mode 1)
```

Recognized links become buttons. RET/mouse-2 toggles an image preview or prompts
for a file destination. `M-x zr-erc-media-show` toggles the image at point, or
all image links overlapping the active region. With a prefix argument
(`C-u M-x zr-erc-media-show`), it toggles images in the selected window's
visible range, taking precedence over the region. If any targeted image is
displayed or loading, all targeted previews are hidden and pending image
requests canceled; otherwise, they are fetched and shown. This also hides
automatically displayed images, even after their links have expired. Range
previews skip file links and continue if an image has expired or a request
fails. These manual previews work with automatic image fetching disabled.

`M-x zr-erc-media-download` saves either type. Downloads
run asynchronously, and overwriting a file requires confirmation. Automatic
image fetching is off by default; it can be enabled globally, per buffer, or
per rule. Inline images need an Emacs display with image support; downloads
also work in terminal Emacs.

Set `zr-erc-media-max-age` to an age limit in seconds, globally or per buffer,
to avoid requesting expired links. The default is nil (unlimited). A rule's
`:max-age` overrides the option; an explicit `:max-age nil` disables the limit
for that rule. For example, only request these image links for one hour:

```elisp
(setq-local zr-erc-media-rules
            '((:regexp "\\`https://multimedia\\.nt\\.qq\\.com\\.cn/download\\?"
               :type image :auto-show t :max-age 3600)))
```

Age uses the IRC `time` tag supplied by servers with `server-time`, falling
back to local receipt time when the tag is absent or invalid. Without that
tag, the original age of replayed history cannot be determined. Expired
links remain buttons but skip automatic previews; manual previews and
downloads report expiration before starting a request or asking for a save
destination. Age is checked again for each request. Existing previews and
requests already in progress are retained. This is separate from
`zr-erc-media-timeout`, which limits how long a request may run.

Use `zr-erc-media-proxy` to select an HTTP proxy for both previews and
downloads. It supports global and buffer-local settings, with per-rule
overrides via `:proxy`:

```elisp
(setq-local zr-erc-media-proxy "http://127.0.0.1:7890")
;; Alternatively, add this to an existing media rule:
;; :proxy "http://127.0.0.1:7890"
```

The default, `inherit`, uses Emacs's existing URL proxy settings. A nil
value forces a direct connection, including `:proxy nil` in a rule.
`:proxy inherit` restores the Emacs settings for a rule. Proxy addresses
accept `host:port` or `http://host:port`, including bracketed IPv6 hosts;
credentials and paths in proxy URLs are not supported. Explicit proxies
bypass `no_proxy` exclusions. HTTP links use the proxy directly, and HTTPS
links use CONNECT tunnels. These settings affect only media requests and
do not alter the proxy configuration used by other Emacs packages.

Example for an authenticated image proxy and ordinary downloadable files:

```elisp
(setq-local zr-erc-media-rules
            '((:regexp "\\`https://cdn\\.example/images/\\(.*\\)\\'"
               :replace "https://gateway.example/media/\\1"
               :type image
               :headers (("X-Client" . "erc"))
               :auth-source (:user "bridge")
               :auth-scheme bearer
               :auto-show t :ffmpeg t
               :max-width 0.85 :max-height 0.6)
              (:regexp "\\.\\(?:pdf\\|zip\\)\\(?:[?#].*\\)?\\'" :type file)))
```

The visible label keeps the original link; requests use the rewritten URL.
Credentials are looked up for the **rewritten** host and port. For example,
an entry in an `auth-sources` file could be:

```text
machine gateway.example port 443 login bridge password YOUR_TOKEN
```

`:auth-source t` searches by host/port; a plist can add or override search
criteria. `:auth-scheme basic` is the default; `bearer` sends the secret as a
Bearer token. `:auth-header` changes the header name. Credentials are resolved
at request time, not stored in the message button. Redirects are rejected;
use a rewrite to the final resource URL.

As with the other modules, `:match` accepts message selectors. A URL can also
come from a tag rather than the body:

```elisp
(setq-local zr-erc-media-rules
            '((:match (:tags (("+media-kind" . "^image$")))
               :url-tag "+media-url" :regexp "\\`https://" :type image)))
```

`zr-erc-media-use-ffmpeg` enables FFmpeg conversion by default; a rule's
`:ffmpeg` overrides it. Conversion produces a single-frame PNG preview,
preserves aspect ratio and does not enlarge small images. Downloads always
save the original data. `zr-erc-media-max-width` / `-max-height` accept integer
pixels or floating-point fractions of the current window. Preview again to
fit a changed window size. `zr-erc-media-ffmpeg-program` selects the executable.

Requests and conversions use `zr-erc-media-timeout`; responses larger than
`zr-erc-media-max-bytes` are rejected. Temporary previews and pending requests
are cleaned when the module is disabled or the buffer is killed; removing a
link from scrollback also removes its preview. `zr-erc-media-download-directory`
sets the initial save directory.

## Configuration scope

The stitch, completion, display-name and media options are ordinary `defcustom` variables
with global defaults. Loading or enabling these modules does not create local
bindings for their options. Use `setq` or `setopt` for global configuration,
or `setq-local` in an ERC buffer to override an option for that buffer only.
The modules' buffer-local internal state is separate from these user options.

On Emacs 32, the native
[`erc-settings`](https://github.com/emacs-mirror/emacs/blob/master/lisp/erc/erc-settings.el)
module can also assign these options per buffer. It skips any variable that
already has a local binding, even if the local value is nil or equals the
global default; neither `:eval` nor `:custom` forces an override. If using
`erc-settings`, let it create the local bindings instead of copying defaults
into buffers with `setq-local` or `make-local-variable` beforehand. Declaring
a variable with `defvar-local` or `make-variable-buffer-local` alone does not
create a local binding in each buffer; assigning it locally does.

These modules do not require `erc-settings`. Configure that option and enable
the `settings` module before connecting if you use it. Its upstream guidance
is to destroy and reopen affected sessions to apply changes to `erc-settings`.

Message-tag selectors require the server to send those tags; on Emacs 30,
enabling `erc-zr-reply-mode` negotiates `message-tags`. The regexp-only paths
work independently of the reply module.

Run all ERC tests with `make test TEST_FILE="$(echo erc/test/*-test.el)"`.
The media tests start a temporary loopback HTTP server when Python 3 is
available and exercise actual FFmpeg conversion when FFmpeg/ffprobe are
available. Proxy tests use a loopback HTTP proxy; HTTPS CONNECT tests also
require OpenSSL and Emacs GnuTLS support. The current terminal test environment
substitutes only image creation, then checks the generated PNG dimensions and
inline display property.
