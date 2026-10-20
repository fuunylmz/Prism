import Foundation
import Observation

/// 播放质量预设。
public enum QualityPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 由服务器与网络状况自动决定。
    case auto
    /// 原码率直连（不转码）。
    case original
    /// 1080p。
    case p1080
    /// 720p。
    case p720

    /// `Identifiable` 要求。
    public var id: String { rawValue }

    /// 该预设对应的目标高度；`auto` / `original` 为 `nil`。
    public var targetHeight: Int? {
        switch self {
        case .auto, .original: nil
        case .p1080: 1080
        case .p720: 720
        }
    }

    /// 该预设对应的建议码率上限（Mbps）；`auto` / `original` 为 `nil`。
    public var suggestedBitrateMbps: Int? {
        switch self {
        case .auto, .original: nil
        case .p1080: 20
        case .p720: 8
        }
    }
}

/// 字幕显示策略。
public enum SubtitleMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 只要有字幕就显示。
    case always
    /// 只显示强制字幕（forced，通常用于外语对白的翻译）。
    case forced
    /// 仅在音轨语言与界面语言不同时显示。
    case foreign
    /// 从不自动显示。
    case never

    /// `Identifiable` 要求。
    public var id: String { rawValue }
}

/// 界面语言。
public enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 跟随系统。
    case system
    /// 简体中文。
    case zhHans
    /// 英文。
    case en

    /// `Identifiable` 要求。
    public var id: String { rawValue }

    /// 对应的 `Locale`；`system` 返回 `nil`（表示沿用当前环境）。
    public var locale: Locale? {
        switch self {
        case .system: nil
        case .zhHans: Locale(identifier: "zh-Hans")
        case .en: Locale(identifier: "en")
        }
    }
}

/// 应用设置，`UserDefaults` 持久化。
///
/// 设计要点：
/// - `@MainActor`：所有 UI 状态变更都在主 actor，符合 ROADMAP 的并发铁律；
/// - `@Observable`：SwiftUI 直接观察属性变化，不需要 `ObservableObject`；
/// - **每个属性在 `didSet` 里立刻写入 `UserDefaults`**，`init` 时读回，
///   因此进程被杀也不会丢设置；
/// - `subtitleScale` 与 `seekStepSeconds` 在 `didSet` 里做范围钳制；
/// - `reset()` 把全部属性恢复默认值（并覆盖已落盘的值）。
///
/// 测试注入独立 suite：
/// ```swift
/// if let defaults = UserDefaults(suiteName: "test.settings") {
///     let settings = AppSettings(defaults: defaults)
/// }
/// ```
@MainActor
@Observable
public final class AppSettings {
    /// 全局共享实例（App 与 UI 使用）。
    public static let shared = AppSettings()

    /// 用于持久化的 `UserDefaults`（测试可注入独立 suite）。
    private let defaults: UserDefaults

    /// 键名前缀，避免与其他模块的 key 冲突。
    private let keyPrefix: String

    // MARK: - 播放

    /// 首选播放质量。
    public var preferredQuality: QualityPreset {
        didSet { write(preferredQuality.rawValue, forKey: Keys.preferredQuality) }
    }

    /// 码率上限（Mbps）。`0` 表示不限制；负值会被钳到 `0`。
    public var maxBitrateMbps: Int {
        didSet {
            guard maxBitrateMbps >= 0 else {
                maxBitrateMbps = 0
                write(0, forKey: Keys.maxBitrateMbps)
                return
            }
            write(maxBitrateMbps, forKey: Keys.maxBitrateMbps)
        }
    }

    /// 首选音频语言（ISO 639-1/2 代码，如 `zh`、`eng`）；`nil` 表示自动。
    public var preferredAudioLanguage: String? {
        didSet { write(preferredAudioLanguage, forKey: Keys.preferredAudioLanguage) }
    }

    /// 首选字幕语言；`nil` 表示自动。
    public var preferredSubtitleLanguage: String? {
        didSet { write(preferredSubtitleLanguage, forKey: Keys.preferredSubtitleLanguage) }
    }

    // MARK: - 字幕

    /// 字幕显示策略。
    public var subtitleMode: SubtitleMode {
        didSet { write(subtitleMode.rawValue, forKey: Keys.subtitleMode) }
    }

    /// 字幕缩放比例，取值被钳制在 `0.5...2.0`。
    ///
    /// 超出范围时属性本身也会被改写成边界值（不只是持久化值），
    /// 这样 UI 上的滑块与真实设置始终一致。
    public var subtitleScale: Double {
        didSet {
            let clamped = min(max(subtitleScale, Self.subtitleScaleRange.lowerBound), Self.subtitleScaleRange.upperBound)
            if clamped != subtitleScale {
                subtitleScale = clamped
                write(clamped, forKey: Keys.subtitleScale)
                return
            }
            write(subtitleScale, forKey: Keys.subtitleScale)
        }
    }

    /// 是否给字幕加背景底色。
    public var subtitleBackground: Bool {
        didSet { write(subtitleBackground, forKey: Keys.subtitleBackground) }
    }

    // MARK: - 交互

    /// 快进 / 快退步长（秒），只接受 ``seekStepOptions`` 中的值（`5` / `10` / `30`）。
    ///
    /// 传入非法值时回退到 ``defaultSeekStepSeconds``。
    public var seekStepSeconds: Int {
        didSet {
            let clamped = Self.seekStepOptions.contains(seekStepSeconds) ? seekStepSeconds : Self.defaultSeekStepSeconds
            if clamped != seekStepSeconds {
                seekStepSeconds = clamped
                write(clamped, forKey: Keys.seekStepSeconds)
                return
            }
            write(seekStepSeconds, forKey: Keys.seekStepSeconds)
        }
    }

    /// 播完一集是否自动播放下一集。
    public var autoPlayNextEpisode: Bool {
        didSet { write(autoPlayNextEpisode, forKey: Keys.autoPlayNextEpisode) }
    }

    // MARK: - 外观

    /// 界面语言。
    public var language: AppLanguage {
        didSet { write(language.rawValue, forKey: Keys.language) }
    }

    // MARK: - 常量

    /// 字幕缩放的合法区间。
    public static let subtitleScaleRange: ClosedRange<Double> = 0.5...2.0
    /// 可选的快进步长。
    public static let seekStepOptions: [Int] = [5, 10, 30]
    /// 默认快进步长。
    public static let defaultSeekStepSeconds = 10

    /// `UserDefaults` 键名。
    private enum Keys {
        static let preferredQuality = "preferredQuality"
        static let maxBitrateMbps = "maxBitrateMbps"
        static let preferredAudioLanguage = "preferredAudioLanguage"
        static let preferredSubtitleLanguage = "preferredSubtitleLanguage"
        static let subtitleMode = "subtitleMode"
        static let subtitleScale = "subtitleScale"
        static let subtitleBackground = "subtitleBackground"
        static let seekStepSeconds = "seekStepSeconds"
        static let autoPlayNextEpisode = "autoPlayNextEpisode"
        static let language = "language"
    }

    /// 使用共享 `UserDefaults.standard` 创建。
    public convenience init() {
        self.init(defaults: .standard)
    }

    /// 使用指定 `UserDefaults` 创建（测试用）。
    ///
    /// - Parameters:
    ///   - defaults: 持久化容器。
    ///   - keyPrefix: 键名前缀，默认 `"prism.settings."`。
    public init(defaults: UserDefaults, keyPrefix: String = "prism.settings.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix

        // 先赋默认值再读回，避免 didSet 在初始化阶段写入。
        self.preferredQuality = Self.storedString(for: Keys.preferredQuality, in: defaults, prefix: keyPrefix)
            .flatMap(QualityPreset.init(rawValue:)) ?? .auto
        self.maxBitrateMbps = Self.storedInt(for: Keys.maxBitrateMbps, in: defaults, prefix: keyPrefix) ?? 0
        self.preferredAudioLanguage = Self.storedString(for: Keys.preferredAudioLanguage, in: defaults, prefix: keyPrefix)
        self.preferredSubtitleLanguage = Self.storedString(for: Keys.preferredSubtitleLanguage, in: defaults, prefix: keyPrefix)
        self.subtitleMode = Self.storedString(for: Keys.subtitleMode, in: defaults, prefix: keyPrefix)
            .flatMap(SubtitleMode.init(rawValue:)) ?? .foreign
        self.subtitleScale = Self.storedDouble(for: Keys.subtitleScale, in: defaults, prefix: keyPrefix)
            .map { min(max($0, Self.subtitleScaleRange.lowerBound), Self.subtitleScaleRange.upperBound) } ?? 1.0
        self.subtitleBackground = Self.storedBool(for: Keys.subtitleBackground, in: defaults, prefix: keyPrefix) ?? false
        let storedSeek = Self.storedInt(for: Keys.seekStepSeconds, in: defaults, prefix: keyPrefix) ?? Self.defaultSeekStepSeconds
        self.seekStepSeconds = Self.seekStepOptions.contains(storedSeek) ? storedSeek : Self.defaultSeekStepSeconds
        self.autoPlayNextEpisode = Self.storedBool(for: Keys.autoPlayNextEpisode, in: defaults, prefix: keyPrefix) ?? true
        self.language = Self.storedString(for: Keys.language, in: defaults, prefix: keyPrefix)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    // MARK: - 操作

    /// 恢复全部默认值（并覆盖已持久化的值）。
    public func reset() {
        preferredQuality = .auto
        maxBitrateMbps = 0
        preferredAudioLanguage = nil
        preferredSubtitleLanguage = nil
        subtitleMode = .foreign
        subtitleScale = 1.0
        subtitleBackground = false
        seekStepSeconds = Self.defaultSeekStepSeconds
        autoPlayNextEpisode = true
        language = .system
    }

    /// 清空本实例写入的全部键（测试收尾用）。
    public func removeAllPersistedValues() {
        for key in Self.allKeys {
            defaults.removeObject(forKey: keyPrefix + key)
        }
    }

    /// 全部键名（用于清理）。
    private static let allKeys: [String] = [
        Keys.preferredQuality,
        Keys.maxBitrateMbps,
        Keys.preferredAudioLanguage,
        Keys.preferredSubtitleLanguage,
        Keys.subtitleMode,
        Keys.subtitleScale,
        Keys.subtitleBackground,
        Keys.seekStepSeconds,
        Keys.autoPlayNextEpisode,
        Keys.language
    ]

    // MARK: - 读写

    /// 读取字符串值；不存在时为 `nil`。
    private static func storedString(for key: String, in defaults: UserDefaults, prefix: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    /// 读取 `Int` 值；不存在时为 `nil`。
    private static func storedInt(for key: String, in defaults: UserDefaults, prefix: String) -> Int? {
        defaults.object(forKey: prefix + key) as? Int
    }

    /// 读取 `Double` 值；不存在时为 `nil`。
    private static func storedDouble(for key: String, in defaults: UserDefaults, prefix: String) -> Double? {
        defaults.object(forKey: prefix + key) as? Double
    }

    /// 读取 `Bool` 值；不存在时为 `nil`。
    private static func storedBool(for key: String, in defaults: UserDefaults, prefix: String) -> Bool? {
        defaults.object(forKey: prefix + key) as? Bool
    }

    /// 写入字符串值；`nil` 表示移除。
    private func write(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: keyPrefix + key)
        } else {
            defaults.removeObject(forKey: keyPrefix + key)
        }
    }

    /// 写入 `Int` 值。
    private func write(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    /// 写入 `Double` 值。
    private func write(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    /// 写入 `Bool` 值。
    private func write(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: keyPrefix + key)
    }
}
