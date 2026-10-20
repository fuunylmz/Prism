import Foundation
import PrismCore

// MARK: - HTTP 方法

/// Emby REST API 使用的 HTTP 方法。
public enum HTTPMethod: String, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

// MARK: - 端点协议（冻结契约）

/// 一个 Emby REST 端点。
///
/// **本文件由主管维护，属冻结契约，代理不得修改签名。**
/// `EmbyClient` 通过这个协议统一发出请求：拼接 `server.baseURL`、注入鉴权头、
/// 解析错误、脱敏日志。端点自身只描述「路径 + 参数 + 请求体」。
///
/// 设计要点：
/// - `body` 是已经编码好的 `Data?` 而非 `Encodable?`。原因是 Swift 6 下
///   `any Encodable` 不是 `Sendable`，无法安全穿过 actor 边界；端点负责用
///   ``EmbyJSON/encode(_:)`` 自己编码，`EmbyClient` 只负责发送字节。
/// - `query` 用 `[String: String]`（而非 `[URLQueryItem]`）便于按 key 覆盖与测试断言；
///   值为 `nil` 的项由端点自行省略。
public protocol EmbyEndpoint: Sendable {
    /// 以 `/` 开头的路径，例如 `/Users/{userId}/Items`。
    var path: String { get }

    /// HTTP 方法，默认 `.get`。
    var method: HTTPMethod { get }

    /// URL 查询参数，默认空。值会被百分号编码。
    var query: [String: String] { get }

    /// 已编码的请求体，默认 `nil`。
    var body: Data? { get }

    /// 请求体的 Content-Type，默认 `nil`（由 `EmbyClient` 按需补 `application/json`）。
    var contentType: String? { get }

    /// 是否需要携带鉴权头，默认 `true`。
    /// `/System/Info/Public` 与 `/Users/AuthenticateByName` 设为 `false`。
    var requiresAuth: Bool { get }

    /// 单次请求超时；`nil` 表示用 `EmbyClient` 的默认值。
    var timeout: TimeInterval? { get }

    /// 请求的缓存策略，默认 `.useProtocolCachePolicy`。
    /// 图片等可缓存资源建议用 `.returnCacheDataElseLoad`。
    var cachePolicy: URLRequest.CachePolicy { get }
}

public extension EmbyEndpoint {
    var method: HTTPMethod { .get }
    var query: [String: String] { [:] }
    var body: Data? { nil }
    var contentType: String? { nil }
    var requiresAuth: Bool { true }
    var timeout: TimeInterval? { nil }
    var cachePolicy: URLRequest.CachePolicy { .useProtocolCachePolicy }

    /// 把 `path` 与 `query` 拼成可直接用于日志/测试的相对路径。
    ///
    /// 返回形如 `/Users/abc/Items?Limit=20&Recursive=true`。
    /// key 按字典序排序，保证测试断言与日志可复现。
    ///
    /// - Note: 值使用 ``percentEncodedQueryValue`` 编码，空格会被编码为 `%20` 而非 `+`，
    ///   与 Emby 服务端的期望一致。
    func resolvedPath() -> String {
        guard !query.isEmpty else { return path }
        let pairs = query
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.percentEncodedQueryValue)" }
            .joined(separator: "&")
        return "\(path)?\(pairs)"
    }
}

// MARK: - JSON 编解码

/// Emby 请求/响应的统一 JSON 编解码器。
///
/// **不要设置 `keyDecodingStrategy`**：所有 DTO 自带 PascalCase 的 `CodingKeys`，
/// 全局转换会与它们冲突。
///
/// 日期策略为 `.iso8601`（宽松解码由 `PrismCore.EmbyDateDecoding` 在 DTO 层处理）。
public enum EmbyJSON {
    /// 用于请求体编码。字段名保持 Swift 属性名，由各 DTO 自己的 `CodingKeys` 决定输出。
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// 用于响应解码。
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

// MARK: - 查询值编码

extension String {
    /// 按 RFC 3986 的 query 规则百分号编码。
    ///
    /// `urlQueryAllowed` 会放行 `+`、`&`、`=` 等在 query 里有语义的字符，
    /// 因此这里显式排除它们。
    var percentEncodedQueryValue: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#[]")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}