import Foundation
import PrismCore

// MARK: - 标记已看

/// `POST|DELETE /Users/{userId}/PlayedItems/{itemId}` —— 标记已看 / 未看。
///
/// 官方文档（标记已看）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html>
/// 官方文档（标记未看）：<https://dev.emby.media/reference/RestAPI/PlaystateService/deleteUsersByUseridPlayeditemsById.html>
///
/// 返回更新后的 ``PrismCore/UserItemData``，可直接用来刷新 UI，不必重新拉列表。
///
/// ```swift
/// let updated: UserItemData = try await client.send(
///     MarkPlayedEndpoint(userId: userId, itemId: item.id, isPlayed: true)
/// )
/// ```
///
/// - Note: 对 **Series** 标记已看会级联到所有集 —— ◐ 社区一致行为，官方未明说。
///   【待验证】在剧集详情页点「标记已看」后，检查各集的 `UserData.Played`。
public struct MarkPlayedEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 条目 id。
    public let itemId: String

    /// `true` = 标记已看（POST），`false` = 标记未看（DELETE）。
    public let isPlayed: Bool

    /// 观看时间（可选）。
    ///
    /// - Important: 该参数格式是 **`yyyyMMddHHmmss`**（无时区、无分隔符），
    ///   与响应里的 ISO8601 完全不同（已核实：
    ///   <https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html>）。
    ///   【待验证】官方未说明时区语义，本实现按 UTC 格式化。
    public let datePlayed: Date?

    /// 以用户 id、条目 id 与目标状态创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    ///   - isPlayed: `true` 标记已看，`false` 标记未看。
    ///   - datePlayed: 观看时间（仅标记已看时有意义）。
    public init(userId: String, itemId: String, isPlayed: Bool, datePlayed: Date? = nil) {
        self.userId = userId
        self.itemId = itemId
        self.isPlayed = isPlayed
        self.datePlayed = datePlayed
    }

    /// `/Users/{userId}/PlayedItems/{itemId}`。
    public var path: String { "/Users/\(userId)/PlayedItems/\(itemId)" }

    /// 标记已看用 `POST`，标记未看用 `DELETE`。
    public var method: HTTPMethod { isPlayed ? .post : .delete }

    /// `DatePlayed`（仅标记已看时发送）。
    public var query: [String: String] {
        guard isPlayed, let datePlayed else { return [:] }
        return ["DatePlayed": EmbyDateFormat.playedDate(datePlayed)]
    }
}

// MARK: - 收藏

/// `POST|DELETE /Users/{userId}/FavoriteItems/{itemId}` —— 收藏 / 取消收藏。
///
/// 官方文档（收藏）：<https://dev.emby.media/reference/RestAPI/UserLibraryService/postUsersByUseridFavoriteitemsById.html>
/// 官方文档（取消收藏）：<https://swagger.emby.media/openapi.json> →
/// `/Users/{UserId}/FavoriteItems/{Id}` 的 `delete`。
///
/// 返回更新后的 ``PrismCore/UserItemData``。
public struct MarkFavoriteEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 条目 id。
    public let itemId: String

    /// `true` = 收藏（POST），`false` = 取消收藏（DELETE）。
    public let isFavorite: Bool

    /// 以用户 id、条目 id 与目标状态创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    ///   - isFavorite: `true` 收藏，`false` 取消收藏。
    public init(userId: String, itemId: String, isFavorite: Bool) {
        self.userId = userId
        self.itemId = itemId
        self.isFavorite = isFavorite
    }

    /// `/Users/{userId}/FavoriteItems/{itemId}`。
    public var path: String { "/Users/\(userId)/FavoriteItems/\(itemId)" }

    /// 收藏用 `POST`，取消收藏用 `DELETE`。
    public var method: HTTPMethod { isFavorite ? .post : .delete }
}
