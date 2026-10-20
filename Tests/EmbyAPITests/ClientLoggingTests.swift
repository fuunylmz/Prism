import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

@Suite("请求日志与脱敏")
struct ClientLoggingTests {
    private let secretToken = "SUPER-SECRET-TOKEN-42"

    @Test("成功请求记录方法、脱敏 URL、状态码、耗时、重试次数")
    func successLog() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let logger = RecordingLogger()
        let client = await TestFixtures.client(mock: mock, token: secretToken, logger: logger)

        let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))

        let line = try #require(logger.lines.first { $0.contains("-> 200") })
        #expect(line.contains("GET"))
        #expect(line.contains("/Users/Me"))
        #expect(line.contains("retries=0"))
        #expect(line.contains("status=200"))
        #expect(line.contains("duration_ms="))
        // 请求体与请求头都不该进日志。
        #expect(!line.contains("X-Emby-Token"))
        #expect(!line.contains(secretToken))
    }

    @Test("日志里的 api_key 被 Redactor 打码，真实 token 不出现")
    func redactsQueryToken() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let logger = RecordingLogger()
        let client = await TestFixtures.client(mock: mock, token: secretToken, logger: logger)

        // 故意把 token 放进 query，模拟图片/流地址里的 api_key。
        let _: TestPayload = try await client.send(
            TestEndpoint(path: "/Users/Me", query: ["api_key": secretToken])
        )

        let text = logger.text
        #expect(!text.contains(secretToken))
        #expect(text.contains("api_key=***"))
    }

    @Test("重试过程也有日志，且同样不含 token")
    func retryLogs() async throws {
        let mock = MockServer([
            .json(#"{"Message":"boom"}"#, statusCode: 500),
            .json(#"{"Message":"boom"}"#, statusCode: 500),
            .json(#"{"Id":"u1","Name":"Alice"}"#)
        ])
        let logger = RecordingLogger()
        let client = await TestFixtures.client(
            mock: mock,
            token: secretToken,
            retryPolicy: RetryPolicy(
                clock: FixedClock(now: Date(timeIntervalSince1970: 1_700_000_000))
            ),
            logger: logger
        )

        let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))

        let text = logger.text
        #expect(text.contains("retrying"))
        #expect(text.contains("retries=2"))
        #expect(!text.contains(secretToken))
        #expect(logger.entries.contains { $0.level == .warning })
        #expect(logger.entries.contains { $0.level == .info })
    }

    @Test("登录请求体（含明文密码）绝不进日志")
    func neverLogsBody() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let logger = RecordingLogger()
        let client = await TestFixtures.client(mock: mock, logger: logger)

        let _: TestPayload = try await client.send(
            TestEndpoint(
                path: "/Users/AuthenticateByName",
                method: .post,
                body: Data(#"{"Username":"alice","Pw":"hunter2"}"#.utf8),
                requiresAuth: false
            )
        )

        let text = logger.text
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("Username"))
        #expect(text.contains("POST"))
    }

    @Test("解码失败单独记一条错误日志，含类型名")
    func decodingFailureLog() async throws {
        let mock = MockServer(.json(#"{"Unexpected":1}"#))
        let logger = RecordingLogger()
        let client = await TestFixtures.client(mock: mock, token: secretToken, logger: logger)

        do {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
            Issue.record("应当抛解码错误")
        } catch {
            // 期望路径：解码失败。
        }

        let text = logger.text
        #expect(text.contains("解码失败"))
        #expect(text.contains("TestPayload"))
        #expect(!text.contains(secretToken))
        #expect(logger.entries.contains { $0.level == .error })
    }
}
