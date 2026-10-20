import Foundation

/// 演示模式（Demo Mode）的全局开关。
///
/// ## 为什么需要它
///
/// 真实 Emby 服务器由用户后置提供，开发期不能依赖任何服务器。演示模式让 App
/// 在没有后端的情况下也能跑通「登录 → 首页 → 媒体库 → 详情 → 播放」全链路，
/// 同时让 UI 开发可以完全独立于网络层推进。
///
/// ## 开启方式（二选一，均不需要写磁盘）
///
/// ```bash
/// # 1. 启动参数（Xcode Scheme → Arguments Passed On Launch）
/// Prism.app/Contents/MacOS/Prism -DemoMode YES
///
/// # 2. 环境变量（Xcode Scheme → Environment Variables）
/// PRISM_DEMO=1 Prism.app/Contents/MacOS/Prism
/// ```
///
/// ## 刻意不做持久化
///
/// 状态**不写入 `UserDefaults`**。原因：演示模式是「临时看一眼 UI」的开关，
/// 一旦持久化，用户下次真正连服务器时会因为忘记关掉而以为「服务器里就是这些假数据」，
/// 这类误判的排查成本极高。因此它只认进程启动时的参数与环境变量，
/// 进程退出即失效。
///
/// ## 求值时机
///
/// ``isEnabled`` 是 `static let`，**进程生命周期内只求值一次**（首次访问时）。
/// 这样 UI 层可以在任意位置读取，不会因为某处改了 `ProcessInfo` 而前后不一致。
/// 需要重新求值时只能重启进程 —— 这是刻意设计的。
public enum DemoMode {

    // MARK: - 常量

    /// 启动参数名。完整形态为 `-DemoMode YES` / `-DemoMode 1` / `-DemoMode`。
    ///
    /// 这是 Apple 的 `UserDefaults` 命令行参数约定：`-Key Value` 会同时被
    /// `UserDefaults.standard` 读取。这里不用 `UserDefaults`，只用
    /// `ProcessInfo.processInfo.arguments` 自行解析，避免污染偏好域。
    /// 参考：<https://developer.apple.com/documentation/foundation/userdefaults>
    public static let launchArgument = "-DemoMode"

    /// 环境变量名。取值 `1` / `true` / `yes`（大小写不敏感）视为开启。
    public static let environmentVariable = "PRISM_DEMO"

    // MARK: - 开关

    /// 是否处于演示模式。
    ///
    /// 进程启动后首次访问时求值一次，之后恒定。
    public static let isEnabled: Bool = evaluate(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    /// 纯函数版的开关判定，便于测试在不启动新进程的情况下覆盖各种参数组合。
    ///
    /// 判定顺序：
    /// 1. 环境变量 ``environmentVariable`` 为真值 → 开启；
    /// 2. 启动参数里出现 ``launchArgument``：
    ///    - 后面紧跟一个布尔值 → 以该值为准（`-DemoMode NO` 可以显式关闭）；
    ///    - 后面没有值、或紧跟的是下一个 `-Flag` → 视为开启。
    ///
    /// - Parameters:
    ///   - arguments: 进程启动参数（通常为 `ProcessInfo.processInfo.arguments`）。
    ///   - environment: 环境变量表（通常为 `ProcessInfo.processInfo.environment`）。
    /// - Returns: 是否开启演示模式。
    static func evaluate(arguments: [String], environment: [String: String]) -> Bool {
        if let raw = environment[environmentVariable], isTruthy(raw) {
            return true
        }
        guard let index = arguments.firstIndex(of: launchArgument) else { return false }
        let nextIndex = arguments.index(after: index)
        guard nextIndex < arguments.endIndex else { return true }
        let value = arguments[nextIndex]
        // `-DemoMode -AnotherFlag`：没有跟值，按开启处理。
        guard !value.hasPrefix("-") else { return true }
        return isTruthy(value)
    }

    /// 把 `1` / `true` / `yes` / `on` 判定为真（大小写不敏感）。
    ///
    /// - Parameter raw: 原始字符串。
    /// - Returns: 是否为真值。
    private static func isTruthy(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }
}
