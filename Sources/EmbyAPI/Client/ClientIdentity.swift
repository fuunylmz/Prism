import Foundation
import PrismCore

/// 客户端身份，对应 Emby 鉴权头里的 `Client` / `Device` / `DeviceId` / `Version` 四个字段。
///
/// 契约见 `docs/ARCHITECTURE.md` §2.1。四个字段的取值规则：
///
/// | 字段 | 来源 | 说明 |
/// |---|---|---|
/// | `appName` | 常量 `"Prism"` | 对应 `Client=` |
/// | `appVersion` | `CFBundleShortVersionString` | 取不到时回退 `"0.0.0"` |
/// | `deviceName` | `HostInfo.deviceName` | 用户在「系统设置 → 通用 → 共享」里起的机器名 |
/// | `deviceId` | `PrismCore.DeviceID` | **持久化**的 UUID，跨启动、跨服务器复用 |
///
/// - Important: `deviceId` 必须稳定。Emby 用它在服务端区分设备，播放进度、转码会话、
///   「继续观看」的归属都挂在它上面；每次启动重新生成会被服务器当成新设备。
///   ``PrismCore/DeviceID`` 把值存在 `UserDefaults` 的单一键里，因此**切换服务器时
///   同一个 deviceId 会被复用**，这正是官方客户端的做法。
public struct ClientIdentity: Sendable, Hashable {
    /// 默认客户端名，写入鉴权头的 `Client=`。
    public static let defaultAppName = "Prism"

    /// 版本号取不到时的回退值。
    public static let fallbackAppVersion = "0.0.0"

    /// 客户端名（`Client=`），Prism 固定为 `"Prism"`。
    public let appName: String

    /// 客户端版本（`Version=`），例如 `"0.1.0"`。
    public let appVersion: String

    /// 设备名（`Device=`），例如 `"fuunylmz的Mac Mini"`。
    public let deviceName: String

    /// 设备唯一标识（`DeviceId=`），持久化的 UUID 字符串。
    public let deviceId: String

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - appName: 客户端名，默认 ``defaultAppName``。
    ///   - appVersion: 客户端版本。
    ///   - deviceName: 设备名。
    ///   - deviceId: 设备唯一标识（必须持久化，见类型说明）。
    public init(
        appName: String = ClientIdentity.defaultAppName,
        appVersion: String,
        deviceName: String,
        deviceId: String
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.deviceId = deviceId
    }

    /// 读取（必要时生成）当前进程应使用的身份。
    ///
    /// - Parameters:
    ///   - defaults: `deviceId` 的持久化容器，测试可注入独立 suite。
    ///   - deviceName: 设备名，默认取 `HostInfo.deviceName`。
    /// - Returns: 组装好的身份。
    public static func current(
        defaults: UserDefaults = .standard,
        deviceName: String = HostInfo.deviceName
    ) -> ClientIdentity {
        ClientIdentity(
            appVersion: appVersion(),
            deviceName: deviceName,
            deviceId: DeviceID.current(in: defaults)
        )
    }

    /// 从 Info.plist 的 `CFBundleShortVersionString` 取版本号。
    ///
    /// - Parameter infoDictionary: 默认取 `Bundle.main.infoDictionary`；
    ///   测试可直接传字典，避免依赖宿主进程的 plist。
    /// - Returns: 版本号；缺失或为空时返回 ``fallbackAppVersion``。
    public static func appVersion(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let raw = infoDictionary?["CFBundleShortVersionString"] as? String else {
            return fallbackAppVersion
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackAppVersion : trimmed
    }
}
