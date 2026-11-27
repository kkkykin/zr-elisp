# Gnus 工具

需要 Emacs 31.1 及以上。将仓库根目录和本目录加入 `load-path`，按需加载。

## nnopds

`nnopds` 将 OPDS 2 目录作为 Gnus server，在 Article buffer 中显示章节或页图。
章节阅读复用 `zr-epub`，分页阅读复用 `zr-doc-view` 的分页规则。

| 阅读方式 | 本地原文件 | 流式来源 |
| --- | --- | --- |
| `zr-epub` | EPUB 章节 | — |
| `zr-doc-view` | PDF、CBZ、EPUB 页图 | CBZ 的 Divina 页图 |

HTTP 请求需要 `curl`，EPUB 章节解析需要 libxml 和 `7zz`/`7z`。
PDF 和 CBZ 的下载验证以及本地分页需要提供 `run` 和 `draw` 命令的 `mutool`。
显示页图需要支持相应图片格式的图形 Emacs。

更新已编译的 nnopds 时，先用 `make clean` 清理旧字节码，再重新编译这些
模块；它们共享的结构体访问器会在编译时内联：

```sh
make byte-compile FILE='zr-epub.el $(wildcard gnus/*.el)'
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

用 `M-x nnopds-browse` 选择已打开的服务器，浏览 OPDS 分级目录。
Gnus 自带的 server buffer `RET` 和 group buffer `B` 则显示已遇到的书籍
索引；新服务器尚无索引时列表为空，可以先用 `nnopds-browse` 发现书籍。
分级目录保留 OPDS 的 `navigation`、嵌套 `groups` 和 facets，
只加载当前页，不递归扫描。目录和分页链接都按 `RET` 进入，`b`/`^` 返回，
`n`/`p` 移动，`g` 刷新当前页，`q` 退出。书籍用 `u` 订阅，`RET` 进入
Gnus 的章节或页码列表，并定位到上次读到的位置。首次进入整本格式的列表时
会下载文件。
可以直接将某个目录或书目列表的 URL 配为 `nnopds-url`。

在书籍行按 `D`（`M-x nnopds-browse-download`）下载整本并留在目录中。
`SPC` 在 Article buffer 开始阅读。有原文件缓存时从本地读取，未下载的 Divina 漫画
通过服务器按页读取。未下载的 EPUB、
PDF 和仅提供整包链接的 CBZ 会提示先按 `D`。Gnus 生成章节或页码列表时
复用已下载的原文件。

`nnopds-book-readers` 按格式选择 Gnus Summary 和 Article 的阅读方式。
EPUB 默认按章节阅读，PDF 和 CBZ 默认按页阅读。
用下面的配置可将 EPUB 也按页阅读。

```elisp
(setq nnopds-book-readers '((epub . zr-doc-view)))
```

两种 EPUB 阅读方式共用原件缓存，各自有 Gnus group、已读标记和续读位置。
EPUB 全文搜索结果定位到章节 group。

在目录浏览器按 `s`（`M-x nnopds-browse-search`）输入关键词进行服务端搜索。
后端自动读取当前页的 OPDS 2 `rel=search` URI 模板，当前页未提供时使用根目录
的模板。支持 `{query}`、`{?query}`、`{&query}`，关键词按 UTF-8 编码，模板中
未填写的可选字段会省略；服务器提供的库名、代理路径和其他参数会保留。
搜索结果沿用目录的分页、订阅和阅读命令，`b` 返回搜索前的页面和光标位置，
`g` 刷新结果。搜索只取书目，不下载 EPUB、PDF 或漫画图片。

[Komga](https://github.com/gotson/komga/blob/master/komga/src/main/kotlin/org/gotson/komga/interfaces/api/opds/v2/Opds2Controller.kt)
使用 `search{?query}`，搜索结果按系列、书籍、集合和阅读列表分组；当前每类
最多返回 20 条，未提供搜索结果的分页链接。
[calibre](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/srv/opds.py)
在 `/opds` 使用路径中的 `{query}`，可直接输入 calibre 搜索表达式，如
`title:"三体" and authors:"刘慈欣"`；服务器启用全文索引后，进入目录中的
“Search book contents” 再按 `s` 可搜索正文。
具体搜索范围和语法由服务器决定，客户端遵循其
[OPDS 2 搜索链接](https://specs.opds.io/opds-2.0#3-search)，无需按服务器配置路径。

章节全文搜索使用独立的 `nnopds-search` 模块：

```elisp
(require 'nnopds-search)
```

它为 `nnopds` 注册 `gnus-search-nnopds` 引擎。在 Group buffer 的书籍行按
`G G`（`gnus-group-read-ephemeral-search-group`）搜索该书，也可先标记多本书
再搜索；在 Server buffer 的 OPDS 服务器行按 `G` 搜索其本地已知书籍。
`G g` 创建可重复使用的搜索 group。只搜索已下载的 EPUB，包含可阅读的
章节、附录和目录；未下载书籍、PDF、漫画和 EPUB 中的纯图片资源跳过。
搜索不联网、不更新阅读位置，重新启动后仍可搜索本地缓存。
结果列出命中的章节，可直接阅读，按 `A W` 返回原书中的该章节。

默认查询是不区分大小写的字面文本匹配，正文会去除 HTML 标签、解码实体并
合并空白；章节标题和作者也参与匹配。需要多个关键词、字段和布尔条件时，
启用 Gnus 的查询解析：

```elisp
(setq gnus-search-use-parsed-queries t)
```

支持隐式 AND、`or`、`not` / `-`、括号、带双引号的短语和 `/正则/`。
`body:` 搜索章节正文，`subject:` 搜索章节标题，`from:` / `sender:` 搜索作者，
`text:` 搜索正文和文章头，`id:` 搜索 Message-ID。例如
`body:"中文内容" not subject:附录`，或 `subject:第一章 or body:/脚注.*目标/`。
`limit:20` 限制结果数；`C-u G G` 可临时使用字面查询。
不支持的字段会报告错误。

书籍没有显示配置时，nnopds 为该书添加 `(display . all)` group 参数，
全部章节按顺序列出，`gnus-parameters` 保持原样。
书籍的章节顺序、`gnus-summary-goto-unread`（`never`）和 `gnus-large-newsgroup`
（`nil`）是 Summary 的局部默认值。这些阅读设置均可由书籍的 group 参数覆盖。

目录按服务器提供的分页逐页加载。

首次列出书籍时只取书目，Gnus 的章节数或页数在首次进入书籍列表后更新。支持
`application/divina+json` 漫画 manifest，以及 `application/epub+zip`、
`application/pdf` 和 `application/x-cbz` 等整本下载链接。带 Divina manifest
的书籍使用 CBZ 下载链接，其他书籍按 EPUB、PDF、CBZ 的顺序选择。
EPUB 章节阅读使用 Gnus 原有命令，图片、跨章链接和脚注由 `zr-gnus-epub` 处理。

Komga 的 OPDS 2 目录在 `self` 链接提供漫画 manifest，用户需要页面流式阅读
权限。calibre 9.18 及以上在 `/opds` 的 acquisition 链接提供 CBZ 漫画 manifest；
CBR/CB7 的整包下载链接不会作为流式漫画列出。后端沿 manifest 的 `readingOrder`
读取图片，保留页 URL 的库名、版本等参数，并从原始和 alternate 链接中选择
Emacs 支持的格式。图片请求复用目录认证，包括 Basic、Digest 和 API key。

分页阅读时，Summary 和 Article buffer 启用 `nnopds-paged-mode`。
同一本漫画下载后再次打开时，Gnus 从本地文件取页，沿用页码、同屏页数、独占设置和阅读方向。

| 按键 | 操作 |
| --- | --- |
| `1` / `2` | 同屏最多一页 / 两页 |
| `v` | 设置同屏最多 N 页 |
| `c` | 切换封面独占 |
| `l` | 切换横页独占 |
| `r` | 切换左向右 / 右向左 |
| `n` / `SPC` | 按阅读顺序前进一屏 |
| `p` / `DEL` | 按阅读顺序后退一屏 |
| 左右箭头 | 按阅读方向移动一个原始页码 |
| `j` | 跳到指定原始页码 |
| `g` | 重试当前页图的下载或渲染 |

分页布局共用 `zr-doc-view` 的自定义项。默认同屏最多两页，横页独占。
自动方向优先跟随已缓存 manifest 的 `readingProgression`，然后读取 OPDS 书目，
缺少方向时使用左向右。
`M-x nnopds-paged-set-direction` 可选择 `auto`。
设置可在阅读中切换，并按书保存。可配置新书的初始显示：

```elisp
(setq zr-doc-view-visible-pages 3
      zr-doc-view-cover-single t
      zr-doc-view-landscape-single t
      zr-doc-view-direction 'auto)
```

当前原始页码是显示起点：N=3 时，`[2,3,4]` 按前进方向键变为 `[3,4,5]`，
按 `SPC` 则变为 `[5,6,7]`。右向左只反转屏幕摆放和箭头含义，
`SPC/DEL` 始终沿原始阅读顺序前后翻屏。切换 N 或方向保留当前原始页码。
独占页会截断显示范围，末尾不足 N 页时显示剩余页面。页面按窗口宽高等比缩放，
并排页使用相同高度，窗口调整后重新适配。漫画未提供尺寸时按需读取图片尺寸。

打开未下载的 Divina 漫画页列表时只取 manifest。列页目录或 Gnus 预取文章时也只取页码。
Gnus 从 PDF、CBZ 或 EPUB 原文件分页时，通过 `mutool run` 获取页尺寸，再由
`mutool draw` 渲染 PNG。PDF 页尺寸包含裁剪、旋转和 UserUnit。渲染按目标像素宽度向上取
256、512、1024、2048 等档位，窗口变化跨越档位时重新渲染并复用已有缓存。
可用 `nnopds-mupdf-program` 指定可执行文件路径。
Gnus 中的 PDF 采用页图阅读，文字选择、搜索和注释需要额外文本层。要求密码的 PDF
会报告打开失败。

`nnopds-paged-prefetch-pages` 默认准备显示范围前后各 4 页，设为 0 可关闭；
`nnopds-paged-max-requests` 默认限制每本书最多 2 个并发取图或渲染任务。
任务写入临时文件，成功后替换正式缓存，关闭阅读或服务器时取消待处理任务。
漫画 manifest 和图片缓存位于账号目录下的 `.comic/`。PDF 和 CBZ 的整本原文件、
页尺寸索引和 Gnus 渲染图片分别位于 `.pdf/` 和 `.cbz/`。分页 EPUB 的页尺寸和
渲染图片位于 `.epub-pages/`。这些缓存可跨会话复用。
解码图片只保留当前显示的页面。

分页阅读完整显示当前页面范围后保存本地页码，更新相应 articles 的已读标记并保留
收藏等手动标记。重新进入 Gnus group 时从保存的页码继续。
`nnopds-koreader-*`、`nnopds-resume` 和 `nnopds-save-position` 的服务器同步用于 EPUB 章节阅读。

整本下载优先接受书籍格式对应的媒体类型，也接受 `application/octet-stream`。

目录、EPUB、漫画和 PDF 缓存保存在 `gnus-cache-directory` 下的 `nnopds/` 子目录，
不同 server 和认证配置分别缓存。打开 Gnus 只读取本地已遇到的书籍索引，
没有缓存时也不联网；首次使用 `nnopds-browse` 才请求根目录，进入未缓存的
目录或分页时请求该页。默认重访目录和返回上级均使用缓存。新增书籍或版本更新后，在所在
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
便于区分网络等待与本地处理。请求使用 `zr-http`；`nnopds-http-options`
覆盖全局 `zr-http-default-options`，例如 `(:timeout 60 :proxy nil)`。
打开书籍失败时，Messages 会显示具体 HTTP 状态或 curl 错误；Gnus 的
“group couldn't be activated” 是后续的通用报错。最近一次 backend 错误也可用
`M-: (nnheader-get-report-string 'nnopds) RET` 查看。

在 Gnus 的 Group buffer 对书籍执行 `M-x gnus-group-delete-group`，会移除
本地 group 和书目索引并关闭阅读会话，保留已下载的书籍。加 `C-u` 前缀还会
清理该书的本地下载缓存和阅读设置。此操作不删除服务器上的书籍或已同步的进度；
再次浏览相应目录时仍可发现并订阅该书。仅想退订并保留 Gnus 阅读状态时，用 `u`。

EPUB 和单书索引使用书籍 ID 的摘要作短文件名，临时文件使用固定短前缀，
避免 Windows 用户目录较深时超出路径长度限制。

Group 名称在首次读取书目时生成，格式为 `book.书名.作者.16位摘要`，例如
`nnopds+calibre-pub:book.三体.刘慈欣.48b9663e8718c9cb`。中文直接保留，空格和
标点转成连字符；书名和作者各最多 64 个字符，缺失时分别使用 `untitled` 和
`unknown-author`。多位作者用连字符连接，原始书名和作者仍用于目录及章节标题。
摘要由书目的稳定 URL 和 `metadata.modified` 共同生成，用于区分同名书及版本。
生成的书名、作者部分或版本变化会产生新 group，已遇到的旧版本和 Gnus 标记继续保留。
使用原哈希名称的订阅需要按新名称重新订阅，旧 group 的标记不会自动迁移。
全局 `gnus-group-line-format` 无需调整。没有 `modified` 的书目作为一个
固定版本缓存；这种服务器需要提供版本变化信号才能自动发现新版。已记录的
版本会校验 EPUB 内容摘要，避免缓存缺失后将不同内容用于旧文章编号。

`nnopds-progress-protocol` 默认是 `koreader`。只有明确配置
`nnopds-koreader-url` 才启用服务器同步。KOReader 的同步认证独立于取书认证：

- Komga 的地址通常是 `/koreader`，`nnopds-koreader-user` 填 API key，
  不需要同步密码；该 API key 的用户需要 KOReader 同步权限。
- calibre 的地址通常是 `/kosync`，`nnopds-koreader-user` 填 Content server
  用户名。密码从同步 URL 对应的 `auth-source` 记录获取，也可显式设置
  `nnopds-koreader-password`；请求发送 UTF-8 密码的 MD5。
- 同步服务器和目录的 origin（协议、主机和端口）相同时，同步请求也携带
  `nnopds-headers`，可通过 Caddy 等反向代理的自定义请求头校验。同步账号仍用
  `nnopds-koreader-user/password`；取书账号生成的 Basic/Digest 认证不会随之发送。
  同步请求头仅发送到配置的同步服务器 origin。
  calibre 首次下载前会先登录同步接口，让服务器关联下载文件与原书的哈希。

书籍标识使用 KOReader 的 partial MD5，设备端应选择默认的 Binary 匹配方式。
EPUB 的 CREngine XPointer 按 OPF spine 对应到 Gnus 章节；Komga 的无时间戳
响应和 calibre 的 Unix 时间戳响应均可读取，保存接受两端不同的 HTTP 200
响应格式。

配置同步后，自动恢复和保存章级位置：

- 进入书籍时获取服务器位置，在 Summary 定位到对应章节，并把之前的普通
  未读章节标为已读，保留收藏、休眠等手动标记。仅定位不会把当前章节标为
  已读；`SPC` 阅读该章。
- 实际显示章节后延迟保存，`nnopds-progress-sync-delay` 默认 1 秒。
- 预取文章和查看正文之外的附录脚注不会改变同步位置；退出 group 时完成
  待保存的位置。Gnus 的订阅、已读和收藏标记继续由 Gnus 保存。
- 服务器读取失败、另一个设备位置更靠后或写入返回 `409` 时保留服务器状态。
  用 `M-x nnopds-resume` 重新获取位置并更新前面章节的已读标记；用
  `M-x nnopds-save-position` 立即尝试保存当前章。两个命令也可在 article buffer 调用。

`nnopds-progress-device-id` 和 `nnopds-progress-device-name` 标识本设备。
设置 `nnopds-progress-sync` 为 nil 可关闭自动恢复和保存。
未配置 KOReader 地址的书库使用 Gnus 本地阅读状态。
本版保存章节起点，尚不保存章内滚动位置；KOReader 的 `percentage` 以章节在
spine 中的序号估算，实际跳转使用 XPointer。KOReader 没有条件写入接口，
写前检查可以保留已发现的更新位置，但不能保证原子冲突检测。

目录、阅读格式和同步协议分别处理。`nnopds-progress-protocol` 当前只支持
`koreader`，配置项和协议读写接口保留，方便后续添加正式的 OPDS 同步协议。
Divina 取图位于 `nnopds-comic.el`，本地文档的 Gnus 页图渲染位于
`nnopds-mupdf.el`。`nnopds-paged.el` 将页图接入 Gnus Article buffer，
调度取图任务并管理阅读状态。并排尺寸、页范围和翻屏位置由 `zr-doc-view` 计算。
服务器漫画和 PDF 进度协议可在现有位置接口上另行适配。

## zr-epub

`zr-epub` 是独立的 EPUB 库，不加载 Gnus，也不提供 `nnepub` select method。
原来配置了 `nnepub` 的话，移除对应的 select method；本地单本仍可用 `zr-nndoc-epub` 打开。
它解析 EPUB 2 NCX、EPUB 3 导航和 OPF spine；脚注等补充 XHTML 资源排在正文之后。
需要支持 libxml 的 Emacs，以及 `7zz` 或 `7z`；可用 `zr-epub-7z-program` 指定程序。
EPUB 解析参考 nov.el，无需安装 nov 或 esxml。

```elisp
(require 'zr-epub)
(let ((book (zr-epub-open "~/Books/book.epub")))
  (unwind-protect
      (zr-epub-chapter-html book (zr-epub-chapter book 1))
    (zr-epub-close book)))
```

`zr-epub-book-chapters` 返回章节列表。调用者可向 `zr-epub-chapter-html` 传入
章节链接和图片 URL 的转换函数。Gnus 适配层 `zr-gnus-epub` 将图片封装为
`multipart/related`，保留跨章链接和脚注锚点；外部链接沿用 shr 的行为。
图片显示遵循 `gnus-inhibit-images` 和 `gnus-blocked-images`。
CSS、脚本、字体和固定版式的显示效果取决于渲染器；不支持 DRM 解密。

## zr-nndoc-epub

临时打开单本 EPUB 可以使用 `nndoc` 的 `epub` 文档类型，无需配置书库目录：

```elisp
(require 'zr-nndoc-epub)
```

在 Gnus group buffer 中按 `G f`，选择 EPUB 文件，然后用 `RET` 进入创建的
group。类型会自动识别，章节、图片和脚注处理与 `nnopds` 共用；普通 mbox
等 `nndoc` 文档继续沿用原有处理。

`G f` 创建的是普通 group，订阅和已读标记由 Gnus 保留。需要临时阅读、
不保存订阅和已读状态时，可以在 group buffer 中用 `M-:` 调用 Gnus 原生接口：

```elisp
(gnus-group-read-ephemeral-group
 "epub" `(nndoc ,(expand-file-name "~/Downloads/book.epub")) t)
```

用 summary buffer 的 `q` 退出阅读时清理解压目录；排序和 EPUB 渲染设置只作用于
对应的阅读缓冲区。单本入口沿用 `nndoc` 的 group 身份。

## zr-gnus-article-follow

`zr-gnus-article-follow` 一步进入分栏阅读，适用于普通文章和 EPUB 章节：

```elisp
(require 'zr-gnus-article-follow)
```

在 Summary 或正文窗口执行 `M-x zr-gnus-article-follow`。在 Summary 中调用
时打开光标所在文章并切到正文，自动启用模式，按正文的 `fill-column` 决定
栏数；已有正文分栏会保留，重复调用不会增加栏数。窗口较窄时保留单栏。
选择另一篇文章时从开头显示，同一篇文章重复调用时保留当前阅读位置。
`C-u M-x zr-gnus-article-follow` 先让正文占满 frame，再重新分栏。
布局复用 `zr-window-arrange-follow-columns`，按实际可显示字符数计算栏宽，
包含边缘、滚动条等开销；加载 Gnus Follow 模块时会自动加载 `zr-window`。

也可以在正文中单独启用 `zr-gnus-article-follow-mode`，只开启 Follow 和翻页
按键，分栏由自己安排；适合已有布局或通过 hook 启用。

模式通过局部 keymap 将正文的 `SPC` / `C-v` 映射到
`zr-gnus-article-follow-next-page`，将 `DEL` / `S-SPC` / `M-v` 映射到
`zr-gnus-article-follow-prev-page`，不使用 advice。
前后翻过整屏的栏，保留 `next-screen-context-lines` 行上下文；后续栏
显示到文章末尾后，再按 `SPC` 即切换下一篇，无需让最左栏也滚到末尾。
最左栏已显示文章开头时，向前翻页切换上一篇。带前缀参数时按指定行数滚动，
并在文章边界停止。

这两个新命令也可以在 Summary 中调用，操作已启用模式的可见正文。
文章选择遵循 Summary 中的 `gnus-summary-goto-unread`：`never` 包含已读
文章，`nil` 或 `t` 导航到未读文章。已读标记继续由 Gnus 处理，
Gnus 的原有命令及函数保持不变。

新命令切换文章时保留现有分栏和其他窗口，并从第一栏开始显示新正文。模式不负责
重新排版正文；HTML 分栏前已渲染的换行仍由 shr/Gnus 决定。
关闭模式恢复启用前的 `follow-mode` 状态和原有按键，窗口布局保留；
加载库不会自动启用模式。

## 检查

```sh
make test TEST_FILE='gnus/test/zr-epub-test.el gnus/test/nnopds-test.el gnus/test/nnopds-comic-test.el gnus/test/nnopds-mupdf-test.el'
make check-parens byte-compile FILE='zr-epub.el $(wildcard gnus/*.el)'
make clean
```

测试会使用实际 7-Zip 创建 EPUB 2/3 文件，验证独立解析、OPDS 阅读，以及
单本和临时 group 的正文、脚注跳转、资源清理和用户参数覆盖。
OPDS 测试启动本地 Python HTTP 服务，验证导航、分页、下载缓存、认证、
进度同步及独立 Gnus 会话的恢复位置。KOReader 测试依据
[Komga 接口](https://github.com/gotson/komga/blob/master/komga/src/main/kotlin/org/gotson/komga/interfaces/api/kosync/KoreaderSyncController.kt)
和 [calibre 接口](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/srv/kosync.py)
构造对应的认证和响应，包含无时间戳、空响应、分块 MD5 和下载前登录检查，
无需外部服务器。
漫画测试使用 Komga 与 calibre 的两种 manifest 链接形式、相对页 URL 和 Digest
认证，验证流式缓存、并发预取、实时布局切换、已读标记、失败重试和本地恢复。
PDF 测试使用真实 `mutool` 验证有效页尺寸、下载校验、按需渲染、分辨率缓存、
整屏与逐页导航、失败重试、取消和离线重开。
图像解码和显示能力在 nox Emacs 中使用替身，网络、图片文件和 Gnus 会话实际运行。
未安装 `7zz`/`7z`、`mutool` 或 Emacs 不支持 libxml 时，需要相应依赖的测试会跳过。
