import Foundation
import Testing
@testable import PrismCore

@Suite("日志与脱敏")
struct RedactorTests {
    @Test(
        "URL query 里的令牌被替换",
        arguments: [
            "http://nas:8096/emby/Items?api_key=SECRET123",
            "http://nas:8096/emby/Items?Api_Key=SECRET123",
            "http://nas:8096/emby/Items?apikey=SECRET123",
            "http://nas:8096/emby/Items?access_token=SECRET123",
            "http://nas:8096/emby/Items?token=SECRET123"
        ]
    )
    func redactsQueryToken(url: String) {
        let redacted = Redactor.redact(url)
        #expect(!redacted.contains("SECRET123"))
        #expect(redacted.contains("***"))
    }

    @Test("多个参数只替换敏感值，保留其余 query")
    func keepsNonSensitiveQuery() {
        let url = "http://nas:8096/emby/Items/1/Images/Primary?maxHeight=300&api_key=SECRET&tag=abc"
        let redacted = Redactor.redact(url)
        #expect(redacted.contains("maxHeight=300"))
        #expect(redacted.contains("tag=abc"))
        #expect(!redacted.contains("SECRET"))
    }

    @Test("请求头里的令牌被整体替换")
    func redactsHeaders() {
        let headers = [
            "X-Emby-Token": "TOKENVALUE",
            "Authorization": #"Emby UserId="u1", Client="Prism", Token="abc123""#,
            "Accept": "application/json"
        ]
        let redacted = Redactor.redact(headers: headers)
        #expect(redacted["X-Emby-Token"] == "***")
        #expect(redacted["Authorization"] == "***")
        #expect(redacted["Accept"] == "application/json")
        #expect(!redacted.values.contains { $0.contains("TOKENVALUE") })
        #expect(!redacted.values.contains { $0.contains("abc123") })
    }

    @Test("文本里的 Authorization 头被替换（日志行场景）")
    func redactsAuthorizationLine() {
        let line = #"Authorization: Emby UserId="u1", Token="abc123", Version="4.8""#
        let redacted = Redactor.redact(line)
        #expect(!redacted.contains("abc123"))
        #expect(redacted.hasPrefix("Authorization: ***"))
    }

    @Test("敏感元数据 key 被打码，普通值里的 token 也被打码")
    func redactsMetadata() {
        let metadata = [
            "token": "abc123",
            "X-Emby-Token": "xyz",
            "url": "http://nas:8096/Items?api_key=SECRET",
            "status": "200"
        ]
        let redacted = Redactor.redact(metadata: metadata)
        #expect(redacted["token"] == "***")
        #expect(redacted["X-Emby-Token"] == "***")
        #expect(redacted["status"] == "200")
        #expect(redacted["url"]?.contains("SECRET") == false)
    }

    @Test("脱敏后仍是合法 URL")
    func redactedURLIsValid() throws {
        let url = try #require(URL(string: "http://nas:8096/Items?api_key=SECRET&x=1"))
        let redacted = Redactor.redact(url: url)
        #expect(redacted.absoluteString.contains("api_key=***"))
        #expect(redacted.host() == "nas")
    }

    @Test("空字符串与无敏感内容原样返回")
    func idempotent() {
        #expect(Redactor.redact("") == "")
        #expect(Redactor.redact("GET /Users/Me") == "GET /Users/Me")
    }

    @Test("OSLogger 落盘内容不含令牌（通过 compose 验证格式）")
    func osLoggerCompose() {
        let line = OSLogger.compose("GET /Items", metadata: Redactor.redact(metadata: [
            "api_key": "SECRET",
            "status": "200"
        ]))
        #expect(!line.contains("SECRET"))
        #expect(line.contains("api_key=***"))
        #expect(line.contains("status=200"))
    }

    @Test("LogLevel 顺序与比较")
    func logLevelOrdering() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .warning)
        #expect(LogLevel.warning < .error)
        #expect(LogLevel.error > .debug)
        #expect(LogLevel.debug.label == "DEBUG")
        #expect(LogLevel.warning.label == "WARN")
    }

    @Test("OSLogger 的级别过滤与 NoopLogger")
    func loggerFiltering() {
        // 只要能构造并调用不崩即可（真实输出进统一日志系统）
        let logger = OSLogger(subsystem: "app.prism.tests", category: "test", minimumLevel: .error)
        logger.log(.debug, "debug line", metadata: ["token": "SECRET"])
        logger.log(.error, "error line", metadata: ["token": "SECRET"])
        logger.info("convenience")
        logger.error("convenience error")

        let noop = NoopLogger()
        noop.log(.error, "nothing", metadata: [:])
        noop.warning("nothing")
    }
}
