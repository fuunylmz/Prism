import Foundation
import EmbyAPI
import PrismCore
import Testing
@testable import PrismUI

@Suite("搜索图片地址")
struct SearchImageURLTests {
    @Test("按回退来源的真实图片类型生成地址")
    func usesResolvedImageKind() throws {
        let server = ServerConnection(
            id: "server-1",
            name: "测试服务器",
            baseURL: try #require(URL(string: "https://emby.example.com/emby"))
        )
        let source = EmbySearchDataSource(
            client: EmbyClient(server: server, identity: .current()),
            userId: "user-1",
            apiKey: "token",
            baseURL: server.baseURL
        )
        let url = try #require(source.imageURL(
            for: "parent-1",
            kind: .thumb,
            tag: "thumb-tag",
            maxWidth: 480
        ))

        #expect(url.path == "/emby/Items/parent-1/Images/Thumb")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "tag", value: "thumb-tag")
        ) == true)
    }
}
