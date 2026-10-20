import SwiftUI

// MARK: - 骨架块

/// 骨架屏的基础灰块。
///
/// 用于「加载中」占位：保持布局稳定，避免内容出现时跳动。
/// 默认带微光（shimmer）动画；开启系统「减弱动态效果」时自动退化为**静态灰块**。
///
/// ```swift
/// SkeletonView(cornerRadius: Radius.poster)
///     .aspectRatio(2.0 / 3.0, contentMode: .fit)
/// ```
///
/// 灰块颜色用 `Color.primary.opacity(0.08)`：浅色下是 8% 黑，深色下是 8% 白，
/// 两种外观都自然，且不需要写死灰度。
public struct SkeletonView: View {
    private let cornerRadius: CGFloat

    /// 创建骨架块。
    ///
    /// - Parameter cornerRadius: 圆角，默认 ``Radius/card``。海报占位传 ``Radius/poster``。
    public init(cornerRadius: CGFloat = Radius.card) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .prismShimmer(cornerRadius: cornerRadius)
            .accessibilityHidden(true)
    }
}

// MARK: - Shimmer

/// 微光扫过效果。
///
/// 实现方式：在内容上叠一条半透明白色渐变带，用 `offset` 从左扫到右并循环。
/// - 不使用 `TimelineView`：循环动画开销更低，且不会在窗口不可见时继续跑。
/// - **尊重「减弱动态效果」**：`accessibilityReduceMotion` 为真时不渲染渐变带，
///   内容保持静态。
public struct PrismShimmerModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isAnimating = false

    /// 创建 shimmer modifier。
    ///
    /// - Parameters:
    ///   - cornerRadius: 裁剪圆角，默认 `0`（直角）。
    ///   - isActive: 是否启用；`false` 时不渲染动画层，用于暂停。
    public init(cornerRadius: CGFloat = 0, isActive: Bool = true) {
        self.cornerRadius = cornerRadius
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isActive, !reduceMotion {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        LinearGradient(
                            stops: [
                                .init(color: highlight.opacity(0), location: 0),
                                .init(color: highlight, location: 0.5),
                                .init(color: highlight.opacity(0), location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.7)
                        .offset(x: isAnimating ? width : -width)
                        .animation(
                            .linear(duration: 1.4).repeatForever(autoreverses: false),
                            value: isAnimating
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                isAnimating = !reduceMotion
            }
            .onChange(of: reduceMotion) { _, isReduced in
                // 从「减少动效」切回来时重新启动扫光；切过去时立刻停住。
                isAnimating = !isReduced
            }
    }

    /// 扫光带颜色：深色下用低透明度白，浅色下稍高一点才能在浅灰块上看出来。
    private var highlight: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.45)
    }
}

public extension View {
    /// 给任意视图叠加骨架屏微光。
    ///
    /// - Parameters:
    ///   - cornerRadius: 裁剪圆角；需要与内容自身圆角一致，默认 `0`。
    ///   - isActive: 是否启用，默认 `true`。
    /// - Returns: 叠加了微光层的视图。
    ///
    /// 示例：
    /// ```swift
    /// RoundedRectangle(cornerRadius: Radius.poster)
    ///     .fill(Palette.surfaceElevated)
    ///     .prismShimmer(cornerRadius: Radius.poster)
    /// ```
    func prismShimmer(cornerRadius: CGFloat = 0, isActive: Bool = true) -> some View {
        modifier(PrismShimmerModifier(cornerRadius: cornerRadius, isActive: isActive))
    }
}

// MARK: - 预览

private struct SkeletonPreviewBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Skeleton").font(Typography.title)

            HStack(alignment: .top, spacing: Spacing.lg) {
                SkeletonView(cornerRadius: Radius.poster)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: 120)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SkeletonView().frame(height: 18)
                    SkeletonView().frame(width: 160, height: 12)
                    SkeletonView().frame(width: 90, height: 12)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420, height: 300, alignment: .topLeading)
        .background(Palette.surface)
    }
}

#Preview("Skeleton · 深色") {
    SkeletonPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("Skeleton · 浅色") {
    SkeletonPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
