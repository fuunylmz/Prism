import Foundation
import Testing
@testable import EmbyAPI
import PrismCore

/// 发现流程的测试（全部使用脚本化假传输，不碰真实网络）。
@Suite("服务器发现流程")
struct DiscoveryFlowTests {
    /// 三个不同服务器 + 一条重复回包（同一 Id、不同地址，模拟多网卡）。
    private static let threeServers: [(json: String, sourceHost: String?)] = [
        (#"{"Address":"http://192.168.1.51:8096","Id":"server-a","Name":"EMBY"}"#, "192.168.1.51"),
        (#"{"Address":"http://192.168.1.52:8096","Id":"server-b","Name":"SynologyNAS"}"#, "192.168.1.52"),
        (#"{"Address":"http://10.0.0.9:8096","Id":"server-a","Name":"EMBY"}"#, "10.0.0.9"),
        (#"{"Address":"http://192.168.1.53:8096","Id":"server-c","Name":"Attic"}"#, "192.168.1.53"),
    ]

    @Test("发送正确的广播报文与端口")
    func sendsBroadcast() async {
        let transport = FakeDiscoveryTransport(payloads: [])
        let discovery = ServerDiscovery(port: 7359, timeout: .milliseconds(50), transport: transport)

        for await _ in discovery.discover() {}

        let recorded = transport.recorded
        #expect(recorded.startedPort == 7359)
        #expect(recorded.sentPayloads.count == 1)
        #expect(recorded.sentPayloads.first == DiscoveryPacket.requestData)
        #expect(recorded.cancelCount >= 1)
    }

    @Test("收集 3 个服务器、按 Id 去重、顺序稳定")
    func collectsAndDeduplicates() async {
        let transport = FakeDiscoveryTransport(payloads: Self.threeServers)
        let discovery = ServerDiscovery(timeout: .milliseconds(100), transport: transport)

        var received: [DiscoveredServer] = []
        for await server in discovery.discover() {
            received.append(server)
        }

        #expect(received.count == 3)
        #expect(received.map(\.address) == ["192.168.1.51", "192.168.1.52", "192.168.1.53"])
        #expect(received.map(\.name) == ["EMBY", "SynologyNAS", "Attic"])
        #expect(received.map(\.id) == ["192.168.1.51:8096", "192.168.1.52:8096", "192.168.1.53:8096"])
        // 重复的 server-a（10.0.0.9）被丢弃。
        #expect(!received.contains { $0.address == "10.0.0.9" })
    }

    @Test("discoverAll 与流式结果一致")
    func discoverAllMatchesStream() async {
        let transport = FakeDiscoveryTransport(payloads: Self.threeServers)
        let discovery = ServerDiscovery(timeout: .milliseconds(100), transport: transport)
        let servers = await discovery.discoverAll()
        #expect(servers.map(\.address) == ["192.168.1.51", "192.168.1.52", "192.168.1.53"])
    }

    @Test("没有响应时流在超时后正常结束、不抛错")
    func timeoutEndsStreamQuietly() async {
        let transport = FakeDiscoveryTransport(payloads: [])
        let discovery = ServerDiscovery(timeout: .milliseconds(200), transport: transport)

        let clock = ContinuousClock()
        let start = clock.now
        var count = 0
        for await _ in discovery.discover() { count += 1 }
        let elapsed = start.duration(to: clock.now)

        #expect(count == 0)
        #expect(elapsed >= .milliseconds(150), "流应等到超时才结束，实际 \(elapsed)")
        #expect(elapsed < .seconds(3), "不应远超超时时间，实际 \(elapsed)")
    }

    @Test("transport 启动失败等价于没找到，流正常结束")
    func startFailureEndsStream() async {
        let transport = FakeDiscoveryTransport(startError: .serverUnreachable("socket 建不起来"))
        let discovery = ServerDiscovery(timeout: .seconds(1), transport: transport)

        var count = 0
        for await _ in discovery.discover() { count += 1 }

        #expect(count == 0)
        #expect(transport.recorded.sentPayloads.isEmpty)
        #expect(transport.recorded.cancelCount >= 1)
    }

    @Test("广播发送失败等价于没找到，流正常结束")
    func sendFailureEndsStream() async {
        let transport = FakeDiscoveryTransport(sendError: .serverUnreachable("广播发不出去"))
        let discovery = ServerDiscovery(timeout: .seconds(1), transport: transport)

        var count = 0
        for await _ in discovery.discover() { count += 1 }
        #expect(count == 0)
    }

    @Test("没有 transport 时返回空流")
    func missingTransportYieldsEmptyStream() async {
        let discovery = ServerDiscovery(timeout: .seconds(1), transport: nil)
        var count = 0
        for await _ in discovery.discover() { count += 1 }
        #expect(count == 0)
    }

    @Test("夹杂非法报文时跳过，不影响其他结果")
    func skipsMalformedReplies() async {
        let transport = FakeDiscoveryTransport(payloads: [
            ("not json", "192.168.1.60"),
            (#"{"Foo":"bar"}"#, "192.168.1.61"),
            (#"{"Address":"http://192.168.1.62:8096","Id":"server-x","Name":"X"}"#, "192.168.1.62"),
            ("[]", "192.168.1.63"),
        ])
        let discovery = ServerDiscovery(timeout: .milliseconds(100), transport: transport)

        var received: [DiscoveredServer] = []
        for await server in discovery.discover() { received.append(server) }

        #expect(received.count == 1)
        #expect(received.first?.address == "192.168.1.62")
    }

    @Test("Id 缺失时按地址去重")
    func deduplicatesWithoutId() async {
        let transport = FakeDiscoveryTransport(payloads: [
            (#"{"Address":"http://192.168.1.70:8096","Name":"A"}"#, "192.168.1.70"),
            (#"{"Address":"http://192.168.1.70:8096","Name":"A"}"#, "192.168.1.70"),
        ])
        let discovery = ServerDiscovery(timeout: .milliseconds(100), transport: transport)

        var received: [DiscoveredServer] = []
        for await server in discovery.discover() { received.append(server) }
        #expect(received.count == 1)
    }

    @Test("消费者提前退出时取消内部任务")
    func cancelsOnEarlyExit() async {
        let transport = FakeDiscoveryTransport(payloads: Self.threeServers)
        let discovery = ServerDiscovery(timeout: .seconds(5), transport: transport)

        for await server in discovery.discover() {
            #expect(server.address == "192.168.1.51")
            break
        }

        // 给取消一个调度窗口；`onTermination` 是异步触发的。
        for _ in 0..<20 where transport.recorded.cancelCount == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(transport.recorded.cancelCount >= 1)
    }

    @Test("初始化参数的默认值")
    func defaults() {
        let discovery = ServerDiscovery()
        #expect(discovery.port == 7359)
        #expect(discovery.timeout == .seconds(3))
    }
}
