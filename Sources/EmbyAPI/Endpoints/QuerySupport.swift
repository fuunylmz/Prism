import Foundation
import PrismCore

/// 端点内部使用的 query 参数累加器。
///
/// 存在的意义：Emby 的查询参数一律是「字符串键值对」，而 Swift 侧希望保持类型安全
/// （`Bool` / `Int` / 枚举数组）。这里统一负责：
/// - `nil` / 空值**不写入**（`EmbyEndpoint.query` 的约定：值为 `nil` 的项由端点自行省略）；
/// - `Bool` 写成小写 `true` / `false`（服务端按 `bool` 解析，大小写不敏感，但统一更好读）；
/// - 数组按 Emby 的两种分隔符拼接：多数用逗号，`Genres` / `Tags` / `OfficialRatings` /
///   `Studios` 用**竖线 `|`**（见 `docs/research/emby-api.md` §4.2 参数表）。
///
/// - Note: 仅本模块内部使用，不是公开 API。
struct QueryAccumulator {
    /// 已写入的参数。
    private(set) var values: [String: String] = [:]

    /// 写入字符串；`nil` 或空串跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名（PascalCase，与官方文档一致）。
    ///   - value: 参数值。
    mutating func put(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        values[key] = value
    }

    /// 写入布尔；`nil` 跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - value: 布尔值。
    mutating func put(_ key: String, _ value: Bool?) {
        guard let value else { return }
        values[key] = value ? "true" : "false"
    }

    /// 写入整数；`nil` 跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - value: 整数值。
    mutating func put(_ key: String, _ value: Int?) {
        guard let value else { return }
        values[key] = String(value)
    }

    /// 写入浮点数；`nil` 跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - value: 浮点值。
    mutating func put(_ key: String, _ value: Double?) {
        guard let value else { return }
        values[key] = String(value)
    }

    /// 写入 64 位整数；`nil` 跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - value: 64 位整数值。
    mutating func put(_ key: String, _ value: Int64?) {
        guard let value else { return }
        values[key] = String(value)
    }

    /// 写入枚举数组（逗号分隔）；空数组跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - items: 枚举值数组。
    mutating func putList<T: EmbyStringEnum>(_ key: String, _ items: [T]) {
        putStrings(key, items.map(\.rawValue))
    }

    /// 写入字符串数组（逗号分隔）；空数组跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - items: 字符串数组。
    mutating func putStrings(_ key: String, _ items: [String], separator: String = ",") {
        let joined = items.filter { !$0.isEmpty }.joined(separator: separator)
        guard !joined.isEmpty else { return }
        values[key] = joined
    }

    /// 写入整数数组（逗号分隔）；空数组跳过。
    ///
    /// - Parameters:
    ///   - key: 参数名。
    ///   - items: 整数数组。
    mutating func putInts(_ key: String, _ items: [Int]) {
        guard !items.isEmpty else { return }
        values[key] = items.map(String.init).joined(separator: ",")
    }
}

/// Emby 的两种日期字符串格式。
///
/// - `DatePlayed` 参数用 **`yyyyMMddHHmmss`**（无时区、无分隔符），
///   与响应里的 ISO8601 完全不同（已核实：
///   <https://dev.emby.media/reference/RestAPI/PlaystateService/postUsersByUseridPlayeditemsById.html>）。
///
/// - Note: 仅本模块内部使用。
enum EmbyDateFormat {
    /// 把日期格式化成 `DatePlayed` 期望的 `yyyyMMddHHmmss`。
    ///
    /// 【待验证】官方只给了格式串，没说明时区语义。这里按 **UTC** 格式化，
    /// 需在真实服务器上核对「标记已看」后 `LastPlayedDate` 的落库时间是否相差时区偏移。
    ///
    /// - Parameter date: 待格式化的日期。
    /// - Returns: 形如 `20261021143000` 的字符串。
    static func playedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}
