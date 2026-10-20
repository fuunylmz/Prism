import Foundation
import PrismCore
import SwiftUI

// MARK: - 媒体库网格

/// 媒体库的海报网格 / 紧凑列表。
///
/// 布局（`docs/research/ux-benchmark.md` §S05）：
/// - **网格**：`LazyVGrid` 自适应列宽，最小 140pt，间距 ``Spacing/lg``，海报 2:3；
/// - **列表**：紧凑行（海报缩略图 + 标题 + 年份 + 时长 + 简介），适合快速浏览。
///
/// 交互：
/// - 单击选中（回调里通常打开详情栏）、双击播放（``PosterCard`` 内置）；
/// - hover 放大 + 浮出播放按钮 + 已看角标（``PosterCard`` 内置）；
/// - 右键上下文菜单：播放 / 标记已看 / 标记未看 / 收藏 / 查看详情 / 在 Finder 中显示；
/// - 键盘：↑↓←→ 移动焦点、↵ 打开详情、空格播放；
/// - 无限滚动：滚到倒数第 10 条时通过 ``onItemAppear`` 预取，底部另有
///   `ProgressView` + ``onLoadMore`` 兜底。
///
/// **键盘实现说明**：整块网格是**一个** Tab 停靠点（`.focusable()`），
/// 内部焦点由 ``focusedItemID`` 自己维护——这与 AppKit `NSCollectionView` 的
/// 语义一致（Tab 进出集合，方向键在集合内移动），也避免 60 个格子各占一个
/// Tab 位、键盘用户要按 60 次才能穿过去。焦点移动时用 `ScrollViewReader`
/// 把目标滚到可见区域。
public struct LibraryGridView: View {
    /// 海报最小宽度（pt）。
    public static let minimumPosterWidth: CGFloat = 140

    /// 海报最大宽度（pt），防止超宽窗口下海报被拉得过大。
    public static let maximumPosterWidth: CGFloat = 220

    /// 网格左右内边距。
    private static let contentPadding = Spacing.xl

    // MARK: 输入

    private let items: [MediaItem]
    private let layout: GridLayout
    private let isLoadingMore: Bool
    private let hasMore: Bool
    private let selectedItemID: String?
    private let imageURL: (MediaItem) -> URL?
    private let onSelect: (MediaItem) -> Void
    private let onPlay: (MediaItem) -> Void
    private let onMarkPlayed: (MediaItem) -> Void
    private let onMarkUnplayed: (MediaItem) -> Void
    private let onToggleFavorite: (MediaItem) -> Void
    private let onShowInFinder: (MediaItem) -> Void
    private let onItemAppear: (MediaItem) -> Void
    private let onLoadMore: () -> Void

    // MARK: 状态

    @FocusState private var isGridFocused: Bool
    @State private var focusedItemID: String?
    @State private var keyboardScrollTarget: String?
    @State private var containerWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建网格。
    ///
    /// - Parameters:
    ///   - items: 已加载的条目。
    ///   - layout: 网格 / 列表。
    ///   - isLoadingMore: 是否正在加载下一页（显示底部菊花）。
    ///   - hasMore: 是否还有下一页（决定底部提示文案）。
    ///   - selectedItemID: 当前选中条目 id（强调色描边）。
    ///   - imageURL: 条目 → 海报地址。
    ///   - onSelect: 单击 / ↵，通常是打开详情。
    ///   - onPlay: 双击 / 空格 / 上下文菜单「播放」。
    ///   - onMarkPlayed: 标记为已看。
    ///   - onMarkUnplayed: 标记为未看。
    ///   - onToggleFavorite: 收藏 / 取消收藏。
    ///   - onShowInFinder: 在 Finder 中显示（v1.1，当前入口禁用）。
    ///   - onItemAppear: 某条目滚入可视区域，用于 ``LibraryViewModel/loadMoreIfNeeded(currentItem:)``。
    ///   - onLoadMore: 底部加载占位出现时的兜底触发。
    public init(
        items: [MediaItem],
        layout: GridLayout,
        isLoadingMore: Bool,
        hasMore: Bool,
        selectedItemID: String?,
        imageURL: @escaping (MediaItem) -> URL?,
        onSelect: @escaping (MediaItem) -> Void,
        onPlay: @escaping (MediaItem) -> Void,
        onMarkPlayed: @escaping (MediaItem) -> Void,
        onMarkUnplayed: @escaping (MediaItem) -> Void,
        onToggleFavorite: @escaping (MediaItem) -> Void,
        onShowInFinder: @escaping (MediaItem) -> Void,
        onItemAppear: @escaping (MediaItem) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.items = items
        self.layout = layout
        self.isLoadingMore = isLoadingMore
        self.hasMore = hasMore
        self.selectedItemID = selectedItemID
        self.imageURL = imageURL
        self.onSelect = onSelect
        self.onPlay = onPlay
        self.onMarkPlayed = onMarkPlayed
        self.onMarkUnplayed = onMarkUnplayed
        self.onToggleFavorite = onToggleFavorite
        self.onShowInFinder = onShowInFinder
        self.onItemAppear = onItemAppear
        self.onLoadMore = onLoadMore
    }

    // MARK: - 视图

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle.slash",
                        title: "没有可显示的内容",
                        message: "换一个筛选条件，或刷新后重试。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    switch layout {
                    case .poster:
                        posterGrid
                    case .list:
                        listRows
                    }
                    footer
                }
            }
            .onChange(of: keyboardScrollTarget) { _, target in
                guard let target else { return }
                if reduceMotion {
                    proxy.scrollTo(target, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: Motion.quick)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                keyboardScrollTarget = nil
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onKeyPress(.upArrow) { moveFocus(.up) }
        .onKeyPress(.downArrow) { moveFocus(.down) }
        .onKeyPress(.leftArrow) { moveFocus(.left) }
        .onKeyPress(.rightArrow) { moveFocus(.right) }
        .onKeyPress(.return) { openFocusedItem() }
        .onKeyPress(.space) { playFocusedItem() }
        .onAppear {
            if focusedItemID == nil { focusedItemID = items.first?.id }
        }
        .onChange(of: items.count) { _, _ in
            // 首屏数据到达后补一个焦点，否则第一次按方向键会「无起点」。
            if focusedItemID == nil { focusedItemID = items.first?.id }
        }
    }

    // MARK: 网格

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.minimumPosterWidth, maximum: Self.maximumPosterWidth), spacing: Spacing.lg)]
    }

    private var posterGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.xl) {
            ForEach(items) { item in
                posterCell(item)
            }
        }
        .padding(Spacing.xl)
    }

    private func posterCell(_ item: MediaItem) -> some View {
        PosterCard(
            title: item.name,
            subtitle: item.subtitle,
            imageURL: imageURL(item),
            badges: badges(for: item),
            isSelected: selectedItemID == item.id,
            progress: item.isResumable ? item.progress : nil,
            isPlayed: item.userData.played,
            unplayedCount: item.userData.unplayedItemCount,
            onPlay: { onPlay(item) },
            onSelect: { select(item) }
        )
        .overlay {
            focusRing(isHighlighted: isFocused(item))
        }
        .contextMenu {
            contextMenu(for: item)
        }
        .onAppear {
            onItemAppear(item)
        }
        .id(item.id)
    }

    // MARK: 列表

    private var listRows: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(items) { item in
                LibraryListRow(
                    item: item,
                    imageURL: imageURL(item),
                    isSelected: selectedItemID == item.id,
                    isHighlighted: isFocused(item),
                    onSelect: { select(item) },
                    onPlay: { onPlay(item) }
                )
                .contextMenu {
                    contextMenu(for: item)
                }
                .onAppear {
                    onItemAppear(item)
                }
                .id(item.id)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: 底部

    @ViewBuilder
    private var footer: some View {
        if isLoadingMore || hasMore {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载更多…")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
            .onAppear {
                onLoadMore()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("正在加载更多"))
        } else {
            Text("已全部加载")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .accessibilityLabel(Text("已全部加载"))
        }
    }

    // MARK: 上下文菜单

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        Button("播放") { onPlay(item) }
        if item.isResumable {
            Button("从上次位置继续") { onPlay(item) }
        }

        Divider()

        Button("标记为已看") { onMarkPlayed(item) }
            .disabled(item.userData.played)
        Button("标记为未看") { onMarkUnplayed(item) }
            .disabled(!item.userData.played)
        Button(item.userData.isFavorite ? "取消收藏" : "收藏") { onToggleFavorite(item) }

        Divider()

        Button("查看详情") { onSelect(item) }
        Button("在 Finder 中显示") { onShowInFinder(item) }
            .disabled(true)
            .help("v1.1 提供（需要服务端返回文件路径）")
    }

    // MARK: 焦点与键盘

    /// 该条目是否处于键盘焦点。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 网格获得焦点且该条目是当前焦点时为 `true`。
    private func isFocused(_ item: MediaItem) -> Bool {
        isGridFocused && focusedItemID == item.id
    }

    private func select(_ item: MediaItem) {
        focusedItemID = item.id
        // 点击卡片时把键盘焦点交给网格，之后方向键就能直接接管。
        isGridFocused = true
        onSelect(item)
    }

    /// 焦点框：2pt 强调色描边，与 ``PosterCard`` 的选中态区分开
    /// （选中是「当前打开的条目」，焦点是「方向键落点」）。
    private func focusRing(isHighlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous)
            .strokeBorder(Palette.accent, lineWidth: 2)
            .padding(-4)
            .opacity(isHighlighted ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 焦点移动方向。
    private enum MoveDirection {
        case up, down, left, right
    }

    /// 网格当前的列数（用于 ↑↓ 的跨行移动）。
    ///
    /// 与 `LazyVGrid(.adaptive(minimum:))` 的列数算法一致：
    /// `floor((可用宽度 + 间距) / (最小列宽 + 间距))`。
    private var columnCount: Int {
        guard layout == .poster, containerWidth > 0 else { return 1 }
        let available = max(containerWidth - Self.contentPadding * 2, Self.minimumPosterWidth)
        let count = Int(((available + Spacing.lg) / (Self.minimumPosterWidth + Spacing.lg)).rounded(.down))
        return max(count, 1)
    }

    /// 按方向移动键盘焦点。
    ///
    /// - Parameter direction: 方向。
    /// - Returns: 事件处理结果；没有可移动的目标时返回 `.ignored`，
    ///   把按键交还给系统（例如让 ScrollView 自己滚动）。
    private func moveFocus(_ direction: MoveDirection) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }

        guard let currentID = focusedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID })
        else {
            focusedItemID = items.first?.id
            keyboardScrollTarget = items.first?.id
            return .handled
        }

        let step: Int
        switch direction {
        case .left:
            guard layout == .poster else { return .ignored }
            step = -1
        case .right:
            guard layout == .poster else { return .ignored }
            step = 1
        case .up:
            step = -columnCount
        case .down:
            step = columnCount
        }

        let target = currentIndex + step
        guard items.indices.contains(target) else { return .handled }

        let targetID = items[target].id
        focusedItemID = targetID
        keyboardScrollTarget = targetID
        return .handled
    }

    /// ↵：打开当前焦点条目的详情。
    ///
    /// - Returns: 事件处理结果。
    private func openFocusedItem() -> KeyPress.Result {
        guard let item = focusedItem else { return .ignored }
        onSelect(item)
        return .handled
    }

    /// 空格：播放当前焦点条目。
    ///
    /// - Returns: 事件处理结果。
    private func playFocusedItem() -> KeyPress.Result {
        guard let item = focusedItem else { return .ignored }
        onPlay(item)
        return .handled
    }

    /// 当前焦点条目。
    private var focusedItem: MediaItem? {
        guard let focusedItemID else { return nil }
        return items.first { $0.id == focusedItemID }
    }

    // MARK: 角标

    /// 从媒体源推断画质角标。
    ///
    /// 网格查询为了瘦身不取 `MediaSources`（见 ``LibraryViewModel``），因此通常返回空数组；
    /// 一旦条目上带了媒体源（例如从详情页回填的缓存数据），就能正确显示 4K / HDR。
    /// **不猜**：没有证据就不显示角标。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 角标数组。
    private func badges(for item: MediaItem) -> [PosterBadge] {
        let streams = item.mediaSources.flatMap(\.mediaStreams)
        var badges: [PosterBadge] = []
        if streams.contains(where: { ($0.height ?? 0) >= 2160 }) {
            badges.append(.fourK)
        }
        if streams.contains(where: { ($0.videoRange ?? "").uppercased().contains("HDR") }) {
            badges.append(.hdr)
        }
        return badges
    }
}

// MARK: - 列表行

/// 列表模式的紧凑行：海报缩略图 + 标题 + 年份 · 时长 + 简介。
private struct LibraryListRow: View {
    let item: MediaItem
    let imageURL: URL?
    let isSelected: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Text(verbatim: metaLine)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                if let overview = item.overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: Spacing.sm)

            trailingStatus
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isHighlighted ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
        // 双击必须注册在单击之前，否则单击要等双击判定超时（同 `PosterCard`）。
        .onTapGesture(count: 2) { onPlay() }
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    // MARK: 组成

    private var thumbnail: some View {
        AsyncPosterImage(
            url: imageURL,
            targetSize: CGSize(width: 120, height: 180),
            placeholderText: item.name
        )
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(width: 52)
        .clipShape(RoundedRectangle(cornerRadius: Radius.poster, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.poster, style: .continuous)
                .strokeBorder(Palette.separator.opacity(0.5), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isHovering {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .help("播放")
            .accessibilityLabel(Text("播放"))
        } else if item.userData.played {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel(Text("已看"))
        } else if item.isResumable {
            Text(verbatim: "\(Int((item.progress * 100).rounded()))%")
                .font(Typography.monoTime)
                .foregroundStyle(Palette.accent)
                .accessibilityLabel(Text("已观看 \(Int((item.progress * 100).rounded()))%"))
        }
    }

    /// 年份 · 时长 · 评分（缺失项自动省略，不显示「未知」）。
    private var metaLine: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let duration = item.durationText { parts.append(duration) }
        if let rating = item.communityRating {
            parts.append(String(format: "★ %.1f", rating))
        }
        if let count = item.userData.unplayedItemCount, count > 0 {
            parts.append("\(count) 集未看")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [item.name]
        if let year = item.productionYear { parts.append("\(year) 年") }
        if let rating = item.communityRating { parts.append(String(format: "%.1f 分", rating)) }
        parts.append(item.userData.played ? "已观看" : "未观看")
        return parts.joined(separator: "，")
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(isHovering || isHighlighted ? Palette.surfaceElevated : .clear)
    }

    private var borderColor: Color {
        if isHighlighted { return Palette.accent }
        if isSelected { return Palette.accent.opacity(0.6) }
        if isHovering { return Palette.separator }
        return Palette.separator.opacity(0.35)
    }
}

// MARK: - 预览

#Preview("网格 · 有数据") {
    LibraryGridView(
        items: LibraryPreviewData.items,
        layout: .poster,
        isLoadingMore: false,
        hasMore: true,
        selectedItemID: LibraryPreviewData.items.first?.id,
        imageURL: { LibraryPreviewData.posterURL(for: $0.id) },
        onSelect: { _ in },
        onPlay: { _ in },
        onMarkPlayed: { _ in },
        onMarkUnplayed: { _ in },
        onToggleFavorite: { _ in },
        onShowInFinder: { _ in },
        onItemAppear: { _ in },
        onLoadMore: {}
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .environment(\.posterImageLoader, PreviewImageLoader())
    .background(Palette.surface)
    .frame(width: 760, height: 640)
}

#Preview("列表 · 有数据") {
    LibraryGridView(
        items: LibraryPreviewData.items,
        layout: .list,
        isLoadingMore: false,
        hasMore: false,
        selectedItemID: nil,
        imageURL: { LibraryPreviewData.posterURL(for: $0.id) },
        onSelect: { _ in },
        onPlay: { _ in },
        onMarkPlayed: { _ in },
        onMarkUnplayed: { _ in },
        onToggleFavorite: { _ in },
        onShowInFinder: { _ in },
        onItemAppear: { _ in },
        onLoadMore: {}
    )
    .prismTheme(PrismTheme(appearance: .light))
    .environment(\.posterImageLoader, PreviewImageLoader())
    .background(Palette.surface)
    .frame(width: 620, height: 560)
}

#Preview("网格 · 加载更多") {
    LibraryGridView(
        items: Array(LibraryPreviewData.items.prefix(8)),
        layout: .poster,
        isLoadingMore: true,
        hasMore: true,
        selectedItemID: nil,
        imageURL: { LibraryPreviewData.posterURL(for: $0.id) },
        onSelect: { _ in },
        onPlay: { _ in },
        onMarkPlayed: { _ in },
        onMarkUnplayed: { _ in },
        onToggleFavorite: { _ in },
        onShowInFinder: { _ in },
        onItemAppear: { _ in },
        onLoadMore: {}
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .environment(\.posterImageLoader, PreviewImageLoader())
    .background(Palette.surface)
    .frame(width: 620, height: 520)
}

#Preview("网格 · 空") {
    LibraryGridView(
        items: [],
        layout: .poster,
        isLoadingMore: false,
        hasMore: false,
        selectedItemID: nil,
        imageURL: { _ in nil },
        onSelect: { _ in },
        onPlay: { _ in },
        onMarkPlayed: { _ in },
        onMarkUnplayed: { _ in },
        onToggleFavorite: { _ in },
        onShowInFinder: { _ in },
        onItemAppear: { _ in },
        onLoadMore: {}
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .environment(\.posterImageLoader, PreviewImageLoader())
    .background(Palette.surface)
    .frame(width: 620, height: 420)
}
