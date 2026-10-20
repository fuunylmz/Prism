import SwiftUI
import PrismCore

// MARK: - 详情路由

/// 按条目类型选择详情布局：剧集走 ``SeriesDetailView``，其余走 ``MovieDetailView``。
///
/// 详情页本身不持有导航与播放器（`DetailActions` 由外壳注入），
/// 但两个布局类型是分开的，需要一个薄路由层在拿到数据后决定用哪一个。
///
/// 之所以放在 `AppShell/` 而不是 `Detail/`：这是**集成逻辑**，
/// 属于外壳对页面模块的编排；`Detail/` 目录保持「只认识自己的 ViewModel」。
struct DetailRouterView: View {
    let viewModel: DetailViewModel
    let actions: DetailActions

    var body: some View {
        Group {
            if case let .loaded(content) = viewModel.state, content.item.type == .series {
                SeriesDetailView(model: viewModel, actions: actions)
            } else {
                MovieDetailView(model: viewModel, actions: actions)
            }
        }
        .task {
            await viewModel.load()
        }
    }
}
