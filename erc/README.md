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
when `ZR_ERC_REPLY_TEST_PORT` names its listening port.
