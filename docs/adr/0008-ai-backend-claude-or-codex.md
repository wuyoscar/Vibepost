# 0008：AI 后端可以是 Claude Code 或 Codex

- 状态：已采纳（2026-09-30）

## 背景

AI 助手原来只接本机的 Claude Code。Oscar 平时多用 Codex（它自带生图），开源之后用户手上可能只有其中一个。两者都是本机的命令行 Agent，有自己的登录、模型、技能与权限规则，也都能把 App 的工具（换主题、分页、摆图片……）当成自己的工具调用；不同的是协议：Claude Code 是 `claude -p` 的 stream-json 加控制请求，Codex 是 `codex app-server` 的 JSON-RPC。

## 决定

- **每篇稿子选一个后端**，存在稿子的 `ai.backend`。这篇有了对话就锁定；要换只能「重新开始这篇的对话」（清空会话，解锁）。新稿子用上次选的；从没选过时本机有 Codex（找到、登录了）就用 Codex，否则 Claude Code。
- **两个后端都是一轮一个进程。** Codex 也不常驻一个 app-server：每轮起 `codex app-server`，握手后 `thread/start`（第一轮）或 `thread/resume`（之后），发 `turn/start`，收到 `turn/completed` 就关上 stdin，它读到 EOF 退出。这样壳对两者的管法一样（起进程、转发输出、说完收尾、停止就是结束进程），没有闲着的后台进程，重开 App 也接得上（续线程只要线程 id；codex-cli 0.157 实测：动态工具在续上的线程里还在）。
- **分三层。** 壳的 `AIBackend`（`AIBackends.swift`）只知道怎么起（参数、环境变量、开头写进 stdin 的几行）、哪一行算说完、页面要写回的一行像不像这个后端的；每行的意思由页面的适配器（`src/ai/backends/claude.js`、`codex.js`）翻成会话核心的动作（流式出字、记一行工具、问权限、调 App 的工具、这一轮的结果），回答也由它写好经壳原样写回。会话核心（`src/ai/session.js`）不认识任何一个后端：一轮的生命周期、版本、修改对比、确认框、工具排队都只写一次。
- **App 的工具**：Claude Code 是 SDK MCP 服务 `mediacraft`（控制通道里的 `mcp_message`）；Codex 是线程上的动态工具（`dynamicTools`，调用时发 `item/tool/call`）。两边执行的是同一份 `src/ai/tools.js`。Codex 不给 `generate_image`：它有自带的生图。
- **权限**跟随各自的规则：Codex 线程用 `approvalPolicy: "on-request"`、`sandbox: "workspace-write"`（工作副本里随便改，要联网、写目录外、跑沙盒外的命令先问），这两样与线程的工作目录由壳填，页面改不了；壳也只写认得的几种请求。审批请求在 App 的确认框里答（`accept` / `acceptForSession` / `decline`），框里写全它要的，给出去的就是框里写的。因为每轮是新进程，Codex 自己记的「本次会话都允许」到下一轮就没了，所以放行的规则由页面记着（这篇的会话里，App 开着期间），一模一样的请求（命令连同目录与额外权限……）再来时直接答 `accept`。
- **模型**：Claude Code 是三个别名加自定义 ID；Codex 问它自己（`model/list`），每篇各选，按后端分别记上次选的。

## 后果

- Codex 的动态工具与 `experimentalApi` 是 app-server 的实验接口，Codex 升级可能改掉它们。我们对协议的假设写在假的 codex（`macos/Tests/Fixtures/ai/fake-codex`）与 `AICodexTests` 里；Codex 升级后要用真的 codex 走一轮再发版。
- 加第三个后端只要写一个页面适配器与一个 `AIBackend`，会话核心、确认框与界面不用动。
- 两个后端的会话记录各在各自那边（`~/.claude/projects/`、`~/.codex/sessions/`），删稿子时都不删。
- 「重新开始这篇的对话」是换后端的唯一入口：已经有的对话不会被换到另一个后端上接着聊（两边的上下文不通）。
