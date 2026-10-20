import Foundation

/// Prism 的模块标识与构建信息。
///
/// 这里刻意保持“零依赖、零业务逻辑”，后续任何 target 都可以安全引用。
public enum Prism {
    /// 当前骨架版本号，跟随 `App/Info.plist` 的 `CFBundleShortVersionString`。
    public static let version = "0.1.0"

    /// 用于日志 subsystem / UserDefaults 前缀等场景的稳定标识。
    public static let bundleIdentifier = "app.prism.Prism"
}
