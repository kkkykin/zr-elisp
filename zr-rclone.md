# zr-rclone

通过 rclone RC 管理文件、后台任务、挂载和 WebDAV 服务。目录界面使用
`dired-x` 的 Virtual Dired，文件浏览和操作不经过 TRAMP；需要编辑文件时，
再显式转交给 `zr-tramp-webdav`。

## 开始使用

    (require 'zr-rclone)
    (global-set-key (kbd "C-c r") #'zr-rclone)

执行 `M-x zr-rclone` 打开面板：

- `S` 启动由 Emacs 管理的本机 rcd，默认地址为 `127.0.0.1:5572`。
- `c` 连接已有的本机或远程 RC 服务。
- `a` 设置此次会话的 RC 账号和密码，然后 `r` 重新连接。
- `RET` 返回目录浏览，目录 buffer 中按 `?` 再次打开面板。
- `J` 切换连接；每个连接保留独立的目录 buffer、任务和服务映射。

HTTP 是默认传输；面板中的 `e` 可以切换到 `rclone rc`。
仅连接远程服务时，HTTP 传输不要求 Emacs 所在机器安装 rclone。

    (setq zr-rclone-program "/path/to/rclone"
          zr-rclone-transport 'http
          zr-rclone-url "https://nas.example.org/rclone/"
          zr-rclone-config-file "/path/on/rcd/machine/rclone.conf")

`zr-rclone-config-file` 用于新建连接。面板的 `f` 可以修改当前连接的值。
它供本机 rcd 启动和 `core/command` 子进程使用，不会更改已经运行的
rcd 的配置文件。

已有 RC 服务的密码也可以通过 auth-source 提供，例如：

    machine nas.example.org port 443 login alice password YOUR_PASSWORD

本机启动的服务使用独立凭据。在有 `/dev/urandom` 的系统上自动生成密码，
其他系统通过 minibuffer 输入。凭据不写入历史。CLI 传输的 RC 登录密码
通过进程环境传递；请求参数仍使用 `--json` 命令参数。

## 路径与执行位置

两个 buffer-local 变量分别保存当前目录和目标目录：

- `zr-rclone-current-path`：例如 `drive:music/live`，nil 表示服务器根目录列表。
- `zr-rclone-target-path`：例如 `backup:music`。

两个路径均属于**当前 rcd 所在机器**。`/srv/files` 是服务器的本地目录，
`drive:` 使用服务器的 rclone 配置。复制和同步的两端由同一个 rcd 访问。
`cd` 只改变 Emacs 会话状态，不改变 rcd 的进程工作目录。

路径输入支持 RC 补全、历史、相对路径及 `..`，不会调用 TRAMP。
支持命名 remote、连接字符串、Unix 绝对路径、Windows 盘符和 UNC 路径。
`remote:path` 与 `remote:/path` 保持区别。

连接默认按远程文件系统处理；用 `C-u M-x zr-rclone-connect`，或面板的
`L`，标记它与 Emacs 共享文件系统。本机启动的 rcd 自动标记为本机。
这个标记决定 mount 的挂载点是否使用本地目录补全；远程挂载点只读字符串。
localhost 地址也可能是隧道，因此不会仅凭 URL 推断文件系统位置。

## Virtual Dired

| 按键 | 行为 |
| --- | --- |
| `RET` / `^` | 进入目录 / 返回上级 |
| `c` / `T` | 设置当前路径 / 目标路径 |
| `m` / `u` / `U` / `t` | 标记 / 取消 / 取消全部 / 反向标记 |
| `% m` / `* /` | 正则标记 / 标记目录 |
| `g` | 通过 RC 刷新，保留仍存在条目的标记和当前位置 |
| `s` | 按名称、大小、修改时间切换排序 |
| `(` / `k` | 隐藏详情 / 从当前显示中移除条目 |
| `C` / `R` | 复制 / 移动或改名 |
| `d` / `x` | 标记删除 / 执行已标记的删除 |
| `D` / `+` | 删除当前选择 / 创建目录 |
| `P` | 播放标记文件，没有标记时播放当前文件 |
| `W` | 通过 WebDAV 打开条目；带前缀时打开当前目录 |
| `j` / `!` / `?` | 任务列表 / 临时命令 / Transient 面板 |

单条目的 `C`、`R` 接受完整目标文件名；目标以 `/` 结束时表示目标目录。
多条目操作使用目标目录变量，并保留每个条目的名称。复制或移动目录时，
目录本身的名称也会保留。目录同步则同步当前目录与目标目录的**内容**。

原始 `lsjson` 条目随每行保存，操作不依赖显示文本解析。名称中的换行、
制表符和反斜线只在显示时转义。权限和属主列是展示用的合成值。
面板的 `l` 可以查看 JSON 列表，带前缀时递归列目录。

这是 Dired 的专用子集：不提供 Wdired、压缩、shell 文件操作、子目录插入
或文件系统通知。未适配的 Dired 文件操作没有绑定到这个界面。
它运行 `zr-rclone-dired-mode-hook`，不运行普通 `dired-mode-hook`。

目录查询和补全是有超时、可用 `C-g` 中断的短请求；复制、同步等操作
提交为后台 RC 任务。

## 同步与后台任务

面板的 `-n` 控制原生文件操作的 dry-run；`s` 同步当前路径到目标路径。
`b` 执行日常 bisync，`B` 显式初始化或 resync，不会自动用 resync 修复失败。
bisync 的路径顺序和工作目录应保持稳定。

`-o` 编辑每次文件操作的配置和过滤条件，例如：

    {"_config":{"Transfers":4},"_filter":{"IncludeRule":["*.mkv"]}}

DryRun 由面板开关决定。在 `v` 子面板用 `-b` 编辑 bisync 参数，例如：

    {"workdir":"/srv/rclone/bisync-state","conflictResolve":"newer"}

配置中的文件路径同样属于服务器。设置只作用于当前操作，不调用
`options/set` 修改服务器全局配置。

在任务 buffer 中：

- `g` 刷新状态。
- `RET` 查看保存下来的输出和错误。
- `k` 取消当前任务。

原生任务显示传输统计。临时 CLI 子进程的输出在完成后取得。
已取得的结果保留在 Emacs；断开期间服务端可能清理已完成任务，
未取得的结果不能保证恢复。重连会识别服务器重启，避免混用旧任务 ID。

关闭目录 buffer 或退出面板不停止服务器任务。`d` 断开连接并停止轮询；
`Q` 只停止由此连接启动的本机 rcd，包含它的任务、挂载和 WebDAV 服务。

## 临时命令与任意 RC 请求

面板或目录 buffer 的 `!` 独立调用 `core/command`，例如：

    lsjson "drive:music/live"
    copy "drive:music" "backup:music" --dry-run

支持命令名和路径补全、命令历史、单双引号与反斜线引用。输入是 rclone
参数，不执行 shell 展开、管道或重定向。这个入口适用于非交互式命令。
路径应显式填写；它不继承面板的当前目录、dry-run 或过滤参数。
连接配置中的 config 文件会显式传给子进程，手输的 `--config` 优先。

`:` 可从服务器公布的接口中选择任意 JSON RC 请求。输入 `_async: true`
时把结果纳入任务列表。程序启动时使用 `rc/list` 探测接口，缺少的接口
会给出明确错误。

## mount、WebDAV 和播放

面板的 `m`、`u`、`M` 分别挂载、卸载和列出挂载；
在 `v` 子面板用 `-m` 编辑参数，例如：

    {"vfsOpt":{"CacheMode":"writes","ReadOnly":true}}

实际挂载发生在 rcd 所在机器，需由该机器提供 FUSE 或 WinFsp。

`w` 将当前路径通过 `serve/start` 导出为 WebDAV。本机会选择空闲端口；
远程服务分别输入监听地址和 **Emacs 能访问的 URL**，以适应隧道和反向代理。
`W` 停止选中的 WebDAV 服务。在 `v` 子面板用 `v` 列出服务，
`-w` 编辑额外服务参数。
例如 `{"vfsOpt":{"CacheMode":"writes"}}` 可启用写缓存。

已有 WebDAV 服务可以用 `U` 将其 URL 映射到当前路径。
直接配置的 WebDAV 后端也可自动发现 URL 与用户名；认证由 auth-source
或已有 WebDAV 包处理，不把 rclone 的 obscured 密码当作明文密码。
alias、crypt 等包装后端以及 SharePoint 认证建议由 rclone 导出 WebDAV。

`o` 用 `zr-tramp-webdav` 打开当前目录。生成的服务凭据只用于对应
origin、路径根和用户，并保留已有的 WebDAV 额外请求头配置。

`P` 按目录 buffer 中的顺序将标记文件 URL 组成 M3U，通过 stdin 交给 mpv。
媒体内容由 mpv 直接读取，不经过 Emacs。Basic 认证通过私有临时配置文件
传给 mpv，不放进播放 URL 或 argv，进程结束时清理文件。

`C-u P` 改用 RC 端口上的 HTTP 对象服务，要求 rcd 已启用 `--rc-serve`：

    (setq zr-rclone-rcd-arguments '("--rc-serve"))

`--rc-serve` 提供 HTTP 文件读取，不能替代 WebDAV。播放要求选择文件；
可以先进入目录再标记需要播放的条目。

## 验证

    make check-parens FILE='zr-rclone.el test/zr-rclone-test.el'
    make byte-compile FILE=zr-rclone.el
    make test

有 rclone 时，测试会启动隔离的认证 rcd，使用临时配置和数据。
可以用 `RCLONE_TEST_PROGRAM=/path/to/rclone make test` 指定测试程序。
未安装 rclone 时仍运行路径、Dired、超时和播放进程等测试，
需要 rclone 的集成测试会跳过。实现已使用 rclone v1.75.1 验证。
