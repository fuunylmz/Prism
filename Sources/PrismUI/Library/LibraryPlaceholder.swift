import SwiftUI

// MARK: - 骨架屏

/// 媒体库的骨架屏，与真实网格 / 列表**同一套尺寸与间距**。
///
/// 为什么不用一个转圈：`docs/research/ux-benchmark.md` §3.0 明确要求列表 / 网格
/// 默认用骨架屏，「保留布局，避免内容出现时跳动」。这里的列宽（最小 140pt）、
/// 间距（``Spacing/lg``）、内边距（``Spacing/xl``）与 ``LibraryGridView`` 完全一致，
/// 因此数据到达时不会发生重排。
///
/// ```swift
/// LibrarySkeletonView(layout: .poster)
/// LibrarySkeletonView(layout: .list, itemCount: 6)
/// ```
public struct LibrarySkeletonView: View {
    /// 与真实网格一致的列定义（最小 140pt，自适应）。
    private static let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Spacing.lg)
    ]

    private let layout: GridLayout
    private let itemCount: Int
    @State private var containerWidth: CGFloat = 0

    private var horizontalInset: CGFloat {
        PageMetrics.horizontalInset(for: containerWidth)
    }

    /// 创建骨架屏。
    ///
    /// - Parameters:
    ///   - layout: 与当前布局一致，默认网格。
    ///   - itemCount: 骨架块数量，默认 12（UX 文档 §S05「骨架网格（12 个灰块）」）。
    public init(layout: GridLayout = .poster, itemCount: Int = 12) {
        self.layout = layout
        self.itemCount = max(itemCount, 1)
    }

    public var body: some View {
        ScrollView {
            switch layout {
            case .poster:
                posterGrid
            case .list:
                listRows
            }
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("正在加载媒体库"))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
    }

    // MARK: 网格形态

    private var posterGrid: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Spacing.xl) {
            ForEach(0..<itemCount, id: \.self) { index in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SkeletonView(cornerRadius: Radius.poster)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)

                    SkeletonView()
                        .frame(height: 14)
                        .padding(.trailing, index.isMultiple(of: 3) ? 24 : 8)

                    SkeletonView()
                        .frame(width: 52, height: 11)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: 列表形态

    private var listRows: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(0..<itemCount, id: \.self) { index in
                HStack(alignment: .top, spacing: Spacing.md) {
                    SkeletonView(cornerRadius: Radius.poster)
                        .frame(width: 52, height: 78)

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SkeletonView()
                            .frame(height: 14)
                            .padding(.trailing, index.isMultiple(of: 2) ? 60 : 24)
                        SkeletonView()
                            .frame(width: 120, height: 11)
                        SkeletonView()
                            .frame(height: 10)
                    }
                    .padding(.top, 2)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, Spacing.xl)
    }
}

// MARK: - 预览

#Preview("骨架屏 · 网格 · 深色") {
    LibrarySkeletonView(layout: .poster)
        .prismTheme(PrismTheme(appearance: .dark))
        .background(Palette.surface)
        .frame(width: 760, height: 640)
}

#Preview("骨架屏 · 列表 · 浅色") {
    LibrarySkeletonView(layout: .list, itemCount: 6)
        .prismTheme(PrismTheme(appearance: .light))
        .background(Palette.surface)
        .frame(width: 520, height: 560)
}
