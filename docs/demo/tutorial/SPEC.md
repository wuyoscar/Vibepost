# 详细教程（按功能一段段讲；主视频的分镜在 SPEC.md）

```text
GOAL:    看完的人知道 Vibepost 是什么，并且能照着做出第一篇：写、排、改、查、发。
OUTPUT:  HyperFrames，1920 x 1080，30 fps，mp4（H.264、yuv420p、faststart）；另出一份配轻音乐的
TIME:    开场 2.6 s + 各段底片首尾相接（每段的时间表在帧目录的 <段名>/screen.json）+ 收尾 4.4 s；
         基础功能约 40 s，每个使用场景 20–40 s（等 AI 的部分快进 8–10 倍，画面不动时再压短）
LOOK:    画面就是界面本身，铺满 16:9，不加边框、不放进样机。
         字：PingFang SC Semibold，白字 44 px，字距 0，压在墨色块（#16171a，圆角 12 px，左右内边距 28 px，高 84 px）上；
         墨色块在画面下方居中、下边距 112 px（在 80% 标题安全框里），一次只有一句。
         快进的地方在字幕上方加一块小的墨色标记「快进 ×8」（28 px），只在快进时出现。
         不另加强调色：画面里唯一的彩色是界面本身和片尾的 App 图标。
         阴影：墨色块下 0 10 px 30 px、18% 黑；不加颗粒、暗角、光晕。
OBJECTS: 窗口（真实截图）、指针（底片里画好的 macOS 箭头，点的时候一圈蓝色涟漪）、收尾的 App 图标（brand/icon.png）。
MOTION:  镜头推近 / 平移：18 帧，power3.inOut；一段里只推一次，推到正在用的那一块（放大 1.28–1.5 倍）。
         字幕进场：墨色块从左到右擦出来 8 帧（clip-path），power2.out；出场直接切掉，不淡出。
         文字落定以后不再动。
SHOTS:   0.0–2.6    全景，窗口里已经有标题和第一段；标题「Vibepost：一篇小红书笔记，从写到发」（62 px，同一种墨色块，第 0 帧就在）
         先讲基础功能（basics，不用 AI）：
           write    推到编辑区 + 舞台；打出小标题和三条列表，卡片跟着排；行首打 /，菜单弹出，插进一张图
           themes   平移到舞台 + 检查器；点四个主题
           cover    同一个机位；勾上封面，翻回第一张看封面
           publish  拉回全景：检查面板、手机预览
           send     点「发送到 iPhone」，出「已发送」
         再讲使用场景（都是本机真的 Agent 跑出来的，回复每次不一样）：
           polish   写好的长文：一键润色，修改标在正文里（推到编辑区看），全部接受；再一键排版
           paste    一篇现成的长文贴进对话框，排成图文卡片；换一个主题
           topic    点名「论文与技术解读」手册，让 AI 找最近的热点写成一篇（联网前的确认框照实出现）
           manuals  AI 设置里的内置技能与内置写作手册；复制一份来改；把这篇存成我的写作手册（确认框）
           agent    终端里的 Claude Code 经 MCP 连进来新建一篇、排版、换主题
         end        界面模糊着退后，露出浅色底（#f2f2f4）：图标落定，「Vibepost」逐字出现，一句「用 Markdown 写小红书的桌面 App」，下面仓库地址；停 3 s
BANNED:  深色空底上飘着小界面；光晕、粒子、渐变底；把截图压暗再压标题；每一段都淡入上滑；
         和内容无关的角标、边框、编号「01 / 02」；胶囊形的标签；字幕落定后还在动；三张卡片并排；logo 挂在角上。
QA:      每一段开头后 0.5 s 一帧：字幕在安全框里、没压住正在操作的控件；
         推近的画面里正在点的按钮在画面内；最后一帧是收尾卡；首帧不是空的。
```

素材是真的：界面是测试 harness 里真实的页面逐帧截的（`macos/Tests/MediaCraftShellTests/DemoFramesTests.swift`，一段一段录）。
基础功能一段不用 AI；使用场景几段用的是本机真的 Claude Code 或 Codex（用这台机器的登录），权限确认、保存确认都是它们当时真的弹出来的，
等回复的时间快进并在画面上标明。隔空投送的接收端是假的；别的都是页面自己的行为。

重做：`DEMO_FRAMES_DIR=<帧目录> DEMO_PART=<段名> DEMO_AGENT_BIN=<claude 或 codex 所在的目录> macos/run-tests.sh --filter DemoFramesTests 1500`，
`uv run scripts/make-demo.py <帧目录> docs/screenshots`，再在 docs/demo 里 `uv run tools/build.py <帧目录>`、`uv run tools/sound.py`，然后在 docs/demo/tutorial 里 `npx hyperframes check`、`npx hyperframes render`。
