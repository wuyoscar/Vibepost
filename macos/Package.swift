// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MediaCraft",
    platforms: [.macOS(.v14)], // 与 build-app.sh 的 LSMinimumSystemVersion 一致，依据见 docs/compatibility.md
    products: [
        .executable(name: "MediaCraft", targets: ["MediaCraft"]),
        // 外部 Agent 用的 MCP 服务（stdio），打包在 MediaCraft.app/Contents/MacOS/ 里
        .executable(name: "mediacraft-mcp", targets: ["mediacraft-mcp"]),
    ],
    targets: [
        .target(name: "MediaCraftMCP"),
        .target(name: "MediaCraftShell", dependencies: ["MediaCraftMCP"]),
        .executableTarget(name: "MediaCraft", dependencies: ["MediaCraftShell"]),
        .executableTarget(name: "mediacraft-mcp", dependencies: ["MediaCraftMCP"]),
        .testTarget(name: "MediaCraftShellTests", dependencies: ["MediaCraftShell", "MediaCraftMCP"]),
    ]
)
