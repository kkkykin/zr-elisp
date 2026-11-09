# zr-elisp

一组独立的 Emacs Lisp 工具包，需要 Emacs 31.1 及以上。
各模块按需加载，通过命令、hook 或 minor mode 启用功能。

## 目录

| 代码目录 | 内容 | 测试目录 |
| --- | --- | --- |
| 仓库根目录 | 编辑、词典、进程、网络、媒体和平台工具 | `test/` |
| [`org/`](org/README.md) | Org 编辑、Babel、Tangle、导出、链接、协议和 Org-srs | `org/test/` |
| [`erc/`](erc/README.md) | ERC 消息显示、补全、链接和回复 | `erc/test/` |
| [`gnus/`](gnus/README.md) | Gnus 后端和本地 EPUB 阅读 | `gnus/test/` |
| [`scripts/`](scripts/) | 按模块存放的 PowerShell 等辅助脚本 | 随对应模块测试 |

## 加载

将仓库根目录加入 `load-path`，使用 Org、ERC 或 Gnus 模块时加入对应目录：

```elisp
(add-to-list 'load-path "/path/to/zr-elisp")
(add-to-list 'load-path "/path/to/zr-elisp/org")
(add-to-list 'load-path "/path/to/zr-elisp/erc")
(add-to-list 'load-path "/path/to/zr-elisp/gnus")

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
各模块的配置与入口见对应文件的 Commentary 和 docstring；Org、ERC、Gnus 的详细说明见目录中的 README。
使用脚本的模块会按自身位置查找 `scripts/`；复制或安装时需一并保留该目录结构。
`zr-windows-powershell-program` 可指定 PowerShell 的名称或路径，默认自动查找；
`zr-windows-powershell-arguments` 可调整快捷方式注册和 TTS 共用的启动参数。

`zr-terminal` 提供公共 OSC 编码、发送和 OSC 777 通知，`zr-wezterm` 负责
`ZRTransport` JSON 分块传输。发送接口默认使用当前终端 frame，也可传入明确的
frame，适合 daemon 的多个终端连接。目标必须是存活的终端 frame。

在支持 OSC 777 notify 扩展的终端（如 WezTerm）中，可以直接发送通知，
或显式配置 `zr-notify` 使用终端通知后端：

```elisp
(require 'zr-terminal)
(zr-terminal-notify "Emacs" "任务完成")

(use-package zr-notify
  :custom (zr-notify-function #'zr-notify-terminal))
;; (zr-notify-send "Emacs" "任务完成" :frame terminal-frame)
```

通知文本里的分号和控制字符会替换为空格。终端通知后端仅使用 `:frame` 选项，
不提供通知 ID、超时、优先级或操作按钮；没有有效的目标终端 frame 时跳过通知，
并在每个 Emacs 会话中提示一次。图形界面可将 `zr-notify-function` 设为 nil，
使用平台默认通知后端。
加载库时不会自动更换通知后端。

启用 `zr-notify-mode` 后，调用 `notifications-notify` 的包也会使用
`zr-notify` 后端。Android、Windows 默认使用原生通知；其他平台未设置
`zr-notify-function` 时保留原来的 D-Bus 通知。以 Android、Windows 和
SSH Linux 共用配置为例：

```elisp
(use-package zr-notify
  :config
  (setq zr-notify-function
        (pcase system-type
          ((or 'android 'windows-nt) nil)
          ('gnu/linux
           (if (getenv "TERMUX_VERSION")
               #'zr-termux-notify
             #'zr-notify-terminal))))
  (zr-notify-mode 1))

(with-eval-after-load 'erc
  (add-to-list 'erc-modules 'match)
  (add-to-list 'erc-modules 'notifications)
  (erc-update-modules))
```

ERC 的 `notifications` 模块负责检测提及、私聊及通知过滤。
Android 原生 ERC 已直接调用 Android 通知 API；Windows 和 SSH Linux
通过全局适配转发。关闭 `zr-notify-mode` 即可恢复 `notifications-notify`。
Termux 后端不会转发此接口的操作按钮和 Lisp 回调，因为 Termux 的操作
接口接受 shell 命令，语义不同。

`zr-notify-send` 在 Android 原生后端接受 `:group`，默认按 urgency 使用
`Emacs (normal)` 等分类；显式传入的 group 会保留。Android 会记住分类的
重要性，建议同一个分类使用固定的 urgency。

ERC 可额外启用 [zr-notifications](erc/README.md#notifications)，识别含 `/`
或中文的 RELAYMSG 发送者、过滤自己的回显，并按 channel、nick、网络、正文
或标签配置 `:notify`、`:urgency`、Android `:group` 和 `:replaces-id`。
默认每个会话 buffer 保存自己的通知 ID，Android 分类包含网络、会话及 urgency。

Windows 上执行 `M-x zr-windows-register-emacs-shortcut`，可创建或修复当前用户
开始菜单中的 `Emacs.lnk`，并将通知应用标识设置为 `GNU.Emacs`。已有快捷方式
保留目标和启动参数；也可通过 Lisp 调用传入其他 `.lnk` 路径。

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

Makefile 自动发现根目录、`org/`、`erc/`、`gnus/` 下的业务文件和对应测试，
并将 `test/` 加入测试加载路径，供各测试复用公共辅助宏。
跨模块加载与生命周期检查位于 `test/zr-module-loading-test.el`。
集成测试使用临时目录和本机服务；涉及 Org-srs 的测试在未安装该包时跳过。
