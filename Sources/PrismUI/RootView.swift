import SwiftUI
import PrismCore
import EmbyAPI
import PrismData
import PrismPlayback

/// Prism 的根视图占位。
///
/// 骨架阶段只负责证明整条依赖链（UI → Data → API → Core）能编译、能上屏；
/// 真正的导航骨架与设计系统由 PrismUI 的 owner 在 `Sources/PrismUI/` 内演进。
public struct RootView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)

            Text("Prism")
                .font(.largeTitle.weight(.semibold))

            Text("骨架已就绪 · \(Prism.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 640, minHeight: 420)
        .padding(40)
    }
}
