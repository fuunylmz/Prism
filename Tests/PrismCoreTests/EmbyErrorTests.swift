import Foundation
import Testing
@testable import PrismCore

@Suite("EmbyError 归一化")
struct EmbyErrorTests {
    @Test(
        "HTTP 状态码映射表",
        arguments: [
            (401, EmbyError.unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (408, .timeout),
            (400, .server(status: 400, message: nil)),
            (409, .server(status: 409, message: nil)),
            (422, .server(status: 422, message: nil)),
            (500, .server(status: 500, message: nil)),
            (502, .server(status: 502, message: nil)),
            (503, .server(status: 503, message: nil)),
            (504, .server(status: 504, message: nil)),
            (418, .server(status: 418, message: nil))
        ]
    )
    func statusCodeMapping(status: Int, expected: EmbyError) {
        #expect(EmbyError.from(statusCode: status, body: nil) == expected)
    }

    @Test("5xx 从响应体里提取 Message")
    func extractsServerMessage() {
        let body = Data(#"{"Message": "Library is offline", "StatusCode": 500}"#.utf8)
        let error = EmbyError.from(statusCode: 500, body: body)
        #expect(error == .server(status: 500, message: "Library is offline"))
    }

    @Test("响应体不是 JSON 或没有 Message 时不崩")
    func toleratesBadBody() {
        #expect(EmbyError.from(statusCode: 500, body: Data("plain text".utf8))
            == .server(status: 500, message: nil))
        #expect(EmbyError.from(statusCode: 500, body: Data()) == .server(status: 500, message: nil))
        #expect(EmbyError.from(statusCode: 500, body: "not json") == .server(status: 500, message: nil))
    }

    @Test(
        "URLError 映射表",
        arguments: [
            (URLError.Code.timedOut, EmbyError.timeout),
            (.cancelled, .cancelled)
        ]
    )
    func urlErrorSimpleMapping(code: URLError.Code, expected: EmbyError) {
        #expect(EmbyError.from(urlError: URLError(code)) == expected)
    }

    @Test(
        "URLError 网络类错误映射为 serverUnreachable",
        arguments: [
            URLError.Code.cannotConnectToHost,
            .cannotFindHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .dnsLookupFailed
        ]
    )
    func urlErrorUnreachable(code: URLError.Code) {
        let mapped = EmbyError.from(urlError: URLError(code))
        guard case .serverUnreachable = mapped else {
            Issue.record("期望 serverUnreachable，实际 \(mapped)")
            return
        }
    }

    @Test("isRecoverable：网络抖动与 5xx 为真，认证 / 权限 / 不存在 / 解码为假")
    func recoverability() {
        #expect(EmbyError.timeout.isRecoverable)
        #expect(EmbyError.serverUnreachable("boom").isRecoverable)
        #expect(EmbyError.unknown("?").isRecoverable)

        // 5xx 是暂时性的：Emby 在扫描库、转码排队、反代后端重启时都会返回。
        // 判成不可恢复会让错误页不渲染「重试」按钮，用户在一次服务器抖动后
        // 就被永久钉死在错误页上（这是真实发生过的故障）。
        #expect(EmbyError.server(status: 500, message: nil).isRecoverable)
        #expect(EmbyError.server(status: 502, message: nil).isRecoverable)
        #expect(EmbyError.server(status: 503, message: nil).isRecoverable)

        // 这些重试多少次都不会变好，重试按钮只会误导用户。
        #expect(!EmbyError.invalidURL.isRecoverable)
        #expect(!EmbyError.unauthorized.isRecoverable)
        #expect(!EmbyError.forbidden.isRecoverable)
        #expect(!EmbyError.notFound.isRecoverable)
        #expect(!EmbyError.decoding("x").isRecoverable)
        #expect(!EmbyError.cancelled.isRecoverable)
    }

    @Test("只有 401 触发登出")
    func signOut() {
        #expect(EmbyError.unauthorized.requiresSignOut)
        #expect(!EmbyError.forbidden.requiresSignOut)
        #expect(!EmbyError.notFound.requiresSignOut)
    }

    @Test("userMessage 的 key 与文案")
    func userMessages() {
        #expect(EmbyError.timeout.userMessage.key == "error.timeout")
        #expect(EmbyError.unauthorized.userMessage.key == "error.unauthorized")
        #expect(EmbyError.invalidURL.userMessage.key == "error.invalidURL")
        #expect(EmbyError.forbidden.userMessage.key == "error.forbidden")
        #expect(EmbyError.notFound.userMessage.key == "error.notFound")
        #expect(EmbyError.decoding("x").userMessage.key == "error.decoding")
        #expect(EmbyError.cancelled.userMessage.key == "error.cancelled")
        #expect(EmbyError.unknown("x").userMessage.key == "error.unknown")
        #expect(EmbyError.serverUnreachable("x").userMessage.key == "error.serverUnreachable")
        #expect(EmbyError.server(status: 500, message: nil).userMessage.key == "error.server")
        #expect(EmbyError.server(status: 500, message: "boom").userMessage.key == "error.server.withMessage")

        // 中文默认文案非空
        #expect(!String(localized: EmbyError.timeout.userMessage).isEmpty)
        #expect(!String(localized: EmbyError.unauthorized.userMessage).isEmpty)
    }

    @Test("任意错误归一化")
    func normalizeArbitraryErrors() {
        #expect(EmbyError.from(EmbyError.notFound) == .notFound)
        #expect(EmbyError.from(URLError(.timedOut)) == .timeout)
        #expect(EmbyError.from(CancellationError()) == .cancelled)

        let decodingError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        guard case .decoding = EmbyError.from(decodingError) else {
            Issue.record("期望 decoding")
            return
        }
    }

    @Test("debugDescription 不泄露令牌")
    func debugDescriptionIsSafe() {
        let error = EmbyError.serverUnreachable("cannot connect")
        #expect(error.debugDescription.contains("serverUnreachable"))
        #expect(!error.debugDescription.contains("token"))
    }
}
