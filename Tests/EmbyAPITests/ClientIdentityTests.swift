import Foundation
import PrismCore
import Testing

@testable import EmbyAPI

@Suite("客户端身份")
struct ClientIdentityTests {
    /// 每个测试用独立 suite，避免污染真实 `UserDefaults`。
    private func makeDefaults() -> UserDefaults {
        let suite = "app.prism.tests.identity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建 UserDefaults suite：\(suite)")
            return .standard
        }
        return defaults
    }

    @Test("默认客户端名是 Prism")
    func defaultAppName() {
        let identity = ClientIdentity(appVersion: "1.2.3", deviceName: "Mac", deviceId: "D1")
        #expect(identity.appName == "Prism")
        #expect(ClientIdentity.defaultAppName == "Prism")
    }

    @Test("版本号取自 CFBundleShortVersionString，缺失或空时回退 0.0.0")
    func appVersionFromInfoDictionary() {
        #expect(
            ClientIdentity.appVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.0"])
                == "0.1.0"
        )
        #expect(
            ClientIdentity.appVersion(infoDictionary: ["CFBundleShortVersionString": " 0.2.0 "])
                == "0.2.0"
        )
        #expect(ClientIdentity.appVersion(infoDictionary: [:]) == ClientIdentity.fallbackAppVersion)
        #expect(
            ClientIdentity.appVersion(infoDictionary: ["CFBundleShortVersionString": "   "])
                == ClientIdentity.fallbackAppVersion
        )
        #expect(ClientIdentity.appVersion(infoDictionary: nil) == "0.0.0")
    }

    @Test("deviceId 持久化：两次取值相同，reset 后才变化")
    func deviceIdIsStable() {
        let defaults = makeDefaults()
        let key = "prism.test.deviceId"

        let first = DeviceID.current(in: defaults, key: key)
        let second = DeviceID.current(in: defaults, key: key)
        #expect(!first.isEmpty)
        #expect(first == second)

        DeviceID.reset(in: defaults, key: key)
        let third = DeviceID.current(in: defaults, key: key)
        #expect(third != first)
        #expect(UUID(uuidString: third) != nil)
    }

    @Test("切换服务器复用同一个 deviceId")
    func deviceIdSharedAcrossServers() {
        let defaults = makeDefaults()
        let serverA = ClientIdentity.current(defaults: defaults, deviceName: "Mac")
        let serverB = ClientIdentity.current(defaults: defaults, deviceName: "Mac")
        #expect(serverA.deviceId == serverB.deviceId)
        #expect(serverA.deviceName == "Mac")
        #expect(serverA.appName == "Prism")
        #expect(!serverA.appVersion.isEmpty)
    }

    @Test("鉴权头字段直接来自身份")
    func headerReflectsIdentity() {
        let identity = ClientIdentity(
            appName: "Prism",
            appVersion: "9.9.9",
            deviceName: "Living Room",
            deviceId: "DEV-1"
        )
        let header = AuthHeader(identity: identity)
        #expect(header.client == "Prism")
        #expect(header.version == "9.9.9")
        #expect(header.device == "Living Room")
        #expect(header.deviceId == "DEV-1")
    }
}
