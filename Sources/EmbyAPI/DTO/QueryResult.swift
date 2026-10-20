import Foundation
import PrismCore

/// Emby 的 `QueryResult<T>`：分页查询的统一返回包装。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// —— `Items: BaseItemDto[]`、`TotalRecordCount: integer(int32)`。
///
/// ## 关于 `StartIndex`
///
/// Emby 的 `QueryResult` **只声明了 `Items` 与 `TotalRecordCount`**（对照
/// <https://dev.emby.media/reference/RestAPI/SystemService/getSystemLogsQuery.html> 等任意
/// `QueryResult_*` 定义可见，均只有这两个字段）。任务书要求的 `StartIndex` 在实际响应里
/// 通常**不返回**，因此这里做成可选字段：有就解出来，没有就是 `nil`，客户端应自行记住
/// 自己请求的 `StartIndex`。
///
/// ## 用法
///
/// ```swift
/// let page: ItemsQueryResult = try await client.send(ItemsEndpoint(userId: userId))
/// page.items            // [MediaItem]
/// page.totalRecordCount // 过滤后的总数，不是本页条数
/// ```
///
/// - Note: ``ItemsQueryResult`` 是 `QueryResult<MediaItem>` 的别名；``MediaView`` 的列表
///   用 `QueryResult<MediaView>`。
public struct QueryResult<Item: Codable & Sendable & Hashable>: Sendable, Codable, Hashable {
    /// 本页条目。
    public let items: [Item]

    /// **过滤后**的总数（不是本页条数）。用它算总页数、判断是否还有下一页。
    ///
    /// 服务端没给时退化为 `items.count`（这样至少不会把「有数据」误判成「空」）。
    public let totalRecordCount: Int

    /// 本页起点。Emby 的 `QueryResult` 未声明该字段，通常为 `nil`。
    public let startIndex: Int?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - items: 本页条目。
    ///   - totalRecordCount: 过滤后总数。
    ///   - startIndex: 本页起点。
    public init(items: [Item], totalRecordCount: Int, startIndex: Int? = nil) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.startIndex = startIndex
    }

    /// 本页条数。
    public var count: Int {
        items.count
    }

    /// 是否为空库 / 空结果。
    public var isEmpty: Bool {
        items.isEmpty
    }

    /// 是否还有下一页。
    ///
    /// - Parameter pageSize: 本次请求的 `Limit`；`nil` 时按 `items.count` 估算。
    /// - Returns: `true` 表示可以继续翻页。
    public func hasMore(pageSize: Int? = nil) -> Bool {
        guard !items.isEmpty else { return false }
        let consumed = (startIndex ?? 0) + (pageSize ?? items.count)
        return consumed < totalRecordCount
    }

    private enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }

    /// 宽松解码：`Items` 缺失返回空数组，坏元素只丢自己；`TotalRecordCount` 缺失时退化为条数。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems: [Item] = container.embyArray(Item.self, forKey: .items)
        self.items = decodedItems
        self.totalRecordCount = container.embyInt(forKey: .totalRecordCount) ?? decodedItems.count
        self.startIndex = container.embyInt(forKey: .startIndex)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(totalRecordCount, forKey: .totalRecordCount)
        try container.encodeIfPresent(startIndex, forKey: .startIndex)
    }
}

/// `GET /Users/{userId}/Items`、`/Shows/NextUp` 等返回 `QueryResult<BaseItemDto>` 的端点。
public typealias ItemsQueryResult = QueryResult<MediaItem>

/// `GET /Users/{userId}/Views` 的返回：`QueryResult<UserView>`。
public typealias ViewsQueryResult = QueryResult<MediaView>

/// 媒体库入口，对应 `/Users/{userId}/Views` 返回的 `BaseItemDto`。
///
/// 与 ``PrismCore/MediaItem`` 的区别只有一处：视图需要 `CollectionType` 来决定用哪种 UI 呈现
/// （海报墙 / 剧集 / 音乐 / 书…），而 ``PrismCore/MediaItem`` 没有这个字段。
/// 这里用「组合」而不是复制字段：`item` 承载全部通用字段，`collectionType` 是额外的一层。
///
/// `CollectionType` 取值（已核实）：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>
/// —— `movies`、`tvshows`、`music`、`games`、`books`、`musicvideos`、`homevideos`、
/// `livetv`、`channels`；`null` 表示混合文件夹，按通用方式浏览。
public struct MediaView: Sendable, Codable, Hashable, Identifiable {
    /// 视图对应的通用条目（id / name / type / imageTags / userData…）。
    public let item: MediaItem

    /// 视图类型；`nil` 表示混合文件夹。
    public let collectionType: LibraryType?

    /// `Identifiable` 要求。
    public var id: String {
        item.id
    }

    /// 视图名（如 `Movies`、`TV Shows`）。
    public var name: String {
        item.name
    }

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - item: 视图对应的通用条目。
    ///   - collectionType: 视图类型。
    public init(item: MediaItem, collectionType: LibraryType? = nil) {
        self.item = item
        self.collectionType = collectionType
    }

    private enum CodingKeys: String, CodingKey {
        case collectionType = "CollectionType"
    }

    /// 宽松解码：先按 ``PrismCore/MediaItem`` 解出通用字段，再取 `CollectionType`。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        self.item = try MediaItem(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = container.embyString(forKey: .collectionType) ?? ""
        self.collectionType = raw.isEmpty ? nil : LibraryType(rawValue: raw)
    }

    /// 编码为扁平的 `BaseItemDto`（额外写入 `CollectionType`）。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        try item.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(collectionType?.rawValue, forKey: .collectionType)
    }
}

/// 媒体库类型，对应 `CollectionType` 字段。
///
/// 取值来源（已核实）：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>。
/// 用开放类型承载，未知取值原样保留（服务端将来新增库类型时不会解码失败）。
public struct LibraryType: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 电影库。
    public static let movies = LibraryType(rawValue: "movies")
    /// 剧集库。
    public static let tvShows = LibraryType(rawValue: "tvshows")
    /// 音乐库。
    public static let music = LibraryType(rawValue: "music")
    /// 游戏库。
    public static let games = LibraryType(rawValue: "games")
    /// 图书库。
    public static let books = LibraryType(rawValue: "books")
    /// 音乐视频库。
    public static let musicVideos = LibraryType(rawValue: "musicvideos")
    /// 家庭视频库。
    public static let homeVideos = LibraryType(rawValue: "homevideos")
    /// 直播电视。
    public static let liveTV = LibraryType(rawValue: "livetv")
    /// 频道。
    public static let channels = LibraryType(rawValue: "channels")
}
