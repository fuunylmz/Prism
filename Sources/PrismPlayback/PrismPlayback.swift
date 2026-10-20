import Foundation
import PrismCore

/// 播放引擎抽象。
///
/// 后续由播放代理接入 MPVKit；本文件只定义骨架阶段的占位协议与状态，
/// 保证上层可以先按协议编程。
public enum PrismPlayback {
    /// 该模块在骨架阶段就绪的标记，供测试与启动自检使用。
    public static let isPlaceholder = true
}

/// 播放器对外暴露的最小状态机，后续实现需要满足它。
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed(String)
}
