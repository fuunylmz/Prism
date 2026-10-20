import AppKit
import SwiftUI
import PrismCore

// MARK: - 预览图片加载器

/// 预览专用加载器：不联网，按 URL 生成一张渐变海报。
///
/// - 这样 `#Preview` 里能同时看到「有图」的真实观感，而不是一片占位符；
/// - URL 里包含 `fail` 时抛错，用来演示加载失败态；
/// - ``delay`` 用来演示骨架屏（加载中）。
///
/// 只在预览 / 演示里使用；生产代码应注入 ``PassthroughImageLoader`` 或 Nuke 实现。
struct PreviewImageLoader: PosterImageLoading {
    private let delay: Duration

    /// 创建预览加载器。
    ///
    /// - Parameter delay: 人为延迟，用于观察加载态；默认不延迟。
    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func image(for url: URL, targetSize: CGSize) async throws -> NSImage {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        guard !url.absoluteString.contains("fail") else {
            throw PosterImageError.unavailable
        }
        guard let image = Self.makeGradientImage(seed: Self.seed(for: url)) else {
            throw PosterImageError.decodingFailed
        }
        return image
    }

    /// 稳定的种子：同一 URL 每次预览得到同一张图。
    private static func seed(for url: URL) -> UInt32 {
        url.absoluteString.unicodeScalars.reduce(UInt32(7)) { partial, scalar in
            partial &* 31 &+ scalar.value
        }
    }

    /// 用 CoreGraphics 画一张 2:3 的渐变图（不依赖 AppKit 绘制上下文，线程安全）。
    private static func makeGradientImage(seed: UInt32) -> NSImage? {
        let width = 300
        let height = 450
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

        let hue = CGFloat(seed % 360) / 360
        let start = NSColor(calibratedHue: hue, saturation: 0.62, brightness: 0.42, alpha: 1).cgColor
        let end = NSColor(
            calibratedHue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
            saturation: 0.72,
            brightness: 0.78,
            alpha: 1
        ).cgColor

        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [start, end] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: height),
                end: CGPoint(x: width, y: 0),
                options: []
            )
        }

        // 两个半透明圆，让不同海报看起来有区分度。
        context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.fillEllipse(in: CGRect(x: -40, y: 250, width: 240, height: 240))
        context.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        context.fillEllipse(in: CGRect(x: 170, y: -60, width: 220, height: 220))

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }
}

// MARK: - 假数据

/// `#Preview` 用的假数据。
///
/// 所有条目都指向 `preview.prism.invalid` 假域名，**不会发起真实请求**
/// （配合 ``PreviewImageLoader`` 更是完全不联网）。
enum PreviewData {
    /// 假服务器 id。
    static let serverId = "preview-server"

    /// 海报地址（假域名，只给 ``PreviewImageLoader`` 用）。
    ///
    /// - Parameter id: 条目 id，用来生成不同的渐变。
    /// - Returns: 假地址；字符串恒定合法，因此正常不会为 `nil`。
    static func posterURL(for id: String) -> URL? {
        URL(string: "https://preview.prism.invalid/posters/\(id).jpg")
    }

    /// 正在观看的电影（带进度）。
    static let inProgressMovie = MediaItem(
        id: "preview-movie-1",
        name: "银翼杀手 2049",
        type: .movie,
        serverId: serverId,
        productionYear: 2017,
        runTime: Ticks(seconds: 9780),
        overview: "一名新一代银翼杀手揭开了尘封三十年的秘密，这个秘密有可能让社会陷入混乱。",
        officialRating: "R",
        communityRating: 8.0,
        genres: ["科幻", "剧情"],
        imageTags: [.primary: "tag-movie-1"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 2100),
            playCount: 1,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    )

    /// 已看完的电影。
    static let watchedMovie = MediaItem(
        id: "preview-movie-2",
        name: "降临",
        type: .movie,
        serverId: serverId,
        productionYear: 2016,
        runTime: Ticks(seconds: 6960),
        overview: "语言学家受雇于军方，试图与外星来客沟通。",
        officialRating: "PG-13",
        communityRating: 7.9,
        genres: ["科幻", "悬疑"],
        imageTags: [.primary: "tag-movie-2"],
        userData: UserItemData(
            playbackPosition: .zero,
            playCount: 2,
            isFavorite: true,
            played: true,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    )

    /// 未看过的剧集（带未看集数角标）。
    static let series = MediaItem(
        id: "preview-series-1",
        name: "人生切割术",
        type: .series,
        serverId: serverId,
        productionYear: 2022,
        runTime: Ticks(seconds: 3300),
        overview: "一家公司用手术把员工的工作记忆与生活记忆分离。",
        officialRating: "TV-MA",
        communityRating: 8.7,
        genres: ["剧情", "科幻"],
        imageTags: [.primary: "tag-series-1"],
        userData: UserItemData(
            playbackPosition: .zero,
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: 7
        )
    )

    /// 单集（4K / HDR 角标）。
    static let episode = MediaItem(
        id: "preview-episode-1",
        name: "第一集",
        type: .episode,
        serverId: serverId,
        productionYear: 2022,
        runTime: Ticks(seconds: 3420),
        overview: "新员工入职的第一天。",
        officialRating: "TV-MA",
        communityRating: 8.4,
        genres: ["剧情"],
        imageTags: [.primary: "tag-episode-1"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 640),
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        ),
        indexNumber: 1,
        parentIndexNumber: 1,
        seriesName: "人生切割术"
    )

    /// 网格用的一组条目。
    static let items: [MediaItem] = [inProgressMovie, watchedMovie, series, episode]

    /// 空态用的空数组。
    static let emptyItems: [MediaItem] = []

    /// 错误态用的示例错误（可恢复，因此会显示「重试」）。
    static let recoverableError: EmbyError = .serverUnreachable("预览数据：连接被拒绝")
}

// MARK: - 三态预览板

/// 演示 `LoadState` → 视图映射的三态总览。
private struct StateBoardPreview: View {
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: Spacing.lg)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                section("有数据 · loaded") {
                    LazyVGrid(columns: columns, spacing: Spacing.xl) {
                        ForEach(PreviewData.items) { item in
                            PosterCard(
                                title: item.name,
                                subtitle: item.subtitle,
                                imageURL: PreviewData.posterURL(for: item.id),
                                badges: item.id == PreviewData.episode.id ? [.fourK, .hdr] : [],
                                progress: item.isResumable ? item.progress : nil,
                                isPlayed: item.userData.played,
                                unplayedCount: item.userData.unplayedItemCount
                            )
                        }
                    }
                }

                section("空态 · empty") {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle.slash",
                        title: "这里还什么都没有",
                        message: "在 Emby 中添加媒体库后，回到这里刷新即可。",
                        actionTitle: "刷新"
                    ) {}
                }

                section("错误态 · failed") {
                    ErrorStateView(error: PreviewData.recoverableError) {}
                }
            }
            .padding(Spacing.xxl)
        }
        .frame(width: 720, height: 760)
        .background(Palette.surface)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title)
                .font(Typography.title)
                .foregroundStyle(Palette.textSecondary)
            content()
        }
    }
}

#Preview("三态总览 · 深色") {
    StateBoardPreview()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("三态总览 · 浅色") {
    StateBoardPreview()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

// MARK: - stateView 四态映射预览

/// 演示 `.stateView(_:)` 把 `LoadState` 映射成四种画面。
///
/// 加载中的占位直接用 ``LoadingStateView``；有数据时用 ``PosterCard``；
/// 空态 / 错误态使用默认文案。
private struct LoadStateMappingPreview: View {
    private let loading: LoadState<[MediaItem]> = .loading
    private let loaded: LoadState<[MediaItem]> = .loaded(PreviewData.items)
    private let empty: LoadState<[MediaItem]> = .empty
    private let failed: LoadState<[MediaItem]> = .failed(PreviewData.recoverableError)

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            pane("loading") {
                LoadingStateView(style: .list(rows: 3))
                    .stateView(loading) { items in
                        Text(verbatim: "\(items.count)")
                    }
            }
            pane("loaded") {
                LoadingStateView(style: .list(rows: 3))
                    .stateView(loaded) { items in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            PosterCard(
                                title: items.first?.name ?? "",
                                subtitle: items.first?.subtitle,
                                imageURL: PreviewData.posterURL(for: items.first?.id ?? "none"),
                                progress: items.first?.progress,
                                onSelect: {}
                            )
                            Text(verbatim: "\(items.count) 项")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
            }
            pane("empty") {
                LoadingStateView(style: .list(rows: 3))
                    .stateView(empty) { items in
                        Text(verbatim: "\(items.count)")
                    }
            }
            pane("failed") {
                LoadingStateView(style: .list(rows: 3))
                    .stateView(failed, onRetry: {}) { items in
                        Text(verbatim: "\(items.count)")
                    }
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 980, height: 460, alignment: .top)
        .background(Palette.surface)
    }

    private func pane(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            content()
                .frame(width: 210, height: 360)
                .background(Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }
}

#Preview("stateView 四态 · 深色") {
    LoadStateMappingPreview()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("stateView 四态 · 浅色") {
    LoadStateMappingPreview()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, PreviewImageLoader())
}
