import Foundation

/// 基于 `URLProtocol` 的网络桩：**按预设顺序**返回响应，绝不发起真实网络。
///
/// 用法：
/// ```swift
/// let mock = MockServer([.json(#"{"Id":"u1"}"#)])
/// let client = EmbyClient(server: server, identity: identity, session: mock.makeSession())
/// _ = try await client.send(TestEndpoint(path: "/Users/Me"))
/// #expect(mock.requestCount == 1)
/// ```
///
/// 并行测试隔离：每个 `MockServer` 有唯一 id，`makeSession()` 把它写进
/// `httpAdditionalHeaders`（``sessionHeader``），桩据此把请求路由到对应的 server。
/// 因此同一进程里多个测试并行跑也不会串响应。
///
/// - Important: 只允许出现在测试 target，不得进入 App 产物。
final class MockURLProtocol: URLProtocol {
    /// 路由头：把请求绑定到某个 ``MockServer``。
    static let sessionHeader = "X-Prism-Mock-ID"

    /// 全局路由表（弱引用 server，避免注册表让 server 永不释放）。
    static let registry = MockRegistry()

    /// 只接管 http/https。
    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// 原样返回请求，不做规范化。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 同步返回预设响应。
    ///
    /// 延迟用 `Thread.sleep` 实现：`startLoading` 运行在 URLSession 自己的加载线程上，
    /// 阻塞它不会卡住主线程；这样也避免把非 `Sendable` 的 `URLProtocol` 捕获进
    /// `DispatchQueue.asyncAfter` 的 `@Sendable` 闭包（Swift 6 会报错）。
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.sessionHeader),
              let server = Self.registry.server(id: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        server.record(request)
        let stub = server.nextResponse()

        if stub.delay > 0 {
            Thread.sleep(forTimeInterval: stub.delay)
        }

        if let code = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.headers
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

    /// 测试里不需要中途取消。
    override func stopLoading() {}
}

/// 一条预设响应。
struct MockResponse: Sendable {
    /// HTTP 状态码。
    var statusCode: Int
    /// 响应头。
    var headers: [String: String]
    /// 响应体。
    var body: Data
    /// 非 `nil` 时以 `URLError` 失败（不产生 HTTP 响应）。
    var errorCode: URLError.Code?
    /// 返回前的延迟（秒）。
    var delay: TimeInterval

    /// 完整初始化。
    init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        errorCode: URLError.Code? = nil,
        delay: TimeInterval = 0
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.errorCode = errorCode
        self.delay = delay
    }

    /// JSON 响应（自动补 `Content-Type`）。
    static func json(_ raw: String, statusCode: Int = 200) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(raw.utf8)
        )
    }

    /// 二进制响应（图片等）。
    static func bytes(
        _ bytes: Data,
        statusCode: Int = 200,
        contentType: String = "application/octet-stream"
    ) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: ["Content-Type": contentType],
            body: bytes
        )
    }

    /// 网络层失败（超时、连不上、取消……）。
    static func failure(_ code: URLError.Code, delay: TimeInterval = 0) -> MockResponse {
        MockResponse(errorCode: code, delay: delay)
    }
}

/// 一个按序出队的响应队列 + 请求记录器。
final class MockServer: @unchecked Sendable {
    /// 路由 id。
    let id: String

    private let lock = NSLock()
    private var pending: [MockResponse]
    private let repeatsLast: Bool
    private var recorded: [URLRequest] = []

    /// 创建桩服务器。
    ///
    /// - Parameters:
    ///   - responses: 按序返回的响应；队列耗尽后按 `repeatsLast` 决定复用最后一条。
    ///   - repeatsLast: 队列耗尽后是否重复最后一条（默认 `true`）。
    init(_ responses: [MockResponse], repeatsLast: Bool = true) {
        self.id = UUID().uuidString
        self.pending = responses
        self.repeatsLast = repeatsLast
        MockURLProtocol.registry.register(self)
    }

    /// 创建只返回同一条响应的桩服务器。
    convenience init(_ response: MockResponse) {
        self.init([response])
    }

    deinit {
        MockURLProtocol.registry.unregister(id)
    }

    /// 已收到的请求数（等价于「桩被调用了几次」）。
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    /// 已收到的请求（按到达顺序）。
    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// 桩被调用的次数（``requestCount`` 的别名，便于按语义断言）。
    var handlerCallCount: Int { requestCount }

    /// 取出下一条响应。
    ///
    /// - Returns: 预设响应；队列为空且不允许重复时返回一个 500，让测试显式失败。
    func nextResponse() -> MockResponse {
        lock.lock()
        defer { lock.unlock() }
        if pending.count > 1 {
            return pending.removeFirst()
        }
        if let last = pending.first {
            if !repeatsLast { pending.removeFirst() }
            return last
        }
        return .json(#"{"Message":"MockServer 队列已空"}"#, statusCode: 500)
    }

    /// 记录一次请求。
    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }

    /// 创建绑定了本桩的 `URLSession`。
    ///
    /// - Returns: 只走 ``MockURLProtocol`` 的临时会话。
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [MockURLProtocol.sessionHeader: id]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }
}

/// 弱引用路由表。
final class MockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: WeakServer] = [:]

    /// 登记一个桩服务器。
    func register(_ server: MockServer) {
        lock.lock()
        defer { lock.unlock() }
        servers[server.id] = WeakServer(server)
    }

    /// 注销。
    func unregister(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        servers.removeValue(forKey: id)
    }

    /// 按 id 查找。
    func server(id: String) -> MockServer? {
        lock.lock()
        defer { lock.unlock() }
        return servers[id]?.value
    }

    /// 弱引用包装。
    private final class WeakServer {
        weak var value: MockServer?

        init(_ value: MockServer) {
            self.value = value
        }
    }
}
