import Foundation
import MediaCraftMCP

// mediacraft-mcp：外部 Agent（终端里的 Claude Code 等）用的 MCP 服务，打包在 MediaCraft.app/Contents/MacOS/ 里。
// 由 Agent 启动，经 stdin / stdout 说 MCP（见 MCPServer），工具交给正在运行的 MediaCraft 执行；App 没开时先打开它。
// 接入：claude mcp add mediacraft -- "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp"（docs/mcp.md）。
// stdout 只写 MCP 消息，别的什么都不写。环境变量 MEDIACRAFT_MCP_SOCKET 可以换套接字的位置（测试与开发用）。

// App 已经退出时往套接字写字只得到 EPIPE，不让整个进程被 SIGPIPE 结束
signal(SIGPIPE, SIG_IGN)

let socketPath = ProcessInfo.processInfo.environment["MEDIACRAFT_MCP_SOCKET"]
    ?? MCPPaths.supportDirectory.appendingPathComponent(MCPPaths.socketName).path

let link = AppLink(socketPath: socketPath) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-b", MCPPaths.bundleIdentifier]
    // open 的输出不能进 stdout（那里只能有 MCP 消息）
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
        throw MCPFailure("Vibepost 没开，也没能打开它（open -b \(MCPPaths.bundleIdentifier) 失败）。先把 Vibepost.app 装进「应用程序」再试")
    }
}

MCPServer(link: link, output: LineChannel(descriptor: STDOUT_FILENO)).run(input: LineChannel(descriptor: STDIN_FILENO))
exit(0)
