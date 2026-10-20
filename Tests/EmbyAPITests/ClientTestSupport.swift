import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

// MARK: - 测试端点

/// 可配置的假端点：测试用它拼出任意 path / method / query / body。
struct TestEndpoint: EmbyEndpoint {
    var path: String
    var method: HTTPMethod
    var query: [String: String]
    var body: Data?
    var contentType: String?
    var requiresAuth: Bool
    var timeout: TimeInterval?
    var cachePolicy: URLRequest.CachePolicy

    init(
        path: String,
        method: HTTPMethod = .get,
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil,
        requiresAuth: Bool = true,
        timeout: TimeInterval? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.contentType = contentType
        self.requiresAuth = requiresAuth
        self.timeout = timeout
        self.cachePolicy = cachePolicy
    }
}

/// 解码用的小 DTO。
struct TestPayload: Decodable, Sendable, Equatable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

// MARK: - 日志 / 等待器替身

/// 记录所有日志的 `Logging` 实现。
///
/// 它**不做脱敏** —— 这正是重点：脱敏必须由 ``EmbyClient`` 自己完成，
/// 否则换个日志实现就泄露令牌。
final class RecordingLogger: Logging, @unchecked Sendable {
    struct Entry: Sendable {
        let level: LogLevel
        let message: String
        let metadata: [String: String]

        /// 消息 + 元数据的合并文本，便于做「包含 / 不包含」断言。
        var combined: String {
            let pairs = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return pairs.isEmpty ? message : "\(message) \(pairs)"
        }
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    /// 已记录的全部条目。
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 已记录的全部条目文本。
    var lines: [String] {
        entries.map(\.combined)
    }

    /// 全部条目拼成一段文本（用换行分隔）。
    var text: String {
        lines.joined(separator: "\n")
    }

    /// 写入一条日志。
    func log(_ level: LogLevel, _ msg: String, metadata: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(level: level, message: msg, metadata: metadata))
    }
}

/// 记录退避时长但立即返回的等待器：测试不会真的等 0.5s。
final class RecordingSleeper: RetrySleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    /// 已记录的等待时长（按调用顺序）。
    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 记录并立即返回。
    func sleep(seconds: TimeInterval) async {
        record(seconds)
    }

    /// 同步记录（`NSLock` 在 async 上下文里不可直接加锁，拆成同步方法）。
    private func record(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(seconds)
    }
}

// MARK: - 工厂

/// 测试共用的构造器。
enum TestFixtures {
    /// 固定身份，保证鉴权头断言可逐字比较。
    static func identity(
        appVersion: String = "1.0.0",
        deviceName: String = "TestMac",
        deviceId: String = "TEST-DEVICE-ID"
    ) -> ClientIdentity {
        ClientIdentity(
            appVersion: appVersion,
            deviceName: deviceName,
            deviceId: deviceId
        )
    }

    /// 构造 URL；非法字面量记一条测试问题而不是崩溃。
    static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            Issue.record("非法 URL 字面量：\(string)")
            return URL(filePath: "/")
        }
        return url
    }

    /// 构造服务器连接。
    static func server(_ baseURL: String, id: String = "srv-test") -> ServerConnection {
        ServerConnection(id: id, name: "Test Server", baseURL: url(baseURL))
    }

    /// 构造客户端（默认关闭重试、日志静音、退避立即返回）。
    static func client(
        mock: MockServer,
        baseURL: String = "http://127.0.0.1:8096",
        token: String? = nil,
        userId: String? = nil,
        identity: ClientIdentity = TestFixtures.identity(),
        retryPolicy: RetryPolicy = RetryPolicy(maxRetries: 0),
        logger: any Logging = NoopLogger(),
        sleeper: any RetrySleeping = RecordingSleeper()
    ) async -> EmbyClient {
        let client = EmbyClient(
            server: server(baseURL),
            identity: identity,
            session: mock.makeSession(),
            logger: logger,
            retryPolicy: retryPolicy,
            sleeper: sleeper
        )
        if let token {
            await client.setAccessToken(token)
        }
        if let userId {
            await client.setUserId(userId)
        }
        return client
    }
}
