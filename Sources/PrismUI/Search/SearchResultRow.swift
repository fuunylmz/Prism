import PrismCore
import SwiftUI

// MARK: - 结果行

/// 一条搜索结果行（单集 / 人物，以及列表形态的电影 / 剧集）。
///
/// ## 视觉
///
/// - 左侧：缩略图（人物为圆形头像，单集为 16:9 缩略图，其余为 2:3 海报）；
/// - 中间：标题（``HighlightedText`` 高亮查询词）+ 副标题；
/// - 右侧：类型徽标（图标 + 「电影 / 剧集 / 单集 / 人物」）。
///
/// ## 状态
///
/// - `isSelected`：键盘选中态——强调色底 + 左侧 2pt 竖条（`Palette.accent`）；
/// - hover：极淡的底色，不抢选中态；
/// - 两者都不依赖系统焦点环，避免与内容区的焦点环叠成双层边框。
///
/// ## 键盘
///
/// 行本身不是焦点目标：**↑↓ / ↵ 由容器统一处理**（见 ``SearchView`` 的结果区），
/// 因为「在结果间移动」本质是跨行的列表行为，逐行各自监听会导致焦点在行之间跳、
/// 高亮与焦点两套状态不同步。行只负责「呈现」与「点击」，选中态通过
/// ``isSelected`` 传入。
///
/// ```swift
/// SearchResultRow(
///     item: SearchResultItem(item: episode),
///     query: "切割",
///     isSelected: selectedID == episode.id,
///     onActivate: { open(episode) }
/// )
/// ```
public struct SearchResultRow: View {
    private let item: SearchResultItem
    private let query: String
    private let isSelected: Bool
    private let onActivate: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建结果行。
    ///
    /// - Parameters:
    ///   - item: 结果行模型。
    ///   - query: 当前查询词，用于标题高亮；为空时不高亮。
    ///   - isSelected: 是否是键盘当前选中项。
    ///   - onActivate: 点击 / ↵ 的回调（↵ 由容器转发）。
    public init(
        item: SearchResultItem,
        query: String = "",
        isSelected: Bool = false,
        onActivate: @escaping () -> Void
    ) {
        self.item = item
        self.query = query
        self.isSelected = isSelected
        self.onActivate = onActivate
    }

    public var body: some View {
        HStack(spacing: Spacing.md) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(item.title, query: query)
                    .font(Typography.body)
                    .lineLimit(1)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.sm)

            kindBadge
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            selectionBar
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.accessibilityDescription))
        .accessibilityAddTraits(.isButton)
        .help(Text(verbatim: item.accessibilityDescription))
    }

    // MARK: 缩略图

    @ViewBuilder
    private var thumbnail: some View {
        if item.usesCircularImage {
            AsyncPosterImage(
                url: item.imageURL,
                targetSize: CGSize(width: 96, height: 96),
                placeholderText: item.title
            )
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(Palette.separator, lineWidth: 1)
            }
        } else if item.kind == .episode {
            AsyncPosterImage(
                url: item.imageURL,
                targetSize: CGSize(width: 160, height: 90),
                placeholderText: item.title
            )
            .frame(width: 72, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster / 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.poster / 2, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
        } else {
            AsyncPosterImage(
                url: item.imageURL,
                targetSize: CGSize(width: 120, height: 180),
                placeholderText: item.title
            )
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster / 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.poster / 2, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
        }
    }

    // MARK: 类型徽标

    private var kindBadge: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(verbatim: item.kind.title)
                .font(Typography.caption)
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Palette.surfaceElevated))
        .overlay {
            Capsule().strokeBorder(Palette.separator, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    // MARK: 状态

    private var background: Color {
        if isSelected {
            Palette.accent.opacity(0.16)
        } else if isHovering {
            Palette.textPrimary.opacity(0.06)
        } else {
            Palette.surfaceElevated.opacity(0.5)
        }
    }

    private var borderColor: Color {
        isSelected ? Palette.accent.opacity(0.7) : Palette.separator.opacity(0.6)
    }

    @ViewBuilder
    private var selectionBar: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Palette.accent)
                .frame(width: 3)
                .padding(.vertical, Spacing.xs)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 预览

private struct SearchResultRowPreviewBoard: View {
    private let episode = SearchPreviewData.episode
    private let person = SearchPreviewData.people[0]
    private let movie = SearchPreviewData.movies[0]

    var body: some View {
        VStack(spacing: Spacing.sm) {
            SearchResultRow(
                item: SearchResultItem(item: episode),
                query: "切",
                isSelected: true
            ) {}

            SearchResultRow(
                item: SearchResultItem(person: person),
                query: "亚当"
            ) {}

            SearchResultRow(
                item: SearchResultItem(item: movie),
                query: "银翼"
            ) {}

            SearchResultRow(
                item: SearchResultItem(
                    id: "no-image",
                    kind: .episode,
                    title: "没有缩略图的单集",
                    subtitle: "某部剧 · S02E10"
                ),
                query: "缩略图"
            ) {}
        }
        .padding(Spacing.lg)
        .frame(width: 520)
        .background(Palette.surface)
    }
}

#Preview("结果行 · 深色") {
    SearchResultRowPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("结果行 · 浅色") {
    SearchResultRowPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, PreviewImageLoader())
}
