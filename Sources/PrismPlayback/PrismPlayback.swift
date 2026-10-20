import Foundation
import PrismCore

/// PrismPlayback 模块入口。
///
/// 骨架阶段的占位 ``PlaybackState`` 已被冻结契约取代：真正的
/// ``PlaybackEngine`` 协议、状态机与事件定义在 `Engine/` 下
/// （见 `docs/ARCHITECTURE.md` §3）。
public enum PrismPlayback {
    /// 该模块在骨架阶段就绪的标记，供测试与启动自检使用。
    ///
    /// - Note: T3.1 起模块已具备真实的引擎适配器（``AetherEngineAdapter``），
    ///   这个标记仅为兼容早期自检代码而保留。
    public static let isPlaceholder = true
}
