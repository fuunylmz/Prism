import EmbyAPI
import Foundation
import PrismCore

// MARK: - 媒体库类型

/// 一个服务端媒体库的内容形态。
///
/// 来源是 `/Users/{id}/Views` 返回的 `MediaView.collectionType`（Emby 的 `CollectionType`），
/// **不是库名**。早期实现按库名里的「剧 / tv / series」猜类型，猜不中就一律当电影，
/// 导致「点任何媒体库都进电影栏」——自定义命名的剧集库、音乐库、合集库全部被误判。
///
/// 类型决定三件事：网格查什么条目、页面标题、侧边栏归属。
///
/// - Note: 取值来源（已核实）：<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>
///   —— `movies`、`tvshows`、`music`、`games`、`books`、`musicvideos`、`homevideos`、
///   `livetv`、`channels`；`null` 表示混合文件夹。
public enum LibraryKind: String, Sendable, Hashable, CaseIterable {
    /// 电影库（`movies`）。
    case movies
    /// 剧集库（`tvshows`）。
    case series
    /// 合集 / 套装库（`boxsets`）。
    case boxsets
    /// 家庭视频库（`homevideos`）。
    case homeVideos
    /// 音乐视频库（`musicvideos`）。
    case musicVideos
    /// 音乐库（`music`）。
    case music
    /// 图书库（`books`）。
    case books
    /// 照片库（`photos`）。
    case photos
    /// 混合 / 未知类型：不限制条目类型，按视频浏览。
    case mixed

    /// 由服务端 `CollectionType` 映射。
    ///
    /// - Parameter collectionType: `/Views` 返回的 `CollectionType`；`nil` 表示混合文件夹。
    public init(collectionType: LibraryType?) {
        switch collectionType?.rawValue.lowercased() {
        case "movies": self = .movies
        case "tvshows": self = .series
        case "boxsets": self = .boxsets
        case "homevideos": self = .homeVideos
        case "musicvideos": self = .musicVideos
        case "music": self = .music
        case "books": self = .books
        case "photos": self = .photos
        default: self = .mixed
        }
    }

    /// 由 ``PrismCore/ItemType`` 映射（用于旧路由 / 预览数据的兼容）。
    ///
    /// - Parameter itemType: 条目类型。
    public init(itemType: ItemType) {
        switch itemType {
        case .series: self = .series
        case .boxSet: self = .boxsets
        case .musicAlbum, .audio, .musicArtist: self = .music
        case .book: self = .books
        case .photo, .photoAlbum: self = .photos
        case .musicVideo: self = .musicVideos
        default: self = .movies
        }
    }

    // MARK: 展示

    /// 页面标题 / 侧边栏标题。
    public var title: String {
        switch self {
        case .movies: "电影"
        case .series: "剧集"
        case .boxsets: "合集"
        case .homeVideos: "家庭视频"
        case .musicVideos: "音乐视频"
        case .music: "音乐"
        case .books: "图书"
        case .photos: "照片"
        case .mixed: "媒体库"
        }
    }

    /// SF Symbol 名称。
    public var systemImage: String {
        switch self {
        case .movies: "film"
        case .series: "tv"
        case .boxsets: "rectangle.stack"
        case .homeVideos: "video"
        case .musicVideos: "music.note.tv"
        case .music: "music.note"
        case .books: "book"
        case .photos: "photo"
        case .mixed: "square.grid.2x2"
        }
    }

    /// 计数单位（筛选栏的「共 N 部 / 张 / 项」）。
    public var countUnit: String {
        switch self {
        case .movies, .series, .boxsets, .homeVideos, .musicVideos: "部"
        case .music: "张"
        case .books, .photos, .mixed: "项"
        }
    }

    /// 该库在侧边栏中的固定归属；`nil` 表示只从首页进入。
    public var sidebarItem: SidebarItem? {
        switch self {
        case .movies: .movies
        case .series: .series
        default: nil
        }
    }

    // MARK: 查询

    /// 网格要请求的 `IncludeItemTypes`。
    ///
    /// 空数组表示不限制类型（混合库），由服务端返回全部可浏览条目。
    public var itemTypes: [ItemType] {
        switch self {
        case .movies: [.movie]
        case .series: [.series]
        case .boxsets: [.boxSet]
        case .homeVideos: [.video]
        case .musicVideos: [.musicVideo]
        case .music: [.musicAlbum]
        case .books: [.book]
        case .photos: [.photo]
        case .mixed: []
        }
    }

    /// 网格的媒体大类（决定 `MediaTypes` 与卡片形态）。
    public var mediaKind: MediaKind {
        switch self {
        case .music: .audio
        case .books: .book
        case .photos: .photo
        default: .video
        }
    }
}
