import AppKit
import Foundation
import PrismCore
import EmbyAPI

// MARK: - 演示图片加载器

/// 演示模式下的海报加载器：**不走网络**，按 URL 里的条目 id 生成渐变色块。
///
/// 为什么需要它：`DemoDataSources` 的 `imageURL` 返回 `nil` 时，界面会退回
/// `AsyncPosterImage` 的灰块占位——能跑，但看起来不像一个媒体库。
/// 这里把「条目 id」从 URL 里解析出来，交给 ``DemoArtwork`` 画一张确定性渐变色海报，
/// 让演示界面有真实的视觉密度。
///
/// 与真实加载器的关系：两者都实现 `PosterImageLoading`，由外壳按是否演示模式二选一注入。
/// 页面代码不需要知道用的是哪一个。
public struct DemoImageLoader: PosterImageLoading {
    public init() {}

    public func image(for url: URL, targetSize: CGSize) async throws -> NSImage {
        // 从 `/Items/{id}/Images/{kind}` 里取条目 id 与图片类型。
        let components = url.pathComponents
        let itemID = components.count >= 3 && components.contains("Items")
            ? (components.firstIndex(of: "Items").flatMap { idx in
                components.indices.contains(idx + 1) ? components[idx + 1] : nil
            } ?? url.lastPathComponent)
            : url.lastPathComponent

        let kind: ImageKind = url.path.contains("/Images/Backdrop")
            ? .backdrop
            : (url.path.contains("/Images/Logo") ? .logo : .primary)

        let size = targetSize.width > 0 && targetSize.height > 0
            ? targetSize
            : CGSize(width: 300, height: 450)

        return DemoArtwork.image(seed: itemID, kind: kind, size: size)
    }
}
