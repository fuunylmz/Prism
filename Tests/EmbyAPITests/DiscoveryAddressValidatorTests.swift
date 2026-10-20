import Foundation
import Testing
@testable import EmbyAPI
import PrismCore

/// 地址归一化的测试。
///
/// 这是「手动填地址登录」的关键路径，覆盖面刻意做宽：真实用户会粘贴
/// 带空格、带换行、带全角字符、带反代路径、带引号的地址。
@Suite("服务器地址归一化")
struct DiscoveryAddressValidatorTests {
    // MARK: - 七种必测形态

    @Test("裸 IP 补 scheme 与默认端口 8096")
    func bareIPv4() throws {
        let url = try ServerAddressValidator.normalize("192.168.1.10")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("IP 带端口只补 scheme")
    func ipWithPort() throws {
        let url = try ServerAddressValidator.normalize("192.168.1.10:8096")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("去掉尾部斜杠")
    func trailingSlash() throws {
        let url = try ServerAddressValidator.normalize("http://192.168.1.10:8096/")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("https 默认 443，不补 8096")
    func httpsDefaultPort() throws {
        let url = try ServerAddressValidator.normalize("https://emby.example.com")
        #expect(url.absoluteString == "https://emby.example.com")
        #expect(url.port == nil)          // 交给 scheme 默认值
        #expect(ServerAddressValidator.parse("https://emby.example.com")?.port == 443)
    }

    @Test("保留反代路径前缀")
    func reverseProxyPrefix() throws {
        let url = try ServerAddressValidator.normalize("http://host/emby")
        #expect(url.absoluteString == "http://host/emby")
        #expect(ServerAddressValidator.parse("http://host/emby")?.path == "/emby")
    }

    @Test("纯域名按默认策略补 http 与 8096")
    func bareDomain() throws {
        let url = try ServerAddressValidator.normalize("emby.example.com")
        #expect(url.absoluteString == "http://emby.example.com:8096")
    }

    @Test("前后空格与换行")
    func whitespaceAndNewlines() throws {
        let url = try ServerAddressValidator.normalize("  http://192.168.1.10:8096/\n ")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("粘贴时尾部带换行 / 制表符（最常见场景）")
    func trailingNewlineOnly() throws {
        for input in [
            "http://192.168.1.10:8096\n",
            "http://192.168.1.10:8096\r\n",
            "http://192.168.1.10:8096\t",
            "192.168.1.10\n",
            "192.168.1.10:8096 \n\n",
        ] {
            let url = try ServerAddressValidator.normalize(input)
            #expect(url.absoluteString == "http://192.168.1.10:8096", "输入 \(input.debugDescription)")
        }
    }

    @Test("多行粘贴只保留第一个地址")
    func multiLinePaste() throws {
        let url = try ServerAddressValidator.normalize("http://192.168.1.10:8096\nhttp://other:8096")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("首行是空行的多行粘贴仍能解析")
    func leadingBlankLines() throws {
        let url = try ServerAddressValidator.normalize("\n\n  http://192.168.1.10:8096  \n")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("只有空行 / 空串时抛 invalidURL")
    func blankOnlyInputs() {
        for input in ["", "\n\n", "\n \n\t\n", "   \n   "] {
            #expect(throws: EmbyError.invalidURL) {
                try ServerAddressValidator.normalize(input)
            }
        }
    }

    @Test("单行内的制表符被删除")
    func tabInsideLine() throws {
        let url = try ServerAddressValidator.normalize("\thttp://192.168.1.10:8096\t")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    @Test("中文全角数字与全角冒号")
    func fullWidthCharacters() throws {
        let url = try ServerAddressValidator.normalize("１９２.１６８.１.１０：８０９６")
        #expect(url.absoluteString == "http://192.168.1.10:8096")
    }

    // MARK: - 更多真实形态

    @Test(
        "各种可接受形态",
        arguments: [
            ("http://192.168.1.10:8096", "http://192.168.1.10:8096"),
            ("http://192.168.1.10:8096//", "http://192.168.1.10:8096"),
            ("HTTP://HOST:8096", "http://host:8096"),
            ("//host:8096", "http://host:8096"),
            ("192.168.1.10:8096/emby", "http://192.168.1.10:8096/emby"),
            ("http://host:8096/emby/", "http://host:8096/emby"),
            ("https://emby.example.com:8443/emby", "https://emby.example.com:8443/emby"),
            ("http://192.168.1.10:80", "http://192.168.1.10:80"),
            ("https://host:443", "https://host:443"),
            ("http://host:8096/emby?x=1#frag", "http://host:8096/emby"),
            ("\"http://host:8096\"", "http://host:8096"),
            ("<http://host:8096>", "http://host:8096"),
            ("http://user:pass@host:8096", "http://host:8096"),
            ("192.168.1.10:", "http://192.168.1.10:8096"),
            ("[::1]:8096", "http://[::1]:8096"),
            ("http://[::1]:8096/emby", "http://[::1]:8096/emby"),
            ("192.168.1.10:65535", "http://192.168.1.10:65535"),
            ("emby.local.", "http://emby.local.:8096"),
            // 回归：路径含空格曾让 Foundation 的 percentEncodedPath setter 直接崩溃。
            ("http://host:8096/emby bad", "http://host:8096/emby%20bad"),
            ("http://host/emby/中文", "http://host/emby/%E4%B8%AD%E6%96%87"),
            ("http://host/my%20emby", "http://host/my%20emby"),
            ("http://host/100%", "http://host/100%25"),
        ]
    )
    func acceptedForms(input: String, expected: String) throws {
        let url = try ServerAddressValidator.normalize(input)
        #expect(url.absoluteString == expected)
    }

    @Test("归一化是幂等的")
    func idempotent() throws {
        for input in ["192.168.1.10", "https://emby.example.com", "http://host/emby", "emby.example.com:8096"] {
            let once = try ServerAddressValidator.normalize(input)
            let twice = try ServerAddressValidator.normalize(once.absoluteString)
            #expect(once == twice, "重复归一化不应改变结果：\(input)")
        }
    }

    // MARK: - 非法输入

    @Test(
        "非法输入一律抛 invalidURL",
        arguments: [
            "",
            "   ",
            "\n\t",
            "ftp://x",
            "ftp://192.168.1.10:8096",
            "file:///etc/passwd",
            "http://",
            "http:///emby",
            "!!!",
            "^^^",
            "中文乱码没有点",
            "192.168.1.10:99999",
            "192.168.1.10:abc",
            "192.168.1.10:8096:80",
            "host:0",
            "mailto:x@y",
            "::1",
            "例子.测试",
        ]
    )
    func rejectedForms(input: String) {
        #expect(throws: EmbyError.invalidURL) {
            try ServerAddressValidator.normalize(input)
        }
    }

    @Test("含空格的路径不会崩溃（回归）")
    func pathWithSpaceDoesNotCrash() throws {
        let url = try ServerAddressValidator.normalize("http://host:8096/my emby")
        #expect(url.absoluteString == "http://host:8096/my%20emby")
    }

    @Test("parse 对非法输入返回 nil 而不抛错")
    func parseReturnsNil() {
        #expect(ServerAddressValidator.parse("ftp://x") == nil)
        #expect(ServerAddressValidator.parse("") == nil)
        #expect(ServerAddressValidator.parse("!!!") == nil)
    }

    // MARK: - 结构化字段

    @Test("parse 暴露 host / port / path")
    func parsedFields() throws {
        let parsed = try #require(ServerAddressValidator.parse("https://emby.example.com:8443/emby"))
        #expect(parsed.scheme == "https")
        #expect(parsed.host == "emby.example.com")
        #expect(parsed.port == 8443)
        #expect(parsed.path == "/emby")
        #expect(parsed.url.absoluteString == "https://emby.example.com:8443/emby")
    }

    @Test("主机名统一小写")
    func hostLowercased() throws {
        let parsed = try #require(ServerAddressValidator.parse("HTTP://EMBY.Example.COM:8096"))
        #expect(parsed.host == "emby.example.com")
    }

    @Test("默认策略常量的取值")
    func constants() {
        #expect(ServerAddressValidator.defaultScheme == "http")
        #expect(ServerAddressValidator.defaultPort == 8096)
        #expect(ServerAddressValidator.httpsDefaultPort == 443)
    }
}
