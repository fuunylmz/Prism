import AppKit
import EmbyAPI
import Foundation
import PrismCore

@testable import PrismData

// MARK: - 网络桩

/// 基于 `URLProtocol` 的图片桩：**绝不发起真实网络**。
///
/// 与 `Tests/EmbyAPITests/MockURLProtocol.swift` 是**两份独立实现**（测试 target 之间
/// 不能互相引用）。这里多做了两件图片管线测试必需的事：
/// 1. 记录**峰值并发**（验证「同时最多 6 个下载」）；
/// 2. 响应延迟用 `DispatchQueue.asyncAfter` 而不是 `Thread.sleep`，
///    这样多个桩实例的延迟能真正重叠 —— 否则测不出并发。
///
/// 并行测试隔离：每个 ``ImagesMockServer`` 有唯一 id，`makeSession()` 把它写进
/// `httpAdditionalHeaders`，桩据此路由。同一进程里多个测试并行跑不会串响应。
final class ImagesMockURLProtocol: URLProtocol {
    /// 路由头。
    static let sessionHeader = "X-Prism-ImageMock-ID"

    /// 全局路由表。
    static let registry = ImagesMockRegistry()

    private let stateLock = NSLock()
    private var stopped = false

    /// 标记已停止（`stopLoading` 之后不再向 client 投递）。
    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.sessionHeader),
              let server = Self.registry.server(id: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        server.begin(self, request)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

/// 把 `URLProtocol`（非 `Sendable`）安全地送进 `DispatchQueue` 的 `@Sendable` 闭包。
private final class ImagesProtocolBox: @unchecked Sendable {
    let proto: ImagesMockURLProtocol

    init(_ proto: ImagesMockURLProtocol) {
        self.proto = proto
    }
}

/// 一条预设响应。
struct ImagesMockResponse: Sendable {
    /// HTTP 状态码。
    var statusCode: Int
    /// 响应头。
    var headers: [String: String]
    /// 响应体。
    var body: Data
    /// 非 `nil` 时以 `URLError` 失败。
    var errorCode: URLError.Code?
    /// 投递前的延迟（秒）。
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

    /// 图片响应。
    static func image(_ data: Data, delay: TimeInterval = 0) -> ImagesMockResponse {
        ImagesMockResponse(
            statusCode: 200,
            headers: ["Content-Type": "image/png"],
            body: data,
            delay: delay
        )
    }

    /// 404（Emby 在对象没指示图片存在时就是这样）。
    static func notFound(delay: TimeInterval = 0) -> ImagesMockResponse {
        ImagesMockResponse(statusCode: 404, body: Data("Not Found".utf8), delay: delay)
    }
}

/// 按序出队的响应队列 + 请求记录器 + 并发峰值统计。
final class ImagesMockServer: @unchecked Sendable {
    /// 路由 id。
    let id: String

    private let lock = NSLock()
    private var pending: [ImagesMockResponse]
    private let repeatsLast: Bool
    private var recorded: [URLRequest] = []
    private var active = 0
    private var peak = 0

    /// 创建桩服务器。
    ///
    /// - Parameters:
    ///   - responses: 按序返回的响应；队列耗尽后按 `repeatsLast` 决定复用最后一条。
    ///   - repeatsLast: 队列耗尽后是否重复最后一条（默认 `true`）。
    init(_ responses: [ImagesMockResponse], repeatsLast: Bool = true) {
        id = UUID().uuidString
        pending = responses
        self.repeatsLast = repeatsLast
        ImagesMockURLProtocol.registry.register(self)
    }

    /// 只返回同一条响应。
    convenience init(_ response: ImagesMockResponse) {
        self.init([response])
    }

    deinit {
        ImagesMockURLProtocol.registry.unregister(id)
    }

    /// 收到的请求数。
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    /// 收到的请求（按到达顺序）。
    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// 观测到的**峰值并发**（同时处于「已开始、未投递完成」状态的请求数）。
    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    /// 创建绑定了本桩的 `URLSession`。
    ///
    /// `httpMaximumConnectionsPerHost` 故意设成 20：`URLSession` 对单主机的默认上限
    /// 正好也是 6，如果让它也生效，就分不清「被我们的信号量挡住」还是「被 URLSession
    /// 挡住」了。
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImagesMockURLProtocol.self]
        configuration.httpAdditionalHeaders = [ImagesMockURLProtocol.sessionHeader: id]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 20
        return URLSession(configuration: configuration)
    }

    // MARK: 桩内部

    /// 开始一次请求：记录、算峰值、安排投递。
    func begin(_ proto: ImagesMockURLProtocol, _ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        active += 1
        peak = max(peak, active)
        let response = nextResponseLocked()
        lock.unlock()

        let box = ImagesProtocolBox(proto)
        let deliver: @Sendable () -> Void = { [weak self] in
            self?.finish(box, request: request, response: response)
        }
        if response.delay > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + response.delay,
                execute: deliver
            )
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: deliver)
        }
    }

    /// 投递响应。
    private func finish(
        _ box: ImagesProtocolBox,
        request: URLRequest,
        response: ImagesMockResponse
    ) {
        lock.lock()
        active -= 1
        lock.unlock()

        let proto = box.proto
        guard !proto.isStopped else { return }

        if let code = response.errorCode {
            proto.client?.urlProtocol(proto, didFailWithError: URLError(code))
            return
        }
        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.headers
              )
        else {
            proto.client?.urlProtocol(proto, didFailWithError: URLError(.badServerResponse))
            return
        }
        proto.client?.urlProtocol(proto, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            proto.client?.urlProtocol(proto, didLoad: response.body)
        }
        proto.client?.urlProtocolDidFinishLoading(proto)
    }

    /// 取队首（调用方已持锁）。
    private func nextResponseLocked() -> ImagesMockResponse {
        if pending.count > 1 {
            return pending.removeFirst()
        }
        if let last = pending.first {
            if !repeatsLast { pending.removeFirst() }
            return last
        }
        return ImagesMockResponse(statusCode: 500, body: Data("MockServer 队列已空".utf8))
    }
}

/// 弱引用路由表。
final class ImagesMockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: WeakServer] = [:]

    /// 登记。
    func register(_ server: ImagesMockServer) {
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
    func server(id: String) -> ImagesMockServer? {
        lock.lock()
        defer { lock.unlock() }
        return servers[id]?.value
    }

    private final class WeakServer {
        weak var value: ImagesMockServer?

        init(_ value: ImagesMockServer) {
            self.value = value
        }
    }
}

// MARK: - 测试图

/// 用代码生成测试图片，**不下载任何真实图片**。
enum ImagesTestSupport {
    /// 画一张纯色 + 对角线的 PNG。
    ///
    /// - Parameters:
    ///   - width: 像素宽。
    ///   - height: 像素高。
    ///   - orientation: 写入 EXIF 方向（1 = 正常，6 = 顺时针 90°）。
    /// - Returns: PNG 字节；绘制失败时返回空 `Data`（测试里用 `#require` 兜住）。
    static func png(width: Int, height: Int, orientation: Int = 1) -> Data {
        guard let cgImage = makeCGImage(width: width, height: height) else { return Data() }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = NSSize(width: width, height: height)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return Data()
        }
        guard orientation != 1 else { return data }
        return pngWithOrientation(data, orientation: orientation) ?? data
    }

    /// 画一张纯色位图。
    static func makeCGImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return context.makeImage()
    }

    /// 给 PNG 写入 EXIF 方向。
    ///
    /// 走 `CGImageDestination` 重新编码：ImageIO 会把 `kCGImagePropertyOrientation`
    /// 写进 `eXIf` 块，回读时 `CGImageSourceCopyPropertiesAtIndex` 能拿到。
    static func pngWithOrientation(_ data: Data, orientation: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 构造指向桩的 `EmbyClient`（关闭重试、日志静音）。
    static func client(_ mock: ImagesMockServer, token: String? = "TKN-TEST") async -> EmbyClient {
        let baseURL = URL(string: "http://127.0.0.1:8096") ?? URL(fileURLWithPath: "/")
        let client = EmbyClient(
            server: ServerConnection(id: "srv-images", name: "Images Test", baseURL: baseURL),
            identity: ClientIdentity(
                appVersion: "1.0.0",
                deviceName: "TestMac",
                deviceId: "TEST-DEVICE-ID"
            ),
            session: mock.makeSession(),
            logger: NoopLogger(),
            retryPolicy: RetryPolicy(maxRetries: 0),
            sleeper: NoopSleeper()
        )
        await client.setAccessToken(token)
        await client.setUserId("user-1")
        return client
    }

    /// 临时目录里的缓存实例。
    ///
    /// - Parameters:
    ///   - memoryCostLimit: 内存上限。
    ///   - diskLimit: 磁盘上限。
    /// - Returns: 缓存 + 它独占的目录（测试结束自己删）。
    static func makeCache(
        memoryCostLimit: Int = 128 * 1024 * 1024,
        diskLimit: Int = 500 * 1024 * 1024
    ) -> (cache: ImageCache, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-images-test-\(UUID().uuidString)", isDirectory: true)
        let cache = ImageCache(
            configuration: ImageCache.Configuration(
                directory: directory,
                memoryCostLimit: memoryCostLimit,
                diskLimit: diskLimit
            )
        )
        return (cache, directory)
    }

    /// 删除临时目录。
    static func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 立即返回的退避等待器（本管线的测试不涉及重试）。
struct NoopSleeper: RetrySleeping {
    func sleep(seconds: TimeInterval) async {}
}

// MARK: - 假加载器

/// 只记录调用的 `ImageLoading` 实现，用于测试 ``ImagePrefetcher`` 的队列与取消语义。
actor RecordingImageLoader: ImageLoading {
    private(set) var requestedKeys: [String] = []
    private(set) var prefetchBatches: [[String]] = []
    private let delay: Duration

    /// 创建假加载器。
    ///
    /// - Parameter delay: 每次 `prefetch` 的模拟耗时。
    init(delay: Duration = .milliseconds(10)) {
        self.delay = delay
    }

    func image(for request: ImageRequest) async throws -> PlatformImage {
        requestedKeys.append(request.cacheKey)
        return PlatformImage(size: CGSize(width: 1, height: 1))
    }

    func prefetch(_ requests: [ImageRequest], limit: Int) async {
        guard !Task.isCancelled else { return }
        prefetchBatches.append(requests.prefix(limit).map(\.cacheKey))
        try? await Task.sleep(for: delay)
    }

    nonisolated func clearMemoryCache() {}

    /// 所有被预取的键（按批次展开）。
    var prefetchedKeys: [String] {
        prefetchBatches.flatMap { $0 }
    }
}

// MARK: - 顺序记录

/// 记录并发任务的完成顺序。
actor OrderRecorder {
    private(set) var values: [String] = []

    /// 追加一个标记。
    func append(_ value: String) {
        values.append(value)
    }
}
