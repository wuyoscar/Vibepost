# 主视频「你写，Agent 排」：交付说明（2026-11-16，第二版）

成片：`docs/screenshots/vibepost.mp4`（配乐）与 `docs/screenshots/vibepost-silent.mp4`（无声，不进 git），1920 × 1080、30 fps、H.264 yuv420p、faststart，73.5 秒，14 MB。封面：`docs/screenshots/vibepost-cover.png`（1920 × 1080）与 `vibepost-cover-3x4.png`（1242 × 1656）。分镜与规格见 `SPEC.md`。

## 第二版改了什么

- 整条片子快 1.25 倍（排的时候按一秒 24 帧算，放的时候一秒 30 帧；弹簧、光标、字的来去都一起快），成片 120 BPM。
- 配图：一张五拍。图飞进去以后，在带图的那一页上停 1.4 秒再翻下一页（第一版只停了 0.4 秒，看着像图没放进第一页）。
- 加了十拍「自己动手调」：换两个主题再换回来、图文尺寸换成 9:16 再换回 3:4、按着滑块把图片拖大再拖回来。
- 片尾去掉了那行定位的话，只留图标、名字、仓库地址。
- 配乐换成 `tools/groove_music.py`：有鼓点，编排跟着镜头走（开头只有几个音，亮名字时鼓进来，擦「之前 / 现在」时鼓停，发到手机时最满，结尾三句各一个和弦）。旧的那首还在：`uv run tools/sound.py . 120 soft`。

## 里面有什么

| 时间 | 镜头 | 内容 |
| --- | --- | --- |
| 0–4 s | 开头 | 「写完了。还要排版、配图、分页。」窗口里是一整屏没排过的字 |
| 4–10 s | 现状、点题 | 窗口摆正，镜头推到全是字的卡片；「Vibepost：你写字，Agent 排版。」光标点开 AI 助手，面板分成两块 |
| 10–15 s | 说一句 | 对话框里打出那句要求，发送 |
| 15–22 s | Agent 动手 | 右边是 Agent 的每一步，左边的卡片同时变样；三张配图候选出来。快进 ×17 |
| 22–26 s | 你点头 | 编辑器里逐处标出的修改，光标点「全部接受」 |
| 26–33.5 s | 配图 | 三次：点一张候选图，图飞进那道菜的一页，停住 |
| 33.5–36.5 s | 之前 / 现在 | 光标在卡片上拖一条线，线左边是开头那张没排过的 |
| 36.5–41.5 s | 自己动手调 | 主题、图文尺寸、图片大小 |
| 41.5–48.5 s | 写卡片样式 | 让 Agent 给这篇写一套卡片样式（快进），再逐页翻过去 |
| 48.5–52.5 s | 写作手册 | 「存成我的写作手册」，确认框，保存 |
| 52.5–59.5 s | 终端 | 终端里的 Codex 经 MCP 新建一篇、分页、换主题（快进），翻三页 |
| 59.5–66.5 s | 发到 iPhone | 点「发送到 iPhone」，三张卡片飞进手机 |
| 66.5–73.5 s | 结尾 | 「你写字。Agent 排版。你点头。」手机收成图标，名字和仓库地址 |

画面里 Agent 的话、三张配图、改的样式、终端输出都是那一次真跑出来的（本机 Codex 0.167.2，App 里一次、终端里经 MCP 一次），所以重录一遍内容会不一样。快进的倍数按录制时每帧记下的时刻算。终端里只放了 Codex 说的话和它调的 MCP 工具名，每段话留前两行。「自己动手调」那一段是另录的（`tune`，不用 AI）：稿子是 `collab` 那一段排好的原文，三张配图是那一段里 Agent 生成的原图，字号和图片高照那一段设的；分页是四页（那一段是三页），所以页眉上的页码不一样。

## 检查了什么

- `npx hyperframes check`：通过，没有错误，没有读不完的字。剩下的警告：`dead_stretch`（它只看页面元素，不看录屏里的变化；那几段录屏在动）、`font_face_local_only`（苹方、SF Mono 只在这台 Mac 上有，只在本机渲染）、`duplicate_media_discovery_risk`（两块面板用的是同一条录屏，有意的）、两类结构建议。
- 抽帧（`hyperframes snapshot` 12 帧看配图停留、手调那段和片尾；`framesheet.py` 12 帧）：首帧有主体，最后一帧是片尾；配图落下后那一页带着图停住。
- 体积：渲染出来 27 MB，再压一遍到 14 MB（libx264 crf 21，和渲染结果比 PSNR 49 dB）。
- 声音：-16.8 LUFS，峰值 -4.9 dBTP。**新配乐没试听过，请听一遍。**

## 没做的、要知道的

- Agent 写的卡片样式改动不大（标题变番茄红、底色变暖）。要更明显得重录 `collab` 一段，约 12 分钟。
- 稿子没填标题和小红书正文，所以手机上卡片下面只有一行标题（取自正文第一个标题行）。
- 配乐是现场合成的。想用真的曲库：`npx hyperframes auth login`（免费）之后可以从 HeyGen 的曲库里挑。
- 重出：`uv run tools/film.py <帧目录>`、`uv run tools/sound.py .`、`npx hyperframes@0.9.55 check`、`npx hyperframes@0.9.55 render -o renders/film.mp4 --video-frame-format png`，再用 ffmpeg 做 -17 LUFS 的配乐版（`-c:v libx264 -crf 21 -preset slow -af loudnorm=I=-17:TP=-2:LRA=11`）和无声版。帧由 `DemoFramesTests` 的 `collab`、`agent`、`tune` 三段录（前两段 `DEMO_AGENT_BIN` 指向 codex 所在的目录；`tune` 要先把那三张配图放到 `docs/demo/assets/brunch-1.png`–`brunch-3.png`）。
- 封面：`cover.html` 用无头 Chrome 截图，横版 `--window-size=1920,1080`，竖版地址后加 `#tall`、`--window-size=1242,1656`。
