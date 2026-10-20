import CoreGraphics
import EmbyAPI
import Foundation
import PrismCore

/// 一次图片请求的完整描述，同时充当**缓存键的来源**。
///
/// ## `tag` 就是缓存版本号
///
/// 条目对象上的 `ImageTags`（`{"Primary":"abc"}`）与 `BackdropImageTags`（`["t1"]`）
/// 既是「这张图存在吗」的凭据，也是缓存版本号：带上 `?tag=` 后服务器会返回强缓存头，
/// 客户端可以**无条件永久缓存**；图片变了 tag 就变，URL 随之变化，旧缓存自然失效。
/// 因此 ``cacheKey`` 必须包含 `tag` —— 同一条目换 tag 就是另一张图。
///
/// - ✅ 官方说明（"The image tag on the item object also doubles as a caching value …
///   If the image changes, the tag will also change, thus creating a whole new url."）：
///   <https://dev.emby.media/doc/restapi/Images.html>
/// - ✅ 端点参数：<https://dev.emby.media/reference/RestAPI/ImageService/getItemsByIdImagesByType.html>
///
/// ## 尺寸语义
///
/// `maxWidth` / `maxHeight` 是**像素**尺寸（Emby 的 `maxWidth` / `maxHeight` 参数单位就是像素），
/// 同时也是解码降采样的目标像素框。``ImageDownsampler`` 保证输出图片的最长边不超过这个框，
/// 且**不放大**源图。2× 屏请直接请求 2 倍像素（例如 300pt 宽的海报请求 600px）。
public struct ImageRequest: Sendable, Hashable {
    /// 图片类型。取值与 Emby `ImageType` 枚举一致（见调研文档 §8.1）。
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// 主图（电影/剧集海报、人物头像）。
        case primary = "Primary"
        /// 背景图 / 剧照。
        case backdrop = "Backdrop"
        /// 标题 logo（通常带透明通道）。
        case logo = "Logo"
        /// 缩略图（16:9 剧照）。
        case thumb = "Thumb"

        /// 映射到 ``PrismCore/ImageKind``，供 `ImageEndpoint` 使用。
        public var imageKind: ImageKind {
            ImageKind(rawValue: rawValue)
        }
    }

    /// 条目 id。
    public let itemId: String

    /// 图片类型。
    public let kind: Kind

    /// 缓存 tag（来自 `ImageTags` / `BackdropImageTags`）。
    ///
    /// `nil` 表示对象上没有指示该图存在；此时请求大概率 404，调用方应优先走回退链。
    public let tag: String?

    /// 目标像素宽度。
    public let maxWidth: Int

    /// 目标像素高度。
    public let maxHeight: Int

    /// JPEG 质量 0–100（Emby 默认 90）。
    ///
    /// - Note: 当前 `ImageEndpoint` 的便捷构造没有暴露 `quality` 参数，因此该值
    ///   **只参与缓存键**，不会写进 URL。保留它是为了将来换实现或直接拼 URL 时
    ///   仍能区分不同质量的缓存条目。
    public let quality: Int

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - kind: 图片类型，默认 ``Kind/primary``。
    ///   - tag: 缓存 tag；空字符串按 `nil` 处理。
    ///   - maxWidth: 目标像素宽度，小于 1 时按 1 处理。
    ///   - maxHeight: 目标像素高度，小于 1 时按 1 处理。
    ///   - quality: JPEG 质量，自动夹到 0…100，默认 90。
    public init(
        itemId: String,
        kind: Kind = .primary,
        tag: String? = nil,
        maxWidth: Int,
        maxHeight: Int,
        quality: Int = 90
    ) {
        self.itemId = itemId
        self.kind = kind
        self.tag = (tag?.isEmpty ?? true) ? nil : tag
        self.maxWidth = max(1, maxWidth)
        self.maxHeight = max(1, maxHeight)
        self.quality = min(100, max(0, quality))
    }

    // MARK: - 预设尺寸

    /// 海报预设：2:3，600×900 像素（2× 屏上显示 300×450 pt）。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - tag: 缓存 tag。
    ///   - quality: JPEG 质量。
    /// - Returns: 主图请求。
    public static func poster(itemId: String, tag: String? = nil, quality: Int = 90) -> ImageRequest {
        ImageRequest(
            itemId: itemId,
            kind: .primary,
            tag: tag,
            maxWidth: 600,
            maxHeight: 900,
            quality: quality
        )
    }

    /// 背景图预设：16:9，1920×1080 像素。
    ///
    /// 调研文档建议详情页背景用 `maxWidth=1920`；不要请求原图
    /// （官方明确提醒 "Users will often download high resolution images. Steps should be
    /// taken to ensure that you are not retrieving these at full size."）。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - tag: 缓存 tag。
    ///   - quality: JPEG 质量。
    /// - Returns: 背景图请求。
    public static func backdrop(itemId: String, tag: String? = nil, quality: Int = 90) -> ImageRequest {
        ImageRequest(
            itemId: itemId,
            kind: .backdrop,
            tag: tag,
            maxWidth: 1920,
            maxHeight: 1080,
            quality: quality
        )
    }

    /// 头像预设：1:1，256×256 像素（2× 屏上显示 128×128 pt）。
    ///
    /// 用户头像走 `/Users/{userId}/Images/Primary`，人物头像走
    /// `/Persons/{name}/Images/Primary`（调研文档 §8.1）；本管线统一走 `Items` 端点，
    /// 需要头像时由上层自行拼 URL 走 ``ImageLoading`` 的 URL 入口。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - tag: 缓存 tag。
    ///   - quality: JPEG 质量。
    /// - Returns: 头像请求。
    public static func avatar(itemId: String, tag: String? = nil, quality: Int = 90) -> ImageRequest {
        ImageRequest(
            itemId: itemId,
            kind: .primary,
            tag: tag,
            maxWidth: 256,
            maxHeight: 256,
            quality: quality
        )
    }

    // MARK: - 派生值

    /// 缓存键。
    ///
    /// 形如 `abc123/Primary/tag-1/600x900/q90`。
    ///
    /// **刻意不含 host 与 port**：官方建议 "It is recommended to cache based on the url
    /// after the hostname and port. This will allow the same cache to be utilized whether
    /// connected internally (lan/wifi) or externally (mobile)."
    /// （<https://dev.emby.media/doc/restapi/Images.html>）这样局域网与公网访问共用一份缓存。
    ///
    /// - Note: `tag` 参与键，因此 tag 变化 = 缓存未命中 = 重新下载，正是 Emby 的缓存约定。
    public var cacheKey: String {
        "\(itemId)/\(kind.rawValue)/\(tag ?? "notag")/\(maxWidth)x\(maxHeight)/q\(quality)"
    }

    /// 目标像素框。
    public var targetPixelSize: CGSize {
        CGSize(width: maxWidth, height: maxHeight)
    }

    /// 转成 Emby 端点（已存在的 ``ImageEndpoint``，本管线不重复实现 URL 拼装）。
    public var endpoint: ImageEndpoint {
        ImageEndpoint(
            itemId: itemId,
            kind: kind.imageKind,
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
    }
}
