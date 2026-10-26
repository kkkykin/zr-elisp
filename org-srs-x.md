# org-srs-x

让 LunaTranslator 通过 AnkiConnect v6 HTTP 接口，把词条保存为 Org-srs 卡片。
需要 Emacs 30.2 及以上、带 libxml 支持，并已安装 `org-srs` 和它的依赖。
只加载库不会启动服务；用 `M-x org-srs-x-start` 开始接收制卡请求。

## 启用

将仓库根目录加入 `load-path`，配置保存目录：

```elisp
(require 'org-srs-x)
(setq org-srs-x-directory "~/org/srs/"
      org-srs-x-host "127.0.0.1"
      org-srs-x-port 8765)
```

也可以延迟加载：

```elisp
(use-package org-srs-x
  :commands (org-srs-x-start org-srs-x-stop org-srs-x-review)
  :custom (org-srs-x-directory "~/org/srs/"))
```

执行 `M-x org-srs-x-start` 后，将 LunaTranslator 的 AnkiConnect 主机和端口
设为同样的地址。默认是 `127.0.0.1:8765`；如果该端口已被 Anki 占用，可以
给两端配置另一个端口。修改服务地址或端口后，执行 `org-srs-x-stop` 再启动。
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

每条笔记生成一个顶层标题，带有 `ID`、`ANKI_NOTE_ID`、`ANKI_MODEL`、
`ANKI_FIELDS` 和 `ANKI_TAGS` 属性，以及 `Front` / `Back` 子标题。
通过 `org-srs-item-new` 创建实际的 `card back` 复习条目和日志。

默认正面包含单词、例句、单词音频、例句音频和截图；背面包含读音、备注、
选中的词典释义和额外字段。HTML 转成 Org 文本和链接，脚本、样式不参与正文。
Anki 模型字段、HTML 模板和 CSS 保存在目录下的 `.org-srs-x.json`，
卡片使用 Org-srs 的显示方式，模板中的 HTML/CSS/JavaScript 不会执行。

## 按文件选择词典

`org-srs-x-dictionaries` 的键是相对于保存目录的 Org 文件名，也支持绝对路径。
值是要保留的词典 ID 或显示名称列表：

```elisp
(setq org-srs-x-dictionaries
      '(("英語.org" "edict")
        ("日本語/ゲーム.org" "国語辞典" "jmdict")
        ("无释义.org")))
```

没有配置的文件保留全部词典；配置为空列表的文件不保留词典。
词典 ID 和名称来自 LunaTranslator 的 `dictionaryInfo` 字段；可以在未过滤的
卡片 `ANKI_FIELDS` 属性中查看。

也可以在目标 Org 文件中写入 JSON 数组，覆盖上述配置：

```org
#+SRS_X_DICTIONARIES: ["国語辞典", "jmdict"]
```

写 `#+SRS_X_DICTIONARIES: []` 表示不保留任何词典。
过滤同时作用于背面正文和保存的 `dictionaryInfo` / `dictionaryContent` 字段。
配置修改对之后创建的卡片生效。

## 音频与截图

附件从请求的本地 `path` 或 base64 `data` 导入，存入 deck 文件旁的
`<文件名>.media/` 目录；卡片使用相对文件链接。文件名带内容摘要以避免覆盖。
客户端提供的 `path` 必须能被 Emacs 读取。

如果 LunaTranslator 在 Windows、Emacs 在 WSL，可以配置路径转换：

```elisp
(setq org-srs-x-media-path-function
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

执行 `M-x org-srs-x-review` 复习保存目录中的卡片。
在单个 deck 文件中也可以直接运行 `M-x org-srs-review-start`。

`org-srs-x-render-function` 可以设为接收字段 hash table、返回
`(FRONT . BACK)` 字符串对的函数。它在词典过滤和附件导入之后运行，
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
make test TEST_FILE=test/org-srs-x-test.el
make check-parens FILE='org-srs-x.el test/org-srs-x-test.el'
make byte-compile FILE=org-srs-x.el
make clean
```

测试使用临时目录和本机随机端口；涉及 Org-srs 的测试加载已安装的包，
未安装时跳过这些测试。
