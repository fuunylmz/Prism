import AppKit
import EmbyAPI
import Foundation
import PrismCore

/// 图片管线的默认实现：`URLSession` 下载 + ImageIO 降采样 + 两级缓存。
///
/// ## 职责
///
/// - 走已存在的 ``ImageEndpoint``（`GET /Items/{id}/Images/{Type}?maxWidth=&maxHeight=&tag=`）
///   拿字节，不重复实现 URL 拼装；
/// - 同时实现 ``ImageLoading``（按条目 id 取图）与 `PosterImageLoading` 的**方法签名**
///   （按 URL 取图，见 ``image(for:targetSize:)``）；
/// - 并发上限、请求去重、优先级、404 占位、缓存读写。
///
/// ## 为什么是 actor
///
/// 去重表（`inFlight`）与信号量配额都是可变状态，必须串行化。下载本身在
/// `URLSession` 里异步进行，actor 在 `await` 处让出，不会成为瓶颈。
///
/// ## 并发控制
///
/// - 同时最多 ``defaultMaxConcurrentDownloads``（6）个下载。这个数字来自调研文档
///   §3 的建议（"图片与元数据批量拉取并发上限设 6"），也是 HTTP/1.1 单主机常见上限。
/// - 同一缓存键的并发请求只发一次网络：先到者创建 `Task`，后来者 `await` 同一个任务。
///   这也是为什么去重表存的是 `Task<NSImage, Error>` 而不是「信号量 + 字典」。
/// - `prefetch` 用低优先级，可见区域用高优先级；见 ``AsyncSemaphore``。
///
/// ## 与 PrismUI 的关系
///
/// `PosterImageLoading` 定义在 `PrismUI`（`DesignSystem/AsyncPosterImage.swift`）。
/// 依赖方向是 `PrismUI → PrismData`，**PrismData 不能反向 import PrismUI**，否则成环。
/// 所以本类型没有写 `: PosterImageLoading`，只提供**逐字一致**的方法：
///
/// ```swift
/// func image(for url: URL, targetSize: CGSize) async throws -> NSImage
/// ```
///
/// 由 PrismUI 侧一行空 extension 完成协议遵循：
///
/// ```swift
/// extension EmbyImageLoader: PosterImageLoading {}
/// ```
///
/// 这样接口仍然可替换（换 Nuke 只需换实现类），且不引入反向依赖。
public actor EmbyImageLoader: ImageLoading {
    /// 默认同时下载数。
    public static let defaultMaxConcurrentDownloads = 6

    /// 默认显示缩放（macOS Retina 为 2）。只影响 URL 入口的像素换算。
    public static let defaultDisplayScale: CGFloat = 2

    private let client: EmbyClient
    private let cache: ImageCache
    private let session: URLSession
    private let semaphore: AsyncSemaphore
    private let displayScale: CGFloat
    private let prefetchConcurrency: Int

    /// 进行中的下载：缓存键 → 共享任务。
    private var inFlight: [String: Task<NSImage, Error>] = [:]

    /// 创建加载器。
    ///
    /// - Parameters:
    ///   - client: 已配置好服务器与令牌的客户端（负责鉴权、错误归一化）。
    ///   - cache: 两级缓存，默认 ``ImageCache/shared``。
    ///   - session: 下载任意 URL 时使用的会话（``image(for:targetSize:)`` 用）；
    ///     测试注入 `URLProtocol` 桩。``ImageRequest`` 路径走 `client` 自己的会话。
    ///   - maxConcurrentDownloads: 同时下载数，默认 6。
    ///   - displayScale: 点→像素比例，默认 2（Retina）。
    ///   - prefetchConcurrency: 预取时同时处理的任务数，默认 4。
    public init(
        client: EmbyClient,
        cache: ImageCache = .shared,
        session: URLSession = .shared,
        maxConcurrentDownloads: Int = EmbyImageLoader.defaultMaxConcurrentDownloads,
        displayScale: CGFloat = EmbyImageLoader.defaultDisplayScale,
        prefetchConcurrency: Int = 4
    ) {
        self.client = client
        self.cache = cache
        self.session = session
        self.displayScale = displayScale > 0 ? displayScale : 1
        self.prefetchConcurrency = max(1, prefetchConcurrency)
        semaphore = AsyncSemaphore(limit: maxConcurrentDownloads)
    }

    // MARK: - ImageLoading

    /// 按条目请求取图。
    ///
    /// 顺序：内存缓存 → 磁盘缓存 → 网络（低优先级以外的路径用高优先级）。
    /// 404 返回占位图；其他网络错误向上抛，由 UI 显示重试。
    ///
    /// - Parameter request: 图片请求。
    /// - Returns: 解码并降采样后的图片。
    /// - Throws: ``PrismCore/EmbyError`` 或 ``ImagePipelineError``。
    public func image(for request: ImageRequest) async throws -> PlatformImage {
        try await load(request, priority: .high)
    }

    /// 后台预取。
    ///
    /// 调用方已取消时**直接返回**：页面切走之后不该再占用下载名额。
    ///
    /// - Parameters:
    ///   - requests: 待预取请求，按重要性排序。
    ///   - limit: 最多处理多少个；`<= 0` 时直接返回。
    public func prefetch(_ requests: [ImageRequest], limit: Int) async {
        guard limit > 0, !requests.isEmpty, !Task.isCancelled else { return }
        let batch = Array(requests.prefix(limit))
        let width = min(batch.count, prefetchConcurrency)

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < width {
                let request = batch[next]
                next += 1
                group.addTask { await self.prefetchOne(request) }
            }
            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                guard next < batch.count else { continue }
                let request = batch[next]
                next += 1
                group.addTask { await self.prefetchOne(request) }
            }
        }
    }

    /// 清空内存缓存。
    ///
    /// `nonisolated`：`ImageCache` 自己线程安全，不必经过 actor 排队。
    public nonisolated func clearMemoryCache() {
        cache.clearMemory()
    }

    // MARK: - PosterImageLoading 兼容入口

    /// 按 URL 取图（`PosterImageLoading` 的方法签名）。
    ///
    /// 用于 `AsyncPosterImage(url:targetSize:)` 这类只拿得到 URL 的调用点。
    /// 与 ``image(for:)`` 共用同一份缓存与去重表，但缓存键带 `url/` 前缀，不会互相污染。
    ///
    /// 缓存键会**剔除** `api_key` / `X-Emby-Token` 等凭据参数：令牌轮换不应该让整墙海报失效。
    ///
    /// - Parameters:
    ///   - url: 图片地址（可自带 `?tag=`）。
    ///   - targetSize: 期望显示尺寸（pt）。按 `displayScale` 换算成像素后降采样。
    /// - Returns: 解码并降采样后的图片。
    /// - Throws: ``ImagePipelineError`` 或 `URLError`。
    public func image(for url: URL, targetSize: CGSize) async throws -> NSImage {
        try Task.checkCancellation()
        guard targetSize.width > 0, targetSize.height > 0 else {
            throw ImagePipelineError.invalidTargetSize
        }

        let key = Self.cacheKey(for: url, targetSize: targetSize)
        if let cached = cache.memoryImage(forKey: key) {
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let session = self.session
        let cache = self.cache
        let semaphore = self.semaphore
        let scale = displayScale
        let client = self.client
        let task = Task<NSImage, Error> {
            try await Self.loadURL(
                url,
                targetSize: targetSize,
                key: key,
                client: client,
                session: session,
                cache: cache,
                semaphore: semaphore,
                scale: scale
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    // MARK: - 便利查询

    /// 同步查内存缓存（未命中返回 `nil`，不触发磁盘或网络）。
    ///
    /// 视图首帧可以先拿它填位，避免闪一下占位图。
    ///
    /// - Parameter request: 图片请求。
    /// - Returns: 内存中已有的图片。
    public nonisolated func cachedImage(for request: ImageRequest) -> PlatformImage? {
        cache.memoryImage(forKey: request.cacheKey)
    }

    /// 当前磁盘占用（字节）。
    public func diskUsage() async -> Int64 {
        await cache.currentDiskUsage()
    }

    /// 清空磁盘缓存。
    public func clearDiskCache() async {
        await cache.clearDisk()
    }

    // MARK: - 内部

    /// 统一入口：缓存 → 去重 → 下载。
    ///
    /// ## 已知的优先级反转（刻意不修）
    ///
    /// 去重是**按缓存键**做的，任务创建时用的优先级属于**先到者**。极端情况下：
    /// 预取（低优先级）先创建了某张图的任务，用户恰好滚到它、发起可见请求，
    /// 后者会 `await` 同一个低优先级任务 —— 这张图就按低优先级排队了。
    ///
    /// 不修的理由：命中这个窗口的前提是「预取正在下这张图，同时它变成了可见」，
    /// 而预取本来就是为了让它**提前**就绪；真要修就得引入「任务内可升级的优先级」，
    /// 复杂度远大于收益。这里选择记录而不是过度设计。
    ///
    /// - Parameters:
    ///   - request: 图片请求。
    ///   - priority: 本次请求的优先级（只在需要排队时起作用）。
    /// - Returns: 图片。
    private func load(
        _ request: ImageRequest,
        priority: AsyncSemaphore.Priority
    ) async throws -> PlatformImage {
        try Task.checkCancellation()

        let key = request.cacheKey
        if let cached = cache.memoryImage(forKey: key) {
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let client = self.client
        let cache = self.cache
        let semaphore = self.semaphore
        let task = Task<NSImage, Error> {
            try await Self.loadItem(
                request,
                client: client,
                cache: cache,
                semaphore: semaphore,
                priority: priority
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// 预取单个请求：低优先级，失败静默。
    private func prefetchOne(_ request: ImageRequest) async {
        guard !Task.isCancelled else { return }
        _ = try? await load(request, priority: .low)
    }

    /// 条目图片的完整加载链路（静态方法：不持有 actor 隔离，避免把下载串行化）。
    private static func loadItem(
        _ request: ImageRequest,
        client: EmbyClient,
        cache: ImageCache,
        semaphore: AsyncSemaphore,
        priority: AsyncSemaphore.Priority
    ) async throws -> NSImage {
        let key = request.cacheKey
        if let cached = cache.memoryImage(forKey: key) {
            return cached
        }
        if let decoded = await cache.diskImage(
            forKey: key,
            fitting: request.targetPixelSize,
            scale: 1
        ) {
            return decoded.image
        }

        try Task.checkCancellation()
        await semaphore.acquire(priority: priority)
        defer { semaphore.release() }
        try Task.checkCancellation()

        let data: Data
        do {
            data = try await client.data(request.endpoint)
        } catch let error as EmbyError {
            // 404 = 这张图确实不存在。调研文档 §8.4：对象没指示图片存在时必然 404，
            // 属于正常分支，不该让 UI 显示「加载失败 / 重试」。
            if error == .notFound {
                let placeholder = PlaceholderImage.make(size: request.targetPixelSize)
                // 只进内存、不进磁盘：占位图不值得占 500 MB 的磁盘配额，
                // 但缓存起来可以避免每次滚动经过都重打一次必然 404 的请求。
                cache.storeMemoryOnly(
                    placeholder,
                    forKey: key,
                    pixelSize: request.targetPixelSize
                )
                return placeholder
            }
            throw error
        }

        guard let decoded = ImageDownsampler.downsample(
            data,
            fitting: request.targetPixelSize,
            scale: 1
        ) else {
            throw ImagePipelineError.decodingFailed
        }
        cache.store(decoded.image, forKey: key, pixelSize: decoded.pixelSize)
        return decoded.image
    }

    /// 任意 URL 的加载链路。
    ///
    /// **同源 URL 走 `client`**：`PosterImageLoading` 只给一个 `URL`，不带请求头，
    /// 而 Emby 的图片端点要鉴权。如果直接用 `URLSession.data(from:)` 裸取，
    /// 服务器会返回 401/404，海报墙整片变成占位图（UI 侧也记录了这个坑）。
    /// 所以这里把 URL 还原成「相对服务器基址的 path + query」，交给 ``EmbyClient``
    /// 重新注入鉴权头。只有**跨域**的 URL（真正的外部图片）才退回裸 `URLSession`。
    private static func loadURL(
        _ url: URL,
        targetSize: CGSize,
        key: String,
        client: EmbyClient,
        session: URLSession,
        cache: ImageCache,
        semaphore: AsyncSemaphore,
        scale: CGFloat
    ) async throws -> NSImage {
        if let cached = cache.memoryImage(forKey: key) {
            return cached
        }
        let box = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        if let decoded = await cache.diskImage(forKey: key, fitting: box, scale: scale) {
            return decoded.image
        }

        try Task.checkCancellation()
        await semaphore.acquire(priority: .high)
        defer { semaphore.release() }
        try Task.checkCancellation()

        let data: Data
        if let endpoint = ImageURLEndpoint(url: url, baseURL: client.baseURL) {
            do {
                data = try await client.data(endpoint)
            } catch let error as EmbyError {
                if error == .notFound {
                    return cachePlaceholder(forKey: key, targetSize: targetSize, scale: scale, cache: cache)
                }
                throw error
            }
        } else {
            let (payload, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    return cachePlaceholder(forKey: key, targetSize: targetSize, scale: scale, cache: cache)
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ImagePipelineError.httpStatus(http.statusCode)
                }
            }
            data = payload
        }

        guard let decoded = ImageDownsampler.downsample(data, fitting: box, scale: scale) else {
            throw ImagePipelineError.decodingFailed
        }
        cache.store(decoded.image, forKey: key, pixelSize: decoded.pixelSize)
        return decoded.image
    }

    /// 生成占位图并**只写内存**（不占磁盘配额）。
    private static func cachePlaceholder(
        forKey key: String,
        targetSize: CGSize,
        scale: CGFloat,
        cache: ImageCache
    ) -> NSImage {
        let placeholder = PlaceholderImage.make(size: targetSize)
        cache.storeMemoryOnly(
            placeholder,
            forKey: key,
            pixelSize: CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        )
        return placeholder
    }

    /// URL 入口的缓存键。
    ///
    /// 去掉凭据类查询参数（令牌轮换不该让缓存全部失效），其余部分（含 host）原样保留：
    /// 这里拿到的是任意 URL，不像条目图片那样能保证「同一 itemId 就是同一张图」。
    static func cacheKey(for url: URL, targetSize: CGSize) -> String {
        let credentialKeys: Set<String> = ["api_key", "x-emby-token", "token", "deviceid"]
        var normalized = url
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            let kept = items.filter { !credentialKeys.contains($0.name.lowercased()) }
            components.queryItems = kept.isEmpty ? nil : kept
            normalized = components.url ?? url
        }
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        return "url/\(normalized.absoluteString)/\(width)x\(height)"
    }
}

// MARK: - URL → 端点

/// 把「已经是完整 URL」的图片地址还原成一个 ``EmbyEndpoint``。
///
/// 存在的唯一理由：`PosterImageLoading` 只传 `URL`，而 Emby 的图片端点需要鉴权头。
/// 直接 `URLSession.data(from:)` 是匿名请求，服务器会 401/404 —— UI 侧的
/// `LibraryDataSource` 已经把这一点列为「图片层需要统一解决的问题」。
///
/// 还原规则：
/// 1. scheme / host / port 必须与服务器基址一致（跨域 URL 返回 `nil`，走裸下载）；
/// 2. 路径必须以基址路径为前缀（兼容 `/emby` 这类反代前缀），多出来的部分就是端点 `path`；
/// 3. query 原样转成字典（重复键只保留最后一个，图片参数里没有重复键）。
///
/// 这样 `client.data(_:)` 会重新注入 `X-Emby-Authorization` / `X-Emby-Token`，
/// 并且沿用 ``ImageEndpoint`` 的 `.returnCacheDataElseLoad` 缓存策略。
struct ImageURLEndpoint: EmbyEndpoint {
    /// 相对基址的路径（以 `/` 开头）。
    let path: String

    /// 查询参数。
    let query: [String: String]

    /// 从完整 URL 构造；不属于本服务器时返回 `nil`。
    ///
    /// - Parameters:
    ///   - url: 完整图片地址。
    ///   - baseURL: 服务器基址（可能带反代前缀）。
    init?(url: URL, baseURL: URL) {
        guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let targetHost = target.host,
              let baseHost = base.host,
              target.scheme?.lowercased() == base.scheme?.lowercased(),
              targetHost.lowercased() == baseHost.lowercased(),
              Self.effectivePort(target) == Self.effectivePort(base)
        else {
            return nil
        }

        var basePath = base.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let fullPath = target.path
        guard fullPath.hasPrefix(basePath) else { return nil }

        let remainder = String(fullPath.dropFirst(basePath.count))
        // 前缀必须**整段**匹配：基址 `/emby` 不能匹配 `/embyfoo/...`，
        // 否则会把 `foo/...` 当成端点路径，发出一个不存在的请求。
        // 同时排除「URL 就是基址本身」：那不是一张图。
        guard remainder.hasPrefix("/") else { return nil }
        path = remainder

        var pairs: [String: String] = [:]
        for item in target.queryItems ?? [] where item.value != nil {
            pairs[item.name] = item.value
        }
        query = pairs
    }

    /// 默认端口按 scheme 补齐后再比较，避免 `http://host` 与 `http://host:80` 被判成不同源。
    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// 图片允许走 HTTP 缓存。
    var cachePolicy: URLRequest.CachePolicy { .returnCacheDataElseLoad }
}
