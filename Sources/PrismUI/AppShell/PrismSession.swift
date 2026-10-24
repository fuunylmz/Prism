import Foundation
import Observation
import PrismCore
import EmbyAPI
import PrismData
import SwiftUI

// MARK: - 会话容器

/// 一次登录会话所需的全部运行时对象。
///
/// **为什么需要这一层**：每个页面模块（Home / Library / Detail / Search）都只依赖自己目录内
/// 定义的 `*DataSource` 协议，并各自提供了 `Emby*DataSource` 实现——但它们需要一个
/// **已登录的 `EmbyClient`**。这个容器负责创建并持有它，保证「一次登录 = 一个 client 实例」。
///
/// 会话变化（切换服务器 / 重新登录 / token 失效）时，外壳应当**重建整个容器**，
/// 而不是复用旧的 `EmbyClient`（旧 token 已失效，`setSession` 也只改 token 不改 baseURL）。
@MainActor
public final class PrismSession {
    /// 当前服务器。
    public let server: ServerConnection
    /// 当前会话（含 token 与用户）。
    public let session: AuthSession
    /// 网络客户端。
    public let client: EmbyClient
    /// 图片加载器（两级缓存 + 解码期降采样 + 并发去重 + 请求合并）。
    public let imageLoader: EmbyImageLoader

    /// 是否为演示会话（`DemoEmbyClient` 驱动，不走网络）。
    public let isDemo: Bool

    /// 当前用户 id 的便捷访问。
    public var userId: String { session.userId }
    /// 当前用户。
    public var user: EmbyUser { session.user }
    /// 访问令牌（拼图片 URL 的 `api_key` 用）。
    public var accessToken: String { session.accessToken }

    /// 创建会话容器。
    ///
    /// - Parameters:
    ///   - server: 服务器连接信息。
    ///   - session: 已登录的会话。
    public init(server: ServerConnection, session: AuthSession, isDemo: Bool = false) {
        self.server = server
        self.session = session
        self.isDemo = isDemo || server.isDemo
        self.client = EmbyClient(server: server, identity: ClientIdentity.current())
        let scopedImageDirectory = ImageCache.Configuration.defaultDirectory
            .appendingPathComponent(server.id, isDirectory: true)
        let imageCache = ImageCache(
            configuration: ImageCache.Configuration(directory: scopedImageDirectory)
        )
        self.imageLoader = EmbyImageLoader(client: self.client, cache: imageCache)
    }

    /// 把 token 与用户 id 注入客户端。
    ///
    /// `EmbyClient` 是 actor，注入必须 `await`；外壳应在展示任何页面之前调用一次。
    public func activate() async {
        await client.setSession(session)
    }

    // MARK: 数据源

    /// 首页数据源。
    public var homeDataSource: EmbyHomeDataSource {
        EmbyHomeDataSource(client: client, userId: userId)
    }

    /// 媒体库数据源。
    /// 媒体库数据源。
    ///
    /// 同样不传 `accessToken`，理由见 ``detailDataSource``。
    public var libraryDataSource: EmbyLibraryDataSource {
        EmbyLibraryDataSource(
            client: client,
            userId: userId,
            baseURL: server.baseURL,
            accessToken: nil
        )
    }

    /// 详情数据源。
    ///
    /// 注意：`EmbyDetailDataSource` 不接收 `baseURL`——它内部用 `client.baseURL` 拼图片地址。
    /// 详情数据源。
    ///
    /// `accessToken` 传 `nil`：图片走 `EmbyImageLoader`，它会把同源 URL 还原成端点、
    /// 由 `EmbyClient` 注入 `X-Emby-Token` 头。把令牌拼进 URL 会同时进入
    /// 缓存键、服务端访问日志与 Referer，是不必要的泄漏面。
    public var detailDataSource: EmbyDetailDataSource {
        EmbyDetailDataSource(
            client: client,
            userId: userId,
            accessToken: nil
        )
    }

    /// 搜索数据源。
    /// 搜索数据源。
    ///
    /// 同样不传 `apiKey`，理由见 ``detailDataSource``。
    public var searchDataSource: EmbySearchDataSource {
        EmbySearchDataSource(
            client: client,
            userId: userId,
            apiKey: nil,
            baseURL: server.baseURL
        )
    }
}
