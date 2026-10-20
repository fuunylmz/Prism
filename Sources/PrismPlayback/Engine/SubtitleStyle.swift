import Foundation

/// 8 位 RGBA 颜色。
///
/// 用整数通道而不是 `NSColor` / `CGColor`：字幕样式要跨层传递（设置项 → 播放层 → 渲染），
/// 值语义更省心，也便于序列化到设置文件。
public struct SubtitleColor: Sendable, Equatable, Hashable, Codable {
    /// 红通道。
    public var r: UInt8
    /// 绿通道。
    public var g: UInt8
    /// 蓝通道。
    public var b: UInt8
    /// 不透明度（255 = 完全不透明）。
    public var a: UInt8

    /// 完整初始化。
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 白色。
    public static let white = SubtitleColor(r: 255, g: 255, b: 255)
    /// 黑色。
    public static let black = SubtitleColor(r: 0, g: 0, b: 0)
    /// 半透明黑色（默认描边 / 背景）。
    public static let translucentBlack = SubtitleColor(r: 0, g: 0, b: 0, a: 160)
}

/// 字幕的整体位置。
public enum SubtitleAlignment: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// 底部（最常见的电影字幕位置）。
    case bottom
    /// 居中。
    case center
    /// 顶部。
    case top
}

/// 字幕样式偏好（用户设置，引擎无关）。
///
/// 字幕由 **Prism 自绘**：AetherEngine 只解码出 ``SubtitleCue``，没有任何「字幕样式」API
/// （`docs/ARCHITECTURE.md` §3.3 缺口）。因此这个类型完全由我们的渲染层消费，
/// ``PlaybackEngine/setSubtitleStyle(_:)`` 只负责保存，不影响引擎。
///
/// ## ASS 覆盖标签的支持边界（**实测结论，必读**）
///
/// 引擎只解析**一部分** ASS 行内覆盖标签（源码 `Subtitles/SubtitleRectText.swift` +
/// `docs/research/playback-spike-results.md` §2 实测，macOS 27 / AetherEngine 7.44.0）：
///
/// | 标签 | 含义 | 是否生效 |
/// |---|---|---|
/// | `\c` / `\1c` | 行内颜色（BGR） | ✅ 生效，`\c&H0000FF&` → 红色（BGR→RGB 正确） |
/// | `\b` / `\i` / `\u` / `\s` | 粗 / 斜 / 下划线 / 删除线 | ✅ 生效 |
/// | `\fn` / `\fs` | 字体名 / 字号 | ✅ 生效（进 ``SubtitleCue/TextRun``） |
/// | `\r` | 重置为样式 | ✅ 生效 |
/// | `\an` / `\pos` | 对齐 / 定位 | ✅ 生效（进 ``SubtitleCue/Placement``） |
/// | `\N` / `\n` / `\h` | 换行 / 软换行 / 硬空格 | ✅ 生效 |
/// | **`\fad` / `\fade`** | **淡入淡出** | ❌ **被完全丢弃**，没有任何淡入淡出信息 |
/// | **`\bord`** | **描边宽度** | ❌ 不支持（``outlineWidth`` 只能来自用户样式） |
/// | **`\shad`** | **阴影偏移** | ❌ 不支持（``shadowOffset`` 只能来自用户样式） |
/// | **`\fscx` / `\fscy`** | **缩放** | ❌ 不支持 |
/// | **`\fsp`** | **字距** | ❌ 不支持 |
/// | **`\iclip` / `\clip`** | **裁剪** | ❌ 不支持 |
///
/// 还有两条同样实测确认的限制：
/// 1. **Style 行里的 `Alignment` 不映射到 ``SubtitleCue/Placement``**——只有行内 `\an` / `\pos` 生效。
///    依赖样式定位的字幕会全部落在默认位置。
/// 2. **描边 / 阴影 / 字体（Style 行）完全不暴露**——`SubtitleCue` 里没有对应字段。
///
/// 对 UI 的含义：SRT / 基本 ASS 完全够用；**带特效的动漫 ASS 会丢淡入淡出与描边**，
/// 这是选型的已知代价（v1.0 接受）。自绘层可以用 ``outlineWidth`` / ``shadowOffset``
/// 给**所有**字幕统一加描边与阴影作为补偿，但无法还原作者逐条的 `\bord` / `\shad`。
///
/// - Important: ``overrideEmbeddedASS`` 为 `true` 时，用户样式优先于 cue 自带的行内样式；
///   为 `false` 时尊重作者排版（动漫 / 特效字幕必须 `false`）。
public struct SubtitleStyle: Sendable, Equatable {
    /// 字体名；`nil` = 跟随系统默认（`PingFang SC` / `Helvetica Neue` 之类）。
    public var fontName: String?

    /// 字号：相对 **1080p** 的像素值（渲染时按实际画面高度缩放）。
    public var fontSize: Double

    /// 正文颜色。
    public var primaryColor: SubtitleColor

    /// 描边颜色。
    public var outlineColor: SubtitleColor

    /// 背景色（半透明底衬；`a == 0` 表示不画背景）。
    public var backgroundColor: SubtitleColor

    /// 描边宽度（相对 1080p 的像素值；`0` = 不描边）。
    ///
    /// - Note: 引擎不支持 ASS 的 `\bord`（见类型文档），这个值只会作用于我们自己的渲染。
    public var outlineWidth: Double

    /// 阴影偏移（相对 1080p 的像素值；`0` = 不画阴影）。
    public var shadowOffset: Double

    /// 底部安全边距（相对 1080p 的像素值）。
    public var marginBottom: Double

    /// 整体位置。
    public var alignment: SubtitleAlignment

    /// 是否允许用户样式覆盖 ASS 内嵌样式。
    ///
    /// - `false`（默认）：尊重字幕作者排版——动漫 / 特效字幕必须用这个。
    /// - `true`：用户样式优先（普通观影偏好）。
    public var overrideEmbeddedASS: Bool

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - fontName: 字体名；`nil` = 系统默认。
    ///   - fontSize: 字号（相对 1080p 的像素）。
    ///   - primaryColor: 正文颜色。
    ///   - outlineColor: 描边颜色。
    ///   - backgroundColor: 背景色。
    ///   - outlineWidth: 描边宽度。
    ///   - shadowOffset: 阴影偏移。
    ///   - marginBottom: 底部边距。
    ///   - alignment: 整体位置。
    ///   - overrideEmbeddedASS: 是否覆盖 ASS 内嵌样式。
    public init(
        fontName: String? = nil,
        fontSize: Double = 44,
        primaryColor: SubtitleColor = .white,
        outlineColor: SubtitleColor = .black,
        backgroundColor: SubtitleColor = .init(r: 0, g: 0, b: 0, a: 0),
        outlineWidth: Double = 2,
        shadowOffset: Double = 0,
        marginBottom: Double = 48,
        alignment: SubtitleAlignment = .bottom,
        overrideEmbeddedASS: Bool = false
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.primaryColor = primaryColor
        self.outlineColor = outlineColor
        self.backgroundColor = backgroundColor
        self.outlineWidth = outlineWidth
        self.shadowOffset = shadowOffset
        self.marginBottom = marginBottom
        self.alignment = alignment
        self.overrideEmbeddedASS = overrideEmbeddedASS
    }

    /// 默认样式：白字黑边、底部、不覆盖作者排版。
    public static let `default` = SubtitleStyle()
}
