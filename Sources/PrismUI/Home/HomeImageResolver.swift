import Foundation
import PrismCore
import SwiftUI

// MARK: - 图片地址解析

/// 把 ``PrismCore/MediaItem`` 解析成 Emby 的图片地址。
///
/// 首页只负责**拼 URL**，不负责下载 / 解码 / 缓存——那些由 `DesignSystem` 的
/// ``AsyncPosterImage`` 与注入的 `PosterImageLoading` 完成（本工单不实现图片加载）。
///
/// ## 为什么需要它
///
/// `AsyncPosterImage` 的过渡实现 `PassthroughImageLoader` 用裸 `URLSession` 发请求，
/// **不带任何请求头**；而 Emby 的图片端点默认要求鉴权。因此这里把令牌以
/// `?api_key=` 的形式写进 URL（Emby / Jellyfin 都支持该查询参数，是图片端点的
/// 通用做法）。
///
/// - Important: `api_key` 会出现在 URL 里，可能被日志 / Referer 记录。
///   一旦图片加载器支持自定义请求头（Nuke 实现），应改用 `X-Emby-Token` 头，
///   届时只需把 ``accessToken`` 传 `nil`。
///
/// ## 缓存
///
/// 带上 `tag`（条目上的 `ImageTags` / `BackdropImageTags`）后，服务器会返回强缓存头，
/// 客户端可以把这个 URL 当作稳定缓存键：图片变了 tag 也变，旧缓存自然失效。
/// **没有 tag 就不发请求**（否则必然 404），直接返回 `nil` 让 UI 显示占位图。
public struct HomeImageResolver: Sendable, Hashable {
    /// 服务器基地址；`nil` 表示「不解析图片」（预览里会显示占位图）。
    public let baseURL: URL?
    /// 访问令牌；`nil` 时不附加 `api_key`（演示模式 / 预览）。
    public let accessToken: String?

    /// 什么都不解析的解析器：所有 URL 都是 `nil`，UI 显示占位图。
    public static let disabled = HomeImageResolver(baseURL: nil)

    /// 创建解析器。
    ///
    /// - Parameters:
    ///   - baseURL: 服务器基地址（例如 `http://192.168.1.10:8096`）。
    ///   - accessToken: 访问令牌，默认 `nil`。
    public init(baseURL: URL?, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    /// 是否为「禁用」状态（不产生任何网络请求）。
    public var isDisabled: Bool {
        baseURL == nil
    }

    /// 生成某条目的某类图片地址。
    ///
    /// - Parameters:
    ///   - item: 媒体条目（提供 id 与图片 tag）。
    ///   - kind: 图片类型（海报 / 背景图 / 缩略图）。
    ///   - maxWidth: 期望宽度（服务端等比缩放；Retina 下按 2 倍取）。
    ///   - tag: 缓存 tag；`nil` 时自动从条目上取对应类型的 tag。
    ///   - index: 图片序号（`Backdrop` 有多张时用，`0` 基）；`nil` 表示由服务端取默认。
    /// - Returns: 图片地址；没有可用 tag 或未配置服务器时为 `nil`。
    public func url(
        for item: MediaItem,
        kind: ImageKind,
        maxWidth: Int,
        tag: String? = nil,
        index: Int? = nil
    ) -> URL? {
        guard let baseURL, !item.id.isEmpty else { return nil }

        guard let cacheTag = tag ?? Self.tag(for: item, kind: kind), !cacheTag.isEmpty else {
            return nil
        }

        var url = baseURL
        url.appendPathComponent("Items")
        url.appendPathComponent(item.id)
        url.appendPathComponent("Images")
        url.appendPathComponent(kind.rawValue)
        if let index {
            url.appendPathComponent(String(index))
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "tag", value: cacheTag)
        ]
        if let accessToken, !accessToken.isEmpty {
            queryItems.append(URLQueryItem(name: "api_key", value: accessToken))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// 海报地址（2:3）。没有海报时返回 `nil`。
    ///
    /// - Parameters:
    ///   - item: 媒体条目。
    ///   - maxWidth: 期望宽度，默认 360（160pt 卡片在 Retina 下的两倍）。
    /// - Returns: 图片地址。
    public func posterURL(for item: MediaItem, maxWidth: Int = 360) -> URL? {
        url(for: item, kind: .primary, maxWidth: maxWidth)
    }

    /// 横向剧照地址（16:9），用于「继续观看」卡片。
    ///
    /// 优先 `Backdrop`（宽幅剧照），没有时退回 `Primary`——单集的 `Primary`
    /// 通常就是 16:9 的剧照，退化后观感依然成立。
    ///
    /// - Parameters:
    ///   - item: 媒体条目。
    ///   - maxWidth: 期望宽度，默认 640。
    /// - Returns: 图片地址。
    public func backdropURL(for item: MediaItem, maxWidth: Int = 640) -> URL? {
        url(for: item, kind: .backdrop, maxWidth: maxWidth, index: 0)
            ?? url(for: item, kind: .primary, maxWidth: maxWidth)
    }

    /// 缩略图地址（16:9），用于「接下来」与横版卡片。
    ///
    /// 优先 `Thumb`，没有时退回 `Primary`。
    ///
    /// - Parameters:
    ///   - item: 媒体条目。
    ///   - maxWidth: 期望宽度，默认 480。
    /// - Returns: 图片地址。
    public func thumbnailURL(for item: MediaItem, maxWidth: Int = 480) -> URL? {
        url(for: item, kind: .thumb, maxWidth: maxWidth)
            ?? url(for: item, kind: .primary, maxWidth: maxWidth)
    }

    /// 取条目上对应图片类型的缓存 tag。
    ///
    /// - Parameters:
    ///   - item: 媒体条目。
    ///   - kind: 图片类型。
    /// - Returns: tag；条目上没有该类型图片时为 `nil`。
    static func tag(for item: MediaItem, kind: ImageKind) -> String? {
        switch kind {
        case .primary:
            item.primaryImageTag
        case .backdrop:
            item.primaryBackdropTag
        case .thumb:
            item.thumbImageTag
        default:
            item.imageTags[kind]
        }
    }
}

// MARK: - 环境注入

private struct HomeImageResolverKey: EnvironmentKey {
    static let defaultValue = HomeImageResolver.disabled
}

public extension EnvironmentValues {
    /// 首页使用的图片地址解析器。
    ///
    /// 由 ``HomeView`` 在根部注入一次；``MediaRail`` / ``ContinueWatchingCard`` /
    /// `LibraryGrid` 从环境读取，避免把同一个闭包层层透传。
    var homeImageResolver: HomeImageResolver {
        get { self[HomeImageResolverKey.self] }
        set { self[HomeImageResolverKey.self] = newValue }
    }
}

public extension View {
    /// 注入首页图片地址解析器。
    ///
    /// - Parameter resolver: 解析器；传 ``HomeImageResolver/disabled`` 时全部显示占位图。
    /// - Returns: 已注入的视图。
    func homeImageResolver(_ resolver: HomeImageResolver) -> some View {
        environment(\.homeImageResolver, resolver)
    }
}
