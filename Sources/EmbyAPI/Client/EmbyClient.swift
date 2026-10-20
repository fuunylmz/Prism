import Foundation
import PrismCore

/// Emby REST 客户端的唯一出口。
///
/// 所有请求都从这里发出，它负责四件事：
/// 1. 拼接 `server.baseURL`（支持反代前缀 `/emby`，见 ``RequestBuilder``）；
/// 2. 注入鉴权头（``AuthHeader`` + `X-Emby-Token`）；
/// 3. 把 HTTP 状态码 / `URLError` / 解码失败归一化成 ``PrismCore/EmbyError``；
/// 4. 写脱敏日志（``EmbyClient/RequestLogEntry``，见 `EmbyClient+Logging.swift`）。
///
/// 并发模型：`actor`。令牌与用户 id 是可变状态，只能通过 ``setAccessToken(_:)`` /
/// ``setUserId(_:)`` / ``setSession(_:)`` 修改；请求本身在 `await` 点让出执行权，
/// 期间令牌可能被换掉，因此每次请求在**开始时**取一份快照。
///
/// ```swift
/// let client = EmbyClient(server: connection, identity: .current())
/// let user: EmbyUser = try await client.send(CurrentUserEndpoint())
/// ```
public actor EmbyClient {
    /// 服务器基地址（与 `server.baseURL` 相同）。
    ///
    /// 声明成 `nonisolated` 是为了让图片 URL 拼装等纯计算不需要 `await`。
    public nonisolated var baseURL: URL { baseURLValue }

    /// 基地址的存储值（actor 的 `let` 存储属性对 `Sendable` 类型隐式 nonisolated）。
    private let baseURLValue: URL

    /// 底层会话；测试注入带 `URLProtocol` 桩的会话。
    private let session: URLSession

    /// 日志实现；**本层负责脱敏**，不依赖实现方自觉。
    let logger: any Logging

    /// 计时时钟（日志里的耗时）。
    private let clock: any ClockProviding

    /// 重试策略。
    private let retryPolicy: RetryPolicy

    /// 退避等待器（测试注入立即返回的实现）。
    private let sleeper: any RetrySleeping

    /// 请求构造器（纯函数）。
    private let builder: RequestBuilder

    /// 当前访问令牌；`nil` 表示未登录。
    private var accessToken: String?

    /// 当前用户 id（写进鉴权头的 `UserId=`）；未知时省略该字段。
    private var userId: String?

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - server: 服务器连接（提供 `baseURL`）。
    ///   - identity: 客户端身份（鉴权头里的 Client/Device/DeviceId/Version）。
    ///   - session: 网络会话，默认 `.shared`；测试注入 `URLProtocol` 桩会话。
    ///   - logger: 日志实现，默认 `OSLogger(category: "network")`。
    ///   - clock: 计时时钟，默认 `SystemClock()`。
    ///   - retryPolicy: 重试策略，默认 ``RetryPolicy/default``。
    ///   - sleeper: 退避等待器，默认 ``TaskSleeper``。
    /// - Note: 若希望退避抖动在测试里可复现，``RetryPolicy`` 需要单独注入
    ///   `FixedClock`；本参数里的 `clock` 只用于日志耗时。
    public init(
        server: ServerConnection,
        identity: ClientIdentity,
        session: URLSession = .shared,
        logger: any Logging = OSLogger(category: "network"),
        clock: any ClockProviding = SystemClock(),
        retryPolicy: RetryPolicy = .default,
        sleeper: any RetrySleeping = TaskSleeper()
    ) {
        self.baseURLValue = server.baseURL
        self.session = session
        self.logger = logger
        self.clock = clock
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.builder = RequestBuilder(baseURL: server.baseURL, identity: identity)
    }

    // MARK: - 会话状态

    /// 设置（或清除）访问令牌。
    ///
    /// - Parameter token: 新的令牌；`nil` 表示登出，之后的鉴权请求会抛
    ///   ``PrismCore/EmbyError/unauthorized`` 而不发出。
    public func setAccessToken(_ token: String?) {
        accessToken = (token?.isEmpty ?? true) ? nil : token
    }

    /// 设置（或清除）当前用户 id，用于鉴权头的 `UserId=` 字段。
    ///
    /// - Parameter userId: 用户 id；`nil` 时省略该字段（Emby 允许，服务端靠 token 认人）。
    public func setUserId(_ userId: String?) {
        self.userId = (userId?.isEmpty ?? true) ? nil : userId
    }

    /// 一次性设置会话（令牌 + 用户 id）。
    ///
    /// 这是契约之外的便利方法：登录成功后调用一次即可，避免忘记设 `userId`。
    ///
    /// - Parameter session: 登录结果；`nil` 等价于登出。
    public func setSession(_ session: AuthSession?) {
        setAccessToken(session?.accessToken)
        setUserId(session?.userId)
    }

    // MARK: - 发送

    /// 发送请求并解码响应。
    ///
    /// - Parameter endpoint: 端点。
    /// - Returns: 解码后的模型。
    /// - Throws: ``PrismCore/EmbyError``（网络、状态码、解码均已归一化）。
    public func send<T: Decodable & Sendable>(_ endpoint: EmbyEndpoint) async throws -> T {
        let payload = try await perform(endpoint)
        do {
            return try EmbyJSON.decode(T.self, from: payload)
        } catch {
            let mapped = EmbyClientError.decoding(T.self, underlying: error)
            logDecodingFailure(endpoint: endpoint, error: mapped)
            throw mapped
        }
    }

    /// 发送请求并丢弃响应体（例如 `POST /Sessions/Playing/Stopped`）。
    ///
    /// - Parameter endpoint: 端点。
    /// - Throws: ``PrismCore/EmbyError``。
    public func send(_ endpoint: EmbyEndpoint) async throws {
        _ = try await perform(endpoint)
    }

    /// 发送请求并返回**原始字节**（图片、字幕、流片段）。
    ///
    /// 不解码、不校验 `Content-Type`：调用方拿到的就是服务器给的那串字节。
    ///
    /// - Parameter endpoint: 端点。
    /// - Returns: 原始响应体。
    /// - Throws: ``PrismCore/EmbyError``。
    public func data(_ endpoint: EmbyEndpoint) async throws -> Data {
        try await perform(endpoint)
    }

    // MARK: - 内部

    /// 执行一次请求（含重试）。
    ///
    /// - Parameter endpoint: 端点。
    /// - Returns: 成功的响应体。
    /// - Throws: ``PrismCore/EmbyError``。
    private func perform(_ endpoint: EmbyEndpoint) async throws -> Data {
        let token = accessToken

        // 需要鉴权但没有令牌：**不发请求**，直接抛 401 语义的错误。
        // 这样调用方（以及服务器日志）都不会看到一个注定失败的请求。
        guard !endpoint.requiresAuth || (token?.isEmpty == false) else {
            throw EmbyError.unauthorized
        }

        let request = try builder.build(endpoint, token: token, userId: userId)
        let url = request.url

        var attempt = 0
        while true {
            let startedAt = clock.now
            var duration: TimeInterval = 0
            var statusCode: Int?
            let outcome: Result<Data, EmbyError>

            do {
                let (payload, response) = try await session.data(for: request)
                duration = clock.now.timeIntervalSince(startedAt)
                if let http = response as? HTTPURLResponse {
                    statusCode = http.statusCode
                    if let error = EmbyClientError.error(statusCode: http.statusCode, body: payload) {
                        outcome = .failure(error)
                    } else {
                        outcome = .success(payload)
                    }
                } else {
                    outcome = .failure(
                        .unknown("非 HTTP 响应：\(String(describing: type(of: response)))")
                    )
                }
            } catch {
                duration = clock.now.timeIntervalSince(startedAt)
                outcome = .failure(EmbyClientError.normalized(error))
            }

            switch outcome {
            case let .success(payload):
                logRequest(
                    RequestLogEntry(
                        method: endpoint.method,
                        url: url,
                        statusCode: statusCode,
                        duration: duration,
                        retryCount: attempt,
                        error: nil
                    )
                )
                return payload

            case let .failure(error):
                let canRetry = attempt < retryPolicy.maxRetries
                    && !Task.isCancelled
                    && retryPolicy.shouldRetry(error, for: endpoint)
                if canRetry {
                    let delay = retryPolicy.delay(forRetry: attempt)
                    attempt += 1
                    logRequest(
                        RequestLogEntry(
                            method: endpoint.method,
                            url: url,
                            statusCode: statusCode,
                            duration: duration,
                            retryCount: attempt,
                            error: error,
                            retrying: true
                        )
                    )
                    await sleeper.sleep(seconds: delay)
                    continue
                }
                logRequest(
                    RequestLogEntry(
                        method: endpoint.method,
                        url: url,
                        statusCode: statusCode,
                        duration: duration,
                        retryCount: attempt,
                        error: error
                    )
                )
                throw error
            }
        }
    }
}
