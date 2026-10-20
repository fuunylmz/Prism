// swift-tools-version: 6.0
import PackageDescription

/// Prism 的本地 SPM 包。
///
/// 这是**所有 Swift 源码的唯一构建入口**：`swift build` / `swift test` 直接跑这个包，
/// Xcode 工程只负责把 `PrismUI` 链接进 `Prism.app`。
///
/// 分层约定（依赖只能自上而下，禁止反向或同层互相引用）：
///
///     PrismUI  ──▶ PrismData ──▶ EmbyAPI ──▶ PrismCore
///        │            │            │
///        └──▶ PrismPlayback ───────┘
///
/// - PrismCore：基础模型、日志、设置存储、通用工具（无依赖）
/// - EmbyAPI：Emby 网络层与 DTO（依赖 PrismCore）
/// - PrismData：本地缓存 / Keychain / 图片缓存（依赖 PrismCore、EmbyAPI）
/// - PrismPlayback：播放引擎（依赖 PrismCore + AetherEngine）
/// - PrismUI：设计系统与界面（依赖以上全部）

/// 所有 target 共享的 Swift 编译设置。
///
/// `-disable-sandbox` 是**必需的**，不是优化项：
/// 外部宏（`@Observable` / `@Test` / `#Preview`）由 `swift-plugin-server` 子进程展开，
/// 而编译器默认会把这个子进程包进 `sandbox-exec`。本仓库运行在 DSH 的文件沙箱里，
/// 再嵌套一层 sandbox 会直接失败，报：
///
///     sandbox-exec: sandbox_apply: Operation not permitted
///     error: external macro implementation type 'ObservationMacros.ObservableMacro'
///            could not be found for macro 'Observable()'
///
/// 这些 flag 同时覆盖 `swift build` 与 xcodebuild（后者会把 SPM target 的
/// swiftSettings 透传给 swiftc），因此不需要修改任何 Xcode 用户级偏好。
/// 详见 docs/BUILD_ENV.md。
///
/// `.unsafeFlags` 只在**根包**（本仓库自身）里合法；若将来本包被别的包当依赖引用，
/// 需要改为在调用方传 `-Xswiftc -disable-sandbox`。
let sharedSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-disable-sandbox"])
]

let package = Package(
    name: "Prism",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PrismCore", targets: ["PrismCore"]),
        .library(name: "EmbyAPI", targets: ["EmbyAPI"]),
        .library(name: "PrismData", targets: ["PrismData"]),
        .library(name: "PrismPlayback", targets: ["PrismPlayback"]),
        .library(name: "PrismUI", targets: ["PrismUI"])
    ],
    dependencies: [
        // 播放内核：FFmpeg demux + VideoToolbox 解码 + AVPlayer 处理 DV/Atmos。
        // 许可证 LGPL-3.0 + App Store/DRM 例外，与 GPL-3.0 完全兼容。
        // 锁定精确版本：上游是单人维护、发版频繁，跟随 latest 会引入不可控变更。
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.44.0")
    ],
    targets: [
        .target(
            name: "PrismCore",
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "EmbyAPI",
            dependencies: ["PrismCore"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "PrismData",
            dependencies: ["PrismCore", "EmbyAPI"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "PrismPlayback",
            dependencies: [
                "PrismCore",
                // 协商层要用 `DeviceProfile` / `PlaybackInfoResponse`，
                // 这两个类型在 EmbyAPI 里，所以播放层需要它。
                // 分层仍是自上而下：EmbyAPI → PrismCore，PrismPlayback → EmbyAPI。
                "EmbyAPI",
                .product(name: "AetherEngine", package: "AetherEngine")
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "PrismUI",
            dependencies: ["PrismCore", "EmbyAPI", "PrismData", "PrismPlayback"],
            // 品牌色 AccentColor（深/浅两套）放在这里。用资源目录而非写死 hex，
            // 是为了保留系统「增强对比度」「降低透明度」等辅助功能，
            // 以及让 `Color.accentColor` 跟随我们定义的品牌色。
            resources: [.process("Resources")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PrismCoreTests",
            dependencies: ["PrismCore"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "EmbyAPITests",
            dependencies: ["EmbyAPI", "PrismCore"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PrismDataTests",
            dependencies: ["PrismData", "EmbyAPI", "PrismCore"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PrismPlaybackTests",
            dependencies: ["PrismPlayback", "PrismCore", "EmbyAPI"],
            swiftSettings: sharedSwiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
