# Gnus 工具

需要 Emacs 31.1 及以上。将本目录加入 `load-path`，按需加载。

## nnopds

`nnopds` 将 OPDS 2 目录作为 Gnus server，每本书是一个 group，正文资源
是 articles。首次进入 EPUB 时下载整本，章节、图片及脚注处理复用 `nnepub`。
漫画通过 Divina manifest 按页取图，一张原始图片对应一篇 article。
HTTP 请求需要 `curl`；EPUB 需要 libxml 和 `7zz`/`7z`，漫画阅读需要支持
相应图片格式的图形 Emacs。

更新已编译的 nnopds 时，先用 `make clean` 清理旧字节码，再重新编译这些
模块；它们共享的结构体访问器会在编译时内联：

```sh
make byte-compile FILE='gnus/nnopds.el gnus/nnopds-browse.el gnus/nnopds-comic.el gnus/nnopds-progress.el gnus/nnopds-koreader.el'
```

```elisp
(add-to-list 'load-path "/path/to/zr-elisp/gnus")
(require 'nnopds)

(add-to-list 'gnus-secondary-select-methods
             '(nnopds "komga"
                      (nnopds-url "https://komga.example/opds/v2/catalog")
                      (nnopds-headers (("X-API-Key" . "YOUR_API_KEY")))
                      (nnopds-koreader-url "https://komga.example/koreader")
                      (nnopds-koreader-user "YOUR_API_KEY")))

(add-to-list 'gnus-secondary-select-methods
             '(nnopds "calibre"
                      (nnopds-url "https://calibre.example/opds")
                      (nnopds-user "reader")
                      (nnopds-koreader-url "https://calibre.example/kosync")
                      (nnopds-koreader-user "reader")))
```

HTTP 认证可以配置 server 变量 `nnopds-user`，密码从 `auth-source` 获取，
匹配目录 URL 的主机和端口；也可以设置 `nnopds-password`。自定义请求头使用
`nnopds-headers`。请求和重定向仅向配置的服务器 origin 发送这些凭据。
`nnopds-auth-method` 默认 `basic`；calibre 在未启用 HTTPS 时默认使用 Digest，
应显式配置 `(nnopds-auth-method digest)`。它只控制取书认证，同步认证独立。
calibre 在原有 `/opds` 路径按 `Accept: application/opds+json` 返回 OPDS 2，
后端已发送此请求头。反向代理有路径前缀时，需要在两个 URL 中显式写出。

在 Gnus group buffer 按 `^` 进入 server buffer，选择服务器并用 `RET` 浏览；
也可以用 `B nnopds RET 目录URL RET` 浏览，或用 `M-x nnopds-browse` 选择
已打开的服务器。浏览保留 OPDS 的 `navigation`、嵌套 `groups` 和 facets，
只加载当前页，不递归扫描。目录和分页链接都按 `RET` 进入，`b`/`^` 返回，
`n`/`p` 移动，`g` 刷新当前页，`q` 退出。书籍用 `u` 订阅，`RET` 进入章节
列表，`SPC` 阅读。可以直接将某个目录或书目列表的 URL 配为 `nnopds-url`。

在目录浏览器按 `s`（`M-x nnopds-browse-search`）输入关键词进行服务端搜索。
后端自动读取当前页的 OPDS 2 `rel=search` URI 模板，当前页未提供时使用根目录
的模板。支持 `{query}`、`{?query}`、`{&query}`，关键词按 UTF-8 编码，模板中
未填写的可选字段会省略；服务器提供的库名、代理路径和其他参数会保留。
搜索结果沿用目录的分页、订阅和阅读命令，`b` 返回搜索前的页面和光标位置，
`g` 刷新结果。搜索只取书目，不下载 EPUB 或漫画图片。

[Komga](https://github.com/gotson/komga/blob/master/komga/src/main/kotlin/org/gotson/komga/interfaces/api/opds/v2/Opds2Controller.kt)
使用 `search{?query}`，搜索结果按系列、书籍、集合和阅读列表分组；当前每类
最多返回 20 条，未提供搜索结果的分页链接。
[calibre](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/srv/opds.py)
在 `/opds` 使用路径中的 `{query}`，可直接输入 calibre 搜索表达式，如
`title:"三体" and authors:"刘慈欣"`；服务器启用全文索引后，进入目录中的
“Search book contents” 再按 `s` 可搜索正文。
具体搜索范围和语法由服务器决定，客户端遵循其
[OPDS 2 搜索链接](https://specs.opds.io/opds-2.0#3-search)，无需按服务器配置路径。

书籍始终显示完整章节列表，包括已读章节，并保留 Gnus 的已读标记。
`gnus-large-newsgroup` 不限制书籍章节；目录按服务器提供的分页逐页加载。

首次列出书籍时只取书目，章节数或漫画页数在首次打开后更新。支持直接 EPUB
取书链接以及 `application/divina+json` 漫画 manifest 链接；两者都有时优先
使用漫画流式入口。EPUB 阅读使用 Gnus 原有命令，图片、跨章链接和脚注沿用
`nnepub`。

Komga 的 OPDS 2 目录在 `self` 链接提供漫画 manifest，用户需要页面流式阅读
权限。calibre 9.18 及以上在 `/opds` 的 acquisition 链接提供 CBZ 漫画 manifest；
CBR/CB7 的整包下载链接不会作为流式漫画列出。后端沿 manifest 的 `readingOrder`
读取图片，保留页 URL 的库名、版本等参数，并从原始和 alternate 链接中选择
Emacs 支持的格式。图片请求复用目录认证，包括 Basic、Digest 和 API key。

漫画在 summary 和 article buffer 启用局部 `nnopds-comic-mode`：

| 按键 | 操作 |
| --- | --- |
| `1` / `2` | 单页 / 双页 |
| `c` | 切换封面单页 |
| `r` | 切换左向右 / 右向左 |
| `n` / `SPC` | 下一页或下一跨页 |
| `p` / `DEL` | 上一页或上一跨页 |
| 左右箭头 | 按阅读方向翻页 |
| `j` | 跳到指定原始页码 |
| `g` | 重试当前页的取图失败 |

默认单页，封面独占一跨页，方向使用 manifest 的 `readingProgression`；缺少方向
时使用左向右。`M-x nnopds-comic-set-direction` 可选择 `auto`，恢复跟随书籍方向。
这些设置可在阅读中切换，并按书保存。可配置未读漫画的初始布局：

```elisp
(setq nnopds-comic-layout 'double
      nnopds-comic-cover-single t
      nnopds-comic-direction 'auto)
```

封面单页时按 `[1] [2,3] [4,5] …` 配对，关闭后按 `[1,2] [3,4] …` 配对；
右向左只改变屏幕上的左右摆放，原始图片次序和 article 编号始终保持不变。
切换布局会保留当前原始页，例如第 3 页切换双页后显示 `[2,3]`，切回仍是第 3 页。
横向图片独占一跨页，末尾剩一页也单独显示。图片按窗口宽高等比缩放，双页使用
相同显示高度；调整窗口大小后自动重新排版。calibre 未提供页尺寸时在显示图片后
识别，并记录尺寸以保持后续会话的配对。

打开漫画只取 manifest 和当前图片，列页目录或 Gnus 预取文章不会下载图片。
`nnopds-comic-prefetch-pages` 默认预取后续 4 张图片，设为 0 可关闭预取；
`nnopds-comic-max-requests` 默认限制每本漫画最多 2 个并发请求。
图片以临时文件下载，成功后替换正式缓存，关闭阅读或服务器时取消待处理请求。
已经读取的 manifest 和图片可跨会话、离线复用，缓存保存在同一账号的 `.comic/`
目录中；内存中的解码图片只保留当前显示的一页或两页。

漫画自动保存本地原始页码，重新进入 group 时恢复。完整显示当前阅读单元后才
保存位置，并处理双页的两篇 article 的已读标记；预取、失败请求和布局重绘
不会推进位置，Gnus 的收藏等手动标记保留。漫画目前使用本地位置，
`nnopds-koreader-*`、`nnopds-resume` 和 `nnopds-save-position` 的服务器同步
继续用于 EPUB。

取书请求优先接受 EPUB 媒体类型，也接受通用二进制响应；下载内容按 EPUB
解析，支持将附件标为 `application/octet-stream` 的接口。

目录、EPUB 和漫画缓存保存在 `gnus-cache-directory` 下的 `nnopds/` 子目录，
不同 server 和认证配置分别缓存。打开 Gnus 只读取本地已遇到的书籍索引，
没有缓存时也不联网；首次浏览才请求根目录，进入未缓存的目录或分页时请求
该页。默认重访目录和返回上级均使用缓存。新增书籍或版本更新后，在所在
目录按 `g` 手动刷新；`M-x nnopds-refresh-catalog` 只刷新服务器根目录。
`nnopds-catalog-cache-ttl` 默认为 nil；设为秒数可启用页面定时过期，设为 0
则每次浏览页面都尝试联网刷新，失败时复用旧页。

刷新按分页保存缓存，并使用服务器提供的 ETag/Last-Modified 条件请求，
未变化的页面无需重新下载。页面加载失败时保留当前位置和已缓存的页面，
重新启动也能继续使用。只有浏览过的书籍进入 Gnus 索引，章节数集中缓存，启动
无需逐本读取索引。已下载的 EPUB 可离线阅读；解压内容在关闭 server 时清理，
下载缓存跨会话保留。完整下载通过版本摘要校验后，立即写入正式缓存和摘要索引，
再开始解压和章节索引；即使 Emacs 在后续处理时崩溃，重新打开也会复用下载。
curl 直接写入文件，避免把整个 EPUB 在 Emacs 内存中来回复制；同一次打开只计算
一次完整文件摘要。Messages 显示下载、缓存校验、解压和章节索引阶段及耗时，
便于区分网络等待与本地处理。`nnopds-request-timeout` 限制每个 HTTP 请求。

EPUB 和单书索引使用书籍 ID 的摘要作短文件名，临时文件使用固定短前缀，
避免 Windows 用户目录较深时超出路径长度限制。

Group 身份由书目的稳定 URL 和 `metadata.modified` 确定，书目版本更新会
产生新 group，已遇到的旧版本和 Gnus 标记继续保留。没有 `modified` 的书目作为一个
固定版本缓存；这种服务器需要提供版本变化信号才能自动发现新版。已记录的
版本会校验 EPUB 内容摘要，避免缓存缺失后将不同内容用于旧文章编号。

`nnopds-progress-protocol` 默认是 `koreader`。只有明确配置
`nnopds-koreader-url` 才启用服务器同步。KOReader 的同步认证独立于取书认证：

- Komga 的地址通常是 `/koreader`，`nnopds-koreader-user` 填 API key，
  不需要同步密码；该 API key 的用户需要 KOReader 同步权限。
- calibre 的地址通常是 `/kosync`，`nnopds-koreader-user` 填 Content server
  用户名。密码从同步 URL 对应的 `auth-source` 记录获取，也可显式设置
  `nnopds-koreader-password`；请求发送 UTF-8 密码的 MD5。
- 同步请求头仅发送到配置的同步服务器 origin，取书认证不会随之发送。
  calibre 首次下载前会先登录同步接口，让服务器关联下载文件与原书的哈希。

书籍标识使用 KOReader 的 partial MD5，设备端应选择默认的 Binary 匹配方式。
EPUB 的 CREngine XPointer 按 OPF spine 对应到 Gnus 章节；Komga 的无时间戳
响应和 calibre 的 Unix 时间戳响应均可读取，保存接受两端不同的 HTTP 200
响应格式。

配置同步后，自动恢复和保存章级位置：

- 进入书籍时获取服务器位置，跳到对应章节。
- 实际显示章节后延迟保存，`nnopds-progress-sync-delay` 默认 1 秒。
- 预取文章和查看正文之外的附录脚注不会改变同步位置；退出 group 时完成
  待保存的位置。Gnus 的订阅、已读和收藏标记继续由 Gnus 保存。
- 服务器读取失败、另一个设备位置更靠后或写入返回 `409` 时保留服务器状态。
  用 `M-x nnopds-resume` 重新获取位置；用 `M-x nnopds-save-position` 立即尝试
  保存当前章。两个命令也可在 article buffer 调用。

`nnopds-progress-device-id` 和 `nnopds-progress-device-name` 标识本设备。
设置 `nnopds-progress-sync` 为 nil 可关闭自动恢复和保存。
未配置 KOReader 地址的书库使用 Gnus 本地阅读状态。
本版保存章节起点，尚不保存章内滚动位置；KOReader 的 `percentage` 以章节在
spine 中的序号估算，实际跳转使用 XPointer。KOReader 没有条件写入接口，
写前检查可以保留已发现的更新位置，但不能保证原子冲突检测。

目录、阅读格式和同步协议分别处理。`nnopds-progress-protocol` 当前只支持
`koreader`，配置项和协议读写接口保留，方便后续添加正式的 OPDS 同步协议。
漫画的 Divina 读取和本地布局位于独立的 `nnopds-comic.el`，服务器漫画进度
协议可在现有位置接口上另行适配。

## nnepub

`nnepub` 把一个本地目录作为 Gnus select method，每本 EPUB 是一个 group，
书内资源按 OPF spine 顺序作为 articles。EPUB 2 NCX 和 EPUB 3 导航中的标题
用于章节摘要；spine 外的 XHTML 附录、脚注和导航文档排在正文之后。

需要支持 libxml 的 Emacs，以及 `7zz` 或 `7z`。默认先查找 `7zz`，再查找 `7z`；
可以通过 `nnepub-7z-program` 指定命令名称或完整路径。
EPUB 解析参考 [nov.el](https://depp.brause.cc/nov.el/nov.el)，无需安装 nov 或 esxml。

```elisp
(add-to-list 'load-path "/path/to/zr-elisp/gnus")
(require 'nnepub)

;; 可选：显式指定 7-Zip。
;; (setq nnepub-7z-program "7zz")

;; 配置书库。
(add-to-list 'gnus-secondary-select-methods
             '(nnepub "books" (nnepub-directory "~/Books/")))
```

启动 Gnus 后，在 group buffer 中按 `^` 进入 server buffer，再用 `RET` 浏览
配置的 `books` 服务器。也可以在 group buffer 中用
`B nnepub RET ~/Books/ RET` 直接浏览目录。组列表中的每一项对应一本 EPUB，
用 `u` 订阅、`RET` 阅读，`q` 返回；只扫描目录直接包含的 `.epub` 文件。

Summary 是章节列表，使用 Gnus 的 `RET`、`SPC`、`n`、`p` 等阅读命令。
正文链接的 `RET` 或鼠标中键支持跨章跳转及脚注锚点；外部链接沿用 shr 的行为。
图片封装为 `multipart/related` MIME 内容，重复图片只封装一次；简单 SVG 图片
包装也会转换。图片显示遵循 `gnus-inhibit-images` 和 `gnus-blocked-images`；
后端保留 MIME 中的图片，便于使用 Gnus 的图片显示命令。内嵌 CID 图片沿用
Gnus 的内嵌图片规则，`gnus-blocked-images` 主要过滤外部图片 URL。

订阅、已读和收藏标记由 Gnus 保存。进入书籍时，章节显示范围和初始位置沿用
Gnus 的设置；在 group buffer 中用 `C-u RET` 可以包含已读章节。阅读状态以文章
为单位，书内的段落或滚动位置使用 Gnus 现有行为，不另存一套位置文件。

Group 身份包含文件路径和 EPUB 内容摘要。更换文件内容或移动文件后会建立
新的 group，旧版本的已读标记保留在 Gnus 中，避免把旧文章编号用于不同章节。
内部 group 名称是稳定标识，后端另提供书名作为 group description；可在
`gnus-group-line-format` 中使用 `%d` 显示描述。

首次扫描会读取目录内每本书的目录和元数据；会话内按文件修改时间及大小复用
缓存。章节资源和目录标题用哈希表建立索引，路径校验在建索引期间复用；查找
正文标题时找到首个标题即停止遍历。Messages 分别显示解压和建索引的耗时。
损坏的 EPUB 会跳过，并在 Messages 中显示原因。解压内容存放在临时目录，
关闭服务器或退出 Gnus 时清理；原始 EPUB 文件保持只读。

目前处理常规 XHTML 和图片书籍。CSS、脚本、字体和 EPUB 固定版式的显示效果
取决于 shr；不支持 DRM 解密。

## zr-nndoc-epub

临时打开单本 EPUB 可以使用 `nndoc` 的 `epub` 文档类型，无需配置书库目录：

```elisp
(require 'zr-nndoc-epub)
```

在 Gnus group buffer 中按 `G f`，选择 EPUB 文件，然后用 `RET` 进入创建的
group。类型会自动识别，EPUB 2/3 的章节、图片和脚注处理复用 `nnepub`；
图片显示同样遵循 Gnus 设置。普通 mbox 等 `nndoc` 文档继续沿用原有处理。

`G f` 创建的是普通 group，订阅和已读标记由 Gnus 保留。需要临时阅读、
不保存订阅和已读状态时，可以在 group buffer 中用 `M-:` 调用 Gnus 原生接口：

```elisp
(gnus-group-read-ephemeral-group
 "epub" `(nndoc ,(expand-file-name "~/Downloads/book.epub")) t)
```

用 summary buffer 的 `q` 退出阅读时，解压目录和该 group 的临时显示参数一并
清理。单本入口沿用 `nndoc` 的 group 身份；需要按 EPUB 版本分别保存阅读状态
时，使用上面的 `nnepub` 书库。

## zr-gnus-article-follow

`zr-gnus-article-follow-mode` 让 Gnus 按整个 Follow 窗口组翻页，适用于普通
文章和 EPUB 章节。在 article buffer 中启用，再手动分栏，或使用已有的
`zr-window-follow-columns`：

```elisp
(require 'zr-gnus-article-follow)
(require 'zr-window)
```

在正文窗口执行 `M-x zr-gnus-article-follow-mode` 和
`M-x zr-window-follow-columns`。后者按 `fill-column` 决定栏数；带前缀参数
时先删除其他窗口。已有分栏可以直接启用新模式，无需重新分栏。

模式通过局部 keymap 将正文的 `SPC` / `C-v` 映射到
`zr-gnus-article-follow-next-page`，将 `DEL` / `S-SPC` / `M-v` 映射到
`zr-gnus-article-follow-prev-page`，不使用 advice。
前后翻过整屏的栏，保留 `next-screen-context-lines` 行上下文；后续栏
显示到文章末尾后，再按 `SPC` 即切换下一篇，无需让最左栏也滚到末尾。
最左栏已显示文章开头时，向前翻页切换上一篇。带前缀参数时按指定行数滚动，
并在文章边界停止。

这两个新命令也可以在 Summary 中调用，操作已启用模式的可见正文。
文章选择及已读标记继续由 Gnus 处理，Gnus 的原有命令及函数保持不变。

新命令切换文章时保留现有分栏和其他窗口，并从第一栏开始显示新正文。模式不负责
重新排版正文；HTML 分栏前已渲染的换行仍由 shr/Gnus 决定。
关闭模式恢复启用前的 `follow-mode` 状态和原有按键，窗口布局保留；
加载库不会自动启用模式。

## 检查

```sh
make test TEST_FILE='gnus/test/nnepub-test.el gnus/test/nnopds-test.el gnus/test/nnopds-comic-test.el'
make check-parens byte-compile FILE='$(wildcard gnus/*.el)'
make clean
```

测试会使用实际 7-Zip 创建 EPUB 2/3 文件，并在独立 Gnus 会话中验证书库、
单本和临时 group 的正文、脚注跳转、资源清理及已读状态保存和恢复。
OPDS 测试启动本地 Python HTTP 服务，验证导航、分页、下载缓存、认证、
进度同步及独立 Gnus 会话的恢复位置。KOReader 测试依据
[Komga 接口](https://github.com/gotson/komga/blob/master/komga/src/main/kotlin/org/gotson/komga/interfaces/api/kosync/KoreaderSyncController.kt)
和 [calibre 接口](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/srv/kosync.py)
构造对应的认证和响应，包含无时间戳、空响应、分块 MD5 和下载前登录检查，
无需外部服务器。
漫画测试使用 Komga 与 calibre 的两种 manifest 链接形式、相对页 URL 和 Digest
认证，验证流式缓存、并发预取、实时布局切换、已读标记、失败重试和本地恢复。
图像解码和显示能力在 nox Emacs 中使用替身，网络、图片文件和 Gnus 会话实际运行。
未安装 `7zz`/`7z` 或 Emacs 不支持 libxml 时，
需要这些依赖的测试会跳过。
