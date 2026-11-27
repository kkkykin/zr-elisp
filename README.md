# zr-elisp

一组独立的 Emacs Lisp 工具包，需要 Emacs 31.1 及以上。
各模块按需加载，通过命令、hook 或 minor mode 启用功能。

## 目录

| 代码目录 | 内容 | 测试目录 |
| --- | --- | --- |
| 仓库根目录 | 编辑、文档阅读、词典、进程、网络、媒体和平台工具 | `test/` |
| [`org/`](org/README.md) | Org 编辑、Babel、Tangle、导出、链接、协议和 Org-srs | `org/test/` |
| [`erc/`](erc/README.md) | ERC 消息显示、补全、链接、回复和文件上传 | `erc/test/` |
| [`gnus/`](gnus/README.md) | Gnus 后端和本地 EPUB 阅读 | `gnus/test/` |
| [`scripts/`](scripts/) | 按模块存放的 PowerShell 等辅助脚本 | 随对应模块测试 |

## 加载

将仓库根目录加入 `load-path`，使用 Org、ERC 或 Gnus 模块时加入对应目录：

```elisp
(add-to-list 'load-path "/path/to/zr-elisp")
(add-to-list 'load-path "/path/to/zr-elisp/org")
(add-to-list 'load-path "/path/to/zr-elisp/erc")
(add-to-list 'load-path "/path/to/zr-elisp/gnus")

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

`M-x zr-window-follow-columns` 按 `fill-column` 将当前 buffer 分栏，并启用
Follow 连续显示。栏数按实际可显示的字符数计算，包含边缘、滚动条等占用的
空间；窗口较窄时保留单栏。已有分栏和其他 buffer 的窗口会保留，重复调用
不再拆分现有栏。`C-u M-x zr-window-follow-columns` 先占满 frame，再重新
计算栏数。无效的 `fill-column` 或分栏失败不会改变原有窗口布局。

`zr-window-arrange-follow-columns` 提供同样的布局操作，返回分栏窗口列表，
供其他模块复用；Follow 状态由调用方管理。

`zr-doc-view` 在 DocView 窗口中并排显示连续页，复用 DocView 的转换器、
PNG/SVG 缓存、文字搜索和书签。通过 `M-x zr-doc-view-open` 打开文档，
或在已有 DocView buffer 中执行 `M-x zr-doc-view-mode`：

```elisp
(use-package zr-doc-view
  :commands (zr-doc-view-open zr-doc-view-mode)
  :custom
  (zr-doc-view-visible-pages 2)
  (zr-doc-view-cover-single nil)
  (zr-doc-view-landscape-single t))
```

默认显示最多两页，各页按窗口宽高等比适配，具有相同显示高度。当前原始页码
是显示起点：N=3 时，`[2,3,4]` 按前进方向键变为 `[3,4,5]`，按
`SPC` 变为 `[5,6,7]`。右向左布局反转页面摆放和左右方向键，`SPC/DEL`
始终按文件原始顺序翻屏。封面或横页独占时截断显示范围，末尾显示剩余页面。
转换过程中，若仍无法确定翻屏目标，翻屏命令会提示等待页图就绪。方向键仍可逐页移动。

| 按键 | 操作 |
| --- | --- |
| `←/→` | 按阅读方向移动一个原始页 |
| `SPC/DEL`、`PageDown/PageUp` | 前后移动一个显示范围 |
| `1/2/v` | 单页、双页或指定最大页数 |
| `d` | 切换左右阅读方向 |
| `C/L` | 切换封面、横页独占 |
| `g` | 用 DocView 重新转换文档 |

`+/−/0`、`W/H/P` 继续使用 DocView 的缩放和窗口适配命令。
切换页数、阅读方向和窗口尺寸保留当前原始页码；同一 buffer 的布局选项共享，
每个窗口的页码和缩放独立。DocView 裁剪临时使用单页显示，清除裁剪后恢复多页。
转换沿用 DocView 默认流程，会继续转换全书。图形 Emacs 和转换器依赖也沿用
DocView 的配置；加载新包不会自动启用模式，关闭模式恢复原生显示及 buffer 设置。

其他阅读入口可调用 `(zr-doc-view-open file page)` 获取文档 buffer，
用 `zr-doc-view-goto-page` 定位，或用 `zr-doc-view-current-pages` 获取窗口
请求的原始页码范围。`zr-doc-view-page-count` 返回当前文档转换完成后的总页数，
转换未完成时返回 `nil`。启用模式前可设置两个 buffer-local hook：
`zr-doc-view-page-change-functions` 接收 `(window page)`，
`zr-doc-view-after-display-functions` 接收 `(window pages)`。后者只在完整显示
成功后触发，页码始终按文件顺序排列；加载失败及缩放、方向切换等重绘不会重复
报告。这些接口可供 nnopds 等入口同步页文章和已读标记。

`zr-shadowfile` 修正内置 shadowfile 对 Windows 盘符、cluster 和 regexp
文件组的路径处理，通过 TRAMP 维护跨机器的文件副本：

```elisp
(use-package zr-shadowfile
  :config (zr-shadowfile-mode 1))
```

用此模式代替 `shadow-initialize`，继续使用 `shadow-define-literal-group`、
`shadow-define-regexp-group`、`shadow-define-cluster` 和 `shadow-cancel`。
定义 literal 文件组时，逐个输入站点及该站点的文件路径，例如本机的
`C:/Users/user/notes.txt` 与远端的 `/home/user/notes.txt`；`~/` 在所选站点
展开。Regexp 文件组要求各站点的文件名相同，Windows 与 Linux 的不同路径
应使用 literal 文件组。

保存文件后记录待复制队列，执行 `C-x 4 s` 或 `shadow-copy-files` 更新副本。
默认退出 Emacs 时也询问复制；将 `zr-shadowfile-copy-on-exit` 设为 nil 可关闭
退出复制。确认行为沿用 `shadow-noquery`，配置和队列分别保存在
`shadow-info-file`、`shadow-todo-file`。复制失败保留队列，供下次重试。
TRAMP 连接须能独立访问目标，目标目录须已存在；副本更新会覆盖目标文件，
不合并两端的并行修改。加载库不会自动启用，关闭模式撤销替换、hook 和快捷键。

HTTP 客户端请求统一使用 `zr-http`，需要本机安装 curl。全局默认、包级
`*-http-options`、单次请求参数按顺序覆盖，显式 nil 也会覆盖默认值：

```elisp
(setq zr-http-default-options
      '(:timeout 30 :proxy inherit
        :headers (("User-Agent" . "zr-elisp"))))
;; inherit 使用 curl 的代理环境变量；nil 直连；明确代理忽略 no_proxy。
(setq zr-mpv-http-options '(:timeout 10))
(setq zr-erc-upload-http-options
      '(:timeout 120 :proxy "http://127.0.0.1:7890"))
(setq zr-tramp-webdav-http-options
      (lambda (file)
        (when (string-match-p "example.org" file)
          '(:curl-arguments ("--ipv4")))))

(zr-http-request-sync "https://example.org/api"
                      :method "POST"
                      :headers '(("Content-Type" . "application/json"))
                      :body (encode-coding-string (json-serialize '(:query "中文"))
                                                  'utf-8 t))
```

包级配置包括 `zr-mpv-http-options`、`zr-rclone-http-options`、
`zr-tramp-rcrc-http-options`、`zr-tramp-webdav-http-options`、
`zr-ffmpeg-http-options`、`zr-erc-link-http-options`、
`zr-erc-upload-http-options` 和 `nnopds-http-options`。
Headers 按名称忽略大小写合并；字段值 nil 删除继承字段，`:headers nil`
清空继承的 headers；`:curl-arguments` 则整体覆盖。curl 程序路径用
`:curl-program` 配置。额外参数用于代理、证书、协议版本等传输设置；
请求方法、body、上传和输出使用结构化选项。

`zr-http-request` 返回可用 `zr-http-cancel` 取消的请求对象，`:callback`
接收 `(response error)`，只调用一次。响应包含 `:status`、`:headers`、
`:url` 和字节串 `:body`；使用 `:output-file` 时返回 `:file`，下载直接
写入临时文件，完整收到响应后替换目标，传输失败或取消保留原目标。
HTTP 4xx/5xx 也作为响应返回，由业务代码判断；重定向及认证来源由各包
处理。`:upload-file` 支持文件请求体，`:form` 支持普通字段和文件字段，
`:max-bytes` 限制实际接收的响应体大小。详细选项见 `zr-http-default-options`。
加载库不会改变 Emacs 的 URL 配置或进程环境。本轮只实现 curl 后端。

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

Windows 每个 frame 只保留一条活动托盘通知，发送新通知前会关闭旧通知。
正数 `:timeout` 会在指定毫秒数后关闭通知；超时、替换和删除 frame 时的
关闭操作都使用创建通知的 frame。Windows 原生后端不支持操作按钮和 Lisp 回调。

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

make test TEST_FILE='$(wildcard org/test/*-test.el)'
make check-parens byte-compile FILE='$(wildcard org/*.el)'
```

Makefile 自动发现根目录、`org/`、`erc/`、`gnus/` 下的业务文件和对应测试，
并将 `test/` 加入测试加载路径，供各测试复用公共辅助宏。
跨模块加载与生命周期检查位于 `test/zr-module-loading-test.el`。
集成测试使用临时目录和本机服务；涉及 Org-srs 的测试在未安装该包时跳过。
