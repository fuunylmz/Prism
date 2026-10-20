import PrismCore
import SwiftUI

// MARK: - 继续观看卡片

/// 「继续观看」专用卡片。
///
/// 与 ``PosterCard`` 的区别是**用横版剧照（Backdrop）而不是 2:3 海报**：
/// 继续观看是「回到上次的画面」，横向截图比海报更贴近用户的记忆，
/// 也能在卡片上容纳进度条与剩余时间。
///
/// 结构（自下而上）：
/// - 底部：进度条（强调色已播段）+「剩余 32 分钟」；
/// - 左下：标题（剧集显示剧名）与 `S1E2 · 集名`；
/// - 右上：小播放图标，hover 时放大成可点击的主播放按钮；
/// - hover：整卡放大 1.03 + 投影（尊重「减弱动态效果」）。
///
/// ```swift
/// ContinueWatchingCard(item: item, onPlay: { play(item) }, onSelect: { open(item) })
/// ```
public struct ContinueWatchingCard: View {
    private let item: MediaItem
    private let onPlay: (() -> Void)?
    private let onSelect: (() -> Void)?

    @Environment(\.homeImageResolver) private var resolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// 创建继续观看卡片。
    ///
    /// - Parameters:
    ///   - item: 条目（通常带 `PlaybackPositionTicks`）。
    ///   - onPlay: 播放回调（从上次位置继续）。
    ///   - onSelect: 单击回调（打开详情）。
    public init(
        item: MediaItem,
        onPlay: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.item = item
        self.onPlay = onPlay
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            artwork
            caption
        }
        .frame(width: HomeMetrics.continueWatchingWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: accessibilityTitle))
    }

    // MARK: 画面

    private var artwork: some View {
        Color.clear
            .aspectRatio(HomeMetrics.landscapeAspect, contentMode: .fit)
            .overlay {
                AsyncPosterImage(
                    url: resolver.backdropURL(for: item),
                    targetSize: CGSize(
                        width: HomeMetrics.continueWatchingWidth * 2,
                        height: HomeMetrics.continueWatchingWidth * 2 / HomeMetrics.landscapeAspect
                    ),
                    placeholderText: item.name
                )
            }
            .overlay { bottomScrim }
            .overlay { hoverScrim }
            .overlay(alignment: .bottomLeading) { overlayText }
            .overlay(alignment: .bottom) { progressBar }
            .overlay(alignment: .topTrailing) { playIndicator }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isHovering ? Palette.separator : Palette.separator.opacity(0.5),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: isHovering ? .black.opacity(0.35) : .clear,
                radius: isHovering ? 16 : 0,
                x: 0,
                y: isHovering ? 8 : 0
            )
            .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
    }

    /// 底部渐变：保证白字在亮色剧照上也读得清。
    private var bottomScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0.45),
                .init(color: .black.opacity(0.72), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var overlayText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.seriesName ?? item.name)
                .font(Typography.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            HStack(spacing: Spacing.xs) {
                if let marker = episodeMarker {
                    Text(verbatim: marker)
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }
                if let remaining = Self.remainingText(for: item) {
                    Text(verbatim: remaining)
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        // 底部留出进度条的位置，避免文字被压条压住。
        .padding(.bottom, Spacing.md)
        .allowsHitTesting(false)
    }

    /// 进度条：轨道 + 强调色已播段。
    @ViewBuilder
    private var progressBar: some View {
        let fraction = min(max(item.progress, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 右上角播放指示；hover 时变成可点击的大按钮。
    @ViewBuilder
    private var playIndicator: some View {
        if isHovering, let onPlay {
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
            .padding(Spacing.sm)
            .transition(.opacity)
            .accessibilityLabel(Text("继续播放"))
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.55)))
                .padding(Spacing.sm)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// hover 时压暗整张图，让播放按钮更突出。
    @ViewBuilder
    private var hoverScrim: some View {
        if isHovering {
            Palette.scrim.opacity(0.28)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: 文字

    /// 卡片下方的标题（与服务端返回的条目名一致）。
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.name)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            if let remaining = Self.remainingText(for: item) {
                Text(verbatim: remaining)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 无障碍标签：标题 + 剩余时间。
    private var accessibilityTitle: String {
        var parts = [item.seriesName ?? item.name]
        if let marker = episodeMarker { parts.append(marker) }
        if let remaining = Self.remainingText(for: item) { parts.append(remaining) }
        return parts.joined(separator: "，")
    }

    /// 集标记（`第 2 季 第 5 集`）；电影为 `nil`。
    private var episodeMarker: String? {
        guard let season = item.parentIndexNumber, let episode = item.indexNumber else {
            return nil
        }
        return "第 \(season) 季 第 \(episode) 集"
    }

    // MARK: 剩余时间

    /// 剩余时长文案：「剩余 32 分钟」。
    ///
    /// 规则：< 1 分钟 → 「剩余不到 1 分钟」；≥ 1 小时 → 「剩余 1 小时 32 分钟」
    /// （整小时省略分钟）。时长未知时返回 `nil`（不显示，而不是显示「剩余 0 分钟」）。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 文案；未知时长时为 `nil`。
    static func remainingText(for item: MediaItem) -> String? {
        guard let runTime = item.runTime, runTime.rawValue > 0 else { return nil }

        let remainingSeconds = max(0, runTime.seconds - item.userData.playbackPosition.seconds)
        if remainingSeconds < 60 {
            return "剩余不到 1 分钟"
        }

        let totalMinutes = Int(remainingSeconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return minutes > 0 ? "剩余 \(hours) 小时 \(minutes) 分钟" : "剩余 \(hours) 小时"
        }
        return "剩余 \(minutes) 分钟"
    }
}

// MARK: - 预览

#Preview("继续观看 · 有进度") {
    HStack(alignment: .top, spacing: Spacing.lg) {
        ContinueWatchingCard(item: HomePreviewData.inProgressMovie, onPlay: {}, onSelect: {})
        ContinueWatchingCard(item: HomePreviewData.inProgressEpisode, onPlay: {}, onSelect: {})
        ContinueWatchingCard(item: HomePreviewData.noProgressEpisode, onSelect: {})
    }
    .padding(Spacing.xxl)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}

#Preview("继续观看 · 无图 / 无时长") {
    HStack(alignment: .top, spacing: Spacing.lg) {
        ContinueWatchingCard(item: HomePreviewData.missingArtwork, onPlay: {}, onSelect: {})
        ContinueWatchingCard(item: HomePreviewData.unknownRuntime, onPlay: {}, onSelect: {})
    }
    .padding(Spacing.xxl)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader())
}

#Preview("继续观看 · 加载中（图片骨架）") {
    // `PreviewImageLoader(delay:)` 让图片晚一点到，能看到 `AsyncPosterImage` 的骨架态。
    HStack(alignment: .top, spacing: Spacing.lg) {
        ContinueWatchingCard(item: HomePreviewData.inProgressMovie, onPlay: {}, onSelect: {})
        ContinueWatchingCard(item: HomePreviewData.inProgressEpisode, onPlay: {}, onSelect: {})
    }
    .padding(Spacing.xxl)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
    .homeImageResolver(HomePreviewData.imageResolver)
    .posterImageLoader(PreviewImageLoader(delay: .seconds(30)))
}
