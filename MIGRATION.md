# user-lisp 功能迁移

验收基线为 Emacs 30.2。原 `../emacs.d/user-lisp` 文件保留作来源参考；新库不加载旧模块，不提供旧名字兼容层。`../emacs.d/init.el` 通过功能对应的 `use-package` 接入。

## 保留与拆分

| 原模块 | 新库 | 保留功能及主要入口 |
| --- | --- | --- |
| init-misc | zr-dired | `zr-dired-duplicate`、`zr-dired-random-file`、目标目录管理、`zr-dired-pandoc`、`zr-dired-open-externally` |
| init-misc | zr-bookmark | `zr-bookmark-shared-mode`，共享前缀、本地与共享文件分离 |
| init-misc | zr-window、zr-speedbar | Follow 分栏、Tab-line 分组过滤、Speedbar 比较与临时显示所有类型 |
| init-misc | zr-process-menu | 缓冲区级过滤、分组、隐藏行、终止选中进程 |
| init-prog | zr-vc | 文件名复制、提交模板与 server 提交辅助；快捷键在 init.el |
| init-comint | zr-comint | `zr-comint-history-mode`、`zr-comint-shell-setup` |
| init-esh | zr-eshell | 书签变量、EDITOR、输出格式化、Git 颜色、解释器、历史展开 |
| init-pcmpl | zr-pcmpl | `zr-pcmpl-mode` 注册 7z/7zz、ADB、fd 补全 |
| init-org | zr-org | 列表速度命令、条目剪切、表格查询、编辑模板、`org-dblock-write:zr-file-finder` |
| init-org | zr-org-babel | 块/调用执行、展开、结果图片、语言补全、JSON 格式化、Bat 变量赋值；AHK/Bat 默认头参数在 init.el |
| init-org | zr-org-tangle | `zr-org-tangle-path`、CUSTOM_ID、`zr-org-tangle-detangle` |
| init-org | zr-org-link | `dict:` 链接及导出，调用现有 zr-wezterm 打开链接 |
| init-org | zr-org-export | Pandoc OPTIONS 与 LaTeX 图片路径修正 |
| init-org | zr-org-protocol | 显式 Windows 协议注册、Netscape Cookie 导入 |
| init-viper、init-org | zr-viper | Ex 扩展、临时行号、Wdired/Org 编辑保存；使用 Org 功能时才加载相应库 |
| init-net | zr-eww | 配置驱动的 URL 重写、认证、阅读模式、文本源码显示 |
| init-misc、init-android | zr-notify、zr-termux | 通知与预约参数适配，Termux API 通知/Toast、状态查询及已有 TRAMP 连接配置 |
| init-winnt | zr-windows | UWP 回环、Shell 切换、编码、自解压归档、IME 控制 |
| init-android、init-misc | zr-android | 屏幕、软键盘、修饰栏、ADB 与应用操作 |
| init-misc | zr-data、zr-elisp | JSON 读取合并、SOPS、UUID、密码、Emacs 源码 URL |

来源文件中的版权、作者声明保留在对应库头部。Dired 递增复制参考 [James Dyer](https://www.emacs.dyerdwelling.family/emacs/20231013153639-emacs--more-flexible-duplicate-thing-function/)；Org 列表速度命令参考 [Sacha Chua](https://sachachua.com/blog/2025/03/org-mode-cutting-the-current-list-item-including-nested-lists-with-a-speed-command/)。

## 移除与个人配置

不迁移 Neovim 后端、sq/私人脚本桥接、Rish 及包装命令、提权保存、GPG 终端、Windows Terminal 聚焦、OneDrive、输入法切换、SSH/Dropbear 管理、Keystore 下载、文件时间/PID 工具。Termux 只保留 Wi-Fi 状态和扫描查询，不包含位置推断或自动连接。

旧 RSS、SQL 扩展、Rclone 桥接以及未列入清单的 init-linux、init-dir-vc 等功能不接入；内置 SQL 等无关配置保留，Rclone 使用已有 zr-rclone。旧 init-emms 可选加载入口已清除。

路径、环境、站点规则、快捷键、菜单和提醒日程在 init.el。APK 签名仍使用 `zr-emacs-keystore-file`，不下载密钥。Viper 设置 `viper-custom-file-name` 为 nil，初始化后接入 zr-viper。Eshell 可视命令使用原生 em-term。

已有 Org 文档或私人脚本中的旧调用需改成表中的新入口；动态块名字由 `file-finder` 改为 `zr-file-finder`，不会自动批量改写用户文档。

## 最小启用示例

将仓库根目录加入 `load-path` 后，按需选择：

```elisp
(use-package zr-bookmark
  :demand t
  :custom (zr-bookmark-shared-file "~/shared/bookmarks")
  :config (zr-bookmark-shared-mode 1))

(use-package zr-comint
  :hook ((comint-mode . zr-comint-history-mode)
         (shell-mode . zr-comint-shell-setup)))
(use-package zr-eshell :hook (eshell-mode . zr-eshell-mode))
(use-package zr-dired :commands (zr-dired-duplicate zr-dired-pandoc))
(use-package zr-org :hook (org-mode . zr-org-mode))
(use-package zr-org-babel :hook (org-mode . zr-org-babel-mode))
(use-package zr-org-tangle :commands zr-org-tangle-detangle)
(use-package zr-pcmpl :demand t :config (zr-pcmpl-mode 1))
```

全局或局部 minor mode 用参数 `-1` 关闭。只加载库不启用功能、不执行平台命令。Hook 函数只在配置加入后运行。

旧 `zn/has-public-ipv6-addr-p` 改用独立模块 `zr-network`：

```elisp
(require 'zr-network)
(zr-network-has-public-ipv6-addr-p)
;; 只检查指定 Wi-Fi 接口，名称按本机实际情况填写。
(zr-network-has-public-ipv6-addr-p
 (lambda (name) (string= name "wlan0")))
;; 显式忽略 rmnet_data 系列蜂窝接口。
(zr-network-has-public-ipv6-addr-p
 (lambda (name) (not (string-prefix-p "rmnet_data" name))))
```

这里只检查本机接口上配置的地址，不判断默认路由、接口状态或实际 IPv6 联网能力。
地址分类采用 `2000::/3` 及 IANA 标记为全球可达的特殊分配，排除文档等特殊范围；
Teredo、6to4 保守返回 nil。范围表固定在库内，不会联网查询 IANA。
接口过滤为空时返回 nil，不回退到全部接口。Termux 标准 Wi-Fi 查询没有 `ipv6` 字段，
因此不自动调用 Termux API 或据此推断当前出口。

共享书签普通保存会写两个独立文件，包括空列表。显式另存为保留 Emacs 的完整导出语义。任一写入失败都报错且不清除修改计数；两份文件不是跨文件原子事务，修复失败原因后可重试保存。Comint 尊重已有历史文件，进程终止前、缓冲区关闭/改模式、Emacs 正常退出时保存；强制杀死 Emacs 不保证保存。

Detangle 完成全部合并后才修改源码，保留缓冲区中的未保存修改供审核，冲突使用 smerge-mode。Babel 执行遵循 `org-confirm-babel-evaluate`。Cookie 导入要求 Netscape 格式和合法主机文件名，导入文件权限为 0600。

## 验证

```sh
make check-parens
make byte-compile
make test
make check-parens FILE=../emacs.d/init.el
make clean
```

迁移测试按模块放在 `test/zr-<模块>-test.el`，例如 `zr-bookmark-test.el`、`zr-comint-test.el`、`zr-org-babel-test.el` 和 `zr-org-tangle-test.el`。公共临时目录与 Org 缓冲区辅助宏放在 `test/zr-test-helpers.el`；跨模块加载与生命周期检查放在 `test/zr-module-loading-test.el`。

测试覆盖临时目录中的书签读写及失败状态、Comint 历史/退出/sentinel、实际 Eshell 事件展开、Dired 操作、Org 执行/回写、JSON 合并、通知参数转换、补全参数与平台边界。独立子 Emacs 测试逐库加载且拦截外部进程、网络、写文件、环境修改和定时器；另测反向加载、重复启用和关闭。

可以单独运行一个模块的测试：

```sh
make test TEST_FILE=test/zr-bookmark-test.el
```

Makefile 会将 `test/` 加入测试加载路径，供各模块复用公共辅助宏。

init.el 只做括号、读取、迁移模块依赖与符号静态检查，不启动整个个人配置或服务。Linux 自动测试不能替代以下实机验收：

| 平台 | 待实机验证 |
| --- | --- |
| Windows | UWP 授权、注册表协议与 emacsclient 路径、cmdproxy 编码、IME 焦点事件、自解压归档、通知关闭、Windows IPC |
| Android | 图形帧软键盘/修饰栏、屏幕切换、应用启动、系统通知；Termux API 权限、Wi-Fi 状态与扫描、Toast/通知替换及超时、已有 TRAMP 连接 |

上述平台接口在 Linux 使用替身测试；真实外部程序失败不得被作为正常输出返回。既有全仓库测试还包含临时本地 WebDAV/媒体集成测试，不访问个人服务。

本次验证：Emacs 30.2 下括号检查通过、字节编译无警告，270 项 ERT 中 268 项通过、2 项 Windows IPC 测试因平台跳过，无失败。init.el 的 28 个 zr-* use-package 声明静态展开成功，165 个 zr-* 符号引用可静态对应到定义或生成入口；未执行完整个人初始化。
