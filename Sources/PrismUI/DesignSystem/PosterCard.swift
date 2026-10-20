import SwiftUI

// MARK: - 角标

/// 海报右上角的画质角标。
///
/// 只在服务端确实给了对应信息时才传（4K = 视频流宽高 ≥ 3840，HDR = `videoRange` 含 HDR），
/// 不要靠猜测，否则会出现「4K 角标 + 1080p 片源」的误导。
public enum PosterBadge: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// 4K / UHD。
    case fourK = "4K"
    /// HDR10 / HLG。
    case hdr = "HDR"
    /// Dolby Vision。
    case dolbyVision = "DV"

    /// `Identifiable` 要求的稳定 id。
    public var id: String { rawValue }

    /// 展示文案（本身就是国际通用写法，无需本地化）。
    public var label: String { rawValue }
}

// MARK: - 海报卡

/// 海报卡：媒体网格与横滑行的最小单元。
///
/// **比例固定 2:3**（`docs/research/ux-benchmark.md` §5.0 的硬性要求）：
/// Emby / TMDB 的海报都是 2:3，混用 16:9 会让网格出现参差不齐的洞。
/// 横版图只用于详情页头部与集缩略图，不要用本组件承载。
///
/// 状态：
/// - 默认：海报 + 标题（+ 可选副标题）；
/// - hover：放大到 1.03、加投影、浮出播放按钮（``Motion/quick``）；
/// - 选中：强调色 2pt 描边；
/// - 播放中：强调色描边 + 底部进度条；
/// - 已看 / 未看集数 / 4K·HDR 角标：按参数显示。
///
/// 图片加载失败会显示占位图（见 ``AsyncPosterImage``），不会出现空白格。
///
/// ```swift
/// PosterCard(
///     title: item.name,
///     subtitle: item.subtitle,
///     imageURL: posterURL,
///     isSelected: selection == item.id,
///     progress: item.isResumable ? item.progress : nil,
///     unplayedCount: item.userData.unplayedItemCount,
///     onPlay: { play(item) },
///     onSelect: { selection = item.id }
/// )
/// .frame(width: 180)
/// ```
public struct PosterCard: View {
    private let title: String
    private let subtitle: String?
    private let imageURL: URL?
    private let badges: [PosterBadge]
    private let isSelected: Bool
    private let isPlaying: Bool
    private let progress: Double?
    private let isPlayed: Bool
    private let unplayedCount: Int?
    private let onPlay: (() -> Void)?
    private let onSelect: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /// 创建海报卡。
    ///
    /// - Parameters:
    ///   - title: 标题（服务端数据，按原样显示，1 行截断）。
    ///   - subtitle: 副标题（年份 / `S1E2` / 剩余时长），可选。
    ///   - imageURL: 海报地址；`nil` 时显示占位图。
    ///   - badges: 右上角画质角标，默认空。
    ///   - isSelected: 是否选中（强调色描边）。
    ///   - isPlaying: 是否正在播放（显示进度条与播放指示）。
    ///   - progress: 观看进度 0...1；`nil` 表示不显示进度条。
    ///   - isPlayed: 是否已看完（左上角对勾）。
    ///   - unplayedCount: 未看集数；`> 0` 时左上角显示数字角标。
    ///   - onPlay: 播放回调；提供时 hover 会浮出可点击的播放按钮。
    ///   - onSelect: 单击回调（打开详情）。
    public init(
        title: String,
        subtitle: String? = nil,
        imageURL: URL? = nil,
        badges: [PosterBadge] = [],
        isSelected: Bool = false,
        isPlaying: Bool = false,
        progress: Double? = nil,
        isPlayed: Bool = false,
        unplayedCount: Int? = nil,
        onPlay: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.badges = badges
        self.isSelected = isSelected
        self.isPlaying = isPlaying
        self.progress = progress
        self.isPlayed = isPlayed
        self.unplayedCount = unplayedCount
        self.onPlay = onPlay
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            poster
            textBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 语义见 `docs/research/ux-benchmark.md` §S05：单击选中、双击播放。
        // 双击手势必须注册在单击**之前**；且只有提供 `onPlay` 时才挂载，
        // 否则不可播放的卡片（文件夹、合集）每次单击都要等双击判定超时。
        .modifier(DoubleTapToPlay(isEnabled: onPlay != nil, action: { onPlay?() }))
        .onTapGesture {
            onSelect?()
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    // MARK: 海报

    private var poster: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                AsyncPosterImage(
                    url: imageURL,
                    targetSize: CGSize(width: 360, height: 540),
                    placeholderText: title
                )
            }
            .overlay {
                hoverOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.poster, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .overlay(alignment: .topLeading) {
                topLeadingBadges
            }
            .overlay(alignment: .topTrailing) {
                qualityBadges
            }
            .overlay(alignment: .bottom) {
                progressBar
            }
            .shadow(
                color: isHovering ? .black.opacity(0.35) : .clear,
                radius: isHovering ? 16 : 0,
                x: 0,
                y: isHovering ? 8 : 0
            )
            .scaleEffect(hoverScale, anchor: .center)
    }

    /// hover 时的压暗 + 播放按钮。
    private var hoverOverlay: some View {
        ZStack {
            if isHovering {
                Palette.scrim.opacity(0.45)
                    .allowsHitTesting(false)
                playAffordance
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var playAffordance: some View {
        if let onPlay {
            Button(action: onPlay) {
                playGlyph
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("播放"))
        } else {
            playGlyph
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    // MARK: 角标

    @ViewBuilder
    private var topLeadingBadges: some View {
        let hasWatched = isPlayed
        let hasUnplayed = (unplayedCount ?? 0) > 0
        if hasWatched || hasUnplayed {
            HStack(spacing: Spacing.xs) {
                if hasWatched {
                    watchedBadge
                }
                if let unplayedCount, unplayedCount > 0 {
                    unplayedBadge(count: unplayedCount)
                }
            }
            .padding(Spacing.sm)
        }
    }

    private var watchedBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(Circle().fill(.black.opacity(0.62)))
            .accessibilityLabel(Text("已看"))
    }

    private func unplayedBadge(count: Int) -> some View {
        Text("\(count)")
            .font(Typography.caption)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Palette.accent))
            .accessibilityLabel(Text("\(count) 集未看"))
    }

    @ViewBuilder
    private var qualityBadges: some View {
        if !badges.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(badges) { badge in
                    Text(verbatim: badge.label)
                        .font(Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.62)))
                        .accessibilityLabel(Text(verbatim: badge.label))
                }
            }
            .padding(Spacing.sm)
        }
    }

    // MARK: 进度

    @ViewBuilder
    private var progressBar: some View {
        if let value = progressFraction {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: proxy.size.width * value)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, Spacing.xs)
            .padding(.bottom, Spacing.xs)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 进度值（已夹到 0...1）；播放中即使没有进度也显示轨道。
    private var progressFraction: Double? {
        guard let progress else {
            return isPlaying ? 0 : nil
        }
        return min(max(progress, 0), 1)
    }

    // MARK: 文字

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                HStack(spacing: Spacing.xs) {
                    if isPlaying {
                        playingGlyph
                    }
                    Text(verbatim: subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            } else if isPlaying {
                HStack(spacing: Spacing.xs) {
                    playingGlyph
                    Text("正在播放")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playingGlyph: some View {
        Image(systemName: "waveform")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.accent)
            .accessibilityLabel(Text("正在播放"))
    }

    // MARK: 状态

    private var borderColor: Color {
        if isSelected || isPlaying {
            Palette.accent
        } else if isHovering {
            Palette.separator
        } else {
            Palette.separator.opacity(0.5)
        }
    }

    private var borderWidth: CGFloat {
        isSelected || isPlaying ? 2 : 1
    }

    private var hoverScale: CGFloat {
        isHovering && !reduceMotion ? 1.03 : 1.0
    }
}

// MARK: - 双击播放

/// 条件挂载的双击手势。
///
/// `isEnabled == false` 时完全不挂载，避免单击选中被双击判定延迟。
private struct DoubleTapToPlay: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.onTapGesture(count: 2, perform: action)
        } else {
            content
        }
    }
}

// MARK: - 预览

private struct PosterCardPreviewBoard: View {
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.lg)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.xl) {
            PosterCard(
                title: PreviewData.inProgressMovie.name,
                subtitle: "继续观看 · 剩余 2 小时 8 分",
                imageURL: PreviewData.posterURL(for: PreviewData.inProgressMovie.id),
                progress: PreviewData.inProgressMovie.progress,
                onPlay: {},
                onSelect: {}
            )

            PosterCard(
                title: PreviewData.watchedMovie.name,
                subtitle: PreviewData.watchedMovie.subtitle,
                imageURL: PreviewData.posterURL(for: PreviewData.watchedMovie.id),
                isSelected: true,
                isPlayed: true,
                onPlay: {},
                onSelect: {}
            )

            PosterCard(
                title: PreviewData.series.name,
                subtitle: PreviewData.series.subtitle,
                imageURL: PreviewData.posterURL(for: PreviewData.series.id),
                unplayedCount: PreviewData.series.userData.unplayedItemCount,
                onPlay: {},
                onSelect: {}
            )

            PosterCard(
                title: PreviewData.episode.name,
                subtitle: PreviewData.episode.subtitle,
                imageURL: PreviewData.posterURL(for: PreviewData.episode.id),
                badges: [.fourK, .hdr],
                isPlaying: true,
                progress: PreviewData.episode.progress,
                onPlay: {},
                onSelect: {}
            )

            PosterCard(
                title: "无海报的条目",
                subtitle: "占位图",
                imageURL: nil,
                onSelect: {}
            )

            PosterCard(
                title: "禁用态",
                subtitle: "不可点",
                imageURL: PreviewData.posterURL(for: "disabled"),
                onSelect: {}
            )
            .disabled(true)
        }
        .padding(Spacing.xxl)
        .frame(width: 760)
        .background(Palette.surface)
    }
}

#Preview("PosterCard · 深色") {
    PosterCardPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("PosterCard · 浅色") {
    PosterCardPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, PreviewImageLoader())
}
