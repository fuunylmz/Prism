import PrismCore
import SwiftUI

// MARK: - 演职员

/// 演职员的横向列表：圆形头像 + 姓名 + 角色。
///
/// 按 `docs/research/ux-benchmark.md` §S07 的「横向圆形头像」：
/// - 直径 72pt 的圆形容器，没有头像时用**姓名首字 + 取色底**占位
///   （和海报占位同一套语言，避免出现一排灰洞）；
/// - 姓名 1 行截断、角色 1 行截断（角色名可能很长，如「他自己（年轻时期）」）；
/// - 导演 / 编剧没有角色名时显示其职能（「导演」），比留空更有信息量；
/// - 悬停轻微放大 + 强调色描边（与海报卡一致的反馈）。
///
/// 人物详情页属于 v1.1，因此点击只在提供 `onSelect` 时才可点。
public struct CastRow: View {
    private let people: [Person]
    private let imageURL: (Person) -> URL?
    private let onSelect: ((Person) -> Void)?

    /// 头像直径。
    public static let avatarSize: CGFloat = 72

    /// 创建演职员列表。
    ///
    /// - Parameters:
    ///   - people: 演职员（调用方已排序：导演 → 编剧 → 演员）。
    ///   - imageURL: 头像地址解析。
    ///   - onSelect: 点击回调；`nil` 时不可点（v1.1 才有人员页）。
    public init(
        people: [Person],
        imageURL: @escaping (Person) -> URL?,
        onSelect: ((Person) -> Void)? = nil
    ) {
        self.people = people
        self.imageURL = imageURL
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(people) { person in
                    CastMember(
                        person: person,
                        imageURL: imageURL(person),
                        onSelect: onSelect
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

// MARK: - 单个演职员

/// 单个演职员：圆形头像 + 姓名 + 角色。
private struct CastMember: View {
    let person: Person
    let imageURL: URL?
    let onSelect: ((Person) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isInteractive: Bool { onSelect != nil }

    var body: some View {
        Group {
            if let onSelect {
                Button {
                    onSelect(person)
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(person.name))
        .accessibilityValue(Text(roleText ?? ""))
        .help(person.displayName)
    }

    private var content: some View {
        VStack(spacing: Spacing.sm) {
            avatar
            VStack(spacing: 1) {
                Text(verbatim: person.name)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let roleText {
                    Text(verbatim: roleText)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 96)
        }
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        Color.clear
            .frame(width: CastRow.avatarSize, height: CastRow.avatarSize)
            .overlay {
                AsyncPosterImage(
                    url: imageURL,
                    targetSize: CGSize(width: 144, height: 144),
                    placeholderText: person.name
                )
            }
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(
                        isHovering && isInteractive ? Palette.accent : Palette.separator.opacity(0.6),
                        lineWidth: isHovering && isInteractive ? 2 : 1
                    )
            }
            .scaleEffect(isHovering && isInteractive && !reduceMotion ? 1.04 : 1)
            .shadow(
                color: .black.opacity(isHovering && isInteractive ? 0.28 : 0),
                radius: isHovering && isInteractive ? 8 : 0,
                y: 3
            )
    }

    /// 角色文案：优先 `Role`，没有时用职能（导演 / 编剧）的中文名。
    private var roleText: String? {
        if let role = person.role, !role.isEmpty {
            return role
        }
        switch person.type?.lowercased() {
        case "director": return "导演"
        case "writer", "screenplay": return "编剧"
        case "producer": return "制片"
        case "composer": return "作曲"
        case "actor": return nil
        default: return nil
        }
    }
}

// MARK: - 预览

private struct CastRowPreviewBoard: View {
    private let people = DetailViewModel.orderedPeople(DetailPreviewData.movie.people ?? [])

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(verbatim: "可点击")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            CastRow(people: people) { person in
                DetailPreviewData.imageURL(
                    itemID: person.id,
                    kind: .primary,
                    tag: person.primaryImageTag ?? ""
                )
            } onSelect: { _ in }

            Text(verbatim: "不可点击（v1.0 默认）")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            CastRow(people: people) { person in
                DetailPreviewData.imageURL(
                    itemID: person.id,
                    kind: .primary,
                    tag: person.primaryImageTag ?? ""
                )
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760, alignment: .leading)
        .background(Palette.surface)
    }
}

#Preview("CastRow · 深色") {
    CastRowPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
}

#Preview("CastRow · 浅色") {
    CastRowPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
}
