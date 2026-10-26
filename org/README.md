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
全纯 Org 模式存储，**不生成任何外部 JSON 元数据文件**，完全避免 Git 冲突。
卡片使用 Anki 兼容的 13 位毫秒时间戳作为 Org 的 `:ID:` 属性与 `srsitem:<ID>::card::back` 条目名。
AnkiConnect 的查找、删除和去重直接在 Org buffer 中按 `:ID:` 与标题进行。

默认正面包含单词、例句、单词音频、例句音频和截图；背面包含读音、翻译/备注
（`remarks`）、dictionary.el 的释义和额外字段。
HTML 转成 Org 文本和链接，脚本、样式不参与正文。
客户端创建的 Anki 模型仅在 Emacs 运行时保存在内存中，不落盘。
模板 HTML 和 CSS 请求会被验证后丢弃，卡片使用 Org-srs 的显示方式。

## dictionary.el 查词

LunaTranslator 发来的 `dictionaryInfo`、`dictionaryContent` 直接丢弃，
不解析、不保存。制卡时用 Emacs 自带的 `dictionary.el` 查询单词，将返回的
全部释义追加到背面。每个词典默认使用 `*** [数据库 id]` 子标题，
id 为 `unknown` 时使用完整词典名；多个词典分别分段，同一显示名称的多条释义放在同一子标题下。
没有命中时仍保存单词、翻译和其他内容。

```org
** Back
一个小村庄

*** [dictd-db-eng-zho]
hamlet
村
A small village or a group of houses.

*** [dict-db-wordnet-542]
hamlet
    n 1: a community of people smaller than a village
```

可通过 `zr-org-srs-x-dictionary-name-function` 自定义标题。
函数接收完整词典名和数据库 id，返回不含开头星号的单行标题文字。例如始终显示完整名称和 id：

```elisp
(setq zr-org-srs-x-dictionary-name-function
      (lambda (name id) (format "%s [%s]" name id)))
```

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

用 `zr-org-srs-x-model-alist` 按 Anki 的 `modelName` 配置卡片内容。
模型名可以是 symbol 或字符串；每项的 cdr 是 `name/front/back` 模板 alist：

```elisp
(setq zr-org-srs-x-model-alist
      '((modelofluna
         . ((name . "$.word")
            (front . "$.example_sentence\n\n$picture\n\n$audio")
            (back . "$.remarks\n\n$dictionary")))
        (t . zr-org-srs-x-render-default-note)))
```

`name` 是 Org 卡片标题，`front` 和 `back` 是正反面的 Org 文本。三项都必须提供，
标题不能为空。`t` 项处理未单独配置的模型；默认函数用第一个字段作为标题和
正面，其余字段及词典释义放到背面。省略 `t` 时，未配置的模型返回错误。

| 占位符 | 内容 |
| --- | --- |
| `$.字段名` | 该字段转成 Org 的文本；没有该字段时为空字符串 |
| `$dictionary` | dictionary.el 返回的全部释义 |
| `$picture` | 本条笔记导入的全部图片链接 |
| `$audio` | 本条笔记导入的全部音频链接 |
| `$video` | 本条笔记导入的全部视频链接 |
| `$$` | 字面量 `$` |

没有释义或附件时，对应占位符为空字符串。替换只执行一遍，字段里的 `$` 不会
再次展开。附件链接也会追加到请求指定的字段中，例如 `$.audio_for_word`；
同时使用该字段和 `$audio` 会显示两次同一个附件。
查词使用 `word` 字段，没有时使用模型的第一个字段。

模型项的 cdr 也可以是函数。函数接收 `(fields variables)`，返回
`((name . STRING) (front . STRING) (back . STRING))`，返回的字符串直接使用：

```elisp
(defun my-srs-card (fields variables)
  `((name . ,(cdr (assoc "word" fields)))
    (front . ,(alist-get "example_sentence" fields "" nil #'equal))
    (back . ,(concat (alist-get "remarks" fields "" nil #'equal) "\n\n"
                    (alist-get 'dictionary variables) "\n\n"
                    (alist-get 'audio variables)))))

(setq zr-org-srs-x-model-alist
      '((modelofluna . my-srs-card)
        (t . zr-org-srs-x-render-default-note)))
```

`fields` 是按模型声明顺序排列的 `((字段名字符串 . Org 文本) ...)` alist，已移除
Luna 词典字段、导入附件并将字段转成 Org。`variables` 是以
`dictionary/picture/audio/video` 为 symbol key、Org 文本为值的 alist。
模板 alist 中的单项 cdr 也可以是函数，接收相同参数，
返回该项的 Org 字符串。

配置读取和渲染函数调用都在目标 deck buffer 中进行，所以这份 alist 也能通过
file-local 或 `.dir-locals.el` 设置，遵循 Emacs 的局部变量信任规则。
修改局部配置后执行 `M-x normal-mode`，仅影响之后创建的卡片。
服务会转义可能被解释成额外标题、关键字或抽屉的正文行。

## 接口与验证

支持 `version`、`deckNames`、`deckNamesAndIds`、`createDeck`、`modelNames`、
`modelFieldNames`、`createModel`、`updateModelStyling`、`updateModelTemplates`、
`addNote`、`findNotes`、`deleteNotes`。接收 GET 或 POST 中的 JSON 请求，
返回 AnkiConnect 的 `result` / `error` 对象。

`findNotes` 支持空查询、`deck:"名称"` 和 LunaTranslator 使用的
`deck:"名称" w:"单词"`（也接受 `word:`）。单词查询精确匹配一级标题文字，
不匹配例句、释义或其他正文；自定义标题与单词不同的卡片按标题查找。
标题匹配忽略 tags，保留 TODO 关键词、优先级和 COMMENT。
查找只返回规范的正整数 `ID`，UUID 等其他 Org ID 不参与接口查询。
重复检查比对已有的一级标题文字，
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
