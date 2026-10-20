import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

@Suite("EmbyClient 基址拼接与请求构造")
struct ClientRequestBuilderTests {
    private func builder(_ base: String) -> RequestBuilder {
        RequestBuilder(baseURL: TestFixtures.url(base), identity: TestFixtures.identity())
    }

    @Test(
        "基址 5 种形态都能正确拼接（含反代前缀与尾斜杠）",
        arguments: zip(
            [
                "http://host:8096",
                "http://host:8096/",
                "http://host:8096/emby",
                "https://domain/emby",
                "https://domain/emby/"
            ],
            [
                "http://host:8096/Users/Me",
                "http://host:8096/Users/Me",
                "http://host:8096/emby/Users/Me",
                "https://domain/emby/Users/Me",
                "https://domain/emby/Users/Me"
            ]
        )
    )
    func baseURLJoining(base: String, expected: String) throws {
        let request = try builder(base).build(
            TestEndpoint(path: "/Users/Me"),
            token: nil,
            userId: nil
        )
        let absolute = try #require(request.url?.absoluteString)
        #expect(absolute == expected)
        // 不能出现 `//` 造成的空路径段。
        #expect(!absolute.contains("//Users"))
        #expect(request.url?.path == URL(string: expected)?.path)
    }

    @Test("基址带反代前缀且端点路径带 query 时，前缀不丢")
    func reverseProxyPrefixWithQuery() throws {
        let request = try builder("https://domain/emby/").build(
            TestEndpoint(path: "/Users/abc/Items", query: ["Limit": "20"]),
            token: nil,
            userId: nil
        )
        #expect(
            request.url?.absoluteString
                == "https://domain/emby/Users/abc/Items?Limit=20"
        )
    }

    @Test("query 按 key 排序，空格编码为 %20 且转义 & = +")
    func queryEncoding() throws {
        let endpoint = TestEndpoint(
            path: "/Users/abc/Items",
            query: [
                "SearchTerm": "a b&c",
                "Limit": "20",
                "Fields": "Overview,Genres"
            ]
        )
        let url = try builder("http://host:8096").url(for: endpoint)

        // 排序稳定：Fields < Limit < SearchTerm。
        #expect(
            url.absoluteString
                == "http://host:8096/Users/abc/Items"
                + "?Fields=Overview,Genres&Limit=20&SearchTerm=a%20b%26c"
        )
        // 与端点自己的 `resolvedPath()` 逐字一致（两处编码规则必须相同）。
        #expect(url.absoluteString.hasSuffix(endpoint.resolvedPath()))
        #expect(!url.absoluteString.contains("+"))
    }

    @Test("无 query 时不产生问号")
    func noQuery() throws {
        let url = try builder("http://host:8096").url(for: TestEndpoint(path: "/System/Info/Public"))
        #expect(url.absoluteString == "http://host:8096/System/Info/Public")
        #expect(!url.absoluteString.contains("?"))
    }

    @Test("GET 无 body：不设 Content-Type，Accept 固定 JSON")
    func headersForGet() throws {
        let request = try builder("http://host:8096").build(
            TestEndpoint(path: "/Users/Me"),
            token: "TKN",
            userId: "u1"
        )
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == RequestBuilder.defaultTimeout)
    }

    @Test("有 body 时按端点 contentType 设置，缺省 application/json")
    func headersForPost() throws {
        let payload = Data(#"{"Pw":"secret"}"#.utf8)

        let defaulted = try builder("http://host:8096").build(
            TestEndpoint(path: "/Users/AuthenticateByName", method: .post, body: payload),
            token: nil,
            userId: nil
        )
        #expect(defaulted.httpMethod == "POST")
        #expect(defaulted.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(defaulted.httpBody == payload)

        let custom = try builder("http://host:8096").build(
            TestEndpoint(
                path: "/Items",
                method: .post,
                body: payload,
                contentType: "application/xml"
            ),
            token: nil,
            userId: nil
        )
        #expect(custom.value(forHTTPHeaderField: "Content-Type") == "application/xml")
    }

    @Test("端点声明的超时与缓存策略被采用")
    func timeoutAndCachePolicy() throws {
        let request = try builder("http://host:8096").build(
            TestEndpoint(
                path: "/Items/1/Images/Primary",
                timeout: 7,
                cachePolicy: .returnCacheDataElseLoad
            ),
            token: "TKN",
            userId: nil
        )
        #expect(request.timeoutInterval == 7)
        #expect(request.cachePolicy == .returnCacheDataElseLoad)
    }

    @Test("非法基址抛 invalidURL（不发请求）")
    func invalidBaseURL() {
        let requestBuilder = RequestBuilder(
            baseURL: TestFixtures.url("about:blank"),
            identity: TestFixtures.identity()
        )
        #expect(throws: EmbyError.invalidURL) {
            _ = try requestBuilder.url(for: TestEndpoint(path: "/Users/Me"))
        }
    }

    @Test("端点路径缺少前导斜杠时自动补上")
    func pathWithoutLeadingSlash() throws {
        let url = try builder("http://host:8096/emby").url(for: TestEndpoint(path: "Users/Me"))
        #expect(url.absoluteString == "http://host:8096/emby/Users/Me")
    }
}
