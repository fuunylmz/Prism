import Foundation
import PrismCore

/// 用 `GET /System/Info/Public` 判断「这个地址真的是 Emby 吗」。
///
/// 该端点**不需要鉴权**，是连接校验的第一站
/// （✅ <https://dev.emby.media/reference/RestAPI/SystemService/getSystemInfoPublic.html>）。
///
/// 这里刻意**不依赖 `EmbyClient`**：`Client/` 与 `Endpoints/` 由其他代理并行开发，
/// 发现模块必须能独立编译、独立测试。等 `EmbyClient` 稳定后，这层可以整体替换成
/// 一个 `EmbyEndpoint` 实现，对外签名不变。
///
/// ## 错误映射
///
/// | 情况 | 抛出 |
/// |---|---|
/// | 超时 | ``PrismCore/EmbyError/timeout`` |
/// | 连不上 / DNS 失败 / 证书失败 | ``PrismCore/EmbyError/serverUnreachable(_:)`` |
/// | 404 / 401 / 403 / 5xx | 对应 case（由 ``PrismCore/EmbyError/from(statusCode:body:)`` 归一化） |
/// | 返回体不是预期 JSON（含 HTML 欢迎页、空对象） | ``PrismCore/EmbyError/decoding(_:)`` |
public struct ServerProbe: Sendable {
    /// 公开信息端点路径。
    public static let publicInfoPath = "/System/Info/Public"

    private let session: URLSession
    private let timeout: TimeInterval

    /// 创建探测器。
    ///
    /// - Parameters:
    ///   - session: 用于发请求的会话；测试可注入自定义配置。
    ///   - timeout: 单次请求超时，默认 10 秒（局域网连不上时 URLSession 自身
    ///     的等待会更久，这里显式给一个上限，避免 UI 卡在「正在连接」）。
    public init(session: URLSession = .shared, timeout: Duration = .seconds(10)) {
        self.session = session
        self.timeout = max(1, timeout.prismSeconds)
    }

    /// 请求公开信息并解析。
    ///
    /// - Parameter baseURL: 服务器基地址（已归一化，可带反代前缀如 `http://host/emby`）。
    /// - Returns: 解析后的公开信息。
    /// - Throws: 见类型文档里的错误映射表。
    public func fetchPublicInfo(baseURL: URL) async throws -> PublicServerInfo {
        guard let url = Self.publicInfoURL(for: baseURL) else { throw EmbyError.invalidURL }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw EmbyError.timeout
            case .cancelled:
                throw EmbyError.cancelled
            default:
                throw EmbyError.serverUnreachable(urlError.localizedDescription)
            }
        } catch is CancellationError {
            throw EmbyError.cancelled
        } catch {
            throw EmbyError.serverUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EmbyError.decoding("响应不是 HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            throw EmbyError.from(statusCode: http.statusCode, body: data)
        }

        let info: PublicServerInfo
        do {
            info = try EmbyJSON.decode(PublicServerInfo.self, from: Self.trimPadding(data))
        } catch {
            throw EmbyError.decoding(String(describing: error))
        }

        // `PublicServerInfo` 是宽松解码（缺字段退化为空串），所以「是合法 JSON 但根本
        // 不是 Emby」的情况要靠 Id 兜底判定：任何 Emby / Jellyfin 服务器都必然返回 Id。
        guard !info.id.isEmpty else {
            throw EmbyError.decoding("响应缺少 Id 字段，可能不是 Emby 服务器")
        }
        return info
    }

    /// 由基地址拼出公开信息端点 URL（保留反代路径前缀）。
    ///
    /// - Parameter baseURL: 基地址，例如 `http://host:8096/emby`。
    /// - Returns: `http://host:8096/emby/System/Info/Public`。
    public static func publicInfoURL(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + publicInfoPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// 裁掉响应体首尾的空白与 NUL 填充。
    ///
    /// 正常 Emby 服务器不会给响应体补 `\0`，但反向代理或某些中间层会（与 UDP 报文
    /// 同理）。`JSONDecoder` 容忍首尾空白却不容忍 `\0`，不裁的话会误判成「不是 Emby」。
    ///
    /// - Parameter data: 原始响应体。
    /// - Returns: 裁剪后的响应体。
    private static func trimPadding(_ data: Data) -> Data {
        func isPadding(_ byte: UInt8) -> Bool {
            byte == 0x00 || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        return Data(data.drop(while: isPadding).reversed().drop(while: isPadding).reversed())
    }
}
