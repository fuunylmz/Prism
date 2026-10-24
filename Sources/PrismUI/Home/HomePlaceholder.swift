import SwiftUI

// MARK: - 加载骨架

/// 首页骨架屏。
///
/// 结构与真实布局**一一对应**（继续观看横版卡 → 接下来缩略图 → 最新添加海报 →
/// 媒体库网格），这样数据回来时不会出现整页跳动——这是 UX §S04「加载态」的要求：
/// 用骨架屏而不是菊花。
///
/// - Important: 本组件**不自带纵向 `ScrollView`**：它总是被 ``HomeView`` 放在自己的
///   纵向滚动容器里，再套一层会形成嵌套滚动（滚动手势互相抢占、内容高度塌陷）。
///   单独预览时由调用方自己包 `ScrollView`。
///
/// 微光动画由 ``SkeletonView`` 提供，开启系统「减弱动态效果」时自动退化为静态灰块。
///
/// ```swift
/// case .idle, .loading:
///     HomePlaceholder()
/// ```
struct HomePlaceholder: View {
    /// 每行骨架卡片的数量。
    private let railCounts = [4, 5, 6]

    var body: some View {
        VStack(alignment: .leading, spacing: PageMetrics.sectionSpacing) {
            continueWatchingRail
            episodeRail
            posterRail
            libraryGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("正在加载首页"))
    }

    // MARK: 继续观看

    /// 「继续观看」骨架：只有横版卡，没有卡片下方文字（真实布局也是这样）。
    private var continueWatchingRail: some View {
        rail(count: railCounts[0], cardWidth: HomeMetrics.continueWatchingWidth, ratio: HomeMetrics.landscapeAspect, showsText: false)
    }

    /// 「接下来」骨架：横版缩略图 + 两行文字。
    private var episodeRail: some View {
        rail(count: railCounts[1], cardWidth: HomeMetrics.episodeWidth, ratio: HomeMetrics.landscapeAspect, showsText: true)
    }

    /// 「最新添加」骨架：2:3 海报 + 两行文字。
    private var posterRail: some View {
        rail(count: railCounts[2], cardWidth: HomeMetrics.posterWidth, ratio: HomeMetrics.posterAspect, showsText: true)
    }

    // MARK: 通用

    /// 一行骨架：标题条 + 若干卡片占位。
    ///
    /// 横向用 `HStack` 而不是 `ScrollView`：骨架不参与滚动，也不需要裁剪，
    /// 用 `HStack` 还能让超出宽度的卡片自然溢出（被父容器裁掉即可），
    /// 与真实横向滚动行的首屏观感一致。
    ///
    /// - Parameters:
    ///   - count: 卡片数量。
    ///   - cardWidth: 卡片宽度（与真实卡片一致，保证不跳动）。
    ///   - ratio: 图片宽高比。
    ///   - showsText: 是否画卡片下方的标题 / 副标题占位。
    private func rail(count: Int, cardWidth: CGFloat, ratio: CGFloat, showsText: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SkeletonView()
                .frame(width: 132, height: 20)

            HStack(alignment: .top, spacing: Spacing.lg) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SkeletonView(cornerRadius: Radius.card)
                            .aspectRatio(ratio, contentMode: .fit)
                            .frame(width: cardWidth)

                        if showsText {
                            SkeletonView()
                                .frame(width: cardWidth * 0.7, height: 12)
                            SkeletonView()
                                .frame(width: cardWidth * 0.4, height: 10)
                        }
                    }
                }
            }
            // 卡片比内容区宽时右端被裁掉，这是骨架屏的预期表现（真实行可以横向滚动）。
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }

    // MARK: 媒体库

    /// 媒体库网格骨架。
    private var libraryGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SkeletonView()
                .frame(width: 96, height: 20)

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(
                            minimum: HomeMetrics.libraryMinWidth,
                            maximum: HomeMetrics.libraryMaxWidth
                        ),
                        spacing: Spacing.lg,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: Spacing.lg
            ) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SkeletonView(cornerRadius: Radius.card)
                            .aspectRatio(HomeMetrics.landscapeAspect, contentMode: .fit)
                        SkeletonView()
                            .frame(width: 88, height: 12)
                    }
                }
            }
        }
    }
}

// MARK: - 预览

#Preview("首页骨架 · 深色（加载中）") {
    ScrollView(.vertical) {
        HomePlaceholder()
            .padding(.horizontal, PageMetrics.horizontalInset(for: 1000))
            .padding(.vertical, Spacing.xl)
    }
    .frame(width: 1000, height: 760)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("首页骨架 · 浅色（加载中）") {
    ScrollView(.vertical) {
        HomePlaceholder()
            .padding(.horizontal, PageMetrics.horizontalInset(for: 700))
            .padding(.vertical, Spacing.xl)
    }
    .frame(width: 700, height: 620)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
}
