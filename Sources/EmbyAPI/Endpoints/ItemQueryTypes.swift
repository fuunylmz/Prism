import Foundation
import PrismCore

// MARK: - Fields

/// 列表查询的「额外字段」，对应 Emby 的 `MediaBrowser.Model.Querying.ItemFields`。
///
/// ## ⚠️ 为什么必须显式传 `Fields`
///
/// 列表接口默认只返回极简字段：`Overview`、`People`、`MediaSources`、`Chapters`
/// **全部为空**。官方原文："When requesting lists of items, the data coming back will be
/// much smaller… If you want to add additional fields to the items, use the fields param"
/// （<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>）。
///
/// 单条详情 `GET /Users/{id}/Items/{itemId}` 才返回全量字段。
///
/// ## ⚠️ Swagger 的 Fields 说明是过时子集
///
/// Reference 页的 `Fields` 参数说明只列了 17 项，而 Emby 4.x 的 `ItemFields` 枚举
/// **实际有 97 项**（<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Querying.ItemFields.html>）。
/// 这里收录的是客户端实际会用到的子集；需要其他字段时用 `ItemField(rawValue:)` 直接写。
///
/// 用开放类型而非封闭枚举：服务端新增字段时不会解码失败。
public struct ItemField: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 简介。
    public static let overview = ItemField(rawValue: "Overview")
    /// 类型标签。
    public static let genres = ItemField(rawValue: "Genres")
    /// 演职员（列表接口默认不返回）。
    public static let people = ItemField(rawValue: "People")
    /// 媒体源（播放协商前的兜底数据）。
    public static let mediaSources = ItemField(rawValue: "MediaSources")
    /// 媒体流（仅用于展示，播放决策请用 `MediaSources`）。
    public static let mediaStreams = ItemField(rawValue: "MediaStreams")
    /// 入库时间。
    public static let dateCreated = ItemField(rawValue: "DateCreated")
    /// 外部 id（`Tmdb` / `Imdb` / `Tvdb`…）。
    public static let providerIds = ItemField(rawValue: "ProviderIds")
    /// 制片厂。
    public static let studios = ItemField(rawValue: "Studios")
    /// 宣传语。
    public static let taglines = ItemField(rawValue: "Taglines")
    /// 出品年份。
    public static let productionYear = ItemField(rawValue: "ProductionYear")
    /// 首播 / 上映日期。
    public static let premiereDate = ItemField(rawValue: "PremiereDate")
    /// 时长（ticks）。
    public static let runTimeTicks = ItemField(rawValue: "RunTimeTicks")
    /// 分级。
    public static let officialRating = ItemField(rawValue: "OfficialRating")
    /// 社区评分。
    public static let communityRating = ItemField(rawValue: "CommunityRating")
    /// 影评人评分。
    public static let criticRating = ItemField(rawValue: "CriticRating")
    /// 主图宽高比（`Primary` 不固定比例，海报墙排版必须用它）。
    public static let primaryImageAspectRatio = ItemField(rawValue: "PrimaryImageAspectRatio")
    /// 用户数据（进度 / 已看 / 收藏）。
    public static let userData = ItemField(rawValue: "UserData")
    /// 章节。
    public static let chapters = ItemField(rawValue: "Chapters")
    /// 文件路径。
    public static let path = ItemField(rawValue: "Path")
    /// 容器格式。
    public static let container = ItemField(rawValue: "Container")
    /// 排序名。
    public static let sortName = ItemField(rawValue: "SortName")
    /// 直接子项数。
    public static let childCount = ItemField(rawValue: "ChildCount")
    /// 递归子项数。
    public static let recursiveItemCount = ItemField(rawValue: "RecursiveItemCount")
    /// 原始标题。
    public static let originalTitle = ItemField(rawValue: "OriginalTitle")
    /// 所属剧集的制片厂。
    public static let seriesStudio = ItemField(rawValue: "SeriesStudio")
    /// 是否允许下载。
    public static let canDownload = ItemField(rawValue: "CanDownload")
    /// 同步基础信息（`SupportsSync` 依赖它）。
    public static let basicSyncInfo = ItemField(rawValue: "BasicSyncInfo")
    /// 同步状态。
    public static let syncStatus = ItemField(rawValue: "SyncStatus")
    /// 宽度。
    public static let width = ItemField(rawValue: "Width")
    /// 高度。
    public static let height = ItemField(rawValue: "Height")
    /// 视频编码。
    public static let videoCodec = ItemField(rawValue: "VideoCodec")
    /// 音频编码。
    public static let audioCodec = ItemField(rawValue: "AudioCodec")
    /// 码率。
    public static let bitrate = ItemField(rawValue: "Bitrate")
    /// 文件大小。
    public static let size = ItemField(rawValue: "Size")
    /// 播出星期（剧集）。
    public static let airDays = ItemField(rawValue: "AirDays")
    /// 播出时间（剧集）。
    public static let airTime = ItemField(rawValue: "AirTime")
    /// 连载状态（`Continuing` / `Ended`）。
    public static let status = ItemField(rawValue: "Status")
    /// 专辑名（音乐）。
    public static let album = ItemField(rawValue: "Album")
    /// 专辑 id（音乐）。
    public static let albumId = ItemField(rawValue: "AlbumId")
    /// 艺术家（音乐）。
    public static let artists = ItemField(rawValue: "Artists")
    /// 外部链接。
    public static let externalUrls = ItemField(rawValue: "ExternalUrls")
    /// 在线预告片。
    public static let remoteTrailers = ItemField(rawValue: "RemoteTrailers")
    /// 本地预告片数量。
    public static let localTrailerCount = ItemField(rawValue: "LocalTrailerCount")
    /// 花絮数量。
    public static let specialFeatureCount = ItemField(rawValue: "SpecialFeatureCount")
    /// 多文件视频的分片数。
    public static let partCount = ItemField(rawValue: "PartCount")
    /// 条目元数据版本（可用于本地缓存失效判断）。
    public static let etag = ItemField(rawValue: "Etag")

    /// UI 必需字段的默认组合。
    ///
    /// 任务书要求包含 `Overview` / `Genres` / `People` / `MediaSources` / `MediaStreams` /
    /// `DateCreated` / `ProviderIds` / `Studios` / `Taglines`，这里再加 `UserData` 与
    /// `PrimaryImageAspectRatio`（海报墙排版、进度条都要用）。
    ///
    /// - Important: 列表接口用这一组会让响应明显变大；海报墙可以只用
    ///   `[.primaryImageAspectRatio, .productionYear, .userData, .runTimeTicks]`。
    public static let defaultFields: [ItemField] = [
        .overview,
        .genres,
        .people,
        .mediaSources,
        .mediaStreams,
        .dateCreated,
        .providerIds,
        .studios,
        .taglines,
        .userData,
        .primaryImageAspectRatio
    ]
}

// MARK: - SortBy / SortOrder

/// 排序字段，对应 `SortBy` 参数。
///
/// 取值来源（已核实，Swagger 描述）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// —— `Album`、`AlbumArtist`、`Artist`、`Budget`、`CommunityRating`、`CriticRating`、
/// `DateCreated`、`DatePlayed`、`PlayCount`、`PremiereDate`、`ProductionYear`、
/// `SortName`、`Random`、`Revenue`、`Runtime`。
///
/// - Note: 多字段排序的语法是 `SortBy=A,B,C&SortOrder=Descending,Descending,Ascending`，
///   两个参数**按位置一一对应**（<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>）。
public struct ItemSortBy: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 排序名（去掉 `The ` 等前缀）。
    public static let sortName = ItemSortBy(rawValue: "SortName")
    /// 入库时间。
    public static let dateCreated = ItemSortBy(rawValue: "DateCreated")
    /// 首播 / 上映日期。
    public static let premiereDate = ItemSortBy(rawValue: "PremiereDate")
    /// 出品年份。
    public static let productionYear = ItemSortBy(rawValue: "ProductionYear")
    /// 社区评分。
    public static let communityRating = ItemSortBy(rawValue: "CommunityRating")
    /// 影评人评分。
    public static let criticRating = ItemSortBy(rawValue: "CriticRating")
    /// 上次播放时间。
    public static let datePlayed = ItemSortBy(rawValue: "DatePlayed")
    /// 播放次数。
    public static let playCount = ItemSortBy(rawValue: "PlayCount")
    /// 时长。
    public static let runtime = ItemSortBy(rawValue: "Runtime")
    /// 随机。
    public static let random = ItemSortBy(rawValue: "Random")
    /// 专辑名。
    public static let album = ItemSortBy(rawValue: "Album")
    /// 专辑艺术家。
    public static let albumArtist = ItemSortBy(rawValue: "AlbumArtist")
    /// 艺术家。
    public static let artist = ItemSortBy(rawValue: "Artist")

    /// 名称（Jellyfin 枚举里有，Emby 官方列表**没有**）。
    ///
    /// 【待验证】用 Emby 未列出的值可能被静默忽略并退回默认排序。
    /// 验证方法：同一查询分别用 `SortBy=Name` 与 `SortBy=SortName` 比较返回顺序。
    public static let name = ItemSortBy(rawValue: "Name")
}

/// 排序方向，对应 `SortOrder`。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// —— `Ascending`、`Descending`。
public struct SortOrder: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 升序。
    public static let ascending = SortOrder(rawValue: "Ascending")
    /// 降序。
    public static let descending = SortOrder(rawValue: "Descending")
}

// MARK: - Filters

/// 列表过滤条件，对应 `Filters` 参数。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// —— `IsFolder`、`IsNotFolder`、`IsUnplayed`、`IsPlayed`、`IsFavorite`、`IsResumable`、
/// `Likes`、`Dislikes`。
public struct ItemFilter: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 只看文件夹。
    public static let isFolder = ItemFilter(rawValue: "IsFolder")
    /// 只看非文件夹。
    public static let isNotFolder = ItemFilter(rawValue: "IsNotFolder")
    /// 只看未看。
    public static let isUnplayed = ItemFilter(rawValue: "IsUnplayed")
    /// 只看已看。
    public static let isPlayed = ItemFilter(rawValue: "IsPlayed")
    /// 只看收藏。
    public static let isFavorite = ItemFilter(rawValue: "IsFavorite")
    /// 只看有进度未看完（「继续观看」）。
    public static let isResumable = ItemFilter(rawValue: "IsResumable")
    /// 只看「喜欢」。
    public static let likes = ItemFilter(rawValue: "Likes")
    /// 只看「不喜欢」。
    public static let dislikes = ItemFilter(rawValue: "Dislikes")
}

// MARK: - MediaTypes

/// 媒体大类，对应 `MediaTypes` 参数。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// —— `Video`、`Audio`、`Photo`、`Book`。
///
/// - Note: 与 ``PrismCore/ItemType``（精确类型，如 `Movie` / `Episode`）是两层概念：
///   `MediaTypes` 粗粒度，`IncludeItemTypes` 细粒度。
public struct MediaKind: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 视频。
    public static let video = MediaKind(rawValue: "Video")
    /// 音频。
    public static let audio = MediaKind(rawValue: "Audio")
    /// 图片。
    public static let photo = MediaKind(rawValue: "Photo")
    /// 图书。
    public static let book = MediaKind(rawValue: "Book")
}
