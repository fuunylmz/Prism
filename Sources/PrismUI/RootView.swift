import SwiftUI
import PrismCore
import EmbyAPI
import PrismData
import PrismPlayback

/// Prism 的根视图。
///
/// 只负责把 `AppShell` 的根外壳接上屏；导航骨架、侧边栏与页面由
/// `AppShell/` 提供，设计 token 由 `DesignSystem/` 提供。
///
/// 依赖链的连通性由本文件证明：UI → Data → API → Core 全部可编译、可上屏。
public struct RootView: View {
    public init() {}

    public var body: some View {
        RootShell()
    }
}
