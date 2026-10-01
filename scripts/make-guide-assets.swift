// 生成内置说明书用的演示素材（docs/guide-assets/）：三张插画和一段实况视频，全部由代码画出来。
// 画面是扁平插画（山、湖、海），配色取低饱和的色调；随机数用固定种子，每次生成的画面一样。
//   valley-morning.jpg     山谷晨光，1440 × 1080，「图片」一页用
//   night-lake.jpg         夜湖，1440 × 1080，和上一张拼成「拼图」
//   sunset-live.mp4        海边日落，1280 × 960、每秒 30 帧、4 秒，H.264，无声：云在飘、日头下沉、浪在走、帆船在晃
//   sunset-live-cover.jpg  实况的封面：视频第 1.5 秒那一帧（说明书里实况的 coverOffset）
// 用法：swift scripts/make-guide-assets.swift [输出目录，默认 docs/guide-assets]
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/guide-assets")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// ===== 小工具 =====

/// 固定种子的随机数（SplitMix64），保证每次生成一样的画面。
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func makeContext(width: Int, height: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    flipped(context, height: height)
    return context
}

/// 换成左上角为原点、y 向下，和网页画布一样好想。
func flipped(_ context: CGContext, height: Int) {
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
}

/// 竖直方向的线性渐变，stops 是 (位置 0–1, 颜色)。
func verticalGradient(_ context: CGContext, _ rect: CGRect, _ stops: [(CGFloat, UInt32)]) {
    let gradient = CGGradient(
        colorsSpace: colorSpace, colors: stops.map { color($0.1) } as CFArray, locations: stops.map(\.0)
    )!
    context.saveGState()
    context.clip(to: rect)
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    context.restoreGState()
}

/// 以 center 为心、向外淡出的一团光（按平滑曲线淡出，边缘看不出圈）。
func glow(_ context: CGContext, center: CGPoint, radius: CGFloat, hex: UInt32, alpha: CGFloat) {
    let locations: [CGFloat] = stride(from: 0, through: 1, by: 0.125).map { $0 }
    let gradient = CGGradient(
        colorsSpace: colorSpace, colors: locations.map { color(hex, alpha * pow(1 - $0, 2.2)) } as CFArray, locations: locations
    )!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// 一道山脊：几条正弦波叠起来，填到 bottom。
struct Ridge {
    var base: CGFloat
    var waves: [(amplitude: CGFloat, frequency: CGFloat, phase: CGFloat)]

    init(base: CGFloat, height: CGFloat, seed: UInt64) {
        var random = SeededRandom(seed: seed)
        self.base = base
        waves = (0..<4).map { index in
            let scale = CGFloat(1) / CGFloat(index + 1)
            return (height * scale * CGFloat(random.range(0.5, 1)), CGFloat(random.range(0.8, 1.6)) * CGFloat(index + 1), CGFloat(random.range(0, 2 * .pi)))
        }
    }

    func y(at x: CGFloat, width: CGFloat) -> CGFloat {
        base - waves.reduce(0) { $0 + $1.amplitude * sin($1.frequency * x / width * 2 * .pi + $1.phase) }
    }

    func path(width: CGFloat, bottom: CGFloat, mirroredAt mirror: CGFloat? = nil) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: bottom))
        for x in stride(from: CGFloat(0), through: width, by: 4) {
            let y = y(at: x, width: width)
            path.addLine(to: CGPoint(x: x, y: mirror.map { 2 * $0 - y } ?? y))
        }
        path.addLine(to: CGPoint(x: width, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// 一只远处的鸟：两道弧线，wing 是翅膀扇到的角度（-1 下、1 上）。
func bird(_ context: CGContext, at point: CGPoint, size: CGFloat, wing: CGFloat, hex: UInt32) {
    context.saveGState()
    context.setStrokeColor(color(hex, 0.85))
    context.setLineWidth(size * 0.16)
    context.setLineCap(.round)
    let lift = size * 0.45 * wing
    for side: CGFloat in [-1, 1] {
        context.move(to: point)
        context.addQuadCurve(
            to: CGPoint(x: point.x + side * size, y: point.y - lift),
            control: CGPoint(x: point.x + side * size * 0.5, y: point.y - size * 0.55)
        )
    }
    context.strokePath()
    context.restoreGState()
}

/// 细颗粒：让平涂的色块像印刷品，不那么「电脑画」。算一次，每帧叠同一层。
func grain(width: Int, height: Int, strength: Double, seed: UInt64) -> CGImage {
    var random = SeededRandom(seed: seed)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<(width * height) {
        let alpha = UInt8(random.range(0, strength) * 255)
        let value: UInt8 = random.next() < 0.5 ? 0 : alpha // 预乘：白颗粒的值等于透明度
        pixels[index * 4] = value
        pixels[index * 4 + 1] = value
        pixels[index * 4 + 2] = value
        pixels[index * 4 + 3] = alpha
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

func writeJPEG(_ image: CGImage, to name: String, quality: Double = 0.8) throws {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// ===== 山谷晨光 =====

func drawValley(_ context: CGContext, width: CGFloat, height: CGFloat) {
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    verticalGradient(context, full, [(0, 0xC4D3DE), (0.45, 0xE7E1D6), (0.62, 0xF2DFC6)])
    let sun = CGPoint(x: width * 0.68, y: height * 0.36)
    glow(context, center: sun, radius: height * 0.42, hex: 0xFBE7C6, alpha: 0.9)
    context.setFillColor(color(0xF8E3BE))
    context.fillEllipse(in: CGRect(x: sun.x - 56, y: sun.y - 56, width: 112, height: 112))

    let layers: [(base: CGFloat, height: CGFloat, hex: UInt32)] = [
        (0.52, 0.10, 0xB7C3C9), (0.60, 0.09, 0x9DB0AC), (0.69, 0.08, 0x81998B), (0.79, 0.07, 0x62806E), (0.90, 0.06, 0x445F51),
    ]
    for (index, layer) in layers.enumerated() {
        let ridge = Ridge(base: height * layer.base, height: height * layer.height, seed: 101 + UInt64(index))
        context.addPath(ridge.path(width: width, bottom: height))
        context.setFillColor(color(layer.hex))
        context.fillPath()
        // 山与山之间一层薄雾，越远越浓
        let mist = CGRect(x: 0, y: height * (layer.base - 0.02), width: width, height: height * 0.1)
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [color(0xF4EEE4, 0), color(0xF4EEE4, 0.34 - CGFloat(index) * 0.06), color(0xF4EEE4, 0)] as CFArray,
            locations: [0, 0.5, 1]
        )!
        context.saveGState()
        context.clip(to: mist)
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: mist.minY), end: CGPoint(x: 0, y: mist.maxY), options: [])
        context.restoreGState()
    }
    // 近处一条小路
    let road = CGMutablePath()
    road.move(to: CGPoint(x: width * 0.44, y: height))
    road.addCurve(
        to: CGPoint(x: width * 0.58, y: height * 0.8),
        control1: CGPoint(x: width * 0.5, y: height * 0.93), control2: CGPoint(x: width * 0.63, y: height * 0.86)
    )
    road.addCurve(
        to: CGPoint(x: width * 0.52, y: height),
        control1: CGPoint(x: width * 0.62, y: height * 0.87), control2: CGPoint(x: width * 0.54, y: height * 0.94)
    )
    context.addPath(road)
    context.setFillColor(color(0xD9C9A8, 0.9))
    context.fillPath()
    for (index, point) in [CGPoint(x: 0.24, y: 0.25), CGPoint(x: 0.27, y: 0.23), CGPoint(x: 0.31, y: 0.27)].enumerated() {
        bird(context, at: CGPoint(x: width * point.x, y: height * point.y), size: 16 - CGFloat(index) * 2, wing: 0.6, hex: 0x5B6770)
    }
}

// ===== 夜湖 =====

func drawNightLake(_ context: CGContext, width: CGFloat, height: CGFloat) {
    let horizon = height * 0.62
    verticalGradient(context, CGRect(x: 0, y: 0, width: width, height: horizon), [(0, 0x1B2536), (0.7, 0x3A4461), (1, 0x5E5A78)])
    var random = SeededRandom(seed: 7)
    for _ in 0..<220 {
        let point = CGPoint(x: random.range(0, Double(width)), y: random.range(0, Double(horizon) * 0.8))
        let size = CGFloat(random.range(1, 3.2))
        context.setFillColor(color(0xF1ECDD, CGFloat(random.range(0.35, 0.95))))
        context.fillEllipse(in: CGRect(x: point.x, y: point.y, width: size, height: size))
    }
    let moon = CGPoint(x: width * 0.3, y: height * 0.24)
    glow(context, center: moon, radius: 240, hex: 0xE9E2CC, alpha: 0.35)
    context.setFillColor(color(0xEFE8D3))
    context.fillEllipse(in: CGRect(x: moon.x - 46, y: moon.y - 46, width: 92, height: 92))

    let ridges = [
        (Ridge(base: horizon - height * 0.05, height: height * 0.07, seed: 31), 0x3B4560 as UInt32),
        (Ridge(base: horizon + 2, height: height * 0.05, seed: 37), 0x262E42 as UInt32),
    ]
    verticalGradient(context, CGRect(x: 0, y: horizon, width: width, height: height - horizon), [(0, 0x4B4B69), (1, 0x151C2A)])
    for (ridge, hex) in ridges {
        context.addPath(ridge.path(width: width, bottom: horizon + 1))
        context.setFillColor(color(hex))
        context.fillPath()
        // 湖面倒影：同一道山翻过来，淡一些
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: horizon, width: width, height: height - horizon))
        context.addPath(ridge.path(width: width, bottom: horizon, mirroredAt: horizon))
        context.setFillColor(color(hex, 0.55))
        context.fillPath()
        context.restoreGState()
    }
    // 月亮在水里的一道光：一截截横线，越远越短
    for row in 0..<26 {
        let y = horizon + 16 + CGFloat(row) * 13
        let length = CGFloat(random.range(20, 90)) * (1 + CGFloat(row) * 0.05)
        context.setFillColor(color(0xEFE8D3, 0.55 - CGFloat(row) * 0.015))
        context.fill(CGRect(x: moon.x - length / 2 + CGFloat(random.range(-10, 10)), y: y, width: length, height: 2.4))
    }
}

// ===== 海边日落（实况，t 是第几秒）=====

struct SunsetScene {
    let width: CGFloat
    let height: CGFloat
    var horizon: CGFloat { height * 0.6 }

    func draw(_ context: CGContext, t: CGFloat) {
        let horizon = horizon
        verticalGradient(context, CGRect(x: 0, y: 0, width: width, height: horizon), [(0, 0xCDB9C6), (0.55, 0xECC5A6), (1, 0xF5DDB9)])
        // 日头慢慢往下沉，一半没进海平面
        let sun = CGPoint(x: width * 0.6, y: horizon - 46 + t * 9)
        glow(context, center: sun, radius: height * 0.45, hex: 0xF9D7A6, alpha: 0.85)
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: horizon))
        context.setFillColor(color(0xF6C48E))
        context.fillEllipse(in: CGRect(x: sun.x - 78, y: sun.y - 78, width: 156, height: 156))
        context.restoreGState()
        // 云往右飘
        let clouds: [(x: CGFloat, y: CGFloat, w: CGFloat, speed: CGFloat)] = [
            (0.12, 0.16, 360, 14), (0.58, 0.11, 280, 10), (0.8, 0.27, 220, 18), (0.3, 0.33, 260, 12),
        ]
        for cloud in clouds {
            let x = width * cloud.x + t * cloud.speed
            let y = height * cloud.y
            context.setFillColor(color(0xF7E7DA, 0.72))
            context.fillEllipse(in: CGRect(x: x, y: y, width: cloud.w, height: 26))
            context.fillEllipse(in: CGRect(x: x + cloud.w * 0.2, y: y - 14, width: cloud.w * 0.45, height: 30))
        }
        // 海：渐变打底，太阳的倒影一截截闪，浪线往左走
        verticalGradient(context, CGRect(x: 0, y: horizon, width: width, height: height - horizon), [(0, 0x9AAFB7), (1, 0x587684)])
        for row in 0..<22 {
            let y = horizon + 10 + CGFloat(row) * 16
            let shimmer = 0.55 + 0.45 * sin(t * 5 + CGFloat(row) * 1.7)
            let length = (40 + CGFloat(row) * 7) * shimmer
            context.setFillColor(color(0xF8D9A8, 0.75 - CGFloat(row) * 0.025))
            context.fill(CGRect(x: sun.x - length / 2 + sin(CGFloat(row) * 2.3) * 12, y: y, width: length, height: 3))
        }
        context.setLineCap(.round)
        for row in 0..<7 {
            let y = horizon + 40 + CGFloat(row * row) * 7 + CGFloat(row) * 16
            let amplitude = 2 + CGFloat(row) * 1.2
            let wavelength = 90 + CGFloat(row) * 36
            let offset = t * (30 + CGFloat(row) * 14)
            context.setStrokeColor(color(0xE9EEEC, 0.22 + CGFloat(row) * 0.05))
            context.setLineWidth(1.4 + CGFloat(row) * 0.5)
            for segment in stride(from: CGFloat(-200), to: width + 200, by: wavelength * 2.2) {
                let start = segment - offset.truncatingRemainder(dividingBy: wavelength * 2.2)
                context.move(to: CGPoint(x: start, y: y))
                for step in stride(from: CGFloat(0), through: wavelength, by: 6) {
                    context.addLine(to: CGPoint(x: start + step, y: y + sin(step / wavelength * .pi * 2) * amplitude))
                }
            }
            context.strokePath()
        }
        drawBoat(context, at: CGPoint(x: width * 0.26 + t * 6, y: horizon + 34 + sin(t * 2.4) * 3), tilt: sin(t * 2.4 + 0.6) * 0.05)
        for (index, start) in [CGPoint(x: 0.12, y: 0.24), CGPoint(x: 0.18, y: 0.21), CGPoint(x: 0.22, y: 0.26)].enumerated() {
            let point = CGPoint(x: width * start.x + t * 42, y: height * start.y - t * 4)
            bird(context, at: point, size: 15 - CGFloat(index) * 2, wing: sin(t * 9 + CGFloat(index) * 1.3), hex: 0x6A5A63)
        }
    }

    private func drawBoat(_ context: CGContext, at point: CGPoint, tilt: CGFloat) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: tilt)
        let hull = CGMutablePath()
        hull.move(to: CGPoint(x: -46, y: 0))
        hull.addLine(to: CGPoint(x: 46, y: 0))
        hull.addLine(to: CGPoint(x: 32, y: 13))
        hull.addLine(to: CGPoint(x: -32, y: 13))
        hull.closeSubpath()
        context.addPath(hull)
        context.setFillColor(color(0x4B4148))
        context.fillPath()
        context.setFillColor(color(0x4B4148))
        context.fill(CGRect(x: -2, y: -86, width: 3, height: 86))
        let sail = CGMutablePath()
        sail.move(to: CGPoint(x: 3, y: -82))
        sail.addLine(to: CGPoint(x: 42, y: -6))
        sail.addLine(to: CGPoint(x: 3, y: -6))
        sail.closeSubpath()
        context.addPath(sail)
        context.setFillColor(color(0xF3E9DC))
        context.fillPath()
        let jib = CGMutablePath()
        jib.move(to: CGPoint(x: -3, y: -70))
        jib.addLine(to: CGPoint(x: -3, y: -8))
        jib.addLine(to: CGPoint(x: -30, y: -8))
        jib.closeSubpath()
        context.addPath(jib)
        context.setFillColor(color(0xE2C9B5))
        context.fillPath()
        context.restoreGState()
    }
}

// ===== 输出 =====

func renderStill(width: Int, height: Int, grainSeed: UInt64, draw: (CGContext) -> Void) -> CGImage {
    let context = makeContext(width: width, height: height)
    draw(context)
    context.draw(grain(width: width, height: height, strength: 0.045, seed: grainSeed), in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func writeVideo(scene: SunsetScene, seconds: Int, fps: Int32, to name: String) throws {
    let url = outputDirectory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let width = Int(scene.width)
    let height = Int(scene.height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_500_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: Int(fps),
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.shouldOptimizeForNetworkUse = true
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let texture = grain(width: width, height: height, strength: 0.035, seed: 11)
    for frame in 0..<(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        flipped(context, height: height)
        scene.draw(context, t: CGFloat(frame) / CGFloat(fps))
        context.draw(texture, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try writeJPEG(renderStill(width: 1440, height: 1080, grainSeed: 3) { drawValley($0, width: 1440, height: 1080) }, to: "valley-morning.jpg")
try writeJPEG(renderStill(width: 1440, height: 1080, grainSeed: 5) { drawNightLake($0, width: 1440, height: 1080) }, to: "night-lake.jpg")
let sunset = SunsetScene(width: 1280, height: 960)
try writeVideo(scene: sunset, seconds: 4, fps: 30, to: "sunset-live.mp4")
let poster = makeContext(width: 1280, height: 960)
sunset.draw(poster, t: 1.5)
poster.draw(grain(width: 1280, height: 960, strength: 0.035, seed: 11), in: CGRect(x: 0, y: 0, width: 1280, height: 960))
try writeJPEG(poster.makeImage()!, to: "sunset-live-cover.jpg")
print("已生成 \(outputDirectory.path)：valley-morning.jpg、night-lake.jpg、sunset-live.mp4、sunset-live-cover.jpg")
