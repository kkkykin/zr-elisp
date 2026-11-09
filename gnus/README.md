# Gnus 工具

需要 Emacs 31.1 及以上。将本目录加入 `load-path`，按需加载。

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
make test TEST_FILE=gnus/test/nnepub-test.el
make check-parens byte-compile FILE='$(wildcard gnus/*.el)'
make clean
```

测试会使用实际 7-Zip 创建 EPUB 2/3 文件，并在独立 Gnus 会话中验证书库、
单本和临时 group 的正文、脚注跳转、资源清理及已读状态保存和恢复。
未安装 `7zz`/`7z` 或 Emacs 不支持 libxml 时，
需要这些依赖的测试会跳过。
