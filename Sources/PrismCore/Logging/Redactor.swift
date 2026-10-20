import Foundation

/// 日志脱敏工具。
///
/// Emby 的访问令牌会出现在三个地方：URL query（`?api_key=...`）、
/// 请求头（`X-Emby-Token` / `Authorization: Emby ..., Token="..."`）、
/// 以及登录请求体（`{"Pw":"..."}`）。这些内容一旦进日志就等于泄露凭证，
/// 因此**所有**日志输出都必须先过一遍本工具。
///
/// 用法：
/// ```swift
/// Redactor.redact("GET http://nas:8096/Items?api_key=ABC")
/// // "GET http://nas:8096/Items?api_key=***"
///
/// Redactor.redact(headers: ["X-Emby-Token": "ABC"])
/// // ["X-Emby-Token": "***"]
/// ```
public enum Redactor {
    /// 替换后的占位符。
    public static let placeholder = "***"

    /// 需要整体打码的请求头（小写比较）。
    private static let sensitiveHeaderNames: Set<String> = [
        "x-emby-token",
        "x-emby-authorization",
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key"
    ]

    /// 需要打码的 query / 表单参数名（小写比较）。
    private static let sensitiveParameterNames: Set<String> = [
        "api_key",
        "apikey",
        "api_token",
        "apitoken",
        "access_token",
        "accesstoken",
        "token",
        "x-emby-token",
        "pw",
        "password",
        "secret"
    ]

    // 关于 `nonisolated(unsafe)`：
    // `Regex` 在当前工具链下不是 `Sendable`，`static let` 会被 Swift 6 严格并发拦下。
    // 但 `Regex` 是不可变值类型，正则一旦编译完成就只做只读匹配，没有可变状态，
    // 因此用 `nonisolated(unsafe)` 声明为常量是安全的；同时避免了每次脱敏都重新编译正则
    // （日志与请求头脱敏是高频路径）。

    /// `key=value` 形式（query string、表单、URL）。
    private nonisolated(unsafe) static let parameterPattern = /(?i)(api_key|apikey|api_token|apitoken|access_token|accesstoken|x-emby-token|password|token|secret|pw)=([^&\s,;"']+)/

    /// `Key="value"` 形式（Emby 的 Authorization 头）。
    private nonisolated(unsafe) static let quotedPattern = /(?i)\b(token|password|pw|access_token)="([^"]*)"/

    /// `Header: value` 形式（整段请求头）。
    private nonisolated(unsafe) static let headerPattern = /(?i)(x-emby-token|x-emby-authorization|authorization|cookie|set-cookie)\s*:\s*([^\r\n]+)/

    /// 脱敏任意文本（URL、请求行、日志正文）。
    ///
    /// - Parameter text: 原始文本。
    /// - Returns: 令牌值被替换为 `***` 的文本。
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text.replacing(parameterPattern) { match in
            "\(match.1)=\(placeholder)"
        }
        result = result.replacing(quotedPattern) { match in
            "\(match.1)=\"\(placeholder)\""
        }
        result = result.replacing(headerPattern) { match in
            "\(match.1): \(placeholder)"
        }
        return result
    }

    /// 脱敏 URL，保留 scheme / host / path 与其余 query。
    ///
    /// - Parameter url: 原始 URL。
    /// - Returns: 脱敏后的 URL；若替换后无法再构成合法 URL，则退回原始 URL 的脱敏字符串。
    public static func redact(url: URL) -> URL {
        let text = url.absoluteString
        let redacted = redact(text)
        return URL(string: redacted) ?? url
    }

    /// 脱敏请求头字典：敏感头的值整体替换为 `***`，其余头的值做文本脱敏。
    ///
    /// - Parameter headers: 原始请求头。
    /// - Returns: 脱敏后的请求头。
    public static func redact(headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(headers.count)
        for (key, value) in headers {
            if sensitiveHeaderNames.contains(key.lowercased()) {
                result[key] = placeholder
            } else {
                result[key] = redact(value)
            }
        }
        return result
    }

    /// 脱敏日志元数据：敏感 key 的值整体替换为 `***`，其余值做文本脱敏。
    ///
    /// - Parameter metadata: 原始元数据。
    /// - Returns: 脱敏后的元数据。
    public static func redact(metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            let lowered = key.lowercased()
            let isSensitive = sensitiveParameterNames.contains(lowered)
                || sensitiveHeaderNames.contains(lowered)
                || lowered.contains("token")
                || lowered.contains("password")
            result[key] = isSensitive ? placeholder : redact(value)
        }
        return result
    }
}
