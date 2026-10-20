import SwiftUI

// MARK: - 详情骨架屏

/// 详情页的加载骨架。
///
/// 结构与真实页面**一一对应**（头图 → 按钮行 → 简介 → 演职员 → 相似推荐），
/// 这样内容出现时不会发生布局跳动——这是骨架屏存在的唯一理由，
/// 骨架和真页面对不上就还不如一个菊花。
///
/// 用于 `LoadState` 的 `.idle` / `.loading` 两态；剧集额外多出季选择器与集卡骨架。
/// 微光动画由 ``PrismUI/SkeletonView`` 提供，开启「减弱动态效果」时自动退化为静态灰块。
public struct DetailSkeletonView: View {
    private let showsSeriesSections: Bool

    /// 创建骨架屏。
    ///
    /// - Parameter showsSeriesSections: 是否显示「季选择器 + 集列表」骨架。
    ///   电影传 `false`（默认）；剧集传 `true`。加载完成前并不知道条目类型，
    ///   所以调用方按路由 / 已知信息决定，二者都不会出错。
    public init(showsSeriesSections: Bool = false) {
        self.showsSeriesSections = showsSeriesSections
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    actionRow

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(0..<3, id: \.self) { index in
                            SkeletonView()
                                .frame(height: 14)
                                .frame(maxWidth: index == 2 ? 420 : .infinity)
                        }
                    }

                    if showsSeriesSections {
                        seasonChips
                        episodeCards
                    }

                    castRow
                    posterRow
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
            }
        }
        .background(Palette.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("正在加载详情"))
    }

    // MARK: 区块

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            SkeletonView(cornerRadius: 0)

            VStack(alignment: .leading, spacing: Spacing.md) {
                SkeletonView(cornerRadius: Radius.poster)
                    .frame(width: 280, height: 54)
                SkeletonView()
                    .frame(width: 220, height: 14)
                SkeletonView()
                    .frame(width: 160, height: 20)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .frame(height: CinematicHeader.fallbackHeight)
        .clipped()
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.md) {
            SkeletonView()
                .frame(width: 108, height: 30)
            SkeletonView()
                .frame(width: 96, height: 30)
            SkeletonView()
                .frame(width: 84, height: 30)
        }
    }

    private var seasonChips: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<3, id: \.self) { index in
                SkeletonView(cornerRadius: 12)
                    .frame(width: index == 0 ? 92 : 80, height: 28)
            }
        }
    }

    private var episodeCards: some View {
        HStack(spacing: Spacing.lg) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SkeletonView(cornerRadius: Radius.card)
                        .frame(width: EpisodeRow.width, height: EpisodeRow.width * 9 / 16)
                    SkeletonView()
                        .frame(width: 180, height: 14)
                    SkeletonView()
                        .frame(width: 220, height: 11)
                }
            }
        }
    }

    private var castRow: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SkeletonView()
                .frame(width: 80, height: 18)

            HStack(spacing: Spacing.lg) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(spacing: Spacing.sm) {
                        SkeletonView(cornerRadius: CastRow.avatarSize / 2)
                            .frame(width: CastRow.avatarSize, height: CastRow.avatarSize)
                        SkeletonView()
                            .frame(width: 64, height: 11)
                    }
                }
            }
        }
    }

    private var posterRow: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SkeletonView()
                .frame(width: 96, height: 18)

            HStack(spacing: Spacing.lg) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonView(cornerRadius: Radius.poster)
                        .frame(width: 150, height: 225)
                }
            }
        }
    }
}

// MARK: - 预览

#Preview("详情骨架 · 电影") {
    DetailSkeletonView()
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 900, height: 900)
}

#Preview("详情骨架 · 剧集") {
    DetailSkeletonView(showsSeriesSections: true)
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 900, height: 1100)
}

#Preview("详情骨架 · 浅色") {
    DetailSkeletonView(showsSeriesSections: true)
        .prismTheme(PrismTheme(appearance: .light))
        .frame(width: 900, height: 1100)
}
