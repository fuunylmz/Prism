import Foundation
import PrismCore

// MARK: - 结果条目

/// 搜索结果里的一条**可导航条目**（电影 / 剧集 / 单集 / 人物）。
///
/// 搜索接口返回的是混合类型的 ``PrismCore/MediaItem`` 与 ``PrismCore/Person``，
/// 而 UI（结果行、键盘导航、海报卡）需要统一的一等类型：
///
/// - 统一的 `id` / `title` / `subtitle`，便于高亮与键盘环；
/// - 统一的 `imageURL`，由 ``SearchViewModel`` 通过 ``SearchImageProviding`` 解析
///   （视图层不掌握服务器基址，不该自己拼图片地址）；
/// - 保留原始 ``mediaItem`` / ``person``，让「播放 / 续播」这类动作拿得到
///   `PlaybackPositionTicks`、`SeriesName` 等细节。
///
/// 本类型是纯值类型，`Sendable` + `Hashable`，可以安全地放进 `@State` 或跨 actor 传递。
public struct SearchResultItem: Identifiable, Hashable, Sendable {
    // MARK: 种类

    /// 结果条目的种类。
    ///
    /// 只收录 v1.0 搜索结果会出现的四类；合集（`BoxSet`）等由后续工单决定是否加入。
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// 电影。
        case movie
        /// 剧集（整部剧）。
        case series
        /// 单集。
        case episode
        /// 人物（演员 / 导演…）。
        case person

        /// 展示文案（分组标题、类型徽标）。
        public var title: String {
            switch self {
            case .movie: "电影"
            case .series: "剧集"
            case .episode: "单集"
            case .person: "人物"
            }
        }

        /// 类型图标（SF Symbol）。
        ///
        /// 全部是 macOS 15 起长期存在的符号，避免系统版本差异导致空白图标。
        public var systemImage: String {
            switch self {
            case .movie: "film"
            case .series: "tv"
            case .episode: "rectangle.stack"
            case .person: "person.crop.circle"
            }
        }

        /// 该类条目是否可以直接交给播放器。
        ///
        /// 剧集需要先选季 / 集，人物没有媒体源，两者都不在搜索结果里直接播放。
        public var isPlayable: Bool {
            self == .movie || self == .episode
        }

        /// 图片是否按圆形展示（人物头像为圆形，其余为矩形海报 / 缩略图）。
        public var usesCircularImage: Bool {
            self == .person
        }
    }

    // MARK: 存储属性

    /// 稳定 id：媒体条目 id 或人物 id。
    public let id: String

    /// 条目种类。
    public let kind: Kind

    /// 主标题（单集是集名，人物是姓名）。
    public let title: String

    /// 副标题（电影 / 剧集是「年份 · 时长」，单集是「剧名 · S01E02」，人物是身份）。
    public let subtitle: String?

    /// 海报 / 头像地址；`nil` 时视图显示占位图。
    public let imageURL: URL?

    /// 原始媒体条目；人物结果为 `nil`。
    public let mediaItem: MediaItem?

    /// 原始人物；媒体条目结果为 `nil`。
    public let person: Person?

    // MARK: 初始化

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 稳定 id。
    ///   - kind: 种类。
    ///   - title: 主标题。
    ///   - subtitle: 副标题，可选。
    ///   - imageURL: 海报 / 头像地址，可选。
    ///   - mediaItem: 原始媒体条目，可选。
    ///   - person: 原始人物，可选。
    public init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        imageURL: URL? = nil,
        mediaItem: MediaItem? = nil,
        person: Person? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.mediaItem = mediaItem
        self.person = person
    }

    /// 用媒体条目构造。
    ///
    /// 未知类型（服务端新增的类型）降级成 ``Kind/movie``，保证不会因为类型不认识就丢结果。
    ///
    /// - Parameters:
    ///   - item: 媒体条目。
    ///   - imageURL: 已解析的海报地址，可选。
    public init(item: MediaItem, imageURL: URL? = nil) {
        let kind: Kind
        switch item.type {
        case .series: kind = .series
        case .episode: kind = .episode
        default: kind = .movie
        }
        self.init(
            id: item.id,
            kind: kind,
            title: item.name,
            subtitle: Self.subtitle(for: item),
            imageURL: imageURL,
            mediaItem: item,
            person: nil
        )
    }

    /// 用人物构造。
    ///
    /// - Parameters:
    ///   - person: 人物。
    ///   - imageURL: 已解析的头像地址，可选。
    public init(person: Person, imageURL: URL? = nil) {
        self.init(
            id: person.id,
            kind: .person,
            title: person.name,
            subtitle: Self.subtitle(for: person),
            imageURL: imageURL,
            mediaItem: nil,
            person: person
        )
    }

    // MARK: 派生属性

    /// 是否可以直接交给播放器（剧集 / 人物为 `false`）。
    public var isPlayable: Bool {
        kind.isPlayable && mediaItem != nil
    }

    /// 续播点；新片为 ``PrismCore/Ticks/zero``。
    public var resumePosition: Ticks {
        mediaItem?.userData.playbackPosition ?? .zero
    }

    /// 是否有未看完的进度（用于「继续播放」文案）。
    public var isResumable: Bool {
        mediaItem?.isResumable ?? false
    }

    /// 图片是否按圆形展示。
    public var usesCircularImage: Bool {
        kind.usesCircularImage
    }

    /// 供 `.help(...)` 与 VoiceOver 使用的完整描述。
    public var accessibilityDescription: String {
        var parts = [kind.title, title]
        if let subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        return parts.joined(separator: "，")
    }

    // MARK: 私有工具

    /// 媒体条目的副标题：单集给「剧名 · S01E02」，其余给「年份 · 时长」。
    ///
    /// - Parameter item: 媒体条目。
    /// - Returns: 副标题；没有任何可用信息时为 `nil`。
    private static func subtitle(for item: MediaItem) -> String? {
        if item.type == .episode {
            var parts: [String] = []
            if let seriesName = item.seriesName, !seriesName.isEmpty {
                parts.append(seriesName)
            }
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                parts.append(String(format: "S%02dE%02d", season, episode))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        var parts: [String] = []
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if let duration = item.durationText {
            parts.append(duration)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 人物副标题：优先用角色名，其次用人物类型（`Actor` / `Director`…）。
    ///
    /// - Parameter person: 人物。
    /// - Returns: 副标题；两者都没有时为 `nil`。
    private static func subtitle(for person: Person) -> String? {
        if let role = person.role, !role.isEmpty {
            return role
        }
        if let type = person.type, !type.isEmpty {
            return type
        }
        return nil
    }
}
