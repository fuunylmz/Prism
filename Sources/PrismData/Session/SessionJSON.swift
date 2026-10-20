import Foundation
import PrismCore

/// 会话与服务器列表共用的 JSON 编解码器。
///
/// **为什么必须自定义日期解码策略**
///
/// PrismCore 里两个模型的 `Codable` 是**不对称**的（均为冻结契约，本模块不能改）：
///
/// | 模型 | 编码 | 解码 |
/// |---|---|---|
/// | ``AuthSession`` | `encodeEmbyDateIfPresent` → ISO8601 **字符串** | `container.decodeIfPresent(Date.self, ...)` |
/// | ``ServerConnection`` | 同上 | 同上 |
///
/// 用默认的 `JSONDecoder`（`.deferredToDate`，期望 `Double` 秒数）去解字符串会抛
/// `typeMismatch`，而两处都套了 `try?`，结果是 **`createdAt` / `lastConnectedAt` 静默变成
/// `nil`**——不报错、不崩溃，只是数据悄悄丢了。这类 bug 在测试里表现为「排序莫名其妙」
/// （见 `SessionRegistryTests.sortsByRecentUse`）。
///
/// 解法：`.custom` 策略拦截所有 `Date` 解码，把 ISO8601 字符串（以及旧数据的
/// `Double` 秒数）都还原成 `Date`。编码侧不需要策略——两个模型都显式把日期写成字符串。
///
/// 精度：ISO8601 带 3 位小数秒（毫秒），亚毫秒部分会丢；对本场景（记录登录时间、
/// 上次连接时间）无影响。
enum SessionJSON {
    /// 构造编码器。
    ///
    /// 每次新建而不是共享单例：`JSONEncoder` / `JSONDecoder` 不是 `Sendable`，
    /// 共享就得加 `nonisolated(unsafe)`；而载荷只有几 KB，构造成本可以忽略。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // 稳定输出：同样的数据编出同样的字节，便于排查与将来做「载荷校验」。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// 构造解码器（带 Emby 风格的日期策略，见类型文档）。
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self),
               let date = EmbyDateDecoding.date(from: text) {
                return date
            }
            if let seconds = try? container.decode(Double.self) {
                // `.deferredToDate` 的产物（参考日起点的秒数），兼容旧数据。
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析日期"
            )
        }
        return decoder
    }
}
