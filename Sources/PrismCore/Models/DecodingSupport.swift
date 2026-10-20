import Foundation

/// 容错数组解码的包装类型。
///
/// Emby 返回的数组里只要有一个元素解码失败（例如某个插件塞了脏数据），
/// 整个 `[T]` 就会解码失败并连带整条 `MediaItem` 报废。用 `[Lossy<T>]` 承接后
/// 可以逐元素降级：坏元素变成 `nil`，好元素照常保留。
struct Lossy<Wrapped: Decodable>: Decodable {
    /// 解码成功的元素；失败为 `nil`。
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// 容错解码数组：字段缺失返回空数组，单个元素失败只丢该元素。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 解码成功的元素数组，永不为 `nil`。
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard let wrappers = try? decodeIfPresent([Lossy<T>].self, forKey: key) else { return [] }
        return wrappers.compactMap(\.value)
    }

    /// 容错解码单个对象：类型不符或缺失都返回 `nil`，不抛错。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 解码出的对象或 `nil`。
    func decodeLossyObject<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// 宽松解码 `String`：兼容字符串与数字（部分插件会把 `Id` 写成数字）。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 字符串或 `nil`。
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    /// 宽松解码 `Int`：兼容数字与数字字符串（部分插件会写成 `"2024"`）。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 整数或 `nil`。
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    /// 宽松解码 `Int64`：兼容数字与数字字符串。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 64 位整数或 `nil`。
    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        return nil
    }

    /// 宽松解码 `Double`：兼容数字与数字字符串。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 浮点数或 `nil`。
    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    /// 宽松解码 `Bool`：兼容 `true/false` 与 `"true"/"1"/1`。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: 布尔值或 `nil`。
    func decodeFlexibleBool(forKey key: Key) -> Bool? {
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

    /// 宽松解码 `Ticks`：字段缺失或类型不符返回 `nil`。
    ///
    /// - Parameter key: 字段名。
    /// - Returns: ``Ticks`` 或 `nil`。
    func decodeTicksIfPresent(forKey key: Key) -> Ticks? {
        guard let raw = decodeFlexibleInt64(forKey: key) else { return nil }
        return Ticks(raw)
    }
}
