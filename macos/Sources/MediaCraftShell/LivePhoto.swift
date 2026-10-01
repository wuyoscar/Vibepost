import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 实况合成（ADR 0004）：卡片画面 + 一段视频 → 同一个配对 ID 的 JPG 与 MOV，外加 metadata.plist。
/// 视频在卡片的图片框里播放：按裁剪取景、铺满图片框（多出的部分居中切掉）、切出圆角；JPG 是封面那一帧。
/// 页面经原生桥 `POST /__native/live-photo` 调用（请求与回复的格式见 docs/app-api.md），
/// 合成在后台队列里做，进度推回页面；页面中止请求时这次合成跟着取消。
final class LivePhotos: @unchecked Sendable {
    /// 推给页面的进度（JSON 文本），由 ShellWebView 转成页面里的 `mediacraft:native-live-photo` 事件。
    typealias Sink = @Sendable (String) -> Void

    private let lock = NSLock()
    private var sink: Sink?

    func setSink(_ sink: Sink?) {
        lock.withLock { self.sink = sink }
    }

    func handle(body: Data) async -> NativeBridge.Reply {
        let cancelled = CancellationFlag()
        return await withTaskCancellationHandler {
            do {
                let (request, card, video) = try LivePhotoRequest.parse(body)
                var reported = -1.0
                let composer = LivePhotoComposer(request: request, cancelled: cancelled) { [weak self] progress in
                    // 每涨 2% 报一次，免得往页面里塞太多事件
                    guard progress >= 1 || progress - reported >= 0.02 else { return }
                    reported = progress
                    self?.report(job: request.job, progress: progress)
                }
                let package = try await composer.compose(card: card, video: video)
                return .binary(package.framed())
            } catch is CancellationError {
                return .failure(499, "已取消")
            } catch {
                return .failure(500, error.localizedDescription)
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private func report(job: String, progress: Double) {
        let fields: [String: Any] = ["job": job, "progress": min(1, max(0, progress))]
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
        let sink = lock.withLock { self.sink }
        sink?(String(decoding: data, as: UTF8.self))
    }
}

/// 页面中止请求时置位；合成的每一帧都看一眼。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }

    func cancel() {
        lock.withLock { value = true }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

enum LivePhotoError: LocalizedError {
    case badRequest(String)
    case unreadableCard
    case unreadableVideo
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .badRequest(let detail): "实况请求不对：\(detail)"
        case .unreadableCard: "卡片画面读不出来"
        case .unreadableVideo: "这段视频读不出来，换一段试试"
        case .writeFailed(let detail): "实况没能生成：\(detail)"
        }
    }
}

/// 页面交来的设置。时间都按原视频计：从 `start` 起用 `span` 秒，按 `speed` 倍速播完；封面在起点后 `cover` 秒。
struct LivePhotoRequest: Decodable, Sendable {
    struct Frame: Decodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Well: Decodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let radius: Double
    }

    let job: String
    /// 卡片的逻辑大小（864 × 1152），图片框坐标以它为准
    let cardWidth: Double
    let cardHeight: Double
    let well: Well
    /// 取景：0–1，按视频的显示方向
    let crop: Frame
    let start: Double
    let span: Double
    let speed: Double
    let cover: Double
    let sound: Bool
    let videoName: String
    let cardBytes: Int
    let videoBytes: Int

    /// body：带文件的桥请求（`FramedBody`），头部是这个结构，后面依次是卡片 PNG 与原视频。
    static func parse(_ body: Data) throws -> (LivePhotoRequest, Data, Data) {
        let (header, payload) = try FramedBody.split(body)
        guard let request = try? JSONDecoder().decode(LivePhotoRequest.self, from: header) else {
            throw LivePhotoError.badRequest("头部读不出来")
        }
        try request.validate(payloadSize: payload.count)
        let card = payload.prefix(request.cardBytes)
        let video = payload.dropFirst(request.cardBytes)
        return (request, Data(card), Data(video))
    }

    private func validate(payloadSize: Int) throws {
        let unit = 0.0...1.0
        // 先比再减：两个很大的数相加会溢出（让 App 崩掉）
        guard cardBytes > 0, videoBytes > 0, cardBytes < payloadSize, videoBytes == payloadSize - cardBytes else {
            throw LivePhotoError.badRequest("文件长度")
        }
        guard cardWidth > 0, cardHeight > 0, well.width > 0, well.height > 0 else { throw LivePhotoError.badRequest("图片框") }
        guard speed > 0, speed <= 8, span > 0, start >= 0, cover >= 0 else { throw LivePhotoError.badRequest("时间") }
        guard unit.contains(crop.x), unit.contains(crop.y), crop.width > 0, crop.height > 0,
              crop.x + crop.width <= 1.0001, crop.y + crop.height <= 1.0001
        else { throw LivePhotoError.badRequest("取景") }
    }
}

/// 合成结果：`.pvt` 目录包里的三个文件。
struct LivePhotoPackage {
    let identifier: String
    let photo: Data
    let movie: Data
    let metadata: Data

    /// 回给页面：头部 `{ identifier, files: [{ name, size }] }`，后面依次是 JPG、MOV、metadata.plist。
    func framed() -> Data {
        let files = [("photo.JPG", photo), ("movie.MOV", movie), ("metadata.plist", metadata)]
        let header: [String: Any] = [
            "ok": true,
            "identifier": identifier,
            "files": files.map { ["name": $0.0, "size": $0.1.count] },
        ]
        let json = (try? JSONSerialization.data(withJSONObject: header)) ?? Data()
        return FramedBody.join(header: json, parts: files.map(\.1))
    }
}

/// 原生桥里带文件的 body：4 字节大端的头部长度 + JSON 头部 + 各段二进制依次相接（各段长度写在头部里）。
enum FramedBody {
    static func split(_ data: Data) throws -> (header: Data, payload: Data) {
        guard data.count >= 4 else { throw LivePhotoError.badRequest("太短") }
        let bytes = [UInt8](data.prefix(4))
        let length = bytes.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, 4 + length <= data.count else { throw LivePhotoError.badRequest("头部长度") }
        let start = data.startIndex
        return (data.subdata(in: start + 4..<start + 4 + length), data.subdata(in: start + 4 + length..<data.endIndex))
    }

    static func join(header: Data, parts: [Data]) -> Data {
        let length = UInt32(header.count)
        var body = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        body.append(header)
        for part in parts { body.append(part) }
        return body
    }
}

/// 一次合成。视频逐帧解码、按倍速取帧（每秒 30 帧）、叠到卡片上编码；声音按倍速变速不变调。
final class LivePhotoComposer: @unchecked Sendable {
    /// 成片视频的宽：和 iPhone 实况的视频一样 1440 宽，高按卡片比例（3:4 为 1920）
    static let movieWidth = 1440
    static let frameRate: Int32 = 30

    private let request: LivePhotoRequest
    private let cancelled: CancellationFlag
    private let progress: (Double) -> Void
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(request: LivePhotoRequest, cancelled: CancellationFlag, progress: @escaping (Double) -> Void) {
        self.request = request
        self.cancelled = cancelled
        self.progress = progress
    }

    func compose(card: Data, video: Data) async throws -> LivePhotoPackage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaCraft-LivePhoto", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let source = CGImageSourceCreateWithData(card as CFData, nil),
              let cardImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LivePhotoError.unreadableCard }
        let videoURL = directory.appendingPathComponent("source.\(Self.fileExtension(request.videoName))")
        try video.write(to: videoURL)
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform),
              naturalSize.width > 0, naturalSize.height > 0
        else { throw LivePhotoError.unreadableVideo }
        let audio = request.sound ? try? await asset.loadTracks(withMediaType: .audio).first : nil
        let duration = try await asset.load(.duration).seconds
        try cancelled.check()

        let clip = Clip(request: request, videoDuration: duration)
        let identifier = UUID().uuidString
        let card = CIImage(cgImage: cardImage)

        // 封面：原视频里封面那一刻的画面，按卡片原尺寸合成
        let still = try await coverFrame(asset: asset, at: clip.coverTime)
        let stillCompositor = WellCompositor(request: request, background: card)
        let photo = try jpeg(stillCompositor.frame(still), size: stillCompositor.size, identifier: identifier)
        progress(0.1)
        try cancelled.check()

        // 视频：卡片先缩到成片大小画好一次，每帧只叠视频
        let movieSize = CGSize(
            width: Self.movieWidth,
            height: Int((Double(Self.movieWidth) * request.cardHeight / request.cardWidth / 2).rounded()) * 2
        )
        let scaled = card
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: movieSize.width / card.extent.width, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(origin: .zero, size: movieSize))
        guard let background = context.createCGImage(scaled, from: CGRect(origin: .zero, size: movieSize), format: .RGBA8, colorSpace: sRGB) else {
            throw LivePhotoError.unreadableCard
        }
        let movieURL = directory.appendingPathComponent("live.MOV")
        try await writeMovie(
            to: movieURL, asset: asset, track: track, orientation: Self.orientation(transform), audio: audio,
            clip: clip, compositor: WellCompositor(request: request, background: CIImage(cgImage: background)), identifier: identifier
        )
        progress(1)
        return LivePhotoPackage(identifier: identifier, photo: photo, movie: try Data(contentsOf: movieURL), metadata: Self.metadataPlist)
    }

    // MARK: - 时间

    /// 用原视频的哪一段：不够长时成片跟着变短。
    struct Clip {
        let start: Double
        let span: Double
        let speed: Double
        /// 封面在原视频里的时刻
        let coverTime: Double

        init(request: LivePhotoRequest, videoDuration: Double) {
            let total = videoDuration.isFinite && videoDuration > 0 ? videoDuration : request.start + request.span
            start = min(request.start, max(0, total - 0.05))
            span = max(0.05, min(request.span, total - start))
            speed = request.speed
            // 封面最晚取成片最后一帧
            let lastFrame = max(0, span - speed / Double(LivePhotoComposer.frameRate))
            coverTime = start + min(request.cover, lastFrame)
        }

        var outputDuration: Double { span / speed }
        var frameCount: Int { max(1, Int((outputDuration * Double(LivePhotoComposer.frameRate)).rounded(.down))) }
        /// 成片里封面那一帧的时刻（still-image-time）
        var stillTime: Double { (coverTime - start) / speed }
    }

    // MARK: - 封面

    private func coverFrame(asset: AVAsset, at seconds: Double) async throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else {
            throw LivePhotoError.unreadableVideo
        }
        return CIImage(cgImage: image)
    }

    /// JPG 的 Apple MakerNote 第 17 项是实况配对 ID，iOS 靠它和 MOV 认成一张实况。
    private func jpeg(_ image: CIImage, size: CGSize, identifier: String) throws -> Data {
        guard let rendered = context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: sRGB) else {
            throw LivePhotoError.writeFailed("封面画不出来")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LivePhotoError.writeFailed("JPG")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
        ]
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LivePhotoError.writeFailed("JPG") }
        return output as Data
    }

    /// 和 iPhone 隔空投送的实况一样的 metadata.plist
    static let metadataPlist: Data = (try? PropertyListSerialization.data(
        fromPropertyList: ["PFVideoComplementMetadataVersionKey": "1"], format: .xml, options: 0
    )) ?? Data()

    // MARK: - MOV

    private func writeMovie(
        to url: URL, asset: AVAsset, track: AVAssetTrack, orientation: CGImagePropertyOrientation, audio: AVAssetTrack?,
        clip: Clip, compositor: WellCompositor, identifier: String
    ) async throws {
        // 硬件 HEVC 编不了时退回 H.264
        var lastError: Error = LivePhotoError.writeFailed("没有能用的编码器")
        for codec in [AVVideoCodecType.hevc, .h264] {
            try? FileManager.default.removeItem(at: url)
            do {
                // 声音这一段取不出来（比如音轨比视频短、提前结束）时成片不带声音，不因此失败
                var audioSource: AudioSource?
                if let audio { audioSource = try? await AudioSource(track: audio, clip: clip) }
                let writer = try MovieWriter(url: url, codec: codec, size: compositor.size, identifier: identifier, audio: audioSource != nil)
                try await writeFrames(writer, asset: asset, track: track, orientation: orientation, audio: audioSource, clip: clip, compositor: compositor)
                return
            } catch let error as MovieWriter.Unsupported {
                lastError = error
            }
        }
        throw lastError
    }

    private func writeFrames(
        _ writer: MovieWriter, asset: AVAsset, track: AVAssetTrack, orientation: CGImagePropertyOrientation, audio audioSource: AudioSource?,
        clip: Clip, compositor: WellCompositor
    ) async throws {
        let videoReader = try AVAssetReader(asset: asset)
        // 往前多读一点：起点那一刻显示的是它之前最近的一帧
        let lead = 0.5
        videoReader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, clip.start - lead), preferredTimescale: 600),
            duration: CMTime(seconds: clip.span + lead + 0.5, preferredTimescale: 600)
        )
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)

        defer {
            videoReader.cancelReading()
            audioSource?.cancel()
        }
        guard videoReader.startReading(), audioSource?.start() ?? true else { throw LivePhotoError.unreadableVideo }
        try writer.start(stillTime: clip.stillTime)

        let pump = FramePump(
            clip: clip, frames: FrameCursor(output: videoOutput), orientation: orientation, compositor: compositor,
            context: context, sRGB: sRGB, cancelled: cancelled, progress: { [progress] done in progress(0.1 + 0.88 * done) }
        )
        let cancelled = cancelled
        let written: Bool = await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            group.enter()
            writer.pumpVideo { pump.next(into: writer) } done: { group.leave() }
            if let audioSource, let input = writer.audioInput {
                group.enter()
                audioSource.pump(into: input, cancelled: cancelled) { group.leave() }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume(returning: pump.failure == nil && !cancelled.isCancelled)
            }
        }
        guard written else {
            writer.cancel()
            try cancelled.check()
            throw pump.failure ?? LivePhotoError.writeFailed("视频帧")
        }
        try await writer.finish(at: clip.outputDuration)
    }

    // MARK: - 方向

    /// 视频轨道的 preferredTransform → 解码出的画面要怎样转才是正的
    static func orientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    static func fileExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "m4v", "mov"].contains(ext) ? ext : "mov"
    }
}

/// 一帧画面怎样叠到卡片上：卡片（已是成品大小）做底；视频按裁剪取景后铺满图片框（比例不同时居中切掉多余），切出圆角。
struct WellCompositor {
    let size: CGSize
    private let background: CIImage
    private let well: CGRect
    private let mask: CIImage
    private let crop: LivePhotoRequest.Frame

    init(request: LivePhotoRequest, background: CIImage) {
        self.background = background
        size = background.extent.size
        crop = request.crop
        let scale = size.width / request.cardWidth
        // 卡片坐标原点在左上，Core Image 在左下
        let rect = request.well
        well = CGRect(
            x: rect.x * scale, y: size.height - (rect.y + rect.height) * scale,
            width: rect.width * scale, height: rect.height * scale
        )
        let radius = min(rect.radius * scale, well.width / 2, well.height / 2)
        mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: well), "inputRadius": radius, "inputColor": CIColor.white,
        ])?.outputImage ?? CIImage(color: .white).cropped(to: well)
    }

    /// video：已经转正的一帧
    func frame(_ video: CIImage) -> CIImage {
        let extent = video.extent
        var region = CGRect(
            x: extent.minX + crop.x * extent.width,
            y: extent.minY + (1 - crop.y - crop.height) * extent.height,
            width: crop.width * extent.width,
            height: crop.height * extent.height
        )
        // 铺满：在取景框里取一块与图片框同比例、居中的区域
        let aspect = well.width / well.height
        if region.width / region.height > aspect {
            let width = region.height * aspect
            region = CGRect(x: region.midX - width / 2, y: region.minY, width: width, height: region.height)
        } else {
            let height = region.width / aspect
            region = CGRect(x: region.minX, y: region.midY - height / 2, width: region.width, height: height)
        }
        let scale = well.width / region.width
        let placed = video.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .transformed(by: CGAffineTransform(translationX: well.minX, y: well.minY))
            .cropped(to: well)
        return placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask,
        ]).cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// 按原视频时间往前走的解码帧：取某一刻正在显示的那一帧（它之前最近的一帧）。
final class FrameCursor {
    private let output: AVAssetReaderOutput
    private var current: CMSampleBuffer?
    private var upcoming: CMSampleBuffer?

    init(output: AVAssetReaderOutput) {
        self.output = output
    }

    func frame(at seconds: Double) -> CVPixelBuffer? {
        if current == nil { current = output.copyNextSampleBuffer() }
        if upcoming == nil { upcoming = output.copyNextSampleBuffer() }
        while let next = upcoming, next.presentationTimeStamp.seconds <= seconds + 0.0005 {
            current = next
            upcoming = output.copyNextSampleBuffer()
        }
        return (current ?? upcoming)?.imageBuffer
    }
}

/// 逐帧喂给视频编码器：成片第 i 帧取原视频 start + i / 30 × 倍速 那一刻的画面。
final class FramePump: @unchecked Sendable {
    private let clip: LivePhotoComposer.Clip
    private let frames: FrameCursor
    private let orientation: CGImagePropertyOrientation
    private let compositor: WellCompositor
    private let context: CIContext
    private let sRGB: CGColorSpace
    private let cancelled: CancellationFlag
    private let progress: (Double) -> Void
    private var index = 0
    private(set) var failure: Error?

    init(
        clip: LivePhotoComposer.Clip, frames: FrameCursor, orientation: CGImagePropertyOrientation, compositor: WellCompositor,
        context: CIContext, sRGB: CGColorSpace, cancelled: CancellationFlag, progress: @escaping (Double) -> Void
    ) {
        self.clip = clip
        self.frames = frames
        self.orientation = orientation
        self.compositor = compositor
        self.context = context
        self.sRGB = sRGB
        self.cancelled = cancelled
        self.progress = progress
    }

    /// 编一帧；返回 false 表示没有下一帧了（写完、出错或被取消）。
    func next(into writer: MovieWriter) -> Bool {
        guard index < clip.frameCount, failure == nil, !cancelled.isCancelled else { return false }
        let time = CMTime(value: CMTimeValue(index), timescale: LivePhotoComposer.frameRate)
        let sourceTime = clip.start + time.seconds * clip.speed
        guard let pixels = frames.frame(at: sourceTime) else {
            failure = LivePhotoError.unreadableVideo
            return false
        }
        let upright = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let video = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        do {
            try writer.append(compositor.frame(video), at: time, context: context, colorSpace: sRGB)
        } catch {
            failure = error
            return false
        }
        index += 1
        progress(Double(index) / Double(clip.frameCount))
        return true
    }
}

/// 声音：取出这一段、按倍速变速不变调，解成 PCM 交给编码器。
final class AudioSource: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let queue = DispatchQueue(label: "com.wuyoscar.mediacraft.live-photo.audio")

    init(track: AVAssetTrack, clip: LivePhotoComposer.Clip) async throws {
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LivePhotoError.unreadableVideo
        }
        // 只取音轨上真有的部分，放在这一段里对应的位置
        let start = CMTime(seconds: clip.start, preferredTimescale: 600)
        let span = CMTime(seconds: clip.span, preferredTimescale: 600)
        let available = CMTimeRange(start: start, duration: span).intersection(try await track.load(.timeRange))
        guard available.duration > .zero else { throw LivePhotoError.unreadableVideo }
        try target.insertTimeRange(available, of: track, at: available.start - start)
        target.scaleTimeRange(
            CMTimeRange(start: .zero, duration: available.end - start),
            toDuration: CMTime(seconds: (available.end - start).seconds / clip.speed, preferredTimescale: 600)
        )
        reader = try AVAssetReader(asset: composition)
        output = AVAssetReaderAudioMixOutput(audioTracks: [target], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
    }

    func start() -> Bool { reader.startReading() }

    func cancel() { reader.cancelReading() }

    func pump(into input: AVAssetWriterInput, cancelled: CancellationFlag, done: @escaping () -> Void) {
        var finished = false
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while !finished && input.isReadyForMoreMediaData {
                guard !cancelled.isCancelled, let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    finished = true
                    input.markAsFinished()
                    done()
                    return
                }
            }
        }
    }
}

/// 写 MOV：视频轨、声音轨（可选）、still-image-time 定时元数据轨，外加配对 ID。
final class MovieWriter: @unchecked Sendable {
    struct Unsupported: LocalizedError {
        let codec: AVVideoCodecType
        var errorDescription: String? { "这台 Mac 编不了 \(codec.rawValue) 视频" }
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let metadataInput: AVAssetWriterInput
    private let metadataAdaptor: AVAssetWriterInputMetadataAdaptor
    let audioInput: AVAssetWriterInput?
    private let size: CGSize
    private let queue = DispatchQueue(label: "com.wuyoscar.mediacraft.live-photo.video")

    init(url: URL, codec: AVVideoCodecType, size: CGSize, identifier: String, audio: Bool) throws {
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let compression: [String: Any] = codec == .hevc
            ? [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30]
            : [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30,
               AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw Unsupported(codec: codec) }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        writer.add(videoInput)

        var description: CMFormatDescription?
        let specification: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: "com.apple.metadata.datatype.int8",
        ]
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description
        )
        metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        writer.add(metadataInput)

        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [item]
    }

    /// 开始写：still-image-time 标在封面那一帧
    func start(stillTime: Double) throws {
        guard writer.startWriting() else {
            throw Unsupported(codec: (videoInput.outputSettings?[AVVideoCodecKey] as? AVVideoCodecType) ?? .hevc)
        }
        writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.value = -1 as NSNumber
        item.dataType = "com.apple.metadata.datatype.int8"
        let time = CMTime(seconds: stillTime, preferredTimescale: 600)
        let range = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: LivePhotoComposer.frameRate))
        guard metadataAdaptor.append(AVTimedMetadataGroup(items: [item], timeRange: range)) else {
            throw LivePhotoError.writeFailed(writer.error?.localizedDescription ?? "still-image-time")
        }
        metadataInput.markAsFinished()
    }

    /// 编码器要帧时反复调 next，直到它返回 false
    func pumpVideo(_ next: @escaping () -> Bool, done: @escaping () -> Void) {
        var finished = false
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in
            while !finished && videoInput.isReadyForMoreMediaData {
                if !next() {
                    finished = true
                    videoInput.markAsFinished()
                    done()
                    return
                }
            }
        }
    }

    func append(_ image: CIImage, at time: CMTime, context: CIContext, colorSpace: CGColorSpace) throws {
        guard let pool = adaptor.pixelBufferPool else { throw LivePhotoError.writeFailed(writer.error?.localizedDescription ?? "像素缓冲") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw LivePhotoError.writeFailed("像素缓冲") }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw LivePhotoError.writeFailed(writer.error?.localizedDescription ?? "视频帧")
        }
    }

    func finish(at seconds: Double) async throws {
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LivePhotoError.writeFailed(writer.error?.localizedDescription ?? "MOV")
        }
    }

    func cancel() {
        writer.cancelWriting()
    }
}
