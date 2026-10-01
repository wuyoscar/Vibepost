// 由品牌图生成 macOS 风格的 App 图标：1024×1024 透明画布，中间 824×824 的连续圆角方块（四周各留 100），
// 带一层柔和投影，与系统 App 图标的网格一致。macos/build-app.sh 用它生成 .icns。
// 用法：swift scripts/build_app_icon.swift brand/icon.png 输出.png
import AppKit
import ImageIO
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let avatar = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("用法：swift build_app_icon.swift 品牌图.png 输出.png\n".utf8))
    exit(2)
}

let canvas = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath
guard let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
context.interpolationQuality = .high
// 裁好的头像放在透明图层里，合上图层时整块一起投影。
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
context.beginTransparencyLayer(auxiliaryInfo: nil)
context.addPath(shape)
context.clip()
context.draw(avatar, in: body)
context.endTransparencyLayer()

guard let icon = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, "public.png" as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, icon, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
