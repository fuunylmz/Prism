import PrismPlayback
import SwiftUI

// MARK: - 轨道展示模型

/// 一条音轨 / 字幕轨的**展示用**模型。
///
/// 存在的理由：引擎的 `TrackInfo` 是数据契约，菜单需要的是「语言 · 声道 · 码率」
/// 这类已经排版好的字符串。把排版收敛到这一个类型里，菜单视图就完全不认识引擎类型，
/// `#Preview` 也不需要构造引擎对象。
///
/// 由 `TrackInfo` 到本类型的映射集中在 `TrackMenu.swift` 末尾的
/// `PlayerTrack.init(track:kind:)`，引擎类型改名时只需要改那一处。
public struct PlayerTrack: Identifiable, Hashable, Sendable {
    /// 轨道类型。
    public enum Kind: Sendable, Hashable {
        /// 音轨。
        case audio
        /// 字幕轨。
        case subtitle
    }

    /// 引擎的轨道索引（`selectAudioTrack(_:)` / `selectSubtitleTrack(_:)` 的入参）。
    public let index: Int
    /// 轨道类型。
    public let kind: Kind
    /// 原始语言代码（ISO 639-2 或 BCP-47）。
    public let language: String?
    /// 轨道标题（容器里的 `title`，例如「English AAC」）。
    public let title: String?
    /// 编码，例如 `aac` / `dts` / `ass` / `hdmv_pgs_subtitle`。
    public let codec: String?
    /// 声道数（音轨）。
    public let channels: Int?
    /// 码率（bit/s，音轨）。
    public let bitrate: Int?
    /// 是否默认轨。
    public let isDefault: Bool
    /// 是否外挂轨。
    public let isExternal: Bool
    /// 是否为强制轨（forced，通常只翻译外语对白）。
    ///
    /// 同一部片子常有多条语言相同的字幕（完整轨 + 强制轨），不显示这个标记时
    /// 两行会完全一样，用户根本没法选。
    public let isForced: Bool

    /// `Identifiable` 要求的 id：轨道索引在同类轨道内唯一。
    public var id: Int { index }

    /// 创建展示模型。
    ///
    /// - Parameters:
    ///   - index: 引擎轨道索引。
    ///   - kind: 音轨 / 字幕轨。
    ///   - language: 语言代码。
    ///   - title: 轨道标题。
    ///   - codec: 编码。
    ///   - channels: 声道数。
    ///   - bitrate: 码率。
    ///   - isDefault: 是否默认轨。
    ///   - isExternal: 是否外挂轨。
    ///   - isForced: 是否强制轨。
    public init(
        index: Int,
        kind: Kind,
        language: String? = nil,
        title: String? = nil,
        codec: String? = nil,
        channels: Int? = nil,
        bitrate: Int? = nil,
        isDefault: Bool = false,
        isExternal: Bool = false,
        isForced: Bool = false
    ) {
        self.index = index
        self.kind = kind
        self.language = language
        self.title = title
        self.codec = codec
        self.channels = channels
        self.bitrate = bitrate
        self.isDefault = isDefault
        self.isExternal = isExternal
        self.isForced = isForced
    }

    // MARK: 文案

    /// 菜单主标题。
    ///
    /// 语言已知时优先用轨道名（它通常写明了「简体中文 / 繁体中文 / Signs」这类
    /// 区分信息），否则回退到语言名。轨道名与语言名相同时不会重复。
    public var displayName: String {
        trackName ?? languageName
    }

    /// 语言的中文名（未知时回退到标题，再回退到「未知语言」）。
    public var languageName: String {
        if let language, let name = Self.languageNames[language.lowercased()] {
            return name
        }
        if let language, !language.isEmpty, language.lowercased() != "und" {
            return language.uppercased()
        }
        if let title, !title.isEmpty {
            return title
        }
        return "未知语言"
    }

    /// 编码的大写展示名（`ass` → `ASS`，`hdmv_pgs_subtitle` → `PGS`）。
    public var codecName: String? {
        guard let codec, !codec.isEmpty else { return nil }
        switch codec.lowercased() {
        case "hdmv_pgs_subtitle", "pgs": return "PGS"
        case "dvd_subtitle", "vobsub": return "VobSub"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "eac3": return "E-AC3"
        case "ac3": return "AC3"
        case "truehd": return "TrueHD"
        case "dts", "dts-hd", "dtshd": return "DTS"
        case "flac": return "FLAC"
        case "aac": return "AAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        default: return codec.uppercased()
        }
    }

    /// 声道的展示名：2 → 立体声、6 → 5.1、8 → 7.1，其余显示原始数量。
    public var channelLayout: String? {
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "单声道"
        case 2: return "立体声"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels) 声道"
        }
    }

    /// 码率的展示名（`640 kbps`）；未知为 `nil`。
    public var bitrateText: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        return "\(Int((Double(bitrate) / 1000).rounded())) kbps"
    }

    /// 音轨的副标题：「语言 · 声道 · 码率」，缺项自动省略。
    public var audioDetail: String {
        var parts: [String] = [languageName]
        if let channelLayout { parts.append(channelLayout) }
        if let bitrateText { parts.append(bitrateText) }
        if let codecName { parts.append(codecName) }
        return parts.joined(separator: " · ")
    }

    /// 字幕轨的副标题：「语言 · 类型 · 内嵌/外挂 · 强制 · 轨道名」。
    ///
    /// 同一语言经常有多条轨（完整 / 强制 / SDH），只写「意大利语 · SRT · 内嵌」
    /// 会让两行完全一样、无法区分。因此把 `forced` 与容器里的轨道名都带上。
    public var subtitleDetail: String {
        var parts: [String] = [languageName]
        if let codecName { parts.append(codecName) }
        parts.append(isExternal ? "外挂" : "内嵌")
        if isForced { parts.append("强制") }
        if let trackName { parts.append(trackName) }
        return parts.joined(separator: " · ")
    }

    /// 容器里的轨道名；与语言名重复时返回 `nil`（避免「意大利语 · 意大利语」）。
    ///
    /// 引擎给的 `name` 常常就是语言名本身，直接拼上去只会更啰嗦。
    public var trackName: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 与语言展示名相同、或本身就是语言代码时没有额外信息量。
        if trimmed.caseInsensitiveCompare(languageName) == .orderedSame { return nil }
        if let language, trimmed.caseInsensitiveCompare(language) == .orderedSame { return nil }
        return trimmed
    }

    /// 菜单里显示的副标题（按轨道类型分派）。
    public var detail: String {
        switch kind {
        case .audio: audioDetail
        case .subtitle: subtitleDetail
        }
    }

    /// 常见语言代码到中文名的映射。
    ///
    /// Emby / mpv 混用 ISO 639-2（`eng` / `chi`）与 BCP-47（`en` / `zh-CN`），
    /// 这里两种都收，取不到就原样大写显示，不猜。
    private static let languageNames: [String: String] = [
        "zh": "中文", "zho": "中文", "chi": "中文", "zh-cn": "中文（简）",
        "zh-hans": "中文（简）", "zh-tw": "中文（繁）", "zh-hant": "中文（繁）",
        "yue": "粤语", "cantonese": "粤语",
        "en": "英语", "eng": "英语",
        "ja": "日语", "jpn": "日语",
        "ko": "韩语", "kor": "韩语",
        "fr": "法语", "fra": "法语", "fre": "法语",
        "de": "德语", "deu": "德语", "ger": "德语",
        "es": "西班牙语", "spa": "西班牙语",
        "it": "意大利语", "ita": "意大利语",
        "ru": "俄语", "rus": "俄语",
        "pt": "葡萄牙语", "por": "葡萄牙语",
        "th": "泰语", "tha": "泰语",
        "vi": "越南语", "vie": "越南语",
        "ar": "阿拉伯语", "ara": "阿拉伯语",
        "hi": "印地语", "hin": "印地语"
    ]
}

// MARK: - 音轨菜单

/// 音轨菜单（`docs/research/ux-benchmark.md` §3.12）。
///
/// - 每行显示「语言 · 声道 · 码率 · 编码」，当前项打勾；
/// - 底部说明解码路径：v1.0 全部是「引擎解码」，转码兜底时由调用方换成
///   「服务器转码为 AAC 立体声」的提示（本视图通过 ``footerNote`` 接收）；
/// - 没有音轨时给一句「该视频只有一条音轨」，而不是空白面板。
public struct AudioTrackMenu: View {
    private let tracks: [PlayerTrack]
    private let selectedIndex: Int?
    private let footerNote: String?
    private let onSelect: (Int) -> Void

    /// 创建音轨菜单。
    ///
    /// - Parameters:
    ///   - tracks: 音轨列表。
    ///   - selectedIndex: 当前音轨索引。
    ///   - footerNote: 底部说明（转码提示等），`nil` 时显示默认的「直通 · 引擎解码」。
    ///   - onSelect: 选择回调。
    public init(
        tracks: [PlayerTrack],
        selectedIndex: Int?,
        footerNote: String? = nil,
        onSelect: @escaping (Int) -> Void
    ) {
        self.tracks = tracks
        self.selectedIndex = selectedIndex
        self.footerNote = footerNote
        self.onSelect = onSelect
    }

    public var body: some View {
        PlayerMenuContainer(title: "音轨") {
            if tracks.isEmpty {
                PlayerMenuEmptyRow(text: "该视频只有一条音轨")
            } else {
                ForEach(tracks) { track in
                    PlayerMenuRow(
                        title: track.displayName,
                        detail: track.audioDetail,
                        isSelected: track.index == selectedIndex,
                        badge: track.isDefault ? "默认" : nil
                    ) {
                        onSelect(track.index)
                    }
                }
            }
        } footer: {
            Text(footerNote ?? "直通 · 引擎解码")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 字幕菜单

/// 字幕菜单（`docs/research/ux-benchmark.md` §3.11）。
///
/// 分区（自上而下）：
/// 1. **关闭字幕**（置顶，独立一行，当前关闭时打勾）；
/// 2. 轨道列表：「语言 · 类型 · 内嵌/外挂」，当前项打勾；
/// 3. **延迟**：`−0.1s` / 当前偏移 / `+0.1s` / 重置；
/// 4. 底部一行小字：ASS 复杂特效可能丢失（`docs/ARCHITECTURE.md` §3.5 坑 3）。
///
/// 延迟调整是**即时生效**的（只改偏移，不重建播放器、不重新请求）。
public struct SubtitleTrackMenu: View {
    private let tracks: [PlayerTrack]
    private let selectedIndex: Int?
    private let delay: Double
    private let onSelect: (Int?) -> Void
    private let onAdjustDelay: (Double) -> Void
    private let onResetDelay: () -> Void

    /// 创建字幕菜单。
    ///
    /// - Parameters:
    ///   - tracks: 字幕轨列表。
    ///   - selectedIndex: 当前字幕轨索引；`nil` 表示字幕关闭。
    ///   - delay: 当前字幕延迟（秒）。
    ///   - onSelect: 选择回调；`nil` 表示关闭字幕。
    ///   - onAdjustDelay: 延迟增量回调（±0.1）。
    ///   - onResetDelay: 延迟归零回调。
    public init(
        tracks: [PlayerTrack],
        selectedIndex: Int?,
        delay: Double,
        onSelect: @escaping (Int?) -> Void,
        onAdjustDelay: @escaping (Double) -> Void,
        onResetDelay: @escaping () -> Void
    ) {
        self.tracks = tracks
        self.selectedIndex = selectedIndex
        self.delay = delay
        self.onSelect = onSelect
        self.onAdjustDelay = onAdjustDelay
        self.onResetDelay = onResetDelay
    }

    public var body: some View {
        PlayerMenuContainer(title: "字幕") {
            PlayerMenuRow(
                title: "关闭字幕",
                detail: "不显示任何字幕",
                isSelected: selectedIndex == nil
            ) {
                onSelect(nil)
            }

            if tracks.isEmpty {
                PlayerMenuEmptyRow(text: "该视频没有字幕")
            } else {
                PlayerMenuDivider()
                ForEach(tracks) { track in
                    PlayerMenuRow(
                        title: track.displayName,
                        detail: track.subtitleDetail,
                        isSelected: track.index == selectedIndex,
                        badge: track.isDefault ? "默认" : nil
                    ) {
                        onSelect(track.index)
                    }
                }
            }

            PlayerMenuDivider()
            delaySection
        } footer: {
            // 坑 3：引擎只支持一部分 ASS 覆盖标签，\fad / \bord 会被丢弃。
            Text("复杂 ASS 特效（淡入淡出、描边）可能丢失")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 延迟调节区：`−0.1s` / 当前值 / `+0.1s` / 重置。
    private var delaySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text("字幕延迟")
                    .font(Typography.body)

                Spacer(minLength: Spacing.sm)

                PlayerStepButton(title: "−0.1s", isEnabled: delay > -30) {
                    onAdjustDelay(-PlayerKeyboardMap.subtitleDelayStep)
                }

                Text(delayText)
                    .font(Typography.monoTime)
                    .foregroundStyle(delay == 0 ? Palette.textSecondary : Palette.accent)
                    .frame(minWidth: 46)

                PlayerStepButton(title: "+0.1s", isEnabled: delay < 30) {
                    onAdjustDelay(PlayerKeyboardMap.subtitleDelayStep)
                }
            }

            if delay != 0 {
                Button("重置延迟") {
                    onResetDelay()
                }
                .buttonStyle(.link)
                .font(Typography.caption)
                .accessibilityLabel("重置字幕延迟")
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    /// 当前偏移的展示文案：`+0.3s` / `-0.1s` / `0.0s`。
    private var delayText: String {
        let sign = delay > 0 ? "+" : ""
        return String(format: "\(sign)%.1fs", delay)
    }
}

// MARK: - 菜单公共组件

/// 菜单容器：统一标题、宽度与内边距。
///
/// ## 为什么列表必须可滚动
///
/// 一部多语种片源可能有 20 条以上字幕轨。容器早期是纯 `VStack`，既没有滚动容器
/// 也没有高度上限，面板会被撑到超出屏幕、内容被裁掉——滚轮完全没有反应，
/// 用户只能看到最上面几条。现在列表放进 ``ScrollableMenuList``，标题与底部说明
/// 固定，中间区域按内容高度自适应并在超过上限后滚动。
private struct PlayerMenuContainer<Content: View, Footer: View>: View {
    let title: LocalizedStringKey
    let content: Content
    let footer: Footer

    init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.sm)

            ScrollableMenuList {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
            }

            Divider()

            footer
                .padding(.horizontal, Spacing.sm)
        }
        .padding(Spacing.md)
        .frame(width: 300)
    }
}

/// 可滚动的菜单列表：内容少时贴合内容高度，内容多时封顶并滚动。
///
/// 高度靠测量内容得出（`GeometryReader` + preference），而不是写死：
/// 只有一条音轨时不该留一大片空白，而有 20 条字幕轨时必须能滚动。
struct ScrollableMenuList<Content: View>: View {
    /// 列表区域的最大高度（pt）。加上标题与底部说明后，整个面板仍能放进笔记本屏幕。
    static var maxHeight: CGFloat { 320 }

    let content: Content

    /// 内容实际高度；初始取上限，避免首帧从 0 高度「弹开」。
    @State private var contentHeight: CGFloat = ScrollableMenuList.maxHeight

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// 把内容高度夹到 `1...maxHeight`。
    ///
    /// 抽成纯函数是为了能被单测覆盖：`ScrollView` 的滚动行为没法在离屏渲染里
    /// 验证（`ImageRenderer` 不绘制滚动内容），但「高度是否被封顶」可以。
    ///
    /// - Parameter measured: 测量到的内容高度。
    /// - Returns: 实际使用的列表高度。
    static func clampedHeight(for measured: CGFloat) -> CGFloat {
        guard measured.isFinite else { return maxHeight }
        return min(max(measured, 1), maxHeight)
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MenuContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .scrollIndicators(.automatic)
        // 内容比上限矮时不弹跳，避免「明明没得滚还回弹」。
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Self.clampedHeight(for: contentHeight))
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            guard height > 0 else { return }
            contentHeight = height
        }
    }
}

/// 菜单内容的测量高度。
private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 菜单行：标题 + 副标题 + 可选角标，选中时右侧打勾。
private struct PlayerMenuRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建菜单行。
    ///
    /// - Parameters:
    ///   - title: 主标题（语言名）。
    ///   - detail: 副标题（声道 / 编码 / 内嵌外挂）。
    ///   - isSelected: 是否当前项。
    ///   - badge: 行内角标（例如「默认」）。
    ///   - action: 点击回调。
    init(
        title: String,
        detail: String? = nil,
        isSelected: Bool,
        badge: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.xs) {
                        Text(title)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Palette.textSecondary.opacity(0.14))
                                }
                        }
                    }

                    if let detail {
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Spacing.sm)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.textPrimary.opacity(isHovering ? 0.07 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 菜单空态行。
private struct PlayerMenuEmptyRow: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 菜单分隔线。
private struct PlayerMenuDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 2)
    }
}

/// 延迟调节的小步进按钮。
private struct PlayerStepButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    /// 创建步进按钮。
    ///
    /// - Parameters:
    ///   - title: 按钮文字（例如 `+0.1s`）。
    ///   - isEnabled: 是否可用。
    ///   - action: 点击回调。
    init(title: String, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Palette.textPrimary.opacity(isHovering ? 0.14 : 0.08))
                }
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - 预览

#Preview("音轨菜单") {
    AudioTrackMenu(
        tracks: [
            PlayerTrack(index: 1, kind: .audio, language: "chi", codec: "aac", channels: 2, bitrate: 192_000, isDefault: true),
            PlayerTrack(index: 2, kind: .audio, language: "jpn", codec: "dts", channels: 6, bitrate: 1_536_000),
            PlayerTrack(index: 3, kind: .audio, language: "eng", codec: "truehd", channels: 8, bitrate: 4_000_000)
        ],
        selectedIndex: 2,
        onSelect: { _ in }
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .padding()
    .background(Palette.surfaceElevated)
}

#Preview("字幕菜单 · 有轨道") {
    SubtitleTrackMenu(
        tracks: [
            PlayerTrack(index: 4, kind: .subtitle, language: "chi", codec: "ass", isDefault: true),
            PlayerTrack(index: 5, kind: .subtitle, language: "eng", codec: "hdmv_pgs_subtitle"),
            PlayerTrack(index: 100_000, kind: .subtitle, language: "jpn", codec: "srt", isExternal: true)
        ],
        selectedIndex: 5,
        delay: 0.3,
        onSelect: { _ in },
        onAdjustDelay: { _ in },
        onResetDelay: {}
    )
    .prismTheme(PrismTheme(appearance: .dark))
    .padding()
    .background(Palette.surfaceElevated)
}

#Preview("字幕菜单 · 无轨道") {
    SubtitleTrackMenu(
        tracks: [],
        selectedIndex: nil,
        delay: 0,
        onSelect: { _ in },
        onAdjustDelay: { _ in },
        onResetDelay: {}
    )
    .prismTheme(PrismTheme(appearance: .light))
    .padding()
    .background(Palette.surfaceElevated)
}

// MARK: - 引擎轨道 → 展示模型

extension TrackInfo {
    /// 传给引擎 / 用于比较的轨道索引。
    ///
    /// 引擎的 `selectAudioTrack(_:)` 要的是 ``TrackInfo/id``（容器内的 stream index），
    /// **不是数组下标**；视图模型里的 `selectedAudioIndex` 也用它比较。
    var playerIndex: Int { id }
}

public extension PlayerTrack {
    /// 从引擎的 ``PrismPlayback/TrackInfo`` 构造展示模型。
    ///
    /// 这是**唯一**把引擎类型翻译成菜单文案的地方：引擎字段改名时只改这里。
    ///
    /// - Note: ``PrismPlayback/TrackInfo`` 没有码率字段（只有 Emby 的 `MediaStream` 有），
    ///   所以菜单显示「语言 · 声道 · 编码」；码率留到 v1.1 由协商层补充进 `TrackInfo`
    ///   之后再显示（``bitrate`` 字段已经预留）。
    ///
    /// - Parameter track: 引擎轨道。
    init(track: TrackInfo) {
        self.init(
            index: track.id,
            kind: track.kind == .audio ? .audio : .subtitle,
            language: track.language,
            title: track.title,
            codec: track.codec.isEmpty ? nil : track.codec,
            channels: track.channels > 0 ? track.channels : nil,
            bitrate: nil,
            isDefault: track.isDefault,
            isExternal: track.isExternal,
            isForced: track.isForced
        )
    }
}
