# ERC modules

Requires Emacs 30.1 or newer. Add this directory to `load-path` before
loading a module. Loading files and setting options do not enable modules.
Enable them with their mode commands, or list them in `erc-modules` so ERC
enables them during setup.

```elisp
(add-to-list 'load-path "/path/to/zr-elisp/erc")
(require 'zr-erc-reply)
(erc-zr-reply-mode 1)
```

Alternatively, configure ERC's module list before connecting:

```elisp
(require 'zr-erc-reply)
(add-to-list 'erc-modules 'zr-reply)
```

The other global module names are `zr-stitch`, `zr-completion` and `zr-media`.
After changing `erc-modules` in an existing session, run
`M-x erc-update-modules` to enable listed global modules. If they are already
enabled through this list or earlier configuration, changing rules takes
effect without another mode call. `zr-display` is buffer-local: add it
to `erc-modules` before connecting, or run `M-x erc-zr-display-mode`
in an existing conversation. `erc-update-modules` skips local modules.

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

## Local display rules

`zr-erc-display` changes local presentation with overlays: replace the speaker
name, replace selected text, or hide it by replacing it with an empty string.
Rules default to nil. Loading the file does not enable the buffer-local mode.
To enable it during ERC setup:

```elisp
(require 'zr-erc-display)
(add-to-list 'erc-modules 'zr-display)
```

To extract a relay name and hide its duplicate body prefix, evaluate this in
the conversation buffer; no rejoin is needed:

```elisp
(setq-local zr-erc-display-rules
            '((:match (:sender "\\`nichi_bot\\'")
               :source body :regexp "\\[\\([^]]+\\)\\][ \t]*"
               :replace-sender "\\1" :replace-text "")))
(erc-zr-display-mode 1)
```

For `<nichi_bot> [nami.yti] 强大v5`, the nickname becomes `nami.yti` and
the matched prefix `[nami.yti] ` is hidden, leaving `<nami.yti> 强大v5`.
Both `:replace-sender` and `:replace-text` are optional: nil or omitted means
no change, while an empty string hides that part. The first rule yielding a
replacement wins; a matching rule with neither action is skipped.

String replacements use Emacs `replace-match` backreferences: `"\\1"` selects
group 1, `"\\&"` selects the full match, and `"user: \\1"` adds a prefix.
Case is preserved. `:replace-sender` replaces the displayed nickname;
`:replace-text` replaces the **entire regexp match**, not just a capture.
Use captures to preserve or rearrange parts of that match:

```elisp
(setq-local zr-erc-display-rules
            '((:match (:sender "\\`nichi_bot\\'")
               :source body :regexp "\\`\\[\\([^]]+\\)\\] *\\(.*\\)"
               :replace-sender "\\1" :replace-text "\\2")))
(zr-erc-display-refresh)
```

Either replacement may instead be a function receiving a context plist. It
contains the original `:sender`, `:body`, `:text`, `:tags`, `:target`, `:server`
and `:network`, plus `:source` (the selected source), `:value` (its full string),
and `:groups` (a vector of captures, starting with the complete match at 0).
Unmatched optional groups are nil. Each callback receives its own context
copy and need not depend on dynamic match data. Return nil for no change or
a string for literal display; backreferences in returned strings are not
expanded. For example:

```elisp
(setq-local zr-erc-display-rules
            '((:source body :regexp "\\[\\([^]]+\\)\\]"
               :replace-sender
               (lambda (context)
                 (concat (plist-get context :sender) "/"
                         (aref (plist-get context :groups) 1)))
               :replace-text "")))
```

Sender and text replacements are independent. Nonempty sender replacements
containing control characters or only whitespace are rejected. Rules retain
the full source and match offsets; replacement never searches for another
occurrence of the matched fragment. Position mapping depends on the source:

- `text`: use offsets in the complete retained formatted message, including
  wrapped lines, after verifying that it still matches the buffer text.
- `body`: verify the complete raw body at the end of the rendered message,
  either as-is or with IRC controls removed, before mapping its offsets.
  ERC trailing timestamp fields and their padding are excluded from this
  comparison; timestamps and original message text remain unchanged.
  Whitespace runs may change during ERC filling; the complete body must
  still match. Matches splitting a control sequence or a changed whitespace
  run are not replaced.
- Reply references: verify the visible excerpt against the corresponding
  prefix of the original body, using the reply module's control conversion.
  A match extending beyond the truncated excerpt is not replaced. `text`
  offsets are usable when the original raw body is an exact suffix of that
  source text.

If formatting prevents that correspondence, preserve the display.
Old history without retained
message boundaries supports only its fallback line. Tag and sender sources
support nickname replacement, not body text replacement. Empty matches do
not insert text. All text replacements stay after the nickname and within
their own message or reply reference.

Tag-based names are opt-in. Without `:regexp`, the entire source is group 0:

```elisp
(setq zr-erc-display-rules
      '((:source (:tag "+display-name") :replace-sender "\\&")))
```

The default `zr-erc-message-tag-receive-remap` still maps
`+draft/display-name` to `+display-name`. Reception decodes tags, applies
remapping, then builds rule contexts for all modules. A canonical tag in the
message wins over its alias, even when empty. Remapping is applied once,
without chaining, and does not modify the raw IRC message.

The extraction sources are distinct; `:match` uses the same selectors as
the other modules:

| Source | Contents |
| --- | --- |
| `body` | Original message body, possibly with IRC formatting controls; no sender or tags. |
| `text` (default) | ERC's formatted buffer text, usually nickname and body, without display overlays or the reply reference prefix; no protocol tags. |
| `sender` | Original IRC nickname, without the user/host suffix. |
| `(:tag "+display-name")` | The decoded tag value after receive remapping. |

Use `text` for history whose original body metadata is no longer available.
For such history, the fallback text is the retained line containing the
speaker; formatting, timestamps and wrapping may affect its contents.
History without ERC speaker properties cannot be transformed.

Reply references, including those in locally sent replies, use the quoted
message's own original context. Both name replacement and text replacement
work there, including rules that only hide text. Reply summaries retain this
context even with display mode off, so references can still be transformed
after their original messages have been truncated from history. References
created before the reply module retained this metadata remain unchanged.

Toggle with `M-x erc-zr-display-mode`; disabling restores names and body text.
Enabling refreshes retained history. After changing rules, run
`M-x zr-erc-display-refresh` to update existing messages.
Original text, sender identities, tags and shared rule contexts remain
unchanged: completion, replies, stitching and media match the actual message.
Copying and logging buffer text retain the originals; reply navigation is
unchanged. Hovering over a replaced nickname shows its IRC nickname.

### Wrapping displayed messages

Use ERC's `fill-wrap` module with display rules. It wraps at the window's
width without inserting newlines, so hidden body prefixes and replacement
text take their displayed width. `zr-display` remeasures the first-line
indentation after applying overlays, including renamed speakers in reply
references. Refreshing rules or disabling display also updates indentation.

Configure this before connecting:

```elisp
(require 'zr-erc-display)
(setq erc-fill-wrap-merge nil)
(add-to-list 'erc-modules 'fill-wrap)
(add-to-list 'erc-modules 'zr-display)
```

Keep `fill` enabled: `fill-wrap` uses it. Disable `erc-fill-wrap-merge`
because it groups messages by the original IRC nickname; different people
relayed through the same bot must keep their speaker labels. The display
module does not change these settings automatically.

In an existing conversation, enable wrapping explicitly:

```elisp
(setq-local erc-fill-wrap-merge nil)
(erc-fill-wrap-mode 1)
(erc-zr-display-mode 1)
```

This applies to new messages. Old hard-filled history retains its inserted
newlines; use a fresh buffer for a completely wrapped history. If the buffer
already used `fill-wrap` with merging enabled, run
`C-u M-x erc-fill-wrap-refill-buffer` to restore merged speaker labels.

`erc-fill-static-center` controls the common body column. `fill-wrap` places
timestamps in the window margins; `erc-fill-wrap-margin-width` controls
their reserved width. Use `erc-fill-wrap-nudge` for interactive adjustments
and `erc-fill-wrap-refill-buffer` after font-size changes. Ordinary
`erc-fill-variable` and `erc-fill-static` still insert hard breaks before
display replacements and do not get this alignment update.

## Images and downloads

```elisp
(require 'zr-erc-media)
(erc-zr-media-mode 1)
```

Links are dispatched through buffer-local `org-link-parameters` from `ol`.
HTTP(S) media links use the rules below; ordinary web links open in the browser.
`file:/path` and `file:///path` open local files (including images) in Emacs.
`irc://irc.example.com/#channel?key` and
`ircs://irc.example.com/#channel?key` open ERC and join the channel with its
optional key; `ircs` uses TLS for new connections. Explicit ports are supported.
ERC controls connection reuse and any prompts needed to establish a connection.

The module installs local handlers in existing and new ERC buffers and restores
previous parameters when disabled. After enabling it, customize a buffer with:

```elisp
;; Replace an existing handler without affecting Org or other ERC buffers.
(org-link-set-parameters "https" :follow
                         (lambda (path _arg) (browse-url (concat "https:" path))))
;; Add a type directly, without rebuilding Org's global link regexps.
(setf (alist-get "project" org-link-parameters nil nil #'equal)
      '(:follow my-project-open)) ; receives PATH and prefix ARG
```

Registered plain `type:path` links in new messages become buttons. Handlers are
looked up when clicked, so changes also apply to existing buttons. File handlers
use the same dispatch as other types. Org markup and Org font locking are not
enabled in ERC buffers.

Recognized media links become buttons. RET/mouse-2 toggles an image preview or prompts
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

The stitch, completion, display and media options are ordinary `defcustom` variables
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
