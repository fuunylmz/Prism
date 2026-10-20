import EmbyAPI
import Foundation
import PrismCore

// MARK: - 数据源协议

/// 首页需要的全部数据能力。
///
/// 这是一层**注入点**，首页本身不认识 `EmbyClient`：
/// - 真实实现：``EmbyHomeDataSource``（包装 `EmbyClient` 的 `resume` / `latest` /
///   `nextUp` / `views` 便利方法）；
/// - 演示实现：由 Demo Mode 工单提供的 `DemoEmbyClient` 适配器（**不在本模块内**，
///   避免 `PrismUI` 反向依赖演示数据）；
/// - 预览 / 测试：`HomePreviewData.swift` 里的 `PreviewHomeDataSource`。
///
/// 协议要求 `Sendable`：``HomeViewModel`` 会用 `withThrowingTaskGroup` 并发拉取四个分区，
/// 实现会被多个子任务同时持有，因此实现内部的可变状态必须自己保证线程安全
/// （`EmbyClient` 是 actor，天然满足）。
///
/// ```swift
/// let dataSource = EmbyHomeDataSource(client: client, userId: session.userId)
/// let model = HomeViewModel(dataSource: dataSource)
/// await model.load()
/// ```
public protocol HomeDataSource: Sendable {
    /// 「继续观看」：有播放进度但未看完的条目。
    func resume() async throws -> [MediaItem]

    /// 「最新添加」。
    ///
    /// - Parameter limit: 最多取多少条（该端点不支持分页）。
    func latest(limit: Int) async throws -> [MediaItem]

    /// 「接下来」：在追剧集的下一集。
    func nextUp() async throws -> [MediaItem]

    /// 顶层媒体库入口（`/Users/{id}/Views`）。
    ///
    /// 保留 `MediaView.collectionType`，因为它是服务端给出的真实库类型；不能
    /// 降级成 `MediaItem` 后再按库名猜测，否则自定义命名的剧集库会被当成电影库。
    func views() async throws -> [MediaView]
}

// MARK: - Emby 实现

/// ``HomeDataSource`` 的真实实现：把四个分区映射到 `EmbyClient` 的便利方法。
///
/// 只做「端点 + 参数」的组合，不做重试 / 缓存 / 状态机——那些属于网络层与视图模型。
///
/// ```swift
/// let dataSource = EmbyHomeDataSource(client: client, userId: "u1")
/// ```
public struct EmbyHomeDataSource: HomeDataSource {
    private let client: EmbyClient
    private let userId: String
    private let resumeLimit: Int
    private let latestLimit: Int
    private let nextUpLimit: Int

    /// 创建 Emby 数据源。
    ///
    /// - Parameters:
    ///   - client: 已登录的客户端（令牌由 `EmbyClient` 自己持有）。
    ///   - userId: 当前用户 id（Emby 的 `/Users/{id}/…` 端点必填）。
    ///   - resumeLimit: 「继续观看」条数，默认 20。
    ///   - latestLimit: 「最新添加」条数，默认 20。
    ///   - nextUpLimit: 「接下来」条数，默认 24。
    public init(
        client: EmbyClient,
        userId: String,
        resumeLimit: Int = 20,
        latestLimit: Int = 20,
        nextUpLimit: Int = 24
    ) {
        self.client = client
        self.userId = userId
        self.resumeLimit = resumeLimit
        self.latestLimit = latestLimit
        self.nextUpLimit = nextUpLimit
    }

    public func resume() async throws -> [MediaItem] {
        try await client.resume(userId: userId, limit: resumeLimit)
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        try await client.latest(userId: userId, limit: limit)
    }

    public func nextUp() async throws -> [MediaItem] {
        try await client.nextUp(userId: userId, limit: nextUpLimit)
    }

    /// 媒体库入口。
    ///
    /// 直接返回 `/Views` 的 `MediaView`，保留 `CollectionType`——点击库入口时
    /// 用它精确决定这是电影库还是剧集库，而不是靠库名猜。
    public func views() async throws -> [MediaView] {
        try await client.views(userId: userId)
    }
}
