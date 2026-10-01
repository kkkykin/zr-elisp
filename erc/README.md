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
