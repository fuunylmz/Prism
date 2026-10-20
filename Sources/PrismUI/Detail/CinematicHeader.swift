import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PrismCore
import SwiftUI

// MARK: - 电影 / 剧集共用的头图

/// 详情页的 Cinematic Header：backdrop + logo + 取色渐变。
///
/// 结构与 `docs/research/ux-benchmark.md` §S07 / §5.1 一致：
///
/// 1. **背景**：`Backdrop` 图铺满，高斯模糊 + 轻微放大（模糊会让边缘透明，
///    所以放大 1.08 把边缘推出可视区）；
/// 2. **取色渐变**：从 backdrop 提取主色（``ArtworkColorExtractor``），
///    生成从上到下逐渐加浓的氛围光，再把底部 12% 淡到页面背景色——
///    这是「高级感」的来源，也是 Apple TV app 的做法；
/// 3. **压暗层**：保证白色标题与元数据在任何画面上都有对比度；
/// 4. **前景**：有 `Logo` 图就用 logo，否则用大标题文字；下方是
///    年份 · 时长 · 评分 · 分级 · 画质角标 · 类型标签。
///
/// 高度随宽度自适应：`width * 0.42`，夹在 300…440pt 之间（常见宽度下约 420pt）。
/// 之所以不用固定 16:9，是因为详情栏通常比 16:9 窄，固定比例会让头图显得过矮。
///
/// ```swift
/// CinematicHeader(
///     item: content.item,
///     backdropURL: model.headerImageURL(for: content.item),
///     logoURL: model.logoImageURL(for: content.item)
/// )
/// ```
public struct CinematicHeader: View {
    /// 宽度未知时使用的高度（首帧 / 预览）。
    public static let fallbackHeight: CGFloat = 420

    /// 头图最小高度。
    public static let minimumHeight: CGFloat = 300

    /// 头图最大高度。
    public static let maximumHeight: CGFloat = 440

    private let item: MediaItem
    private let backdropURL: URL?
    private let logoURL: URL?

    @Environment(\.posterImageLoader) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var backdrop: NSImage?
    @State private var logo: NSImage?
    @State private var dominantColor: Color?
    @State private var width: CGFloat?
    @State private var isHovering = false

    /// 创建头图。
    ///
    /// - Parameters:
    ///   - item: 条目（提供标题、年份、时长、评分、分级、类型与画质信息）。
    ///   - backdropURL: 背景图地址；`nil` 时显示纯色骨架，取色退回强调色。
    ///   - logoURL: 标题 logo 地址；`nil` 或加载失败时用文字标题。
    public init(item: MediaItem, backdropURL: URL?, logoURL: URL?) {
        self.item = item
        self.backdropURL = backdropURL
        self.logoURL = logoURL
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
            gradients
            foreground
        }
        .frame(maxWidth: .infinity)
        .frame(height: resolvedHeight)
        .clipped()
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .task(id: backdropURL) { await loadBackdrop() }
        .task(id: logoURL) { await loadLogo() }
        .accessibilityElement(children: .contain)
    }

    // MARK: 尺寸

    /// 当前高度：宽度已知时按比例算，未知时用 ``fallbackHeight``。
    private var resolvedHeight: CGFloat {
        guard let width, width > 0 else { return Self.fallbackHeight }
        return Self.height(for: width)
    }

    /// 按容器宽度算头图高度。
    ///
    /// - Parameter width: 容器宽度。
    /// - Returns: 300…440pt 之间的高度。
    public static func height(for width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return fallbackHeight }
        return min(max(width * 0.42, minimumHeight), maximumHeight)
    }

    // MARK: 背景

    private var artwork: some View {
        GeometryReader { proxy in
            ZStack {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        // opaque: true 让模糊核把边缘当作图像内部像素，
                        // 否则四边会渗出透明、露出下面的背景色。
                        .blur(radius: 26, opaque: true)
                        .scaleEffect(zoomScale)
                        .animation(reduceMotion ? nil : .easeOut(duration: Motion.slow), value: isHovering)
                } else {
                    SkeletonView(cornerRadius: 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }

    /// 悬停时轻微推近（UX §S07：1.02，0.4s）；基础缩放 1.08 用来盖住模糊边缘。
    private var zoomScale: CGFloat {
        guard !reduceMotion else { return 1.08 }
        return isHovering ? 1.10 : 1.08
    }

    // MARK: 渐变

    /// 三层渐变：主色氛围光 → 压暗 → 融入页面背景。
    private var gradients: some View {
        ZStack {
            // 1) 取色渐变：把 backdrop 的颜色记忆带进页面，从上到下逐渐加浓。
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.00), location: 0.00),
                    .init(color: tint.opacity(0.18), location: 0.45),
                    .init(color: tint.opacity(0.45), location: 0.78),
                    .init(color: tint.opacity(0.62), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 2) 压暗：白色文字在任何 backdrop 上都要可读。
            //    顶部也压一点，避免亮色画面把窗口标题栏「顶」得发白。
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.22), location: 0.00),
                    .init(color: .black.opacity(0.04), location: 0.32),
                    .init(color: .black.opacity(0.28), location: 0.70),
                    .init(color: .black.opacity(0.52), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 3) 底部融入页面背景：最后 12%（至少 32pt）淡到 Palette.surface，
            //    头图与正文之间因此没有硬边。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Palette.surface.opacity(0), Palette.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(resolvedHeight * 0.12, 32))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 主色：取不到时退回强调色，保证渐变永远有颜色。
    private var tint: Color {
        dominantColor ?? Palette.accent
    }

    // MARK: 前景

    private var foreground: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            titleView

            HStack(spacing: Spacing.sm) {
                if !metadataParts.isEmpty {
                    Text(verbatim: metadataParts.joined(separator: " · "))
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
                ForEach(badges) { badge in
                    Text(badge.label)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(0.20))
                        )
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)

            if !genreChips.isEmpty {
                HStack(spacing: Spacing.sm) {
                    ForEach(genreChips, id: \.self) { genre in
                        Text(verbatim: genre)
                            .font(Typography.caption)
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 有 logo 用 logo，否则用文字标题。
    @ViewBuilder private var titleView: some View {
        if let logo {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 340, maxHeight: 110, alignment: .leading)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                .accessibilityLabel(Text(verbatim: item.name))
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(verbatim: item.name)
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// 元数据：年份 · 时长 · 评分 · 分级。缺哪项就不显示哪项（不写「未知」）。
    private var metadataParts: [String] {
        var parts: [String] = []
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if let duration = item.durationText {
            parts.append(duration)
        }
        if let rating = item.communityRating, rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        }
        if let official = item.officialRating, !official.isEmpty {
            parts.append(official)
        }
        return parts
    }

    /// 类型标签：最多 4 个，避免头图被标签淹没。
    private var genreChips: [String] {
        Array(item.genres.prefix(4))
    }

    /// 画质角标：只按服务端真实给到的视频流判断，不猜。
    ///
    /// - 4K：视频流宽 ≥ 3840 或高 ≥ 2160；
    /// - HDR：`videoRange` 含 `HDR`；
    /// - DV：`videoRange` 含 `DolbyVision`。
    private var badges: [PosterBadge] {
        let videoStreams = item.mediaSources
            .flatMap(\.mediaStreams)
            .filter { $0.type == .video }
        guard !videoStreams.isEmpty else { return [] }

        var result: [PosterBadge] = []
        let is4K = videoStreams.contains { ($0.width ?? 0) >= 3840 || ($0.height ?? 0) >= 2160 }
        if is4K {
            result.append(.fourK)
        }
        let ranges = videoStreams.compactMap(\.videoRange).map { $0.uppercased() }
        if ranges.contains(where: { $0.contains("DOLBYVISION") || $0.contains("DOLBY VISION") }) {
            result.append(.dolbyVision)
        } else if ranges.contains(where: { $0.contains("HDR") || $0.contains("HLG") }) {
            result.append(.hdr)
        }
        return result
    }

    // MARK: 加载

    /// 加载 backdrop 并提取主色。
    private func loadBackdrop() async {
        guard let backdropURL else {
            backdrop = nil
            dominantColor = nil
            return
        }
        do {
            let image = try await loader.image(
                for: backdropURL,
                targetSize: CGSize(width: 1280, height: 720)
            )
            guard !Task.isCancelled else { return }
            backdrop = image
            dominantColor = ArtworkColorExtractor.dominantColor(for: backdropURL, image: image)
        } catch is CancellationError {
            // 地址变了或视图消失：保留当前画面。
        } catch {
            guard !Task.isCancelled else { return }
            backdrop = nil
            dominantColor = nil
        }
    }

    /// 加载 logo。
    private func loadLogo() async {
        guard let logoURL else {
            logo = nil
            return
        }
        do {
            let image = try await loader.image(
                for: logoURL,
                targetSize: CGSize(width: 640, height: 240)
            )
            guard !Task.isCancelled else { return }
            logo = image
        } catch is CancellationError {
            // 同上。
        } catch {
            guard !Task.isCancelled else { return }
            logo = nil
        }
    }
}

// MARK: - 取色

/// 从图片里提取「主色」，供详情头图的取色渐变使用。
///
/// 做法：把图片缩到 48×27 → 用 Core Image 的 `CIAreaAverage` 求平均色 →
/// 按 UI 需要收敛饱和度 / 亮度。
///
/// ## 为什么这样配置 `CIContext`
///
/// 1. **只创建一个上下文，并长期持有。**
///    Apple 在 `CIContext` 文档里明确写道：上下文内部管理 `MTLCommandQueue`、
///    编译好的 kernel 缓存与中间缓冲，「not recommended to create many `CIContext`
///    instances」，建议每个视图或每个后台任务一个。
///    详情页每次换条目都要取一次色，如果每次新建上下文，会在 GPU 上反复建队列。
///    <https://developer.apple.com/documentation/coreimage/cicontext>
///
/// 2. **`useSoftwareRenderer: true`：强制 CPU。**
///    输入已经被缩到 48×27，一次 1×1 归约在 CPU 上是微秒级；反过来，走 GPU 要为
///    这一个像素建 Metal 命令队列、上传纹理、等 fence，在 SwiftUI 预览 / 无窗口
///    环境里还更容易拿不到可用的设备。Apple 的 QA1416 说明了该开关的语义
///    （YES = 始终用 CPU），`CIContextOption.useSoftwareRenderer` 的文档同样适用。
///    <https://developer.apple.com/library/archive/qa/qa1416/_index.html>
///    <https://developer.apple.com/documentation/coreimage/cicontextoption/usesoftwarerenderer>
///
/// 3. **显式指定工作 / 输出色彩空间为 sRGB。**
///    不指定时 Core Image 会按图像自带的色彩空间工作（可能是 Display P3），
///    同一个颜色在渐变里会和 SwiftUI 的 sRGB 颜色对不上。
///
/// 4. **`cacheIntermediates: false`。**
///    这是一次性归约，缓存中间结果只会白占内存。
///
/// `CIContext` 与 `CIImage` 都是不可变的，可以跨线程共享（见 `CIContext` 头文件
/// 与文档：「`CIContext` and `CIImage` instances are immutable, so multiple threads
/// can use the same `CIContext` instance」），因此这里用 `static let` 共享一份。
enum ArtworkColorExtractor {
    /// sRGB 色彩空间（上下文与渲染共用一份）。
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// 共享上下文：配置说明见类型文档。
    private static let context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false,
        .useSoftwareRenderer: true
    ])

    /// 缩放后的采样尺寸（16:9，够算平均色，又便宜到可以忽略）。
    private static let sampleWidth = 48
    private static let sampleHeight = 27

    /// 主色缓存（按图片 URL）。
    ///
    /// 取色本身不贵（缩到 48×27 后一次归约是微秒级），但**进详情页、切季、
    /// 从播放器返回**都会重建头图；缓存后这些场景连那几微秒都省掉，也避免
    /// 每次重建都产生一张采样用的 `CGImage`。
    private static let cache = ColorCache()

    /// 取图片主色（带缓存）。
    ///
    /// - Parameters:
    ///   - url: 图片地址，用作缓存 key；`nil` 时退化为不缓存。
    ///   - image: 原图（通常是 1280×720 的 backdrop）。
    /// - Returns: 适合做渐变的主色；取不到（无图 / 渲染失败 / 全透明）时 `nil`，
    ///   调用方应退回强调色。
    static func dominantColor(for url: URL?, image: NSImage) -> Color? {
        let key = url?.absoluteString
        if let key, let cached = cache.color(forKey: key) {
            return Color(nsColor: cached)
        }
        guard let color = dominantColor(from: image) else { return nil }
        if let key {
            cache.store(color, forKey: key)
        }
        return Color(nsColor: color)
    }

    /// 取图片主色（不带缓存）。
    ///
    /// - Parameter image: 原图。
    /// - Returns: 适合做渐变的主色；取不到时 `nil`。
    static func dominantColor(from image: NSImage) -> NSColor? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        guard let small = downsampled(source, width: sampleWidth, height: sampleHeight) else {
            return nil
        }
        guard let average = areaAverage(of: small) else { return nil }
        return tuned(average)
    }

    /// 清空主色缓存（内存警告或切换服务器时调用）。
    static func clearCache() {
        cache.removeAll()
    }

    /// 线程安全的主色缓存。
    ///
    /// `NSCache` 自身的方法可以在任意线程调用（Apple 文档：
    /// 「NSCache is thread safe」），但它的**类型本身没有标注 `Sendable`**，
    /// 在 Swift 6 严格并发下不能直接做 `static let`。这里用一个带锁的薄包装把它
    /// 隔离起来，既保留 LRU 淘汰与内存压力处理，又满足编译器的并发检查。
    ///
    /// <https://developer.apple.com/documentation/foundation/nscache>
    private final class ColorCache: @unchecked Sendable {
        private let storage = NSCache<NSString, NSColor>()
        private let lock = NSLock()

        /// 读缓存。
        ///
        /// - Parameter key: 图片地址。
        /// - Returns: 缓存的主色。
        func color(forKey key: String) -> NSColor? {
            lock.lock()
            defer { lock.unlock() }
            return storage.object(forKey: key as NSString)
        }

        /// 写缓存。
        ///
        /// - Parameters:
        ///   - color: 主色。
        ///   - key: 图片地址。
        func store(_ color: NSColor, forKey key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.setObject(color, forKey: key as NSString)
        }

        /// 清空。
        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAllObjects()
        }
    }

    /// 把图片缩到采样尺寸。
    ///
    /// 先缩小再归约是关键：`CIAreaAverage` 会对输入的每个像素做归约，
    /// 直接喂 4K 原图在软件渲染下要几十毫秒，缩小后是微秒级。
    ///
    /// - Parameters:
    ///   - image: 原图。
    ///   - width: 目标宽。
    ///   - height: 目标高。
    /// - Returns: 缩小后的图。
    private static func downsampled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 用 `CIAreaAverage` 求整张图的平均色。
    ///
    /// `CIAreaAverage` 返回一张 1×1 的图，用 `CIContext.render(_:toBitmap:…)`
    /// 把它读成 4 个字节（RGBA8）。
    ///
    /// - `colorSpace` 传 sRGB：与上下文的工作 / 输出空间一致，避免再做一次色彩匹配；
    /// - `bounds` 传 1×1：只读那一个像素。
    ///
    /// <https://developer.apple.com/documentation/coreimage/ciareaaverage>
    /// <https://developer.apple.com/documentation/coreimage/cicontext/render(_:tobitmap:rowbytes:bounds:format:colorspace:)>
    ///
    /// - Parameter image: 采样尺寸的图。
    /// - Returns: 平均色；渲染失败（alpha 为 0）时 `nil`。
    private static func areaAverage(of image: CGImage) -> NSColor? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )
        guard bitmap[3] > 0 else { return nil }

        return NSColor(
            srgbRed: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: 1
        )
    }

    /// 把平均色收敛成适合做 UI 渐变的颜色。
    ///
    /// 平均色天生「发灰」：一张高对比画面的平均值接近中间灰，直接拿来当渐变会
    /// 显得脏。这里做三件事：
    ///
    /// - 饱和度提亮到 0.38…0.92（纯灰画面保持 0，不硬加色偏）；
    /// - 亮度压到 0.20…0.58（太亮会把白色标题吃掉，太暗看不出颜色）；
    /// - 色相不动（它才是「这张海报的颜色」）。
    ///
    /// - Parameter color: 平均色。
    /// - Returns: 渐变用色。
    private static func tuned(_ color: NSColor) -> NSColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let tunedSaturation = saturation < 0.05
            ? saturation
            : min(max(saturation * 1.30, 0.38), 0.92)
        let tunedBrightness = min(max(brightness * 0.92, 0.20), 0.58)

        return NSColor(
            hue: hue,
            saturation: tunedSaturation,
            brightness: tunedBrightness,
            alpha: 1
        )
    }
}

// MARK: - 预览

private struct CinematicHeaderPreviewBoard: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                section("有 backdrop + logo") {
                    CinematicHeader(
                        item: DetailPreviewData.movie,
                        backdropURL: DetailPreviewData.imageURL(
                            itemID: DetailPreviewData.movie.id,
                            kind: .backdrop,
                            tag: "tag-movie-backdrop"
                        ),
                        logoURL: DetailPreviewData.imageURL(
                            itemID: DetailPreviewData.movie.id,
                            kind: .logo,
                            tag: "tag-movie-logo"
                        )
                    )
                }

                section("无 logo（退回文字标题）") {
                    CinematicHeader(
                        item: DetailPreviewData.series,
                        backdropURL: DetailPreviewData.imageURL(
                            itemID: DetailPreviewData.series.id,
                            kind: .backdrop,
                            tag: "tag-series-backdrop"
                        ),
                        logoURL: nil
                    )
                }

                section("无 backdrop（骨架 + 强调色渐变）") {
                    CinematicHeader(item: DetailPreviewData.movie, backdropURL: nil, logoURL: nil)
                }
            }
            .padding(.vertical, Spacing.xl)
        }
        .background(Palette.surface)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(verbatim: title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.xl)
            content()
        }
    }
}

#Preview("CinematicHeader · 深色") {
    CinematicHeaderPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
        .frame(width: 980, height: 1400)
}

#Preview("CinematicHeader · 浅色") {
    CinematicHeaderPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
        .frame(width: 980, height: 1400)
}
