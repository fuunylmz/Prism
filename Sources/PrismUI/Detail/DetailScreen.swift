import PrismCore
import SwiftUI

// MARK: - 详情入口

/// 详情栏的统一入口：按条目类型分派到电影页或剧集页。
///
/// 外壳只需要这一行：
///
/// ```swift
/// DetailScreen(
///     model: DetailViewModel(
///         dataSource: EmbyDetailDataSource(client: client, userId: session.userId,
///                                          accessToken: session.accessToken),
///         itemId: itemID
///     ),
///     actions: DetailActions(
///         play: { request in navigation.openPlayer(request) },
///         openItem: { id in navigation.showDetail(id) }
///     )
/// )
/// .id(itemID)
/// ```
///
/// 为什么不直接让外壳判断类型：**加载完成前根本不知道条目是电影还是剧集**
/// （路由里只有 id）。所以这里先渲染骨架，拿到内容后再分派；两个子页面共用
/// 同一个 ``DetailViewModel`` 实例，不会重复请求。
///
/// - Important: 切换条目时请在调用处加 `.id(itemID)`，否则会继续显示上一个条目。
public struct DetailScreen: View {
    @State private var model: DetailViewModel
    private let actions: DetailActions

    /// 创建详情入口。
    ///
    /// - Parameters:
    ///   - model: 视图模型（内部 `@State` 持有）。
    ///   - actions: 播放 / 打开别的条目的回调。
    public init(model: DetailViewModel, actions: DetailActions = DetailActions()) {
        _model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some View {
        switch model.state {
        case let .loaded(content):
            if content.isSeries {
                SeriesDetailView(model: model, actions: actions)
            } else {
                MovieDetailView(model: model, actions: actions)
            }
        case .idle, .loading:
            DetailSkeletonView()
                .task { await model.loadIfNeeded() }
        case .empty:
            EmptyStateView(
                systemImage: "questionmark.folder",
                title: "找不到这个条目",
                message: "它可能已从服务器上移除。",
                actionTitle: "重试",
                actionSystemImage: "arrow.clockwise"
            ) {
                Task { await model.load() }
            }
        case let .failed(error):
            ErrorStateView(error: error, onRetry: { Task { await model.load() } })
        }
    }
}

struct DetailPageScaffold<Content: View>: View {
    private let header: CinematicHeader
    private let content: Content

    init(
        header: CinematicHeader,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    content
                        .frame(maxWidth: 1_120, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PageMetrics.horizontalInset(for: min(proxy.size.width, 1_120)))
                        .padding(.top, Spacing.xl)
                        .padding(.bottom, Spacing.xxl)
                }
                .frame(maxWidth: 1_120)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.surface)
    }
}

// MARK: - 预览

#Preview("DetailScreen · 电影") {
    DetailScreen(model: DetailViewModel(previewState: .loaded(DetailPreviewData.movieContent)))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 900, height: 900)
}

#Preview("DetailScreen · 剧集") {
    DetailScreen(model: DetailViewModel(previewState: .loaded(DetailPreviewData.seriesContent)))
        .environment(\.posterImageLoader, DetailPreviewImageLoader())
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 900, height: 1000)
}

#Preview("DetailScreen · 加载中") {
    DetailScreen(model: DetailViewModel(previewState: .loading))
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 900, height: 900)
}

#Preview("DetailScreen · 错误") {
    DetailScreen(model: DetailViewModel(previewState: .failed(.notFound)))
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 900, height: 700)
}
