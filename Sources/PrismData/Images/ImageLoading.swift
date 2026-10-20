import AppKit
import Foundation

/// 跨模块使用的图片类型。
///
/// 契约见 `docs/ARCHITECTURE.md` §4 的 `ImageLoading`：协议用 `PlatformImage` 表达
/// 「平台图片类型」，macOS 下就是 `NSImage`。将来若增加 iOS target，只需在这里改映射，
/// 协议与调用点不动。
///
/// - Note: 本包只支持 macOS（`Package.swift` 的 `platforms` 只有 `.macOS(.v15)`），
///   所以没有做 `#if canImport(UIKit)` 分支。
public typealias PlatformImage = NSImage

/// 图片加载器的统一抽象。
///
/// **这是刻意设计的可替换层**：v1 的实现是 ``EmbyImageLoader``（`URLSession` + ImageIO 降采样
/// + 自研两级缓存）。将来若引入 Nuke，只需新增一个实现本协议的类，在 App 根部换注入即可，
/// 调用点（海报墙、详情页、预取器）无需改动。
///
/// 协议要求 `Sendable`：加载器会被放进 SwiftUI Environment 并被多个视图并发读取，
/// 实现内部的可变状态必须自己保证线程安全（``EmbyImageLoader`` 是 `actor`，
/// ``ImageCache`` 用锁保护）。
///
/// - Important: 本协议的签名由 `docs/ARCHITECTURE.md` §4 冻结，**不要修改**。
public protocol ImageLoading: Sendable {
    /// 取一张图。
    ///
    /// 命中内存或磁盘缓存时**不发起网络请求**。
    ///
    /// - Parameter request: 图片请求（含条目 id、类型、tag、目标像素尺寸）。
    /// - Returns: 解码并降采样后的图片。
    /// - Throws: ``PrismCore/EmbyError``（网络错误、401、超时等）或
    ///   ``ImagePipelineError/decodingFailed``。**404 不抛错**，返回占位图。
    func image(for request: ImageRequest) async throws -> PlatformImage

    /// 后台预取一批图片。
    ///
    /// 用低优先级执行，且只取前 `limit` 个，避免滚动时把服务器打爆。
    /// 取消调用方的 `Task` 后不再发起新的下载。
    ///
    /// - Parameters:
    ///   - requests: 待预取的请求（调用方通常按可见顺序排列）。
    ///   - limit: 本次最多处理多少个；`<= 0` 时直接返回。
    func prefetch(_ requests: [ImageRequest], limit: Int) async

    /// 清空内存缓存（磁盘缓存保留）。
    ///
    /// 收到内存压力通知或切换服务器时调用。
    func clearMemoryCache()
}

/// 图片管线自身的错误（不依赖网络层的那部分）。
///
/// 网络层错误沿用 ``PrismCore/EmbyError``；这里只放「拿到字节之后」的问题。
public enum ImagePipelineError: Error, Sendable, Equatable {
    /// HTTP 响应不是 2xx（404 已单独处理成占位图，不会走到这里）。
    case httpStatus(Int)
    /// 拿到的字节无法解码成图片（不是图片、数据被截断、格式不支持）。
    case decodingFailed
    /// 目标尺寸非法（宽或高 <= 0）。
    case invalidTargetSize
}
