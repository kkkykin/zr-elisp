# zr-elisp

一组独立的 Emacs Lisp 工具包，需要 Emacs 31.1 及以上。
各模块按需加载，通过命令、hook 或 minor mode 启用功能。

## 目录

| 代码目录 | 内容 | 测试目录 |
| --- | --- | --- |
| 仓库根目录 | 编辑、词典、进程、网络、媒体和平台工具 | `test/` |
| [`org/`](org/README.md) | Org 编辑、Babel、Tangle、导出、链接、协议和 Org-srs | `org/test/` |
| [`erc/`](erc/README.md) | ERC 消息显示、补全、链接和回复 | `erc/test/` |

## 加载

将仓库根目录加入 `load-path`，使用 Org 或 ERC 模块时加入对应目录：

```elisp
(add-to-list 'load-path "/path/to/zr-elisp")
(add-to-list 'load-path "/path/to/zr-elisp/org")
(add-to-list 'load-path "/path/to/zr-elisp/erc")

(use-package zr-bookmark
  :custom (zr-bookmark-shared-file "~/shared/bookmarks")
  :config (zr-bookmark-shared-mode 1))
(use-package zr-comint
  :hook ((comint-mode . zr-comint-history-mode)
         (shell-mode . zr-comint-shell-setup)))
(use-package zr-org :hook (org-mode . zr-org-mode))
(use-package zr-org-babel :hook (org-mode . zr-org-babel-mode))
```

Minor mode 用参数 `-1` 关闭。路径、快捷键及站点配置由个人初始化文件设置。
各模块的配置与入口见对应文件的 Commentary 和 docstring；Org、ERC 的详细说明见目录中的 README。

## 验证

```sh
make test
make check-parens
make byte-compile
make clean

make test TEST_FILE=test/zr-bookmark-test.el
make test TEST_FILE='$(wildcard org/test/*-test.el)'
make check-parens byte-compile FILE='$(wildcard org/*.el)'
```

Makefile 自动发现根目录、`org/`、`erc/` 下的业务文件和对应测试，
并将 `test/` 加入测试加载路径，供各测试复用公共辅助宏。
跨模块加载与生命周期检查位于 `test/zr-module-loading-test.el`。
集成测试使用临时目录和本机服务；涉及 Org-srs 的测试在未安装该包时跳过。
