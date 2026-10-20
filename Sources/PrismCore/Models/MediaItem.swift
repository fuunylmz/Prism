import Foundation

/// Emby 的媒体条目，对应 `BaseItemDto`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.BaseItemDto.html>
/// 与 <https://dev.emby.media/doc/restapi/Item-Information.html>。
///
/// **设计要点（本类型的难点都在这里）**
/// 1. Emby 的 JSON 字段名是 PascalCase（`RunTimeTicks`、`UserData`、`ImageTags`…），
///    一律用 `CodingKeys` 映射，**不使用** `keyDecodingStrategy`——那样会污染
///    所有下游解码器（含 `EmbyAPI` 的请求体编码），且无法处理大小写混杂的插件返回。
/// 2. 任何字段缺失都不能抛错：非可选字段全部在 `init(from:)` 里给默认值；
///    数组 / 字典走容错解码，坏元素只丢自己。
/// 3. `type` 是开放类型 ``ItemType``，未知取值降级保留原字符串，绝不失败。
/// 4. `ImageTags` 的 key 是 PascalCase 的 `ImageType` 名，这里归一化成 ``ImageKind``
///    并**大小写不敏感**（`primary` / `PRIMARY` / `Primary` 都落到 ``ImageKind/primary``）。
/// 5. `RunTimeTicks` 用 ``Ticks`` 承载（`Int64?`）；`UserData` 缺失时给
///    ``UserItemData/empty``。
public struct MediaItem: Sendable, Codable, Hashable, Identifiable {
    /// 条目 id。
    public let id: String
    /// 标题。
    public let name: String
    /// 条目类型。
    public let type: ItemType
    /// 所属服务器 id。
    public let serverId: String
    /// 出品年份。
    public let productionYear: Int?
    /// 时长。
    public let runTime: Ticks?
    /// 简介。
    public let overview: String?
    /// 分级（`G`、`PG-13`、`TV-MA`…）。
    public let officialRating: String?
    /// 社区评分（0...10）。
    public let communityRating: Double?
    /// 类型标签（`Action`、`Drama`…）。
    public let genres: [String]
    /// 可用图片：key 已归一化成 ``ImageKind``。
    public let imageTags: [ImageKind: String]
    /// 背景图 tag 列表（可多张）。
    public let backdropTags: [String]
    /// 当前用户的观看状态。
    public let userData: UserItemData
    /// 所属剧集 id（仅单集 / 季有值）。
    public let seriesId: String?
    /// 所属季 id（仅单集有值）。
    public let seasonId: String?
    /// 集号（音频为音轨号）。
    public let indexNumber: Int?
    /// 季号（音频为碟号）。
    public let parentIndexNumber: Int?
    /// 所属剧集名。
    public let seriesName: String?
    /// 媒体源（多版本）。列表接口通常不返回，为空数组。
    public let mediaSources: [MediaSource]
    /// 演职员（仅详情接口返回；`nil` 表示未请求该字段）。
    public let people: [Person]?
    /// 子项数量（文件夹类条目）。
    public let childCount: Int?

    // MARK: - 契约之外、实际存在的字段

    /// 原始标题（`OriginalTitle`）。
    public let originalTitle: String?
    /// 入库时间（`DateCreated`）。
    public let dateCreated: Date?
    /// 首播 / 上映时间（`PremiereDate`）。
    public let premiereDate: Date?
    /// 服务端标记的“是否文件夹”（导航时比 `type` 更可靠）。
    public let isFolder: Bool

    /// 完整初始化。
    public init(
        id: String,
        name: String,
        type: ItemType,
        serverId: String,
        productionYear: Int? = nil,
        runTime: Ticks? = nil,
        overview: String? = nil,
        officialRating: String? = nil,
        communityRating: Double? = nil,
        genres: [String] = [],
        imageTags: [ImageKind: String] = [:],
        backdropTags: [String] = [],
        userData: UserItemData = .empty,
        seriesId: String? = nil,
        seasonId: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        seriesName: String? = nil,
        mediaSources: [MediaSource] = [],
        people: [Person]? = nil,
        childCount: Int? = nil,
        originalTitle: String? = nil,
        dateCreated: Date? = nil,
        premiereDate: Date? = nil,
        isFolder: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.serverId = serverId
        self.productionYear = productionYear
        self.runTime = runTime
        self.overview = overview
        self.officialRating = officialRating
        self.communityRating = communityRating
        self.genres = genres
        self.imageTags = imageTags
        self.backdropTags = backdropTags
        self.userData = userData
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.seriesName = seriesName
        self.mediaSources = mediaSources
        self.people = people
        self.childCount = childCount
        self.originalTitle = originalTitle
        self.dateCreated = dateCreated
        self.premiereDate = premiereDate
        self.isFolder = isFolder
    }

    // MARK: - 派生属性

    /// 主图（海报）的 tag；没有海报时为 `nil`。
    public var primaryImageTag: String? {
        imageTags[.primary]
    }

    /// 是否有海报。
    public var hasPrimaryImage: Bool {
        primaryImageTag?.isEmpty == false
    }

    /// 第一张背景图的 tag。
    public var primaryBackdropTag: String? {
        backdropTags.first ?? imageTags[.backdrop]
    }

    /// 标题 logo 的 tag。
    public var logoImageTag: String? {
        imageTags[.logo]
    }

    /// 缩略图 tag。
    public var thumbImageTag: String? {
        imageTags[.thumb]
    }

    /// 观看进度（0...1）。
    public var progress: Double {
        userData.progress(against: runTime)
    }

    /// 是否有可继续播放的进度。
    public var isResumable: Bool {
        userData.isInProgress
    }

    /// 展示用副标题：电影取年份，单集取 `S1E2`。
    ///
    /// - Returns: 副标题；没有可用信息时为 `nil`。
    public var subtitle: String? {
        if type == .episode, let season = parentIndexNumber, let episode = indexNumber {
            return String(format: "S%02dE%02d", season, episode)
        }
        if let productionYear { return String(productionYear) }
        return seriesName
    }

    /// 时长文案（`"1:23:45"`）；未知时长时为 `nil`。
    public var durationText: String? {
        runTime?.formatted
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case serverId = "ServerId"
        case productionYear = "ProductionYear"
        case runTime = "RunTimeTicks"
        case overview = "Overview"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case genres = "Genres"
        case imageTags = "ImageTags"
        case backdropTags = "BackdropImageTags"
        case userData = "UserData"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesName = "SeriesName"
        case mediaSources = "MediaSources"
        case people = "People"
        case childCount = "ChildCount"
        case originalTitle = "OriginalTitle"
        case dateCreated = "DateCreated"
        case premiereDate = "PremiereDate"
        case isFolder = "IsFolder"
    }

    /// 宽松解码：字段缺失、类型不符、元素损坏都不抛错。
    ///
    /// `Id` / `Name` / `Type` / `ServerId` 缺失时分别退化为 `""`、`""`、
    /// ``ItemType/unknown(_:)``（空串）、`""`；数字形态的 `Id` 会转成字符串。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = container.decodeFlexibleString(forKey: .id) ?? ""
        self.name = container.decodeFlexibleString(forKey: .name) ?? ""
        self.type = (try? container.decodeIfPresent(ItemType.self, forKey: .type)) ?? .unknown("")
        self.serverId = container.decodeFlexibleString(forKey: .serverId) ?? ""

        self.productionYear = container.decodeFlexibleInt(forKey: .productionYear)
        self.runTime = container.decodeTicksIfPresent(forKey: .runTime)
        self.overview = try? container.decodeIfPresent(String.self, forKey: .overview)
        self.officialRating = try? container.decodeIfPresent(String.self, forKey: .officialRating)
        self.communityRating = container.decodeFlexibleDouble(forKey: .communityRating)

        self.genres = container.decodeStringArrayIfPresent(forKey: .genres)
        self.imageTags = Self.normalizeImageTags(container.decodeStringDictionaryIfPresent(forKey: .imageTags))
        self.backdropTags = container.decodeStringArrayIfPresent(forKey: .backdropTags)
        self.userData = container.decodeLossyObject(UserItemData.self, forKey: .userData) ?? .empty

        self.seriesId = container.decodeFlexibleString(forKey: .seriesId)
        self.seasonId = container.decodeFlexibleString(forKey: .seasonId)
        self.indexNumber = container.decodeFlexibleInt(forKey: .indexNumber)
        self.parentIndexNumber = container.decodeFlexibleInt(forKey: .parentIndexNumber)
        self.seriesName = try? container.decodeIfPresent(String.self, forKey: .seriesName)
        self.mediaSources = container.decodeLossyArray(MediaSource.self, forKey: .mediaSources)
        self.people = Self.decodeOptionalPeople(container)
        self.childCount = container.decodeFlexibleInt(forKey: .childCount)

        self.originalTitle = try? container.decodeIfPresent(String.self, forKey: .originalTitle)
        self.dateCreated = container.decodeEmbyDateIfPresent(forKey: .dateCreated)
        self.premiereDate = container.decodeEmbyDateIfPresent(forKey: .premiereDate)
        self.isFolder = container.decodeFlexibleBool(forKey: .isFolder) ?? false
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(serverId, forKey: .serverId)
        try container.encodeIfPresent(productionYear, forKey: .productionYear)
        try container.encodeIfPresent(runTime, forKey: .runTime)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(officialRating, forKey: .officialRating)
        try container.encodeIfPresent(communityRating, forKey: .communityRating)
        try container.encode(genres, forKey: .genres)
        try container.encode(imageTags, forKey: .imageTags)
        try container.encode(backdropTags, forKey: .backdropTags)
        try container.encode(userData, forKey: .userData)
        try container.encodeIfPresent(seriesId, forKey: .seriesId)
        try container.encodeIfPresent(seasonId, forKey: .seasonId)
        try container.encodeIfPresent(indexNumber, forKey: .indexNumber)
        try container.encodeIfPresent(parentIndexNumber, forKey: .parentIndexNumber)
        try container.encodeIfPresent(seriesName, forKey: .seriesName)
        try container.encode(mediaSources, forKey: .mediaSources)
        try container.encodeIfPresent(people, forKey: .people)
        try container.encodeIfPresent(childCount, forKey: .childCount)
        try container.encodeIfPresent(originalTitle, forKey: .originalTitle)
        try container.encodeEmbyDateIfPresent(dateCreated, forKey: .dateCreated)
        try container.encodeEmbyDateIfPresent(premiereDate, forKey: .premiereDate)
        try container.encode(isFolder, forKey: .isFolder)
    }

    // MARK: - 私有工具

    /// 把 `[String: String]` 的 ImageTags 归一化成 `[ImageKind: String]`。
    ///
    /// - Parameter raw: 服务端原始字典（key 大小写可能不一致）。
    /// - Returns: 以 ``ImageKind`` 为 key 的字典；空值被丢弃。
    private static func normalizeImageTags(_ raw: [String: String]) -> [ImageKind: String] {
        var result: [ImageKind: String] = [:]
        for (key, value) in raw where !value.isEmpty {
            result[ImageKind(key)] = value
        }
        return result
    }

    /// 解码可选的 `People` 数组，并区分“字段缺失”与“空数组”。
    ///
    /// - Parameter container: 解码容器。
    /// - Returns: 字段缺失时 `nil`，存在时返回（可能为空的）数组。
    private static func decodeOptionalPeople(_ container: KeyedDecodingContainer<CodingKeys>) -> [Person]? {
        guard container.contains(.people) else { return nil }
        guard (try? container.decodeNil(forKey: .people)) != true else { return nil }
        return container.decodeLossyArray(Person.self, forKey: .people)
    }
}
