import Foundation
import PrismCore

/// 一次请求的日志载荷。
///
/// **不包含**请求体（登录体里有明文密码）与请求头（鉴权头里有令牌）；
/// 需要展示的 URL 在 ``message`` / ``metadata`` 里统一过 ``PrismCore/Redactor``。
struct RequestLogEntry: Sendable {
    /// HTTP 方法。
    let method: HTTPMethod

    /// 请求 URL（可能为 `nil`，仅在 URL 构造异常时）。
    let url: URL?

    /// HTTP 状态码；网络层失败（超时、连不上）时为 `nil`。
    let statusCode: Int?

    /// 本次尝试耗时（秒）。
    let duration: TimeInterval

    /// 已完成的重试次数（0 表示首次请求）。
    let retryCount: Int

    /// 失败原因；成功时为 `nil`。
    let error: EmbyError?

    /// 是否是「即将重试」的中间记录。
    let retrying: Bool

    /// 创建日志载荷。
    ///
    /// - Parameters:
    ///   - method: HTTP 方法。
    ///   - url: 请求 URL。
    ///   - statusCode: 状态码。
    ///   - duration: 耗时（秒）。
    ///   - retryCount: 已重试次数。
    ///   - error: 失败原因。
    ///   - retrying: 是否为重试前的中间记录，默认 `false`。
    init(
        method: HTTPMethod,
        url: URL?,
        statusCode: Int?,
        duration: TimeInterval,
        retryCount: Int,
        error: EmbyError?,
        retrying: Bool = false
    ) {
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.duration = duration
        self.retryCount = retryCount
        self.error = error
        self.retrying = retrying
    }

    /// 单行日志正文（未脱敏，写入前必须过 `Redactor`）。
    var message: String {
        var text = "\(method.rawValue) \(url?.absoluteString ?? "<无 URL>")"
        text += " -> \(statusCode.map(String.init) ?? "<无响应>")"
        text += " (\(Self.milliseconds(duration))ms, retries=\(retryCount))"
        if retrying {
            text += " retrying"
        }
        if let error {
            text += " error=\(error.debugDescription)"
        }
        return text
    }

    /// 结构化元数据（未脱敏，写入前必须过 `Redactor`）。
    var metadata: [String: String] {
        var result: [String: String] = [
            "method": method.rawValue,
            "duration_ms": Self.milliseconds(duration),
            "retries": String(retryCount)
        ]
        if let statusCode {
            result["status"] = String(statusCode)
        }
        if let url {
            result["url"] = url.absoluteString
            result["path"] = url.path
        }
        if let error {
            result["error"] = error.debugDescription
        }
        if retrying {
            result["retrying"] = "true"
        }
        return result
    }

    /// 把秒转成毫秒字符串（无小数）。
    ///
    /// - Parameter duration: 秒。
    /// - Returns: 毫秒字符串。
    private static func milliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.0f", duration * 1000)
    }
}

extension EmbyClient {
    /// 写一条请求日志。
    ///
    /// 脱敏在这里做，而不是依赖 `Logging` 的实现：`NoopLogger`、测试里的记录器
    /// 都可能是「不脱敏」的实现，一旦漏在实现侧，令牌就会以明文进日志。
    ///
    /// 记录内容：方法、脱敏后的 URL、状态码、耗时、重试次数、错误摘要。
    /// **不记录**请求体与请求头。
    ///
    /// - Parameter entry: 日志载荷。
    nonisolated func logRequest(_ entry: RequestLogEntry) {
        let level: LogLevel
        if entry.retrying {
            level = .warning
        } else if entry.error == nil {
            level = .info
        } else {
            level = .error
        }
        logger.log(
            level,
            Redactor.redact(entry.message),
            metadata: Redactor.redact(metadata: entry.metadata)
        )
    }

    /// 记录一次解码失败（HTTP 已 200，但字节解不开）。
    ///
    /// - Parameters:
    ///   - endpoint: 出错的端点（只记 path，不记 query）。
    ///   - error: 已归一化的解码错误。
    nonisolated func logDecodingFailure(endpoint: EmbyEndpoint, error: EmbyError) {
        logger.log(
            .error,
            Redactor.redact("\(endpoint.method.rawValue) \(endpoint.path) 解码失败 error=\(error.debugDescription)"),
            metadata: Redactor.redact(metadata: [
                "method": endpoint.method.rawValue,
                "path": endpoint.path,
                "error": error.debugDescription
            ])
        )
    }
}
