import CoreGraphics
import Foundation
import PrismCore

/// 播放失败。
///
/// 适配器把引擎的字符串错误包装成这个类型：`kind` 用于**分支判断**（可重试？换源？），
/// `message` 只用于日志与「技术详情」，不要拿它做判断（引擎的文案会随系统语言变化）。
public struct PlaybackFailure: Error, Sendable, Equatable, Hashable {
    /// 失败分类。
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// 加载失败（打开源、探测、建立会话）。
        case load
        /// 网络 / 连接层失败（可重试）。
        case network
        /// 媒体不受支持（编码 / 容器 / DRM）。
        case unsupportedMedia
        /// 解码失败（媒体损坏，或解码器拒绝）。
        case decode
        /// 被调用方取消（`Task.cancel()`），不是真失败。
        case cancelled
        /// 无法归类的失败。
        case unknown
    }

    /// 失败分类。
    public let kind: Kind

    /// 面向日志的原始描述（可能来自引擎 / AVFoundation，**不要**直接展示给用户）。
    public let message: String

    /// 上层是否值得自动重试（网络类失败为 `true`）。
    public let isRecoverable: Bool

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - kind: 失败分类。
    ///   - message: 原始描述。
    ///   - isRecoverable: 是否值得自动重试。
    public init(kind: Kind, message: String, isRecoverable: Bool = false) {
        self.kind = kind
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

extension PlaybackFailure: LocalizedError {
    /// 面向用户的描述（当前直接用 `message`，本地化文案由 UI 层负责）。
    public var errorDescription: String? { message }
}

/// 播放状态（冻结契约）。
///
/// 迁移规则由 ``PlaybackStateMachine`` 约束；非法迁移（如 ``ended`` → ``playing``）会被丢弃。
public enum PlaybackState: Sendable, Equatable {
    /// 无会话：未加载，或已 ``PlaybackEngine/stop()``。
    case idle
    /// 正在建立会话 / 起播 / 重建管线（切音轨也走这里）。
    case loading
    /// 正在播放。
    case playing
    /// 已暂停。
    case paused
    /// 播放中但缓冲不足（引擎状态仍是 `playing`，靠 `isBuffering` 区分）。
    case buffering
    /// 自然播到结尾（**终态**，不是 `idle`；重播要先重新 `load`）。
    case ended
    /// 失败（终态，直到下一次 `load`）。
    case failed(PlaybackFailure)

    /// 是否是终态（不会自己回到播放）。
    public var isTerminal: Bool {
        switch self {
        case .ended, .failed: true
        case .idle, .loading, .playing, .paused, .buffering: false
        }
    }

    /// 是否处于「有会话」的中间状态（`loading` / `playing` / `paused` / `buffering`）。
    public var isActive: Bool {
        switch self {
        case .loading, .playing, .paused, .buffering: true
        case .idle, .ended, .failed: false
        }
    }

    /// 失败原因（非失败态为 `nil`）。
    public var failure: PlaybackFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

/// 播放事件（冻结契约）。
///
/// 由 ``PlaybackEngine/events`` 发出，UI / 进度上报在 `@MainActor` 消费。
public enum PlaybackEvent: Sendable, Equatable {
    /// 状态迁移。
    case stateChanged(PlaybackState)

    /// 播放位置变化（**至少 4Hz**）。
    ///
    /// - Parameters:
    ///   - 位置: 当前播放位置。
    ///   - duration: 当前已知总时长；`0` 表示还不知道（见 §3.5 坑 1）。
    case positionChanged(Ticks, duration: Ticks)

    /// 总时长第一次可用 / 发生变化。
    ///
    /// - Note: `load()` 返回时引擎的 `duration` 还是 0，61ms 后才可用（§3.5 坑 1）；
    ///   这条事件就是「可以显示总时长了」的信号。
    case durationChanged(Ticks)

    /// 缓冲进度（0...1）。
    case bufferChanged(Double)

    /// 可选轨道列表变化（加载完成、切轨、外挂字幕增删）。
    case tracksChanged(audio: [TrackInfo], subtitle: [TrackInfo])

    /// 当前字幕 cue 列表变化。
    ///
    /// - Important: 时间轴**已经**施加了 ``PlaybackEngine/setSubtitleDelay(_:)`` 的偏移
    ///   （§3.5 坑 4：引擎的 `setSoftwareSubtitleDelay` 不管宿主自绘字幕，所以偏移由适配器负责）。
    case subtitleCues([SubtitleCue])

    /// 自然播完（与 ``stateChanged(_:)`` 的 ``PlaybackState/ended`` 同时发出，方便只关心结尾的调用方）。
    case ended

    /// 失败（与 ``stateChanged(_:)`` 的 ``PlaybackState/failed(_:)`` 同时发出）。
    case failed(PlaybackFailure)

    /// 如果是状态事件，取出其中的状态。
    public var state: PlaybackState? {
        if case .stateChanged(let state) = self { return state }
        return nil
    }

    /// 如果是位置事件，取出位置。
    public var position: Ticks? {
        if case .positionChanged(let position, _) = self { return position }
        return nil
    }
}

// MARK: - 字幕 cue

/// 一条字幕 cue（**Prism 自绘**用的中间表示）。
///
/// 字幕由 Prism 画，不由引擎画：引擎只负责把容器里的字幕解码成 cue
/// （文本 / 富文本 / 位图），样式完全由 ``SubtitleStyle`` 决定。
///
/// - Note: 位图字幕（PGS / DVB）暂不进入这个类型——它的载荷是 `CGImage`，
///   无法做成 `Equatable` 的值语义；图形字幕的渲染归 T3.6 处理。
public struct SubtitleCue: Sendable, Equatable, Identifiable {
    /// 一段同样式文本（对应 ASS 的行内覆盖标签）。
    public struct TextRun: Sendable, Equatable {
        /// 文本内容。
        public let text: String
        /// 颜色；`nil` = 跟随 ``SubtitleStyle/primaryColor``。
        public let color: SubtitleColor?
        /// 粗体（ASS `\b1`）。
        public let isBold: Bool
        /// 斜体（ASS `\i1`）。
        public let isItalic: Bool
        /// 下划线（ASS `\u1`）。
        public let isUnderlined: Bool
        /// 删除线（ASS `\s1`）。
        public let isStruckThrough: Bool
        /// 字体名（ASS `\fn`）；`nil` = 跟随 ``SubtitleStyle/fontName``。
        public let fontName: String?
        /// 字号（ASS `\fs`，相对 1080p 的像素值）；`nil` = 跟随 ``SubtitleStyle/fontSize``。
        public let fontSize: Double?

        /// 完整初始化。
        public init(
            text: String,
            color: SubtitleColor? = nil,
            isBold: Bool = false,
            isItalic: Bool = false,
            isUnderlined: Bool = false,
            isStruckThrough: Bool = false,
            fontName: String? = nil,
            fontSize: Double? = nil
        ) {
            self.text = text
            self.color = color
            self.isBold = isBold
            self.isItalic = isItalic
            self.isUnderlined = isUnderlined
            self.isStruckThrough = isStruckThrough
            self.fontName = fontName
            self.fontSize = fontSize
        }

        /// 是否带任何行内样式。
        public var isStyled: Bool {
            color != nil || isBold || isItalic || isUnderlined || isStruckThrough
                || fontName != nil || fontSize != nil
        }
    }

    /// cue 的正文。
    public enum Body: Sendable, Equatable {
        /// 纯文本。
        case text(String)
        /// 富文本（行内颜色 / 粗体 / 字体…）。
        case richText([TextRun])
    }

    /// 作者指定的位置（ASS `\an` / `\pos`）。
    ///
    /// - Note: 引擎只映射**行内** `\an` / `\pos`；Style 行里的 `Alignment` 不会进这里
    ///   （§3.5 坑 3）。`nil` 表示按 ``SubtitleStyle`` 的默认位置画。
    public struct Placement: Sendable, Equatable {
        /// ASS numpad 对齐（1 左下 … 9 右上，5 居中）。
        public let alignment: Int?
        /// 归一化坐标（相对播放分辨率，y 从顶部算）。
        public let position: CGPoint?

        /// 完整初始化。
        public init(alignment: Int? = nil, position: CGPoint? = nil) {
            self.alignment = alignment
            self.position = position
        }
    }

    /// 会话内唯一的 cue id（单调递增，用于 SwiftUI diff）。
    public let id: Int

    /// 起始时间（媒体时间轴）。
    public let start: Ticks

    /// 结束时间（媒体时间轴）。
    public let end: Ticks

    /// 正文。
    public let body: Body

    /// 作者指定的位置。
    public let placement: Placement?

    /// 完整初始化。
    public init(id: Int, start: Ticks, end: Ticks, body: Body, placement: Placement? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.body = body
        self.placement = placement
    }

    /// 展示时长。
    public var duration: Ticks { end - start }

    /// 纯文本（富文本按 run 拼接）；图形字幕没有文本，返回 `nil`。
    public var text: String? {
        switch body {
        case .text(let string): return string
        case .richText(let runs): return runs.map(\.text).joined()
        }
    }

    /// 施加字幕延迟，返回偏移后的 cue。
    ///
    /// 语义与引擎一致：**正延迟 = 字幕延后出现**（cue 整体后移），负延迟 = 提前。
    ///
    /// - Parameter delay: 延迟秒数。非有限值直接返回自身（视为无效输入）。
    /// - Returns: 偏移后的 cue；若整条 cue 都被推到 0 之前（`end <= 0`），返回 `nil` 表示这条不再显示。
    ///
    /// - Note: 这是 §3.5 坑 4 的实现核心：引擎的 `setSoftwareSubtitleDelay` 只作用于 software PiP，
    ///   宿主自绘字幕必须自己对时间轴施加偏移。
    public func shifted(by delay: Double) -> SubtitleCue? {
        guard delay.isFinite, delay != 0 else { return self }
        let delta = Ticks(seconds: delay)
        let shiftedEnd = end + delta
        guard shiftedEnd > .zero else { return nil }
        let shiftedStart = max(start + delta, .zero)
        return SubtitleCue(
            id: id,
            start: shiftedStart,
            end: shiftedEnd,
            body: body,
            placement: placement
        )
    }
}
