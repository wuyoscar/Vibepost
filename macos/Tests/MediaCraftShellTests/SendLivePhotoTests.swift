import AVFoundation
import Foundation
import ImageIO
import Testing

/// 两个 WKWebView 同时解码视频会互相卡住，实况用例逐个执行。
/// 素材是自己生成的两段 10 秒视频（macos/Tests/Fixtures/make-live-fixtures.sh）：上半截每秒换一种颜色
/// （红、绿、蓝、琥珀、紫，五秒一轮），下半截白色，据此核对成片取的是原视频的哪一刻、方向对不对。
@MainActor
@Suite(.serialized)
struct SendLivePhotoTests {
    static let h264 = "/macos/Tests/Fixtures/live-h264.mp4"
    static let hevc = "/macos/Tests/Fixtures/live-hevc.mov"

    /// 页面里：把一段夹具视频做成 File（`liveFile(path, name)`），等条件成立（`until(check)`）。
    static let helpers = """
        window.mc = window.mediacraft;
        window.liveFile = async (path, name = path.split("/").pop()) => {
          const blob = await (await fetch(path)).blob();
          return new File([blob], name, { type: path.endsWith(".mov") ? "video/quicktime" : "video/mp4" });
        };
        window.until = async (check, timeout = 20000) => {
          const deadline = Date.now() + timeout;
          while (!(await check())) {
            if (Date.now() > deadline) throw new Error(`等不到：${check}`);
            await new Promise((resolve) => setTimeout(resolve, 50));
          }
        };
    """

    struct LiveCase: Sendable, CustomTestStringConvertible {
        let video: String
        let options: String
        /// 成片长度（秒）、封面在成片里的时刻、成片某一刻（秒）→ 那时的颜色
        let seconds: Double
        let stillTime: Double
        let coverColor: String
        let frames: [(Double, String)]
        let sound: Bool
        var testDescription: String { video.hasSuffix(".mov") ? "iPhone 式竖拍 HEVC MOV" : "横拍 H.264 MP4" }
    }

    /// H.264：从第 1 秒起、2 倍速做 3 秒（用原视频 6 秒），封面在起点后 3.4 秒（原视频 4.4 秒，紫），带声音。
    /// HEVC：从头做 5 秒原速，封面在 0.5 秒（红），不要声音；画面转正后上半截有颜色、下半截白。
    static let cases = [
        LiveCase(
            video: h264, options: "{ duration: 3, speed: 2, start: 1, coverOffset: 3.4, sound: true }",
            seconds: 3, stillTime: 1.7, coverColor: "purple", frames: [(0.25, "green"), (1.2, "amber"), (2.2, "red")], sound: true
        ),
        LiveCase(
            video: hevc, options: "{ duration: 5, speed: 1, start: 0, coverOffset: 0.5, sound: false }",
            seconds: 5, stillTime: 0.5, coverColor: "red", frames: [(1.5, "green"), (3.5, "amber")], sound: false
        ),
    ]

    @Test("含实况的卡片组发到 iPhone：实况页是完整的 .pvt，JPG 与 MOV 配对 ID 一致；时长、倍速、起点、封面、声音、方向、尺寸都按设置", arguments: cases)
    func sendsLivePageAsPairedPvt(live: LiveCase) async throws {
        let harness = ShellHarness()
        do {
            try await harness.load()
            let prepared = try await harness.evaluate(Self.helpers + """
                await mc.drafts.create({ markdown });
                const id = await mc.media.insertLivePhoto(await liveFile(video), { at: markdown.length, ...\(live.options) });
                const { markdown: text } = await mc.drafts.current();
                const pages = await mc.render.pages();
                const page = pages.findIndex((item) => item.imageHits.some((hit) => hit.live));
                return {
                  inserted: (await mc.media.get(id))?.kind === "live" && text.trimEnd().endsWith(`[[图片:${id}]]`),
                  page, well: pages[page].imageHits.find((hit) => hit.live),
                };
            """, arguments: ["markdown": SendToIPhoneTests.markdown, "video": live.video]) as? [String: Any]
            // Await the real send in this WK call, matching the passing live ZIP/MCP export path.
            // A returned fire-and-forget call followed by a Swift poll does not await page rasterization.
            let status = try #require(try await harness.evaluate(SendToIPhoneTests.outputDiagnosticsScript + """
                let deadlineTimer;
                let outcome = "发送中";
                let failure = "";
                try {
                  await Promise.race([
                    window.mediacraft.output.sendToIPhone(),
                    new Promise((_, reject) => {
                      deadlineTimer = setTimeout(() => reject(new Error("90 秒内发送没有完成")), 90000);
                    }),
                  ]);
                  outcome = "ok";
                } catch (error) {
                  outcome = "error";
                  failure = error.message || String(error);
                } finally {
                  clearTimeout(deadlineTimer);
                }
                window.sendDiagnostic = { ...outputSnapshot(), outcome, failure };
                return JSON.stringify(window.sendDiagnostic);
            """) as? String)
            let outcome = try JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any]
            try #require(outcome?["outcome"] as? String == "ok", "实况发送没有完成：\(status)，页面错误：\(harness.pageErrors)")
            let items = try #require(harness.sender.batches.first, "页面报告发送成功，但原生接收端没有批次：\(status)")

            let packages = items.filter { $0.pathExtension == "pvt" }
            let package = try #require(packages.first, "应有一个实况 .pvt，状态：\(status)")
            let contents = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)
            let photo = try #require(contents.first { $0.pathExtension == "JPG" })
            let movie = try #require(contents.first { $0.pathExtension == "MOV" })
            let plist = try #require(contents.first { $0.lastPathComponent == "metadata.plist" })
            let movieInfo = try await Self.movieInfo(movie)
            let well = try #require(Self.rect(prepared?["well"]))
            let stillColors = try Self.wellColors(Self.image(photo), well: well)
            var frameColors: [String] = []
            for (time, _) in live.frames {
                frameColors.append(try await Self.wellColors(Self.frame(movie, at: time), well: well).top)
            }
            if frameColors != live.frames.map(\.1), let log = ProcessInfo.processInfo.environment["MEDIACRAFT_TEST_LOG"] {
                // Keep the actual output for independent decoding if a frame assertion fails.
                let directory = URL(fileURLWithPath: log).deletingPathExtension().appendingPathExtension("media")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let saved = directory.appendingPathComponent(live.video.hasSuffix(".mov") ? "hevc.MOV" : "h264.MOV")
                    try FileManager.default.copyItem(at: movie, to: saved)
                    print("帧颜色诊断：\(frameColors)，成片保留于 \(saved.path)")
                } catch {
                    print("无法保留失败成片：\(error)")
                }
            }
            let dates = items.map { $0.pathExtension == "pvt" ? SendToIPhoneTests.captureDate(photo) : SendToIPhoneTests.captureDate($0) }

            #expect(prepared?["inserted"] as? Bool == true, "实况插在正文末尾")
            #expect(packages.count == 1)
            #expect(items.map(\.lastPathComponent) == items.indices.map { index in
                String(format: "%02d.", index + 1) + items[index].pathExtension
            })
            #expect(package.lastPathComponent == String(format: "%02d.pvt", (prepared?["page"] as? Int ?? -1) + 1))
            #expect(Self.appleContentIdentifier(photo) != nil)
            #expect(Self.appleContentIdentifier(photo) == movieInfo.identifier, "iOS 靠同一个 ID 把 JPG 和 MOV 认成一张实况")
            #expect((NSDictionary(contentsOf: plist)?["PFVideoComplementMetadataVersionKey"] as? String) == "1")
            #expect(SendToIPhoneTests.pixelSize(photo) == "1728x2304", "JPG 和导出的 PNG 一样大")
            #expect(movieInfo.size == CGSize(width: 1440, height: 1920), "MOV 是卡片比例的 1440 × 1920")
            #expect(movieInfo.codec == "hvc1", "硬件 HEVC 编码")
            #expect(abs(movieInfo.duration - live.seconds) < 0.1, "成片时长：\(movieInfo.duration)")
            #expect(abs((movieInfo.stillTime ?? -1) - live.stillTime) < 0.05, "still-image-time 在封面那一帧：\(movieInfo.stillTime ?? -1)")
            #expect(movieInfo.hasAudio == live.sound, "声音按设置")
            #expect(stillColors.top == live.coverColor, "JPG 是封面那一刻的画面")
            #expect(stillColors.bottom == "white", "画面方向是正的（上半截有颜色、下半截白）")
            #expect(frameColors == live.frames.map(\.1), "成片每一刻取的是原视频 起点 + 时刻 × 倍速")
            #expect(dates.allSatisfy { $0 != nil })
            #expect(zip(dates, dates.dropFirst()).allSatisfy { ($0 ?? "") < ($1 ?? "") })
            #expect(harness.pageErrors == [])
        } catch {
            let diagnostic = await SendToIPhoneTests.failureDiagnostics(harness)
            print("实况发送诊断：\(diagnostic)")
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    // MARK: - 读成片

    /// JPG 的 Apple MakerNote 第 17 项就是实况配对 ID。
    static func appleContentIdentifier(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        return apple["17"] as? String
    }

    struct MovieInfo {
        let identifier: String?
        let duration: Double
        let size: CGSize
        let codec: String
        let hasAudio: Bool
        let stillTime: Double?
    }

    static func movieInfo(_ url: URL) async throws -> MovieInfo {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataContentIdentifier).first
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, descriptions) = try await video.load(.naturalSize, .formatDescriptions)
        let subtype = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = String(decoding: withUnsafeBytes(of: subtype.bigEndian) { Data($0) }, as: UTF8.self)
        return MovieInfo(
            identifier: try await item?.load(.stringValue),
            duration: try await asset.load(.duration).seconds,
            size: size,
            codec: codec,
            hasAudio: !(try await asset.loadTracks(withMediaType: .audio).isEmpty),
            stillTime: try await stillImageTime(asset)
        )
    }

    /// 定时元数据轨里 still-image-time 那一组的时刻
    static func stillImageTime(_ asset: AVAsset) async throws -> Double? {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.startReading()
            while let group = adaptor.nextTimedMetadataGroup() {
                if group.items.contains(where: { $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" }) {
                    return group.timeRange.start.seconds
                }
            }
        }
        return nil
    }

    static func image(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let sample = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        print("MOV 取帧：请求 \(seconds)，实际 \(sample.actualTime.seconds)")
        return sample.image
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let hit = value as? [String: Any],
              let x = hit["x"] as? Double, let y = hit["y"] as? Double,
              let width = hit["width"] as? Double, let height = hit["height"] as? Double
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 图片框（卡片逻辑坐标 864 × 1152）上四分之一与下四分之一处的颜色
    static func wellColors(_ image: CGImage, well: CGRect) throws -> (top: String, bottom: String) {
        let scale = CGFloat(image.width) / 864
        let x = (well.midX * scale).rounded()
        let top = try color(image, x: x, y: ((well.minY + well.height * 0.25) * scale).rounded())
        let bottom = try color(image, x: x, y: ((well.minY + well.height * 0.75) * scale).rounded())
        return (top, bottom)
    }

    static let palette: [(String, (Double, Double, Double))] = [
        ("red", (229, 57, 53)), ("green", (67, 160, 71)), ("blue", (30, 136, 229)),
        ("amber", (255, 179, 0)), ("purple", (142, 36, 170)), ("white", (255, 255, 255)),
    ]

    /// 某一点的颜色，归到夹具里最近的那一种
    static func color(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> String {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(CGFloat(image.height) - y - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
        let (r, g, b) = (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
        let nearest = palette.min { lhs, rhs in
            let distance = { (c: (Double, Double, Double)) in pow(c.0 - r, 2) + pow(c.1 - g, 2) + pow(c.2 - b, 2) }
            return distance(lhs.1) < distance(rhs.1)
        }
        return nearest?.0 ?? "?"
    }
}
