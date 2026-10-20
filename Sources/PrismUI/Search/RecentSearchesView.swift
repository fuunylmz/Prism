import SwiftUI

// MARK: - 最近搜索

/// 最近搜索列表（chips）。
///
/// 对应 `docs/research/ux-benchmark.md` §S14 的「落地页（未输入）：最近搜索」：
/// - 每条是一个 chip，**点击直接搜索**；
/// - 每个 chip 右侧有删除按钮（`xmark`），只删这一条；
/// - 底部「清除全部」，只在有内容时出现。
///
/// 数据与副作用都由 ``SearchViewModel`` 提供（`recentSearches` / `removeRecent(_:)` /
/// `clearRecent()`），本视图是纯展示 + 回调，方便单独预览与复用。
///
/// ```swift
/// RecentSearchesView(
///     terms: viewModel.recentSearches,
///     onSelect: { term in Task { await viewModel.search(term) } },
///     onDelete: { viewModel.removeRecent($0) },
///     onClearAll: { viewModel.clearRecent() }
/// )
/// ```
public struct RecentSearchesView: View {
    private let terms: [String]
    private let onSelect: (String) -> Void
    private let onDelete: (String) -> Void
    private let onClearAll: (() -> Void)?

    /// 创建最近搜索视图。
    ///
    /// - Parameters:
    ///   - terms: 关键词列表（最近的在前）。
    ///   - onSelect: 点击 chip 的回调（直接搜索）。
    ///   - onDelete: 点击单条删除按钮的回调。
    ///   - onClearAll: 「清除全部」的回调；`nil` 时不显示该按钮。
    public init(
        terms: [String],
        onSelect: @escaping (String) -> Void,
        onDelete: @escaping (String) -> Void,
        onClearAll: (() -> Void)? = nil
    ) {
        self.terms = terms
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onClearAll = onClearAll
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header

            if terms.isEmpty {
                emptyHint
            } else {
                chips
            }

            if !terms.isEmpty, let onClearAll {
                footer(clearAll: onClearAll)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("最近搜索"))
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            Text("最近搜索")
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary)

            if !terms.isEmpty {
                Text(verbatim: "\(terms.count)")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.surfaceElevated))
                    .overlay {
                        Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            }

            Spacer(minLength: Spacing.sm)

            if !terms.isEmpty {
                Text("点击直接搜索")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: 列表

    private var chips: some View {
        SearchFlowLayout(horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
            ForEach(terms, id: \.self) { term in
                RecentSearchChip(
                    term: term,
                    onSelect: { onSelect(term) },
                    onDelete: { onDelete(term) }
                )
            }
        }
    }

    private var emptyHint: some View {
        Text("还没有搜索记录。输入关键词后，最近搜过的内容会出现在这里。")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 底部

    private func footer(clearAll: @escaping () -> Void) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: clearAll) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                    Text("清除全部")
                        .font(Typography.caption)
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("清除全部最近搜索")
            .accessibilityLabel(Text("清除全部最近搜索"))
        }
    }
}

// MARK: - 单个 chip

/// 一个最近搜索 chip：左侧文字可点击搜索，右侧 `xmark` 删除本条。
private struct RecentSearchChip: View {
    let term: String
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isDeleteHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button(action: onSelect) {
                Text(verbatim: term)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.leading, Spacing.sm)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "搜索「\(term)」"))

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isDeleteHovering ? Palette.textPrimary : Palette.textSecondary)
                    .frame(width: 14, height: 14)
                    .background {
                        Circle().fill(Palette.textPrimary.opacity(isDeleteHovering ? 0.12 : 0))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isDeleteHovering = $0 }
            .padding(.trailing, Spacing.xs)
            .help("从最近搜索中删除")
            .accessibilityLabel(Text(verbatim: "删除最近搜索 \(term)"))
        }
        .padding(.vertical, 1)
        .background {
            Capsule()
                .fill(isHovering ? Palette.textPrimary.opacity(0.08) : Palette.surfaceElevated)
        }
        .overlay {
            Capsule().strokeBorder(Palette.separator, lineWidth: 1)
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 预览

private struct RecentSearchesPreviewBoard: View {
    @State private var terms = ["银翼杀手", "人生切割术", "Severance", "沙丘", "降临"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            RecentSearchesView(
                terms: terms,
                onSelect: { _ in },
                onDelete: { term in terms.removeAll { $0 == term } },
                onClearAll: { terms.removeAll() }
            )

            Divider()

            RecentSearchesView(
                terms: [],
                onSelect: { _ in },
                onDelete: { _ in },
                onClearAll: {}
            )
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .background(Palette.surface)
    }
}

#Preview("最近搜索 · 深色") {
    RecentSearchesPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("最近搜索 · 浅色") {
    RecentSearchesPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
