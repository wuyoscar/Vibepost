# 本机存储

稿子只存在这台 Mac 上，由稿件模块（`src/drafts/`）读写。页面的 origin 固定为 `mediacraft://app`，换 origin 就读不到了。

## 布局

**IndexedDB `mediacraft`（版本 1）**

| 表 | 主键 | 内容 |
| --- | --- | --- |
| `drafts` | `id` | 每篇稿子一条记录，不含图片与视频本体 |
| `media` | `key`（`稿子 id/image/图片 id` 或 `稿子 id/video/视频 key`），索引 `draftId` | `{ key, draftId, kind: "image" \| "video", id, data }`：图片存 Blob（少数还原不回原样的 data URL 原样存字符串），实况存原视频文件 |
| `meta` | `key` | `profile`：署名 `{ name, handle, avatar, avatarCrop }`；`palettes`：我的配色，见下 |

**localStorage `mediacraft.prefs.v1`**：`{ currentDraftId, lastTheme }`。丢了只影响下次先打开哪篇、新稿子用什么主题。

**localStorage `mediacraft.ai.v1`**：`{ backend, models: { claude, codex }, model, image: { provider, model } }`，AI 助手的偏好（`src/ai/session.js`）：上次选的后端（新稿子用它；没有时本机有 Codex 就用 Codex，否则 Claude Code）、每个后端上次选的模型（没选过模型的稿子沿用它，`null` 为跟随后端自己的设置；`model` 是这版之前只记 Claude Code 时的写法，`models.claude` 没有时读它）、用 Claude Code 时生图用哪个模型（`provider` 只有 `openai`，`model` 为 `null` 是默认；这版之前选过 `gemini` 的读成 OpenAI 的默认模型）。丢了只是回到默认（按本机有没有 Codex 选后端、跟随后端自己的设置、`gpt-image-2`）。

**几个窗口**共用这一份存储（每个窗口一篇稿子，同一篇只在一个窗口里开）：每次写完经 `BroadcastChannel("mediacraft-store")` 告诉别的窗口写了哪些稿子、删了哪些、改了哪些 meta，别的窗口重读（见 [app-api.md](app-api.md#窗口一个窗口一篇稿子)）。`mediacraft.prefs.v1` 的 `currentDraftId` 记的是最后打开的那篇（哪个窗口都算），`lastTheme` 每次从本机读。

**localStorage `mediacraft.onboarding.v1`**：新手引导看完或跳过后为 `"done"`（`src/onboarding.js`）。丢了只会在还没有自己的稿子时再弹一次引导。

**localStorage `mediacraft.publish.v1`**：`{ beforeSend, fontNotice, ignored: { 稿子 id: [提醒的 key] } }`，发布助手的偏好（`src/publish/assistant.js`，见 [publish-check.md](publish-check.md)）：发送前自动检查、用到系统字体时提醒（都默认开）、每篇忽略了哪些提醒（key 是「分组:命中的字」，如 `absolute:最佳`）。丢了只是都回到默认、忽略过的再提醒一次。

稿子记录：

```js
{
  id, title, markdown,
  caption?,                          // 小红书正文：发布时图片下面的那段（纯文本），和卡片内容 markdown 分开；这版之前的稿子没有，按 "" 读
  mode,                              // "cards" | "article"
  theme,                             // 主题 id
  colors: { bg, text, accent, secondary, surface },   // 这篇的配色（#rrggbb）
  tunedColors,                       // 单独调过的辅助、衬底（["secondary"]……），没列出的按三色规则跟着底色与正文色走
  fonts: { zh, en, code },           // 字体 id，"theme" = 跟随主题
  fontSize?, lineHeight?, imageMaxHeight?,   // 缺的按默认值
  cover?: { enabled, subtitle, image },      // 首页做封面、副标题、底图（图片 id）；这版之前的稿子没有，按不做封面
  cardCss?: string,                          // 这一篇自己的卡片样式（HTML 卡片，检查器「高级 · 卡片样式」，最长 20000 字）；没有按空
  article: { theme?, font?, size?, color? }, // 旧版的长文样式，只为迁移原样保留；长文现在跟随主题，新稿子为 {}
  images: { 图片 id: 图片信息 },       // 名字、来源文件名、裁剪、版式、实况的原视频信息与设置……不含画面；随网页打包的图片留 src 相对路径
  legacy?,                           // 旧版里新模型不认识的字段，原样保留，不参与排版
  ai?,                               // AI 会话（本机 Claude Code），见下
  versions?,                         // 每轮 AI 之前存的版本，见下
  createdAt, updatedAt,
}
```

- 只有迁移来的旧稿子会缺字段；在新版里改过一次就补全了。
- `images` 里可以有不在正文里的图：只给封面用的底图（检查器「封面」里上传的）、从正文里删掉了文字标记的图。它们跟着稿子存、跟着稿子删。
- `colors`：这版之前存的稿子只有 `bg`、`text`、`accent`，打开时辅助色与衬底按三色规则推出来（[app-api.md](app-api.md#五个颜色角色)），之后改了这篇、存盘时写成五个（只是打开不算改动）；撤回到这版之前存的版本（`versions`）时同样处理。旧版迁移来的缺哪个按主题配色补。
- `markdown`（v6 起，每轮 AI 之前存的版本里的 `draft.markdown` 一样）：这版之前写的英文记号（`[[image:…]]`、`{{color:…|…}}`、`:::kicker`、`align=center` 等）打开时换成中文写法（`src/engine/markdown.js` 的 `localizeMarkers`，代码块、行内代码里的不动），换过的一次写回存储，不算修改、不改 `updatedAt`。
- `theme`：v5 定稿的八个主题是 `notes`（备忘，默认）、`plain`（纯白）、`journal`（手帐）、`glow`（柔光）、`clay`（陶土）、`editorial`（杂志）、`poster`（撞色）、`ink`（纯黑）。之前的八个主题不再有，用它们的稿子换成接替的新主题（`src/themes/themes.js` 的 `RETIRED` 与 `migrate`）：

  | 旧主题 | 换成 |
  | --- | --- |
  | `white` 白、`gray` 灰 | `plain` 纯白 |
  | `paper` 纸 | `clay` 陶土 |
  | `mist` 雾 | `glow` 柔光 |
  | `sage` 苔 | `notes` 备忘 |
  | `night` 暗夜、`cyber` 赛博 | `ink` 纯黑 |
  | `waste` 废土 | `journal` 手帐 |

  配色没调过（背景、文字、强调三色和旧主题当时的一样、没有单独调过的辅助或衬底，或者根本没存配色）的换成新主题的配色，`tunedColors` 清空；调过的原样保留。每轮 AI 之前存的版本（`versions[].draft`）同样换；「上次选的主题」（`mediacraft.prefs.v1` 的 `lastTheme`）按表读；认不出的主题按默认主题。启动时把换过的稿子一次写回（不改 `updatedAt`）；别的窗口读到的旧记录也照样换。
- `tunedColors`：这版之前存的稿子与版本没有这个字段，打开（撤回）时按值推断一次：五色里和三色规则推出来的值不一样的辅助、衬底算单独调过，只有三色的都算没调过；之后按标记走，存盘时写进来（只是打开不算改动）。
- `updatedAt` 只在内容真的变了才改（只是打开不算），稿件抽屉按它排序。
- 每次存盘是一个事务（记录 + 新增、删除的图片），要么全成要么全不成。存不进去时状态栏报错，改动留在窗口里，下次存盘重试；切换、新建稿子前必须先存好，存不进去就不切换。
- 删稿子连同它的全部图片与实况视频一起删。
- 界面上删掉的图片（预览里删除），图片在下次存盘时从 `media` 删掉，实况视频立刻删掉——**版本还用着的除外**（见下），等用着它的版本都删了再清。

### 实况：图片记录里的字段

实况在稿子里就是一张图（`[[image:…]]`），原视频存在 `media` 表（`kind: "video"`，键是 `videoKey`），记录里是（`src/media/live.js`，设置的含义见 [app-api.md](app-api.md#media图片与实况)）：

```js
{
  kind: "live",
  src,                  // 封面：封面那一刻按取景截下的 JPEG（data URL），卡片上静止时显示它，排版按它的比例
  name,                 // 默认「视频文件名 · 实况」
  videoKey, videoName, videoType, videoDuration, videoWidth, videoHeight,   // 原视频（宽高按显示方向）
  liveSettings: { duration, speed, start, coverOffset, sound, crop, aspect },
  crop: null, layout,   // 实况不用图片裁剪（取景在 liveSettings.crop），版式同图片
}
```

- `crop` 是 0–1 的取景框；`aspect` 只记编辑器里选的比例（`original` / `free` / `3:4`…）。读的时候缺的、不认识的按默认值，不改写记录。
- 旧版写下的实况还带着 `customAspect`、`focusX`、`focusY`（`aspect` 写成 `"1.777778"` 这样的数），原样保留；在编辑器里改过一次就换成上面的样子。
- 在预览里删掉一段实况时，它的视频先从本机存储里删掉、内存里留着：⌘Z 找回时写回去；换了稿子（撤销不回来了）才从内存里放掉。

### AI 会话：`ai`

每篇稿子一个 AI 会话（`src/ai/session.js`，后端的适配在 `src/ai/backends/`，接口见 [app-api.md](app-api.md#aiai-会话本机-claude-code-或-codex)）。只有用过 AI 的稿子才有这个字段；内置说明书没有。

```js
ai: {
  backend,            // 这篇用的后端："claude"（本机 Claude Code）或 "codex"（本机 Codex）；第一轮一开始就记上，有了对话就不再变，「重新开始这篇的对话」后才能换。
                      // 没有这个字段、却有对话的（这版之前的）按 "claude" 读；什么都没有的新稿子为 null（用上次选的，见 mediacraft.ai.v1）
  sessionId,          // 后端那边的会话 id（Claude Code 是页面起的 UUID，下一轮 --resume 它；Codex 是它起的线程 id，下一轮 thread/resume 它）
  resumable,          // 这个会话已经在后端那边建好（至少答过一次）；为 false 时下一轮开新会话
  model?,             // 这篇选的模型：别名（Claude Code 的 "opus" / "sonnet" / "haiku"）、模型 ID，或 null（跟随后端自己的设置），属于 backend 那个后端；
                      // 没记 backend 时存的模型是 Claude Code 的（这版之前只有它），换成别的后端时不用它。
                      // 没有这个字段时沿用这个后端上次选的（localStorage mediacraft.ai.v1）。「重新开始这篇的对话」清空记录时保留
  messages: [...],    // 给人看的会话记录（AIMessage，见 app-api.md），只留最近 200 条，每条回复最多存 8000 字
  review?,            // 待确认的 AI 修改（修改对比），确认完删掉：
                      // { turnId, base: { markdown, title, caption }, markdown, title, caption, decisions: { 那一处的 key: "accepted" | "rejected" } }
                      // base 是那一轮发出时的卡片内容、标题与小红书正文，markdown / title / caption 是 AI 改成的；每次显示都挪到现在的正文上重算（src/ai/diff.js），
                      // key 由 base 与 AI 的稿子定（第几处，冲突时如 "2+3"；标题是 "title"，小红书正文是 "caption"），所以决定在正文变了之后仍然对得上；
                      // 这版之前存下的没有 caption，算小红书正文没改
  lastActive?,        // 最近一次 AI 活动的时间（毫秒）：每一轮进行中与说完时记（会话历史按它排，ai.sessions()）；
                      // 这版之前的没有，按 updatedAt 算。「重新开始这篇的对话」清空记录时一起去掉
}
```

- 会话记录存的是显示用的摘要（用户说的话、Claude 的回复、用过的工具与 App 里做的动作各一行、权限请求的回答、配图候选的缩略图、每轮结尾的结果），完整的对话在后端自己那边（Claude Code 的 `~/.claude/projects/`、Codex 的 `~/.codex/sessions/`，不归 App 管：删稿子时不删）。动作怎么撤销、「本次会话都允许」只在 App 开着期间记在内存里（配图的放行范围记在壳里），不存盘。
- 写会话记录不算改稿子：不改 `updatedAt`，稿件抽屉的顺序不变；AI 助手的会话历史按 `ai.lastActive` 排。
- 旧版本（第 15 张票之前）留下的 `pending` 不再读，下次写会话记录时去掉。
- 会话记录与稿子的其他字段一起存盘（同一条记录、同一个事务）；改稿子时原样带着走。

### 版本：`versions`

每轮 AI 开始前给稿子存一个版本（`src/drafts/drafts.js` 的 `addVersion`，由 `src/ai/versions.js` 调用；撤回见 [app-api.md](app-api.md#版本aiversions)）。按先后排，最新的在最后；**每篇最多 50 个**，存第 51 个时删最旧的。

```js
versions: [{
  id,        // 那一轮的 turnId
  at,        // 存的时间（毫秒）
  label,     // 那一轮说的话，最多 40 字
  draft: { title, caption, markdown, mode, theme, colors, tunedColors, fonts, fontSize, lineHeight, imageMaxHeight, cover, cardCss, images },
}]
```

- `draft` 的字段与稿子记录里的同名字段一样，是存版本那一刻界面上的样子（存之前先把当前稿子存盘）。这版之前存的版本没有 `caption`，撤回时正文栏不动。`images` 只有图片信息，没有画面：画面还是 `media` 表里那一条。
- **版本用着的媒体不删**：`draft.images` 里的图片、实况图片的原视频（`videoKey`），就算稿子里已经删了，也留在 `media` 表里；删掉最旧的版本时，只有它用着、别的版本与当前稿子都不用的实况视频跟着删，图片在下次存盘时清掉。
- 存版本不算改稿子（不改 `updatedAt`，稿件抽屉的顺序不变）；撤回改了正文等字段，和平常改稿一样存盘。
- 与稿子的其他字段一起存盘（同一条记录、同一个事务）；改稿子时原样带着走。

## AI 的工作副本

`~/Library/Application Support/MediaCraft/ai/`（壳管，页面不直接读写）：

| 位置 | 内容 |
| --- | --- |
| `<稿子 id>/AGENTS.md`、`<稿子 id>/写作手册/` | 每轮开始时重写：`AGENTS.md` 是页面给的操作手册全文，末尾是写作手册的目录（「- 名字：说明（写作手册/文件名）」与怎么用、怎么提议修改）；`写作手册/` 是下面「写作手册」文件夹里每份手册的拷贝（拷的是内容，不是链接）。Agent 在这一轮里改了也不留，下一轮照用户的文件夹重写 |
| `<稿子 id>/draft.md`、`title.txt`、`caption.txt` | 这篇稿子的工作副本：每轮开始前写入编辑器里当前的卡片内容、标题与小红书正文，后端（claude / codex）在这个目录里运行、直接改这几个文件；App 的工具改了分页、段落顺序、图片位置时同步写进 `draft.md`；一轮结束后读回来比对。只是中转，丢了不影响稿子。目录常驻（不是每轮一个临时目录）：Claude Code 按工作目录记会话，`--resume` 要在同一个目录里才接得上；Codex 的工作区（`workspace-write` 能改的范围）就是这个目录 |
| `.candidates/<稿子 id>/<id>.<扩展名>` | 放进会话的配图候选原图（`propose_images` 载入的、`generate_image` 生成的、Codex 自带的生图生成的一份拷贝——它的原图在它自己的目录里，不动）（点了才插进稿子，插进去的是一份拷贝）。不放在工作副本目录里：后端在那里运行，读不到你同意载入的目录外图片的拷贝。丢了只是那张候选插不了 |
| `settings.json` | `{ claudePath?, codexPath? }`：在「AI 设置」里指定的 claude / codex 路径，没有时在终端的 PATH 里自动找（改一个不动另一个） |

删稿子时它的工作副本目录与配图候选一起删（壳的 `ai/remove`：正在载入的配图候选先取消，这篇还在跑的一轮先停掉、等进程退出，删完不会再写回来）；后端自己的会话记录（`~/.claude/projects/`、`~/.codex/sessions/`）不删，删除确认框里也这样说明。工作副本没删掉时稿子照样删了，状态栏说明原因。

### 写作手册：`写作手册/`

`~/Library/Application Support/MediaCraft/写作手册/`（壳管，`WritingManuals.swift`；测试时是 harness 临时目录里的 `写作手册/`）：用户的写作手册，只管写什么、什么口味（排版的写法在操作手册里）。每份一个 `.md`，开头两行 `---` 之间是 `name:`（手册名）与 `description:`（一句话说明，一行、最多 200 字；值可以加引号，`>` / `|` 后面缩进的几行并成一行），后面是正文：

```markdown
---
name: 小红书图文
description: 通用的小红书图文笔记：给谁看、标题怎么抓人……
---

正文……
```

- 没有开头那一段时名字是文件名、说明空着；同名的只认文件名排在前面的那份；不是 UTF-8、超过 1 MB、隐藏文件、不是 `.md` 的不算手册。列出时按名字的拼音排。
- 文件夹不在时（第一次用：打开 AI 设置、AI 的第一轮、外部 Agent 列出）用 App 自带的示例（网页根目录的 `src/writing-manuals/`：小红书图文、代码库解读、国际新闻）建好；已经在了就不动，删掉的示例不会补回来。
- 用户用任何编辑器改，App 每次都读最新的（AI 下一轮就用新的）。Agent 经 `save_writing_manual` 提议的新建、修改，用户在确认框里同意才写：已有的名字写回它原来的文件，新的写成 `<名字>.md`（名字 1–40 字，不能有 `/ \ :` 与控制字符、不以 `.` 开头；文件名撞上别的手册时不覆盖）；写回时开头重新生成（要加引号的加上），正文末尾留一个换行，最多 200 KB。
- **App 从不删这个文件夹和里面的文件**（删稿子、重新开始对话、检查更新替换 App 都不碰）；要删一份手册在 Finder 里删（AI 设置 › 写作手册 › 打开文件夹）。

### 窗口：`windows.json`

`~/Library/Application Support/MediaCraft/windows.json`（壳管）：开着的窗口，`[{ draftId, frame: [x, y, 宽, 高] }]`，按先后（最后一个在最前面）。开关窗口、窗口换稿子、到前面来、挪动、改大小时重写；App 退出时的样子不再改，下次启动照着恢复（见 [app-api.md](app-api.md#窗口一个窗口一篇稿子)）。关掉最后一个窗口时写成空的，下次开一个窗口打开上次那篇。丢了只是不恢复窗口。

## 外部 Agent（MCP）

`~/Library/Application Support/MediaCraft/`（壳管，[mcp.md](mcp.md)）：

| 位置 | 内容 |
| --- | --- |
| `mcp.sock` | App 开着时监听的 Unix 域套接字，`mediacraft-mcp` 连它；权限 0600，App 启动时新建（先删掉上次留下的），退出时删掉 |
| `mcp.json` | `{ allowExternalAgents }`：「允许外部 Agent 连接」开没开，没有这个文件时是关的 |

外部 Agent 的操作记录只在内存里（App 开着期间），不存盘；它改的稿子照常存进 IndexedDB。每次 Agent 会话认定的稿子记在 sessionStorage `mediacraft.mcp.working`（`{ 会话编号: 稿子 id }`，页面重新载入还在，退出 App 就没了）。

## 上限

自己的稿子最多 1000 篇（`mediacraft.drafts.limit`）。原来 24 篇的上限是因为稿子挤在 localStorage 的 5 MB 里；现在稿子与媒体都在 IndexedDB，空间按磁盘算，篇数不再是瓶颈，抽屉列上千篇、搜索都是即时的。留一个很高的上限只为防脚本（AI、MCP）失控连续建稿；到了会明说，不删旧稿。

## 我的配色

IndexedDB `meta` 表的 `palettes`（`src/themes/palettes.js`）：全局的，不属于某一篇，删稿子不影响它。

```js
{ key: "palettes", items: [{ id, name, colors: { bg, text, accent, secondary, surface }, createdAt }] }
```

- `id` 以 `mine-` 开头；`name` 最多 24 字；按存的先后排。
- 每次存、删都整条重写（一个事务）。读的时候缺颜色、色值不对的那一组跳过，不改写记录。

## 界面偏好

**localStorage `mediacraft.panels.v1`**：`{ editor }`，编辑区宽度（像素，360–760，`src/workspace/panels.js`）。丢了只是回到默认宽度。
