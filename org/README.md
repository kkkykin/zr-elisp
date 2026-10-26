# zr-org-srs-x

让 LunaTranslator 通过 AnkiConnect v6 HTTP 接口，把词条保存为 Org-srs 卡片。
需要 Emacs 30.2 及以上、带 libxml 支持，并已安装 `org-srs` 和它的依赖。
只加载库不会启动服务；用 `M-x zr-org-srs-x-start` 开始接收制卡请求。

## 启用

将仓库的 `org/` 目录加入 `load-path`，配置保存目录：

```elisp
(add-to-list 'load-path "/path/to/zr-elisp/org")
(require 'zr-org-srs-x)
(setq zr-org-srs-x-directory "~/org/srs/"
      zr-org-srs-x-host "127.0.0.1"
      zr-org-srs-x-port 8765)
```

也可以延迟加载：

```elisp
(use-package zr-org-srs-x
  :commands (zr-org-srs-x-start zr-org-srs-x-stop zr-org-srs-x-review)
  :custom (zr-org-srs-x-directory "~/org/srs/"))
```

执行 `M-x zr-org-srs-x-start` 后，将 LunaTranslator 的 AnkiConnect 主机和端口
设为同样的地址。默认是 `127.0.0.1:8765`；如果该端口已被 Anki 占用，可以
给两端配置另一个端口。修改服务地址或端口后，执行 `zr-org-srs-x-stop` 再启动。
此服务接收桌面客户端的请求，没有认证功能。

## Deck 与 Org 文件

每个 deck 对应保存目录中的一个 Org 文件：

| LunaTranslator deck | Org 文件 |
| --- | --- |
| `lunadeck` | `~/org/srs/lunadeck.org` |
| `日本語` | `~/org/srs/日本語.org` |
| `日本語::ゲーム` | `~/org/srs/日本語/ゲーム.org` |

创建 deck 会建立目录和文件；已有 Org 文件的内容保留，新卡追加到文件末尾。
目录下已有的 `.org` 文件也会出现在 deck 列表中。deck 名称不能包含路径分隔符、
`..` 路径组件或 Windows 文件名不允许的字符。

每条笔记生成一个顶层标题，只保留 Org 的 `ID`、tags、复习日志，
以及 `Front` / `Back` 子标题；不添加 `ANKI_*` 属性。
通过 `org-srs-item-new` 创建实际的 `card back` 复习条目和日志。

原始字段不写入 Org 或其他文件，LunaTranslator 词典 HTML 直接丢弃。
接口所需的数字笔记 ID、模型名、去重及单词查询摘要，保存在
`.zr-org-srs-x-notes.json` 中，通过 Org `ID` 关联卡片；此文件应随 deck 一起保留。
复习只依赖 Org 文件，摘要索引用于 AnkiConnect 的查找、删除和去重。

默认正面包含单词、例句、单词音频、例句音频和截图；背面包含读音、翻译/备注
（`remarks`）、dictionary.el 的释义和额外字段。
HTML 转成 Org 文本和链接，脚本、样式不参与正文。
Anki 模型只保存字段定义、模板名和编号，写入 `.zr-org-srs-x.json`。
模板 HTML 和 CSS 请求会被验证后丢弃，卡片使用 Org-srs 的显示方式。

## dictionary.el 查词

LunaTranslator 发来的 `dictionaryInfo`、`dictionaryContent` 直接丢弃，
不解析、不保存。制卡时用 Emacs 自带的 `dictionary.el` 查询单词，将返回的
全部释义追加到背面，保留词典名称。没有命中时仍保存单词、翻译和其他内容。

服务地址和端口使用现有的 `dictionary-server`、`dictionary-port` 配置，例如：

```elisp
(use-package dictionary
  :custom
  (dictionary-server "localhost")
  (dictionary-port 2628)
  (dictionary-default-dictionary "*"))
```

如果 `dictionary-server` 未设置，制卡使用 `localhost`。
需要有可用的 DICT 服务；查询使用独立连接，不打开 Dictionary 窗口。

按文件选择词典，直接在目标 Org 文件的**第一行**设置标准文件局部变量：

```org
# -*- dictionary-default-dictionary: "gcide"; -*-
#+title: 英語
```

数据库名必须写成带双引号的字符串，例如 `"dictd-db-eng-zho"`；不加引号会被
Emacs 读成 symbol，无法用于查词。`"*"` 查询全部数据库，`"!"` 使用第一个命中的
数据库，`nil` 跳过查词。

也可以在 deck 目录或其父目录的 `.dir-locals.el` 中配置，适用于该目录下的
Org 文件和子目录中的 deck，包括之后创建的文件：

```elisp
((org-mode . ((dictionary-default-dictionary . "dictd-db-eng-zho"))))
```

文件局部变量优先于目录局部变量；两者都未设置时使用全局
`dictionary-default-dictionary`。Emacs 对文件和目录局部变量的信任规则照常
生效；可以提前允许所需的具体值，避免首次制卡请求等待信任确认：

```elisp
(add-to-list 'safe-local-variable-values
             '(dictionary-default-dictionary . "dictd-db-eng-zho"))
```

修改第一行或 `.dir-locals.el` 后，在已打开的 deck buffer 中执行
`M-x normal-mode`，或关闭后重新打开文件，使设置生效。
配置只影响之后创建的卡片。查询超时或服务错误会让 `addNote` 返回错误，
不保存新卡片；默认超时为 10 秒，可通过 `zr-org-srs-x-dictionary-timeout` 修改。

## 音频与截图

附件从请求的本地 `path` 或 base64 `data` 导入，存入 deck 文件旁的
`<文件名>.media/` 目录；卡片使用相对文件链接。文件名带内容摘要以避免覆盖。
客户端提供的 `path` 必须能被 Emacs 读取。

如果 LunaTranslator 在 Windows、Emacs 在 WSL，可以配置路径转换：

```elisp
(setq zr-org-srs-x-media-path-function
      (lambda (path)
        (let ((path (subst-char-in-string ?\\ ?/ path)))
          (if (string-match "\\`\\([A-Za-z]\\):/\\(.*\\)\\'" path)
              (concat "/mnt/" (downcase (match-string 1 path))
                      "/" (match-string 2 path))
            path))))
```

其他挂载方式可以替换这个函数。HTTP 主机地址也需要按两端的网络环境配置。
删除笔记会移除对应 Org 子树，附件保留。

## 复习与自定义显示

执行 `M-x zr-org-srs-x-review` 复习保存目录中的卡片。
在单个 deck 文件中也可以直接运行 `M-x org-srs-review-start`。

`zr-org-srs-x-render-function` 可以设为接收 `(fields definitions)`、返回
`(FRONT . BACK)` 字符串对的函数。`fields` 是移除 Luna 词典字段后的 hash table，
`definitions` 是 dictionary.el 的 Org 释义文本。它在查词和附件导入之后运行，
返回值使用 Org 格式。服务会转义可能被解释成额外标题、关键字或抽屉的正文行。

## 接口与验证

支持 `version`、`deckNames`、`deckNamesAndIds`、`createDeck`、`modelNames`、
`modelFieldNames`、`createModel`、`updateModelStyling`、`updateModelTemplates`、
`addNote`、`findNotes`、`deleteNotes`。接收 GET 或 POST 中的 JSON 请求，
返回 AnkiConnect 的 `result` / `error` 对象。

`findNotes` 支持空查询、`deck:"名称"` 和 LunaTranslator 使用的
`deck:"名称" w:"单词"`（也接受 `word:`）。重复检查使用同一模型的第一个字段，
范围是所有 deck；`allowDuplicate` 为 true 时允许重复。
模型要求非 cloze 且只有一个卡片模板，其他 AnkiConnect 操作返回错误。

```sh
make test TEST_FILE=org/test/zr-org-srs-x-test.el
make check-parens FILE='org/zr-org-srs-x.el org/test/zr-org-srs-x-test.el'
make byte-compile FILE=org/zr-org-srs-x.el
make clean
```

测试使用临时目录和本机随机端口；涉及 Org-srs 的测试加载已安装的包，
未安装时跳过这些测试。
