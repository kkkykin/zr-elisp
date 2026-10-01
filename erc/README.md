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

The default rule works for any sender. `:match` optionally selects a sender,
target, server, network, body, or tags. For example,
`:match (:tags (("+bridge" . "^onebot$")))` requires that tag value.
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
```

For `<白雪-17225180/onebot> ...`, typing `@白 TAB` completes `@白雪`;
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

## Images and downloads

```elisp
(require 'zr-erc-media)
(erc-zr-media-mode 1)
```

Recognized links become buttons. RET/mouse-2 previews an image or prompts for
a file destination. `M-x zr-erc-media-download` saves either type. Downloads
run asynchronously, and overwriting a file requires confirmation. Automatic
image fetching is off by default; it can be enabled globally, per buffer, or
per rule. Inline images need an Emacs display with image support; downloads
also work in terminal Emacs.

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

The three new modules' options support `setq-local`, so a channel's settings
do not affect another channel. They do not depend on Emacs 32's `erc-settings`.
Message-tag selectors require the server to send those tags; on Emacs 30,
enabling `erc-zr-reply-mode` negotiates `message-tags`. The regexp-only paths
work independently of the reply module.

Run all ERC tests with `make test TEST_FILE="$(echo erc/test/*-test.el)"`.
The media tests start a temporary loopback HTTP server when Python 3 is
available and exercise actual FFmpeg conversion when FFmpeg/ffprobe are
available. The current terminal test environment substitutes only image
creation, then checks the generated PNG dimensions and inline display property.
