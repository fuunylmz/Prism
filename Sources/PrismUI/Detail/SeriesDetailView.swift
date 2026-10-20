import PrismCore
import SwiftUI

// MARK: - 剧集详情

/// 剧集详情页。
///
/// 与 ``MovieDetailView`` 共享头图与操作行，差异在中间多出「季选择器 + 集列表」
/// （`docs/research/ux-benchmark.md` §S08）：
///
/// ```
/// Cinematic Header
/// 操作按钮行（▶ 继续观看 S2E5 / ✓ 已看 / ♡ 收藏 / ⋯ 更多）
/// 季选择器（横向 chips，当前季高亮，←→ 可切换）
/// 集列表（横向卡片：缩略图 + 集号 + 标题 + 简介 + 时长 + 进度 + 已看标记）
/// 简介 → 演职员 → 相似推荐
/// ```
///
/// **默认季**由 ``DetailViewModel`` 在加载时定位到「下一集未看」所在的季，
/// 并把该季的「接下来」那一集滚动到可见位置——进页面就能看到「我看到哪了」。
///
/// - Important: 视图用 `@State` 持有视图模型；切换到别的条目时请在调用处加
///   `.id(itemId)`，否则会继续显示上一个条目的内容。
public struct SeriesDetailView: View {
    @State private var model: DetailViewModel
    private let actions: DetailActions

    /// 创建剧集详情页。
    ///
    /// - Parameters:
    ///   - model: 视图模型（由调用方创建，内部 `@State` 持有）。
    ///   - actions: 播放 / 打开别的条目的回调，默认什么都不做。
    public init(model: DetailViewModel, actions: DetailActions = DetailActions()) {
        _model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some View {
        DetailSkeletonView(showsSeriesSections: true)
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

                    if !content.seasons.isEmpty || !content.episodes.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                                Text("剧集")
                                    .font(.system(.title3, design: .default, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                    .accessibilityAddTraits(.isHeader)

                                Text(verbatim: seasonSummary(content))
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)

                                Spacer(minLength: 0)
                            }

                            // 季列表拉取失败时不显示选择器（没有季可选），
                            // 但集列表照常展示，避免「假空态」。
                            if !content.seasons.isEmpty {
                                SeasonPicker(
                                    seasons: content.seasons,
                                    selectedSeasonId: model.selectedSeasonId,
                                    isBusy: model.isLoadingEpisodes
                                ) { season in
                                    Task { await model.selectSeason(season.id) }
                                }
                            }

                            episodeRail(content)
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

    // MARK: 集列表

    /// 横向集列表；「接下来」那一集默认滚到可见位置。
    ///
    /// ## 为什么用 `.task(id:)` 而不是 `.onAppear`
    ///
    /// 集列表是 `LazyHStack`：**首次出现时 item 还没布局**，此时 `scrollTo` 是空操作
    /// （SwiftUI 找不到目标 id 对应的 frame，直接返回）。实测在真窗口里 `.onAppear`
    /// 里滚动无效，列表仍停在第一集——而 UX 文档 §S08 明确要求
    /// 「当前/下一集默认滚动到可见位置」。
    ///
    /// 解法：`.task(id:)` 先 `await Task.yield()` 让出，等懒加载完成首帧布局再滚动。
    /// `id` 用「季 id + 集数 + 接下来那一集 id」组合，这样切换季、播放进度变化导致
    /// 「接下来」换了目标时都会重新定位。
    private func episodeRail(_ content: DetailContent) -> some View {
        Group {
            if content.episodes.isEmpty {
                EpisodeRailEmptyView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Spacing.lg) {
                            ForEach(content.episodes) { episode in
                                EpisodeRow(
                                    episode: episode,
                                    isNextUp: episode.id == content.nextUpEpisode?.id,
                                    thumbnailURL: model.thumbnailImageURL(for: episode)
                                ) {
                                    actions.play(
                                        DetailPlaybackRequest(
                                            itemId: episode.id,
                                            resumeAt: episode.userData.played
                                                ? .zero
                                                : episode.userData.playbackPosition
                                        )
                                    )
                                }
                                .id(episode.id)
                            }
                        }
                        .padding(.vertical, 2)
                        .scrollTargetLayout()
                    }
                    .scrollClipDisabled()
                    .task(id: EpisodeRailKey(seasonID: model.selectedSeasonId, content: content)) {
                        // 让 LazyHStack 先完成首帧布局，否则 scrollTo 找不到目标。
                        await Task.yield()
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        scrollToNextUp(content, proxy: proxy)
                    }
                }
            }
        }
    }

    /// 把「接下来」那一集滚到可见位置。
    ///
    /// 优先滚到 `nextUpEpisode`；整季看完时滚到第一集（用户通常想回看）。
    /// 用 `anchor: .center`：集列表通常比视口长，居中能同时露出前后几集。
    ///
    /// - Parameters:
    ///   - content: 当前内容。
    ///   - proxy: 滚动代理。
    private func scrollToNextUp(_ content: DetailContent, proxy: ScrollViewProxy) {
        let anchorID = content.nextUpEpisode?.id ?? content.episodes.first?.id
        guard let anchorID else { return }
        withAnimation(.easeInOut(duration: Motion.standard)) {
            proxy.scrollTo(anchorID, anchor: .center)
        }
    }

    /// 「第 2 季 · 共 7 集 · 已看 2 集」。
    ///
    /// - Parameter content: 当前内容。
    /// - Returns: 概要文案。
    private func seasonSummary(_ content: DetailContent) -> String {
        var parts: [String] = []
        if let season = content.seasons.first(where: { $0.id == model.selectedSeasonId }) {
            parts.append(season.name)
        }
        parts.append("共 \(content.episodes.count) 集")
        parts.append("已看 \(content.watchedEpisodeCount) 集")
        return parts.joined(separator: " · ")
    }
}

// MARK: - 集列表定位 key

/// 集列表「重新定位」的触发条件。
///
/// 只要这三者之一变了，就该把「接下来」那一集重新滚到可见位置：
/// 换季、集数变化（加载完 / 该季为空）、「接下来」换了一集（播放进度更新）。
/// 用值类型而不是拼字符串，避免集 id 里恰好含有分隔符时误判。
private struct EpisodeRailKey: Equatable, Sendable {
    /// 当前季 id。
    let seasonID: String?
    /// 当前季的集数。
    let episodeCount: Int
    /// 「接下来」那一集的 id。
    let nextUpID: String?

    /// 从内容构造。
    ///
    /// - Parameters:
    ///   - seasonID: 当前季 id。
    ///   - content: 详情内容。
    init(seasonID: String?, content: DetailContent) {
        self.seasonID = seasonID
        self.episodeCount = content.episodes.count
        self.nextUpID = content.nextUpEpisode?.id
    }
}

// MARK: - 空季

/// 该季没有剧集时的占位。
///
/// 用轻量的一行提示而不是整页空态：页面其余部分（简介、演职员）仍然有效，
/// 整页空态会让人以为「整个条目都没有内容」。
private struct EpisodeRailEmptyView: View {
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text("该季暂无剧集")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surfaceElevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
    }
}

// MARK: - 预览

private struct SeriesDetailPreviewBoard: View {
    let model: DetailViewModel

    var body: some View {
        SeriesDetailView(model: model)
            .environment(\.posterImageLoader, DetailPreviewImageLoader())
            .frame(width: 900, height: 1000)
    }
}

#Preview("剧集详情 · 已加载（默认停在第 2 季）") {
    SeriesDetailPreviewBoard(
        model: DetailViewModel(previewState: .loaded(DetailPreviewData.seriesContent))
    )
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("剧集详情 · 加载中") {
    SeriesDetailPreviewBoard(
        model: DetailViewModel(previewState: .loading)
    )
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("剧集详情 · 错误") {
    SeriesDetailPreviewBoard(
        model: DetailViewModel(previewState: .failed(.timeout))
    )
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("剧集详情 · 浅色") {
    SeriesDetailPreviewBoard(
        model: DetailViewModel(previewState: .loaded(DetailPreviewData.seriesContent))
    )
    .prismTheme(PrismTheme(appearance: .light))
}

#Preview("剧集详情 · 加载 → 已加载（真实数据源）") {
    SeriesDetailPreviewBoard(
        model: DetailViewModel(
            dataSource: PreviewDetailDataSource(delay: .milliseconds(600)),
            itemId: DetailPreviewData.series.id
        )
    )
    .prismTheme(PrismTheme(appearance: .dark))
}
