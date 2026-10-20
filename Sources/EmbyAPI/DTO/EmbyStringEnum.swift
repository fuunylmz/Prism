import Foundation
import PrismCore

/// Emby 的「字符串枚举」统一基座。
///
/// Emby 的枚举在 JSON 里一律是 PascalCase 字符串（`"Video"`、`"Hls"`、`"LessThanEqual"`…）。
/// 与 ``PrismCore/ItemType`` 的设计取舍相同：**不用封闭 `enum`**，因为
/// - 服务端会随版本新增取值（例如 `SubtitleDeliveryMethod` 4.x 多了 `VideoSideData`）；
/// - 封闭枚举遇到未知值只能解码失败或静默丢弃，会把整条 DTO 弄坏。
///
/// 这里用 `RawRepresentable` 的 struct 承载原始字符串，未知值原样保留（降级而不失败），
/// 并通过本协议的默认实现获得 `Codable`：解码空值 / 非字符串时得到 `rawValue == ""`。
///
/// 实现一个新枚举只需要：
/// ```swift
/// /// 对应 Emby 的 `Xxx`。
/// public struct Xxx: EmbyStringEnum {
///     public let rawValue: String
///     public init(rawValue: String) { self.rawValue = rawValue }
///     public static let a = Xxx(rawValue: "A")
/// }
/// ```
public protocol EmbyStringEnum: RawRepresentable, Sendable, Hashable, Codable where RawValue == String {
    /// 以原始字符串构造（与 `RawRepresentable` 的要求一致）。
    init(rawValue: String)
}

public extension EmbyStringEnum {
    /// 以原始字符串构造（省略 `rawValue:` 标签，便于调用处书写）。
    ///
    /// - Parameter rawValue: 服务端返回的原始字符串。
    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// 宽松解码：非字符串、`null` 都退化为空字符串，绝不抛错。
    ///
    /// - Parameter decoder: 解码器。
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? "")
    }

    /// 编码为原始字符串。
    ///
    /// - Parameter encoder: 编码器。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 复用 PrismCore 的开放类型

/// 让 ``PrismCore/ItemType`` 参与本模块的字符串枚举工具（用于 `IncludeItemTypes` 等逗号列表）。
///
/// `ItemType` 自带 `init(from:)` / `encode(to:)`，因此协议默认实现不会覆盖它的行为。
extension ItemType: EmbyStringEnum {}

/// 让 ``PrismCore/ImageKind`` 参与本模块的字符串枚举工具（用于 `EnableImageTypes`）。
extension ImageKind: EmbyStringEnum {}
