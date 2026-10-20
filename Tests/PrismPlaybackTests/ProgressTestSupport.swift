import EmbyAPI
import Foundation
import PrismCore
import Testing

@testable import PrismPlayback

// MARK: - URLProtocol 桩

/// 一条预设响应。
struct ProgressStubResponse: Sendable {
    /// HTTP 状态码。
    var statusCode: Int
    /// 响应体。
    var body: Data
    /// 非 `nil` 时以 `URLError` 失败（不产生 HTTP 响应，模拟断网）。
    var errorCode: URLError.Code?

    /// 成功（200 + 空 body）：三个上报端点的正常返回都是 200 + 空。
    static let ok = ProgressStubResponse(statusCode: 200, body: Data(), errorCode: nil)

    /// 断网。
    static func offline(_ code: URLError.Code = .notConnectedToInternet) -> ProgressStubResponse {
        ProgressStubResponse(statusCode: 0, body: Data(), errorCode: code)
    }
}

/// 一次被桩记录的请求。
struct ProgressRecordedRequest: Sendable {
    /// HTTP 方法。
    let httpMethod: String
    /// 完整 URL。
    let url: URL
    /// 请求体原始字节。
    let body: Data?

    /// URL 路径（不含 query），例如 `/Sessions/Playing/Progress`。
    var path: String { url.path }

    /// 请求体的 JSON 对象。
    var bodyJSON: [String: Any]? {
        guard let body, !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// 请求体的全部顶层 key（**顺序无关**，用于断言「没有多余字段」）。
    var bodyKeys: Set<String> {
        bodyJSON.map { Set($0.keys) } ?? []
    }

    /// 取字符串字段。
    ///
    /// - Parameter key: JSON 的 PascalCase 字段名。
    /// - Returns: 字段值；不存在或类型不符时为 `nil`。
    func string(_ key: String) -> String? {
        bodyJSON?[key] as? String
    }

    /// 取布尔字段。
    ///
    /// - Parameter key: JSON 的 PascalCase 字段名。
    /// - Returns: 字段值；不存在或类型不符时为 `nil`。
    func bool(_ key: String) -> Bool? {
        bodyJSON?[key] as? Bool
    }

    /// 取整数字段（JSON 数字一律是 `NSNumber`，因此统一走 `int64Value`）。
    ///
    /// - Parameter key: JSON 的 PascalCase 字段名。
    /// - Returns: 字段值；不存在或不是数字时为 `nil`。
    func integer(_ key: String) -> Int64? {
        (bodyJSON?[key] as? NSNumber)?.int64Value
    }
}

/// 基于 `URLProtocol` 的网络桩：**绝不发起真实网络**。
///
/// 与 `EmbyAPITests/MockURLProtocol.swift` 是同一套思路的独立副本——
/// 测试 target 之间不能互相 import，所以这里自己写一份（工单明确要求）。
///
/// 并行隔离靠 `X-Prism-Progress-Stub` 头把请求路由到各自的 ``ProgressStubServer``。
final class ProgressStubURLProtocol: URLProtocol {
    /// 路由头。
    static let routingHeader = "X-Prism-Progress-Stub"

    /// 全局路由表。
    static let registry = ProgressStubRegistry()

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.routingHeader),
              let server = Self.registry.server(id: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        server.record(
            ProgressRecordedRequest(
                httpMethod: request.httpMethod ?? "GET",
                url: request.url ?? URL(fileURLWithPath: "/"),
                body: Self.bodyData(of: request)
            )
        )

        let stub = server.currentResponse
        if let code = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// 读取请求体。
    ///
    /// - Parameter request: 被拦截的请求。
    /// - Returns: 请求体字节。
    /// - Note: `URLSession` 会把 `httpBody` 转成 `httpBodyStream`，
    ///   在 `URLProtocol` 里直接读 `httpBody` 往往拿到 `nil`，必须两路都试。
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// 一个可切换响应的桩服务器。
final class ProgressStubServer: @unchecked Sendable {
    /// 路由 id。
    let id = UUID().uuidString

    private let lock = NSLock()
    private var responses: [ProgressStubResponse]
    private var recorded: [ProgressRecordedRequest] = []

    /// 创建桩。
    ///
    /// - Parameters:
    ///   - response: 初始响应。
    ///   - queue: 可选的按序响应队列；耗尽后沿用最后一条。
    init(_ response: ProgressStubResponse = .ok, queue: [ProgressStubResponse]? = nil) {
        self.responses = queue ?? [response]
        ProgressStubURLProtocol.registry.register(self)
    }

    deinit {
        ProgressStubURLProtocol.registry.unregister(id)
    }

    /// 下一条要返回的响应。
    var currentResponse: ProgressStubResponse {
        lock.lock()
        defer { lock.unlock() }
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses.first ?? .ok
    }

    /// 记录一次请求。
    func record(_ request: ProgressRecordedRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }

    /// 已收到的请求（按到达顺序）。
    var requests: [ProgressRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// 已收到的请求数。
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    /// 把后续响应的行为改成「全部成功」（模拟网络恢复）。
    func setOnline() {
        lock.lock()
        defer { lock.unlock() }
        responses = [.ok]
    }

    /// 把后续响应的行为改成「全部断网」。
    func setOffline() {
        lock.lock()
        defer { lock.unlock() }
        responses = [.offline()]
    }

    /// 创建只走本桩的 `URLSession`。
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [ProgressStubURLProtocol.routingHeader: id]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }
}

/// 弱引用路由表。
final class ProgressStubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: WeakBox] = [:]

    func register(_ server: ProgressStubServer) {
        lock.lock()
        defer { lock.unlock() }
        servers[server.id] = WeakBox(server)
    }

    func unregister(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        servers.removeValue(forKey: id)
    }

    func server(id: String) -> ProgressStubServer? {
        lock.lock()
        defer { lock.unlock() }
        return servers[id]?.value
    }

    private final class WeakBox {
        weak var value: ProgressStubServer?
        init(_ value: ProgressStubServer) { self.value = value }
    }
}

// MARK: - 时钟 / 日志替身

/// 可变时钟：测试用它把「10 秒」快进过去，避免真的 `Task.sleep`。
///
/// `PrismCore` 的 ``PrismCore/FixedClock`` 是不可变的，无法在节流测试里推进时间，
/// 因此这里补一个可变实现（只在测试 target 里）。
final class MutableClock: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// 以起点创建。
    ///
    /// - Parameter start: 起始时刻，默认 2026-01-01（任意固定值即可）。
    init(start: Date = Date(timeIntervalSince1970: 1_767_225_600)) {
        self.current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// 前进若干秒。
    ///
    /// - Parameter seconds: 秒数，可为负。
    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// 什么都不写的日志实现：测试里不需要 os_log 噪音。
struct SilentLogger: Logging {
    func log(_ level: LogLevel, _ msg: String, metadata: [String: String]) {}
}

// MARK: - 工厂

/// 构造被测对象的便捷工厂。
enum ProgressTestFactory {
    /// 桩服务器的基地址（`.invalid` 是保留 TLD，绝不会真的解析）。
    static let baseURL = URL(string: "http://stub.invalid:8096") ?? URL(fileURLWithPath: "/")

    /// 建一个指向桩服务器的 `EmbyClient`（已设好令牌）。
    ///
    /// - Parameter server: 桩服务器。
    /// - Returns: 可直接发请求的客户端。
    static func client(for server: ProgressStubServer) async -> EmbyClient {
        let connection = ServerConnection(id: "stub-server", name: "Stub", baseURL: baseURL)
        let identity = ClientIdentity(
            appVersion: "1.0.0",
            deviceName: "TestMac",
            deviceId: "TEST-DEVICE-ID"
        )
        let client = EmbyClient(
            server: connection,
            identity: identity,
            session: server.makeSession(),
            logger: SilentLogger()
        )
        await client.setAccessToken("test-token")
        await client.setUserId("user-1")
        return client
    }

    /// 建一个 `ProgressReporter`。
    ///
    /// - Parameters:
    ///   - client: 客户端。
    ///   - clock: 注入的时钟。
    ///   - itemId: 条目 id。
    ///   - method: 播放方式。
    ///   - interval: 上报间隔，默认 10 秒。
    ///   - queueCapacity: 离线队列容量。
    /// - Returns: 上报器。
    static func reporter(
        client: EmbyClient,
        clock: MutableClock,
        itemId: String = "item-1",
        method: PlaybackMethod = .directPlay,
        mediaSourceId: String = "source-1",
        playSessionId: String? = "session-1",
        interval: Duration = .seconds(10),
        queueCapacity: Int = PendingProgressQueue.defaultCapacity
    ) -> PlaybackProgressReporter {
        // 用别名而不是 `ProgressReporter`：macOS 27 的 Foundation 新增了同名类
        // `Foundation.ProgressReporter`，裸写会报 ambiguous；而 `PrismPlayback.ProgressReporter`
        // 也不行——模块里有个同名枚举 `PrismPlayback` 遮蔽了模块名。
        PlaybackProgressReporter(
            client: client,
            userId: "user-1",
            itemId: itemId,
            method: method,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            interval: interval,
            clock: clock,
            logger: SilentLogger(),
            queueCapacity: queueCapacity
        )
    }
}
