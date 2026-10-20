import Foundation

/// Prism 统一错误类型。
///
/// 设计目标：
/// 1. **UI 可直接展示**：`userMessage` 返回 `LocalizedStringResource`，由 String Catalog
///    在渲染时按用户语言解析，不在业务代码里拼字符串。
/// 2. **可判定是否值得重试**：`isRecoverable` 区分“网络抖动”与“权限/资源问题”。
/// 3. **网络层可统一归一化**：``from(statusCode:body:)`` 与 ``from(_:)``
///    把 HTTP 状态码和 `URLError` 收敛到同一套 case，避免各调用点各写一套判断。
///
/// 本地化 key 约定（待 `.xcstrings` 落地后直接建条目即可，代码内先给中文默认值）：
///
/// | key | 中文 | English |
/// |---|---|---|
/// | `error.invalidURL` | 服务器地址无效。 | The server address is invalid. |
/// | `error.unauthorized` | 登录已失效，请重新登录。 | Your session has expired. Please sign in again. |
/// | `error.forbidden` | 没有权限访问该内容。 | You do not have permission to access this content. |
/// | `error.notFound` | 找不到请求的内容。 | The requested content could not be found. |
/// | `error.serverUnreachable` | 无法连接到服务器。 | Unable to reach the server. |
/// | `error.timeout` | 连接超时，请检查网络后重试。 | The connection timed out. Please try again. |
/// | `error.decoding` | 服务器返回了无法识别的数据。 | The server returned data that could not be read. |
/// | `error.server` | 服务器出错了。 | The server reported an error. |
/// | `error.cancelled` | 操作已取消。 | The operation was cancelled. |
/// | `error.unknown` | 发生未知错误。 | An unknown error occurred. |
public enum EmbyError: Error, Sendable, Equatable, Hashable {
    /// 服务器地址无法构成合法 URL。
    case invalidURL
    /// 401：令牌无效或被吊销，应触发登出。
    case unauthorized
    /// 403：已登录但无权访问。
    case forbidden
    /// 404：资源不存在。
    case notFound
    /// 网络层无法连接到主机，附带底层描述。
    case serverUnreachable(String)
    /// 请求超时。
    case timeout
    /// 响应体解码失败，附带解码器描述。
    case decoding(String)
    /// 服务端返回的其他错误状态码。
    case server(status: Int, message: String?)
    /// 任务被取消（`Task.cancel()` / `URLError.cancelled`）。
    case cancelled
    /// 兜底：无法归类的错误。
    case unknown(String)

    /// 面向用户的本地化文案。
    ///
    /// 说明：当前 PrismCore 还没有 `Localizable.xcstrings`（加资源需要改 `Package.swift`，
    /// 属于受保护文件），因此先用 `defaultValue` 提供中文，English 文案见类型文档里的 key 表。
    /// 后续接入 String Catalog 时只需建条目，本属性的调用点无需改动。
    public var userMessage: LocalizedStringResource {
        switch self {
        case .invalidURL:
            LocalizedStringResource(
                "error.invalidURL",
                defaultValue: "服务器地址无效。",
                comment: "EN: The server address is invalid."
            )
        case .unauthorized:
            LocalizedStringResource(
                "error.unauthorized",
                defaultValue: "登录已失效，请重新登录。",
                comment: "EN: Your session has expired. Please sign in again."
            )
        case .forbidden:
            LocalizedStringResource(
                "error.forbidden",
                defaultValue: "没有权限访问该内容。",
                comment: "EN: You do not have permission to access this content."
            )
        case .notFound:
            LocalizedStringResource(
                "error.notFound",
                defaultValue: "找不到请求的内容。",
                comment: "EN: The requested content could not be found."
            )
        case let .serverUnreachable(detail):
            LocalizedStringResource(
                "error.serverUnreachable",
                defaultValue: "无法连接到服务器：\(detail)",
                comment: "EN: Unable to reach the server: %@"
            )
        case .timeout:
            LocalizedStringResource(
                "error.timeout",
                defaultValue: "连接超时，请检查网络后重试。",
                comment: "EN: The connection timed out. Please try again."
            )
        case .decoding:
            LocalizedStringResource(
                "error.decoding",
                defaultValue: "服务器返回了无法识别的数据。",
                comment: "EN: The server returned data that could not be read."
            )
        case let .server(status, message):
            if let message, !message.isEmpty {
                LocalizedStringResource(
                    "error.server.withMessage",
                    defaultValue: "服务器出错了（\(status)）：\(message)",
                    comment: "EN: The server reported an error (%lld): %@"
                )
            } else {
                LocalizedStringResource(
                    "error.server",
                    defaultValue: "服务器出错了（\(status)）。",
                    comment: "EN: The server reported an error (%lld)."
                )
            }
        case .cancelled:
            LocalizedStringResource(
                "error.cancelled",
                defaultValue: "操作已取消。",
                comment: "EN: The operation was cancelled."
            )
        case .unknown:
            LocalizedStringResource(
                "error.unknown",
                defaultValue: "发生未知错误。",
                comment: "EN: An unknown error occurred."
            )
        }
    }

    /// 是否属于“重试可能成功”的错误。
    ///
    /// 只有 `timeout`、`serverUnreachable`、`unknown` 为 `true`：
    /// 认证、权限、资源不存在、解码错误重试多少次都不会变好。
    public var isRecoverable: Bool {
        switch self {
        case .timeout, .serverUnreachable, .unknown:
            true
        case .invalidURL, .unauthorized, .forbidden, .notFound, .decoding, .server, .cancelled:
            false
        }
    }

    /// 是否应触发登出（清除本地会话并回到登录页）。
    public var requiresSignOut: Bool {
        self == .unauthorized
    }

    /// 调试用的技术描述（含底层原因，不含用户可见文案）。
    public var debugDescription: String {
        switch self {
        case .invalidURL: "invalidURL"
        case .unauthorized: "unauthorized(401)"
        case .forbidden: "forbidden(403)"
        case .notFound: "notFound(404)"
        case let .serverUnreachable(detail): "serverUnreachable(\(detail))"
        case .timeout: "timeout"
        case let .decoding(detail): "decoding(\(detail))"
        case let .server(status, message): "server(\(status), \(message ?? "nil"))"
        case .cancelled: "cancelled"
        case let .unknown(detail): "unknown(\(detail))"
        }
    }
}

// MARK: - 工厂方法

extension EmbyError {
    /// 把 HTTP 状态码与响应体归一化成 ``EmbyError``。
    ///
    /// 映射规则：
    /// - `401` → ``unauthorized``
    /// - `403` → ``forbidden``
    /// - `404` → ``notFound``
    /// - `408` → ``timeout``
    /// - `5xx` → ``server(status:message:)``（附带从响应体解析出的 `Message`）
    /// - 其余 → ``server(status:message:)``
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 原始响应体，用于提取 Emby 的错误描述（形如 `{"Message":"..."}`）。
    /// - Returns: 对应的错误。
    public static func from(statusCode: Int, body: Data?) -> EmbyError {
        let message = body.flatMap(extractMessage(from:))
        switch statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 408: return .timeout
        default: return .server(status: statusCode, message: message)
        }
    }

    /// 把 HTTP 状态码与字符串响应体归一化成 ``EmbyError``。
    ///
    /// 与 `body: Data?` 版本并存；这里刻意把参数声明成非可选 `String`，
    /// 以免调用处写 `body: nil` 时与 `Data?` 版本产生重载歧义。
    ///
    /// - Parameters:
    ///   - statusCode: HTTP 状态码。
    ///   - body: 响应体字符串。
    /// - Returns: 对应的错误。
    public static func from(statusCode: Int, body: String) -> EmbyError {
        from(statusCode: statusCode, body: body.data(using: .utf8))
    }

    /// 把 `URLError` 归一化成 ``EmbyError``。
    ///
    /// 映射规则：
    /// - `timedOut` → ``timeout``
    /// - `cannotConnectToHost` / `cannotFindHost` / `networkConnectionLost` /
    ///   `notConnectedToInternet` / `dnsLookupFailed` → ``serverUnreachable(_:)``
    /// - `cancelled` → ``cancelled``
    /// - 其余 → ``unknown(_:)``
    ///
    /// - Parameter urlError: 原始 `URLError`。
    /// - Returns: 对应的错误。
    public static func from(urlError: URLError) -> EmbyError {
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted:
            return .serverUnreachable(urlError.localizedDescription)
        case .cancelled:
            return .cancelled
        default:
            return .unknown(urlError.localizedDescription)
        }
    }

    /// 把任意错误归一化成 ``EmbyError``。
    ///
    /// `EmbyError` 原样返回；`URLError` 走 ``from(urlError:)``；
    /// `DecodingError` 归为 ``decoding(_:)``；其余归为 ``unknown(_:)``。
    ///
    /// - Parameter error: 任意错误。
    /// - Returns: 归一化后的错误。
    public static func from(_ error: any Error) -> EmbyError {
        switch error {
        case let embyError as EmbyError:
            return embyError
        case let urlError as URLError:
            return from(urlError: urlError)
        case let decodingError as DecodingError:
            return .decoding(String(describing: decodingError))
        case is CancellationError:
            return .cancelled
        default:
            return .unknown(error.localizedDescription)
        }
    }

    /// 从 Emby 的错误响应体里提取 `Message` 字段。
    ///
    /// - Parameter data: 原始响应体。
    /// - Returns: 提取到的消息；解析失败或没有该字段时为 `nil`。
    private static func extractMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let message = object["Message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}

extension EmbyError: LocalizedError {
    /// `LocalizedError` 的字符串描述，供 `error.localizedDescription` 使用。
    public var errorDescription: String? {
        String(localized: userMessage)
    }
}
