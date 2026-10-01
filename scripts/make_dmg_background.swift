// 生成 DMG 窗口的背景图（scripts/make-dmg.sh 用）：品牌橘红底，顶上是 App 图标（brand/app-icon-256.png，和 Dock 里的一样）与字标，
// 中间一支从 App 指向「Applications」的箭头，底下一行说明。输出一张同时带 1x 与 2x 的 TIFF，视网膜屏上 Finder 自动用 2x。
// 画布 640×440 点：窗口内容区 640×400，多出的 40 点垫在底下，标题栏高矮不同的系统上也不露白边。
// 图标中心（App 在 170,205，「Applications」在 470,205）与 make-dmg.sh 里的 Finder 布局一致。
// 底色是压深一点的品牌橘红（图标是 #fc4d1f），亮度约 0.18：Finder 写图标名时浅色模式用黑字、深色模式用白字，
// 两种与底色的对比度都在 4.5:1 以上。
// 用法：swift scripts/make_dmg_background.swift 输出.tiff brand/app-icon-256.png
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let appIcon = NSImage(contentsOfFile: arguments[2]) else {
    FileHandle.standardError.write(Data("用法：swift make_dmg_background.swift 输出.tiff App图标.png\n".utf8))
    exit(2)
}

let canvas = NSSize(width: 640, height: 440)
let base = NSColor(srgbRed: 0xd9 / 255, green: 0x3c / 255, blue: 0x17 / 255, alpha: 1)
let brand = NSColor(srgbRed: 0xfc / 255, green: 0x4d / 255, blue: 0x1f / 255, alpha: 1)

/// App 图标的圆角方块边长（点）。图标图片四周留着透明边与投影（scripts/build_app_icon.swift：1024 的画布里方块占 824），
/// 所以图片要画得比方块大一圈。
let markSize: CGFloat = 56
let iconInset: CGFloat = 100 / 824

/// 标志：App 图标，圆角方块的左上角放在 origin（画布是翻转坐标，y 朝下）
func drawMark(at origin: NSPoint) {
    let margin = markSize * iconInset
    let rect = NSRect(x: origin.x - margin, y: origin.y - margin, width: markSize + 2 * margin, height: markSize + 2 * margin)
    appIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ])
}

func drawCentered(_ line: NSAttributedString, y: CGFloat) {
    line.draw(at: NSPoint(x: (canvas.width - line.size().width) / 2, y: y))
}

func draw() {
    base.setFill()
    NSRect(origin: .zero, size: canvas).fill()
    // 顶上一团柔光，落在字标后面；图标名那一带仍是底色
    NSGradient(colors: [.white.withAlphaComponent(0.18), .white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 320, y: 30), radius: 0, toCenter: NSPoint(x: 320, y: 30), radius: 320, options: [])

    // 标志 + 字标，整组水平居中（字标 post 淡一点）
    let word = NSMutableAttributedString(attributedString: text("Vibe", size: 30, weight: .semibold))
    word.append(text("post", size: 30, weight: .semibold, alpha: 0.78))
    let gap: CGFloat = 14
    let left = (canvas.width - markSize - gap - word.size().width) / 2
    let middle: CGFloat = 66
    drawMark(at: NSPoint(x: left, y: middle - markSize / 2))
    word.draw(at: NSPoint(x: left + markSize + gap, y: middle - word.size().height / 2))

    // 从 App 指向「Applications」
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 252, y: 205))
    arrow.line(to: NSPoint(x: 386, y: 205))
    arrow.move(to: NSPoint(x: 374, y: 193))
    arrow.line(to: NSPoint(x: 387, y: 205))
    arrow.line(to: NSPoint(x: 374, y: 217))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke()
    arrow.stroke()

    drawCentered(text("把 Vibepost 拖到右边的 Applications 即可安装", size: 15, weight: .medium), y: 326)
    drawCentered(text("Drag Vibepost onto Applications to install", size: 12, weight: .regular, alpha: 0.72), y: 350)
}

let image = NSImage(size: canvas, flipped: true) { _ in
    draw()
    return true
}

func representation(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: canvas))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = NSImage(size: canvas)
output.addRepresentation(representation(scale: 1))
output.addRepresentation(representation(scale: 2))
guard let tiff = output.tiffRepresentation(using: .lzw, factor: 1) else { exit(1) }
do {
    try tiff.write(to: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write(Data("写不出 \(arguments[1])：\(error.localizedDescription)\n".utf8))
    exit(1)
}
