import Foundation

/// 时钟抽象，便于测试里替换成固定时间。
///
/// 契约（ARCHITECTURE §1.3）要求 `ClockProviding` 是 `Sendable` 且只有一个 `now`。
public protocol ClockProviding: Sendable {
    /// 当前时间。
    var now: Date { get }
}

/// 使用系统时钟的实现。
public struct SystemClock: ClockProviding {
    /// 创建系统时钟。
    public init() {}

    /// 当前时间（`Date()`）。
    public var now: Date { Date() }
}

/// 固定时钟，测试专用。
public struct FixedClock: ClockProviding {
    /// 固定的时间点。
    public let now: Date

    /// 以固定时间点创建。
    ///
    /// - Parameter now: 要固定的时间。
    public init(now: Date) {
        self.now = now
    }
}
