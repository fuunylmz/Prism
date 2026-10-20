import PrismCore
import SwiftUI

// MARK: - 首页尺寸

/// 首页各卡片的尺寸与间距。
///
/// 数值来自 `docs/research/ux-benchmark.md` §S04 与 §5.3：
/// 海报卡 160pt 宽、2:3；横版卡 16:9；内容区左右边距随窗口宽度在 24 / 32 之间切换。
enum HomeMetrics {
    /// 海报卡宽度（2:3 → 240pt 高）。
    static let posterWidth: CGFloat = 160
    /// 「接下来」卡宽度（16:9 → 124pt 高）。
    static let episodeWidth: CGFloat = 220
    /// 横版卡宽度（16:9 → 135pt 高）。
    static let landscapeWidth: CGFloat = 240
    /// 「继续观看」卡宽度（16:9 → 162pt 高）。
    static let continueWatchingWidth: CGFloat = 288
    /// 媒体库网格的最小卡宽。
    static let libraryMinWidth: CGFloat = 180
    /// 媒体库网格的最大卡宽。
    static let libraryMaxWidth: CGFloat = 320

    /// 海报比例（2:3）。
    static let posterAspect: CGFloat = 2.0 / 3.0
    /// 横版比例（16:9）。
    static let landscapeAspect: CGFloat = 16.0 / 9.0

    /// 内容区左右边距：窗口 < 1200pt 用 24，否则 32（UX §5.3）。
    ///
    /// - Parameter width: 内容区宽度。
    /// - Returns: 左右边距。
    static func horizontalPadding(for width: CGFloat) -> CGFloat {
        width >= 1200 ? Spacing.xxl : Spacing.xl
    }
}

// MARK: - 横向分区容器

/// 横向分区的骨架：标题 + 「查看全部」+ 可横向滚动的卡片行。
///
/// ``MediaRail`` 与「继续观看」分区共用它，避免两处各写一遍标题栏与滚动容器。
struct RailScaffold<Content: View>: View {
    private let title: String
    private let onSeeAll: (() -> Void)?
    private let content: Content

    /// 创建分区骨架。
    ///
    /// - Parameters:
    ///   - title: 分区标题。
    ///   - onSeeAll: 「查看全部」回调；`nil` 时不显示按钮。
    ///   - content: 卡片行（通常是 `LazyHStack`）。
    init(
        title: String,
        onSeeAll: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.onSeeAll = onSeeAll
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(verbatim: title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)

                Spacer(minLength: Spacing.md)

                if let onSeeAll {
                    SeeAllButton(action: onSeeAll)
                }
            }
            .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                content
                    // hover 的放大与投影会被滚动容器裁掉，这里留出余量并放开裁剪。
                    .padding(.vertical, Spacing.xs)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }
}

/// 分区标题右侧的「查看全部 ›」。
private struct SeeAllButton: View {
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text("查看全部")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(Typography.caption)
            .foregroundStyle(isHovering ? Palette.accent : Palette.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .help("查看全部")
        .accessibilityLabel(Text("查看全部"))
    }
}

// MARK: - 卡片样式

/// 横向分区的卡片形态。
///
/// 只在 `PrismUI` 内部使用（``MediaRail`` 是内部组件），因此不对外公开——
/// 公开一个「外面用不到」的类型只会扩大 API 面。
enum RailStyle: Sendable, Hashable {
    /// 海报卡（2:3），用于「最新添加」。
    case poster
    /// 剧集缩略图（16:9），用于「接下来」。
    case episode
    /// 横版卡（16:9），用于混合内容的横滑行。
    case landscape

    /// 卡片宽度。
    var cardWidth: CGFloat {
        switch self {
        case .poster: HomeMetrics.posterWidth
        case .episode: HomeMetrics.episodeWidth
        case .landscape: HomeMetrics.landscapeWidth
        }
    }

    /// 图片宽高比。
    var aspectRatio: CGFloat {
        switch self {
        case .poster: HomeMetrics.posterAspect
        case .episode, .landscape: HomeMetrics.landscapeAspect
        }
    }
}

// MARK: - 横向分区

/// 可复用的横向分区：标题 + 「查看全部」+ 横向滚动的一行卡片。
///
/// 图片地址从环境里的 ``HomeImageResolver`` 取（由 ``HomeView`` 在根部注入一次），
/// 因此调用方只需要给条目，不必层层透传图片闭包。
///
/// ```swift
/// MediaRail(
///     title: "最新添加",
///     items: content.latest,
///     onSelect: { model.navigate(to: .detail(itemId: $0.id)) },
///     onSeeAll: { openMore(.latest) },
///     style: .poster,
///     onPlay: { play($0) }
/// )
/// ```
struct MediaRail: View {
    /// 分区标题。
    let title: String
    /// 分区条目（空数组时请由调用方直接隐藏整段）。
    let items: [MediaItem]
    /// 单击卡片。
    let onSelect: (MediaItem) -> Void
    /// 「查看全部」；`nil` 时不显示按钮。
    let onSeeAll: (() -> Void)?
    /// 卡片形态。
    let style: RailStyle
    /// 播放回调；提供时 hover 会浮出播放按钮，双击卡片也直接播放。
    let onPlay: ((MediaItem) -> Void)?

    @Environment(\.homeImageResolver) private var resolver

    /// 创建横向分区。
    ///
    /// - Parameters:
    ///   - title: 分区标题。
    ///   - items: 条目。
    ///   - onSelect: 单击卡片回调。
    ///   - onSeeAll: 「查看全部」回调，默认 `nil`（不显示按钮）。
    ///   - style: 卡片形态，默认 ``RailStyle/poster``。
    ///   - onPlay: 播放回调，默认 `nil`。
    init(
        title: String,
        items: [MediaItem],
        onSelect: @escaping (MediaItem) -> Void,
        onSeeAll: (() -> Void)? = nil,
        style: RailStyle = .poster,
        onPlay: ((MediaItem) -> Void)? = nil
    ) {
        self.title = title
        self.items = items
        self.onSelect = onSelect
        self.onSeeAll = onSeeAll
        self.style = style
        self.onPlay = onPlay
    }

    var body: some View {
        RailScaffold(title: title, onSeeAll: onSeeAll) {
            LazyHStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(items) { item in
                    card(for: item)
                }
            }
        }
    }

    // MARK: 卡片

    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        switch style {
        case .poster:
            PosterCard(
                title: item.name,
                subtitle: item.subtitle,
                imageURL: resolver.posterURL(for: item),
                badges: Self.badges(for: item),
                progress: item.isResumable ? item.progress : nil,
                isPlayed: item.userData.played,
                unplayedCount: item.userData.unplayedItemCount,
                onPlay: playAction(for: item),
                onSelect: { onSelect(item) }
            )
            .frame(width: HomeMetrics.posterWidth)

        case .episode:
            ThumbnailCard(
                title: item.seriesName ?? item.name,
                subtitle: Self.episodeSubtitle(for: item),
                imageURL: resolver.thumbnailURL(for: item),
                badge: "下一集",
                width: HomeMetrics.episodeWidth,
                onPlay: playAction(for: item),
                onSelect: { onSelect(item) }
            )

        case .landscape:
            ThumbnailCard(
                title: item.name,
                subtitle: item.subtitle,
                imageURL: resolver.thumbnailURL(for: item),
                badge: nil,
                width: HomeMetrics.landscapeWidth,
                onPlay: playAction(for: item),
                onSelect: { onSelect(item) }
            )
        }
    }

    /// 把 `onPlay` 包装成 `PosterCard` 需要的「无参」闭包。
    private func playAction(for item: MediaItem) -> (() -> Void)? {
        guard let onPlay else { return nil }
        return { onPlay(item) }
    }

    // MARK: 文案

    /// 剧集副标题：`第 2 季 第 5 集 · 集名`。
    ///
    /// 季 / 集号缺失时退回 ``PrismCore/MediaItem/subtitle``（通常是 `S02E05` 或年份）。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 副标题。
    static func episodeSubtitle(for item: MediaItem) -> String? {
        guard let season = item.parentIndexNumber, let episode = item.indexNumber else {
            return item.subtitle
        }
        let marker = "第 \(season) 季 第 \(episode) 集"
        guard let name = item.name.isEmpty ? nil : item.name else { return marker }
        return "\(marker) · \(name)"
    }

    /// 画质角标（4K / HDR）。
    ///
    /// 只在服务端确实返回了媒体流信息时才给角标：列表接口默认不带
    /// `MediaSources`，此时返回空数组——**不猜**，否则会出现「4K 角标 + 1080p 片源」。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 角标数组（通常为空）。
    static func badges(for item: MediaItem) -> [PosterBadge] {
        guard let video = item.mediaSources
            .first?.mediaStreams
            .first(where: { $0.type == .video })
        else { return [] }

        var badges: [PosterBadge] = []
        if let height = video.height, height >= 2160 {
            badges.append(.fourK)
        }
        if let range = video.videoRange?.uppercased() {
            if range.contains("DOLBY") || range.contains("DOVI") {
                badges.append(.dolbyVision)
            } else if range.contains("HDR") || range.contains("HLG") {
                badges.append(.hdr)
            }
        }
        return badges
    }
}

// MARK: - 横版缩略卡

/// 16:9 的横版卡：剧集缩略图、混合内容横滑行用。
///
/// 与 ``PosterCard`` 的分工：海报固定 2:3（UX §5.0 硬性要求），横版图只能出现在
/// 集缩略图与详情页头部；本组件就是「集缩略图」这一支。
struct ThumbnailCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let badge: String?
    let width: CGFloat
    let onPlay: (() -> Void)?
    let onSelect: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            thumbnail
            textBlock
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(HomeMetrics.landscapeAspect, contentMode: .fit)
            .overlay {
                AsyncPosterImage(
                    url: imageURL,
                    targetSize: CGSize(width: width * 2, height: width * 2 / HomeMetrics.landscapeAspect),
                    placeholderText: title
                )
            }
            .overlay { hoverOverlay }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isHovering ? Palette.separator : Palette.separator.opacity(0.5),
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .topTrailing) { badgeView }
            .shadow(
                color: isHovering ? .black.opacity(0.35) : .clear,
                radius: isHovering ? 16 : 0,
                x: 0,
                y: isHovering ? 8 : 0
            )
            .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
    }

    @ViewBuilder
    private var hoverOverlay: some View {
        if isHovering {
            ZStack {
                Palette.scrim.opacity(0.45)
                    .allowsHitTesting(false)

                if let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("播放"))
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            Text(verbatim: badge)
                .font(Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.accent))
                .padding(Spacing.sm)
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 媒体库入口

/// 媒体库网格入口。
///
/// 首页最后一段：把 `/Views` 的结果排成自适应网格，点击进入对应媒体库。
struct LibraryGrid: View {
    let items: [MediaItem]
    let onSelect: (MediaItem) -> Void

    @Environment(\.homeImageResolver) private var resolver

    private let columns = [
        GridItem(
            .adaptive(minimum: HomeMetrics.libraryMinWidth, maximum: HomeMetrics.libraryMaxWidth),
            spacing: Spacing.lg,
            alignment: .top
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("媒体库")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.lg) {
                ForEach(items) { item in
                    LibraryTile(
                        item: item,
                        imageURL: resolver.url(for: item, kind: .primary, maxWidth: 480),
                        onSelect: { onSelect(item) }
                    )
                }
            }
        }
    }
}

/// 单个媒体库入口卡片。
private struct LibraryTile: View {
    let item: MediaItem
    let imageURL: URL?
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Color.clear
                .aspectRatio(HomeMetrics.landscapeAspect, contentMode: .fit)
                .overlay {
                    AsyncPosterImage(
                        url: imageURL,
                        targetSize: CGSize(width: 480, height: 270),
                        placeholderText: item.name
                    )
                }
                .overlay {
                    if imageURL == nil {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Palette.textSecondary)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if isHovering {
                        Palette.scrim.opacity(0.35)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(
                            isHovering ? Palette.accent : Palette.separator.opacity(0.5),
                            lineWidth: isHovering ? 2 : 1
                        )
                }
                .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                if let count = item.childCount, count > 0 {
                    Text("\(count) 项")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 预览

#Preview("MediaRail · 海报（有数据）") {
    MediaRail(
        title: "最新添加",
        items: HomePreviewData.latestItems,
        onSelect: { _ in },
        onSeeAll: {},
        style: .poster,
        onPlay: { _ in }
    )
    .padding(Spacing.xl)
    .frame(width: 900)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}

#Preview("MediaRail · 剧集（有数据）") {
    MediaRail(
        title: "接下来",
        items: HomePreviewData.nextUpItems,
        onSelect: { _ in },
        onSeeAll: {},
        style: .episode,
        onPlay: { _ in }
    )
    .padding(Spacing.xl)
    .frame(width: 900)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}

#Preview("MediaRail · 空 items（整段隐藏由 HomeView 负责）") {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        Text("空 items：本组件不渲染任何卡片，调用方应整段隐藏")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)

        MediaRail(title: "最新添加", items: [], onSelect: { _ in }, style: .poster)

        Divider()

        Text("有数据（对照组）")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)

        MediaRail(
            title: "最新添加",
            items: HomePreviewData.latestItems,
            onSelect: { _ in },
            onSeeAll: {},
            style: .poster,
            onPlay: { _ in }
        )
    }
    .padding(Spacing.xl)
    .frame(width: 900)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}

#Preview("MediaRail · 横版样式") {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        MediaRail(
            title: "横版样式",
            items: HomePreviewData.libraryItems,
            onSelect: { _ in },
            onSeeAll: {},
            style: .landscape,
            onPlay: { _ in }
        )
    }
    .padding(Spacing.xl)
    .frame(width: 900)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}

#Preview("LibraryGrid · 有数据 / 无图 / 空") {
    VStack(alignment: .leading, spacing: Spacing.xxl) {
        LibraryGrid(items: HomePreviewData.libraryItems, onSelect: { _ in })

        LibraryGrid(items: [HomePreviewData.offlineLibrary], onSelect: { _ in })

        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("空 items：只剩分区标题（真实场景由 HomeView 整段隐藏）")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            LibraryGrid(items: [], onSelect: { _ in })
        }
    }
    .padding(Spacing.xl)
    .frame(width: 900)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}
