import Foundation
import Testing
@testable import EmbyAPI
import PrismCore

/// 手动地址校验（`GET /System/Info/Public`）的测试。
///
/// 用 `URLProtocol` 拦截请求，**不碰真实网络**。
@Suite("手动地址校验", .serialized)
struct DiscoveryValidationTests {
    @Test("成功时返回 ServerConnection 与 PublicServerInfo")
    func success() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(
            status: 200,
            json: #"{"Id":"srv-1","ServerName":"My Emby","Version":"4.8.11.0"}"#
        )
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        let (connection, info) = try await discovery.validate(urlString: "192.168.1.10")

        #expect(info.id == "srv-1")
        #expect(info.serverName == "My Emby")
        #expect(info.version == "4.8.11.0")
        #expect(connection.id == "srv-1")
        #expect(connection.name == "My Emby")
        #expect(connection.baseURL.absoluteString == "http://192.168.1.10:8096")
        #expect(connection.lastConnectedAt != nil)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "http://192.168.1.10:8096/System/Info/Public")
        #expect(request.httpMethod == "GET")
    }

    @Test("反代前缀被保留在校验请求里")
    func proxyPrefixPreserved() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: #"{"Id":"srv-2","ServerName":"Proxy","Version":"4.9.0.0"}"#)
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        _ = try await discovery.validate(urlString: "https://emby.example.com/emby")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://emby.example.com/emby/System/Info/Public")
    }

    @Test("非法地址不发请求，直接抛 invalidURL")
    func invalidAddressSkipsNetwork() async {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: #"{"Id":"x"}"#)
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        await #expect(throws: EmbyError.invalidURL) {
            _ = try await discovery.validate(urlString: "ftp://nope")
        }
        #expect(StubURLProtocol.requestCount == 0)
    }

    @Test("404 归一化成 notFound")
    func notFound() async {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 404, json: #"{"Message":"not here"}"#)
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        await #expect(throws: EmbyError.notFound) {
            _ = try await discovery.validate(urlString: "http://host:8096")
        }
    }

    @Test("连不上映射成 serverUnreachable")
    func unreachable() async {
        StubURLProtocol.reset()
        StubURLProtocol.fail(with: URLError(.cannotConnectToHost))
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        do {
            _ = try await discovery.validate(urlString: "http://host:8096")
            Issue.record("应当抛错")
        } catch let error as EmbyError {
            guard case .serverUnreachable = error else {
                Issue.record("期望 serverUnreachable，实际 \(error.debugDescription)")
                return
            }
        } catch {
            Issue.record("期望 EmbyError，实际 \(error)")
        }
    }

    @Test("超时映射成 timeout")
    func timeout() async {
        StubURLProtocol.reset()
        StubURLProtocol.fail(with: URLError(.timedOut))
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        await #expect(throws: EmbyError.timeout) {
            _ = try await discovery.validate(urlString: "http://host:8096")
        }
    }

    @Test("返回体不是 JSON 时映射成 decoding")
    func notJSON() async {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, raw: Data("<html>hello</html>".utf8))
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        do {
            _ = try await discovery.validate(urlString: "http://host:8096")
            Issue.record("应当抛错")
        } catch let error as EmbyError {
            guard case .decoding = error else {
                Issue.record("期望 decoding，实际 \(error.debugDescription)")
                return
            }
        } catch {
            Issue.record("期望 EmbyError，实际 \(error)")
        }
    }

    @Test("是合法 JSON 但缺少 Id 时也判为 decoding（不是 Emby）")
    func jsonWithoutId() async {
        StubURLProtocol.reset()
        StubURLProtocol.respond(status: 200, json: #"{"Hello":"world"}"#)
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        do {
            _ = try await discovery.validate(urlString: "http://host:8096")
            Issue.record("应当抛错")
        } catch let error as EmbyError {
            guard case .decoding = error else {
                Issue.record("期望 decoding，实际 \(error.debugDescription)")
                return
            }
        } catch {
            Issue.record("期望 EmbyError，实际 \(error)")
        }
    }

    @Test("响应体尾部带 NUL / 换行也能解析（回归）")
    func trailingPaddingInBody() async throws {
        StubURLProtocol.reset()
        var body = Data(#"{"Id":"srv-3","ServerName":"Padded","Version":"4.9.0.0"}"#.utf8)
        body.append(contentsOf: [0x00, 0x0A, 0x00])
        StubURLProtocol.respond(status: 200, raw: body)
        let discovery = ServerDiscovery(probe: ServerProbe(session: StubURLProtocol.makeSession()))

        let (connection, info) = try await discovery.validate(urlString: "http://host:8096")
        #expect(info.id == "srv-3")
        #expect(connection.name == "Padded")
    }

    @Test("ServerProbe 拼 URL 时保留前缀、丢弃 query 与 fragment")
    func probeURLBuilding() throws {
        let cases: [(String, String)] = [
            ("http://host:8096", "http://host:8096/System/Info/Public"),
            ("http://host:8096/", "http://host:8096/System/Info/Public"),
            ("http://host:8096/emby", "http://host:8096/emby/System/Info/Public"),
            ("http://host:8096/emby/", "http://host:8096/emby/System/Info/Public"),
        ]
        for (base, expected) in cases {
            let url = try #require(URL(string: base))
            #expect(ServerProbe.publicInfoURL(for: url)?.absoluteString == expected)
        }
    }
}

// MARK: - URLProtocol 桩

/// 拦截 `URLSession` 请求的测试桩。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub: Sendable {
        var status: Int = 200
        var body: Data = Data()
        var failure: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var requestTotal = 0

    /// 清空所有记录与桩数据。
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stub = Stub()
        requests = []
        requestTotal = 0
    }

    /// 设定成功响应。
    ///
    /// - Parameters:
    ///   - status: HTTP 状态码。
    ///   - json: JSON 响应体。
    static func respond(status: Int, json: String) {
        respond(status: status, raw: Data(json.utf8))
    }

    /// 设定原始字节响应。
    ///
    /// - Parameters:
    ///   - status: HTTP 状态码。
    ///   - raw: 响应体。
    static func respond(status: Int, raw: Data) {
        lock.lock()
        defer { lock.unlock() }
        stub = Stub(status: status, body: raw, failure: nil)
    }

    /// 设定网络层失败。
    ///
    /// - Parameter error: 要抛出的 `URLError`。
    static func fail(with error: URLError) {
        lock.lock()
        defer { lock.unlock() }
        stub = Stub(status: 0, body: Data(), failure: error)
    }

    /// 最近一次被拦截的请求。
    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    /// 被拦截的请求总数。
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestTotal
    }

    /// 构造使用本桩的会话。
    ///
    /// - Returns: 配置好 `StubURLProtocol` 的 `URLSession`。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current: Stub = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.requests.append(request)
            Self.requestTotal += 1
            return Self.stub
        }()

        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(filePath: "/"),
            statusCode: current.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
