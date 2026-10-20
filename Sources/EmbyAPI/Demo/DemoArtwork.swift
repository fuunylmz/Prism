import AppKit
import CoreGraphics
import CoreText
import Foundation
import PrismCore

/// 演示模式的**程序化封面图**：不依赖网络、不占仓库体积，按条目 id 确定性地生成。
///
/// ## 为什么不用内嵌 PNG
///
/// 演示库有 26 部电影 + 8 部剧 + 148 集，每张海报都要有区别。内嵌 180 张 PNG 会让仓库
/// 体积膨胀、也难维护；而「按 id 哈希出色相，再画渐变」的方案零素材、零网络、
/// 每次渲染结果完全一致（同一 id 永远得到同一张图），对 UI 预览和截图都友好。
///
/// ## 线程安全
///
/// 位图用 `CGContext` 在调用线程上直接绘制（`CGBitmapContext` 本身可跨线程使用），
/// 最后包成 `NSImage` 交给主线程显示。这正是 Apple 允许的用法：
/// 「One thread can create an `NSImage` object, draw to the image buffer, and pass it off
/// to the main thread for drawing.」
/// 参考：<https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html>
///
/// 因此本类型没有任何共享可变状态，所有方法都是纯函数式的，可以安全地在任意 actor 上调用。
public enum DemoArtwork {

    /// 渲染尺寸上限（像素）。超过就等比缩到该上限，避免误传巨大尺寸时分配失控。
    public static let maximumDimension: CGFloat = 2048

    /// 按种子生成一张封面图。
    ///
    /// 同一 `seed` + `kind` + `size` 的组合永远得到像素级一致的结果。
    ///
    /// - Parameters:
    ///   - seed: 种子（通常传条目 id）。决定色相与构图。
    ///   - kind: 图片类型，决定构图倾向（海报 / 背景 / logo / 缩略图）。
    ///   - size: 目标尺寸（点）。会被钳到 `1...maximumDimension`。
    ///   - title: 可选的标题，取首字作为水印；`nil` 时只画几何图形。
    /// - Returns: 生成的图片。
    public static func image(
        seed: String,
        kind: ImageKind = .primary,
        size: CGSize,
        title: String? = nil
    ) -> NSImage {
        let width = clampedPixelCount(size.width)
        let height = clampedPixelCount(size.height)
        let hash = stableHash(seed)
        let hue = hue(forSeedHash: hash)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            // 理论上不会发生（参数已钳制在合法范围）。退化为一个 1x1 的纯色图，
            // 保证调用方永远拿到一张可显示的图片，而不是崩溃或 nil。
            return NSImage(size: CGSize(width: width, height: height))
        }

        drawBackground(in: context, width: width, height: height, hue: hue, kind: kind, hash: hash)
        drawAccents(in: context, width: width, height: height, hue: hue, hash: hash)
        if let title, !title.isEmpty {
            drawWatermark(title, in: context, width: width, height: height, kind: kind)
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: CGSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    /// 由种子推导出的基础色相（0...1）。
    ///
    /// 相同种子恒定得到相同色相，不同种子在色环上均匀散开。
    ///
    /// - Parameter seed: 种子字符串。
    /// - Returns: 0...1 的色相值。
    public static func hue(for seed: String) -> Double {
        hue(forSeedHash: stableHash(seed))
    }

    // MARK: - 绘制

    /// 画渐变背景。
    ///
    /// - Parameters:
    ///   - context: 目标上下文。
    ///   - width: 像素宽。
    ///   - height: 像素高。
    ///   - hue: 基础色相。
    ///   - kind: 图片类型。
    ///   - hash: 种子哈希，用于决定渐变角度。
    private static func drawBackground(
        in context: CGContext,
        width: Int,
        height: Int,
        hue: Double,
        kind: ImageKind,
        hash: UInt64
    ) {
        let top = color(hue: hue, saturation: 0.52, brightness: 0.62)
        let bottom = color(hue: wrapped(hue + 0.09), saturation: 0.78, brightness: 0.20)
        let locations: [CGFloat] = [0, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [top, bottom] as CFArray,
            locations: locations
        ) else { return }

        // 海报是竖向渐变，背景图是斜向渐变，缩略图偏横向 —— 让三类图一眼能区分。
        let start: CGPoint
        let end: CGPoint
        switch kind {
        case .backdrop:
            start = CGPoint(x: 0, y: CGFloat(height))
            end = CGPoint(x: CGFloat(width), y: 0)
        case .thumb, .logo:
            start = CGPoint(x: 0, y: CGFloat(height) / 2)
            end = CGPoint(x: CGFloat(width), y: CGFloat(height) / 2)
        default:
            // 用哈希微调竖向渐变的倾角，避免所有海报长得一模一样。
            let tilt = CGFloat(hash % 7) / 7 * CGFloat(width) * 0.35
            start = CGPoint(x: 0, y: CGFloat(height))
            end = CGPoint(x: tilt, y: 0)
        }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 画装饰性的斜向光带与暗角，让占位图不至于太平。
    ///
    /// - Parameters:
    ///   - context: 目标上下文。
    ///   - width: 像素宽。
    ///   - height: 像素高。
    ///   - hue: 基础色相。
    ///   - hash: 种子哈希。
    private static func drawAccents(
        in context: CGContext,
        width: Int,
        height: Int,
        hue: Double,
        hash: UInt64
    ) {
        let bandWidth = CGFloat(width) * (0.18 + CGFloat(hash % 5) / 5 * 0.12)
        let bandX = CGFloat(hash % 11) / 11 * CGFloat(width)
        context.saveGState()
        context.setFillColor(color(hue: wrapped(hue + 0.5), saturation: 0.35, brightness: 1.0, alpha: 0.10))
        context.beginPath()
        context.move(to: CGPoint(x: bandX, y: 0))
        context.addLine(to: CGPoint(x: bandX + bandWidth, y: 0))
        context.addLine(to: CGPoint(x: bandX + bandWidth - CGFloat(height) * 0.45, y: CGFloat(height)))
        context.addLine(to: CGPoint(x: bandX - CGFloat(height) * 0.45, y: CGFloat(height)))
        context.closePath()
        context.fillPath()
        context.restoreGState()

        // 暗角：底部压暗，让白色文字始终可读。
        guard let vignette = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color(hue: hue, saturation: 0.9, brightness: 0.05, alpha: 0.0),
                color(hue: hue, saturation: 0.9, brightness: 0.05, alpha: 0.55)
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(
            vignette,
            start: CGPoint(x: 0, y: CGFloat(height) * 0.55),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    /// 在图上画标题首字水印。
    ///
    /// - Parameters:
    ///   - title: 标题。
    ///   - context: 目标上下文。
    ///   - width: 像素宽。
    ///   - height: 像素高。
    ///   - kind: 图片类型（logo 不画字）。
    private static func drawWatermark(
        _ title: String,
        in context: CGContext,
        width: Int,
        height: Int,
        kind: ImageKind
    ) {
        guard kind != .logo else { return }
        // 取前两个字：中文标题足够辨识，英文标题则是一个缩写。
        let glyphs = String(title.prefix(2))
        let fontSize = CGFloat(min(width, height)) * 0.30
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color(hue: 0, saturation: 0, brightness: 1, alpha: 0.22)
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            glyphs as CFString,
            attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(height) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }

    // MARK: - 颜色与哈希

    /// 用 HSB 构造颜色。
    ///
    /// - Parameters:
    ///   - hue: 色相 0...1（自动环绕）。
    ///   - saturation: 饱和度 0...1。
    ///   - brightness: 明度 0...1。
    ///   - alpha: 不透明度 0...1。
    /// - Returns: 对应颜色。
    private static func color(
        hue: Double,
        saturation: Double,
        brightness: Double,
        alpha: Double = 1
    ) -> CGColor {
        CGColor(
            red: component(hue: hue, saturation: saturation, brightness: brightness, offset: 0),
            green: component(hue: hue, saturation: saturation, brightness: brightness, offset: 2.0 / 3.0),
            blue: component(hue: hue, saturation: saturation, brightness: brightness, offset: 4.0 / 3.0),
            alpha: alpha
        )
    }

    /// HSB → RGB 单通道换算。
    ///
    /// 这是标准 HSV→RGB 公式的逐通道写法，避免为一张占位图引入 `NSColor`（它更适合
    /// 主线程使用，而这里要在后台生成图片）。
    ///
    /// - Parameters:
    ///   - hue: 色相 0...1。
    ///   - saturation: 饱和度 0...1。
    ///   - brightness: 明度 0...1。
    ///   - offset: 通道偏移（0 / 2/3 / 4/3）。
    /// - Returns: 0...1 的通道值。
    private static func component(hue: Double, saturation: Double, brightness: Double, offset: Double) -> Double {
        let k = (wrapped(hue + offset) * 6).truncatingRemainder(dividingBy: 6)
        let chroma = brightness * saturation
        let secondary = chroma * (1 - abs(k.truncatingRemainder(dividingBy: 2) - 1))
        let base = brightness - chroma
        let value: Double
        switch k {
        case ..<1: value = chroma
        case ..<2: value = secondary
        case ..<3: value = 0
        case ..<4: value = 0
        case ..<5: value = secondary
        default: value = chroma
        }
        return min(max(value + base, 0), 1)
    }

    /// 把色相环绕到 0...1。
    ///
    /// - Parameter value: 任意色相值。
    /// - Returns: 0...1 的色相。
    private static func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    /// 把哈希映射到色相。
    ///
    /// - Parameter hash: 种子哈希。
    /// - Returns: 0...1 的色相。
    private static func hue(forSeedHash hash: UInt64) -> Double {
        Double(hash % 360) / 360
    }

    /// 把尺寸钳成合法的像素数。
    ///
    /// - Parameter value: 原始点数。
    /// - Returns: 1...`maximumDimension` 的整数像素。
    private static func clampedPixelCount(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 1 }
        return Int(min(value.rounded(), maximumDimension))
    }

    /// FNV-1a 64 位哈希。
    ///
    /// 选它而不是 `Hasher`：Swift 的 `Hasher` **每次进程启动都换种子**，
    /// 同一 id 在不同启动里会得到不同颜色。演示图必须跨启动稳定，所以用固定参数的 FNV-1a。
    /// 参考：<https://en.wikipedia.org/wiki/Fowler–Noll–Vo_hash_function>
    ///
    /// - Parameter string: 任意字符串。
    /// - Returns: 64 位哈希。
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
