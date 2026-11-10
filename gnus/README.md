# Gnus 工具

需要 Emacs 31.1 及以上。将本目录加入 `load-path`，按需加载。

## nnopds

`nnopds` 将 OPDS 2 目录作为 Gnus server，每本 EPUB 是一个 group，正文资源
是 articles。首次进入书籍时下载 EPUB，章节、图片及脚注处理复用 `nnepub`。
需要支持 libxml 的 Emacs、`curl` 和 `7zz`/`7z`。

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
用 `u` 订阅书籍、`RET` 阅读。也可以用 `B nnopds RET 目录URL RET` 浏览。
目录支持 `navigation`、嵌套 `groups` 和 `next` 分页，并按 publication 的
`self`/取书 URL 去重；搜索模板和 facets 不自动遍历。可以直接将某个书目
列表的 URL 配为 `nnopds-url`，缩小书库范围。

首次列出书籍时只取书目，章节数在首次打开后更新。当前支持带直接 EPUB
取书链接的 publication；不提供 EPUB 下载的条目暂不列出。阅读使用 Gnus
原有命令，图片、跨章链接和脚注沿用 `nnepub`。

目录和 EPUB 保存在 `gnus-cache-directory` 下的 `nnopds/` 子目录，
不同 server 和认证配置分别缓存。默认只在没有目录缓存时联网，之后启动、
`g` 和浏览书库均使用已有缓存，适合慢网或离线使用。新增书籍或版本更新后，
用 `M-x nnopds-refresh-catalog` 选择已打开的 server 手动刷新，再浏览服务器
查看新书。`nnopds-catalog-cache-ttl` 默认为 nil；设为秒数可启用定时过期，
设为 0 则每次扫描都联网刷新。

刷新按分页保存缓存，并使用服务器提供的 ETag/Last-Modified 条件请求，
未变化的页面无需重新下载。首次抓取中断后，普通扫描可复用已完成的分页；
刷新失败时保留完整的旧书目，重新启动也能继续使用。章节数集中缓存，启动
无需逐本读取索引。已下载的 EPUB 可离线阅读；解压内容在关闭 server 时清理，
下载缓存跨会话保留。`nnopds-request-timeout` 限制每个 HTTP 请求。

Group 身份由书目的稳定 URL 和 `metadata.modified` 确定，书目版本更新会
产生新 group，旧版本的 Gnus 标记继续保留。没有 `modified` 的书目作为一个
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
后续漫画可增加阅读格式和 KOReader 页码适配，复用现有目录、缓存和位置队列。

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
缓存。损坏的 EPUB 会跳过，并在 Messages 中显示原因。解压内容存放在临时目录，
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

## 检查

```sh
make test TEST_FILE='gnus/test/nnepub-test.el gnus/test/nnopds-test.el'
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
未安装 `7zz`/`7z` 或 Emacs 不支持 libxml 时，
需要这些依赖的测试会跳过。
