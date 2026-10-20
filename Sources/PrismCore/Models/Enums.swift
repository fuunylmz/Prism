import Foundation

/// 媒体条目的种类，对应 Emby `BaseItemDto.Type` 字段。
///
/// 服务端返回的是字符串（PascalCase，如 `"Movie"`、`"Episode"`、`"BoxSet"`）。
/// 官方文档明确建议客户端**不要穷举类型**（<https://dev.emby.media/doc/restapi/Item-Types.html>：
/// “Try to avoid this as much as possible … This will allow your code to continue to
/// function as new types are added”），因此这里用 `RawRepresentable` 而不是封闭 `enum`：
/// 任何未知取值都降级成 ``unknown(_:)`` 并保留原始字符串，**不会解码失败**。
///
/// 已知取值（Emby 文档 + Jellyfin `BaseItemKind` 并集）：
/// `AggregateFolder`、`Audio`、`AudioBook`、`BasePluginFolder`、`Book`、`BoxSet`、
/// `Channel`、`ChannelFolderItem`、`CollectionFolder`、`Episode`、`Folder`、`Genre`、
/// `LiveTvChannel`、`LiveTvProgram`、`ManualPlaylistsFolder`、`Movie`、`MusicAlbum`、
/// `MusicArtist`、`MusicGenre`、`MusicVideo`、`Person`、`Photo`、`PhotoAlbum`、
/// `Playlist`、`PlaylistsFolder`、`Program`、`Recording`、`Season`、`Series`、`Studio`、
/// `Trailer`、`TvChannel`、`TvProgram`、`UserRootFolder`、`UserView`、`Video`、`Year`。
public struct ItemType: RawRepresentable, Sendable, Hashable, Codable {
    /// 服务端返回的原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 以原始字符串构造（与 `init(rawValue:)` 等价，便于调用处少写标签）。
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - 视频类

    /// 电影。
    public static let movie = ItemType("Movie")
    /// 剧集。
    public static let series = ItemType("Series")
    /// 季。
    public static let season = ItemType("Season")
    /// 单集。
    public static let episode = ItemType("Episode")
    /// 预告片。
    public static let trailer = ItemType("Trailer")
    /// 通用视频文件。
    public static let video = ItemType("Video")
    /// MV / 音乐视频。
    public static let musicVideo = ItemType("MusicVideo")
    /// 成人视频。
    public static let adultVideo = ItemType("AdultVideo")

    // MARK: - 集合与容器

    /// 合集 / 电影套装。
    public static let boxSet = ItemType("BoxSet")
    /// 播放列表。
    public static let playlist = ItemType("Playlist")
    /// 播放列表文件夹。
    public static let playlistsFolder = ItemType("PlaylistsFolder")
    /// 手动播放列表文件夹。
    public static let manualPlaylistsFolder = ItemType("ManualPlaylistsFolder")
    /// 通用文件夹。
    public static let folder = ItemType("Folder")
    /// 媒体库根目录（`/Users/{id}/Views` 返回的就是它）。
    public static let collectionFolder = ItemType("CollectionFolder")
    /// 用户视角根节点。
    public static let userView = ItemType("UserView")
    /// 用户根目录。
    public static let userRootFolder = ItemType("UserRootFolder")
    /// 聚合文件夹。
    public static let aggregateFolder = ItemType("AggregateFolder")
    /// 插件根文件夹。
    public static let basePluginFolder = ItemType("BasePluginFolder")

    // MARK: - 音频

    /// 音频文件。
    public static let audio = ItemType("Audio")
    /// 有声书。
    public static let audioBook = ItemType("AudioBook")
    /// 音乐专辑。
    public static let musicAlbum = ItemType("MusicAlbum")
    /// 音乐人。
    public static let musicArtist = ItemType("MusicArtist")
    /// 音乐流派。
    public static let musicGenre = ItemType("MusicGenre")

    // MARK: - 其他

    /// 书籍。
    public static let book = ItemType("Book")
    /// 照片。
    public static let photo = ItemType("Photo")
    /// 相册。
    public static let photoAlbum = ItemType("PhotoAlbum")
    /// 游戏。
    public static let game = ItemType("Game")
    /// 游戏平台。
    public static let gameSystem = ItemType("GameSystem")
    /// 演员 / 职员。
    public static let person = ItemType("Person")
    /// 流派。
    public static let genre = ItemType("Genre")
    /// 制片厂。
    public static let studio = ItemType("Studio")
    /// 年份。
    public static let year = ItemType("Year")
    /// 频道。
    public static let channel = ItemType("Channel")
    /// 频道内文件夹。
    public static let channelFolderItem = ItemType("ChannelFolderItem")
    /// Live TV 频道。
    public static let liveTvChannel = ItemType("LiveTvChannel")
    /// Live TV 节目。
    public static let liveTvProgram = ItemType("LiveTvProgram")
    /// 电视节目（通用）。
    public static let tvChannel = ItemType("TvChannel")
    /// 电视节目（通用）。
    public static let tvProgram = ItemType("TvProgram")
    /// 录制内容。
    public static let recording = ItemType("Recording")
    /// 通用节目。
    public static let program = ItemType("Program")

    // MARK: - 降级

    /// 无法识别的类型，保留服务端原始字符串。
    ///
    /// 之所以不叫 `unknown(String)`，是因为 `ItemType` 本身就是开放类型：
    /// 只要 `rawValue` 不匹配任何已知常量，即视为未知。
    public static func unknown(_ rawValue: String) -> ItemType {
        ItemType(rawValue)
    }

    /// 是否为“可直接播放”的媒体类型（电影、单集、视频、MV、预告片、音频）。
    public var isPlayable: Bool {
        switch self {
        case .movie, .episode, .video, .musicVideo, .trailer, .audio, .adultVideo:
            true
        default:
            false
        }
    }

    /// 是否为可下钻的容器（剧集、季、合集、文件夹、媒体库、播放列表）。
    public var isContainer: Bool {
        switch self {
        case .series, .season, .boxSet, .folder, .collectionFolder, .playlist,
             .playlistsFolder, .manualPlaylistsFolder, .userView, .userRootFolder,
             .aggregateFolder, .basePluginFolder, .musicAlbum, .photoAlbum:
            true
        default:
            false
        }
    }

    // MARK: - Codable

    /// 从字符串解码；空串也降级为未知类型而不是报错。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = (try? container.decode(String.self)) ?? ""
    }

    /// 编码为原始字符串。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 图片类型，对应 Emby `BaseItemDto.ImageTags` 字典的 key（`ImageType` 枚举）。
///
/// 服务端实际返回的 key 是 PascalCase：`Primary`、`Backdrop`、`Logo`、`Thumb`、`Banner`、
/// `Art`、`Disc`、`Box`、`BoxRear`、`Chapter`、`Menu`、`Screenshot`、`Thumbnail`、
/// `LogoLight`、`LogoLightColor`
/// （<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Entities.ImageType.html>）。
///
/// 解码时**大小写不敏感**（`primary` / `PRIMARY` 都归一到 `.primary`），
/// 未知 key 保留原样，不会导致整条 `MediaItem` 解码失败。
public struct ImageKind: RawRepresentable, Sendable, Hashable, Codable, CodingKeyRepresentable {
    /// 归一化后的规范名（PascalCase）。
    public let rawValue: String

    /// 以规范名构造。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 以原始字符串构造，大小写不敏感地归一化到已知类型。
    public init(_ rawValue: String) {
        self = Self.canonical(for: rawValue)
    }

    /// 把任意大小写的 key 归一化成规范名；未知 key 原样保留。
    private static func canonical(for raw: String) -> ImageKind {
        switch raw.lowercased() {
        case "primary": ImageKind(rawValue: "Primary")
        case "backdrop": ImageKind(rawValue: "Backdrop")
        case "logo": ImageKind(rawValue: "Logo")
        case "thumb": ImageKind(rawValue: "Thumb")
        case "banner": ImageKind(rawValue: "Banner")
        case "art": ImageKind(rawValue: "Art")
        case "disc": ImageKind(rawValue: "Disc")
        case "box": ImageKind(rawValue: "Box")
        case "boxrear": ImageKind(rawValue: "BoxRear")
        case "chapter": ImageKind(rawValue: "Chapter")
        case "menu": ImageKind(rawValue: "Menu")
        case "screenshot": ImageKind(rawValue: "Screenshot")
        case "thumbnail": ImageKind(rawValue: "Thumbnail")
        case "logolight": ImageKind(rawValue: "LogoLight")
        case "logolightcolor": ImageKind(rawValue: "LogoLightColor")
        default: ImageKind(rawValue: raw)
        }
    }

    /// 主图（海报）。
    public static let primary = ImageKind(rawValue: "Primary")
    /// 背景图 / 剧照。
    public static let backdrop = ImageKind(rawValue: "Backdrop")
    /// 标题 logo。
    public static let logo = ImageKind(rawValue: "Logo")
    /// 缩略图。
    public static let thumb = ImageKind(rawValue: "Thumb")
    /// 横幅。
    public static let banner = ImageKind(rawValue: "Banner")
    /// 艺术图。
    public static let art = ImageKind(rawValue: "Art")
    /// 光盘图。
    public static let disc = ImageKind(rawValue: "Disc")
    /// 盒子封面。
    public static let box = ImageKind(rawValue: "Box")
    /// 盒子封底。
    public static let boxRear = ImageKind(rawValue: "BoxRear")
    /// 章节缩略图。
    public static let chapter = ImageKind(rawValue: "Chapter")
    /// 菜单图。
    public static let menu = ImageKind(rawValue: "Menu")
    /// 截图。
    public static let screenshot = ImageKind(rawValue: "Screenshot")

    // MARK: - Codable

    /// 解码时做大小写归一化。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.canonical(for: (try? container.decode(String.self)) ?? "")
    }

    /// 编码为规范名。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 媒体流类型，对应 `MediaStream.Type` 字段。
///
/// 服务端返回 PascalCase 字符串。Emby 的 `MediaStreamType` 枚举取值：
/// `Video`、`Audio`、`Subtitle`、`EmbeddedImage`、`Attachment`、`Data`、`Unknown`
/// （<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Entities.MediaStreamType.html>）。
/// Jellyfin 10.9 起还增加了 `Lyric`（<https://github.com/jellyfin/jellyfin/commit/ccede7d>），
/// 为兼容 Jellyfin 服务器一并收录。
///
/// 解码大小写不敏感，未知取值降级为 ``unknown(_:)``。
public struct StreamType: RawRepresentable, Sendable, Hashable, Codable {
    /// 归一化后的规范名。
    public let rawValue: String

    /// 以规范名构造。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 以原始字符串构造，大小写不敏感地归一化。
    public init(_ rawValue: String) {
        self = Self.canonical(for: rawValue)
    }

    private static func canonical(for raw: String) -> StreamType {
        switch raw.lowercased() {
        case "video": StreamType(rawValue: "Video")
        case "audio": StreamType(rawValue: "Audio")
        case "subtitle": StreamType(rawValue: "Subtitle")
        case "embeddedimage": StreamType(rawValue: "EmbeddedImage")
        case "attachment": StreamType(rawValue: "Attachment")
        case "data": StreamType(rawValue: "Data")
        case "lyric": StreamType(rawValue: "Lyric")
        case "unknown": StreamType(rawValue: "Unknown")
        default: StreamType(rawValue: raw)
        }
    }

    /// 视频轨。
    public static let video = StreamType(rawValue: "Video")
    /// 音频轨。
    public static let audio = StreamType(rawValue: "Audio")
    /// 字幕轨。
    public static let subtitle = StreamType(rawValue: "Subtitle")
    /// 内嵌图片（封面等）。
    public static let embeddedImage = StreamType(rawValue: "EmbeddedImage")
    /// 附件（字体等）。
    public static let attachment = StreamType(rawValue: "Attachment")
    /// 数据轨。
    public static let data = StreamType(rawValue: "Data")
    /// 歌词轨（Jellyfin 10.9+）。
    public static let lyric = StreamType(rawValue: "Lyric")

    /// 无法识别的类型，保留原始字符串。
    public static func unknown(_ rawValue: String) -> StreamType {
        StreamType(rawValue)
    }

    // MARK: - Codable

    /// 解码时做大小写归一化。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.canonical(for: (try? container.decode(String.self)) ?? "")
    }

    /// 编码为规范名。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
