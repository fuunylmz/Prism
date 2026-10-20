import AppKit
import CoreGraphics
import Foundation

/// 404 / 无图时返回的占位图。
///
/// 为什么加载器要返回占位图而不是抛错：`AsyncPosterImage` 的错误态是「重试」语义
/// （网络抖动、超时），而 404 是**确定的没有这张图** —— 抛错会让 UI 显示「加载失败」
/// 并可能触发无意义的重试。调研文档 §8.4 也明确：对象没指示图片存在时请求必然 404，
/// 属于正常情况（<https://dev.emby.media/doc/restapi/Images.html>）。
///
/// 图案是纯代码绘制的深灰底 + 简单「照片」符号（一个圆 + 两座山），不依赖资源文件，
/// 也不依赖主线程（用 `CGContext` 而不是 `NSImage.lockFocus`）。
enum PlaceholderImage {
    /// 占位图按尺寸缓存，避免每次 404 都重画。
    private final class Store: @unchecked Sendable {
        let cache = NSCache<NSString, NSImage>()

        init() {
            cache.countLimit = 32
        }
    }

    private static let store = Store()

    /// 取一张指定尺寸的占位图。
    ///
    /// - Parameter size: 目标尺寸（像素/点同值，与 ``ImageRequest/targetPixelSize`` 一致）。
    /// - Returns: 占位图；尺寸至少为 1×1。
    static func make(size: CGSize) -> NSImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let key = "\(width)x\(height)" as NSString
        if let cached = store.cache.object(forKey: key) {
            return cached
        }
        let image = draw(width: width, height: height)
        store.cache.setObject(image, forKey: key, cost: width * height * 4)
        return image
    }

    /// 绘制占位图。
    private static func draw(width: Int, height: Int) -> NSImage {
        let size = CGSize(width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: size)
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(canvas)

        let side = CGFloat(min(width, height))
        let inset = side * 0.2
        let frame = canvas.insetBy(dx: inset, dy: inset)
        let stroke = max(1, side * 0.035)

        context.setStrokeColor(CGColor(gray: 0.42, alpha: 1))
        context.setLineWidth(stroke)
        context.stroke(frame)

        // 太阳
        let sunRadius = side * 0.075
        let sunCenter = CGPoint(x: frame.minX + sunRadius * 1.9, y: frame.maxY - sunRadius * 1.9)
        context.setFillColor(CGColor(gray: 0.42, alpha: 1))
        context.fillEllipse(in: CGRect(
            x: sunCenter.x - sunRadius,
            y: sunCenter.y - sunRadius,
            width: sunRadius * 2,
            height: sunRadius * 2
        ))

        // 山
        context.beginPath()
        context.move(to: CGPoint(x: frame.minX, y: frame.minY))
        context.addLine(to: CGPoint(x: frame.minX + frame.width * 0.42, y: frame.maxY - frame.height * 0.38))
        context.addLine(to: CGPoint(x: frame.minX + frame.width * 0.68, y: frame.minY + frame.height * 0.42))
        context.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        context.closePath()
        context.fillPath()

        guard let cgImage = context.makeImage() else {
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: size)
    }
}
