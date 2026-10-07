# App API：`window.mediacraft`

页面对外唯一的稳定接口。测试、AI 会话（本机 Claude Code 或 Codex）与外部 Agent 的 MCP 服务（[mcp.md](mcp.md)）都只通过它读写稿子、出图、导出和发送，不碰页面内部的名字。接口实现在 `src/api/`（`api.js`，图片与实况 `media.js`，配色 `palettes.js`），由 `src/app.js` 接到各模块上（稿子 `src/drafts/`、出图 `src/stage/`、主题与字体 `src/themes/`、图片与实况 `src/media/`……）。

## 约定

- **版本**：`mediacraft.version === "5"`。只加字段、加方法不升版本；改名、删除、改语义（参数、返回形状、行为）都算破坏性改动，必须升 `version` 并更新本文。变更记录见下面的[版本变更](#版本变更)。
- **异步**：除 `on` 外所有方法都返回 Promise，出错时 reject 一个带中文原因的 `Error`（参数不对是 `TypeError`，下标越界是 `RangeError`）。
- **可序列化**：参数与返回值都是 JSON 能表示的数据，AI / MCP 可以直接收发。例外只有标注 **〔页内〕** 的方法：它们收 `File` / `Blob` 或返回 `HTMLCanvasElement`，只能在页面里调用。
- **会出图的方法**在返回前都会等最新一次出图画完（并取消界面里还没到点的防抖出图），返回后预览就是最终画面。
- **只读稿子**：内置说明书（`readOnly: true`）不能改；改它的方法会 reject。
- **坐标**：卡片是 864 × 1152 的逻辑像素，预览画布是 2 倍图（`pixelRatio: 2`）。
- **原生桥**：下面各节的「页面与壳之间」都是 `POST mediacraft://app/__native/<动作>`，每次都带请求头 `X-MediaCraft-Bridge: 1`（`src/native-bridge.js` 统一加上）；不是 POST、不带这个头的请求壳一律回 403，卡片样式里的 `url()`、图片地址这类浏览器自己发的请求碰不到原生能力。
- **源码范围** `source: [start, end]`：这块内容在 Markdown 正文里的字符偏移（UTF-16），半开区间；算不出时为 `null`。

### 版本变更

- `"5"`：AI 后端可以是 Codex（[ADR 0008](adr/0008-ai-backend-claude-or-codex.md)，见 [ai](#aiai-会话本机-claude-code-或-codex)），生图只剩 OpenAI。
  - `ai.imageSettings().provider` 总是 `"openai"`，`ai.setImageSettings({ provider })` 只收 `"openai"`（或不给），别的是 `TypeError`；v4 还能选 `"gemini"`。存下的偏好里选过 Gemini 的读成 OpenAI 的默认模型。
  - `ai.newSession()` 是「重新开始这篇的对话」：除了 v4 的清空，还解锁这篇的后端（有了对话后只有这样才能换后端）。
  - 用 Codex 时生图是它自带的：生成的图直接成为配图候选（会话里的 `candidates`），`history().generating` 多了 `byBackend: true`，这时 `ai.stopImages()` 停掉整轮（没法只停生图）。
  - 只加的：`ai.backends()`、`ai.setBackend()`、`ai.models()`；`status({ backend })`、`setPath(path, backend)`；`model()` / `setModel()` 返回多了 `backend`；`history()` 多了 `backend`、`locked`；`status` 事件多了 `backend`。
  - 后来又加的（不升版本）：`ai.sessions()`（会话历史）；`AIStatus` 多了 `reason`；模板库：`drafts.templates()`、`drafts.create({ template })`、`drafts.saveAsTemplate()`、`drafts.removeTemplate()`、`drafts.revealTemplate()`，`drafts.get` / `firstPage` 认得模板的 id（见 [drafts](#drafts稿子)）。
- `"4"`：小红书正文（发布时图片下面的那段）和卡片内容分开了，稿子多了 `caption` 字段（见 [drafts](#drafts稿子)）。
  - `output.sendToIPhone()` 在图文卡片模式下剪贴板放 `caption`（空着时不动剪贴板），不再是卡片内容的纯文本；长文照旧放全文的纯文本。返回值多了 `copied`。v3 里剪贴板总是 `render.plainText()`。
  - `render.plainText()` 只是卡片内容（长文是全文）的纯文本，界面上是「复制卡片文字」（长文里是「复制全文」）；小红书正文的字数按 `caption` 算。
  - `ai.review` 的修改多了 `kind: "caption"`（正文栏整段一处，`source` 为 `null`），排在标题之后、卡片内容之前；`ai.preset("caption")` 写小红书正文。
- `"3"`：
  - `media.insertLivePhoto(file, options?)` 不再弹实况编辑器，按给的设置直接做成实况插入，设置多了 `crop`（取景框），见 [media](#media图片与实况)。v2 里它走实况编辑器。
  - `render.plainText(markdown?)` 的规则换成解析树推出的纯文本（`src/engine/plain-text.js`）：去掉行内标记、图片与分页符，列表留编号、表格留成竖线表、链接写成 `[文字](网址)`，原文隔着空行的块之间空一行。v2 只是去掉图片、分页符与各种标记，列表、表格、链接的写法不同。发送到 iPhone 的剪贴板与正文字数随之变化。
  - `ai.answer(requestId, "session")`：只在 claude 给了「以后不再问」的建议时可用（`AIPermission.scope` 不空），没有建议时 reject，不再退而放行整个工具；回答没送到 Claude 时 reject，这一轮随之以「权限回答没送到」结束（见 [ai](#aiai-会话本机-claude-code-或-codex)）。
  - `themes.swatches()` 不再是固定的 8 个字色、8 个高亮，改成由当前稿子的配色推出来的各 5–6 个（见 [themes](#themes--fonts主题与字体)）。
  - `drafts.remove(id)` 连同这篇的 AI 工作副本与配图候选一起删（Claude Code 自己的会话记录不删）；工作副本没删掉时稿子照样删了，reject 说明原因。
  - 辅助色、衬底「单独调过」改用显式标记 `Draft.tunedColors`（新字段），不再看值是否等于三色规则的值：`drafts.update` / `palettes.apply` 里给了的辅助、衬底就算单独调过（值恰好和三色规则一样也算），之后改底色、正文色时不再跟着变；`update` 也可以直接给 `tunedColors`（见 [drafts](#drafts稿子)）。
- `"2"`：AI 改的稿子不再直接落进正文，先逐处确认（[`ai.review`](#修改对比aireview)）；`TurnResult` 与 `turn` 事件的 `edited` 换成 `changes`（这一轮改了几处），`turn` 事件不再有 `applied`；会话记录结尾的 `pending` / `conflict` 换成 `review`。

## 事件

`mediacraft.on(type, handler) → unsubscribe()`

| 事件 | 何时触发 | handler 收到 |
| --- | --- | --- |
| `change` | 当前稿子存盘后与上次不同（含切换到另一篇） | `{ draftId }` |
| `rendered` | 一次出图画完（被更新的出图取代的那次不触发） | `{ draftId, mode, pageCount }`（长文模式 `pageCount` 为 0） |
| `ai` | AI 会话有动静（任何一篇稿子的），见下面 [ai](#aiai-会话本机-claude-code-或-codex) | `AIEvent` |
| `save-state` | 当前稿子的存盘状态变了（见 [drafts](#drafts稿子) 的 `saveState`）；`saveNow()` 之后总会发一次（`explicit: true`） | `SaveState & { explicit }` |

## drafts：稿子

稿子由稿件模块（`src/drafts/`）存在本机，布局、上限与旧稿子迁移见 [storage.md](storage.md)。首次启动要先搬旧稿子，搬完、打开第一篇之前调用的方法会先等着。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `limit` | 自己的稿子最多几篇（属性，不是方法） | `1000` |
| `list()` | 所有稿子，含内置说明书 | `DraftSummary[]` |
| `get(id)` | 读一篇（不切换）；没有时为 `null` | `Draft \| null` |
| `current()` | 正在编辑的这篇 | `Draft` |
| `create(init?)` | 新建并切过去；`init` 同 `update` 的字段，另可带 `template`（模板的 id 或名字，见 `templates()`）：先照模板复制一份（卡片内容、标题、小红书正文、主题、配色、字体、封面、图片都照它），再套用其余的字段；没有这个模板时 reject。不带 `template` 时是空白稿子，沿用上一次选的主题。到上限时 reject（不删旧稿） | `Draft` |
| `templates()` | 模板库：仓库自带的（`src/templates/*.md`，按登记表顺序在前）与自己存的（App 支持目录「模板」文件夹，每次都重新读目录；浏览器里没有），见[模板](#模板原生桥) | `Template[]` |
| `saveAsTemplate({ name, description?, tags? })` | 把正在编辑的这篇存成自己的模板：写进「模板/<名字>/模板.md」+ 图片文件（画面存成文件，实况只存封面那张；随网页打包的图片先取回来）；存的是卡片内容、标题、小红书正文、主题、配色（背景、文字、强调与单独调过的辅助、衬底）、字体（不跟随主题的）、封面与图片，不存字号、行距、卡片样式。`name` 1–40 字，不能有 `/ \ :` 与控制字符、不以 `.` 开头（`TypeError`）；同名的整套换掉。内置说明书、浏览器里 reject | `Template` |
| `removeTemplate(id)` | 删自己存的那一套（整个文件夹）；自带的 reject | — |
| `revealTemplate(id?)` | 在 Finder 中显示自己存的那一套的文件夹；不给 `id` 时打开模板文件夹（不在时先建好）；自带的 reject | — |
| `open(id)` | 切换到这篇 | `Draft` |
| `remove(id)` | 直接删除（不弹确认框；界面上的删除按钮仍会先确认），连同它的图片、实况视频与 AI 的工作副本、配图候选（[storage.md](storage.md#ai-的工作副本)）；后端自己的会话记录（`~/.claude/projects/`、`~/.codex/sessions/`）不删。工作副本没删掉时稿子照样删了，reject 说明原因 | — |
| `update(patch, options?)` | 改当前稿子的任意字段，出图并存盘（返回时已写进本机，写不进时 reject）；先整体校验，不会只改一半。`options.undoable: true` 时正文与改了的字段（标题、小红书正文、模式、主题、配色、字体、字号、行距、图片最大高）合成撤销历史里的一步，⌘Z / `undo()` 一起撤回（App 的工具与外部 Agent 都这样改）；不给时只有正文的改动进撤销历史 | `Draft` |
| `firstPage(id)` 〔页内〕 | 这篇（不切换过去）的第一张卡片：按它自己存下的正文、主题、配色、字体与图片出图，不管它的模式，署名用现在的；正在编辑的这篇按界面上的样子；模板的 id 也认（画廊的缩略图，用户模板的图片这时才读进来）。只画第一页；不改稿子、不等预览出图。手机预览的发现页、主页用它画别的稿子的首图。没有这篇时 reject | `{ pageCount, canvas }`（没有内容时 `canvas` 为 `null`） |
| `undo()` / `redo()` | 撤销 / 重做正文的改动（与 ⌘Z / ⇧⌘Z 相同）；图片的版式、裁剪和正文在同一条撤销历史里 | `Draft` |
| `saveState()` | 当前稿子的存盘状态（顶栏的保存按钮显示的就是它） | `SaveState` |
| `saveNow()` | 马上存（与点保存按钮、⌘S 相同）：不再等自动存、写进本机后返回；之前没存上过就整篇重写；写不进时 reject 原因。内置说明书什么都不做 | `SaveState` |

**存盘**：界面上的改动（正文、标题、小红书正文、样式、封面、卡片样式、图片、主题、模式、署名）由稿件模块过一会儿自动存进本机：停手约 0.4 秒，一直在改时至少每 2 秒一次，不等出图（出图失败或很慢时照样存）；出图画完后也顺手存一次（没变就不写）。没存上时 5 秒后自动再试，改动留在内存里。App 里壳在退出、关窗、⌘R 重新载入（以及更新重启）之前让每个窗口的页面 `saveNow()`（各最多等 3 秒）。

`SaveState`：`{ status, savedAt, error, draftId }`。`status`：`"saved"` 都存好了；`"pending"` 有改动、过一会儿就存；`"saving"` 正在写；`"error"` 没存上（`error` 是原因）；`"none"` 没有要存的（内置说明书、正在换稿子）。`savedAt` 是最近一次写好的时间（毫秒；刚打开时是这篇的修改时间）。

`Draft`：

```js
{
  id, title,            // title 是这篇自己填的标题，没填为 ""
  caption,              // 小红书正文：发布时图片下面的那段（纯文本，可以有 #话题、emoji、换行），和卡片内容分开写；没写为 ""
  markdown,             // 卡片内容（长文是全文），唯一的底层格式
  mode,                 // "cards" 图文卡片 | "article" 长文
  theme,                // 主题 id，见 themes.list()
  colors: { bg, text, accent, secondary, surface },   // #rrggbb；这篇的配色（在主题配色上调过的），见下面 palettes
  tunedColors,          // 单独调过的辅助、衬底：["secondary"]、["secondary", "surface"]……；没列出的按三色规则跟着底色与正文色走
  fonts: { zh, en, code },        // 字体 id，见 fonts.list()；"theme" = 跟随主题
  fontSize, lineHeight, imageMaxHeight,  // 正文字号、行距、图片最大高（逻辑像素）
  cover: { enabled, subtitle, image },   // 首页做封面（默认关）、副标题（最多 60 字）、底图（这篇的图片 id，null 不要），见下
  cardCss,                               // 这一篇自己的卡片样式（CSS 文字，最长 20000 字），只作用在 HTML 卡片上，见下
  readOnly,             // 内置说明书为 true
}
```

**小红书正文**（`caption`，编辑区标题下面的「正文」栏，只在图文卡片模式下显示）：手机预览里标题下面显示它，发送到 iPhone 时它进剪贴板，「正文 x/1000」数的是它（空白不计，emoji 这类增补平面字符算 2 个字），话题从它里面取，发布检查也查它（见 [publish-check.md](publish-check.md)）。不影响卡片画面，改它不重排。这版之前的稿子没有，读出来是 `""`。

`update(patch)` 的 `patch` 可含上面除 `id`、`readOnly` 外的任意字段（`colors`、`fonts`、`cover` 可只给其中几项）。`colors` 正好给了 `bg`、`text`、`accent` 三个、没给 `secondary`、`surface` 时算三色配色，辅助色与衬底按[三色规则](#五个颜色角色)推出来，记为没单独调过；否则给了的换掉，给了的辅助色、衬底记为单独调过（`tunedColors`），没单独调过的跟着新的底色、正文色重新推（和检查器里改色块一样），其余不动。给了 `tunedColors`（只能列 `secondary`、`surface`，别的是 `TypeError`）就按它记，没列出的按三色规则推。同时给 `theme` 与 `colors` 时，先换主题（配色重置为主题配色、都没单独调过），再套用给的颜色。认不出的字体 id 按「跟随主题」处理；数值超出范围时按界面上的上下限截断。

**卡片样式**（`cardCss`，检查器的「高级 · 卡片样式」）：这一篇自己的 CSS，接在内置卡片样式后面、关在每张卡片的 Shadow DOM 里，不影响 App 界面；进卡片前去掉 `@import`、外部地址（只留 `data:` 图片）。每页是 `.mc-page`（`data-structure` 卡片结构、`data-kind` 为 `cover` / `body` / `end`），正文区 `.mc-body`，组件见 [markdown-syntax.md](markdown-syntax.md#组件html-卡片名字--)。经典引擎不用它。`undoable` 时进撤销历史。

**封面**（`cover`，检查器的「封面」）：`enabled` 为 `true` 时第 1 张是封面、正文从第 2 张开始（正文页都按内页排）。封面的标题取 `title`，空着时取正文第一行字；副标题是 `subtitle`（空着不显示）；`image` 是这篇里的一张图或实况（可以不在正文里），给了没有的 id 时 reject（`drafts.create` 在建稿之前就 reject）。各项类型不对是 `TypeError`。封面的样子随卡片结构（`src/engine/structures.js` 的 `cover`），规则见 [markdown-syntax.md](markdown-syntax.md#封面首页做封面)。

`DraftSummary`：`{ id, title, mode, updatedAt, builtIn, current }`，其中 `title` 是稿件抽屉里显示的名字（没填标题时取正文第一行的文字，最多 24 字）；`list()` 里内置说明书在前，自己的按最近修改在前（只是打开不算修改）。

**模板**（`Template`：`{ id, name, description, tags, theme, builtIn }`）：`id` 自带的是 `template_<登记表里的 id>`（登记表里的 id 是 front matter 的 `id`，没写时是文件名，如 `template_干货清单`），自己存的是 `user_template_<名字>`；`tags` 是题材一个、风格一个（如 `["清单", "简洁"]`）；`theme` 是主题 id。模板不是稿子：不在 `list()` 与稿件抽屉里，`open(id)` reject，`get(id)` 读得到（`readOnly: true`，用户模板的图片这时才读进来），`firstPage(id)` 能画第一页，`create({ template })` 复制一份成自己的稿子。模板文件的格式与文件夹见[模板](#模板原生桥)。

**模板画廊**（`src/templates/gallery.js`，没有新的 API，全靠上面这几个方法）：稿件抽屉「新建」旁的「从模板新建」、空白稿子的空状态（正文空着、这篇能改时编辑区里浮着的「从模板开始」「看看说明书」，一开始打字就收起）打开对话框「从模板新建」；每格是那套模板经 `firstPage` 真实出的第一页（打开后逐个生成，看得见的先；自带的按 id 缓存，自己存的每次打开重出），顶上按题材 / 风格（`tags` 的第一个、第二个）筛，点一格（方向键挪过去回车也行）就 `create({ template })` 并关上。自己存的排在自带的后面，下面有「在 Finder 中显示」（`revealTemplate`）与「删除」（先确认，`removeTemplate`）。稿件抽屉里右键一篇自己的稿子 ›「存为模板…」弹出名字（预填稿子的名字）、说明、题材与风格（两个下拉列出已有模板的标签），确认后 `saveAsTemplate`（不是正在编辑的那篇时先切过去；同名的先问一句再换掉）。

## editor：编辑器

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `selection()` | 当前选区 | `{ start, end, text }` |
| `select(start, end = start)` | 聚焦编辑器并选中这段（Markdown 偏移） | `{ start, end, text }` |
| `focus()` | 聚焦编辑器 | — |

## render：出图

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `pages()` | 等预览画到最新（界面里还有没到点的出图就马上画，否则不重复出图）；长文模式没有分页，返回 `[]` | `PageSummary[]` |
| `refresh()` | 重新排版出一次图（比如字体加载完之后） | `PageSummary[]` |
| `canvases()` 〔页内〕 | 最近一次画完的预览画布，与 `pages()` 同序；不触发重新排版。HTML 卡片（ADR 0006）的画布要出图后才有像素，这里等出图完成再返回 | `HTMLCanvasElement[]` |
| `offscreen({ structure? })` 〔页内〕 | 按当前稿子另出一套图文卡片，不管当前模式；`structure` 可指定卡片结构（`tweet` / `swiss` / `book` / `knowledge` / `memo` / `nightReading` / `cyber` / `waste`，没登记的 reject）；`views` 是每页的卡片元素（没挂到页面上） | `{ pages: PageSummary[], canvases, views }` |
| `plainText(markdown?)` | 页脚「复制卡片文字」（长文里是「复制全文」）得到的纯文本：去掉行内标记、图片与分页符，列表留编号、表格留成竖线表、链接写成 `[文字](网址)`，原文隔着空行的块之间空一行（规则见 `src/engine/plain-text.js`）；长文发送到 iPhone 的剪贴板也按它（图文卡片发的是 `caption`）。不给参数时用当前卡片内容 | `string` |
| `articleHtml(markdown?)` | 长文的语义 HTML（不带排版样式；图片是 `<figure><img src alt></figure>`，实况的 `figure` 带 `data-live`，分页符与找不到的图不出现） | `string` |

`PageSummary`：

```js
{
  index, width: 864, height: 1152, pixelRatio: 2,
  structure,            // 这页用的卡片结构 id
  role,                 // "cover" 封面 / "body" 正文 / "end" 结尾页（[[结尾]] 之后）
  header,               // 这页有没有署名（封面、没有封面时的第一页、结尾页；画在哪里由卡片结构决定）
  contentBounds: { left, top, right, bottom },  // 正文区（封面是标题所在的区域）
  fill,                 // 正文区用了多少（0–1，两位小数）；封面为 null
  chars,                // 这页上的字数（各行文字与表格格子，空白不计，按 UTF-16 算，同小红书）
  overflow,             // 有一块放不下又拆不开，超出了正文区
  issues: [{ id, text }],  // 排版自检（src/stage/layout-check.js）：headingOnly 只有标题、sparse 正文不到正文区四分之一
                        // （封面、结尾页、最后一页不算）、dense 超过 300 字、overflow 溢出；text 是说给人和 Agent 的原因与建议
  items: PageItem[],    // 按绘制顺序
  imageHits: [{ imageId, live, x, y, width, height, baseWidth, maxWidth, resizeMaxWidth, source, cover }],
  dropTargets: [{ kind: "text-line" | "block", imageId, y, height, source }],  // 预览里拖放图片的落点
}
```

`PageItem` 都有 `kind, x, y, width, height, source`，另按种类带：

| kind | 额外字段 |
| --- | --- |
| `text`（一行文字） | `blockType`（`p` / `h1` / `h2` / `h3` / `quote` / `li` / `code`，封面上是 `title` / `subtitle`，`source` 为 `null`）、`text`、`marker`（列表编号或圆点，续行为 `null`）、`fontSize`、`runs: [{ text, bold?, italic?, code?, strike?, underline?, color?, bg?, link? }]`；`width` 是这一行可用的宽度 |
| `quote` | 一段引用在这一页上的框（竖线画在里面） |
| `rule` | 分割线占的那一行 |
| `code` | 一段代码块在这一页上的底框（代码逐行是 `blockType: "code"` 的 `text`，跨页时每页一个框） |
| `table` | `columns`、`cellWidth`、`rows: [{ header, height, cells: string[] }]`；跨页时每页第一行是重复的表头 |
| `image` | `imageId`、`live` |
| `imagePair` | `imageIds` |

`imageHits` 里 `cover: true` 的是封面的底图：`source` 为 `null`，预览里不能点选、拖动、缩放（在检查器的「封面」里换），`media.move` 挪的是正文里的那一张；实况做底图时它就是这页实况的图片框，导出、发送时封面是一张实况。

## engine：解析器

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `parse(markdown?)` | 把 Markdown 解析成块与行内语法树（写法见 [markdown-syntax.md](markdown-syntax.md)）；不出图、不存盘、不发事件。不给参数时解析当前正文 | `MarkdownDocument` |

解析器是纯函数（`src/engine/markdown.js`，页面里也可直接用 `window.MediaCraftEngine.parseMarkdown`），两万字的稿子每次解析约几毫秒，可以每次按键都整篇重解析。图文卡片由新的排版引擎用这棵树排版（`src/engine/layout.js`）、分页（`paginate.js`，含末页回填）、按卡片结构绘制（`src/engine/structures.js`、`paint.js`；封面与结尾页在 `cover.js`）；长文也用这棵树排版（`src/article/article.js`），配色、字体、字号行距跟随这篇的主题与微调。

树里所有 `source`、`…Source` 都是上面约定的源码范围（UTF-16 偏移，半开区间），可以直接 `markdown.slice(start, end)`。

```js
MarkdownDocument = { type: "document", source: [0, markdown.length], blocks: Block[] }
```

每个块都有 `type`、`source`（这块占的整行，含缩进与标记；一行被行内图片拆开时只算自己那一截）与 `blankLinesBefore`（它和上一块之间的空行数，第一块算稿子开头的空行；卡片上每个空行多留一些空白）。按 `type` 另带：

| type | 额外字段 |
| --- | --- |
| `heading` | `level`（1–6，卡片上 4–6 按 3 画）、`marker`（如 `"##"`）、`markerSource`、`contentSource`、`runs` |
| `paragraph` | `lines: Line[]`：相邻的几行，每行在卡片上另起一行 |
| `quote` | `lines: Line[]`，每行另有 `marker: ">"`、`markerSource`；单独一个 `>` 的行 `runs` 为空 |
| `list` | `items: ListItem[]`：紧挨着的列表项，有序、无序可以混在一个列表里 |
| `code` | `lang`、`text`（原文）、`contentSource`（空代码块为 `null`） |
| `table` | `columns`、`align: ("left" \| "center" \| "right" \| null)[]`、`header: Row`、`rows: Row[]` |
| `image` | 应用图片 `[[image:…]]` 有 `imageId`；标准 Markdown 图片 `![…](…)` 有 `path`、`alt`（按文件名找图由排版做） |
| `imagePair` | `imageIds: [甲, 乙]`、`ratio`（第三段原文，如 `"4x3"`，没写为 `null`；支持哪些比例由排版决定） |
| `rule`、`pageBreak`、`endPage` | —（`endPage` 是 `[[结尾]]`） |

- `Line`：`{ source, contentSource, runs }`，`contentSource` 是去掉标记和两端空白后的内容。
- `ListItem`：`{ source, marker, markerSource, ordered, number?, indent, contentSource, runs }`；`marker` 是原文（`"-"`、`"*"`、`"1."`、`"2)"`），`number` 只在有序时有，`indent` 是行首空白的字数（缩进不产生嵌套，留给以后用）。
- `Row`：`{ source, cells: [{ source, runs }] }`，行的 `source` 是整行，格子的 `source` 是去掉两端空白后的内容；行的格数可以少于 `columns`。
- `Run`（行内片段）：`{ text, source, bold?, italic?, strike?, code?, color?, bg?, underline?, link? }`，格式名与 `PageItem.runs` 相同，没有的格式不出现。`text === markdown.slice(source[0], source[1])`；两段之间跳过的字就是被隐藏的标记（`**`、`{{color:…|`、链接网址等）。格式相同、中间没有隐藏标记的相邻片段会并成一段。

## themes / fonts：主题与字体

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `themes.list()` | 全部主题，按主题面板里的顺序：备忘（默认）、纯白、手帐、柔光、陶土、杂志、撞色、纯黑、书卷、报刊（报刊共用书卷的卡片结构 `scroll`，只换黑白配色）；之前的八个主题不再有，用它们的稿子打开时换成接替的新主题（[storage.md](storage.md)） | `[{ id, name, label, structure, colors: { bg, text, accent, secondary, surface }, fonts: { zh, en, code } }]` |
| `themes.apply(id)` | 与主题面板里点选相同：换卡片结构、配色与跟随主题的字体（界面皮肤不变，跟随系统，ADR 0007），这篇调过的配色重置，记为新稿子沿用的主题 | `Draft` |
| `themes.preview(id)` 〔页内〕 | 当前正文换成这个主题会排成几页、第一页什么样（主题面板的缩略图）：卡片结构、主题配色与「跟随主题」的字体都用它的（就是当前主题时保留这篇调过的配色）。只画第一页；不改稿子、不等预览出图 | `{ pageCount, canvas }`（没有内容时 `canvas` 为 `null`） |
| `themes.swatches()` | 选中文字浮动条颜色菜单里的字色与高亮底色，由当前稿子的配色推出来（换主题、套配色、调色块后跟着变），规则见下 | `{ text: string[], highlight: string[] }`，各 5–6 个 |
| `fonts.list()` | 三个字体选单的选项，第一项是「跟随主题」 | `{ zh, en, code }`，每项 `[{ id, label, bundled, available, family, license }]`；`available: false` 是打包字体没下载，`family` 是出图用的 CSS 字体栈，`license` 是 `"ofl"`（打包字体，可商用）或 `"system"`（系统字体，仅限个人），「跟随主题」为 `null`（见 [publish-check.md](publish-check.md#字体许可)） |

主题的 `fonts` 是字体选「跟随主题」时用的字体 id（见 `fonts.list()`）；打包字体没下载时回退系统字体。有的主题另带标题字体（注册表里的 `titleFonts: { zh, en }`，不经 App API 读写）：中文或英文跟随主题时，卡片与长文的标题、封面标题用它，正文仍用 `fonts`；自己选了那种文字的字体，标题也用选的。

**字色与高亮的色块**（`src/themes/palettes.js` 的 `inlineSwatches`）：字色依次是强调色、辅助色（和正文色、强调色分得开时才有）、警示红（强调色本来就偏红时不要）、从强调色的色相（OKLCH）按 30° 一格转出的一个暖色与一个冷色，不够五个时补离已有色相最远的一格，最后是正文色退淡的「次要」；高亮是同样几种颜色的浅底（浅色卡片）或深底（深色卡片），最后是配色的衬底。字色对卡片底色、高亮底对正文色都至少 4.5:1，不够时只调明度；看不出差别的只留一个。已经写进正文的颜色（`{{color:#…|…}}`、`{{bg:#…|…}}`）不跟着变。

## palettes：配色库与色轮

检查器「样式」的「配色」：五个色块，加「配色库」「色轮」两个弹出面板（`src/workspace/palette-panel.js`）；配色的数据与计算在 `src/themes/palettes.js`。配色只改**当前这篇**（和色块一样），换主题时重置为主题配色；界面皮肤不跟着配色变，配色只用在卡片与长文上。

### 五个颜色角色

角色的名字、用处、对比度门槛、三色规则与颜色计算（OKLCH、对比度保护）只定义在 `src/engine/colors.js`（`MediaCraftEngine.colors`）；检查器的色块、主题面板、配色面板、浮动条的色块与 AI 工具的说明都从那里取，叫法只有这一套。

| 角色 | 名字 | 用在哪里 |
| --- | --- | --- |
| `bg` | 背景 | 卡片与长文的底色 |
| `text` | 文字 | 正文 |
| `accent` | 强调 | 列表编号与圆点、链接、引用竖线、页眉页脚的标签、结构的装饰线（长文里还有二级标题的竖线与三级标题） |
| `secondary` | 辅助 | 标题（卡片的 h1–h3，长文的一、二级标题） |
| `surface` | 衬底 | 引用块、表头、代码块与行内代码的底 |

- **三色规则**：只有 `bg`、`text`、`accent` 的配色（这版之前存的稿子、只给三色的 `update`、粘贴的三个色值），辅助 = 正文色，衬底 = 正文色 10% 叠在底色上。8 个主题的辅助色与衬底就是按这条规则取的值，所以主题原来的样子不变，只存了三色的旧稿子打开后也与主题配色一致。
- **单独调过**是显式标记（`Draft.tunedColors`，随稿子、版本与撤销历史一起存），不看值是否等于三色规则的值：改辅助、衬底的色块，`update` / `palettes.apply` 给了它们，就记为单独调过，之后不再跟着变；没单独调过的总是按三色规则从底色、正文色推出来，改底色或正文色（色块、`update`）时跟着重新推，像以前标题跟着正文色走一样。换主题、「恢复主题配色」、三色配色、粘贴色值里按三色规则补出来的角色都算没单独调过。这版之前存的稿子与版本没有这个标记：打开时按值推断一次（和三色规则的值不一样就算调过）。
- **对比度保护只有一套**（`src/engine/colors.js` 的 `withContrast`）：不够时色相、彩度不变，在 OKLCH 里把明度往远离底的方向调；门槛是正文 4.5:1、大字 3:1。配色本身（配色库、色轮、粘贴）按角色的门槛做：文字、强调对底 ≥ 4.5，辅助（标题）≥ 3，衬底上的正文 ≥ 4.5。
- **出图时的保护**（`src/engine/colors.js` 的 `roles`，同一个 `withContrast`）：正文对底 ≥ 4.5:1、衬底上的字对衬底 ≥ 4.5:1、标题对底 ≥ 3:1；用作文字的强调色按大字 3:1 保底（卡片上多是编号、圆点、粗体标签与装饰线，配出来的强调色本来就按 4.5 配，这里只是最后一道保底）。配色本身不改。公众号格式换成白底时（卡片结构有底板时正文写在底板上，也一样）：没单独调过的衬底对着新的底按三色规则重新推，调过的把与底色的差照样放到新的底上。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `list()` | 全部配色：内置的 48 组按分类在前，「我的配色」在后 | `Palette[]` |
| `apply(target)` | 套用到当前稿子，与点配色库里的一格相同：撤销历史里的一步（⌘Z / `drafts.undo()` 撤回，颜色与「单独调过」的标记一起），出图并存盘。`target` 是配色的 `id`、颜色对象（同 `update` 的 `colors`，可只给几个角色）或一串色值（`["#264653", …]`，至少三个，按下面的规则分给五个角色）。给了的辅助、衬底记为单独调过（配色库、我的配色都是五色）。内置说明书 reject | `Draft` |
| `save(name?)` | 当前稿子的五个颜色存进「我的配色」；名字最多 24 字，空着叫「我的配色 N」 | `Palette` |
| `remove(id)` | 从「我的配色」删掉一组；内置的、没有的 reject | — |
| `harmony({ base, rule, tone? })` | 纯函数：基准色 `base`（#rrggbb，取它的色相与彩度）按配色规则 `rule` 推出五个角色，再做对比度保护；`tone` 是 `"light"`（默认）或 `"dark"`。不改稿子 | `Harmony` |
| `preview(colors)` | 舞台先换成这组颜色看看（色轮拖动时用）：不改稿子、不存盘、不进撤销历史；`null` 回到稿子自己的配色。换主题、换稿子、套用配色时自动结束；导出的总是稿子自己的配色 | — |

`Palette`：`{ id, name, category, tone, colors: { bg, text, accent, secondary, surface }, builtIn }`。`category` 是 `morandi`（莫兰迪）/ `japanese`（日系）/ `film`（复古胶片）/ `nature`（自然）/ `neon`（霓虹赛博）/ `mono`（黑白极简）/ `mine`（我的配色），`tone` 是 `"light"` / `"dark"`（卡片底色的深浅）。内置配色都是自己配的：底色与正文 ≥ 7:1，强调 ≥ 4.5:1，辅助 ≥ 3:1。配色库的「适合当前主题」只列与当前主题（卡片底色）深浅一致的，不开时也把它们排在前面。

`Harmony`：`{ colors, contrast, adjusted, rule, tone, hues }`。`hues` 是色轮上各把手的色相（OKLCH，第一个是基准色）；`adjusted` 是对比度保护调过明度的角色；`contrast` 是每个角色的对比度 `{ ratio, minimum, pass }`：`text`、`accent` 对底色（至少 4.5），`secondary` 对底色（标题是大字，至少 3），`surface` 是衬底上的正文（至少 4.5）。

**配色规则**（色相在 OKLCH 里转，第一个把手是基准色，也就是强调色）：

| `rule` | 名字 | 把手 | 辅助 / 衬底 / 底色的色相 |
| --- | --- | --- | --- |
| `analogous` | 类比 | 0°、+30°、−30° | +30° / −30° / −30° |
| `complementary` | 互补 | 0°、180° | 180° / 180° / 0° |
| `split` | 分裂互补 | 0°、150°、210° | 150° / 210° / 0° |
| `triadic` | 三角 | 0°、120°、240° | 120° / 240° / 240° |
| `square` | 方形 | 0°、90°、180°、270° | 90° / 180° / 270° |
| `monochrome` | 单色 | 0° | 都是 0°，只差明度与浓淡 |

浅色配色的明度：底色 0.975、衬底 0.925、正文 0.25、强调 0.55、辅助 0.42；深色：底色 0.2、衬底 0.27、正文 0.94、强调 0.76、辅助 0.84。底色、衬底、正文只带一点基准色的彩度。**对比度保护**：正文、强调对底色不到 4.5:1，辅助不到 3:1 时，色相、彩度不变，把明度往远离底色的方向调；衬底上的正文不到 4.5:1 时调衬底。

**粘贴的色值**（色轮面板里的输入框、`apply([...])`）：色轮面板从粘贴的文字里只认 `#` 开头的 6 位或 3 位写法（`#264653`、`#abc`），没有 `#` 的一串数字或十六进制（电话、年份、Coolors 网址里的 `264653-2a9d8f-…`）都不算；`apply([...])` 的每一项要是 `#rrggbb`。重复的只算一次，至少三个。明度（OKLCH）的中位数 ≥ 0.5 就是浅色配色：最亮的当背景、最暗的当文字（偏暗反过来）；剩下不止一个时，和背景明度差不到 0.12 的那个当衬底；再剩下的按彩度从高到低当强调、辅助；缺的按三色规则推（记为没单独调过），最后做对比度保护。

## profile：署名

署名是全局的，不属于某一篇稿子。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `get()` | 当前署名 | `{ name, handle, avatar, avatarCrop }` |
| `update(patch)` | 改 `name` / `handle` / `avatar`（图片地址或 data URL）/ `avatarCrop`（`{ x, y, width, height }` 或 `null`）；换头像时裁剪清空 | 同 `get()` |

## media：图片与实况

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `list()` | 当前稿子的全部图片 | `MediaInfo[]` |
| `get(id)` | 一张图；没有为 `null` | `MediaInfo \| null` |
| `src(id)` | 画面本体：data URL 或随网页打包的相对路径 | `string \| null` |
| `import(files, { at? })` 〔页内〕 | 插入图片 / PDF（PDF 每页一张图，需在 App 里；最多 100 页，太细长的页按高度上限 16000 像素缩小），按文件名自然排序（`图2` 在 `图10` 前面）后每张一行插在 `at`（Markdown 偏移，默认光标处） | 新图片 id 数组 |
| `update(id, { name?, layout?, live?, crop? })` | 改名字、版式、实况设置或裁剪；`layout` 整个替换：`{ widthPercent?, fixedWidth?, fixedHeight?, align? }`，`null` 回到默认。`live` 只改给出的几项实况设置（同 `insertLivePhoto` 的选项，不含 `at`），封面跟着重截；不是实况时 reject。`crop` 是原图像素里的 `{ x, y, width, height }`，`null` 不裁。与界面上改一样是撤销历史里的一步 | `MediaInfo` |
| `move(id, { page, target, after? })` | 与在预览里拖动图片相同：移到第 `page` 页第 `target` 个落点（`pages()[page].dropTargets[target]`）之前或之后 | 是否移动了 |
| `insertLivePhoto(file, options?)` 〔页内〕 | 把视频（MP4、MOV）做成实况插在 `at`（默认光标处），不弹实况编辑器，按给的设置来，见下 | 新图片 id |
| `video(key)` | 实况视频本体的保存情况 | `{ key, memoryBytes, storedBytes }`（没有为 `null`） |

`MediaInfo`：`{ id, kind: "image" | "live", name, layout, crop, live? }`，实况另有 `live: { videoKey, videoName, duration, speed, start, coverOffset, sound }`。

实况的设置（`insertLivePhoto` 的 `options`、`update` 的 `live`；没给的用默认值）：

| 字段 | 说明 | 默认 |
| --- | --- | --- |
| `duration` | 成片几秒：3 / 5 / 8（别的值 `TypeError`） | 3 |
| `speed` | 倍速：1 / 1.5 / 2 / 3（别的值 `TypeError`）；成片 `duration` 秒要用原视频 `duration × speed` 秒 | 1 |
| `start` | 从原视频第几秒起；超出时挪到能放下这一段的最后位置 | 0 |
| `coverOffset` | 封面（卡片上静止时的那一帧、JPG 的画面）在起点之后第几秒，按原视频计 | 这一段的正中间 |
| `sound` | 成片带不带原视频的声音 | `true` |
| `crop` | 取景框 `{ x, y, width, height }`，0–1，按视频的显示方向（竖拍的 iPhone 视频是竖的）；`null` 是整幅画面 | 整幅 |

视频不够 `duration × speed` 秒时成片跟着变短（用到视频结尾）。实况在卡片上就是一张图：画面是按取景截下的封面，排版按它的比例；图片框比例不同时（固定宽高）居中铺满。界面上的实况编辑器（插入菜单、「/」菜单的「实况视频」，粘贴或拖进编辑区、舞台的视频，点实况卡片）改的是同样这些设置，另有取景比例的选择；舞台上的实况卡片翻到时在图片框里静音播一遍剪好的这段，指针停在图上时循环播放。

## output：导出与发送

实现在 `src/output/`。存进「下载」（App 里经原生桥保存，同名自动加序号，返回的 `filename` 是实际存下的名字；给了 `options.save` 时交给它存），文件名以稿子标题开头：标题里文件名不能用的字（`/ \ : * ? " < > |`）换成 `-`，没填标题时用稿件列表里的名字（正文第一行）。一次只做一件：进行中所有导出按钮停用，进度显示在顶栏下方的小卡片上；整组导出、长图与发送可以取消，取消时 reject「已取消」。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `exportPng(index, options?)` | 导出一页 PNG（`标题-01.png`，1728 × 2304）；实况页打包成 `标题-01.zip`，里面是 `标题-01.pvt/`（MOV、JPG、metadata.plist）。长文模式没有卡片，reject | `{ filename }` |
| `exportZip(options?)` | 整组打包（`标题.zip`），按页序放 `标题-01.png`、`标题-02.pvt/…` | `{ filename }` |
| `exportLongImage(options?)` | 长文长图（`标题.png`，宽 1080），不在长文模式时先切过去 | `{ filename }` |
| `sendToIPhone()` | 按页序交给隔空投送（普通页 `NN.png`，实况页 `NN.pvt`；长文是一张 `01.png`），拍摄时间按页序递增；小红书正文进剪贴板（图文卡片是 `caption`，长文是全文的纯文本），空着时不动剪贴板。发完的提示卡上「复制标题」「复制正文」「复制话题」分别复制标题、同一段正文与其中的 #话题。不经过发送前的发布检查（界面上的按钮才问，见 [publish-check.md](publish-check.md)）。只在 App 里可用 | `{ pageCount, copied }`（`copied`：剪贴板放了正文） |
| `copyArticle()` | 长文的公众号格式进剪贴板：只用行内样式的 HTML（深色主题换成白底深字，字体换成同类的系统字体）加 `render.plainText()` 的纯文本 | `{ html }` |

导出的 `options` 〔页内〕：`{ save }`，`save(blob, filename)` 返回实际存下的文件名，代替存进「下载」；进度卡片写「已导出」。外部 Agent 的 `export` 工具用它把文件交给壳，写进 Agent 指定的目录（[mcp.md](mcp.md)）。

**实况页**由壳合成（AVFoundation，[ADR 0004](adr/0004-native-live-photo.md)），所以含实况的导出与发送只在 App 里能做；浏览器里 reject 并说明要在 App 里导出（没有实况的卡片照常导出）。`.pvt` 里：

- `JPG`：1728 × 2304（和 PNG 一样大），卡片画面，图片框里是封面那一帧；Apple MakerNote 第 17 项是配对 ID。
- `MOV`：1440 × 1920、每秒 30 帧，HEVC（这台 Mac 编不了时 H.264）；卡片做底，视频按取景铺满图片框、切出和卡片一样的圆角，按倍速播 `duration` 秒；带声音时声音变速不变调。元数据 `com.apple.quicktime.content.identifier` 是同一个配对 ID，定时元数据 still-image-time 标在封面那一帧。
- `metadata.plist`：`{ PFVideoComplementMetadataVersionKey: "1" }`。

合成在壳的后台线程做，进度显示在进度卡片上；取消就是中止这次原生桥请求，壳随之停下。

### 实况合成（原生桥）

页面 → 壳：`POST mediacraft://app/__native/live-photo`，body 与成功时的回复都是带文件的分段格式：4 字节大端的头部长度 + JSON 头部 + 各段二进制依次相接。`src/native-bridge.js` 包成 `MediaCraftNative.livePhoto(request, { signal, onProgress })`。

- 请求头部：`{ job, cardWidth, cardHeight, well: { x, y, width, height, radius }, crop, start, span, speed, cover, sound, videoName, cardBytes, videoBytes }`，后面是卡片 PNG（2 倍图）与原视频。时间都按原视频计：从 `start` 起用 `span` 秒，封面在起点后 `cover` 秒；`well` 是卡片逻辑坐标（864 × 1152）里的图片框。
- 回复头部：`{ ok: true, identifier, files: [{ name, size }] }`，后面依次是 JPG、MOV、metadata.plist（`Content-Type: application/octet-stream`）；出错时是普通的 JSON `{ ok: false, error }`。
- 进度：壳在主线程派发 `window` 上的 `mediacraft:native-live-photo` 事件，`detail` 是 `{ job, progress }`（0–1）。
- 页面中止请求（`AbortSignal`、重新载入）时壳停下这次合成、删掉临时文件。

## ai：AI 会话（本机 Claude Code 或 Codex）

AI 就是这台 Mac 上的命令行 Agent：Claude Code（`claude`）或 Codex（`codex`），和在终端里用一样：它自己的登录、技能、MCP 服务、设置与权限规则，不另填密钥。**每篇稿子选一个**（AI 助手顶上，这篇标题下面的选单）：这篇有了对话就锁定，要换先「重新开始这篇的对话」；新稿子用上次选的，从没选过时本机有 Codex（找到、登录了）就用 Codex，否则用 Claude Code（[ADR 0008](adr/0008-ai-backend-claude-or-codex.md)）。实现在 `src/ai/session.js`（会话、权限确认，和哪个后端无关）、`src/ai/backends/`（每个后端一个适配：输出怎么读、回答怎么写、会话怎么续；`claude.js`、`codex.js`）、`src/ai/tools.js`（App 自己的工具）、`src/ai/review.js` 与 `src/ai/diff.js`（修改对比）、`src/ai/versions.js`（版本）、`src/ai/presets.js`（预设命令）与 `src/ai/panel.js`（检查器里的「AI 助手」），编辑器里的标注在 `src/editor/review.js`，进程由壳管（`macos/Sources/MediaCraftShell/AISessions.swift`，每个后端的启动参数、开头写进 stdin 的几行与哪一行算说完在 `AIBackends.swift`，查找 claude / codex 在 `AgentLocator.swift`，配图候选在 `AICandidates.swift`）。只在 App 里可用；浏览器里 `status()` 返回不可用。

**每篇稿子一个会话。** 第一轮开会话（Claude Code 以 `--session-id <新 UUID>`；Codex 是 `thread/start`，线程 id 由它起），之后每轮接着聊（`--resume <同一个 id>`；`thread/resume`）。后端那边的会话没了时这一轮报错，下一轮自动开新会话。会话 id 与会话记录随稿子保存（[storage.md](storage.md) 的 `ai` 字段），切换稿子就换成那篇的会话，重新打开 App 还在。同一篇同时只跑一轮，不同稿子可以同时跑。

**每一轮**：先给稿子存一个[版本](#版本aiversions)，再把编辑器里当前的卡片内容、标题与小红书正文写进这篇稿子的工作副本 `~/Library/Application Support/MediaCraft/ai/<稿子 id>/draft.md`、`title.txt`、`caption.txt`，在这个目录里启动这篇的后端（工作副本是每篇稿子一个的常驻目录，不是每轮一个临时目录：Claude Code 按启动时的工作目录存会话，`--resume` 要在同一个目录里才找得到上一轮，见下面的「两处固定的做法」）。两个后端都是一轮一个进程，说完就退出。**Claude Code** 这样启动：

```
claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
       --permission-mode acceptEdits --permission-prompt-tool stdio --setting-sources user
       --mcp-config '{"mcpServers":{"mediacraft":{"type":"sdk","name":"mediacraft","alwaysLoad":true}}}'
       --allowedTools mcp__mediacraft [这篇稿子的会话里「本次会话都允许」过的规则…]
       --append-system-prompt <说明一篇笔记的三部分（标题 / 卡片内容 / 小红书正文）、自定义标记、App 的工具与防提示词注入的几条> [--model <这篇选的模型>] (--session-id | --resume) <id>
```

环境变量是终端里的那一套（见 `AIStatus`），另加 `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` 关掉后台任务（Claude Code 2.1.280 实测：Bash 工具不再有 `run_in_background`）。从 stdin 先发一条控制请求 `initialize`（`sdkMcpServers: ["mediacraft"]`，登记 App 的工具服务），再发用户消息，流式读回复；stdin 一直开着，用来回答 claude 这一轮里发来的控制请求（见下面「权限」与「App 的工具」）；收到 `result` 就关掉 stdin（claude 读到 EOF 才退出，stdin 开着它会一直等下一句），最多再等 10 秒让它自己退出，还没退出就 SIGTERM，再过 1.5 秒 SIGKILL，这一轮照常按 `result` 算说完。

**说完之后还来的请求**：`result` 之后 stdin 已经关上，claude 再发来的控制请求（比如后台任务跑完后它接着干活，要权限）送不到——它那边会立刻失败（「Tool permission request failed: … Stream closed」）。页面不弹确认框、不执行工具，停掉这一轮，结尾记为出错并说明它还想做什么（「Claude 在这一轮说完之后还想运行命令：…，但这时已经没法问你、也送不回结果了，这一轮已停止。…」）。关掉后台任务之后这本不该发生，发生时也不会让 Claude 一路失败下去。

**模型**：AI 助手顶上的选单，每篇稿子各选，存在稿子的 `ai.model`（[storage.md](storage.md)）；没选过的稿子沿用这个后端上次选的（本机记在 `mediacraft.ai.v1`，按后端分开）。Claude Code 是「默认（跟随 Claude Code 设置）」「Opus」「Sonnet」「Haiku」「自定义…」填模型 ID，选了时启动带 `--model`；Codex 是「默认（跟随 Codex 设置）」、Codex 自己列出的模型（`model/list`，第一次用到时问一次）与「自定义…」，选了时放进 `thread/start` / `thread/resume` 的 `model`。默认都不带（用后端自己的设置）。模型 ID 不能为空、不能有空格、不能以 `-` 开头（免得被当成选项），最多 100 个字符，页面与壳都检查。状态行显示后端报的实际模型（Claude Code 是 `system/init` 的 `model`，没有时取 `result.modelUsage` 的第一个；Codex 是线程回来的 `model`），每轮结尾也记着。

**重新开始这篇的对话**：AI 助手顶上「更多」里的「重新开始这篇的对话…」问一次再做：正在跑的一轮先停（等它结束），还没确认的修改丢掉（都算拒绝），这篇的会话记录清空（`sessionId: null`、`resumable: false`、`messages: []`），「本次会话都允许」的规则与动作的撤销一并忘掉，壳删掉工作副本与配图候选（`ai/remove`，下一轮从编辑器重新写入）；后端随之解锁，可以换；下一轮开新会话（新的 `--session-id`，或 `thread/start`）。每轮之前存的[版本](#版本aiversions)与选的后端、模型保留。

**回答送不到时**：每个回答（权限、工具的结果）壳真正写进 stdin 之后才回 `delivered: true`；写失败（claude 已经不读 stdin……）时页面停掉这一轮（和点停止一样结束进程），结尾记为出错，原因是「权限回答没送到 Claude（…），这一轮已停止」（工具的结果是「工具的结果没送到」），`ai.answer` 也以同样的原因 reject，不让 claude 一直挂着等。连停止也没成功（原生桥出错）时不再等进程退出：页面这边直接结束这一轮，原因后面接上「停止这一轮也没成功（…），claude 可能还在运行」（这篇要等它退出才能发下一轮）。这一轮已经结束（stdin 已关）时回答本来就不再需要，不算出错。

**Claude Code 两处固定的做法**（和在终端里用 `claude` 不同的地方）：

- 固定 `--setting-sources user`：只读你自己的用户级设置，工作副本里的项目级 `.claude/settings.json`（模型自己写进去的 hook 之类）不生效，不能借它绕开权限确认。
- 固定 `--permission-mode acceptEdits`：自动接受的只是工作目录里的文件修改，而工作目录就是这篇稿子的工作副本（只有 `draft.md`、`title.txt`、`caption.txt`），所以 Claude 改稿不用一处处确认（改动之后在[修改对比](#修改对比aireview)里逐处确认）；工作目录以外的写入、运行命令、打开网页照样按 Claude Code 自己的规则问。不跟随你在终端里设的默认权限模式。
- 工作副本是常驻目录（`~/Library/Application Support/MediaCraft/ai/<稿子 id>/`），不是每轮一个临时目录：Claude Code 把会话记在按工作目录划分的项目里（`~/.claude/projects/`），`--resume` 只在同一个工作目录下找得到上一轮。所以它在稿子删掉之前一直在（删稿子时一起删）。

- **权限**和终端里一样由 Claude Code 自己的设置与规则决定：工作副本里的 `draft.md`、`title.txt`、`caption.txt` 自动接受修改（`acceptEdits`），在终端里会问你的操作（运行命令、写工作目录以外的文件、打开网页……）改在 App 里问：claude 发来 `can_use_tool` 控制请求（`--permission-prompt-tool stdio`），AI 助手在输入框上方弹出确认框（Claude 想做什么、命令 / 文件 / 网址、它自己的说明），有「允许」「拒绝」「本次会话都允许」。回答按原 `request_id` 写回 stdin：允许是 `{ behavior: "allow", updatedInput: 原输入 }`，拒绝是 `{ behavior: "deny", message: 原因 }`（Claude 收到拒绝和原因，不会换个办法硬做）。「本次会话都允许」的范围和终端里「以后不再问」一样，只用 claude 在请求里给的建议（`permission_suggestions`，比如这条命令、这个网站）；**没给建议时确认框里没有这个选项**，不退而放行整个工具。选了时这一轮回答带上 `updatedPermissions`（`destination: "session"`，不写进 Claude Code 的设置），之后每一轮把这些规则（如 `Bash(npm test:*)`）接在 `--allowedTools` 后面，App 开着期间有效。claude 撤回请求（`control_cancel_request`）、停止这一轮时确认框收起；双击按钮的第二下不算，免得批准了还没看清的下一个请求。
- **App 的工具**挂成一个 SDK MCP 服务 `mediacraft`：不起别的进程、不开端口，claude 调用时发 `mcp_message` 控制请求，页面执行（`src/ai/tools.js`，只经 `window.mediacraft`），回答写回 stdin。`--allowedTools mcp__mediacraft` 让它们不用确认（都可以撤销）；`alwaysLoad` 让工具一开始就在 Claude 手边。工具清单见下面 [App 的工具](#app-的工具mcp-服务-mediacraft)。

**Codex**（`src/ai/backends/codex.js`，壳的 `CodexBackend`）：在工作副本目录里起 `codex app-server`，环境变量是终端里的那一套（不另加），stdio 上是 JSON-RPC（每行一条）。壳写开头的握手（`initialize`，`capabilities.experimentalApi: true`，动态工具要它；`initialized`），之后由页面经 `ai/respond` 写：新会话 `thread/start`（`dynamicTools` 挂上 App 的工具、`developerInstructions` 是和 Claude Code 一样的说明、选了模型时 `model`），之后的轮 `thread/resume { threadId, excludeTurns: true }`（动态工具 Codex 自己记着；不要它回整段历史，里面有每次看页面的图，越聊越大）；线程回来发 `turn/start`（用户的话）。壳只写认得的几种：对服务端请求的回答，`thread/start`、`thread/resume`、`turn/start`、`turn/interrupt`；线程的工作目录（这篇的工作副本）、`sandbox: "workspace-write"`、`approvalPolicy: "on-request"` 由壳填，页面给的别的字段（`config`、换工作目录、换沙箱……）不写进去，`turn/start` 只带文字的用户输入。回复流式读 `item/agentMessage/delta`，`item/completed` 里的命令、改文件、搜索网页、MCP 调用、看图各记一行；收到这个线程这一轮的 `turn/completed`（壳从开线程、发这一轮的回答里记下两个 id）就关掉 stdin（它读到 EOF 退出），收尾与 Claude Code 相同；子线程的通知也可能走这条连接，页面只认这个线程这一轮的，别的不混进回复，服务端请求不论来自哪个线程都照常回答。壳只推页面用得上的通知（`item/started`、`item/completed`、`item/agentMessage/delta`、`error`、`turn/completed`），命令输出的增量、diff、推理、用量、额度、账户这些不推。

- **审批**：工作副本里的修改不用问（`workspace-write`）；要跑沙盒外的命令、连某个主机（受管的网络）、改工作区以外的文件、要更多权限（联网、目录外的读写）时 Codex 发审批请求（`item/commandExecution/requestApproval`，联网时带 `networkApprovalContext`；`item/fileChange/requestApproval`；`item/permissions/requestApproval`），弹同样的确认框（「Codex 想运行命令」「Codex 想访问 主机」「Codex 想修改文件」「Codex 想获得更多权限（联网、读 / 写工作区以外的文件）」，细节是命令、文件路径或一项一行的权限——文件系统规则 `entries` 也逐条写出，有认不出的写法时附上完整的请求，框里写的就是会给出去的全部；附注是它给的原因、命令的目录与额外要的权限）：允许回 `accept`，拒绝回 `decline`，「本次会话都允许」回 `acceptForSession`（Codex 没给这个选项时确认框里也没有）。确认框里的 id 是「这一轮的 id:请求 id」：Codex 每轮是新进程，请求 id 从 0 数起，几篇稿子同时跑时会撞上，回答它时用原来的 id；要权限的回 `{ permissions: 它要的那几项, scope: "turn" | "session" }`，拒绝是 `{ permissions: {}, scope: "turn" }`。每轮是新进程，Codex 自己记的放行到下一轮就没了，所以规则由页面记着，记的是请求的全部要素（命令连同工作目录与额外权限、联网的主机与额外权限、改的文件与要的授权目录、整组权限），一模一样的请求再来才不问（这篇的会话里、App 开着期间），同样的请求再来时直接回 `accept`，不再问。
- **App 的工具**是线程上的动态工具（名字同[下面的清单](#app-的工具mcp-服务-mediacraft)，不带前缀；不含 `generate_image`：Codex 用它自带的生图）：调用时 Codex 发 `item/tool/call`，页面执行（同一份 `src/ai/tools.js`，同样一次一个），回 `{ success, contentItems }`（文字是 `inputText`，页面截图是 `inputImage`）。别的服务端请求（要你填表之类）回错误「Vibepost 不支持 …」。说完之后还来的请求与 Claude Code 一样处理（停掉这一轮并说明）。
- **续不上**：`thread/resume` 报找不到这个线程（Codex 那边的记录没了）时这一轮报「之前的会话在 Codex 里找不到了，下一轮会开一个新会话。」，下一轮 `thread/start`；别的错误照常报（「Codex 没能接着上次的会话：…」），会话留着，下一轮接着续。
- 你拒绝了的命令、改动不另记一行（确认框的回答那一行已经写了）；没成功的记「运行没成功：…」「修改没成功：…」。
- **生图**用 Codex 自带的（给它的说明里写明：直接用自带的生图，不写脚本、不调别的服务或技能），不给它 App 的 `generate_image`。`item/started` 的 `imageGeneration` 开始时面板显示「Codex 正在生成图片… N 秒」，按钮是「停止这一轮」；`item/completed` 时壳读到这一行就把图（`savedPath`，它自己目录里的，如 `~/.codex/generated_images/…`；没有时用 `result` 里的 base64）检查后存一份进这篇的 `.candidates/`（原图不动、不用问你：是它自己画的），推给页面的这一行去掉 `result`（一张几 MB）、带上存好的候选 `vibepostCandidates`；会话里随即出现这组配图候选（说明是它改写后的提示词 `revisedPrompt`），点了才插进稿子。没成功时记一行「生成图片没成功：…」（额度用完了写明什么时候恢复）。

退出后读回工作副本：`draft.md` / `title.txt` / `caption.txt` 与发出时不同（`draft.md`、`caption.txt` 只差末尾空白不算；App 的工具同步进来的结构改动已经在编辑器里，不算），改动**不直接落进正文**，而是进入[修改对比](#修改对比aireview)逐处确认，这一轮的结尾记下「N 处修改待确认」。停止、出错的一轮若已经改了文件，同样进入修改对比。有待确认的修改时，这篇不能发下一轮（先接受或拒绝）。

**换稿子时正在跑的一轮继续跑完**，只属于它自己的稿子：跑完时那篇不在编辑器里，待确认的修改随那篇存着（[storage.md](storage.md) 的 `ai.review`），下次打开那篇时显示。重新载入页面、关窗口、退出 App 会结束所有还在跑的进程，没说完的那轮记为「已中断」。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `status({ refresh?, backend? })` | 找没找到本机的这个后端（`"claude"` / `"codex"`，默认当前这篇用的）。第一次调用时才去找（跑一次登录 shell），之后用缓存；`refresh: true` 重新找 | `AIStatus` |
| `setPath(path, backend?)` | 在设置里指定 claude（`backend` 默认 `"claude"`）或 codex 的完整路径（`~` 可用）并重新查找；`null` 或 `""` 恢复自动查找 | `AIStatus` |
| `backends()` | 认得的后端 | `[{ id, name, label }]` |
| `setBackend(backend, draftId?)` | 给这篇（默认当前这篇）选后端，模型换成那个后端上次选的，同时记成新稿子的默认。这篇已经有对话（或正在跑）时换成别的后端 reject（先「重新开始这篇的对话」）；没有这个后端 `TypeError`，内置说明书 reject | `{ backend, model, used }` |
| `models(backend?)` | 后端能选的模型：Claude Code 是三个别名；Codex 问它自己（`model/list`，问过一次就记着），不在 App 里时为 `[]`；Codex 的每个模型带它能选的推理强度与默认档 | `[{ id, name, isDefault, efforts?, defaultEffort? }]` |
| `send(prompt, options?)` | 在**当前稿子**的会话里发一句，这一轮说完（或停止、出错）时返回（改了稿子时修改对比已经显示出来）。内置说明书、找不到这篇的后端（或 Codex 没登录）、这篇已经在跑一轮、还有待确认的修改时 reject | `TurnResult` |
| `polish()` | 一键润色：固定的话（改错别字、理顺句子、不改原意和结构、保留所有自定义标记）发进同一个会话 | `TurnResult` |
| `preset(name)` | 预设命令（`src/ai/presets.js`，AI 助手里的几个按钮）：固定的话发进同一个会话，会话里显示按钮上的字，用户消息 `kind: "command"`、带 `preset: name`。`"coverTitles"` 封面标题 5 选 1（不改稿子，回复里给 5 个候选的 JSON 数组）、`"hook"` 首图文案（正文最前面一行一级标题）、`"humanize"` 去 AI 味（换成自然的个人口吻，事实与结构不变）、`"repaginate"` 按要点重新分页（Claude 直接改 `draft.md` 里的 `[[分页]]`，不用分页工具）、`"caption"` 写小红书正文（照着卡片内容与标题写 `caption.txt`：纯文本、口语、最后一行 3–5 个 #话题，不改 `draft.md` 与 `title.txt`）；后四个改的稿子照常进修改对比。改卡片内容的提示词都要求保留自定义标记与话题标签。AI 助手里另有快捷命令「加话题标签」（5 个 #话题加到 `caption.txt` 最后，同样进修改对比）。设计方向 `"bolder"` 更醒目、`"quieter"` 更安静、`"distill"` 精简、`"colorize"` 上色、`"typeset"` 调字、`"layout"` 理版式：让 Claude 先用 `get_pages` / `view_page` 看、再用 `restyle_block`、`move_section`、`set_style`、`set_card_css`（与预览里点选一块后的操作同一套）改、改完再看；用户还在经典引擎时提示词里多一句，让 Claude 先提醒切到「HTML 试用」。没有这个名字时 `TypeError` | `TurnResult`；`coverTitles` 另有 `titles: TitleOption[]` |
| `useTitle(title)` | 把标题换成这个（与点封面标题候选相同）：撤销历史里的一步，⌘Z 撤回。空字符串 `TypeError`，内置说明书 reject | `Draft` |
| `cancel(draftId?)` | 停止这篇（默认当前这篇）正在跑的一轮：先 SIGINT，还不退出再 SIGTERM、SIGKILL；正在生图的一并停止 | `{ cancelled }` |
| `model(draftId?)` | 这篇（默认当前这篇）用的后端、选的模型与最近一轮实际用的：`model` 是别名（Claude Code 的 `"opus"` / `"sonnet"` / `"haiku"`）、模型 ID 或 `null`（跟随后端自己的设置），`used` 是后端报的模型（还没跑过为 `null`） | `{ backend, model, used }` |
| `setModel(model, draftId?)` | 给这篇（默认当前这篇）选模型，下一轮起生效，同时记成这个后端没选过的稿子的默认。格式不对 `TypeError`，内置说明书 reject | `{ backend, model, used }` |
| `effort(draftId?)` | 这篇（默认当前这篇）的推理强度：`efforts` 是这个后端与模型能选的档位（Claude Code 固定 `low` / `medium` / `high` / `xhigh` / `max`；Codex 来自 `model/list`），`effort` 是这一轮会用的那档——每篇各记各的，没选过是 `medium`；选过的这个模型不支持（换了模型）时退回 `medium`，没有 `medium` 时退回模型自己的默认档。Claude Code 带 `--effort`，Codex 写进 `turn/start` 的 `effort` | `{ backend, model, effort, efforts }` |
| `setEffort(effort, draftId?)` | 给这篇选推理强度，下一轮起生效；只能是 `effort().efforts` 里的一档，不是时 `TypeError`，内置说明书 reject | `{ backend, model, effort, efforts }` |
| `newSession()` | 重新开始当前这篇的对话（与「更多」里点「重新开始这篇的对话…」并确认相同，见上）。内置说明书 reject；会话记录清空了但工作副本没删掉时 reject 说明原因 | 清空后的 `history()` |
| `imageSettings()` | 用 Claude Code 时 App 的生图工具用哪个模型：`{ provider: "openai", model, defaultModel, key }`，`key` 是要找的环境变量名（Codex 用它自带的生图，不看这里） | 同左 |
| `setImageSettings({ provider?, model? })` | 改生图的模型（AI 助手 › 设置里的「生图」），`model` 空为默认；存在本机 `mediacraft.ai.v1`。`provider` 只能是 `"openai"`（或不给），模型 ID 格式不对 `TypeError` | 同 `imageSettings()` |
| `stopImages(draftId?)` | 停止这篇（默认当前这篇）正在生成的图（与点进度行上的按钮相同）：App 的生图工具停下，Claude 收到「已停止生图」，这一轮接着往下走；Codex 自带的生图没法单独停，停掉整轮（按钮上写「停止这一轮」） | `{ cancelled }` |
| `sessions({ query? })` | 会话历史（AI 助手顶上的钟表按钮）：聊过的稿子（说过话的；内置说明书没有），按最近一次 AI 活动排、最近的在前（这版之前没记活动时间的按修改时间）。`query` 按标题与聊过的话搜（不分大小写）。`last` 是最后一句话（你说的或 AI 回的，去掉 Markdown 记号、最多 80 字），`running` 是这个窗口里 AI 正在回复，`current` 是这个窗口正开着的这篇 | `[{ draftId, title, backend, lastActive, last: { role, text }, running, current }]` |
| `history(draftId?)` | 这篇（默认当前这篇）的会话；`backend` 是这篇用的后端，`locked` 是后端锁定了（有对话或正在跑）；正在跑的一轮含已经流出来的字；`permissions` 是等你回答的权限请求（按先后）；`model` / `usedModel` 同 `model()` 的 `model` / `used`；`generating` 是正在生图时的 `{ provider, model, count, size, startedAt, byBackend? }`（`byBackend: true` 是后端自带的生图，这时 `model`、`size` 为 `null`），没有为 `null` | `{ draftId, backend, locked, sessionId, running, model, usedModel, messages: AIMessage[], permissions: AIPermission[], generating }` |
| `answer(requestId, decision)` | 回答一个权限请求：`"allow"` 允许这一次、`"session"` 本次会话都允许（范围见上；请求的 `scope` 为空时 reject，请求还在）、`"deny"` 拒绝（与点确认框相同）。请求已经不在（撤回、停止、答过）时 reject；回答没送到 Claude 时 reject，这一轮随之结束（见上面「回答送不到时」） | — |
| `undoAction(messageId)` | 撤销会话里的一个动作（与点那一行的「撤销」相同），只撤这一个，之后的改动保留；它改过的东西之后又被改过（同一处正文、同样的设置、同一张图的版式）时不撤，reject 并说明原因 | — |
| `insertCandidate(messageId, candidateId)` | 把一张配图候选插进当前稿子（与点缩略图相同）：插在 Claude 建议的那一块后面，找不到就插在光标处；一步可撤销的编辑 | `{ imageId }` |

`send` 的 `options`：`kind`（`"chat"` 默认 / `"polish"` / `"command"` / `"rewrite"`，只影响记录）、`label`（会话里显示的字，默认就是 `prompt`）、`context: { start, end }`（带上正文里这段选中的文字：文字与位置一起发给 Claude；`prompt` 为空时是「改写这段」）、`preset`（预设命令的名字，记在这条用户消息上，`preset()` 用它）。界面上的「改写」与 ⌘J 就是带 `context` 的 `send`。

`TitleOption`：`{ text, width, over }`。从回复里读候选：先找 JSON 数组（代码块里的或裸写的；不合法时取引号里的每一段），读不出再按编号、圆点列表逐行读，去掉加粗、「标题 1：」前缀与末尾的「（18 字）」，去重，最多 5 个；什么都读不出时为 `[]`（AI 助手里说明读不出、可以再点一次）。`width` 是显示宽度：一个字形按它的第一个码点，拉丁字母、数字、半角符号（U+1100 以前与半角片假名）算 1，汉字、全角标点、emoji 算 2；小红书标题最多 20 个全角字，`over` 是 `width > 40`。AI 助手在「封面标题 5 选 1」那一轮说完后（它是会话里最后一轮时）把候选列在快捷命令下面，字数显示为 `⌈width / 2⌉/20`，超出的标红，和现在的标题一样的那个标为选中。

`AIStatus`：`{ available, path, version, source: "settings" | "login-shell" | null, error, reason }`，每个后端一份；`reason` 是不能用的原因（能用时为 `null`）：`"missing"` 没找到、`"broken"` 找到了但运行不起来、`"login"` 还没登录（Codex），AI 助手照它给这个后端的指引（安装、登录、重新安装的命令，另一个后端能用、这篇还没有对话时可以一键改用它）。从访达打开的 App 不继承终端的 PATH，壳用登录 shell（`$SHELL -l -i -c`）读出终端里的环境变量，在它的 PATH 里找 `claude` / `codex`，跑一次 `--version` 确认能启动（Codex 再跑一次 `codex login status`，没登录时不可用：「Codex 还没有登录：在终端里运行一次 codex login」）；以后启动它也用这套环境变量（它所在目录放在 PATH 最前，npm 装的要找得到旁边的 node）。设置里指定的路径优先，存在 `~/Library/Application Support/MediaCraft/ai/settings.json`。登录 shell 与 `--version` 都在自己的进程组里跑，有总超时（登录 shell 15 秒、`--version` 10 秒，含读完输出）：到时结束整个进程组（它们启动的进程一起），不一直等。进程退出后先不回收，到这次运行结束才回收：超时那一下对进程组发的 SIGKILL 只会落在这次启动的进程组上，不会落到系统把这个号码重新分给的别的进程。登录 shell 读不出环境变量（超时、出错退出、没有输出）时退回 App 自己的环境，找不到或跑不起来时 `error` 后面括号里写着登录 shell 的问题（如「登录 shell /bin/zsh 没有在 15 秒内结束，已结束它和它启动的所有进程」「… 没有输出环境变量，退出码 1：…」）。

`TurnResult`：`{ turnId, state: "done" | "cancelled" | "error", changes, reply, error? }`，`changes` 是这一轮改了几处（等你确认，见 `review`；没改稿子为 0），`reply` 是 Claude 这一轮最后的话。

`AIMessage`（会话记录里的一条，按先后）：

| role | 字段 |
| --- | --- |
| `user` | `text`（显示的字）、`kind`、`context?: { start, end, text }`、`preset?`（预设命令的名字）、`at`（毫秒时间戳） |
| `assistant` | `text`（Claude 的回复，Markdown） |
| `tool` | `text`：Claude 用的工具，一行（「读取 draft.md」「修改 draft.md」「搜索网页：…」「调用 服务 · 工具」……）；App 自己的工具只记看了什么（「查看分页（共 3 页）」）和没成功的（「插入分页没成功：…」） |
| `action` | `text`：Claude 用 App 的工具做的一个动作（「换成主题「纯黑」」「插入分页：在「…」之后」「图片「…」宽度 60%」……）、`undone?`；`history()` 里另有 `undoable`（现在还能撤销：只在 App 开着期间，重新打开后只能用 ⌘Z 或版本） |
| `permission` | 你对一个权限请求的回答：`decision`（`allow` / `session` / `deny`）、`text`（「运行命令：…」） |
| `candidates` | 一组配图候选：`images: [{ id, name, width, height, thumb, caption?, after?, inserted? }]`，`thumb` 是缩略图（JPEG data URL），`after` 是 Claude 建议插在哪一块后面，`inserted` 是插进去后的图片 id |
| `end` | 一轮的结尾：`state`（`done` / `cancelled` / `error` / `interrupted`）、`review?: { count, accepted? }`（改了几处；确认完再记下接受了几处，没确认完时没有 `accepted`）、`edited?`（接受的修改落进了正文）、`error?`、`model?`、`durationMs?`、`costUsd?` |

每条都有 `id` 与 `turn`（这一轮的 id）。子助手（Task）的输出不进记录（它们要确认的操作照样弹确认框）。

`AIPermission`：`{ id, tool, input, title, detail, note, scope, local? }`：`id` 是这个请求的 id（claude 的 `request_id`；Codex 的是「这一轮的 id:JSON-RPC 的请求 id」，见上），`tool` 是工具名（Claude Code 的 `Bash`、`WebFetch`、`mcp__服务__工具`……；Codex 的 `command`、`network`、`fileChange`、`permissions`），`title` 是「运行命令」「写入文件」「打开网页」这样的一句，`detail` 是完整的命令、路径或网址（不截断），`note` 是 Claude 自己的说明与「不在这篇稿子的工作目录里：…」，`scope` 是点「本次会话都允许」会放行的规则（claude 没给建议、Codex 没给 `acceptForSession` 时为空，没有这个选项）。`local: true` 是 App 的工具自己要问的（载入网上的、工作目录以外的图片），回答不经 claude，`scope` 是这批图片所在的本机目录（如「目录 /Users/我/Pictures」），网上的图不给范围（每批都问）。

`AIEvent`（`mediacraft.on("ai", handler)`）：

| type | 字段 | 何时 |
| --- | --- | --- |
| `status` | `backend, status: AIStatus` | 查找或设置之后 |
| `turn` | `draftId, turnId, state: "running" \| "done" \| "cancelled" \| "error", changes` | 一轮开始、结束 |
| `review` | `draftId, turnId, open, count` | 修改对比里做了决定（`open: true`），或确认完、收起了（`open: false`） |
| `message` | `draftId, turnId, message: AIMessage` | 会话里多了一条，或一条变了（动作撤销了、候选插入了；`id` 相同） |
| `text` | `draftId, turnId, messageId, text` | 正在流式生成的回复又多了字（`text` 是到目前为止的全文） |
| `permission` | `draftId, turnId` | 等你回答的权限请求有增减（新请求、回答了、撤回了），用 `history()` 取 |
| `generating` | `draftId, turnId` | 开始生图、生图结束（成功、失败或停止），进度用 `history().generating` 取 |
| `model` | `draftId` | 这篇选的后端或模型变了 |
| `session` | `draftId` | 这篇重新开始了对话（记录已清空） |

### App 的工具（MCP 服务 `mediacraft`）

Claude 用它们直接操作 App（工具全名 `mcp__mediacraft__<名字>`）。只经 `window.mediacraft` 执行，页面是唯一的真相；只操作这一轮的稿子（你切到别的稿子时，工具回错误，不会改到正在看的那篇）。一次执行一个。

- **定位**用稿子里的一段原文（照抄 `draft.md`、不跨行、只出现在一处），定位到包含它的那一块；标题指它连同下面的整节（到下一个同级或更高级的标题为止）。
- **动作**：会改稿子的工具每次在会话里记一行 `action`，行尾「撤销」只撤这一个（正文结构的改动与之后别处的改动三方合并，重叠时说明原因、请你用 ⌘Z）；每个动作同时是撤销历史里的一步（⌘Z）：正文、图片，以及主题、样式、模式（`drafts.update(patch, { undoable: true })`）。
- **外部 Agent 也用**：标了 shared 的工具（`get_pages`、`set_theme`、`set_style`、`set_mode`、分页、挪段落、摆图片、`save_writing_manual`）同样给外部 Agent 的 MCP 服务用（[mcp.md](mcp.md)），描述里提到 `draft.md`、`propose_images`、工作副本的那一句只给 AI 助手。
- **写作手册**（只管写什么、什么口味；文件见 [storage.md](storage.md#写作手册写作手册)）：每轮开始时壳把它们拷进工作副本的 `写作手册/`，`AGENTS.md` 末尾列出目录（名字、说明、路径）；说明书里写明按这篇的题材自己挑一份（你在对话里点名的优先），要把经验记进写作手册时用 `save_writing_manual` 提议。
- **同步 draft.md**：分页、挪段落、摆图片这类结构改动是纯函数（Markdown → Markdown），在编辑器里生效后，同样的改动套到工作副本的 `draft.md` 与这一轮的比对基准上（`ai/work-file`），Claude 之后读到的与编辑器一致，这一轮结束时也不会再套用一次；`draft.md` 那一带被 Claude 改过、套不上时不同步，工具结果里会说。
- 工具看到的是编辑器里的稿子：Claude 在 `draft.md` 里的文字修改要等这一轮结束才进编辑器。

| 工具 | 做什么 |
| --- | --- |
| `get_draft` | 设置与素材：标题、小红书正文（`caption`）、模式、主题、颜色（与单独调过的辅助、衬底）、字体、字号、行距、图片最大高、封面、分页个数、图片（id、名字、原图尺寸、版式、裁剪、在不在正文里），以及可选的主题、字体与取值范围 |
| `get_pages` | 按编辑器里的稿子出图，列出每页放了哪些块（接上页 / 转下页）、正文区用了多少、分页符换页还是放不下自动换页；封面、结尾页标明 |
| `view_page` | 某一页卡片的图（540 像素宽的 JPEG，MCP 的 image 内容） |
| `set_theme` | 换主题（id 或中文名），同 `themes.apply` |
| `set_style` | 颜色（bg 背景 / text 文字 / accent 强调 / secondary 辅助 / surface 衬底，说明取自 `src/engine/colors.js`；只给前三个时后两个按三色规则推，给了的辅助、衬底记为单独调过；撤销时标记一起回去）、字体（zh / en / code）、字号、行距、图片最大高，只改给了的项 |
| `set_mode` | 图文卡片 `cards` / 长文 `article` |
| `insert_page_break` | 在某一块之前或之后插入 `[[分页]]`（那里已有分页、放在开头结尾时拒绝） |
| `remove_page_break` | 去掉第 n 个 `[[分页]]` 或全部 |
| `move_section` | 把一块或一整节挪到某一块之前或之后 |
| `set_card_css` | 这一篇自己的卡片样式（CSS）：整段换掉或接在后面，可撤销 |
| `restyle_block` | 给一块换样式：套成 / 换成 / 拆掉组件（小标签、提示、页尾、等宽、标签列表、步骤），组件对齐，标题改级别（与预览里点选一块后的「换样式」同一套，`src/cards/blocks.js`） |
| `move_image` | 把一张图（或它所在的拼图）挪到某一块之前或之后 |
| `insert_image` | 把素材里有、正文里没有的一张图插回正文 |
| `resize_image` | 宽度百分比或固定宽高、对齐，或恢复默认（同 `media.update` 的 `layout`） |
| `crop_image` | 按比例居中裁（`aspect: "3:4"`）或按原图百分比给裁剪框，或取消裁剪（同 `media.update` 的 `crop`）；实况不能裁 |
| `generate_image` | 只在用 Claude Code 时有（Codex 用它自带的生图，见上面的「Codex」）。按提示词生成配图：`prompt`、`count`（1–4，默认 1）、`size`（「宽x高」，每边 256–3840，默认 `1024x1536` 竖图，配 3:4 卡片）、`style?`（接在提示词后面「风格：…」）。原生壳直接调 OpenAI 的生图接口（`ai/generate-image`），不经 Bash、不用确认（所以一轮最多生 8 张，超出的那次不发请求、告诉 Claude 原因）：默认模型 `gpt-image-2`（与作者自用的 gpt-image 技能一样 `POST /v1/images/generations`，`quality: "high"`，一次出 `n` 张），在 AI 助手 › 设置 › 生图里可以换模型。密钥取终端环境里的 `OPENAI_API_KEY`，没有时重新读一次登录 shell，再找 `~/.env`（`KEY=值` 或 `export KEY=值`）；密钥只进请求头，不进日志、错误与页面（接口的错误原因里出现密钥时换成「…」）。生成的图和 `propose_images` 的一样存进 `.candidates/`、在会话里显示缩略图（说明是提示词），你点了才插进稿子。生成中会话里一行进度（服务、模型、张数、尺寸、用时）和「停止生成」；没有密钥（说明去哪设）、接口出错（带上接口给的原因）、停止（「已停止生图」）时 Claude 收到原因，会话里记一行「生成图片没成功：…」。按张计费，费用记在你自己的 OpenAI 账户上（工具说明与设置里都这样写）；系统提示词让 Claude 生图用它，不自己跑脚本或 curl |
| `save_writing_manual` | 提议新建或整份改写一份写作手册：`name`（已有的名字就是改写，新名字就是新建；1–40 字，不能有 `/ \ :` 与控制字符、不以 `.` 开头）、`description`（一句话，最多 200 字）、`content`（正文 Markdown，最多 200 KB）。页面先照壳的规矩查一遍（不合规矩直接回错误、不弹框），再用确认框（`MediaCraftConfirm`）问你：标题「新建写作手册「X」」或「修改写作手册「X」」，内容是说明（改了时前后都给）与正文开头 300 字（新建），或正文 +N / −M 行与前几行改动（修改）；你同意才经原生桥 `manuals/save` 存，拒绝时 Claude 收到「用户没有同意保存这份写作手册」，和原来一模一样时不弹框、直接说没有改动。存好后会话里记一行「新建写作手册「X」」，下一轮起生效。不看、不改稿子（你切到别的稿子也能用）；标了 shared，外部 Agent 也用（见 [mcp.md](mcp.md)）。浏览器里没有 |
| `propose_images` | 把 Claude 找到的图片（本机路径、`file://` 或 http(s) 网址，最多 8 张）登记成配图候选：这篇工作目录里的直接载入；网上的、工作目录以外的先用确认框问你（一批问一次，和终端里打开网页、读目录外的文件要问一样），不同意时 Claude 收到原因。「本次会话都允许」只放行这批图片所在的**同一目录**（不含子目录），别的目录照样问；**网上的图每批都问**，确认框里写出每个网址，不提供「本次会话都允许」（防提示词注入：放行整个网站的话，被注入的模型能把读到的内容拼进那个网站的网址里带出去），网址里带着一长串编码（base64、十六进制、百分号编码）或特别长的，在确认框里单独点名提醒，超过 2048 字的直接不载入；下载途中重定向到别的站点时停下再问一次（确认框写明「原网址 → 跳去的网址」），同一站点的重定向照跟；主机名解析到本机、局域网、链路本地地址的不载入（网址里直接写的 IP 地址、`localhost`、`.local` 是你在确认框里看得到的，照常问）。同意与放行的范围都由壳记，页面自己说「同意了」不算（见下面原生桥的 `ai/candidate`）。壳读进来、确认真是图片（最多 20 MB、6400 万像素）、存进 `.candidates/`、做缩略图；会话里显示缩略图，你点了才插进稿子 |

调研这类事 Claude 自己用技能与 MCP（agent-reach……）去做，和终端里一样，App 不另外提供；生图用 App 的 `generate_image`，免得 Claude 跑脚本时要一次次确认命令，生成的图也直接进配图候选。

### 修改对比：`ai.review`

一轮改了稿子，改动先标在编辑器里（删掉的字红色删除线，加上的字绿色底），逐处接受或拒绝：

- **按段分处**：以行比对，同一段（中间没有空行）里的几处改动合成一处；标题、小红书正文改了各单独一处（正文栏整段一处），排在最前（显示在编辑器上方那一条里，正文的删改逐字标出）。自定义标记（`[[image:…]]`、`[[分页]]`、`{{…}}`）都在一行之内，不会被拆到两处；标注时标记也整个标出（改动的行露出 Markdown 标记，删掉的与加上的标记对得上）。
- **套用**：每一处都决定了（或「全部接受」「全部拒绝」），把接受的**一次**套用——卡片内容、标题与小红书正文是撤销历史里的一步，⌘Z 整个撤回；没接受的不改。`finish()` 提前结束时，没决定的算拒绝。
- **审阅时**：编辑器只读（打字、⌘Z 都不动正文）；舞台与 `render.pages()` 画的是「没拒绝的都接受」后的样子（决定一处，舞台跟着变），所以这时预览里不能拖改图片，导出与发送会 reject「先处理完 AI 的修改」。
- **你也改了正文**（这一轮跑的时候，或审阅时经 App API 改了）：修改挪到现在的正文上重新算。和你的改动不重叠的照样挪过去；重叠的连成一处**冲突**（`conflict: true`）——接受就把这一段整个换成 AI 的（你在这段里的改动不留），拒绝就留你的，没有只取一半。
- 待确认的修改与已做的决定随稿子存（`ai.review`），换稿子、重新打开 App 都还在。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `get()` | 当前稿子待确认的修改 | `ReviewStatus` |
| `accept(index)` / `reject(index)` | 接受 / 拒绝第 `index` 处（再调一次可以改主意）；这是最后一处没决定的时就套用并结束。没有待确认的修改时 reject，下标不对是 `RangeError` | `ReviewStatus` |
| `acceptAll()` / `rejectAll()` | 每一处都接受 / 拒绝，并套用、结束 | `ReviewStatus` |
| `finish()` | 现在结束：接受的套用，没决定的算拒绝 | `ReviewStatus` |

`ReviewStatus`：`{ open, turnId, hunks: ReviewHunk[], applied? }`。没有待确认的修改时 `{ open: false, turnId: null, hunks: [] }`；结束的那次调用返回 `open: false`、最终的决定与 `applied`（套用了几处）。

`ReviewHunk`：`{ index, kind: "title" | "caption" | "text", before, after, source, conflict, decision: "pending" | "accepted" | "rejected" }`。卡片内容（`text`）的 `before` / `after` 是整行（多行用 `\n` 连起来，不含最后一个换行；纯新增的 `before` 为 `""`），`source` 是 `before` 在现在的卡片内容里的范围；标题与小红书正文（`caption`）是整段，`source` 为 `null`。`index` 在正文变了之后可能变（重新挪过），以最新的 `get()` 为准。

### 版本：`ai.versions`

每轮开始前（`send` 里、启动 claude 之前）给稿子存一个版本，就是这一轮之前的样子：卡片内容、标题、小红书正文、排版模式、主题、配色、字体、字号、行距、图片最大高、封面设置与全部图片的信息（裁剪、版式、实况设置……，画面留在媒体库里）。每篇最多 50 个，多了删最旧的；版本还用着的图片与实况视频不会从本机删掉（在预览里删了图也一样），撤回时画面原样回来。存法见 [storage.md](storage.md) 的 `versions`。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `list(draftId?)` | 这篇（默认当前这篇）的版本，新的在前 | `Version[]` |
| `revert(id)` | 当前稿子撤回到那一轮之前：还没确认的修改先丢掉（算拒绝），再把版本里的全部字段与图片一次换回去——撤销历史里的一步，⌘Z 撤销这次撤回、⇧⌘Z 再撤回，更早的撤销历史照常；不改版本列表。AI 还在回复时、内置说明书、没有这个版本时 reject | `Draft` |

`Version`：`{ id, at, label, draft: { title, caption, markdown, mode, theme, colors, tunedColors, fonts, fontSize, lineHeight, imageMaxHeight, cover, imageIds } }`（这版之前存的版本没有 `cover` 或 `caption`，撤回时封面设置、正文栏不动；没有 `tunedColors` 的按颜色推断一次），`id` 就是那一轮的 `turnId`，`at` 是毫秒时间戳，`label` 是那一轮说的话（最多 40 字）。会话记录里有版本的每一轮结尾都有「撤回到这一轮之前」。同一编号的实况被重新编辑过（封面、原视频换了）时，撤回后用的是编辑后的画面与视频。

### 页面与壳之间（原生桥）

页面 → 壳：`POST mediacraft://app/__native/ai/<动作>`，body 是 JSON（ArrayBuffer），返回 `{ ok, … }`；`src/native-bridge.js` 包成 `MediaCraftNative.ai`。几个窗口共用这些进程，每一轮记着是哪个窗口发起的：事件只推给它，`ai/cancel`、`ai/respond`、`ai/work-file`、`ai/candidate`、`ai/generate-image` 只认它发来的（见[窗口](#窗口一个窗口一篇稿子)）。

| 动作 | body | 返回 |
| --- | --- | --- |
| `ai/status` | `{ refresh, backend }`（`backend` 没给时是 `"claude"`） | `AIStatus` |
| `ai/settings` | `{ backend, path }`（`null` 恢复自动查找；旧的 `{ claudePath }` 也认） | `AIStatus` |
| `ai/models` | `{ backend }` | Codex：起一次 `codex app-server`，握手后问 `model/list` 就关上，`{ models: [{ id, name, isDefault }] }`；别的后端 `{ models: [] }` |
| `ai/send` | `{ turnId, draftId, backend, prompt, markdown, title, caption, systemPrompt, agentsFile, … }`（`agentsFile`：写进工作副本 `AGENTS.md` 的操作手册全文，壳在后面接上写作手册的目录、把写作手册拷进 `写作手册/`，每轮重写），后面是这个后端要的：Claude Code 是 `sessionId, resume, model, allowedTools`（`model`：这篇选的模型，`null` 不传 `--model`，格式不对时 `ok: false`；`allowedTools`：这篇的会话里「本次会话都允许」过的规则），Codex 不要别的（线程由页面经 stdin 开） | 进程启动后立即返回 `{ ok }`；找不到这个后端、缺了它要的字段、这篇已在跑时 `ok: false` 带原因 |
| `ai/cancel` | `{ draftId }` | `{ cancelled }` |
| `ai/respond` | `{ draftId, turnId, message }`：`message` 是一整行（Claude Code 是 `control_response`；Codex 是对服务端请求的回答，或 `thread/start`、`thread/resume`、`turn/start`、`turn/interrupt`，壳按上面「Codex」里说的填好工作目录、沙箱与审批、去掉别的字段），不是这个后端认得的样子时不写、`ok: false` | 写进那一轮的 stdin，真写进去了才回 `{ delivered: true }`；这一轮已经结束、stdin 已关时 `{ delivered: false }`；写失败时 `ok: false` 带原因 |
| `ai/work-file` | `{ draftId, turnId, markdown? }` | 这一轮进行中读工作副本的 `draft.md`；带 `markdown` 时先写进去。返回 `{ markdown }`；这一轮已经结束时 `ok: false` |
| `ai/candidate` | `{ draftId, turnId, source, approval?, session? }`：`source` 是本机路径（相对路径按工作副本目录算，`~` 可用）、`file://` 或 http(s) 网址；只在这一轮进行中可用 | 网上的、工作目录以外的（解开符号链接后判断）要用户同意：本机的这个目录在这篇稿子的会话里放行过就直接读；否则没有有效的 `approval` 时不读，返回 `{ needsApproval: true, approval, scope? }`（`scope` 只有本机目录才有，网上的图没有这一项）——`approval` 是壳发的一次性凭据，只对这篇稿子、这一轮、这张图有效，页面问过用户后带着它再来（`session: true` 时同时放行这个目录，App 开着期间、页面重新载入之前有效；网上的站点不放行，`session` 不起作用）。网址超过 2048 字直接拒绝。伪造、挪用的凭据与旧的 `approved: true` 都不认。放行范围按结构比较（站点是协议 + 主机 + 端口，没写端口按协议的默认端口；目录是解开符号链接后的路径），`scope` 只是给人看的文字。网址的每一跳重定向都要在放行范围里（原来的站点、凭据放行的站点、这篇会话里放行过的）：跳出去时停在这一跳不读，返回 `{ needsApproval: true, approval, scope, redirect }`（`scope` 是跳去的站点，`redirect` 是跳去的网址，凭据仍对这张图），问过带着它再来就跟过去。主机名（不是直接写的 IP、`localhost`、`.local`）解析到本机、局域网、链路本地地址时拒绝，每一跳都查。读进来（最多 20 MB，边下边数；网址 15 秒没动静或 30 秒没下完就算失败），解码不了、超过 6400 万像素就拒绝；PNG / JPEG / WebP / GIF 原样、别的转成 PNG，存进 `.candidates/<稿子 id>/<id>.<扩展名>`（不在 claude 的工作目录里）。返回 `{ id, name, width, height, thumb }`（`thumb` 是最长边 360 像素的 JPEG data URL） |
| `ai/candidate-file` | `{ draftId, id }` | 候选的原图 `{ type, data }`（MIME 类型与 base64） |
| `ai/generate-image` | `{ draftId, turnId, model, prompt, count, size }`：只在这一轮进行中可用，每篇同时一个，一轮一共最多 8 张 | 调生图接口（见上面的 `generate_image`；接口地址测试时可换，见 `AIConfiguration.imageAPI`），每张检查、存进 `.candidates/`，返回 `{ images: [{ id, name, width, height, thumb }] }`；没有密钥、接口出错、停止时 `ok: false` 带原因 |
| `ai/generate-cancel` | `{ draftId }` | 停止这篇正在生成的图（取消网络请求），`{ cancelled }` |
| `ai/remove` | `{ draftId }` | 删稿子、开新会话时调用：先取消这篇正在载入的配图候选、等它们停下，再停掉还在跑的一轮、等进程真正退出（SIGINT、SIGTERM、SIGKILL 各隔一段，最多等到 SIGKILL 之后一秒），然后删掉工作副本目录 `<稿子 id>/` 与 `.candidates/<稿子 id>/`，忘掉它放行过的配图范围，删完不会再有东西写回来；删除期间这篇不能起新的一轮、载入候选。没有这些目录也算成功。后端自己的会话记录（`~/.claude/projects/`、`~/.codex/sessions/`）不碰 |

壳 → 页面：壳在主线程用 `callAsyncJavaScript` 派发 `window` 上的 `mediacraft:native-ai` 事件，`detail` 是：

- `{ type: "lines", turnId, draftId, lines }`：进程 stdout 刚读到的几行（字符串，每行一个 JSON），按读到的顺序；后端发来的请求（claude 的 `control_request`、`control_cancel_request`，Codex 的审批与 `item/tool/call`）也在里面，由页面回答（`ai/respond`）；claude 对 `initialize` 的回答（`control_response`）与心跳（`keep_alive`）、Codex 的吵闹通知不推；后端自己生成的图（Codex 的 `imageGeneration`）壳先存成配图候选，这一行去掉原图数据、加上 `vibepostCandidates`（每张 `{ id, name, width, height, thumb }`，存不了的是 `{ error }`）再推；
- `{ type: "exit", turnId, draftId, status, signal, cancelled, stderr, markdown, title, caption }`：进程退出、输出读完之后；`markdown` / `title` / `caption` 是这时工作副本里 `draft.md` / `title.txt` / `caption.txt` 的内容（文件不在为 `null`），`stderr` 是最后 8 KB。

进程的读写都在后台线程；每一行的意思由页面里这个后端的适配解读（`src/ai/backends/`）：claude 的 stream-json 是 `system/init` 取模型与会话 id，`stream_event` 的 `text_delta` 流式显示，`assistant` 里的完整文字与 `tool_use`，`result` 取花费与用时；Codex 见上面的「Codex」。壳只认哪一行算说完（claude 的 `result`，Codex 的 `turn/completed`）。


## 窗口：一个窗口一篇稿子

App 可以开几个窗口，每个窗口开着一篇稿子，各改各存（都存在同一份本机存储里）。窗口的页面照地址打开稿子：`?draft=<id>` 打开这篇，`?new=1` 新建一篇，都没有时打开上次那篇；打开之后地址换成 `?draft=<这篇>`（`history.replaceState`），重新载入（⌘R）还是这篇，不跟着别的窗口换。窗口里的 `window.mediacraft` 管的就是这个窗口开着的这篇。

**同一篇只在一个窗口里**：一篇稿子在它的窗口里开着（正在看的，或那里的 AI 还在跑的）时，别的窗口打不开它。要开的时候（稿件列表点一篇、`drafts.open(id)`、在新窗口打开）壳把开着它的那个窗口调到前面并换到那篇，这个窗口不换，`drafts.open` reject「「…」在另一个窗口里开着，已经切到那个窗口」（`error.elsewhere` 为真）。内置说明书只读，哪个窗口都能开。窗口启动时要开的那篇在别的窗口里开着，就开上次那篇或最近改过的另一篇（`src/drafts/drafts.js` 的 `firstClaimable`，页面经 `window/claim` 问壳）。

**窗口之间同步**：每次写进本机存储后经 `BroadcastChannel("mediacraft-store")` 告诉别的窗口写了哪些稿子、删了哪些、改了哪些 meta（`src/drafts/store.js`）。别的窗口重读这几篇（它自己正开着的那篇除外——别的窗口不会写它），稿件列表跟着变；署名换到表单与卡片上，「我的配色」下次用时重读；发布助手的偏好本来就每次从本机读。正开着的那篇在别的窗口里删了：这个窗口不再存它，换到另一篇，状态栏说「「…」在另一个窗口里删掉了，已换到另一篇」；它排着的写入里那篇的部分丢掉，并再删一次（删之前已经在写的不会把它写回来）。页面换走时（`pagehide`）关掉广播与库。

**重开 App 恢复窗口**：壳把开着的窗口记在 `~/Library/Application Support/MediaCraft/windows.json`（每个窗口开着的那篇与位置大小，开关窗口、换稿子、到前面来、挪动、改大小时更新）；退出时的样子不再改。下次启动照着一个个开回来（位置挪回屏幕里）；要开的那篇已经不在了的窗口，页面报 `window/missing`，还有别的窗口时关掉它；没有记录（上次关掉了所有窗口）时开一个窗口打开上次那篇。

- 文件 › 新建窗口（⌘⇧N）：新窗口里是一篇新稿子。
- 稿件列表里 ⌘ 点一篇、或右键「在新窗口打开」：在新窗口打开那篇，这个窗口不换（浏览器里没有这一项，⌘ 点照常打开）。右键菜单另有「删除…」（内置说明书没有）。
- 关掉一个窗口不影响别的窗口；关掉最后一个窗口时 App 退出（先结束所有 AI 进程）。
- 关窗、退出、⌘R 重新载入之前，壳先让页面把稿子存完（`drafts.saveNow()`，每个窗口最多等 3 秒，页面卡住也照样往下走）。
- 文件 › 保存（⌘S）：最前面那个窗口马上存（页面自己也接 ⌘S，见 [drafts](#drafts稿子) 的存盘）。

壳（`macos/Sources/MediaCraftShell/`）：全 App 共用一份 `ShellCore`（AI 会话的进程、实况合成、外部 Agent 的套接字、卡片出图、网页的数据存储），每个窗口一个 `ShellWebView`，它的原生桥知道请求来自哪个窗口。AI 的一轮只推给发起它的窗口（`ai/*` 也只能动这个窗口自己发起的那一轮）；一个窗口重新载入只结束它自己发起的那几轮，关掉一个窗口时结束它发起的，之后它的页面还在路上的请求也不再起进程。实况合成的进度与外部 Agent 的状态推给所有窗口；外部 Agent 的请求按它认定的那篇交给开着它的窗口（新建的开新窗口，见 [mcp.md](mcp.md)），没认定时交给最前面的窗口。App 的窗口由 `macos/Sources/MediaCraft/main.swift` 管。

| 原生桥 | body | 返回 |
| --- | --- | --- |
| `window/open` | `{ draftId?, fresh?, panel? }`：打开这篇（`draftId`），或新建一篇（`fresh: true`）；`panel: "ai"` 时新窗口一开就是 AI 助手（地址带 `&panel=ai`，AI 助手顶上的「+」用它） | 开好一个新窗口（位置在最前面那个窗口的右下方错开一点），`{ elsewhere: false }`；那篇在别的窗口里开着时不开新窗口，把那个窗口调到前面并换到那篇，`{ elsewhere: true }` |
| `window/claim` | `{ draftId, focus? }` | 这个窗口能不能开这篇：别的窗口占着时 `{ elsewhere: true }`（`focus` 默认为真：把那个窗口调到前面、让它的页面换到那篇），否则先替这个窗口占着，`{ elsewhere: false }` |
| `window/occupy` | `{ current, drafts, page, sequence }`：这个窗口正开着的那篇（可以是说明书），与别的窗口不能再开的（正开着的自己的稿子、AI 还在跑的）；`page` 是页面启动时自己起的 id，`sequence` 是它第几次报 | `{ ok }`；同时更新 `windows.json`。同一个页面序号旧的丢掉；窗口换了页面（重新载入、页面进程崩了）之后，旧页面迟到的报告也丢掉，新页面报来之前壳照旧替它占着正开着的那篇 |
| `window/missing` | — | 这个窗口要开的那篇已经不在了：还有别的窗口时关掉它，`{ closed }` |
| `window/app-info` | — | App 的版本号与能不能检查更新：`{ version, updates }`（AI 设置 › 关于用它显示版本） |
| `window/check-updates` | — | 像点了「Vibepost › 检查更新…」：交给 App 的更新器（见 [release.md](release.md)）；浏览器、测试里没接更新器时 404 |
| `window/edited` | `{ edited }` | 这个窗口有没有还没存进本机的改动（存盘状态是 pending / saving / error）：壳设窗口的 `isDocumentEdited`，关闭按钮上显示小圆点；`{ ok }` |
| `window/bind-agent` | `{ session, draftId }` | 外部 Agent 的这次会话（`mediacraft-mcp` 的会话编号）认定这篇：壳记着，之后它的请求交给开着这篇的窗口（`src/mcp/server.js` 认定、新建、打开之后调用） |

壳 → 页面：`mediacraft:native-window` 事件，`{ type: "show", draftId }` 让这个窗口换到那篇（别的窗口要开它）。`src/native-bridge.js` 包成 `MediaCraftNative.windows.open / claim / occupy / missing / edited`，页面这边在 `src/drafts/windows.js`。

## 写作手册（原生桥）

写作手册只管写什么、什么口味，文件在 App 支持目录的「写作手册」文件夹（布局见 [storage.md](storage.md#写作手册写作手册)，壳 `WritingManuals.swift`，第一次用时照 `src/writing-manuals/` 的示例建好）。页面经原生桥 `POST mediacraft://app/__native/manuals/<动作>`（body 是 JSON）调用，`src/native-bridge.js` 包成 `MediaCraftNative.manuals`；浏览器里没有（AI 设置里这一节不显示，`save_writing_manual` 回错误）。几个窗口共用一份，读写排在一把锁里。

| 动作 | body | 返回 |
| --- | --- | --- |
| `manuals/list` | — | `{ manuals: [{ name, description }], folder }`：按名字的拼音排，`folder` 是文件夹的路径 |
| `manuals/read` | `{ name }` | `{ name, description, content }`（`content` 是正文，不含开头的 `name` / `description`）；没有这份时 404 |
| `manuals/save` | `{ name, description, content }` | 新建或整份换掉（页面先问过你），`{ name, description }`；名字、说明、正文不合规矩（见 `save_writing_manual`）或文件名撞上别的手册时 400 带中文原因 |
| `manuals/reveal` | `{ name? }` | 在 Finder 中显示这份；没给 `name` 时打开文件夹。`{ ok }` |
| `manuals/open` | `{ name }` | 用默认的 App 打开这份。`{ ok }` |

在 Finder 中显示、用默认的 App 打开经 `ShellCore.revealFile` / `openFile`（测试 harness 换成记下来）。**界面**：AI 助手 › 设置 › 写作手册（`src/ai/manuals.js`）：一句说明、每份一块（名字、说明、「打开」「在 Finder 中显示」）、「打开文件夹」；每次打开设置重新列一遍，`save_writing_manual` 存好后也刷新。

## 模板（原生桥）

模板是写好的整篇稿子（卡片内容 + 主题、配色、字体、封面、小红书正文、示例图），复制一份就能改（`drafts.create({ template })`，见 [drafts](#drafts稿子)）。两处来源，页面在 `src/templates/templates.js` 把它们登记成稿子记录的形状：

- **自带的**：仓库里 `src/templates/<名字>.md`，`node scripts/build-templates.mjs` 合成登记表 `src/templates/index.js`（提交进仓库；`TemplatesTests` 在页面里重新读这些文件比对，过期就不过）。图片用随网页打包的相对路径（`docs/guide-assets/…`、`docs/template-assets/…`），记录里留相对路径，和内置说明书一样直接出图。
- **自己存的**：App 支持目录「模板」文件夹（布局见 [storage.md](storage.md#模板模板)，壳 `TemplateLibrary.swift`），每套一个文件夹 `<名字>/模板.md` + 同目录的图片；页面经原生桥 `POST mediacraft://app/__native/templates/<动作>`（body 是 JSON）读写，`src/native-bridge.js` 包成 `MediaCraftNative.templates`；浏览器里没有。几个窗口共用一份，读写排在一把锁里。

**文件的格式**（`src/templates/format.js`，Node 与页面共用）：开头两行 `---` 之间是 front matter，和写作手册同一套写法（一行一个 `键: 值`，值可以加引号；`|` 后面缩进的几行换行照原样，`>` 并成一行；`键:` 后面缩进的 `子键: 值` 几行是一张表），后面是卡片内容，只用中文记号：

```markdown
---
name: 干货清单                      # 模板名（用户模板就是文件夹名）
description: 一条一页的经验清单……      # 一句话说明
tags: 清单, 简洁                     # 题材一个、风格一个
id: checklist                       # 登记表里的 id（ASCII，不写时用文件名）；用户模板不用
title: 租房第一年，我踩过的 5 个坑     # 新稿子的标题（封面用它）
theme: notes                        # 主题 id；认不出按默认主题
colors:                             # 可省：只给 bg / text / accent 时辅助、衬底按三色规则推；给了的辅助、衬底算单独调过
  bg: #ffffff
  text: #1c1c1e
  accent: #ffbd2e
fonts:                              # 可省：zh / en / code 的字体 id，没给跟随主题
  zh: lxgw-wenkai
cover:                              # 可省：首页做封面
  enabled: true
  subtitle: 看完至少省下一个月房租
  image: cover                      # 这篇里的一张图
caption: |                          # 可省：小红书正文，换行照原样
  第一段
  #话题
images:                             # 可省：图片编号 → 路径（自带的相对网页根，用户的相对它自己的文件夹）
  cover: docs/guide-assets/valley-morning.jpg
---

:::小标签
租房经验 · 第 1 期
:::
…
```

色值直接写 `#rrggbb`（不是 YAML 的注释）；值里有「: 」、以 `#` 以外的特殊符号开头时加双引号。不认识的键、认不出的值跳过；图片编号只能是字母、数字、`_`、`-`。`colors` / `fonts` / `cover` / `images` 这四张表也能写成一行（`src/templates/README.md` 与 `scripts/check-templates.mjs` 的写法，自带模板都这样写）：`cover: enabled true, subtitle 一行副标题, image cover`——半角逗号分开各项，每项第一个空白前是子键（副标题里不能有半角逗号）。`saveAsTemplate` 写回时按这个顺序生成缩进的几行，没有的键不写。

| 动作 | body | 返回 |
| --- | --- | --- |
| `templates/list` | — | `{ templates: [{ name, content }], folder }`：每套的名字（文件夹名）与 `模板.md` 全文，按名字的拼音排；文件夹还不在时为空 |
| `templates/read` | `{ name }` | `{ name, content, images: { 文件名: data URL } }`（`模板.md` 旁边认得的图片：jpg / png / gif / webp，每张最多 20 MB）；没有这套时 404 |
| `templates/save` | `{ name, content, images: [{ name, data }] }`（`data` 是 base64） | 新建或整套换掉：先在旁边的临时文件夹里写好再换到 `<名字>/`，`{ name, folder }`；名字不合规矩（同写作手册）、`content` 空着或超过 1 MB、图片文件名不对、超过 40 张时 400 带中文原因 |
| `templates/remove` | `{ name }` | 删掉那一套（整个文件夹）；没有时 404。`{ ok }` |
| `templates/reveal` | `{ name? }` | 在 Finder 中显示那一套的文件夹；没给 `name` 时打开模板文件夹（不在时先建好）。`{ ok }` |

在 Finder 中显示经 `ShellCore.revealFile`（测试 harness 换成记下来）。

## mcp：外部 Agent

终端里的 Claude Code 等 Agent 经 MCP 服务 `mediacraft-mcp` 操作 App（工具、协议、接入见 [mcp.md](mcp.md)）。实现在 `src/mcp/`（`server.js` 分派与操作记录、`tools.js` 外部 Agent 另外要的工具、`panel.js` 界面）+ 壳 `ExternalAgents.swift`（套接字、开关、本机文件的读写）。只在 App 里可用；浏览器里 `status()` 的 `available` 为 `false`。

| 方法 | 说明 | 返回 |
| --- | --- | --- |
| `status()` | 连接的状态 | `MCPStatus` |
| `setEnabled(enabled)` | 「允许外部 Agent 连接」（AI 助手 › 设置里的开关）：存进 `mcp.json`（[storage.md](storage.md#外部-agentmcp)）；关掉时已连着的先收到原因再断开，新连接被拒绝 | `MCPStatus` |
| `log()` | 外部 Agent 的操作（App 开着期间，最近 50 个，旧的在前） | `MCPLogEntry[]` |
| `undo(id)` | 撤销其中一个（与点那一行的「撤销」相同）：只撤这一个，之后的改动保留；改过的东西之后又被改过（同一处正文、同样的设置、同一张图）时 reject 并说明原因。没有撤销的（新建、打开、导出、发送）或已经撤销过的 reject | — |

`MCPStatus`：`{ available, enabled, clients, command }`：`available` 是壳在不在监听，`clients` 是连着几个，`command` 是「复制接入命令」复制的那一行（`claude mcp add mediacraft -- "<App 里的 mediacraft-mcp>"`）。

`MCPLogEntry`：`{ id, text, draftId, at, undone, undoable }`，`text` 同 AI 会话里动作行的写法（「换成主题「纯黑」」「卡片内容改写（120 字）」「导出整组卡片 ZIP：/Users/…/周末.zip」……），`at` 是毫秒时间戳，`undoable` 是现在还能不能撤销。

**改稿子的调用**每个都是撤销历史里的一步（⌘Z），同时记一条可以单独撤销的操作；只看、只改这次 Agent 会话认定的那篇（它新建、打开的，没有时是它第一次看、改稿子时正在编辑的那篇；按会话编号记在 sessionStorage 的 `mediacraft.mcp.working`，重连、页面重新载入都还在）：用户在 App 里切到别的稿子后，看稿、改稿、出图、导出、发送的工具都报错，说明用 `open_draft` 接着改。工具调用与 `undo` 排在一个队列里一次做一件。内置说明书照 App API 的规矩拒绝。

**界面**：有连接时顶栏出现「外部 Agent」（点开切到 AI 助手、展开操作记录）；AI 助手里「外部 Agent 的操作」一行一个，行尾「撤销」；AI 助手的设置里是开关、接入命令与「复制接入命令」。

### 页面与壳之间（原生桥）

页面 → 壳：`POST mediacraft://app/__native/mcp/<动作>`，`src/native-bridge.js` 包成 `MediaCraftNative.mcp`。

| 动作 | body | 返回 |
| --- | --- | --- |
| `mcp/status` | — | `MCPStatus` |
| `mcp/settings` | `{ enabled }` | `MCPStatus` |
| `mcp/write?request=<凭据>&name=<文件名>` | 文件本体 | 外部 Agent 的导出：写进这次 `export` 调用登记的目录（凭据只在这次调用进行中有效，页面自己选不了目录），文件名只取最后一段；同名文件已经有了且没给 `overwrite: true` 时失败。返回 `{ path, name }` |

壳 → 页面：外部 Agent 的每个请求，壳调用页面的 `window.MediaCraftMCP.handle(JSON 文本)`（页面还在载入时等它准备好，最多 30 秒），收到 `{ result }` 或 `{ error }`（JSON 文本）。请求是 `{ session, method: "tools/list" | "tools/call", params, files?, exportRequest? }`：`session` 是 `mediacraft-mcp` 这次会话的编号（重连不变）；`files` 是壳按 `import_images` 的路径读好、校验过的图片（`[{ path, name, type, data（base64）}]`，页面不自己读本机文件）；`exportRequest` 是 `export` 的凭据。连接数变化时派发 `window` 上的 `mediacraft:native-mcp` 事件，`detail` 是 `{ type: "clients", count }`。
