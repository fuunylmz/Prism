import PrismCore
import SwiftUI

// MARK: - 搜索页

/// 搜索页的**结果区域**（工具栏搜索框由 `AppShellView` 提供，本视图不重复实现）。
///
/// ## 与 `NavigationModel` 的联动
///
/// 搜索框的文本与焦点在 `NavigationModel` 上（`searchText` / `searchFocusRequest`，
/// 由 `AppShellView` 的 `.searchable` 驱动）。本视图按以下优先级拿模型：
///
/// 1. 构造注入的 `navigation:`（预览、单元级使用、或宿主想显式绑定）；
/// 2. `@FocusedValue(\.navigationModel)`——`RootShell` 已把模型挂到场景上，
///    因此正常运行时**零接线**即可拿到；
/// 3. 两者都没有：视图仍可用，只是不跟随搜索框、也不导航。
///
/// 拿到模型后，`navigation.searchText` 的变化会同步进 ``SearchViewModel/query``
/// （`didSet` 触发 300ms 防抖）；点击最近搜索则反向把关键词写回 `searchText`，
/// 保证工具栏输入框与结果区永远一致。
///
/// ## 状态
///
/// | 状态 | 画面 |
/// |---|---|
/// | 关键词为空 | 最近搜索 + 热门推荐 |
/// | 关键词过短 | 「至少输入 N 个字符」 |
/// | 加载中 | 骨架屏（海报网格 + 列表行） |
/// | 有结果 | 电影 / 剧集（海报网格）、单集（紧凑行）、人物（圆形头像行） |
/// | 无结果 | 「没有找到「xxx」」+ 建议 + 清除搜索 |
/// | 失败 | 错误说明 + 重试 |
///
/// ## 键盘
///
/// 结果区是一个可聚焦容器（Tab 进入）：`↑↓` 跨分组移动选中项、`↵` 打开、`⌘↵` 播放。
/// 选中项用强调色描边 / 底色标出。`Esc` 的「清空输入 → 退出搜索」由 `AppShell` 的
/// `onExitCommand` 负责，本视图不重复接管。
///
/// ```swift
/// // 宿主（AppShell）只需要持有一个 ViewModel：
/// @State private var searchModel = SearchViewModel(dataSource: EmbySearchDataSource(...))
/// // ...
/// SearchView(viewModel: searchModel)
/// ```
public struct SearchView: View {
    // MARK: 依赖

    /// 视图模型。
    ///
    /// 与 `LibraryView` 同理：`@State` 保证父视图重算时不会丢掉已加载的搜索结果。
    @State private var viewModel: SearchViewModel

    private let navigation: NavigationModel?
    private let onOpen: ((SearchResultItem) -> Void)?
    private let onPlay: ((SearchResultItem) -> Void)?
    private let popularTerms: [String]

    // MARK: 环境与状态

    @FocusedValue(\.navigationModel) private var focusedNavigation
    @FocusState private var isResultsFocused: Bool
    @State private var selectedResultID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: 初始化

    /// 创建搜索页。
    ///
    /// - Parameters:
    ///   - viewModel: 搜索视图模型（由宿主持有，保证状态不随视图重建丢失）。
    ///   - navigation: 导航模型；`nil` 时回落到 `@FocusedValue`。
    ///   - popularTerms: 热门推荐关键词（v1.0 可留空，留空时显示占位说明）。
    ///   - onOpen: 「打开条目」的覆盖实现；`nil` 时默认导航到 `.detail(itemId:)`。
    ///   - onPlay: 「播放条目」的覆盖实现；`nil` 时默认打开播放器。
    public init(
        viewModel: SearchViewModel,
        navigation: NavigationModel? = nil,
        popularTerms: [String] = [],
        onOpen: ((SearchResultItem) -> Void)? = nil,
        onPlay: ((SearchResultItem) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.navigation = navigation
        self.popularTerms = popularTerms
        self.onOpen = onOpen
        self.onPlay = onPlay
    }

    // MARK: 主体

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    content
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.surface)
            .onChange(of: selectedResultID) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.quick)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .task {
            syncQueryFromNavigation()
        }
        .onChange(of: resolvedNavigation?.searchText) { _, _ in
            syncQueryFromNavigation()
        }
        .onChange(of: viewModel.state) { _, _ in
            // 结果换了一批，旧的选中项已经不存在，回到「未选中」。
            selectedResultID = nil
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.isQueryTooShort {
            tooShortHint
        } else {
            switch viewModel.state {
            case .idle:
                landing
            case .loading:
                loadingPlaceholder
            case let .loaded(results):
                resultsView(results)
            case .empty:
                noResults
            case let .failed(error):
                failure(error)
            }
        }
    }

    // MARK: 初始态

    private var landing: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if viewModel.recentSearches.isEmpty {
                landingHint
            } else {
                RecentSearchesView(
                    terms: viewModel.recentSearches,
                    onSelect: { applyRecent($0) },
                    onDelete: { viewModel.removeRecent($0) },
                    onClearAll: { viewModel.clearRecent() }
                )
            }

            popularSection
        }
    }

    private var landingHint: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                Text("搜索电影、剧集、演员")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
            }

            Text("在工具栏搜索框输入关键词，或按 ⌘F 聚焦搜索框。")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var popularSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("热门推荐", systemImage: "flame", count: nil)

            if popularTerms.isEmpty {
                Text("热门推荐将在接入服务端统计后显示。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                SearchFlowLayout(horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
                    ForEach(popularTerms, id: \.self) { term in
                        popularChip(term)
                    }
                }
            }
        }
    }

    private func popularChip(_ term: String) -> some View {
        Button {
            applyRecent(term)
        } label: {
            Text(verbatim: term)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.surfaceElevated))
                .overlay {
                    Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "搜索「\(term)」"))
    }

    // MARK: 过短提示

    private var tooShortHint: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text("至少输入 \(viewModel.minimumQueryLength) 个字符")
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)

            Text("再输入一些关键词，就能开始搜索。")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    // MARK: 加载态

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)

                Text("正在搜索「\(viewModel.trimmedQuery)」…")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            LoadingStateView(style: .posterGrid(count: 6))
            LoadingStateView(style: .list(rows: 4))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("正在搜索"))
    }

    // MARK: 结果

    private func resultsView(_ results: SearchResults) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            summary(results)

            if !results.movies.isEmpty {
                posterSection("电影", systemImage: SearchResultItem.Kind.movie.systemImage, items: results.movies)
            }
            if !results.series.isEmpty {
                posterSection("剧集", systemImage: SearchResultItem.Kind.series.systemImage, items: results.series)
            }
            if !results.episodes.isEmpty {
                episodeSection(results.episodes)
            }
            if !results.people.isEmpty {
                peopleSection(results.people)
            }

            keyboardHint
        }
        .focusable()
        .focused($isResultsFocused)
        .focusEffectDisabled()
        // 搜索框里按 ↓ 时，外壳自增 `resultsFocusRequest`；这里接住并把焦点交给结果区。
        .onChange(of: resolvedNavigation?.resultsFocusRequest ?? 0) { _, _ in
            guard !viewModel.flatResults.isEmpty else { return }
            if selectedResultID == nil {
                selectedResultID = viewModel.flatResults.first?.id
            }
            isResultsFocused = true
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            moveSelection(by: press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                playSelected()
            } else {
                openSelected()
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("搜索结果"))
    }

    private func summary(_ results: SearchResults) -> some View {
        HStack(spacing: Spacing.sm) {
            Text("「\(viewModel.trimmedQuery)」共 \(results.totalCountText) 个结果")
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Spacing.sm)

            if viewModel.state.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: 海报分组

    private func posterSection(_ title: String, systemImage: String, items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader(title, systemImage: systemImage, count: items.count)

            LazyVGrid(columns: posterColumns, alignment: .leading, spacing: Spacing.xl) {
                ForEach(items) { item in
                    let result = viewModel.resultItem(for: item)
                    SearchPosterCell(
                        item: result,
                        isSelected: selectedResultID == item.id,
                        onOpen: { open(result) },
                        onPlay: { play(result) }
                    )
                    .id(item.id)
                }
            }
        }
    }

    private var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: Spacing.lg)]
    }

    // MARK: 单集分组

    private func episodeSection(_ episodes: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("单集", systemImage: SearchResultItem.Kind.episode.systemImage, count: episodes.count)

            VStack(spacing: Spacing.xs) {
                ForEach(episodes) { episode in
                    let result = viewModel.resultItem(for: episode)
                    SearchResultRow(
                        item: result,
                        query: viewModel.trimmedQuery,
                        isSelected: selectedResultID == episode.id,
                        onActivate: { open(result) }
                    )
                    .id(episode.id)
                }
            }
        }
    }

    // MARK: 人物分组

    private func peopleSection(_ people: [Person]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("人物", systemImage: SearchResultItem.Kind.person.systemImage, count: people.count)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(people) { person in
                        let result = viewModel.resultItem(for: person)
                        SearchPersonCell(
                            item: result,
                            query: viewModel.trimmedQuery,
                            isSelected: selectedResultID == person.id,
                            onActivate: { open(result) }
                        )
                        .id(person.id)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    // MARK: 无结果

    private var noResults: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text("没有找到「\(viewModel.trimmedQuery)」")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                suggestion("检查拼写，或换一个更短的关键词")
                suggestion("试试搜索演员名，例如「汤姆·汉克斯」")
                suggestion("确认该内容已经在 Emby 媒体库中")
            }
            .padding(.top, Spacing.xs)

            PrismSecondaryButton("清除搜索", systemImage: "xmark.circle") {
                resetSearch()
            }
            .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
        .accessibilityElement(children: .contain)
    }

    private func suggestion(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(verbatim: "·")
                .foregroundStyle(Palette.textSecondary)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 错误态

    private func failure(_ error: EmbyError) -> some View {
        ErrorStateView(
            error: error,
            title: "搜索失败",
            onRetry: { Task { await viewModel.retry() } }
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: 键盘提示

    private var keyboardHint: some View {
        HStack(spacing: Spacing.md) {
            hintItem("↑ ↓", "选择")
            hintItem("↵", "打开")
            hintItem("⌘↵", "播放")

            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("键盘：上下键选择，回车打开，Command 加回车播放"))
    }

    private func hintItem(_ key: String, _ action: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(verbatim: key)
                .font(Typography.monoTime)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Palette.surfaceElevated))
                .overlay {
                    Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                }
            Text(verbatim: action)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: 分组标题

    private func sectionHeader(_ title: String, systemImage: String, count: Int?) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text(verbatim: title)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)

            if let count {
                Text(verbatim: "\(count)")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.surfaceElevated))
                    .overlay {
                        Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                    }
                    .accessibilityLabel(Text(verbatim: "\(count) 项"))
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: 导航联动

    /// 生效的导航模型：构造注入优先，其次场景焦点值。
    private var resolvedNavigation: NavigationModel? {
        navigation ?? focusedNavigation
    }

    /// 把工具栏搜索框的文本同步进视图模型。
    private func syncQueryFromNavigation() {
        guard let text = resolvedNavigation?.searchText else { return }
        guard viewModel.query != text else { return }
        viewModel.query = text
    }

    /// 点击最近搜索 / 热门推荐：同步工具栏并立即搜索（跳过防抖）。
    private func applyRecent(_ term: String) {
        selectedResultID = nil
        viewModel.setQueryWithoutSearch(term)
        resolvedNavigation?.searchText = term
        Task { await viewModel.search(term) }
    }

    /// 清空搜索，回到初始态。
    private func resetSearch() {
        selectedResultID = nil
        resolvedNavigation?.searchText = ""
        Task { await viewModel.search("") }
    }

    // MARK: 动作

    /// 打开一条结果。
    ///
    /// 默认行为：非人物结果导航到 `.detail(itemId:)`。
    ///
    /// - Important: 搜索路由（`Route.search`）按 `Route.showsDetailColumn` 的约定
    ///   **没有详情栏**，`NavigationModel.navigate(to: .detail(...))` 在该路由下会被忽略。
    ///   宿主应在接入时二选一：让搜索路由显示详情栏，或传入自己的 `onOpen`。
    ///
    /// - Parameter item: 结果条目。
    private func open(_ item: SearchResultItem) {
        selectedResultID = item.id
        if let onOpen {
            onOpen(item)
            return
        }
        guard let resolvedNavigation, item.kind != .person else { return }
        resolvedNavigation.navigate(to: .detail(itemId: item.id))
    }

    /// 播放一条结果（`⌘↵` 或海报上的播放按钮）。
    ///
    /// - Parameter item: 结果条目。
    private func play(_ item: SearchResultItem) {
        selectedResultID = item.id
        if let onPlay {
            onPlay(item)
            return
        }
        guard let resolvedNavigation, item.isPlayable else { return }
        resolvedNavigation.presentPlayer(itemId: item.id, resumeAt: item.resumePosition)
    }

    /// 键盘 ↑↓：跨分组移动选中项。
    ///
    /// - Parameter offset: `-1` 上移，`1` 下移。
    private func moveSelection(by offset: Int) {
        let items = viewModel.flatResults
        guard !items.isEmpty else { return }

        guard let current = selectedResultID,
              let index = items.firstIndex(where: { $0.id == current }) else {
            selectedResultID = offset > 0 ? items.first?.id : items.last?.id
            return
        }

        let next = min(max(index + offset, 0), items.count - 1)
        selectedResultID = items[next].id
    }

    /// 键盘 ↵：打开选中项；没有选中项时打开第一条。
    private func openSelected() {
        if let item = selectedResult {
            open(item)
        } else if let first = viewModel.flatResults.first {
            open(first)
        }
    }

    /// 键盘 ⌘↵：播放选中项。
    private func playSelected() {
        if let item = selectedResult {
            play(item)
        } else if let first = viewModel.flatResults.first {
            play(first)
        }
    }

    private var selectedResult: SearchResultItem? {
        guard let selectedResultID else { return nil }
        return viewModel.flatResults.first { $0.id == selectedResultID }
    }
}

// MARK: - 海报单元

/// 结果网格里的一个海报单元。
///
/// 复用设计系统的 ``PosterCard``（2:3 比例、hover 播放、进度条、已看角标全部沿用），
/// 只把「键盘选中态」映射到 `PosterCard.isSelected`（强调色描边）。
private struct SearchPosterCell: View {
    let item: SearchResultItem
    let isSelected: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        PosterCard(
            title: item.title,
            subtitle: item.subtitle,
            imageURL: item.imageURL,
            isSelected: isSelected,
            progress: item.isResumable ? item.mediaItem?.progress : nil,
            isPlayed: item.mediaItem?.userData.played ?? false,
            unplayedCount: item.mediaItem?.userData.unplayedItemCount,
            onPlay: item.isPlayable ? onPlay : nil,
            onSelect: onOpen
        )
    }
}

// MARK: - 人物单元

/// 人物结果：圆形头像 + 姓名（关键词高亮）。
private struct SearchPersonCell: View {
    let item: SearchResultItem
    let query: String
    let isSelected: Bool
    let onActivate: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onActivate) {
            VStack(spacing: Spacing.sm) {
                AsyncPosterImage(
                    url: item.imageURL,
                    targetSize: CGSize(width: 160, height: 160),
                    placeholderText: item.title
                )
                .frame(width: 68, height: 68)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? Palette.accent : Palette.separator,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .scaleEffect(isHovering && !reduceMotion ? 1.04 : 1)
                .shadow(color: .black.opacity(isHovering ? 0.25 : 0), radius: 8, y: 3)

                HighlightedText(item.title, query: query)
                    .font(Typography.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 92)
            }
            .frame(width: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .help(Text(verbatim: item.accessibilityDescription))
        .accessibilityLabel(Text(verbatim: item.accessibilityDescription))
    }
}

// MARK: - 预览

/// 预览宿主：用 `@State` 持有视图模型，避免每次 body 求值都重建。
private struct SearchViewPreviewHost: View {
    @State private var viewModel: SearchViewModel

    init(
        state: LoadState<SearchResults>,
        query: String,
        recentSearches: [String] = []
    ) {
        _viewModel = State(
            initialValue: SearchViewModel(
                previewState: state,
                query: query,
                recentSearches: recentSearches,
                imageProvider: SearchPreviewImageProvider()
            )
        )
    }

    var body: some View {
        SearchView(viewModel: viewModel, popularTerms: ["沙丘", "人生切割术"])
            .prismTheme(PrismTheme(appearance: .dark))
            .environment(\.posterImageLoader, PreviewImageLoader())
            .frame(width: 860, height: 720)
    }
}

#Preview("搜索 · 初始态（最近搜索）") {
    SearchViewPreviewHost(
        state: .idle,
        query: "",
        recentSearches: ["银翼杀手", "人生切割术", "沙丘"]
    )
}

#Preview("搜索 · 加载中") {
    SearchViewPreviewHost(state: .loading, query: "银翼")
}

#Preview("搜索 · 有结果") {
    SearchViewPreviewHost(state: .loaded(SearchPreviewData.results), query: "切")
}

#Preview("搜索 · 无结果") {
    SearchViewPreviewHost(state: .empty, query: "不存在的片名")
}

#Preview("搜索 · 错误") {
    SearchViewPreviewHost(state: .failed(.timeout), query: "银翼")
}

#Preview("搜索 · 输入过短") {
    SearchViewPreviewHost(state: .idle, query: "银")
}
