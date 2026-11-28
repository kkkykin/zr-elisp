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

`zr-shadowfile` 根据独立规则维护文件副本。目录规则保留相对路径，文件规则
固定映射一个文件，允许目标文件名不同。路径使用标准 Emacs 文件名，支持
Windows 盘符、UNC 路径以及 TRAMP 远程路径。例如将 Windows 的 `~/org/`
复制到 Koofr，忽略各层级的 `.git`：

```elisp
(require 'zr-tramp-webdav)
(require 'zr-shadowfile)
(setq zr-shadowfile-rules
      '((:source "~/org/"
         :destination "/webdavs:xxxx@app.koofr.net:/dav/Koofr/org/"
         :exclude "\\(?:\\`\\|/\\)\\.git\\(?:/\\|\\'\\)")))
(zr-shadowfile-mode 1)
```

规则根据源路径末尾的目录分隔符区分类型：`~/org/` 表示目录，
`~/notes.org` 表示文件，无需额外指定类型，也不要求配置时源路径已经存在。
目录规则的目标按目录处理；单文件规则的源和目标都填写完整文件名，
可与目录规则混用：

```elisp
(add-to-list 'zr-shadowfile-rules
             '(:source "~/notes.org"
               :destination "/webdavs:xxxx@app.koofr.net:/dav/Koofr/notes-backup.org"))
```

首次执行 `M-x zr-shadowfile-queue-directory RET ~/org/ RET`，再用
`C-x 4 s` 或 `zr-shadowfile-copy-files` 复制；`C-u C-x 4 s` 执行所有待复制项，
不再询问。随后在 Emacs 中保存目录内的文件会自动入队。规则可选的 `:include`
匹配文件相对路径，例如 `"\\.org\\'"`；`:exclude` 匹配相对路径及其父目录，
因此排除目录后，该规则也会排除其后代文件；其他规则仍可选取其中的文件。
文件规则的过滤匹配源文件名。多个规则可映射到不同目标，各自应用过滤条件。

默认手动执行同步复制，规则中的 `:async` 可单独控制各个目标：

| `:async` | 行为 |
| --- | --- |
| 省略或 `nil` | 保存后入队，手动执行同步复制 |
| `t` | 保存后入队，手动执行后台复制 |
| 正数，可为小数 | 最后一次成功保存后等待指定秒数，自动复制 |
| `0` | 成功保存后立即启动自动复制 |

例如在规则中加 `:async 3`，会在停止保存 3 秒后同步；等待期间再次保存会
重新计时。自动复制不逐次询问，只处理已到期的任务；手动复制和退出复制会
跳过剩余延迟。手动入队已有文件仍需执行复制命令。后台传输支持本地与 WebDAV
之间以及 WebDAV 之间的复制，其他路径使用同步文件接口。

`M-x zr-shadowfile-wait` 可等待当前批次，等待时按 `C-g` 会停止批次并保留
未完成任务。后台上传使用已保存字节的快照，传输期间再次保存会保留新任务，
数值规则的新版本继续按保存时间延迟。程序调用 `zr-shadowfile-copy-files`
返回批次，可传给 `zr-shadowfile-wait` 获取成功复制数。

规则可设置 `:vc-only t`，仅将 Emacs VC 管理的文件入队。例如 Git 中已跟踪
或已执行 `git add` 的文件可同步，未跟踪和被忽略的文件会跳过。未设置或设为
`nil` 时不限制版本控制状态；此选项可与 `:include`、`:exclude` 组合，也适用于
单文件规则。VC 状态在入队时重新检查，外部执行 `git add` 后再次保存或入队即可。

只选一个文件时，用 `M-x zr-shadowfile-queue-file` 按规则入队；加前缀参数
`C-u` 可指定一次性目标文件名，无需配置规则。随后用 `C-x 4 s` 执行复制。
保存已配置的源文件也会自动入队，文件规则和目录规则共享去重、持久化与重试。

复制会创建目标父目录，并保留磁盘上已保存的字节；失败或跳过的任务自动保存
到本机的 `zr-shadowfile-pending-file`，执行中的任务也保留到成功确认。
待办保存具体路径、`:async` 设置和延迟截止时间，下次启用模式时恢复剩余倒计时。
自动复制失败后留在队列中，可手动重试；再次保存会重新安排复制。
已入队任务保留解析后的路径和 `:async` 设置；再次保存或入队时，按匹配规则
更新该任务的 `:async` 设置。规则改动不会改写既有任务的目标路径；
用 `zr-shadowfile-cancel` 选择取消，加前缀参数可取消全部任务及其计时器。
规则放在个人配置或通过 Custom 保存。
源文件移动或删除后，复制时会自动清理旧路径的待复制任务；移动后的文件
再次保存或手动入队即可按当前规则复制。

默认复制前询问，`zr-shadowfile-noquery` 可关闭询问；默认退出 Emacs 时也
询问复制，并等待后台批次。`zr-shadowfile-exit-timeout` 限制退出时等待后台复制的总时间，
默认 60 秒；失败、跳过或超时后仍有任务，会再询问是否退出，拒绝则继续使用
Emacs，`C-g` 可中止等待和退出。`zr-shadowfile-copy-on-exit` 设为 nil 时，
退出直接停止后台复制并保存待办。直接调用 `kill-emacs` 也会停止并保存任务，
复制确认与等待通过 `kill-emacs-query-functions` 在正常退出前完成。
加载库不自动启用，关闭模式停止后台复制并撤销 hook 和快捷键。
扫描跳过符号链接，源文件删除不会删除
目标副本，复制覆盖目标文件。Koofr 用户名和 WebDAV 凭据由个人配置及
`auth-source` 提供。后台复制使用已配置或当前会话已输入的凭据，不在完成回调中
询问密码；可先配置 `auth-source`，或同步访问目标一次取得会话凭据。

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
