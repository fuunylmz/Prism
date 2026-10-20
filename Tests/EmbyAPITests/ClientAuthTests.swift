import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

@Suite("鉴权头与令牌")
struct ClientAuthTests {
    /// 期望值的拼装器（避免手写超长转义字符串时看错字段）。
    ///
    /// 注意首词 `Emby` 与字段之间是空格，字段之间才是「逗号 + 空格」——
    /// 这里刻意不复用被测代码的拼装方式，而是按官方 schema 原文逐字拼。
    private func expectedHeader(userId: String?, token: String?) -> String {
        var fields: [String] = []
        if let userId {
            fields.append("UserId=\"\(userId)\"")
        }
        fields.append("Client=\"Prism\"")
        fields.append("Device=\"TestMac\"")
        fields.append("DeviceId=\"TEST-DEVICE-ID\"")
        fields.append("Version=\"1.0.0\"")
        if let token {
            fields.append("Token=\"\(token)\"")
        }
        return "Emby " + fields.joined(separator: ", ")
    }

    @Test("有 token：鉴权头逐字段正确，并额外带 X-Emby-Token")
    func headerWithToken() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let client = await TestFixtures.client(mock: mock, token: "TKN-123", userId: "u1")

        let payload: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        #expect(payload.id == "u1")

        let request = try #require(mock.requests.first)
        let header = try #require(request.value(forHTTPHeaderField: "X-Emby-Authorization"))

        #expect(header == expectedHeader(userId: "u1", token: "TKN-123"))
        // 逐字段断言，避免「整串相等但字段顺序/空格错了也过」。
        #expect(header.hasPrefix("Emby "))
        #expect(header.contains("UserId=\"u1\""))
        #expect(header.contains("Client=\"Prism\""))
        #expect(header.contains("Device=\"TestMac\""))
        #expect(header.contains("DeviceId=\"TEST-DEVICE-ID\""))
        #expect(header.contains("Version=\"1.0.0\""))
        #expect(header.contains("Token=\"TKN-123\""))
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "TKN-123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("无 token：省略 Token= 与 UserId=，其余字段保留")
    func headerWithoutToken() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let client = await TestFixtures.client(mock: mock)

        let _: TestPayload = try await client.send(
            TestEndpoint(path: "/System/Info/Public", requiresAuth: false)
        )

        let request = try #require(mock.requests.first)
        let header = try #require(request.value(forHTTPHeaderField: "X-Emby-Authorization"))

        #expect(header == expectedHeader(userId: nil, token: nil))
        #expect(!header.contains("Token="))
        #expect(!header.contains("UserId="))
        #expect(header.contains("Client=\"Prism\""))
        #expect(header.contains("Device=\"TestMac\""))
        #expect(header.contains("DeviceId=\"TEST-DEVICE-ID\""))
        #expect(header.contains("Version=\"1.0.0\""))
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }

    @Test("headerValue 直接调用：有/无 token 两种形态")
    func headerValueDirect() {
        let header = AuthHeader(identity: TestFixtures.identity())

        #expect(header.headerValue(userId: nil, token: nil) == expectedHeader(userId: nil, token: nil))
        #expect(header.headerValue(userId: "u1", token: "TKN") == expectedHeader(userId: "u1", token: "TKN"))
        // 只有 token 没有 userId：保留 Token，省略 UserId。
        #expect(header.headerValue(userId: nil, token: "TKN") == expectedHeader(userId: nil, token: "TKN"))
    }

    @Test("设备名里的引号/换行不会破坏头结构")
    func sanitizesDeviceName() {
        let header = AuthHeader(
            client: "Prism",
            device: "Bob \"Mac\"\nMini",
            deviceId: "D1",
            version: "1.0.0"
        )
        let value = header.headerValue(userId: nil, token: nil)
        #expect(value == "Emby Client=\"Prism\", Device=\"Bob Mac Mini\", DeviceId=\"D1\", Version=\"1.0.0\"")
        #expect(!value.contains("\n"))
    }

    @Test("requiresAuth 且无 token：抛 unauthorized 且一个请求都不发")
    func unauthorizedWithoutToken() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let sleeper = RecordingSleeper()
        let client = await TestFixtures.client(mock: mock, sleeper: sleeper)

        await #expect(throws: EmbyError.unauthorized) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
        #expect(mock.requestCount == 0)
        #expect(mock.handlerCallCount == 0)
        #expect(sleeper.sleeps.isEmpty)
    }

    @Test("requiresAuth == false 时无 token 也照常发请求")
    func publicEndpointWithoutToken() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let client = await TestFixtures.client(mock: mock)

        let payload: TestPayload = try await client.send(
            TestEndpoint(path: "/System/Info/Public", requiresAuth: false)
        )
        #expect(payload.name == "Alice")
        #expect(mock.requestCount == 1)
    }

    @Test("setAccessToken(nil) 后重新变为未授权")
    func clearingToken() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let client = await TestFixtures.client(mock: mock, token: "TKN")
        await client.setAccessToken(nil)

        await #expect(throws: EmbyError.unauthorized) {
            let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        }
        #expect(mock.requestCount == 0)
    }

    @Test("setSession 同时写入 token 与 userId")
    func setSession() async throws {
        let mock = MockServer(.json(#"{"Id":"u1","Name":"Alice"}"#))
        let client = await TestFixtures.client(mock: mock)

        let session = AuthSession(
            serverId: "srv-test",
            userId: "u9",
            accessToken: "TKN-9",
            user: EmbyUser(id: "u9", name: "Nine", serverId: "srv-test")
        )
        await client.setSession(session)

        let _: TestPayload = try await client.send(TestEndpoint(path: "/Users/Me"))
        let request = try #require(mock.requests.first)
        let header = try #require(request.value(forHTTPHeaderField: "X-Emby-Authorization"))
        #expect(header.contains("UserId=\"u9\""))
        #expect(header.contains("Token=\"TKN-9\""))
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "TKN-9")
    }

    @Test("baseURL 与服务器连接一致")
    func exposesBaseURL() async {
        let mock = MockServer(.json("{}"))
        let client = await TestFixtures.client(mock: mock, baseURL: "https://domain/emby")
        #expect(client.baseURL.absoluteString == "https://domain/emby")
    }
}
