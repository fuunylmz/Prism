import EmbyAPI
import PrismCore
import SwiftUI

// MARK: - 媒体库页面

/// 媒体库页面：筛选排序栏 + 网格，并处理四态（加载骨架 / 有数据 / 空 / 错误）。
///
/// 组装顺序（`docs/research/ux-benchmark.md` §S05 / §S06）：
/// ```
/// ┌──────────────────────────────────────────┐
/// │ 电影  共 1,284 部      排序 ▾  筛选 ●2  ▦│  ← FilterBar，固定不滚
/// ├──────────────────────────────────────────┤
/// │  [海报] [海报] [海报] [海报]              │
/// │  [海报] [海报] [海报] [海报]              │  ← LibraryGridView / 骨架屏
/// │  ...            （滚到倒数第 10 条预取）  │
/// └──────────────────────────────────────────┘
/// ```
///
/// **状态映射**（``PrismCore/LoadState``）：
/// | 状态 | 画面 |
/// |---|---|
/// | `.idle` / `.loading` | ``LibrarySkeletonView``（与真实布局同尺寸，不跳动） |
/// | `.loaded` | ``LibraryGridView`` |
/// | `.empty` | 空态：无筛选时「这个媒体库还是空的」；有筛选/搜索时「没有符合条件的内容 + 清除筛选」 |
/// | `.failed` | ``ErrorStateView``（可恢复错误带「重试」） |
///
/// 刷新失败但已有内容时不清屏，只显示一条内联错误（``LibraryViewModel/inlineError``）。
///
/// ## 用法
///
/// ```swift
/// LibraryView(
///     viewModel: viewModel,
///     libraryName: view.name,
///     onOpenDetail: { navigation.navigate(to: .detail(itemId: $0.id)) },
///     onPlay: { navigation.presentPlayer(itemId: $0.id) }
/// )
/// ```
public struct LibraryView: View {
    /// 视图模型。
    ///
    /// 必须用 `@State` 持有：`AppShellView` 每次 body 求值都会构造新的
    /// `LibraryViewModel` 传进来，如果只做 `@Bindable` 引用，父视图一刷新
    /// （滚动触发、详情栏开关、窗口变化）就会换成一个全新的空 VM，
    /// 网格被打回骨架屏并重新请求第一页。
    @State private var viewModel: LibraryViewModel

    private let libraryName: String
    private let countUnit: String
    private let selectedItemID: String?
    private let onOpenDetail: (MediaItem) -> Void
    private let onPlay: (MediaItem) -> Void
    private let onShowInFinder: (MediaItem) -> Void

    /// 创建媒体库页面。
    ///
    /// - Parameters:
    ///   - viewModel: 视图模型（页面只读它的状态，所有变更都通过它的方法）。
    ///   - libraryName: 库名，显示在筛选栏左侧。
    ///   - countUnit: 量词，电影「部」、剧集「部」、音乐「张」等，默认「部」。
    ///   - selectedItemID: 当前在详情栏打开的条目 id（网格里高亮它）。
    ///   - onOpenDetail: 单击 / ↵ 打开详情。
    ///   - onPlay: 双击 / 空格 / 右键「播放」。
    ///   - onShowInFinder: 右键「在 Finder 中显示」（v1.1 才真正可用）。
    public init(
        viewModel: LibraryViewModel,
        libraryName: String,
        countUnit: String = "部",
        selectedItemID: String? = nil,
        onOpenDetail: @escaping (MediaItem) -> Void,
        onPlay: @escaping (MediaItem) -> Void,
        onShowInFinder: @escaping (MediaItem) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.libraryName = libraryName
        self.countUnit = countUnit
        self.selectedItemID = selectedItemID
        self.onOpenDetail = onOpenDetail
        self.onPlay = onPlay
        self.onShowInFinder = onShowInFinder
    }

    public var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                libraryName: libraryName,
                totalCount: viewModel.totalCount,
                countUnit: countUnit,
                sort: viewModel.sort,
                filters: viewModel.filters,
                layout: viewModel.layout,
                availableGenres: viewModel.availableGenres,
                onSortChange: { newSort in
                    Task { await viewModel.apply(sort: newSort) }
                },
                onFiltersChange: { newFilters in
                    // 滑块 / 多选是高频输入：走防抖路径，拖动一次只发一个请求。
                    viewModel.scheduleFilters(newFilters)
                },
                onLayoutChange: { newLayout in
                    viewModel.layout = newLayout
                }
            )

            Divider()

            if let error = viewModel.inlineError {
                inlineErrorBanner(error)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .task {
            // `.task` 在视图出现时跑一次、消失时自动取消；
            // `loadFirstPage` 内部有 `isLoading` 守卫，重复触发是安全的。
            //
            // 只有「已经有内容」时才跳过：`.failed` 也算 settled，若一并跳过，
            // 一次 5xx 之后用户切走再切回来仍然是那张错误页（页面内又没有刷新入口）。
            switch viewModel.state {
            case .loaded, .empty:
                break
            case .idle, .loading, .failed:
                await viewModel.loadFirstPage()
            }
        }
        // ⌘R 刷新：错误页与空态之外也要有手动出口。
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新媒体库（⌘R）")
                .disabled(viewModel.state.isLoading)
            }
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            LibrarySkeletonView(layout: viewModel.layout)

        case let .loaded(items):
            LibraryGridView(
                items: items,
                layout: viewModel.layout,
                isLoadingMore: viewModel.isLoadingMore,
                hasMore: viewModel.hasMoreItems,
                selectedItemID: selectedItemID,
                imageURL: { viewModel.posterURL(for: $0) },
                onSelect: onOpenDetail,
                onPlay: onPlay,
                onMarkPlayed: { item in
                    Task { await viewModel.setPlayed(true, for: item) }
                },
                onMarkUnplayed: { item in
                    Task { await viewModel.setPlayed(false, for: item) }
                },
                onToggleFavorite: { item in
                    Task { await viewModel.setFavorite(!item.userData.isFavorite, for: item) }
                },
                onShowInFinder: onShowInFinder,
                onItemAppear: { item in
                    Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                },
                onLoadMore: {
                    Task { await viewModel.loadNextPage() }
                }
            )

        case .empty:
            emptyState

        case let .failed(error):
            ErrorStateView(
                error: error,
                title: "加载媒体库失败",
                onRetry: {
                    Task { await viewModel.loadFirstPage() }
                }
            )
        }
    }

    // MARK: - 空态

    /// 空态分两种，文案不同（§S05）：
    /// - 库里真的没有内容 → 引导去服务器添加；
    /// - 筛选 / 搜索之后没有结果 → 给「清除筛选」这个明确的下一步。
    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isFilteredOrSearching {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "没有符合条件的内容",
                message: "试试放宽筛选条件，或清除全部筛选。",
                actionTitle: "清除筛选",
                actionSystemImage: "xmark.circle"
            ) {
                Task { await viewModel.clearFilters() }
            }
        } else {
            EmptyStateView(
                systemImage: "rectangle.on.rectangle.slash",
                title: "这个媒体库还是空的",
                message: "在 Emby 服务器中添加内容后，回到这里刷新即可。",
                actionTitle: "刷新",
                actionSystemImage: "arrow.clockwise"
            ) {
                Task { await viewModel.refresh() }
            }
        }
    }

    // MARK: - 内联错误

    /// 刷新 / 标记失败时的内联错误条：不遮挡已有内容，可手动关闭。
    private func inlineErrorBanner(_ error: EmbyError) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(error.userMessage)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Spacing.sm)

            Button("重试") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.plain)
            .font(Typography.caption)
            .foregroundStyle(Palette.accent)

            Button {
                viewModel.dismissInlineError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel(Text("关闭错误提示"))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator.opacity(0.5))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 预览

/// 预览板：加载四态 + 两种布局。
///
/// `#Preview` 不能跨进程共享状态，因此这里用 `LibraryPreview` 工厂现造 VM，
/// 并在 `.task` 里触发一次加载（``LibraryPreviewDataSource`` 是纯内存实现，不联网）。
@MainActor
private struct LibraryViewPreviewBoard: View {
    let size: CGSize

    @State private var viewModel: LibraryViewModel

    init(
        outcome: LibraryPreviewDataSource.Outcome,
        layout: GridLayout = .poster,
        filters: FilterSet = .none,
        size: CGSize = CGSize(width: 760, height: 620)
    ) {
        self.size = size
        _viewModel = State(
            initialValue: LibraryPreview.viewModel(outcome: outcome, layout: layout, filters: filters)
        )
    }

    var body: some View {
        LibraryView(
            viewModel: viewModel,
            libraryName: "电影",
            selectedItemID: viewModel.items.first?.id,
            onOpenDetail: { _ in },
            onPlay: { _ in }
        )
        .frame(width: size.width, height: size.height)
    }
}

#Preview("媒体库 · 有数据 · 网格 · 深色") {
    LibraryViewPreviewBoard(outcome: .items(LibraryPreviewData.items))
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 有数据 · 列表 · 浅色") {
    LibraryViewPreviewBoard(
        outcome: .items(LibraryPreviewData.items),
        layout: .list,
        size: CGSize(width: 620, height: 560)
    )
    .prismTheme(PrismTheme(appearance: .light))
    .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 空 · 深色") {
    LibraryViewPreviewBoard(
        outcome: .empty,
        size: CGSize(width: 620, height: 480)
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 空（筛选后） · 浅色") {
    LibraryViewPreviewBoard(
        outcome: .empty,
        filters: FilterSet(watchState: .unwatched, genres: ["科幻"]),
        size: CGSize(width: 620, height: 480)
    )
    .prismTheme(PrismTheme(appearance: .light))
    .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 加载中 · 网格 · 深色") {
    LibraryViewPreviewBoard(
        outcome: .pending,
        size: CGSize(width: 760, height: 560)
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 加载中 · 列表 · 浅色") {
    LibraryViewPreviewBoard(
        outcome: .pending,
        layout: .list,
        size: CGSize(width: 620, height: 520)
    )
    .prismTheme(PrismTheme(appearance: .light))
    .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 错误 · 深色") {
    LibraryViewPreviewBoard(
        outcome: .failure(.serverUnreachable("预览数据：连接被拒绝")),
        size: CGSize(width: 620, height: 480)
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("媒体库 · 错误 · 浅色") {
    LibraryViewPreviewBoard(
        outcome: .failure(.timeout),
        size: CGSize(width: 620, height: 480)
    )
    .prismTheme(PrismTheme(appearance: .light))
    .environment(\.posterImageLoader, PreviewImageLoader())
}
