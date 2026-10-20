import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

@Suite("错误归一化")
struct ClientErrorMappingTests {
    private let errorBody = Data(#"{"Message":"boom"}"#.utf8)

    @Test(
        "状态码映射表（200 表示成功，不是错误）",
        arguments: zip(
            [200, 401, 403, 404, 408, 500],
            [
                EmbyError?.none,
                EmbyError?.some(.unauthorized),
                EmbyError?.some(.forbidden),
                EmbyError?.some(.notFound),
                EmbyError?.some(.timeout),
                EmbyError?.some(.server(status: 500, message: "boom"))
            ]
        )
    )
    func statusCodeMapping(status: Int, expected: EmbyError?) {
        let mapped = EmbyClientError.error(statusCode: status, body: errorBody)
        #expect(mapped == expected)
    }

    @Test(
        "客户端按状态码抛对应错误",
        arguments: zip(
            [401, 403, 404, 500],
            [
                EmbyError.unauthorized,
                .forbidden,
                .notFound,
                .server(status: 500, message: "boom")
            ]
        )
    )
    func clientThrowsMappedError(status: Int, expected: EmbyError) async throws {
        let mock = MockServer(.json(#"{"Message":"boom"}"#, statusCode: status))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        await #expect(throws: expected) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
        // 4xx 不重试；500 在 maxRetries == 0 时也只发一次。
        #expect(mock.requestCount == 1)
    }

    @Test("URLError 映射表")
    func urlErrorMapping() {
        #expect(EmbyClientError.error(urlError: URLError(.timedOut)) == .timeout)
        #expect(EmbyClientError.error(urlError: URLError(.cancelled)) == .cancelled)

        let unreachable = EmbyClientError.error(urlError: URLError(.cannotConnectToHost))
        guard case .serverUnreachable = unreachable else {
            Issue.record("cannotConnectToHost 应映射为 serverUnreachable，实际 \(unreachable)")
            return
        }

        let dns = EmbyClientError.error(urlError: URLError(.cannotFindHost))
        guard case .serverUnreachable = dns else {
            Issue.record("cannotFindHost 应映射为 serverUnreachable，实际 \(dns)")
            return
        }
    }

    @Test("超时：客户端抛 .timeout，且不重试（策略关闭）")
    func clientTimeout() async {
        let mock = MockServer(.failure(.timedOut))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        await #expect(throws: EmbyError.timeout) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
        #expect(mock.requestCount == 1)
    }

    @Test("连不上主机：客户端抛 .serverUnreachable")
    func clientUnreachable() async {
        let mock = MockServer(.failure(.cannotConnectToHost))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        do {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
            Issue.record("应当抛错")
        } catch let error as EmbyError {
            guard case .serverUnreachable = error else {
                Issue.record("应映射为 serverUnreachable，实际 \(error)")
                return
            }
        } catch {
            Issue.record("应抛 EmbyError，实际 \(error)")
        }
    }

    @Test("取消：客户端抛 .cancelled")
    func clientCancelled() async {
        let mock = MockServer(.failure(.cancelled))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        await #expect(throws: EmbyError.cancelled) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
    }

    @Test("解码失败 → .decoding，且描述里含目标类型名")
    func decodingFailure() async {
        let mock = MockServer(.json(#"{"Unexpected":1}"#))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        do {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
            Issue.record("应当抛解码错误")
        } catch let error as EmbyError {
            guard case let .decoding(detail) = error else {
                Issue.record("应映射为 decoding，实际 \(error)")
                return
            }
            #expect(detail.contains("TestPayload"))
            #expect(detail.contains("解码"))
        } catch {
            Issue.record("应抛 EmbyError，实际 \(error)")
        }
    }

    @Test("解码失败的错误描述不超过 512 字符")
    func decodingFailureTruncated() {
        let huge = String(repeating: "x", count: 5000)
        let error = EmbyClientError.decoding(
            TestPayload.self,
            underlying: DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: huge)
            )
        )
        guard case let .decoding(detail) = error else {
            Issue.record("应为 decoding")
            return
        }
        #expect(detail.count <= EmbyClientError.maxBodyLength)
    }

    @Test("响应体截断到 512 字符，避免日志爆炸")
    func bodyTruncation() {
        let long = String(repeating: "A", count: 2000)
        let body = Data(#"{"Message":"\#(long)"}"#.utf8)
        let error = EmbyClientError.error(statusCode: 500, body: body)

        guard case let .server(status, message) = error else {
            Issue.record("应为 server，实际 \(String(describing: error))")
            return
        }
        #expect(status == 500)
        let text = message ?? ""
        #expect(text.count <= EmbyClientError.maxBodyLength)
        #expect(text.hasSuffix("…"))
    }

    @Test("非 JSON 错误体（反代 HTML）也能给出可读消息")
    func nonJSONErrorBody() {
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        let error = EmbyClientError.error(statusCode: 502, body: html)

        guard case let .server(status, message) = error else {
            Issue.record("应为 server")
            return
        }
        #expect(status == 502)
        #expect(message?.contains("502 Bad Gateway") == true)
    }

    @Test("二进制响应体不会污染错误消息")
    func binaryErrorBody() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let error = EmbyClientError.error(statusCode: 500, body: png)
        #expect(error == .server(status: 500, message: nil))
    }

    @Test("204 无响应体：send 不抛错")
    func emptyResponse() async throws {
        let mock = MockServer(MockResponse(statusCode: 204))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        try await client.send(
            TestEndpoint(
                path: "/Sessions/Playing/Stopped",
                method: .post,
                body: Data("{}".utf8)
            )
        )
        #expect(mock.requestCount == 1)
    }

    @Test("data(_:) 原样返回二进制（图片场景）")
    func rawData() async throws {
        // 最小 PNG 头 + 任意字节，验证不做任何解码/改写。
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x10])
        let mock = MockServer(.bytes(bytes, contentType: "image/png"))
        let client = await TestFixtures.client(mock: mock, token: "TKN")

        let received = try await client.data(TestEndpoint(path: "/Items/1/Images/Primary"))
        #expect(received == bytes)
        #expect(mock.requestCount == 1)
    }
}
