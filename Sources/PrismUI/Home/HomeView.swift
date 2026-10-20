import PrismCore
import SwiftUI

// MARK: - 首页

/// 首页（S04）：打开就能点播放，不需要先做选择。
///
/// 结构按 `docs/research/ux-benchmark.md` §S04 的**固定四段式**：
/// 1. 继续观看（横版剧照 + 进度条 + 剩余时间）；
/// 2. 接下来（剧集的下一集，`第 X 季 第 Y 集`）；
/// 3. 最新添加（2:3 海报横滑）；
/// 4. 媒体库（网格入口，点击进入 ``PrismUI/Route/library(id:type:)``）。
///
/// 分区之间 `Spacing.xl`，整页纵向滚动；空分区**整段隐藏**，
/// 四段全空时由视图模型给出 `.empty`。
///
/// 图片地址由 ``HomeImageResolver`` 统一解析：``HomeView`` 把导航模型里的服务器地址
/// 拼成解析器注入环境，卡片只负责显示。这样预览 / 演示模式只要注入
/// ``HomeImageResolver/disabled`` 就自动全部走占位图。
///
/// ```swift
/// let model = HomeViewModel(dataSource: EmbyHomeDataSource(client: client, userId: uid))
/// HomeView(
///     model: model,
///     imageResolver: HomeImageResolver(baseURL: client.baseURL, accessToken: token)
/// ) { route in
///     navigation.navigate(to: route)
/// }
/// ```
public struct HomeView: View {
    /// 视图模型。
    @State private var model: HomeViewModel

    /// 图片地址解析器。
    private let imageResolver: HomeImageResolver

    /// 导航回调（由外壳注入）。
    private let onNavigate: (Route) -> Void

    /// 内容区宽度，用于按 UX §5.3 在 24 / 32 之间切换左右边距。
    @State private var contentWidth: CGFloat = 0

    /// 当前展开的「更多」分区（`nil` 表示不显示）。
    @State private var expandedSection: HomeSection?

    /// 是否开启「减弱动态效果」。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建首页。
    ///
    /// - Parameters:
    ///   - model: 首页视图模型（数据源在构造时注入）。
    ///   - imageResolver: 图片地址解析器；默认 ``HomeImageResolver/disabled``（全部占位图）。
    ///   - onNavigate: 导航回调，首页只上报 ``PrismUI/Route``，不直接持有导航模型。
    public init(
        model: HomeViewModel,
        imageResolver: HomeImageResolver = .disabled,
        onNavigate: @escaping (Route) -> Void
    ) {
        _model = State(initialValue: model)
        self.imageResolver = imageResolver
        self.onNavigate = onNavigate
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                stateContent
            }
            .padding(.horizontal, HomeMetrics.horizontalPadding(for: contentWidth))
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
        // 顶部安全区由 ScrollView 的 content inset 承担：内容从工具栏下方开始滚动，
        // 但滚到顶时不会钻到工具栏底下。
        .contentMargins(.top, Spacing.sm, for: .scrollContent)
        .scrollIndicators(.automatic)
        .homeImageResolver(imageResolver)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
        }
        .task {
            await model.load()
        }
        // ⌘R 刷新（UX §S04「刷新：⌘R」）。工具栏按钮是 macOS 上唯一「看得见」的
        // 刷新入口；快捷键挂在按钮上，窗口激活时即生效。
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                refreshControl
            }
        }
    }

    /// 工具栏刷新控件：刷新中显示小菊花，否则显示按钮（⌘R）。
    @ViewBuilder
    private var refreshControl: some View {
        if model.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .help("正在刷新首页")
                .accessibilityLabel(Text("正在刷新首页"))
        } else {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("刷新（⌘R）")
            .accessibilityLabel(Text("刷新首页"))
            .disabled(model.state.isLoading)
        }
    }

    // MARK: 状态

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle, .loading:
            HomePlaceholder()

        case let .loaded(content):
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if model.hasPartialFailure {
                    PartialFailureBanner(message: model.partialFailureMessage) {
                        Task { await model.refresh() }
                    }
                }

                sections(content)
            }

        case .empty:
            EmptyStateView(
                systemImage: "rectangle.on.rectangle.slash",
                title: "这里还什么都没有",
                message: "服务器上还没有媒体，或还没有观看记录。在 Emby 中添加媒体库后刷新即可。",
                actionTitle: "刷新",
                actionSystemImage: "arrow.clockwise"
            ) {
                Task { await model.refresh() }
            }
            .frame(minHeight: 360)

        case let .failed(error):
            ErrorStateView(error: error) {
                Task { await model.refresh() }
            }
            .frame(minHeight: 360)
        }
    }

    // MARK: 四段式

    /// 四个分区。空分区整段隐藏（`if` 而不是空 `ForEach`）。
    ///
    /// 「查看全部」的展开网格**紧跟在自己的分区下方**（而不是统一堆到页尾），
    /// 这样用户点完标题栏按钮，内容就在视线附近出现，不需要再往下找。
    ///
    /// - Parameter content: 已加载内容。
    @ViewBuilder
    private func sections(_ content: HomeContent) -> some View {
        if !content.resume.isEmpty {
            continueWatchingSection(content.resume)
            expandedList(for: .resume, in: content)
        }

        if !content.nextUp.isEmpty {
            MediaRail(
                title: HomeSection.nextUp.title,
                items: content.nextUp,
                onSelect: { openDetail($0) },
                onSeeAll: { toggleExpanded(.nextUp) },
                style: .episode,
                onPlay: { play($0) }
            )
            expandedList(for: .nextUp, in: content)
        }

        if !content.latest.isEmpty {
            MediaRail(
                title: HomeSection.latest.title,
                items: content.latest,
                onSelect: { openDetail($0) },
                onSeeAll: { toggleExpanded(.latest) },
                style: .poster,
                onPlay: { play($0) }
            )
            expandedList(for: .latest, in: content)
        }

        if !content.libraries.isEmpty {
            LibraryGrid(items: content.libraries) { library in
                onNavigate(.library(id: library.id, type: Self.libraryRouteType(for: library)))
            }
        }
    }

    /// 某分区被「查看全部」展开时的完整网格。
    ///
    /// - Parameters:
    ///   - section: 分区。
    ///   - content: 已加载内容。
    @ViewBuilder
    private func expandedList(for section: HomeSection, in content: HomeContent) -> some View {
        if expandedSection == section {
            ExpandedSectionList(
                title: section.title,
                items: content.items(in: section),
                onSelect: { openDetail($0) },
                onClose: { toggleExpanded(section) }
            )
            .transition(.opacity)
        }
    }

    /// 展开 / 收起某个分区（尊重「减弱动态效果」）。
    ///
    /// - Parameter section: 分区。
    private func toggleExpanded(_ section: HomeSection) {
        let update = { expandedSection = expandedSection == section ? nil : section }
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: Motion.standard), update)
        }
    }

    /// 「继续观看」分区：与 ``MediaRail`` 共用标题栏与滚动容器，卡片换成横版卡。
    ///
    /// - Parameter items: 继续观看条目。
    private func continueWatchingSection(_ items: [MediaItem]) -> some View {
        RailScaffold(
            title: HomeSection.resume.title,
            onSeeAll: { expandedSection = .resume }
        ) {
            LazyHStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(items) { item in
                    ContinueWatchingCard(
                        item: item,
                        onPlay: { play(item) },
                        onSelect: { openDetail(item) }
                    )
                }
            }
        }
    }

    // MARK: 动作

    /// 打开详情。
    ///
    /// 首页只上报 ``PrismUI/Route/detail(itemId:)``，不直接持有 ``PrismUI/NavigationModel``
    /// （可测试、可预览）。**集成注意**：外壳当前对首页路由的
    /// `showsDetailColumn` 为 `false`，`NavigationModel.navigate(to: .detail)` 会直接
    /// 返回；外壳接入首页时需要在 `ContentColumnView` 里把首页的单击处理成
    /// 「切到对应媒体库路由 + `pushDetail`」或让首页也显示详情栏。
    ///
    /// - Parameter item: 被点击的条目。
    private func openDetail(_ item: MediaItem) {
        onNavigate(.detail(itemId: item.id))
    }

    /// 直接播放：从上次进度继续（没有进度则从头）。
    ///
    /// - Parameter item: 要播放的条目。
    private func play(_ item: MediaItem) {
        let resumeAt = item.userData.playbackPosition
        onNavigate(
            .player(
                itemId: item.id,
                mediaSourceId: item.mediaSources.first?.id,
                resumeAt: resumeAt.rawValue > 0 ? resumeAt : .zero
            )
        )
    }

    /// 由媒体库入口条目推断 ``PrismCore/ItemType``。
    ///
    /// `/Views` 返回的 `MediaItem` 不携带 `CollectionType`（它在 `MediaView` 上），
    /// 而 ``PrismUI/Route/library(id:type:)`` 需要 `ItemType`。这里按库名做保守推断：
    /// 命中「剧集 / TV / Series / Shows」走 `.series`，其余一律 `.movie`——
    /// 类型只影响库页的标题与网格形态，猜错不会导致功能错误。
    ///
    /// - Parameter library: 媒体库条目。
    /// - Returns: 推断出的条目类型。
    static func libraryRouteType(for library: MediaItem) -> ItemType {
        let name = library.name.lowercased()
        let seriesKeywords = ["剧", "tv", "series", "show", "anime", "动画"]
        if seriesKeywords.contains(where: { name.contains($0) }) {
            return .series
        }
        return .movie
    }
}

// MARK: - 部分失败提示条

/// 顶部内联错误条：不遮挡已有内容，只说明「哪个分区没拉到」。
///
/// 对应 UX §S04「错误：拉取失败 → 顶部内联错误条」。
private struct PartialFailureBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(verbatim: message)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: Spacing.sm)

            Button("重试", action: onRetry)
                .font(Typography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
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
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 「查看全部」展开列表

/// 「查看全部」的就地展开列表。
///
/// v1.0 不做独立的「更多」页（属于媒体库工单的范围），先在同页展开成网格：
/// 满足「点了能看到全部」的诉求，且不产生跨模块路由。
private struct ExpandedSectionList: View {
    let title: String
    let items: [MediaItem]
    let onSelect: (MediaItem) -> Void
    let onClose: () -> Void

    @Environment(\.homeImageResolver) private var resolver

    private let columns = [
        GridItem(
            .adaptive(minimum: HomeMetrics.posterWidth, maximum: HomeMetrics.libraryMaxWidth),
            spacing: Spacing.lg,
            alignment: .top
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(verbatim: title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("全部 \(items.count) 项")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                Spacer(minLength: Spacing.md)

                Button(action: onClose) {
                    HStack(spacing: 2) {
                        Text("收起")
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("收起"))
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.lg) {
                ForEach(items) { item in
                    PosterCard(
                        title: item.name,
                        subtitle: item.subtitle,
                        imageURL: resolver.posterURL(for: item),
                        badges: MediaRail.badges(for: item),
                        progress: item.isResumable ? item.progress : nil,
                        isPlayed: item.userData.played,
                        unplayedCount: item.userData.unplayedItemCount,
                        onSelect: { onSelect(item) }
                    )
                }
            }
        }
        .padding(.top, Spacing.sm)
    }
}

// MARK: - 预览

/// 用真实视图模型驱动预览，覆盖四态 + 部分成功。
private struct HomePreviewBoard: View {
    let mode: PreviewHomeDataSource.Mode
    let width: CGFloat

    @State private var model: HomeViewModel

    init(mode: PreviewHomeDataSource.Mode, width: CGFloat = 980) {
        self.mode = mode
        self.width = width
        _model = State(initialValue: HomeViewModel(dataSource: PreviewHomeDataSource(mode: mode)))
    }

    var body: some View {
        HomeView(model: model, imageResolver: HomePreviewData.imageResolver) { _ in }
            .frame(width: width, height: 760)
            .posterImageLoader(PreviewImageLoader())
    }
}

#Preview("首页 · 有数据（深色）") {
    HomePreviewBoard(mode: .loaded)
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("首页 · 有数据（浅色）") {
    HomePreviewBoard(mode: .loaded)
        .prismTheme(PrismTheme(appearance: .light))
}

#Preview("首页 · 空态") {
    HomePreviewBoard(mode: .empty)
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("首页 · 加载中（骨架）") {
    HomePreviewBoard(mode: .loading)
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("首页 · 错误态（整页失败）") {
    HomePreviewBoard(mode: .failing)
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("首页 · 部分失败（内联错误条）") {
    HomeView(
        model: HomeViewModel(dataSource: PartialFailurePreviewDataSource()),
        imageResolver: HomePreviewData.imageResolver
    ) { _ in }
    .frame(width: 980, height: 760)
    .prismTheme(PrismTheme(appearance: .dark))
    .posterImageLoader(PreviewImageLoader())
}

/// 只让「接下来 / 媒体库」失败的数据源，用来演示部分成功。
private struct PartialFailurePreviewDataSource: HomeDataSource {
    func resume() async throws -> [MediaItem] { HomePreviewData.resumeItems }
    func latest(limit: Int) async throws -> [MediaItem] { HomePreviewData.latestItems }
    func nextUp() async throws -> [MediaItem] { throw EmbyError.timeout }
    func views() async throws -> [MediaItem] { throw EmbyError.serverUnreachable("预览数据：连接被拒绝") }
}
