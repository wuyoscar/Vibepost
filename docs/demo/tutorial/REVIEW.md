# 教程视频：交付说明（2026-11-16）

成片：`docs/screenshots/tutorial.mp4`（配乐，-17 LUFS）与 `docs/screenshots/tutorial-silent.mp4`（无声），1920 × 1080、30 fps、H.264 yuv420p、faststart，2 分 2 秒。

## 里面有什么

| 时间 | 段 | 内容 | Agent |
| --- | --- | --- | --- |
| 0–2.6 s | 开场 | 首帧就是界面，标题「Vibepost：一篇小红书笔记，从写到发」 | — |
| 约 2.6–43 s | 基础功能 | 打字出卡片、行首 / 插图、换四个主题、首页做封面、检查、手机预览、发送到 iPhone | 不用 AI |
| 约 43–67 s | 场景一 | 写好的长文：一键润色（只删了「的的」「在再」、补了一个「把」和一个逗号），全部接受；一键排版（分页、提示块、行距） | 本机 Codex |
| 约 67–89 s | 场景二 | 一篇露营长文贴进对话框：排成 3 张卡片，两张照片放在说到它们的地方，起了标题、写了小红书正文 | 本机 Codex |
| 约 89–117 s | 写作手册 | AI 设置里的两个内置技能与四份内置写作手册；「复制一份来改」；快捷命令「存成我的写作手册」，确认框里看改动后保存 | 本机 Codex |
| 117–122 s | 片尾 | 图标、名字、一句话、仓库地址，停 3 s | — |

Agent 的回复是真的，每次录都不一样；等回复的部分快进 8 倍，画面上标着「快进 ×8」。

## 检查了什么

- `npx hyperframes check`：通过。剩下的警告：14 处 `dead_stretch`（界面停着读字幕或等快进，是有意的）、`font_face_local_only`（苹方只在这台 Mac 上有，只在本机渲染）、两条结构建议。
- 抽帧拼图（`framesheet.py`）：首帧有主体，最后一帧是片尾；每一段的字幕在 80% 安全框里，没有压住正在点的控件。
- 声音：配乐版 -16.9 LUFS，峰值 -3 dBTP。**没试听过，请听一遍。**

## 还没做的

- **场景三（找热点写成一篇）和外部 Agent（终端里的 Claude Code 经 MCP 连进来）没录**：这两段要本机的 Claude Code。录的时候它的登录已经过期（`claude -p` 回「OAuth session expired」），需要在终端里重新登录。Codex 的沙盒不能联网，所以场景三不用它录。登录后：
  `DEMO_FRAMES_DIR=<帧目录> DEMO_PART=topic DEMO_AGENT_BIN=<claude 所在目录> macos/run-tests.sh --filter DemoFramesTests 1500`，`agent` 一段同理，再照 SPEC.md 末尾的命令重出。
- 两个视频共 33 MB，放进 git 会让每次 clone 都多 33 MB；也可以只附在 GitHub Release 里，README 链接过去。
