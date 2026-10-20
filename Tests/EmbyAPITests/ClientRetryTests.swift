import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

@Suite("重试策略")
struct ClientRetryTests {
    private static let fixedClock = FixedClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    private func defaultPolicy(maxRetries: Int = 2) -> RetryPolicy {
        RetryPolicy(maxRetries: maxRetries, clock: Self.fixedClock)
    }

    @Test("5xx 两次后成功：共发 3 次请求，退避 0.5s / 1.5s（含抖动）")
    func retriesThenSucceeds() async throws {
        let mock = MockServer([
            .json(#"{"Message":"boom"}"#, statusCode: 500),
            .json(#"{"Message":"boom"}"#, statusCode: 500),
            .json(#"{"Id":"u1","Name":"Alice"}"#)
        ])
        let sleeper = RecordingSleeper()
        let client = await TestFixtures.client(
            mock: mock,
            token: "TKN",
            retryPolicy: defaultPolicy(),
            sleeper: sleeper
        )

        let payload: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        #expect(payload.id == "u1")
        #expect(mock.requestCount == 3)

        let sleeps = sleeper.sleeps
        #expect(sleeps.count == 2)
        if sleeps.count == 2 {
            #expect(sleeps[0] >= 0.4 && sleeps[0] <= 0.6)
            #expect(sleeps[1] >= 1.2 && sleeps[1] <= 1.8)
        }
    }

    @Test("连续 5xx 用尽重试后抛错：最多 3 次请求")
    func exhaustsRetries() async {
        let mock = MockServer(.json(#"{"Message":"boom"}"#, statusCode: 500))
        let sleeper = RecordingSleeper()
        let client = await TestFixtures.client(
            mock: mock,
            token: "TKN",
            retryPolicy: defaultPolicy(),
            sleeper: sleeper
        )

        await #expect(throws: EmbyError.server(status: 500, message: "boom")) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
        #expect(mock.requestCount == 3)
        #expect(sleeper.sleeps.count == 2)
    }

    @Test("401 绝不重试：只请求 1 次")
    func unauthorizedIsNotRetried() async {
        let mock = MockServer(.json(#"{"Message":"bad token"}"#, statusCode: 401))
        let sleeper = RecordingSleeper()
        let client = await TestFixtures.client(
            mock: mock,
            token: "TKN",
            retryPolicy: defaultPolicy(),
            sleeper: sleeper
        )

        await #expect(throws: EmbyError.unauthorized) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
        #expect(mock.requestCount == 1)
        #expect(sleeper.sleeps.isEmpty)
    }

    @Test("404 / 403 不重试")
    func clientErrorsAreNotRetried() async {
        for status in [403, 404] {
            let mock = MockServer(.json(#"{"Message":"nope"}"#, statusCode: status))
            let client = await TestFixtures.client(
                mock: mock,
                token: "TKN",
                retryPolicy: defaultPolicy()
            )
            _ = try? await client.data(TestEndpoint(path: "/Users/Me"))
            #expect(mock.requestCount == 1)
        }
    }

    @Test("超时可重试：两次超时后成功")
    func timeoutIsRetried() async throws {
        let mock = MockServer([
            .failure(.timedOut),
            .failure(.timedOut),
            .json(#"{"Id":"u1","Name":"Alice"}"#)
        ])
        let client = await TestFixtures.client(
            mock: mock,
            token: "TKN",
            retryPolicy: defaultPolicy()
        )

        let payload: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        #expect(payload.id == "u1")
        #expect(mock.requestCount == 3)
    }

    @Test("POST /Sessions/Playing 不重试（非幂等，避免重复上报进度）")
    func playbackReportIsNotRetried() async {
        let mock = MockServer(.json(#"{"Message":"boom"}"#, statusCode: 500))
        let sleeper = RecordingSleeper()
        let client = await TestFixtures.client(
            mock: mock,
            token: "TKN",
            retryPolicy: defaultPolicy(),
            sleeper: sleeper
        )

        await #expect(throws: EmbyError.server(status: 500, message: "boom")) {
            try await client.send(
                TestEndpoint(
                    path: "/Sessions/Playing/Progress",
                    method: .post,
                    body: Data("{}".utf8)
                )
            )
        }
        #expect(mock.requestCount == 1)
        #expect(sleeper.sleeps.isEmpty)
    }

    @Test("登录 POST 不重试（非幂等，会重复创建会话）")
    func loginIsNotRetried() async {
        let mock = MockServer(.json(#"{"Message":"boom"}"#, statusCode: 503))
        let client = await TestFixtures.client(
            mock: mock,
            retryPolicy: defaultPolicy()
        )

        await #expect(throws: EmbyError.server(status: 503, message: "boom")) {
            let _: TestPayload = try await client.send(
                TestEndpoint(
                    path: "/Users/AuthenticateByName",
                    method: .post,
                    body: Data(#"{"Username":"a","Pw":"b"}"#.utf8),
                    requiresAuth: false
                )
            )
        }
        #expect(mock.requestCount == 1)
    }

    @Test("幂等判定：GET 可重试，POST/PUT/DELETE 与播报路径不可重试")
    func idempotency() {
        #expect(RetryPolicy.isIdempotent(TestEndpoint(path: "/Users/Me")))
        #expect(!RetryPolicy.isIdempotent(TestEndpoint(path: "/Users/Me", method: .post)))
        #expect(!RetryPolicy.isIdempotent(TestEndpoint(path: "/Users/Me", method: .put)))
        #expect(!RetryPolicy.isIdempotent(TestEndpoint(path: "/Users/Me", method: .delete)))
        #expect(!RetryPolicy.isIdempotent(TestEndpoint(path: "/Sessions/Playing")))
        #expect(!RetryPolicy.isIdempotent(TestEndpoint(path: "/Users/AuthenticateByName")))
    }

    @Test("shouldRetry 只放行 timeout / serverUnreachable / 5xx")
    func shouldRetryMatrix() {
        let policy = defaultPolicy()
        let endpoint = TestEndpoint(path: "/Users/Me")

        #expect(policy.shouldRetry(.timeout, for: endpoint))
        #expect(policy.shouldRetry(.serverUnreachable("offline"), for: endpoint))
        #expect(policy.shouldRetry(.server(status: 500, message: nil), for: endpoint))
        #expect(policy.shouldRetry(.server(status: 599, message: nil), for: endpoint))

        #expect(!policy.shouldRetry(.unauthorized, for: endpoint))
        #expect(!policy.shouldRetry(.forbidden, for: endpoint))
        #expect(!policy.shouldRetry(.notFound, for: endpoint))
        #expect(!policy.shouldRetry(.decoding("bad"), for: endpoint))
        #expect(!policy.shouldRetry(.cancelled, for: endpoint))
        #expect(!policy.shouldRetry(.server(status: 400, message: nil), for: endpoint))
        #expect(!policy.shouldRetry(.server(status: 429, message: nil), for: endpoint))
    }

    @Test("退避：第 1 次约 0.5s，第 2 次约 1.5s，且抖动可复现")
    func backoffDelays() {
        let policy = RetryPolicy(clock: Self.fixedClock)
        let first = policy.delay(forRetry: 0)
        let second = policy.delay(forRetry: 1)

        #expect(first >= 0.4 && first <= 0.6)
        #expect(second >= 1.2 && second <= 1.8)

        // 同一 FixedClock 下抖动是确定的（用时钟做种子，而不是 Double.random）。
        #expect(policy.delay(forRetry: 0) == first)
        #expect(policy.delay(forRetry: 1) == second)

        // 时钟不同 → 抖动不同（避免退避同步化）。
        let other = RetryPolicy(clock: FixedClock(now: Date(timeIntervalSince1970: 1_700_000_001)))
        #expect(other.delay(forRetry: 0) != first)
    }

    @Test("maxRetries == 0 时一次都不重试")
    func noRetryPolicy() async {
        let mock = MockServer(.json(#"{"Message":"boom"}"#, statusCode: 500))
        let sleeper = RecordingSleeper()
        let client = await TestFixtures.client(
            mock: mock,
            token: "TKN",
            retryPolicy: defaultPolicy(maxRetries: 0),
            sleeper: sleeper
        )

        _ = try? await client.data(TestEndpoint(path: "/Users/Me"))
        #expect(mock.requestCount == 1)
        #expect(sleeper.sleeps.isEmpty)
    }
}
