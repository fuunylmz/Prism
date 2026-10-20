import Foundation
import PrismCore

/// 一次播放请求：引擎要的全部输入（冻结契约，见 `docs/ARCHITECTURE.md` §3）。
///
/// 由协商层（`Negotiation/`）产出，交给 ``PlaybackEngine/load(_:)``。
/// 这里**不含**任何引擎专属字段：换引擎时这个类型不需要改。
///
/// - Note: ``PlaybackMethod`` 由 `Negotiation/PlaybackMethod.swift` 定义，
///   本类型直接复用它（同一模块内），**不要**在 Engine 下重复定义。
public struct PlaybackRequest: Sendable, Equatable {
    /// 可直接交给引擎的**绝对** URL（协商层已按服务器根地址补全）。
    public let url: URL

    /// 本次播放选定的方式（直连 / 直封 / 转码）。
    ///
    /// - Note: 引擎本身不关心这个值——URL 已经决定了取流方式；
    ///   它主要供日志与「为什么转码」提示使用。
    public let method: PlaybackMethod

    /// 拉流时必须携带的 HTTP 头（Emby 鉴权头等）。
    ///
    /// - Note: Emby 的播放 URL 里通常已内嵌 `api_key`，所以多数场景这里是空字典；
    ///   非空时适配器会把它交给引擎的 HTTP 加载器。
    public let headers: [String: String]

    /// 起播位置（续播）。``Ticks/zero`` 表示从头开始。
    public let startPosition: Ticks

    /// 外挂字幕（已下载到本地或可直接访问的 URL）。
    ///
    /// - Note: 这些轨在 `load()` 时注册，因此**参与**字幕语言偏好与 PiP 原生渲染；
    ///   播放中追加的字幕请用 ``PlaybackEngine/setSubtitleFile(_:)``（仅宿主自绘）。
    public let externalSubtitles: [SubtitleTrack]

    /// 起播时选中的音轨序号（Emby `MediaStream.Index`，**不是数组下标**）；`nil` = 引擎自选。
    public let audioStreamIndex: Int?

    /// 起播时选中的字幕序号；`nil` = 关闭字幕。
    public let subtitleStreamIndex: Int?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - url: 绝对播放 URL。
    ///   - method: 播放方式。
    ///   - headers: 拉流 HTTP 头。
    ///   - startPosition: 起播位置。
    ///   - externalSubtitles: 外挂字幕列表。
    ///   - audioStreamIndex: 音轨序号。
    ///   - subtitleStreamIndex: 字幕序号。
    public init(
        url: URL,
        method: PlaybackMethod,
        headers: [String: String] = [:],
        startPosition: Ticks = .zero,
        externalSubtitles: [SubtitleTrack] = [],
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.startPosition = startPosition
        self.externalSubtitles = externalSubtitles
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
    }
}

/// 一条外挂字幕轨（`PlaybackRequest.externalSubtitles` 的元素）。
///
/// 与 Emby 的 `MediaStream`（``MediaStream``）区分开：那是服务器声明的元数据，
/// 这是「引擎真正能打开的字幕文件」。由协商层把前者转成后者（下载 / 直取地址）。
public struct SubtitleTrack: Sendable, Equatable, Identifiable, Hashable {
    /// 字幕格式提示。用于告诉引擎按什么格式解析（URL 的扩展名不可靠时尤其有用）。
    public enum Format: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// SubRip（`.srt`）。
        case srt
        /// Advanced SubStation Alpha（`.ass`）。
        case ass
        /// SubStation Alpha（`.ssa`）。
        case ssa
        /// WebVTT（`.vtt`）。
        case vtt
        /// PGS 等图形字幕（`.sup`）；引擎只能当图形轨处理。
        case pgs
        /// 无法识别；引擎会嗅探真实格式。
        case other

        /// 按 URL 扩展名推断格式。
        ///
        /// - Parameter url: 字幕地址。
        /// - Returns: 能识别时返回具体格式，否则 ``other``。
        public static func inferred(from url: URL) -> Format {
            switch url.pathExtension.lowercased() {
            case "srt", "subrip": .srt
            case "ass": .ass
            case "ssa": .ssa
            case "vtt", "webvtt": .vtt
            case "sup", "pgs": .pgs
            default: .other
            }
        }
    }

    /// 稳定标识（协商层生成，通常取 Emby 的 `MediaStream.Index` 字符串）。
    public let id: String

    /// 字幕文件地址（本地 `file://` 或服务器直取 `http(s)://`）。
    public let url: URL

    /// 菜单里显示的名字。
    public let title: String?

    /// ISO 639-1/2 语言代码（`eng`、`jpn`…）。
    public let language: String?

    /// 格式提示。
    public let format: Format

    /// 是否为强制字幕轨（forced）。
    public let isForced: Bool

    /// 是否为听障字幕（SDH）。
    public let isHearingImpaired: Bool

    /// 是否为默认字幕轨。
    public let isDefault: Bool

    /// 取字幕文件时需要单独携带的 HTTP 头；`nil` = 沿用 ``PlaybackRequest/headers``。
    public let httpHeaders: [String: String]?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 稳定标识。
    ///   - url: 字幕文件地址。
    ///   - title: 显示名。
    ///   - language: 语言代码。
    ///   - format: 格式提示；`nil` 时按扩展名推断。
    ///   - isForced: 是否强制轨。
    ///   - isHearingImpaired: 是否听障轨。
    ///   - isDefault: 是否默认轨。
    ///   - httpHeaders: 单独的头；`nil` 沿用请求级头。
    public init(
        id: String,
        url: URL,
        title: String? = nil,
        language: String? = nil,
        format: Format? = nil,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        isDefault: Bool = false,
        httpHeaders: [String: String]? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.language = language
        self.format = format ?? Format.inferred(from: url)
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isDefault = isDefault
        self.httpHeaders = httpHeaders
    }
}
