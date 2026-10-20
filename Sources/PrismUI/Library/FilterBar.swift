import Foundation
import SwiftUI

// MARK: - 筛选排序栏

/// 媒体库内容栏顶部的筛选 / 排序栏（`docs/research/ux-benchmark.md` §S06）。
///
/// 结构：
/// - **左**：当前库名 + 条目总数（「共 128 部」）；
/// - **右**：排序菜单、筛选按钮（弹出 ``LibraryFilterPopover``）、布局切换（网格 / 列表）；
/// - 有活动筛选时，筛选按钮显示**徽标数字**，并出现「清除全部」。
///
/// 这一栏由 ``LibraryView`` 放在 `ScrollView` **外面**，因此滚动时不走。
///
/// **紧凑性**：内容栏最窄 420pt。为了让按钮永不换行，控件区用
/// `ViewThatFits(in: .horizontal)` 提供两档：完整档（排序带文字 + 清除全部）
/// 与紧凑档（排序只剩图标）。420pt 下自动落到紧凑档。
///
/// 本视图是**纯展示 + 回调**：不持有视图模型，方便 `#Preview` 单独预览各种筛选状态。
public struct FilterBar: View {
    private let libraryName: String
    private let totalCount: Int
    private let countUnit: String
    private let sort: SortOption
    private let filters: FilterSet
    private let layout: GridLayout
    private let availableGenres: [String]
    private let onSortChange: (SortOption) -> Void
    private let onFiltersChange: (FilterSet) -> Void
    private let onLayoutChange: (GridLayout) -> Void

    @State private var isFilterPopoverPresented = false

    /// 创建筛选排序栏。
    ///
    /// - Parameters:
    ///   - libraryName: 库名（工具栏标题也用它）。
    ///   - totalCount: 条目总数（服务端 `TotalRecordCount`）。
    ///   - countUnit: 量词，默认「部」。
    ///   - sort: 当前排序。
    ///   - filters: 当前筛选。
    ///   - layout: 当前布局。
    ///   - availableGenres: 可选类型列表（来自已加载条目）。
    ///   - onSortChange: 选择排序。
    ///   - onFiltersChange: 筛选变化（每次勾选都立即回调，不做「应用」按钮）。
    ///   - onLayoutChange: 切换网格 / 列表。
    public init(
        libraryName: String,
        totalCount: Int,
        countUnit: String = "部",
        sort: SortOption,
        filters: FilterSet,
        layout: GridLayout,
        availableGenres: [String],
        onSortChange: @escaping (SortOption) -> Void,
        onFiltersChange: @escaping (FilterSet) -> Void,
        onLayoutChange: @escaping (GridLayout) -> Void
    ) {
        self.libraryName = libraryName
        self.totalCount = totalCount
        self.countUnit = countUnit
        self.sort = sort
        self.filters = filters
        self.layout = layout
        self.availableGenres = availableGenres
        self.onSortChange = onSortChange
        self.onFiltersChange = onFiltersChange
        self.onLayoutChange = onLayoutChange
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            titleBlock
                .layoutPriority(1)

            Spacer(minLength: Spacing.sm)

            ViewThatFits(in: .horizontal) {
                fullControls
                compactControls
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        // 不透明底色：内容滚动到栏下方时不会透出来（栏本身不在 ScrollView 里，
        // 但窗口背景是半透明的，这里显式铺一层）。
        .background(Palette.surface)
    }

    // MARK: 左侧

    private var titleBlock: some View {
        HStack(spacing: Spacing.sm) {
            Text(verbatim: libraryName)
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(verbatim: totalText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: totalText))
        }
    }

    /// 条目总数文案：`共 128 部`。
    private var totalText: String {
        "共 \(totalCount) \(countUnit)"
    }

    // MARK: 右侧

    /// 完整档：排序带文字 + 「清除全部」。
    private var fullControls: some View {
        HStack(spacing: Spacing.sm) {
            if filters.isFiltered {
                Button("清除全部") {
                    onFiltersChange(filters.cleared())
                }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundStyle(Palette.accent)
                .fixedSize()
                .help("清除全部筛选条件")
                .accessibilityLabel(Text("清除全部筛选"))
            }

            sortMenu(showsTitle: true)
            filterButton
            layoutToggle
        }
    }

    /// 紧凑档：排序只剩图标，保证 420pt 内容栏里不换行。
    private var compactControls: some View {
        HStack(spacing: Spacing.xs) {
            sortMenu(showsTitle: false)
            filterButton
            layoutToggle
        }
    }

    private func sortMenu(showsTitle: Bool) -> some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    onSortChange(option)
                } label: {
                    if option == sort {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                if showsTitle {
                    Text(verbatim: sort.title)
                        .font(Typography.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Palette.surfaceElevated)
                    .overlay {
                        Capsule().strokeBorder(Palette.separator.opacity(0.6), lineWidth: 1)
                    }
            }
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序：\(sort.title)")
        .accessibilityLabel(Text(verbatim: "排序：\(sort.title)"))
    }

    private var filterButton: some View {
        FilterBadgeButton(
            isActive: filters.isFiltered,
            badgeCount: filters.activeFilterCount,
            isPresented: isFilterPopoverPresented
        ) {
            isFilterPopoverPresented.toggle()
        }
        .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .bottom) {
            LibraryFilterPopover(
                filters: filters,
                availableGenres: availableGenres,
                onChange: onFiltersChange,
                onDismiss: { isFilterPopoverPresented = false }
            )
        }
    }

    private var layoutToggle: some View {
        LayoutToggle(layout: layout, onChange: onLayoutChange)
    }
}

// MARK: - 筛选按钮

/// 带徽标数字的筛选按钮。
///
/// 徽标显示**生效中的条件个数**（勾 3 个类型就是 3），激活时图标变为实心并染强调色。
private struct FilterBadgeButton: View {
    let isActive: Bool
    let badgeCount: Int
    let isPresented: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Palette.accent : Palette.textPrimary)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(Palette.textPrimary.opacity(isHovering || isPresented ? 0.10 : 0))
                }
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        Text(verbatim: "\(badgeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Palette.accent))
                            .offset(x: 4, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .help(isActive ? "筛选（已启用 \(badgeCount) 项）" : "筛选")
        .accessibilityLabel(Text(isActive ? "筛选，已启用 \(badgeCount) 项" : "筛选"))
    }
}

// MARK: - 布局切换

/// 网格 / 列表二选一的分段式切换。
private struct LayoutToggle: View {
    let layout: GridLayout
    let onChange: (GridLayout) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(GridLayout.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(option == layout ? Palette.textPrimary : Palette.textSecondary)
                        .frame(width: 24, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(option == layout ? Palette.textPrimary.opacity(0.12) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(option == layout ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.surfaceElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 1)
                }
        }
        .fixedSize()
    }
}

// MARK: - 筛选弹层

/// 筛选弹层：观看状态 / 类型 / 年份范围 / 评分下限。
///
/// 每个控件改动都**立即**回调 ``FilterBar``（对应 UX 文档 §S06
/// 「任一筛选变更 → 立即请求，不点『应用』」）；防抖由视图模型负责。
struct LibraryFilterPopover: View {
    let filters: FilterSet
    let availableGenres: [String]
    let onChange: (FilterSet) -> Void
    let onDismiss: () -> Void

    /// 年份默认区间（「限制年份范围」刚打开时用）。
    private var defaultYearRange: ClosedRange<Int> {
        let currentYear = Calendar.current.component(.year, from: Date())
        return 1990...currentYear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("筛选")
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    watchStateSection
                    Divider()
                    genreSection
                    Divider()
                    yearSection
                    Divider()
                    ratingSection
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 380)

            Divider()
            footer
        }
        .padding(Spacing.lg)
        .frame(width: 300)
        .background(Palette.surface)
    }

    // MARK: 观看状态

    private var watchStateSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("观看状态")

            Picker(
                "观看状态",
                selection: Binding(
                    get: { filters.watchState },
                    set: { onChange(filters.setting(watchState: $0)) }
                )
            ) {
                ForEach(FilterSet.WatchState.allCases) { state in
                    Text(state.title).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: 类型

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("类型")

            if availableGenres.isEmpty {
                Text("暂无可选类型：媒体库加载后会出现在这里。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: Spacing.xs)],
                    alignment: .leading,
                    spacing: Spacing.xs
                ) {
                    ForEach(availableGenres, id: \.self) { genre in
                        genreChip(genre)
                    }
                }
            }
        }
    }

    private func genreChip(_ genre: String) -> some View {
        let isSelected = filters.genres.contains(genre)
        return Button {
            onChange(filters.togglingGenre(genre))
        } label: {
            Text(verbatim: genre)
                .font(Typography.caption)
                .foregroundStyle(isSelected ? Palette.accent : Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background {
                    Capsule()
                        .fill(isSelected ? Palette.accent.opacity(0.16) : Palette.surfaceElevated)
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    isSelected ? Palette.accent : Palette.separator.opacity(0.6),
                                    lineWidth: 1
                                )
                        }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: genre))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 年份

    private var yearSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("年份范围")

            Toggle(
                "限制年份范围",
                isOn: Binding(
                    get: { filters.yearRange != nil },
                    set: { isOn in
                        onChange(filters.settingYearRange(isOn ? defaultYearRange : nil))
                    }
                )
            )
            .toggleStyle(.checkbox)
            .font(Typography.caption)

            if let range = filters.yearRange {
                yearStepper(title: "从", value: range.lowerBound, range: range) { newValue in
                    filters.settingYearRange(min(newValue, range.upperBound)...range.upperBound)
                }
                yearStepper(title: "到", value: range.upperBound, range: range) { newValue in
                    filters.settingYearRange(range.lowerBound...max(newValue, range.lowerBound))
                }
            }
        }
    }

    private func yearStepper(
        title: String,
        value: Int,
        range: ClosedRange<Int>,
        makeFilters: @escaping (Int) -> FilterSet
    ) -> some View {
        Stepper(
            value: Binding(
                get: { value },
                set: { onChange(makeFilters($0)) }
            ),
            in: 1900...max(range.upperBound, 1900)
        ) {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: title)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text(verbatim: String(value))
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 评分

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                sectionTitle("评分下限")
                Spacer(minLength: 0)
                Text(verbatim: ratingText)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(filters.minimumRating == nil ? Palette.textSecondary : Palette.accent)
            }

            Slider(
                value: Binding(
                    get: { filters.minimumRating ?? 0 },
                    set: { newValue in
                        // 0 = 不限，避免把「滑块在最左」误当成「只看 0 分」。
                        onChange(filters.settingMinimumRating(newValue <= 0 ? nil : newValue))
                    }
                ),
                in: 0...10,
                step: 0.5
            )
            .controlSize(.small)
        }
    }

    private var ratingText: String {
        guard let rating = filters.minimumRating else { return "不限" }
        return String(format: "≥ %.1f", rating)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Button("清除全部") {
                onChange(filters.cleared())
            }
            .buttonStyle(.plain)
            .font(Typography.caption)
            .foregroundStyle(filters.isFiltered ? Palette.accent : Palette.textSecondary)
            .disabled(!filters.isFiltered)
            .accessibilityLabel(Text("清除全部筛选"))

            Spacer(minLength: 0)

            Button("完成") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.small)
        }
    }

    // MARK: 小标题

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
    }
}

// MARK: - 预览

/// 预览用的可交互筛选栏（`#Preview` 里改状态能立刻看到徽标变化）。
private struct FilterBarPreviewBoard: View {
    let width: CGFloat

    @State private var sort: SortOption = .recentlyAdded
    @State private var filters: FilterSet
    @State private var layout: GridLayout = .poster

    init(initialFilters: FilterSet, width: CGFloat) {
        self.width = width
        _filters = State(initialValue: initialFilters)
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                libraryName: "电影",
                totalCount: 1284,
                sort: sort,
                filters: filters,
                layout: layout,
                availableGenres: LibraryPreviewData.genres,
                onSortChange: { sort = $0 },
                onFiltersChange: { filters = $0 },
                onLayoutChange: { layout = $0 }
            )

            Divider()

            Text("内容区（筛选栏固定在顶部，不随内容滚动）")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: 220)
        .background(Palette.surface)
    }
}

#Preview("筛选栏 · 无筛选 · 420pt") {
    FilterBarPreviewBoard(initialFilters: .none, width: 420)
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("筛选栏 · 有筛选 · 420pt") {
    FilterBarPreviewBoard(
        initialFilters: FilterSet(
            watchState: .unwatched,
            genres: ["科幻", "悬疑"],
            yearRange: 1990...2024,
            minimumRating: 7.5
        ),
        width: 420
    )
    .prismTheme(PrismTheme(appearance: .light))
}

#Preview("筛选栏 · 宽栏 · 640pt") {
    FilterBarPreviewBoard(
        initialFilters: FilterSet(genres: ["剧情"]),
        width: 640
    )
    .prismTheme(PrismTheme(appearance: .dark))
}
