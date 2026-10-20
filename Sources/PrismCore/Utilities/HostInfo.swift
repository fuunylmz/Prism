import Foundation

/// 宿主设备信息。
///
/// Emby 的鉴权头需要 `Device` 字段，服务器也会在“活动设备”里显示这个名字，
/// 因此取一个人类可读的机器名。
public enum HostInfo {
    /// 设备名。
    ///
    /// 优先 `Host.current().localizedName`（用户可在“系统设置 → 通用 → 共享”里改名，
    /// 例如 “fuunylmz的Mac Mini”）；取不到时退回 `"Mac"`，
    /// 保证 Emby 鉴权头的 `Device` 字段永远非空。
    public static var deviceName: String {
        let name = Host.current().localizedName ?? ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    /// 系统版本字符串（如 `Version 15.0 (Build 24A335)`）。
    public static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
