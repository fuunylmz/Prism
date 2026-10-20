import Foundation

/// Emby 日期字段的宽松解码工具。
///
/// Emby 服务端用 .NET 的 `DateTimeOffset` 序列化，实际抓包可见多种形态：
///
/// | 形态 | 样例 |
/// |---|---|
/// | 7 位小数秒 + `Z` | `"2024-04-10T04:24:53.0000000Z"` |
/// | 7 位小数秒 + 偏移 | `"2024-02-10T12:34:56.0000000+00:00"` |
/// | 3 位小数秒 + `Z` | `"2022-09-11T04:02:17.365Z"` |
/// | 不带小数秒 + 偏移 | `"2024-02-10T12:34:56+08:00"` |
/// | 不带时区 | `"2024-02-10T12:34:56"` |
/// | .NET 的零值 | `"0001-01-01T00:00:00.0000000Z"` |
///
/// 实测 `ISO8601DateFormatter` 的 `.withFractionalSeconds` 能解析 3~9 位小数秒，
/// 但**不能**解析不带小数秒的串；反过来不带 `.withFractionalSeconds` 的又解析不了
/// 带小数秒的串。因此这里按“带小数秒 → 不带小数秒 → 兜底格式表”的顺序依次尝试。
///
/// 关键约束：**任何失败都返回 `nil`，绝不抛错**，以免一个脏日期毁掉整条 `MediaItem` 解码。
public enum EmbyDateDecoding {
    // 关于 `nonisolated(unsafe)`：
    // `ISO8601DateFormatter` / `DateFormatter` 都不是 `Sendable`，`static let` 会被
    // Swift 6 严格并发拦下。但 Apple 官方保证：macOS 10.9 起，`NSDateFormatter`
    // 只要**不被修改**就是线程安全的（DateFormatter 文档 “Thread Safety” 一节；
    // ISO8601DateFormatter 继承自 Formatter，同样适用）。
    // 这里的每个 formatter 只在初始化闭包里配置一次，之后仅调用只读的 `date(from:)`，
    // 因此声明为不可变单例是安全且高效的（若改成每次新建实例，大列表解码时会有明显的
    // 格式化器构造成本）。`DateFormatter` 在当前 SDK 里已是 `Sendable`，只有
    // `ISO8601DateFormatter` 仍需 `nonisolated(unsafe)` 标注。

    /// 带小数秒的 ISO8601（`.withInternetDateTime` + `.withFractionalSeconds`）。
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 不带小数秒的 ISO8601。
    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 兜底：不带时区、不带小数秒。
    private static let noZoneFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// 兜底：不带时区、带小数秒。
    private static let noZoneFractionalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    /// 兜底：只有日期。
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 解析 ISO8601 字符串；失败返回 `nil`。
    ///
    /// - Parameter string: 待解析的字符串，前后空白会被裁掉。
    /// - Returns: 解析出的 `Date`，无法解析时为 `nil`。
    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = fractionalFormatter.date(from: trimmed) { return date }
        if let date = plainFormatter.date(from: trimmed) { return date }
        if let date = noZoneFractionalFormatter.date(from: trimmed) { return date }
        if let date = noZoneFormatter.date(from: trimmed) { return date }
        if let date = dateOnlyFormatter.date(from: trimmed) { return date }
        return nil
    }

    /// 把日期编码成 Emby 同款 ISO8601 字符串（带 7 位小数秒与 `Z`）。
    ///
    /// 之所以不直接 `encode(date)`：`JSONEncoder` 默认把 `Date` 编成
    /// “距 2001-01-01 的秒数”，既不是 Emby 的格式，也无法被本模块的宽松解码器读回
    /// （会被误当成 Unix 秒）。统一成 ISO8601 后编码 / 解码严格对称。
    ///
    /// - Parameter date: 待编码的日期。
    /// - Returns: 形如 `2024-04-10T04:24:53.0000000Z` 的字符串。
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// 从解码容器里宽松地取一个日期。
    ///
    /// 兼容 `String`、`Double`（Unix 秒）与 `null`；任何异常都返回 `nil`。
    ///
    /// - Parameter container: 解码容器。
    /// - Parameter key: 字段名。
    /// - Returns: 解析出的 `Date`，字段缺失或格式非法时为 `nil`。
    public static func date<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> Date? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return date(from: string)
        }
        if let epoch = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// 宽松解码日期：字段缺失、类型不符或格式非法一律返回 `nil`，不抛错。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 解析出的 `Date` 或 `nil`。
    public func decodeEmbyDateIfPresent(forKey key: Key) -> Date? {
        EmbyDateDecoding.date(from: self, forKey: key)
    }

    /// 宽松解码字符串数组：字段缺失或类型不符返回空数组。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 字符串数组，永不为 `nil`。
    public func decodeStringArrayIfPresent(forKey key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? []
    }

    /// 宽松解码 `[String: String]` 字典：字段缺失或类型不符返回空字典。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 字典，永不为 `nil`。
    public func decodeStringDictionaryIfPresent(forKey key: Key) -> [String: String] {
        (try? decodeIfPresent([String: String].self, forKey: key)) ?? [:]
    }
}

extension KeyedEncodingContainer {
    /// 按 Emby 的 ISO8601 字符串格式编码日期；`nil` 时跳过该字段。
    ///
    /// 与 ``KeyedDecodingContainer/decodeEmbyDateIfPresent(forKey:)`` 严格对称。
    ///
    /// - Parameters:
    ///   - date: 待编码的日期。
    ///   - key: 字段名。
    public mutating func encodeEmbyDateIfPresent(_ date: Date?, forKey key: Key) throws {
        guard let date else { return }
        try encode(EmbyDateDecoding.string(from: date), forKey: key)
    }
}
