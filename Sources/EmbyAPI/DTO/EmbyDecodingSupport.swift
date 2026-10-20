import Foundation
import PrismCore

/// 同时容忍「单个对象」与「单元素数组」的解码包装器。
///
/// 官方 Reference 有多处把对象标成数组（`AuthenticationResult.User`、`SessionInfo`、
/// `PlaybackInfoRequest.DeviceProfile`、`PlaybackProgressInfo.Item`…），
/// 而实际返回往往是单个对象（见 `docs/research/verified-facts.md` A4）。
///
/// 用法：
/// ```swift
/// let user = try container.decodeIfPresent(OneOrMany<EmbyUser>.self, forKey: .user)?.value
/// ```
///
/// 解码顺序：先按单个对象解，失败再按数组取第一个元素；两种都失败时 `value == nil`
/// （**不抛错**，与 PrismCore 的容错约定一致）。
///
/// - Note: 该类型只在本模块内部使用，不属于公开 API。
struct OneOrMany<Wrapped: Decodable>: Decodable {
    /// 解出的值；对象形态与数组形态都失败时为 `nil`。
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            self.value = nil
            return
        }
        if let single = try? container.decode(Wrapped.self) {
            self.value = single
            return
        }
        if let many = try? container.decode([Wrapped].self) {
            self.value = many.first
            return
        }
        self.value = nil
    }
}

// MARK: - 宽松解码工具（EmbyAPI 私有）

/// `PrismCore` 里那套 `decodeFlexible*` 是模块内可见的，EmbyAPI 无法直接调用，
/// 因此这里提供一份同名能力的本地版本（前缀 `emby`，避免与将来的公开 API 撞名）。
///
/// 约定与 PrismCore 完全一致：**字段缺失、类型不符一律返回 `nil`，绝不抛错**。
extension KeyedDecodingContainer {
    /// 宽松解码字符串：兼容 `String`、数字与布尔。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 字符串或 `nil`。
    func embyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    /// 宽松解码整数：兼容数字与数字字符串。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 整数或 `nil`。
    func embyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    /// 宽松解码 64 位整数：兼容数字与数字字符串。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 64 位整数或 `nil`。
    func embyInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        return nil
    }

    /// 宽松解码浮点数：兼容数字与数字字符串。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 浮点数或 `nil`。
    func embyDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    /// 宽松解码布尔：兼容 `true/false`、`1/0` 与 `"true"/"false"`。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 布尔值或 `nil`。
    func embyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// 宽松解码 ticks 数值。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: ``PrismCore/Ticks`` 或 `nil`。
    func embyTicks(forKey key: Key) -> Ticks? {
        guard let raw = embyInt64(forKey: key) else { return nil }
        return Ticks(raw)
    }

    /// 容错解码数组：字段缺失返回空数组，坏元素只丢自己。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 解码成功的元素数组，永不为 `nil`。
    func embyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard let raw = try? decodeIfPresent([EmbyLossy<T>].self, forKey: key) else { return [] }
        return raw.compactMap(\.value)
    }

    /// 容错解码单个对象：缺失或类型不符返回 `nil`。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 解出的对象或 `nil`。
    func embyObject<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// 容错数组的逐元素包装：坏元素解码为 `nil`，不牵连整条 DTO。
///
/// - Note: 仅在本模块内部使用。
struct EmbyLossy<Wrapped: Decodable>: Decodable {
    /// 解码成功的元素；失败为 `nil`。
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        self.value = try? Wrapped(from: decoder)
    }
}
