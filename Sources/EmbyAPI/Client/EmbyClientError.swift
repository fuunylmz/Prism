import Foundation
import PrismCore

/// 把网络层的原始失败归一化成 ``PrismCore/EmbyError`` 的**唯一**入口。
///
/// 本层**不新造错误类型**（契约要求全应用只用 `EmbyError`），只做三件事：
/// 1. 调用 `EmbyError.from(statusCode:body:)` / `EmbyError.from(urlError:)`；
/// 2. 补两条 PrismCore 未覆盖的映射（见下）；
/// 3. 截断过长的响应体，避免日志/UI 被整页 HTML 撑爆（``maxBodyLength``）。
///
/// 补充映射说明：
/// - `2xx` → `nil`（不是错误）。`EmbyError.from(statusCode:body:)` 无此语义，
///   它总是返回一个 case，因此调用方需要 ``error(statusCode:body:)`` 而不是直接用它。
/// - `5xx` 且响应体不是 JSON（例如反向代理返回的 HTML 错误页）→ 用截断后的正文
///   填充 `server(status:message:)` 的 `message`，否则诊断时只剩一个状态码。
///
/// 其余映射（401/403/404/408/5xx/URLError 各码）完全复用 PrismCore 的实现，
/// 见 `Sources/PrismCore/Errors/EmbyError.swift`。
public enum EmbyClientError {
    /// 错误信息里保留的响应体上限（字符数）。
    ///
    /// 512 是「够看清服务器说了什么」与「日志不爆炸」的折中：Emby 的错误体通常是
    /// 几十字节的 `{"Message":"..."}`，而反向代理的错误页动辄数 KB。
    public static let maxBodyLength = 512

    /// 把 HTTP 状态码映射成错误；`2xx` 返回 `nil`。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 原始响应体，用于提取 Emby 的 `Message` 字段或兜底展示正文。
    /// - Returns: 对应的 ``PrismCore/EmbyError``；成功状态码时为 `nil`。
    public static func error(statusCode: Int, body: Data?) -> EmbyError? {
        guard !(200...299).contains(statusCode) else { return nil }

        let mapped = EmbyError.from(statusCode: statusCode, body: body)
        // 非 JSON 正文：PrismCore 提取不到 Message，用截断后的正文兜底。
        if case let .server(status, message) = mapped, message == nil,
           let body, !body.isEmpty, let text = String(data: body, encoding: .utf8) {
            return .server(status: status, message: truncated(text))
        }
        return truncating(mapped)
    }

    /// 把 `URLError` 映射成错误。
    ///
    /// - Parameter urlError: 原始错误。
    /// - Returns: 对应的 ``PrismCore/EmbyError``。
    public static func error(urlError: URLError) -> EmbyError {
        truncating(EmbyError.from(urlError: urlError))
    }

    /// 把解码失败包装成 ``EmbyError/decoding(_:)``，并在描述里带上目标类型名。
    ///
    /// 类型名对排障很关键：`keyNotFound` 的默认描述里没有「我在解哪个 DTO」，
    /// 而同一层有几十个 DTO，缺了类型名几乎无法定位。
    ///
    /// - Parameters:
    ///   - type: 期望解码成的类型。
    ///   - underlying: 原始解码错误。
    /// - Returns: 形如 `解码 ClientFoo 失败：keyNotFound(...)` 的错误。
    public static func decoding(_ type: Any.Type, underlying: any Error) -> EmbyError {
        let name = String(describing: type)
        let detail = (underlying as? DecodingError).map(describe) ?? String(describing: underlying)
        return .decoding(truncated("解码 \(name) 失败：\(detail)"))
    }

    /// 把任意错误归一化（`EmbyError` 原样、`URLError` 走 ``error(urlError:)``）。
    ///
    /// - Parameter error: 任意错误。
    /// - Returns: 归一化后的错误。
    public static func normalized(_ error: any Error) -> EmbyError {
        if let urlError = error as? URLError {
            return self.error(urlError: urlError)
        }
        return truncating(EmbyError.from(error))
    }

    /// 截断文本，并保证结果长度不超过 `limit`。
    ///
    /// 先折叠连续空白（HTML 错误页全是缩进与换行），再按字符截断；
    /// 发生截断时末尾补一个 `…`，它计入 `limit`。
    ///
    /// - Parameters:
    ///   - text: 原始文本。
    ///   - limit: 上限，默认 ``maxBodyLength``。
    /// - Returns: 不超过 `limit` 个字符的文本。
    public static func truncated(_ text: String, limit: Int = maxBodyLength) -> String {
        guard limit > 0 else { return "" }
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// 对错误里携带的自由文本做截断（不改动状态码与 case）。
    ///
    /// - Parameter error: 原始错误。
    /// - Returns: 文本已截断的错误。
    public static func truncating(_ error: EmbyError) -> EmbyError {
        switch error {
        case let .server(status, message):
            .server(status: status, message: message.map { truncated($0) })
        case let .serverUnreachable(detail):
            .serverUnreachable(truncated(detail))
        case let .decoding(detail):
            .decoding(truncated(detail))
        case let .unknown(detail):
            .unknown(truncated(detail))
        case .invalidURL, .unauthorized, .forbidden, .notFound, .timeout, .cancelled:
            error
        }
    }

    /// 把 `DecodingError` 描述成「路径 + 原因」，便于定位是哪个字段。
    ///
    /// - Parameter error: 解码错误。
    /// - Returns: 单行描述。
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            "keyNotFound(\(key.stringValue) @ \(path(context.codingPath)))"
        case let .typeMismatch(type, context):
            "typeMismatch(\(type) @ \(path(context.codingPath)): \(context.debugDescription))"
        case let .valueNotFound(type, context):
            "valueNotFound(\(type) @ \(path(context.codingPath)))"
        case let .dataCorrupted(context):
            "dataCorrupted(@ \(path(context.codingPath)): \(context.debugDescription))"
        @unknown default:
            String(describing: error)
        }
    }

    /// 把 coding path 拼成 `Items[0].Id` 形式。
    ///
    /// - Parameter codingPath: 解码路径。
    /// - Returns: 可读路径；空路径返回 `<root>`。
    private static func path(_ codingPath: [any CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "<root>" : result
    }
}
