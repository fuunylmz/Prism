import Foundation
import PrismCore

/// `GET /Items/{itemId}/Images/{kind}` —— 取条目图片。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/ImageService/getItemsByIdImagesByType.html>
/// 缓存机制：<https://dev.emby.media/doc/restapi/Images.html>
///
/// ## 用法
///
/// ```swift
/// // 海报墙：300pt 宽（Retina 下 600px 足够）
/// let endpoint = ImageEndpoint(itemId: item.id, kind: .primary,
///                              tag: item.primaryImageTag, maxWidth: 300)
/// let data = try await client.data(endpoint)
/// ```
///
/// ## `tag` 即缓存键
///
/// 条目对象里的 `ImageTags`（`{"Primary":"abc"}`）与 `BackdropImageTags`（`["t1","t2"]`）
/// 就是缓存 tag。带上 `?tag=` 后服务器返回**强缓存头**，客户端可以**永久缓存这个 URL**；
/// 图片变了 tag 也变，URL 随之变化，旧缓存自然失效。
///
/// 官方还建议缓存键**去掉 hostname 与 port**，这样局域网与公网访问能共用同一份缓存。
///
/// ## 404 回退
///
/// 对象没指示图片存在就去请求 → 必然 404。调用前先查 `ImageTags` / `BackdropImageTags`。
/// `Backdrop` 的 `index` 超范围也会 404，`BackdropImageTags.count` 才是可用数量。
public struct ImageEndpoint: EmbyEndpoint {
    /// 条目 id。
    public let itemId: String

    /// 图片类型（路径段）。
    public let kind: ImageKind

    /// 图片序号（`Backdrop` / `Screenshot` / `Chapter` 有多张时必须指定，`0` 基）。
    public let index: Int?

    /// 最大宽度（等比缩放）。
    public let maxWidth: Int?

    /// 最大高度。
    public let maxHeight: Int?

    /// 固定宽度（高度按比例）。
    public let width: Int?

    /// 固定高度。
    public let height: Int?

    /// 质量 0–100（官方默认 90）。
    public let quality: Int?

    /// 缓存 tag。
    public let tag: String?

    /// 输出格式（`original` / `gif` / `jpg` / `png` / `bmp`）。
    public let format: String?

    /// 是否裁掉空白（Logo 默认裁）。
    public let cropWhitespace: Bool?

    /// 是否应用 Cover Art 等增强插件。
    public let enableImageEnhancers: Bool?

    /// 是否叠加「已看」角标。
    public let addPlayedIndicator: Bool?

    /// 叠加已看百分比（0–100）。
    public let percentPlayed: Double?

    /// 叠加未看数量角标。
    public let unplayedCount: Int?

    /// 透明图背景色（如 `#000000`）。
    public let backgroundColor: String?

    /// 前景图层。
    public let foregroundLayer: String?

    /// 是否自动纠正方向。
    ///
    /// 【待验证】`autoOrient` 是 Emby 4.8+ 新增，Reference 页有但旧 OpenAPI 没有；
    /// 用不到就别传。
    public let autoOrient: Bool?

    /// 是否保留动图。
    ///
    /// 【待验证】同上，属 4.8+ 新增参数。
    public let keepAnimation: Bool?

    /// 以条目 id、图片类型与 tag 创建（最常用形态）。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - kind: 图片类型。
    ///   - index: 图片序号。
    ///   - tag: 缓存 tag。
    ///   - maxWidth: 最大宽度。
    ///   - maxHeight: 最大高度。
    public init(
        itemId: String,
        kind: ImageKind,
        index: Int? = nil,
        tag: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil
    ) {
        self.itemId = itemId
        self.kind = kind
        self.index = index
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.width = nil
        self.height = nil
        self.quality = nil
        self.tag = tag
        self.format = nil
        self.cropWhitespace = nil
        self.enableImageEnhancers = nil
        self.addPlayedIndicator = nil
        self.percentPlayed = nil
        self.unplayedCount = nil
        self.backgroundColor = nil
        self.foregroundLayer = nil
        self.autoOrient = nil
        self.keepAnimation = nil
    }

    /// `/Items/{itemId}/Images/{kind}`，带 `index` 时为
    /// `/Items/{itemId}/Images/{kind}/{index}`。
    public var path: String {
        if let index {
            return "/Items/\(itemId)/Images/\(kind.rawValue)/\(index)"
        }
        return "/Items/\(itemId)/Images/\(kind.rawValue)"
    }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("maxWidth", maxWidth)
        accumulator.put("maxHeight", maxHeight)
        accumulator.put("width", width)
        accumulator.put("height", height)
        accumulator.put("quality", quality)
        accumulator.put("tag", tag)
        accumulator.put("format", format)
        accumulator.put("cropWhitespace", cropWhitespace)
        accumulator.put("enableImageEnhancers", enableImageEnhancers)
        accumulator.put("addPlayedIndicator", addPlayedIndicator)
        accumulator.put("percentPlayed", percentPlayed)
        accumulator.put("unplayedCount", unplayedCount)
        accumulator.put("backgroundColor", backgroundColor)
        accumulator.put("foregroundLayer", foregroundLayer)
        accumulator.put("autoOrient", autoOrient)
        accumulator.put("keepAnimation", keepAnimation)
        return accumulator.values
    }

    /// 图片允许走本地缓存：`URLCache` 命中时不必回服务器。
    public var cachePolicy: URLRequest.CachePolicy { .returnCacheDataElseLoad }
}
