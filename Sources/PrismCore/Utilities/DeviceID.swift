import Foundation

/// 持久化的设备标识。
///
/// Emby 用 `DeviceId` 区分同一账号下的不同客户端，服务器侧的播放进度、设备权限
/// 都挂在它上面。因此**必须在多次启动之间保持稳定**：首次启动生成 UUID，
/// 之后从 `UserDefaults` 读回。
///
/// ```swift
/// let identity = ClientIdentity(
///     appName: "Prism",
///     appVersion: Prism.version,
///     deviceName: HostInfo.deviceName,
///     deviceId: DeviceID.current(in: .standard)
/// )
/// ```
public enum DeviceID {
    /// `UserDefaults` 里的键名。
    public static let defaultsKey = "prism.deviceId"

    /// 读取（必要时生成）设备 id。
    ///
    /// - Parameters:
    ///   - defaults: 持久化容器。
    ///   - key: 键名，默认 ``defaultsKey``。
    /// - Returns: 稳定的 UUID 字符串（大写、带连字符，与 Emby 官方客户端一致）。
    public static func current(in defaults: UserDefaults = .standard, key: String = defaultsKey) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }

    /// 清除已持久化的设备 id（下次调用会重新生成）。仅用于测试与“重置应用”。
    ///
    /// - Parameters:
    ///   - defaults: 持久化容器。
    ///   - key: 键名。
    public static func reset(in defaults: UserDefaults = .standard, key: String = defaultsKey) {
        defaults.removeObject(forKey: key)
    }
}
