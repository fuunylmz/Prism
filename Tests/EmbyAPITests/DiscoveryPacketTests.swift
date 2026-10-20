import Foundation
import Testing
@testable import EmbyAPI
import PrismCore

/// 发现报文（UDP 7359）编解码的测试。
@Suite("发现报文解析")
struct DiscoveryPacketTests {
    // MARK: - 请求报文

    @Test("请求正文逐字匹配官方文档")
    func requestText() {
        // ✅ https://dev.emby.media/doc/restapi/Locating-the-Server.html
        #expect(DiscoveryPacket.requestText == "who is EmbyServer?")
        #expect(String(decoding: DiscoveryPacket.requestData, as: UTF8.self) == "who is EmbyServer?")
    }

    @Test("请求正文没有换行、没有 BOM")
    func requestDataIsBareText() {
        #expect(DiscoveryPacket.requestData.count == 18)
        #expect(!DiscoveryPacket.requestData.contains(0x0A))
        #expect(!DiscoveryPacket.requestData.contains(0x0D))
        #expect(!DiscoveryPacket.requestData.contains(0x00))
    }

    @Test("默认端口是 7359")
    func defaultPort() {
        #expect(DiscoveryPacket.defaultPort == 7359)
    }

    // MARK: - 正常响应

    @Test("解析官方文档描述的三字段响应")
    func decodeStandardReply() throws {
        let json = #"{"Address":"http://192.168.1.51:8096","Id":"f35bc7160c384ebf9d8bd83ae7e78d60","Name":"EMBY"}"#
        let reply = try #require(DiscoveryPacket.decode(Data(json.utf8)))
        #expect(reply.address == "http://192.168.1.51:8096")
        #expect(reply.serverId == "f35bc7160c384ebf9d8bd83ae7e78d60")
        #expect(reply.name == "EMBY")
        #expect(reply.endpointAddress == nil)
        #expect(reply.hasUsableAddress)
    }

    @Test("Address 带端口时正确拆出 host 与 port")
    func addressWithPort() throws {
        let json = #"{"Address":"http://192.168.1.51:8096","Id":"abc","Name":"SynologyNAS"}"#
        let server = try #require(DiscoveryPacket.server(from: Data(json.utf8), receivedFrom: "192.168.1.51"))
        #expect(server.address == "192.168.1.51")
        #expect(server.port == 8096)
        #expect(server.id == "192.168.1.51:8096")
        #expect(server.baseURL.absoluteString == "http://192.168.1.51:8096")
        #expect(server.name == "SynologyNAS")
    }

    @Test("Address 是裸 host 时补默认端口")
    func addressWithoutPort() throws {
        let json = #"{"Address":"192.168.1.51","Id":"abc","Name":"EMBY"}"#
        let server = try #require(DiscoveryPacket.server(from: Data(json.utf8), receivedFrom: nil))
        #expect(server.address == "192.168.1.51")
        #expect(server.port == 8096)
        #expect(server.baseURL.absoluteString == "http://192.168.1.51:8096")
    }

    @Test("Address 带反代前缀时保留路径")
    func addressWithProxyPath() throws {
        let json = #"{"Address":"https://emby.example.com/emby","Id":"abc","Name":"EMBY"}"#
        let server = try #require(DiscoveryPacket.server(from: Data(json.utf8), receivedFrom: nil))
        #expect(server.baseURL.absoluteString == "https://emby.example.com/emby")
        #expect(server.port == 443)
        #expect(server.id == "emby.example.com:443")
    }

    // MARK: - 容错

    @Test("字段缺失不抛错，只让对应属性为 nil")
    func missingFields() throws {
        let onlyAddress = try #require(DiscoveryPacket.decode(Data(#"{"Address":"http://10.0.0.2:8096"}"#.utf8)))
        #expect(onlyAddress.serverId == nil)
        #expect(onlyAddress.name == nil)

        let server = try #require(onlyAddress.server(receivedFrom: nil))
        #expect(server.port == 8096)
        // 名字缺失时退化为 "地址:端口"，UI 永远有东西可显示。
        #expect(server.name == "10.0.0.2:8096")

        let onlyName = try #require(DiscoveryPacket.decode(Data(#"{"Name":"EMBY"}"#.utf8)))
        #expect(onlyName.server(receivedFrom: nil) == nil)   // 没有地址，无法连接
        #expect(onlyName.hasUsableAddress == false)
    }

    @Test("只有 EndpointAddress 时用发送方信息兜底")
    func endpointAddressFallback() throws {
        let json = #"{"Id":"abc","Name":"EMBY","EndpointAddress":"192.168.1.77"}"#
        let reply = try #require(DiscoveryPacket.decode(Data(json.utf8)))
        let server = try #require(reply.server(receivedFrom: nil))
        #expect(server.address == "192.168.1.77")
        #expect(server.port == 8096)
    }

    @Test("没有 Address 也没有 EndpointAddress 时用回包源 IP")
    func sourceHostFallback() throws {
        let json = #"{"Id":"abc","Name":"EMBY"}"#
        let server = try #require(DiscoveryPacket.server(from: Data(json.utf8), receivedFrom: "10.0.0.9"))
        #expect(server.address == "10.0.0.9")
        #expect(server.port == 8096)
    }

    @Test("字段名大小写不敏感")
    func caseInsensitiveKeys() throws {
        let json = #"{"address":"http://10.0.0.2:8096","id":"abc","name":"EMBY"}"#
        let reply = try #require(DiscoveryPacket.decode(Data(json.utf8)))
        #expect(reply.address == "http://10.0.0.2:8096")
        #expect(reply.serverId == "abc")
        #expect(reply.name == "EMBY")
    }

    @Test("数值型 Id 转成字符串")
    func numericId() throws {
        let reply = try #require(DiscoveryPacket.decode(Data(#"{"Address":"http://10.0.0.2:8096","Id":12345}"#.utf8)))
        #expect(reply.serverId == "12345")
    }

    @Test("尾部带 NUL 或换行也能解析")
    func trailingJunk() throws {
        let json = #"{"Address":"http://10.0.0.2:8096","Id":"abc","Name":"EMBY"}"#
        var data = Data(json.utf8)
        data.append(contentsOf: [0x00, 0x0A, 0x00])
        let reply = try #require(DiscoveryPacket.decode(data))
        #expect(reply.serverId == "abc")
    }

    @Test("尾部带任意垃圾（不止 NUL）也能解析")
    func trailingGarbageAfterBrace() throws {
        let json = #"{"Address":"http://10.0.0.2:8096","Id":"abc","Name":"EMBY"}"#
        let reply = try #require(DiscoveryPacket.decode(Data((json + "\u{01}junk").utf8)))
        #expect(reply.serverId == "abc")
    }

    @Test("头部带 NUL 填充也能解析")
    func leadingJunk() throws {
        let json = #"{"Address":"http://10.0.0.2:8096","Id":"abc","Name":"EMBY"}"#
        var data = Data([0x00, 0x00, 0x0A])
        data.append(contentsOf: Data(json.utf8))
        let reply = try #require(DiscoveryPacket.decode(data))
        #expect(reply.serverId == "abc")
    }

    @Test("空白字段视为缺失")
    func blankFields() throws {
        let reply = try #require(DiscoveryPacket.decode(Data(#"{"Address":"  ","Id":"","Name":" EMBY "}"#.utf8)))
        #expect(reply.address == nil)
        #expect(reply.serverId == nil)
        #expect(reply.name == "EMBY")
    }

    @Test(
        "非法内容返回 nil 而不是崩溃",
        arguments: [
            "",
            "not json at all",
            "[]",
            "[1,2,3]",
            "\"just a string\"",
            "123",
            "{}",
            #"{"Foo":"bar"}"#,
            #"{"Address":null,"Id":null}"#,
        ]
    )
    func invalidPayloads(payload: String) {
        #expect(DiscoveryPacket.decode(Data(payload.utf8)) == nil)
    }

    @Test("二进制垃圾不崩溃")
    func binaryGarbage() {
        let garbage = Data((0..<64).map { UInt8($0 &* 37 & 0xFF) })
        #expect(DiscoveryPacket.decode(garbage) == nil)
    }

    // MARK: - DiscoveredServer 自身

    @Test("DiscoveredServer 的 id 按契约拼装")
    func discoveredServerIdentity() throws {
        let server = DiscoveredServer(address: "192.168.1.10", port: 8096)
        #expect(server.id == "192.168.1.10:8096")
        #expect(server.name == "192.168.1.10:8096")
        #expect(server.baseURL.absoluteString == "http://192.168.1.10:8096")
        #expect(server.isSecure == false)

        let named = DiscoveredServer(address: "emby.example.com", port: 8920, name: "Home")
        #expect(named.name == "Home")
        #expect(named.id == "emby.example.com:8920")

        let https = DiscoveredServer(
            id: "emby.example.com:443",
            name: "Home",
            address: "emby.example.com",
            port: 443,
            baseURL: try #require(URL(string: "https://emby.example.com"))
        )
        #expect(https.isSecure)
    }
}
