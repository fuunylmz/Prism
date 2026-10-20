import Foundation

/// 状态迁移的结果。
public enum PlaybackStateTransition: Sendable, Equatable {
    /// 迁移被接受，状态已改变。
    case accepted
    /// 目标状态与当前相同，什么也没发生（不是错误）。
    case unchanged
    /// 非法迁移，已被丢弃（状态保持不变）。
    case rejected
}

/// ``PlaybackState`` 的迁移规则。
///
/// 引擎（尤其是 AetherEngine）会发一些**瞬时中间态**，UI 不应该照单全收：
/// 例如它会在 `seek` 期间发 `.seeking`（契约里没有这个状态），在切音轨时发 `.loading`
/// 之后又回到 `.playing`。这个类型把「哪些迁移是合法的」集中成一张表，
/// 非法迁移（如 ``PlaybackState/ended`` → ``PlaybackState/playing``）**直接丢弃**，
/// 避免 UI 状态被引擎的抖动带偏。
///
/// 合法迁移表：
///
/// | 从 \ 到 | idle | loading | playing | paused | buffering | ended | failed |
/// |---|---|---|---|---|---|---|---|
/// | **idle** | — | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
/// | **loading** | ✅ | — | ✅ | ✅ | ✅ | ✅ | ✅ |
/// | **playing** | ✅ | ✅¹ | — | ✅ | ✅ | ✅ | ✅ |
/// | **paused** | ✅ | ✅¹ | ✅ | — | ✅ | ✅ | ✅ |
/// | **buffering** | ✅ | ✅¹ | ✅ | ✅ | — | ✅ | ✅ |
/// | **ended** | ✅ | ❌ | ❌ | ❌ | ❌ | — | ✅ |
/// | **failed** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | — |
///
/// ¹ `playing/paused/buffering → loading` 是**切音轨重建管线**的真实路径
/// （实测 143ms，见 `docs/ARCHITECTURE.md` §3.5 坑 2），必须允许。
///
/// - Note: `ended` / `failed` 是终态：要重播必须重新 ``PlaybackEngine/load(_:)``，
/// 而 `load` 会先把状态重置到 `idle`（``force(_:)``），再走 `idle → loading`。
public struct PlaybackStateMachine: Sendable, Equatable {
    /// 当前状态。
    public private(set) var state: PlaybackState

    /// 以指定初始状态构造（默认 ``PlaybackState/idle``）。
    public init(initial: PlaybackState = .idle) {
        self.state = initial
    }

    /// 判断某个迁移是否合法（相同状态视为合法，但 ``apply(_:)`` 会返回 ``PlaybackStateTransition/unchanged``）。
    ///
    /// - Parameter next: 目标状态。
    public func canTransition(to next: PlaybackState) -> Bool {
        next == state || Self.allows(from: state, to: next)
    }

    /// 尝试迁移。
    ///
    /// - Parameter next: 目标状态。
    /// - Returns: 迁移结果；只有 ``PlaybackStateTransition/accepted`` 会真正改变状态。
    @discardableResult
    public mutating func apply(_ next: PlaybackState) -> PlaybackStateTransition {
        if next == state { return .unchanged }
        guard Self.allows(from: state, to: next) else { return .rejected }
        state = next
        return .accepted
    }

    /// 强制设置状态，跳过规则检查。
    ///
    /// 只给「会话重置」用（`load()` 前 / `stop()` 后），不要拿它绕过状态机做日常迁移。
    ///
    /// - Parameter next: 目标状态。
    public mutating func force(_ next: PlaybackState) {
        state = next
    }

    /// 迁移表本体。
    ///
    /// - Parameters:
    ///   - from: 当前状态。
    ///   - to: 目标状态。
    private static func allows(from: PlaybackState, to: PlaybackState) -> Bool {
        switch (from, to) {
        // 未加载：只能开始加载，或直接失败。
        case (.idle, .loading), (.idle, .failed):
            return true

        // 加载中：可以起播、以暂停态挂载、进入缓冲、播完（极短片）、失败、被取消回 idle。
        case (.loading, .playing), (.loading, .paused), (.loading, .buffering),
             (.loading, .ended), (.loading, .failed), (.loading, .idle):
            return true

        // 播放中：暂停、缓冲、切音轨重建（→ loading）、播完、失败、停止。
        case (.playing, .paused), (.playing, .buffering), (.playing, .loading),
             (.playing, .ended), (.playing, .failed), (.playing, .idle):
            return true

        // 暂停中：恢复、缓冲、切音轨重建（→ loading）、播完（暂停在片尾）、失败、停止。
        case (.paused, .playing), (.paused, .buffering), (.paused, .loading),
             (.paused, .ended), (.paused, .failed), (.paused, .idle):
            return true

        // 缓冲中：恢复、暂停、切轨重建、播完、失败、停止。
        case (.buffering, .playing), (.buffering, .paused), (.buffering, .loading),
             (.buffering, .ended), (.buffering, .failed), (.buffering, .idle):
            return true

        // 已播完：只能停止（回 idle）或失败；**不能**直接回到播放（要重播请重新 load）。
        case (.ended, .idle), (.ended, .failed):
            return true

        // 失败：只能停止或重新加载；**不能**直接回到播放。
        case (.failed, .idle), (.failed, .loading):
            return true

        default:
            return false
        }
    }
}
