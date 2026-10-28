# zr-org-srs-x

让 LunaTranslator 通过 AnkiConnect v6 HTTP 接口，把词条保存为 Org-srs 卡片。
需要 Emacs 30.2 及以上、带 libxml 支持，并已安装 `org-srs` 和它的依赖。
只加载库不会启动服务；用 `M-x zr-org-srs-x-start` 开始接收制卡请求。

## 启用

将仓库根目录和 `org/` 目录加入 `load-path`，配置保存目录并启用词典链接：

```elisp
(add-to-list 'load-path "/path/to/zr-elisp")
(add-to-list 'load-path "/path/to/zr-elisp/org")
(require 'zr-org-srs-x)
(zr-org-link-mode 1)
(setq zr-org-srs-x-directory "~/org/srs/"
      zr-org-srs-x-host "127.0.0.1"
      zr-org-srs-x-port 8765)
```

也可以延迟加载：

```elisp
(use-package zr-org-srs-x
  :commands (zr-org-srs-x-start zr-org-srs-x-stop zr-org-srs-x-review
             zr-org-srs-x-update-dictionaries)
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

查询实现独立在根目录的 `zr-dictionary.el`，不依赖 Org。
`M-x zr-dictionary-search` 用当前 buffer 的配置查词，结果 buffer 使用原生
`dictionary-mode`，复用释义样式、引用按钮、查询历史和窗口关闭行为。
`{词语或短语}` 引用可点击继续查词；`s` 查询新词，`d` 查询光标处词语，
`j/k` 跳到当前结果的下一个/上一个词典，`f/b` 用当前词查询配置中的下一组/上一组
词典；切换仅查询目标组，未命中时显示空结果，可继续切换。
`l` 返回上次结果，`g` 重新查询当前查询，`q` 关闭窗口。
`D` 修改词典阶段，`M` 修改匹配策略，`m` 列出首个命中词典阶段中的全部候选词。
按键、按钮和菜单沿用结果 buffer 的分组查询配置；历史返回恢复当时的配置和释义。
查询会立即打开 buffer，同组不同服务器并发查询，先返回的结果先显示，
后返回的结果追加到末尾。追加不会移动光标或切换窗口。
开始新查询、返回历史或关闭 buffer 会取消尚未结束的旧请求。
`C-u M-x zr-dictionary-search` 可临时指定词典阶段列表和匹配策略。
程序调用 `zr-dictionary-lookup` 返回 `((词典显示名 释义...) ...)`，不切换窗口，
等待命中阶段的全部结果，按配置顺序合并；显式传入 `nil` 词典列表禁用查询。
可用可选参数传入词典列表和策略。网络错误会结束查询；手动查询保留已收到的
释义并显示错误，制卡查询返回错误，不保存不完整结果。

LunaTranslator 发来的 `dictionaryInfo`、`dictionaryContent` 直接丢弃，
不解析、不保存。制卡时通过 `zr-dictionary-lookup` 使用 Emacs 自带的 `dictionary.el`
查询单词，将命中阶段的
全部释义追加到背面。每个词典默认使用 `*** [数据库 id]` 子标题，
id 为 `unknown` 时使用完整词典名；多个词典分别分段，同一显示名称的多条释义放在同一子标题下。
首个词典标题前加入原词的 dict link，释义中的 `{词语或短语}` 转成 dict link，
换行短语合并为空格。生成的链接保存本次词典列表和策略，follow 时重新查询。

```org
** Back
一个小村庄

[[dict:hamlet?dictionaries=%28%22%2A%22%20similar%29&strategy=.][hamlet]]

*** [dictd-db-eng-zho]
hamlet
村
A small village or a group of houses.

*** [dict-db-wordnet-542]
hamlet
    n 1: a community of people smaller than a village
```

可通过 `zr-dictionary-name-function` 自定义标题。
函数接收 `(name id source)`，其中 `source` 是包含 `:server`、`:port`、
`:dictionary`、`:proxy` 的解析后配置，返回不含开头星号的单行标题。例如始终显示完整名称和 id：

```elisp
(setq zr-dictionary-name-function
      (lambda (name id _source) (format "%s [%s]" name id)))
```

用 `zr-dictionary-dictionaries` 配置制卡与 `zr-dictionary-search` 的查词顺序，独立于原生查词的
`dictionary-default-dictionary`：

```elisp
(setq zr-dictionary-dictionaries
      '((:server t :port t :dictionary (dict1 dict2))
        (:server t :port t :dictionary dict3)
        similar)
      zr-dictionary-strategy ".")
```

先查询 `dict1` 和 `dict2`，合并两者返回的全部释义；只要其中一个有结果，
就结束查词。两者都未命中才查询 `dict3`。所有精确查询都未命中，才执行最后的
`similar`：按原顺序重试这些词典组，使用 `zr-dictionary-strategy`（默认 `.`）获取每个词典的
第一个候选词，再查询候选词在其所属词典中的释义。同组的结果合并，整组未命中
才继续下一组；不尝试第二个候选词。例如 `reserved` 匹配到 `reserve` 时，
背面填入 `reserve` 的释义，卡片标题和原有词语仍保留 `reserved`。

外层是阶段列表；每个阶段是查询目标 plist，或同组目标的列表。
只接受 plist 目标，不再支持裸词典 id 或旧的 id 分组格式。
`:dictionary` 可以是单个 id 或非空 id 列表，id 可写成 symbol 或字符串：

```elisp
(setq zr-dictionary-dictionaries
      '(((:server "localhost" :port 2628 :dictionary (edict local) :proxy nil)
         (:server "dict.org" :port 2628 :dictionary (gcide wordnet) :proxy "127.0.0.1:7890"))
        (:server "backup.example" :port 2628 :dictionary "*")
        similar))
```

此配置先查询同组的四个字典，全部未命中才查询备用服务器。
同一服务器、端口和代理在一次查询中共用连接，依次查询字典；不同连接并发查询。
全部精确阶段未命中才进入 `similar`，候选词始终在返回它的服务器上继续查询。
`:server` 只有字符串才指定服务器，`:port` 只有数字才指定端口（1–65535 的整数）；
其他值（包括 `nil`、`t`）或省略字段时，分别使用 `dictionary-server`、`dictionary-port`。
`:proxy` 字符串以 `host:port`（IPv6 为 `[地址]:port`）指定 HTTP 代理；
`nil` 表示直连，`t` 或省略字段时沿用 `dictionary-use-http-proxy`、
`dictionary-proxy-server` 和 `dictionary-proxy-port`。
跨服务器查询的默认标题带地址和端口，
例如 `[gcide@dict.org:2628]`，区分同名数据库。
结果 buffer 和历史保存展开后的地址、端口、字典和代理配置。
生成的 dict link 默认只保存词典 id、阶段和策略，follow 时使用当时的默认服务器。
需要链接保留服务器配置时，设置：

```elisp
(setq zr-org-link-dict-include-server t)
```

启用后生成的链接携带解析后的地址和端口，之后修改默认服务器不会改变这些链接的目标。
代理默认不写入链接，启用保存服务器配置时也是如此。

默认配置为 `'((:server t :port t :dictionary t :proxy t))`。
`:dictionary t` 等价于 `:dictionary ("*" similar)`：先查全部数据库，
全部精确阶段未命中后，只为这个目标查询相似词。
`:dictionary (gcide wordnet similar)` 则为同组的这两个字典启用相似查询。
外层末尾的 `similar` 为所有之前的阶段启用相似查询。
`"*"` 查询全部数据库，`"!"` 使用第一个命中的数据库。
使用显式 id 且不带 `similar` 就只做精确查询，整个变量设为 `nil` 则跳过查词。
所有阶段都未命中时，仍保存单词、翻译和其他内容。

服务地址和端口使用现有的 `dictionary-server`、`dictionary-port` 配置，例如：

```elisp
(use-package dictionary
  :custom
  (dictionary-server "localhost")
  (dictionary-port 2628))
```

如果 `dictionary-server` 未设置，制卡使用 `localhost`。
需要有可用的 DICT 服务；查询使用独立连接，不打开 Dictionary 窗口，
也不改动已有 Dictionary 缓冲区及其连接，不受 `dictionary-use-single-buffer` 影响。

`zr-org-link.el` 位于 `org/`，依赖 `zr-dictionary.el`。执行 `zr-org-link-mode` 启用
dict link 的 follow、store 和导出；关闭时恢复原先的链接处理函数。
`[[dict:word]]` 使用当前 buffer 的配置，可在链接查询参数里覆盖 `dictionaries` / `strategy` / `proxy`：

```org
[[dict:reserved?dictionaries=%28%28%3Adictionary%20%28dict1%20dict2%20similar%29%29%29&strategy=prefix][reserved]]
```

`dictionaries` 是经过 URL 编码的 Lisp 阶段列表；上例解码后为
`((:dictionary (dict1 dict2 similar)))`。词语、参数值含空格、中文或 `?&%` 时也用 URL 编码。
可调用 `(zr-org-link-dict-link "reserved" '((:dictionary (dict1 dict2 similar))) "prefix")`
生成链接。在查询结果 buffer 中用 `org-store-link` 保存当前查询及其配置。
独立的 `proxy` URL 参数覆盖所有目标的代理配置，与参数顺序无关：

```org
[[dict:reserved?proxy=127.0.0.1:7890][reserved]]
[[dict:reserved?proxy=nil][reserved]]
```

字符串使用 `host:port`（IPv6 为 `[地址]:port`），`proxy=nil` 直连，
`proxy=t` 沿用全局代理设置。省略 `proxy` 时使用词典配置中的代理。
生成链接时默认省略代理；为 `zr-org-link-dict-link` 显式提供第四个参数才会加入：

```elisp
(zr-org-link-dict-link "reserved" '((:dictionary (dict1 dict2 similar)))
                       "prefix" "127.0.0.1:7890")
```

第四个参数显式传入 `nil` 或 `t` 时，分别生成 `proxy=nil` 或 `proxy=t`。
导出时仍生成翻译 URL，只使用查询词语。

按文件选择词典，直接在目标 Org 文件的**第一行**设置标准文件局部变量：

```org
# -*- zr-dictionary-dictionaries: ((:dictionary (dictd-db-eng-zho gcide)) (:dictionary wordnet) similar); -*-
#+title: 英語
```

也可以在 deck 目录或其父目录的 `.dir-locals.el` 中配置，适用于该目录下的
Org 文件和子目录中的 deck，包括之后创建的文件：

```elisp
((org-mode . ((zr-dictionary-dictionaries
              . ((:dictionary (dictd-db-eng-zho gcide))
                 (:dictionary wordnet) similar)))))
```

文件局部变量优先于目录局部变量；两者都未设置时使用全局
`zr-dictionary-dictionaries`。变量通过 `zr-dictionary-dictionaries-p` 注册了
`safe-local-variable`：结构和值合法的 plist 配置可以直接作为文件或目录局部变量，
无需逐项加入 `safe-local-variable-values`；该谓词不会建立连接或执行配置中的 Lisp。

修改第一行或 `.dir-locals.el` 后，在已打开的 deck buffer 中执行
`M-x normal-mode`，或关闭后重新打开文件，使设置生效。
新配置会用于之后创建的卡片。要覆盖已有卡片的词典，在 deck buffer 中执行
`M-x zr-org-srs-x-update-dictionaries`：无选区时更新光标所在卡片，光标可位于
正面、背面或释义中；有选区时更新与选区相交的所有卡片。
命令以卡片标题查词，使用当前 buffer 的 `zr-dictionary-dictionaries` 和
`zr-dictionary-strategy`、`zr-dictionary-name-function`，替换查询链接及
`Front` / `Back` 下的三级词典子标题；
没有词典子标题时追加到 `Back`。其他正文和复习日志保留。
配置为 `nil` 或全部未命中时移除旧释义；查询或更新失败时撤销整批修改。
修改留在 buffer 中，确认后用 `C-x C-s` 保存。

查询超时或服务错误会让 `addNote` 返回错误，
不保存新卡片；全部阶段共用一个超时，默认为 10 秒，可通过
`zr-dictionary-timeout` 修改。
原有 `zr-org-srs-x-dictionaries`、`zr-org-srs-x-dictionary-timeout`、
`zr-org-srs-x-dictionary-name-function` 已移除，配置与文件局部变量需使用上述新名称。

## 手动制卡与 Org protocol

从 `zr-dictionary-search` 的查询结果中制卡，可添加 capture 模板：

```elisp
(with-eval-after-load 'org-capture
  (add-to-list 'org-capture-templates
               (zr-org-srs-x-capture-template "d" "词典制卡")))
```

加载 `zr-org-srs-x` 后，也可以在结果 buffer 中直接按 `c` 打开这个 capture，
无需注册或选择模板。

在结果 buffer 中执行 `org-capture` 并选择 `d`，默认取光标所在词典的完整释义；
有 region 时取与选区相交的所有词典，合成一张卡。直接复用已显示的查询结果，
不重新查词，保留词典标题，并将 `{词语或短语}` 转成 dict link。
使用 `zr-org-srs-x-model-alist` 的 `t` 项渲染，`word` 是原查询词；
目标为 `t` 项的 `deck`，未配置时使用 `zr-org-srs-x-default-deck`。
默认 Back 包含查询 dict link，链接保存原查询的词典阶段和匹配策略。
可在 capture buffer 中编辑，`C-c C-c` 保存，`C-c C-k` 取消。
候选词列表和没有释义的位置不能制卡。

`M-x zr-org-srs-x-create-card` 输入一个词或短语即可制卡。选区或光标下的词作为
输入默认值；在 deck buffer 中使用 `t` 项配置的 deck，未配置时使用当前 deck。
在其他 buffer 中会提示选择 deck，允许输入新名称；`C-u` 始终提示选择 deck。
命令保存卡片并定位到新卡，使用 Org-srs 的 ID 和复习记录。
默认 Front 是输入的词，Back 是词典释义。

手动与协议制卡没有 model name，使用 `zr-org-srs-x-model-alist` 的 `t` 项，
只提供 `word` 字段，可以自定义 `name/front/back`，例如：

```elisp
(setq zr-org-srs-x-model-alist
      '((modelofluna
         . ((deck . "Luna")
            (dictionaries . ((:server t :port t :dictionary (edict local similar))))
            (name . ("%s" .word)) (front . ("%s\n\n%s" .word .example_sentence))
            (back . ("%s\n\n%s" .remarks dictionary))))
        (t . ((deck . "Words::English")
              (dictionaries . ((:server t :port t :dictionary (gcide wordnet similar))))
              (name . ("%s" .word)) (front . ("%s" .word))
              (back . ("%s" dictionary))))))

;; 程序调用返回卡片的整数 ID；显式 deck 优先于模型配置。
(zr-org-srs-x-create-card "hamlet")
(zr-org-srs-x-create-card "village" "Words::Other")
```

启用协议入口：

```elisp
(zr-org-srs-x-protocol-mode 1)
```

向运行中的 Emacs server 发送 URL：

```sh
emacsclient 'org-protocol://srs-card?word=hamlet&deck=Words%3A%3AEnglish'
```

`word` 必填，`deck` 可省略，此时使用 `t` 项的 deck 或
`zr-org-srs-x-default-deck`（默认 `"Default"`）。参数值使用 URL 编码。
协议入口自动保存卡片；加载模块时不会注册此入口，关闭 mode 会移除注册。
两个入口都能创建新 deck，读取目标文件和目录的局部配置，按标题检查重复，
查询或保存失败时不留下新卡。启用和关闭 HTTP 服务不影响协议入口。

`zr-org-protocol.el` 和其测试已移到 `org/`；Windows 的系统协议注册可用
`M-x zr-org-protocol-register-windows`。启用制卡协议不需要启用导入 Cookie 的
`zr-org-protocol-mode`。

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
         . ((name . ("%s" .word))
            (front . ("%s\n\n%s\n\n%s" .example_sentence picture audio))
            (back . ("%s\n\n%s" .remarks dictionary))))
        (t . zr-org-srs-x-render-default-note)))
```

`name` 是 Org 卡片标题，`front` 和 `back` 是正反面的 Org 文本。三项都必须提供，
标题不能为空。`t` 项处理未单独配置的模型；默认函数用第一个字段作为标题和
正面，其余字段及词典释义放到背面。省略 `t` 时，未配置的模型返回错误。

每个模板可以是字面字符串、`(FORMAT 引用...)` 列表或函数。
格式列表的第一项是 Emacs `format` 格式字符串，后续项是引用符号；
`.word` 按字段名 `"word"` 取值，`dictionary` 等普通符号取内置结果。
引用作为数据解析，配置无需 `let-alist`，也不会执行 Lisp 表达式。
缺失字段或没有对应附件时，引用值为 `""`。

模板 alist 还支持两个可选项，默认均为 `nil`：

| 配置项 | 含义 |
| --- | --- |
| `deck` | 此模型的默认 deck；添加时显式传入 deck（Anki 的 `deckName` 或协议的 `deck`）优先 |
| `dictionaries` | 此模型的词典阶段列表，格式与 `zr-dictionary-dictionaries` 相同；`nil` 或省略时使用 global |

查词配置优先级为目标 deck 的 local → 模型 alist → global。
local 包括文件、目录局部变量和 buffer-local 配置；local 的 `nil` 表示禁用查询。
Back 格式列表的参数包含 `dictionary` 才查词；省略该参数即可跳过查询。
字面文本中的 `dictionary` 和字段引用 `.dictionary` 不触发查词。
函数渲染器和函数 Back 模板会接收词典结果。
生成的 dict link 保存实际使用的词典列表和策略。

| 引用 | 内容 |
| --- | --- |
| `.字段名` | 该字段转成 Org 的文本；没有该字段时为空字符串 |
| `dictionary` | dictionary.el 返回的全部释义 |
| `picture` | 本条笔记导入的全部图片链接 |
| `audio` | 本条笔记导入的全部音频链接 |
| `video` | 本条笔记导入的全部视频链接 |

格式列表用 `%s` 插入引用值，用 `%%` 输出字面 `%`。普通字符串按原文使用，
其中的 `%` 和 `$` 不需要转义。字段和释义作为格式参数，其内部的 `%s`、`$`
或反斜杠不会再次解释。附件链接也会追加到请求指定的字段中，例如 `.audio_for_word`；
同时使用该字段和 `audio` 会显示两次同一个附件。
查词使用 `word` 字段，没有时使用模型的第一个字段。
原有字符串占位符模板需迁移成格式列表，例如 `"$.word"` 改为 `("%s" .word)`。

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
make test TEST_FILE='test/zr-dictionary-test.el org/test/zr-org-link-test.el org/test/zr-org-srs-x-test.el org/test/zr-org-protocol-test.el test/zr-module-loading-test.el'
make check-parens FILE='zr-dictionary.el org/zr-org-link.el org/zr-org-srs-x.el org/zr-org-protocol.el'
make byte-compile FILE='zr-dictionary.el org/zr-org-link.el org/zr-org-srs-x.el org/zr-org-protocol.el'
make clean
```

测试使用临时目录和本机随机端口；涉及 Org-srs 的测试加载已安装的包，
未安装时跳过这些测试。
