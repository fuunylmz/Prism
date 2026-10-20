import AppKit
import PrismCore
import SwiftUI

// MARK: - 电影详情

/// 电影（以及所有非剧集条目）的详情页。
///
/// 布局按 `docs/research/ux-benchmark.md` §S07：
///
/// ```
/// Cinematic Header（backdrop + logo + 取色渐变）
/// 操作按钮行（▶ 播放 / ✓ 已看 / ♡ 收藏 / ⋯ 更多）
/// 简介（4 行截断，可展开）
/// 演职员（横向圆形头像）
/// 相似推荐（横向海报）
/// ```
///
/// 四态由 ``PrismUI/LoadState`` 统一驱动：加载中显示 ``DetailSkeletonView``，
/// 失败显示带重试的错误态，成功才渲染头图（避免头图先出现再被错误覆盖的闪烁）。
///
/// - Important: 视图用 `@State` 持有视图模型，因此**同一份数据源 + 同一个 itemId**
///   才会复用模型。切换到别的条目时，请在调用处加 `.id(itemId)`，否则会继续显示
///   上一个条目的内容。
public struct MovieDetailView: View {
    @State private var model: DetailViewModel
    private let actions: DetailActions

    /// 创建电影详情页。
    ///
    /// - Parameters:
    ///   - model: 视图模型（由调用方创建，内部 `@State` 持有）。
    ///   - actions: 播放 / 打开别的条目的回调，默认什么都不做。
    public init(model: DetailViewModel, actions: DetailActions = DetailActions()) {
        _model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some View {
        DetailSkeletonView()
            .stateView(model.state, onRetry: { Task { await model.load() } }) { content in
                loadedBody(content)
            }
            .background(Palette.surface)
            .task { await model.loadIfNeeded() }
    }

    // MARK: 有数据

    private func loadedBody(_ content: DetailContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CinematicHeader(
                    item: content.item,
                    backdropURL: model.headerImageURL(for: content.item),
                    logoURL: model.logoImageURL(for: content.item)
                )

                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        DetailActionRow(
                            content: content,
                            isUpdatingPlayed: model.isUpdatingPlayed,
                            isUpdatingFavorite: model.isUpdatingFavorite,
                            onPlay: { actions.play($0) },
                            onTogglePlayed: { Task { await model.togglePlayed() } },
                            onToggleFavorite: { Task { await model.toggleFavorite() } },
                            onRefresh: { Task { await model.load() } }
                        )

                        if let error = model.actionError {
                            DetailActionErrorBanner(error: error) { model.clearActionError() }
                        }
                    }

                    if let overview = content.item.overview, !overview.isEmpty {
                        DetailOverview(text: overview)
                    }

                    if !content.people.isEmpty {
                        DetailSection(title: "演职员") {
                            CastRow(people: content.people) { person in
                                model.avatarImageURL(for: person)
                            }
                        }
                    }

                    if !content.similar.isEmpty {
                        DetailSection(title: "相似推荐") {
                            DetailSimilarRow(
                                items: content.similar,
                                imageURL: { model.posterImageURL(for: $0) },
                                onPlay: { item in
                                    actions.play(
                                        DetailPlaybackRequest(
                                            itemId: item.id,
                                            resumeAt: item.userData.played
                                                ? .zero
                                                : item.userData.playbackPosition
                                        )
                                    )
                                },
                                onSelect: { actions.openItem($0.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
            }
        }
    }
}

// MARK: - 操作按钮行

/// 播放 / 已看 / 收藏 / 更多。
///
/// 电影与剧集共用：主按钮的文案由 ``DetailContent/primaryPlayback`` 决定
/// （「播放」/「从 12:34 继续」/「继续观看 S2E5」…），剧集不需要另一套按钮。
struct DetailActionRow: View {
    let content: DetailContent
    let isUpdatingPlayed: Bool
    let isUpdatingFavorite: Bool
    let onPlay: (DetailPlaybackRequest) -> Void
    let onTogglePlayed: () -> Void
    let onToggleFavorite: () -> Void
    let onRefresh: () -> Void

    private var isPlayed: Bool { content.item.userData.played }
    private var isFavorite: Bool { content.item.userData.isFavorite }

    var body: some View {
        HStack(spacing: Spacing.md) {
            PrismPrimaryButton(playLabel, systemImage: "play.fill") {
                play()
            }
            .disabled(content.primaryPlaybackItem == nil)
            .help(playHelp)

            DetailToggleButton(
                systemImage: isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                title: isPlayed ? "已看" : "标记已看",
                isOn: isPlayed,
                isBusy: isUpdatingPlayed,
                action: onTogglePlayed
            )

            DetailToggleButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                title: isFavorite ? "已收藏" : "收藏",
                isOn: isFavorite,
                isBusy: isUpdatingFavorite,
                action: onToggleFavorite
            )

            Menu {
                Button("复制标题", systemImage: "doc.on.doc") {
                    copyTitle()
                }
                Button("刷新详情", systemImage: "arrow.clockwise", action: onRefresh)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel(Text("更多"))

            Spacer(minLength: 0)
        }
    }

    // MARK: 主按钮

    /// 主按钮文案。
    private var playLabel: LocalizedStringKey {
        switch content.primaryPlayback {
        case .play:
            return "播放"
        case let .resume(position):
            return "从 \(position.formatted) 继续"
        case .rewatch:
            return "重新播放"
        case let .continueEpisode(episode):
            if let code = content.episodeCode(for: episode) {
                return "继续观看 \(code)"
            }
            return "继续观看"
        case let .restartSeries(episode):
            if let code = content.episodeCode(for: episode) {
                return "重新观看 \(code)"
            }
            return "重新观看"
        }
    }

    /// 主按钮的 tooltip：剧集显示「S2E5 · 集名」，悬停即可确认要播哪一集。
    private var playHelp: String {
        guard let target = content.primaryPlaybackItem else { return "该季暂无剧集" }
        if content.isSeries {
            let code = content.episodeCode(for: target) ?? ""
            return code.isEmpty ? target.name : "\(code) · \(target.name)"
        }
        return target.name
    }

    /// 发起播放。
    private func play() {
        guard let target = content.primaryPlaybackItem else { return }
        onPlay(
            DetailPlaybackRequest(
                itemId: target.id,
                resumeAt: content.primaryResumePosition
            )
        )
    }

    /// 复制标题到剪贴板。
    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.item.name, forType: .string)
    }
}

// MARK: - 开关按钮

/// 带选中态的次按钮（已看 / 收藏）。
///
/// 视觉与 ``PrismUI/PrismSecondaryButton`` 同族：同样的高度、圆角与描边，
/// 选中时改用强调色描边 + 强调色文字 + 12% 强调色底，**不靠填充强调色**
/// （系统强调色可能是黄色，填充后文字对比度不可控）。
struct DetailToggleButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    let isOn: Bool
    let isBusy: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(Typography.headline)
            }
            .foregroundStyle(isOn ? Palette.accent : Palette.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isOn ? Palette.accent.opacity(0.12) : Palette.surfaceElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.textPrimary.opacity(isHovering ? 0.06 : 0))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(isOn ? Palette.accent : Palette.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .disabled(isBusy)
        .opacity(isEnabled ? 1 : 0.45)
        .help(title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - 简介

/// 可展开的简介。
///
/// 默认 4 行，超出显示「展开 / 收起」。
///
/// - Note: 是否「超出」用字符数估算（≈200 字 ≈ 4 行 @17pt / 900pt 宽）。
///   精确判断需要拿到文本的排版高度，在 SwiftUI 里要额外测量一次布局；
///   详情页的简介来自 Emby，长度分布很稳定，估算足够用。
struct DetailOverview: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    /// 超过这个长度才需要「展开」。
    private static let expandThreshold = 200

    private var isLong: Bool {
        text.count > Self.expandThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(verbatim: text)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(isExpanded || !isLong ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isLong {
                Button(isExpanded ? "收起" : "展开") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.standard)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.link)
                .accessibilityLabel(Text(isExpanded ? "收起简介" : "展开简介"))
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

// MARK: - 分区

/// 详情页的分区容器：标题 + 内容，统一分区间距。
struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title)
                .font(.system(.title3, design: .default, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

// MARK: - 相似推荐

/// 横向滚动的相似推荐海报。
struct DetailSimilarRow: View {
    let items: [MediaItem]
    let imageURL: (MediaItem) -> URL?
    let onPlay: (MediaItem) -> Void
    let onSelect: (MediaItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(items) { item in
                    PosterCard(
                        title: item.name,
                        subtitle: item.subtitle,
                        imageURL: imageURL(item),
                        progress: item.isResumable ? item.progress : nil,
                        isPlayed: item.userData.played,
                        onPlay: { onPlay(item) },
                        onSelect: { onSelect(item) }
                    )
                    .frame(width: 150)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

// MARK: - 动作错误提示

/// 已看 / 收藏提交失败时的一行提示。
///
/// 详情内容仍然可用（乐观更新已回滚），所以**不把整页变成错误态**，
/// 只在按钮行下方提示一句，让用户知道刚才那一下没生效。
struct DetailActionErrorBanner: View {
    let error: EmbyError
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(error.userMessage)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)

            Spacer(minLength: Spacing.sm)

            Button("关闭", action: onDismiss)
                .buttonStyle(.link)
                .font(Typography.caption)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surfaceElevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 预览

private struct MovieDetailPreviewBoard: View {
    let model: DetailViewModel
    var actions: DetailActions = DetailActions()

    var body: some View {
        MovieDetailView(model: model, actions: actions)
            .environment(\.posterImageLoader, DetailPreviewImageLoader())
            .frame(width: 900, height: 900)
    }
}

#Preview("电影详情 · 已加载") {
    MovieDetailPreviewBoard(model: DetailViewModel(previewState: .loaded(DetailPreviewData.movieContent)))
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("电影详情 · 加载中") {
    MovieDetailPreviewBoard(model: DetailViewModel(previewState: .loading))
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("电影详情 · 错误") {
    MovieDetailPreviewBoard(
        model: DetailViewModel(previewState: .failed(.serverUnreachable("预览：连接被拒绝")))
    )
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("电影详情 · 浅色") {
    MovieDetailPreviewBoard(model: DetailViewModel(previewState: .loaded(DetailPreviewData.movieContent)))
        .prismTheme(PrismTheme(appearance: .light))
}

#Preview("电影详情 · 加载 → 已加载（真实数据源）") {
    MovieDetailPreviewBoard(
        model: DetailViewModel(
            dataSource: PreviewDetailDataSource(delay: .milliseconds(600)),
            itemId: DetailPreviewData.movie.id
        )
    )
    .prismTheme(PrismTheme(appearance: .dark))
}
