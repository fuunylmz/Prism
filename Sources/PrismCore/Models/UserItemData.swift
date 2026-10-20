import Foundation

/// 单个媒体条目的**用户态**数据，对应 Emby 的 `UserItemDataDto`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.UserItemDataDto.html>
/// —— `PlaybackPositionTicks`、`PlayCount`、`IsFavorite`、`Played`、`LastPlayedDate`、
/// `UnplayedItemCount`（另有 `Rating`、`PlayedPercentage`，本模型暂未使用）。
///
/// 设计取舍：`UserData` 是 Emby 里**最常整体缺失**的字段（匿名请求、刚入库的条目都会没有），
/// 因此本类型所有字段都有默认值，`init(from:)` 全程宽松解码：
/// 任何字段缺失、类型不符都退化为默认值，**绝不抛错**。
/// `MediaItem.userData` 在字段缺失时会得到一个空实例（见 ``empty``）。
public struct UserItemData: Sendable, Codable, Hashable {
    /// 上次播放到的位置。
    public var playbackPosition: Ticks
    /// 已完整播放的次数。
    public var playCount: Int
    /// 是否已收藏。
    public var isFavorite: Bool
    /// 是否已标记为看完。
    public var played: Bool
    /// 上次播放时间（Emby 返回 ISO8601，可能是 `0001-01-01T00:00:00Z` 这种 .NET 零值）。
    public var lastPlayedDate: Date?
    /// 未播放的子项数量（仅文件夹类条目有值）。
    public var unplayedItemCount: Int?

    /// 创建一个全零的空实例，用于 `UserData` 字段缺失时兜底。
    public static let empty = UserItemData()

    /// 创建一个全零的空实例。
    public init() {
        self.playbackPosition = .zero
        self.playCount = 0
        self.isFavorite = false
        self.played = false
        self.lastPlayedDate = nil
        self.unplayedItemCount = nil
    }

    /// 完整初始化。
    public init(
        playbackPosition: Ticks,
        playCount: Int,
        isFavorite: Bool,
        played: Bool,
        lastPlayedDate: Date?,
        unplayedItemCount: Int?
    ) {
        self.playbackPosition = playbackPosition
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.played = played
        self.lastPlayedDate = lastPlayedDate
        self.unplayedItemCount = unplayedItemCount
    }

    /// 是否处于“看到一半”的状态（有进度且未看完）。
    public var isInProgress: Bool {
        playbackPosition.rawValue > 0 && !played
    }

    /// 播放进度百分比（0...1）；时长未知或为 0 时返回 0。
    ///
    /// - Parameter runtime: 条目总时长。
    /// - Returns: 0...1 的进度。
    public func progress(against runtime: Ticks?) -> Double {
        guard let runtime, runtime.rawValue > 0 else { return 0 }
        let ratio = Double(playbackPosition.rawValue) / Double(runtime.rawValue)
        return min(max(ratio, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case playbackPosition = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case lastPlayedDate = "LastPlayedDate"
        case unplayedItemCount = "UnplayedItemCount"
    }

    /// 宽松解码：任何字段缺失或类型不符都退化为默认值。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.playbackPosition = container.decodeTicksIfPresent(forKey: .playbackPosition) ?? .zero
        self.playCount = container.decodeFlexibleInt(forKey: .playCount) ?? 0
        self.isFavorite = container.decodeFlexibleBool(forKey: .isFavorite) ?? false
        self.played = container.decodeFlexibleBool(forKey: .played) ?? false
        self.lastPlayedDate = container.decodeEmbyDateIfPresent(forKey: .lastPlayedDate)
        self.unplayedItemCount = container.decodeFlexibleInt(forKey: .unplayedItemCount)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playbackPosition, forKey: .playbackPosition)
        try container.encode(playCount, forKey: .playCount)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(played, forKey: .played)
        try container.encodeEmbyDateIfPresent(lastPlayedDate, forKey: .lastPlayedDate)
        try container.encodeIfPresent(unplayedItemCount, forKey: .unplayedItemCount)
    }
}
