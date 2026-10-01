import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把 PDF 每页渲染成 PNG（CoreGraphics，线程安全，可在后台调用）。
enum PDFPages {
    enum Failure: LocalizedError {
        case unreadable
        case tooManyPages(Int)
        case renderFailed(page: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取这个 PDF"
            case .tooManyPages(let count): "这个 PDF 有 \(count) 页，最多 \(PDFPages.pageLimit) 页"
            case .renderFailed(let page): "第 \(page) 页渲染失败"
            }
        }
    }

    /// 一个 PDF 最多转这么多页
    static let pageLimit = 100
    /// 每页图最高这么多像素（细长的页按高缩小，免得一页要几个 GB 的内存）
    static let maxHeight = 16000

    /// 按页宽渲染（太细长的页按 maxHeight 缩小）；白底，保留页面自带的旋转。
    static func pngs(from data: Data, width: Int = 1600) throws -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0
        else { throw Failure.unreadable }
        guard document.numberOfPages <= pageLimit else { throw Failure.tooManyPages(document.numberOfPages) }
        return try (1...document.numberOfPages).map { number in
            guard let page = document.page(at: number), let png = render(page, width: width) else {
                throw Failure.renderFailed(page: number)
            }
            return png
        }
    }

    private static func render(_ page: CGPDFPage, width: Int) -> Data? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = min(CGFloat(width) / pageSize.width, CGFloat(maxHeight) / pageSize.height)
        let pixelWidth = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: height))
        // getDrawingTransform 只会缩小不会放大，所以先整体放大，再让它处理旋转与平移。
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
