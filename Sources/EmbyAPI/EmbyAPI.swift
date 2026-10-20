import Foundation
import PrismCore

/// Emby 服务端访问层。
///
/// 目前只有占位类型：网络客户端、DTO、鉴权都由 EmbyAPI 的 owner 在此目录内实现。
/// 约定：只允许依赖 `PrismCore`，不要反向引用 UI / 数据层。
public enum EmbyAPI {
    /// 该模块在骨架阶段就绪的标记，供测试与启动自检使用。
    public static let isPlaceholder = true

    /// Emby 客户端默认的 API 路径前缀。
    public static let apiPathPrefix = "/emby"
}
