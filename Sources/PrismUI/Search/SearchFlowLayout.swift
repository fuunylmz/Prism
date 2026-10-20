import SwiftUI

// MARK: - 流式布局

/// 自动换行的流式布局（chips 用）。
///
/// SwiftUI 没有内置的「自动换行」容器：`LazyVGrid` 会把每列等宽，chip 会忽宽忽窄；
/// `HStack` 又完全不换行。因此这里用 `Layout` 协议自己实现——按行摆放，
/// 放不下就换行，行内左对齐，行高取该行最高元素。
///
/// 只用于搜索页的 chip 组（最近搜索、热门推荐），不是公开 API。
struct SearchFlowLayout: Layout {
    /// 同一行内元素之间的水平间距。
    var horizontalSpacing: CGFloat = Spacing.sm

    /// 行与行之间的垂直间距。
    var verticalSpacing: CGFloat = Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = layoutRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var y = bounds.minY
        for row in layoutRows(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: x, y: y + (row.height - element.size.height) / 2),
                    proposal: ProposedViewSize(element.size)
                )
                x += element.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    // MARK: 行计算

    /// 行内一个元素（子视图 + 它的固有尺寸）。
    private struct RowElement {
        let subview: LayoutSubview
        let size: CGSize
    }

    /// 一行。
    private struct Row {
        var elements: [RowElement] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 把子视图切成若干行。
    ///
    /// - Parameters:
    ///   - proposal: 父级给出的尺寸建议；宽度为 `nil` 时视为不换行。
    ///   - subviews: 子视图。
    /// - Returns: 行列表。
    private func layoutRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = current.elements.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width

            if !current.elements.isEmpty, neededWidth > maxWidth {
                rows.append(current)
                current = Row()
                current.width = size.width
            } else {
                current.width = neededWidth
            }

            current.height = max(current.height, size.height)
            current.elements.append(RowElement(subview: subview, size: size))
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

// MARK: - 预览

private struct SearchFlowLayoutPreviewBoard: View {
    private let terms = [
        "银翼杀手", "人生切割术", "Severance", "沙丘", "降临",
        "一部名字特别特别长的电影用来测试换行", "2049"
    ]

    var body: some View {
        SearchFlowLayout(horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
            ForEach(terms, id: \.self) { term in
                Text(verbatim: term)
                    .font(Typography.caption)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.surfaceElevated))
                    .overlay {
                        Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                    }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 320, alignment: .leading)
        .background(Palette.surface)
    }
}

#Preview("流式布局 · 深色") {
    SearchFlowLayoutPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("流式布局 · 浅色") {
    SearchFlowLayoutPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
