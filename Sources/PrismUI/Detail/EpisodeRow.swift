import PrismCore
import SwiftUI

// MARK: - 集卡片

/// 剧集详情页里的单集卡片（16:9 缩略图 + 集号 + 标题 + 简介 + 时长 + 进度）。
///
/// 按 `docs/research/ux-benchmark.md` §S08 的「Episode Rail」：
/// - 缩略图 16:9（`Thumb` 图，没有时退回 `Primary`）；
/// - 集号 `S2E5` + 集名 + 2 行简介 + 时长；
/// - 有进度时底部叠进度条，已看完时左上角打勾；
/// - **「接下来」那一集用强调色描边 + 「继续观看」角标高亮**，用户一眼能看到看到哪了；
/// - 悬停浮出播放按钮（点击整卡即播放，所以播放按钮只是视觉提示 + 可点区域）；
/// - 首播时间在未来的集显示「未播出」，播放禁用。
///
/// ```swift
/// EpisodeRow(
///     episode: episode,
///     isNextUp: episode.id == content.nextUpEpisode?.id,
///     thumbnailURL: model.thumbnailImageURL(for: episode),
///     onPlay: { actions.play(...) }
/// )
/// ```
public struct EpisodeRow: View {
    /// 卡片宽度（16:9 缩略图 + 文字）。
    public static let width: CGFloat = 260

    private let episode: MediaItem
    private let isNextUp: Bool
    private let thumbnailURL: URL?
    private let onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    /// 创建集卡片。
    ///
    /// - Parameters:
    ///   - episode: 单集。
    ///   - isNextUp: 是否为「接下来要看」的那一集（高亮）。
    ///   - thumbnailURL: 缩略图地址。
    ///   - onPlay: 播放回调。
    public init(
        episode: MediaItem,
        isNextUp: Bool,
        thumbnailURL: URL?,
        onPlay: @escaping () -> Void
    ) {
        self.episode = episode
        self.isNextUp = isNextUp
        self.thumbnailURL = thumbnailURL
        self.onPlay = onPlay
    }

    public var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                thumbnail
                textBlock
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .opacity(isPlayable ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(isPlayable ? "播放这一集" : "该集尚未播出"))
        .help(tooltip)
    }

    // MARK: 缩略图

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                AsyncPosterImage(
                    url: thumbnailURL,
                    targetSize: CGSize(width: 520, height: 293),
                    placeholderText: episode.name
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isNextUp ? Palette.accent : Palette.separator.opacity(0.6),
                        lineWidth: isNextUp ? 2 : 1
                    )
            }
            .overlay(alignment: .topLeading) { playedBadge }
            .overlay(alignment: .bottomLeading) { progressBar }
            .overlay { playGlyph }
            .overlay(alignment: .topTrailing) { upcomingBadge }
            .shadow(
                color: .black.opacity(isHovering ? 0.32 : 0),
                radius: isHovering ? 12 : 0,
                y: isHovering ? 6 : 0
            )
            .scaleEffect(isHovering && isPlayable && !reduceMotion ? 1.02 : 1)
    }

    /// 已看完的对勾。
    @ViewBuilder private var playedBadge: some View {
        if episode.userData.played {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(Spacing.sm)
                .accessibilityHidden(true)
        }
    }

    /// 「未播出」角标。
    @ViewBuilder private var upcomingBadge: some View {
        if !isPlayable {
            Text("未播出")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.62)))
                .padding(Spacing.sm)
        }
    }

    /// 悬停时浮出的播放按钮。
    @ViewBuilder private var playGlyph: some View {
        if isHovering, isPlayable {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white, .black.opacity(0.45))
                .shadow(color: .black.opacity(0.35), radius: 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 底部进度条；没有进度时不显示。
    @ViewBuilder private var progressBar: some View {
        if episode.userData.playbackPosition.rawValue > 0, !episode.userData.played {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.45))
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: proxy.size.width * episode.progress)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: 文字

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Spacing.xs) {
                if let code = code {
                    Text(verbatim: code)
                        .font(.system(.caption2, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isNextUp ? Palette.accent : Palette.textSecondary)
                }
                Text(verbatim: episode.name)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }

            if let overview = episode.overview, !overview.isEmpty {
                Text(verbatim: overview)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.xs) {
                if let duration = episode.durationText {
                    Text(verbatim: duration)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                if isNextUp {
                    Text("继续观看")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: 派生

    /// `S2E5`；缺号时为 `nil`。
    private var code: String? {
        guard let season = episode.parentIndexNumber, let index = episode.indexNumber else {
            return nil
        }
        return "S\(season)E\(index)"
    }

    /// 是否可播放：首播时间已到（或没有首播时间）。
    private var isPlayable: Bool {
        guard let premiere = episode.premiereDate else { return true }
        return premiere <= Date()
    }

    /// VoiceOver 朗读文本。
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let code { parts.append(code) }
        parts.append(episode.name)
        if let duration = episode.durationText { parts.append(duration) }
        if episode.userData.played { parts.append("已看完") }
        if isNextUp { parts.append("接下来观看") }
        return parts.joined(separator: "，")
    }

    /// 悬停提示：集名 + 简介首句。
    private var tooltip: String {
        guard let code else { return episode.name }
        return "\(code) · \(episode.name)"
    }
}

// MARK: - 预览

private struct EpisodeRowPreviewBoard: View {
    private let episodes = DetailPreviewData.episodes(in: "season-2")

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(episodes) { episode in
                    EpisodeRow(
                        episode: episode,
                        isNextUp: episode.id == "s2e4",
                        thumbnailURL: DetailPreviewData.imageURL(
                            itemID: episode.id,
                            kind: .thumb,
                            tag: "tag-\(episode.id)-thumb"
                        )
                    ) {}
                }

                EpisodeRow(
                    episode: DetailPreviewData.movie,
                    isNextUp: false,
                    thumbnailURL: nil
                ) {}
                .disabled(true)
            }
            .padding(Spacing.xl)
        }
        .background(Palette.surface)
    }
}

#Preview("EpisodeRow · 深色") {
    EpisodeRowPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
        .frame(width: 900, height: 400)
}

#Preview("EpisodeRow · 浅色") {
    EpisodeRowPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
        .frame(width: 900, height: 400)
}
