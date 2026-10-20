import PrismCore
import SwiftUI

// MARK: - 键盘命令

/// 播放器内的一条键盘命令。
///
/// 把「按键 → 动作」的映射与「动作 → 视图模型方法」的执行分开，是为了让键位表
/// 可以被单独阅读、单独测试：``PlayerKeyboardMap`` 是纯函数，不依赖视图。
///
/// 键位来源：`docs/research/ux-benchmark.md` §4.6「播放器键盘映射表（37 条）」。
/// **导航键位不在这里**（⌘1/⌘2/⌘3、⌘F 等由 `AppShell/KeyboardShortcuts.swift` 负责），
/// 两者互不重叠。
public enum PlayerKeyboardCommand: Equatable, Sendable {
    /// 播放 / 暂停。
    case togglePlayPause
    /// 相对跳转（正数前进、负数后退）。
    ///
    /// - Note: 用例名刻意不写成重载的 `seek(by:)` / `seek(toFraction:)`——
    ///   Swift 6 对**同名重载枚举用例**的 `switch` 模式匹配有已知问题
    ///   （会按位置而非标签匹配，报「label must be …」），因此拆成两个不同名字。
    case seekBy(Ticks)
    /// 跳转到时长的某个比例（0...1）。
    case seekToFraction(Double)
    /// 音量相对调整（±0.05）。
    case adjustVolume(by: Double)
    /// 静音切换。
    case toggleMute
    /// 进入 / 退出全屏。
    case toggleFullScreen
    /// 字幕显示 / 隐藏。
    case toggleSubtitles
    /// 循环切换音轨。
    case cycleAudioTrack
    /// 循环切换字幕轨。
    case cycleSubtitleTrack
    /// 字幕延迟相对调整（秒）。
    case adjustSubtitleDelay(by: Double)
    /// 字幕延迟归零。
    case resetSubtitleDelay
    /// 上一集。
    case previousEpisode
    /// 下一集。
    case nextEpisode
    /// 倍速相对调整。
    case adjustRate(by: Double)
    /// 倍速复位到 1.0×。
    case resetRate
}

// MARK: - 键位表

/// 播放器键位表：把一次按键翻译成 ``PlayerKeyboardCommand``。
///
/// 这是 `docs/research/ux-benchmark.md` §4.6 在 UI 侧的**唯一实现**。
/// 本工单的工单文本对 §4.6 做了两处收窄，这里按工单执行并在注释里写明：
///
/// | 按键 | §4.6 | 本实现 | 理由 |
/// |---|---|---|---|
/// | `S` | 打开字幕菜单 | **字幕显示 / 隐藏** | 工单要求「S：字幕开关」；菜单仍可从控制条按钮打开 |
/// | `A` | 打开音轨菜单 | **循环切换音轨** | 工单要求「A：音轨切换（循环）」；菜单仍可从控制条按钮打开 |
/// | `[` / `]` | 倍速 −/+ | **字幕延迟 −/+ 0.1s** | 工单明确要求占用，注释见 ``command(for:)``；倍速改用 `>` / `<`（§4.6 第 34 条） |
///
/// 其余键位与 §4.6 完全一致，并为 mpv / IINA 的肌肉记忆保留等价绑定
/// （`K` 播放暂停、`J`/`L` ∓10s、`V` 字幕显隐、`Z`/`X` 字幕延迟、`C` 归零）。
///
/// **不占用 HIG 保护区**：`⌘F`、`⌘,`、`⌘I`、`⌘?`、`⌘W`、`⌘M`、`⌘Q`、`⌘Z/X/C/V/A`
/// 在这里一律不注册（`⌘←`/`⌘→` 是 IINA 的上一集 / 下一集，HIG 的 `⌘←` 只在文本
/// 上下文里切换键盘布局，播放器内无文本输入，因此安全）。
public enum PlayerKeyboardMap {
    /// 单次快进 / 快退步长（秒）。
    public static let seekStep: Double = 5
    /// 按住 ⇧ 的粗调步长（秒）。
    public static let coarseSeekStep: Double = 30
    /// `J` / `L` 的步长（秒）。
    public static let jumpStep: Double = 10
    /// 音量步长。
    public static let volumeStep: Double = 0.05
    /// 字幕延迟步长（秒）。
    public static let subtitleDelayStep: Double = 0.1
    /// 倍速步长。
    public static let rateStep: Double = 0.25

    /// 把一次按键翻译成命令；不认识的键返回 `nil`，交还给系统（`super`）。
    ///
    /// 优先级（§4.6.5 第 1 条）：带 `⌘` 的组合先判断，避免 `⌘←` 被当成 `←`；
    /// 带 `⌥` 的组合其次；纯字符键最后。
    ///
    /// - Parameter press: SwiftUI 的按键事件。
    /// - Returns: 对应命令；`nil` 表示本层不处理。
    public static func command(for press: KeyPress) -> PlayerKeyboardCommand? {
        let modifiers = press.modifiers

        // HIG 保护区：⌘ 组合一律不在这里处理（⌘← / ⌘→ 除外，见下）。
        if modifiers.contains(.command) {
            switch press.key {
            case .leftArrow: return .previousEpisode
            case .rightArrow: return .nextEpisode
            default: return nil
            }
        }
        if modifiers.contains(.control) {
            // ⌃⌘A / ⌃⌘S / ⌃⌘V（IINA 的循环音轨 / 字幕 / 视频轨）留给菜单命令层，
            // 这里不抢；⌃ 组合一律放行。
            return nil
        }

        // 方向键：⇧ 粗调、⌥ 精细音量（§4.6 第 3/5/13/14 条）。
        switch press.key {
        case .leftArrow:
            return .seekBy(Ticks(seconds: -(modifiers.contains(.shift) ? coarseSeekStep : seekStep)))
        case .rightArrow:
            return .seekBy(Ticks(seconds: modifiers.contains(.shift) ? coarseSeekStep : seekStep))
        case .upArrow:
            return .adjustVolume(by: modifiers.contains(.option) ? volumeStep / 5 : volumeStep)
        case .downArrow:
            return .adjustVolume(by: modifiers.contains(.option) ? -volumeStep / 5 : -volumeStep)
        default:
            break
        }

        // 字符键：⌥ 组合在本表里没有额外语义，统一放行给系统。
        if modifiers.contains(.option) { return nil }

        let characters = press.characters.lowercased()
        guard let first = characters.first else { return nil }

        // 数字键：`0`–`9` 跳到 0%–90%（§4.6 第 8 条，固定键位，不可自定义）。
        if let digit = first.wholeNumberValue, characters.count == 1 {
            return .seekToFraction(Double(digit) / 10)
        }

        switch first {
        case "k", " ":
            return .togglePlayPause
        case "j":
            return .seekBy(Ticks(seconds: -jumpStep))
        case "l":
            return .seekBy(Ticks(seconds: jumpStep))
        case "m":
            return .toggleMute
        case "f":
            return .toggleFullScreen
        case "s":
            // 工单要求 S = 字幕开关（§4.6 里 S 是打开菜单，见类型注释）。
            return .toggleSubtitles
        case "v":
            // §4.6 第 25 条：mpv / IINA 的字幕显隐，作为 S 的等价绑定。
            return .toggleSubtitles
        case "a":
            // 工单要求 A = 循环切换音轨（§4.6 里 A 是打开菜单）。
            return .cycleAudioTrack
        case "[":
            // ⚠️ 占用说明：mpv 里 `[` / `]` 是调速（−/+ 10%），IINA 同。
            // 本产品按工单把这两个键用于**字幕延迟**（mpv 的 `z`/`Z` 语义），
            // 调速改用 §4.6 第 34 条的 `>` / `<`，功能没有丢失。
            return .adjustSubtitleDelay(by: -subtitleDelayStep)
        case "]":
            return .adjustSubtitleDelay(by: subtitleDelayStep)
        case "z":
            // mpv / IINA 的字幕延迟（§4.6 第 26 条），作为 `[` 的等价绑定。
            return .adjustSubtitleDelay(by: -subtitleDelayStep)
        case "x":
            return .adjustSubtitleDelay(by: subtitleDelayStep)
        case "c":
            // §4.6 第 27 条：IINA 的字幕延迟归零。
            return .resetSubtitleDelay
        case ">", ".":
            // §4.6 第 34 条：`>` 加速；`.` 是 mpv 的逐帧前进，v1.0 用倍速承接。
            return .adjustRate(by: rateStep)
        case "<", ",":
            return .adjustRate(by: -rateStep)
        default:
            return nil
        }
    }
}

// MARK: - 键位说明表

/// 一条键位说明（用于帮助浮层与 `#Preview`）。
///
/// HIG 要求「快捷键能做的事，菜单/帮助里也要有」（§4.6.5 第 7 条）；
/// 这张表就是那个「帮助里也要有」的事实来源，键位改这里即可。
public struct PlayerKeyBinding: Identifiable, Sendable, Hashable {
    /// 稳定 id（按键展示串）。
    public let id: String
    /// 按键展示串，例如 `⇧←`。
    public let keys: String
    /// 动作说明。
    public let action: String
    /// 是否可自定义（§4.6 的「可自定义」列）。
    public let isCustomizable: Bool

    /// 创建键位说明。
    ///
    /// - Parameters:
    ///   - keys: 按键展示串。
    ///   - action: 动作说明。
    ///   - isCustomizable: 是否可自定义。
    public init(keys: String, action: String, isCustomizable: Bool = true) {
        self.id = keys
        self.keys = keys
        self.action = action
        self.isCustomizable = isCustomizable
    }
}

public extension PlayerKeyboardMap {
    /// 本播放器实际生效的全部键位。
    ///
    /// 与 ``command(for:)`` 一一对应；`1`–`9` / `0` 与 `Esc` 标为不可自定义
    /// （§4.6.5 第 6 条：避免用户把自己锁死或违反 HIG）。
    static let bindings: [PlayerKeyBinding] = [
        PlayerKeyBinding(keys: "空格 / K", action: "播放 / 暂停"),
        PlayerKeyBinding(keys: "← / →", action: "后退 / 前进 5 秒"),
        PlayerKeyBinding(keys: "⇧← / ⇧→", action: "后退 / 前进 30 秒"),
        PlayerKeyBinding(keys: "J / L", action: "后退 / 前进 10 秒"),
        PlayerKeyBinding(keys: "↑ / ↓", action: "音量 ±5%"),
        PlayerKeyBinding(keys: "⌥↑ / ⌥↓", action: "音量 ±1%"),
        PlayerKeyBinding(keys: "M", action: "静音"),
        PlayerKeyBinding(keys: "F", action: "进入 / 退出全屏"),
        PlayerKeyBinding(keys: "Esc", action: "退出全屏 → 关闭播放器", isCustomizable: false),
        PlayerKeyBinding(keys: "S / V", action: "字幕显示 / 隐藏"),
        PlayerKeyBinding(keys: "A", action: "循环切换音轨"),
        PlayerKeyBinding(keys: "[ / ]", action: "字幕延迟 ∓0.1 秒"),
        PlayerKeyBinding(keys: "Z / X", action: "字幕延迟 ∓0.1 秒（mpv 习惯）"),
        PlayerKeyBinding(keys: "C", action: "字幕延迟归零"),
        PlayerKeyBinding(keys: "0 – 9", action: "跳转到 0% – 90%", isCustomizable: false),
        PlayerKeyBinding(keys: "⌘← / ⌘→", action: "上一集 / 下一集"),
        PlayerKeyBinding(keys: "> / <", action: "加速 / 减速 0.25×"),
        PlayerKeyBinding(keys: ". / ,", action: "加速 / 减速 0.25×（mpv 习惯）")
    ]
}

// MARK: - 视图修饰符

/// 把播放器键位挂到视图上的修饰符。
///
/// 用法（``PlayerView`` 内部已经接好，外部一般不需要直接用）：
///
/// ```swift
/// content
///     .focusable()
///     .focused($isFocused)
///     .playerKeyboard(model, isFullScreen: isFullScreen, onToggleFullScreen: { ... })
/// ```
///
/// 实现要点：
/// - 用 SwiftUI 的 `.onKeyPress`（responder chain 的一部分），**不用全局
///   `NSEvent` 单例**——否则播放器关闭后仍会吞键（§4.6.5 第 5 条）；
/// - 未识别的键返回 `.ignored`，继续上抛给菜单系统；
/// - 每条命令执行前都会让控制条重新出现（键盘用户不该在「看不见的状态」下操作）。
public struct PlayerKeyboardModifier: ViewModifier {
    /// 视图模型。
    private let model: PlayerViewModel
    /// 当前是否全屏（`F` 的语义由它决定）。
    private let isFullScreen: Bool
    /// 切换全屏。
    private let onToggleFullScreen: () -> Void
    /// 上一集 / 下一集是否可用。
    private let canGoPrevious: Bool
    private let canGoNext: Bool
    /// 上一集 / 下一集回调。
    private let onPrevious: () -> Void
    private let onNext: () -> Void

    /// 创建修饰符。
    ///
    /// - Parameters:
    ///   - model: 播放器视图模型。
    ///   - isFullScreen: 当前是否全屏。
    ///   - onToggleFullScreen: 切换全屏的回调。
    ///   - canGoPrevious: 是否存在上一集。
    ///   - canGoNext: 是否存在下一集。
    ///   - onPrevious: 上一集回调。
    ///   - onNext: 下一集回调。
    public init(
        model: PlayerViewModel,
        isFullScreen: Bool,
        onToggleFullScreen: @escaping () -> Void,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {}
    ) {
        self.model = model
        self.isFullScreen = isFullScreen
        self.onToggleFullScreen = onToggleFullScreen
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.onPrevious = onPrevious
        self.onNext = onNext
    }

    public func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard let command = PlayerKeyboardMap.command(for: press) else {
                return .ignored
            }
            perform(command)
            return .handled
        }
    }

    /// 执行命令。
    ///
    /// 所有会改变播放状态的动作都先让控制条出现（否则用户按了键却看不到反馈）。
    ///
    /// - Parameter command: 命令。
    private func perform(_ command: PlayerKeyboardCommand) {
        model.noteUserActivity()

        switch command {
        case .togglePlayPause:
            Task { await model.togglePlayPause() }

        case let .seekBy(delta):
            Task { await model.seek(by: delta) }

        case let .seekToFraction(fraction):
            Task { await model.seek(toFraction: fraction) }

        case let .adjustVolume(by: delta):
            Task { await model.adjustVolume(by: delta) }

        case .toggleMute:
            Task { await model.toggleMute() }

        case .toggleFullScreen:
            onToggleFullScreen()

        case .toggleSubtitles:
            Task { await model.toggleSubtitles() }

        case .cycleAudioTrack:
            Task { await model.cycleAudioTrack() }

        case .cycleSubtitleTrack:
            Task { await model.cycleSubtitleTrack() }

        case let .adjustSubtitleDelay(by: delta):
            Task { await model.adjustSubtitleDelay(by: delta) }

        case .resetSubtitleDelay:
            Task { await model.resetSubtitleDelay() }

        case .previousEpisode:
            guard canGoPrevious else { return }
            onPrevious()

        case .nextEpisode:
            guard canGoNext else { return }
            onNext()

        case let .adjustRate(by: delta):
            Task { await model.adjustRate(by: delta) }

        case .resetRate:
            Task { await model.setRate(1) }
        }
    }
}

public extension View {
    /// 挂载播放器键位（见 ``PlayerKeyboardMap``）。
    ///
    /// - Parameters:
    ///   - model: 播放器视图模型。
    ///   - isFullScreen: 当前是否全屏。
    ///   - onToggleFullScreen: 切换全屏的回调。
    ///   - canGoPrevious: 是否存在上一集。
    ///   - canGoNext: 是否存在下一集。
    ///   - onPrevious: 上一集回调。
    ///   - onNext: 下一集回调。
    /// - Returns: 已挂载键位的视图。
    func playerKeyboard(
        _ model: PlayerViewModel,
        isFullScreen: Bool,
        onToggleFullScreen: @escaping () -> Void,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            PlayerKeyboardModifier(
                model: model,
                isFullScreen: isFullScreen,
                onToggleFullScreen: onToggleFullScreen,
                canGoPrevious: canGoPrevious,
                canGoNext: canGoNext,
                onPrevious: onPrevious,
                onNext: onNext
            )
        )
    }
}

// MARK: - 预览

/// 键位表预览：左侧是完整键位，右侧是「按一个键看看映射到什么」。
///
/// 右侧不是假的示意图——它真的调用 ``PlayerKeyboardMap/command(for:)``，
/// 因此在预览里按键就能验证映射表（含 ⇧ / ⌥ / ⌘ 组合）。
private struct PlayerKeyboardPreviewBoard: View {
    @State private var lastKeys = "（按任意键）"
    @State private var lastCommand = "—"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("播放器键位")
                    .font(Typography.title)

                Text("来源：ux-benchmark §4.6；导航键位不在此表")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(PlayerKeyboardMap.bindings) { binding in
                            HStack(spacing: Spacing.sm) {
                                Text(binding.keys)
                                    .font(Typography.monoTime)
                                    .frame(width: 96, alignment: .leading)
                                Text(binding.action)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                Spacer(minLength: 0)
                                if !binding.isCustomizable {
                                    Text("固定")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Palette.textSecondary.opacity(0.8))
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
            .frame(width: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("按键测试")
                    .font(Typography.title)

                Text(lastKeys)
                    .font(Typography.monoTime)

                Text(lastCommand)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)

                Text(isFocused ? "已聚焦，请按键" : "点一下这里再按键")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(width: 240, height: 160, alignment: .topLeading)
            .background(Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .onKeyPress(phases: .down) { press in
                lastKeys = describe(press)
                if let command = PlayerKeyboardMap.command(for: press) {
                    lastCommand = "\(command)"
                    return .handled
                }
                lastCommand = "未映射（交还系统）"
                return .ignored
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 760, height: 560, alignment: .topLeading)
        .background(Palette.surface)
    }

    /// 把按键事件描述成可读字符串。
    ///
    /// - Parameter press: 按键事件。
    /// - Returns: 例如 `⇧←` 或 `⌘→`。
    private func describe(_ press: KeyPress) -> String {
        var text = ""
        if press.modifiers.contains(.command) { text += "⌘" }
        if press.modifiers.contains(.shift) { text += "⇧" }
        if press.modifiers.contains(.option) { text += "⌥" }
        if press.modifiers.contains(.control) { text += "⌃" }
        switch press.key {
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .space: text += "空格"
        default: text += press.characters
        }
        return text
    }
}

#Preview("播放器键位表 · 深色") {
    PlayerKeyboardPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("播放器键位表 · 浅色") {
    PlayerKeyboardPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
