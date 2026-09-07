# AGENT.md

本仓库是 zr-elisp 的一组 Emacs Lisp 工具包。维护约定如下。

## Preference

- 使用 `{when,if}-let*`，不要用 `{when,if}-let`。
- 不需要 `(require 'json)`，`json-serialize/json-parse-{string/buffer}` 可直接用。

## Conventions

- **专注业务**: `.claude/.env` 等 dotfile 作为环境文件不需要特别关注。
- **重构勿兼容旧代码**：改动时不必为旧代码做兼容处理，保持代码干净简洁。
- **常用操作用 Makefile**：`make test/check-parens/byte-compile/clean` 等，具体见 `Makefile`。
- **业务文件独立**：每个业务代码文件尽量保持独立；通用代码提取到 `zr-lib.el`。
