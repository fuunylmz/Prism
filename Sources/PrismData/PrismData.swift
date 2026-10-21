import Foundation
import PrismCore
import EmbyAPI

/// 本地持久化层：缓存、会话存储、图片缓存。
///
/// 骨架阶段只提供占位入口，具体实现由 PrismData 的 owner 在本目录内完成。
public enum PrismData {
    /// 该模块在骨架阶段就绪的标记，供测试与启动自检使用。
    public static let isPlaceholder = true
}
