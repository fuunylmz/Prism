import AppKit
import Foundation

/// 两级图片缓存：内存（`NSCache`，按像素计费）+ 磁盘（降采样后的 PNG）。
///
/// ## 为什么内存按「像素」而不是「张数」计费
///
/// 海报的尺寸差异极大：一张 600×900 的海报是 2.16 MB（600×900×4 字节），
/// 一张 1920×1080 背景图是 8.29 MB，一张 4K 剧照是 33 MB。按「最多缓存 N 张」限制，
/// 同一个 N 在两种场景下的内存占用能差 15 倍。所以 `NSCache.setObject(_:forKey:cost:)`
/// 的 cost 用**解码后的字节数**（宽 × 高 × 4），并设 `totalCostLimit`。
///
/// ## 为什么在 `NSCache` 之外还自己维护 LRU 顺序
///
/// Apple 文档明确说明 `NSCache` 的淘汰顺序**不保证**，且 `totalCostLimit` **不是硬上限**
/// （"The order in which the cache evicts objects is not guaranteed." / "This is not a strict
/// limit … an object in the cache could be evicted instantly, at a later point in time, or
/// possibly never"）：<https://developer.apple.com/documentation/foundation/nscache/totalcostlimit>
///
/// 因此这里用 `NSCache` 承担存储与系统内存压力响应，另用一把锁维护「键 → 成本」与访问顺序，
/// 插入后**同步**淘汰最久未访问的条目，让上限可预测、可测试。
///
/// ## 磁盘
///
/// - 目录：`~/Library/Caches/<bundleId>/images/`（沙盒内即容器里的同名路径）。
/// - 文件名：缓存键的 SHA-256 十六进制 + `.png`（键里可能含 `/`、`?` 等不能进文件名的字符）。
/// - 内容：**降采样之后**的 PNG，不是原图 —— 这样回读时不需要再解一张大图。
/// - 写入异步（后台串行队列），不阻塞请求返回；读取时才 `await`。
/// - 容量上限默认 500 MB，超限按「最后访问时间」淘汰（读取时显式刷新文件 mtime 作为
///   LRU 时间戳，不依赖文件系统的 atime 更新策略）。
public final class ImageCache: @unchecked Sendable {
    /// 缓存配置。
    public struct Configuration: Sendable {
        /// 磁盘目录。
        public var directory: URL
        /// 内存成本上限（字节），默认 128 MB。
        public var memoryCostLimit: Int
        /// 磁盘容量上限（字节），默认 500 MB。
        public var diskLimit: Int

        /// 创建配置。
        ///
        /// - Parameters:
        ///   - directory: 磁盘目录；`nil` 用 ``defaultDirectory``。
        ///   - memoryCostLimit: 内存上限（字节）。
        ///   - diskLimit: 磁盘上限（字节）。
        public init(
            directory: URL? = nil,
            memoryCostLimit: Int = 128 * 1024 * 1024,
            diskLimit: Int = 500 * 1024 * 1024
        ) {
            self.directory = directory ?? Self.defaultDirectory
            self.memoryCostLimit = max(0, memoryCostLimit)
            self.diskLimit = max(0, diskLimit)
        }

        /// 默认磁盘目录：`~/Library/Caches/<bundleId>/images/`。
        ///
        /// 取不到 `cachesDirectory`（极少见）时退回临时目录，取不到 bundleId 时用 `"Prism"`。
        /// 两级回退都避免强制解包。
        public static var defaultDirectory: URL {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleId = Bundle.main.bundleIdentifier ?? "Prism"
            return base
                .appendingPathComponent(bundleId, isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
        }
    }

    /// 进程内共享缓存。App 里直接用它；测试注入独立目录的实例。
    public static let shared = ImageCache()

    /// 磁盘目录。
    public let directory: URL

    /// 内存成本上限（字节）。
    public let memoryCostLimit: Int

    /// 磁盘容量上限（字节）。
    public let diskLimit: Int

    private let memory: ImageMemoryCache
    private let disk: DiskImageStore

    /// 创建缓存。
    ///
    /// - Parameter configuration: 配置，默认 ``Configuration/init(directory:memoryCostLimit:diskLimit:)``。
    public init(configuration: Configuration = Configuration()) {
        directory = configuration.directory
        memoryCostLimit = configuration.memoryCostLimit
        diskLimit = configuration.diskLimit
        memory = ImageMemoryCache(limit: configuration.memoryCostLimit)
        disk = DiskImageStore(directory: configuration.directory, limit: configuration.diskLimit)
    }

    // MARK: - 读

    /// 只查内存。命中是同步的，调用方不必 `await`。
    ///
    /// - Parameter key: ``ImageRequest/cacheKey``。
    /// - Returns: 命中的图片；未命中返回 `nil`。
    public func memoryImage(forKey key: String) -> NSImage? {
        memory.image(forKey: key)
    }

    /// 查磁盘并解码。
    ///
    /// 命中后会把结果**提升**进内存缓存（下次同步命中）。
    ///
    /// - Parameters:
    ///   - key: ``ImageRequest/cacheKey``。
    ///   - box: 请求时的目标像素框（用于确定回读时的上限，不会放大已存的图）。
    ///   - scale: 点与像素的比例；必须与写入时一致，否则 `NSImage.size` 会差一个倍数。
    /// - Returns: 解码结果；未命中或文件损坏时返回 `nil`（损坏文件会被删掉）。
    public func diskImage(
        forKey key: String,
        fitting box: CGSize,
        scale: CGFloat = 1
    ) async -> DownsampledImage? {
        guard let data = await disk.read(key: key) else { return nil }
        guard let decoded = ImageDownsampler.downsample(data, fitting: box, scale: scale) else {
            await disk.remove(key: key)
            return nil
        }
        memory.insert(decoded.image, forKey: key, cost: Self.cost(for: decoded.pixelSize))
        return decoded
    }

    // MARK: - 写

    /// 写入缓存：内存同步写入，磁盘**异步**写入。
    ///
    /// - Parameters:
    ///   - image: 已降采样的图片。
    ///   - key: ``ImageRequest/cacheKey``。
    ///   - pixelSize: 图片的真实像素尺寸（用于内存计费；不要用 `image.size`，那是点）。
    public func store(_ image: NSImage, forKey key: String, pixelSize: CGSize) {
        memory.insert(image, forKey: key, cost: Self.cost(for: pixelSize))
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        disk.write(cgImage, key: key)
    }

    // MARK: - 维护

    /// 清空内存缓存（磁盘保留）。
    public func clearMemory() {
        memory.removeAll()
    }

    /// 只写内存、**不写磁盘**。
    ///
    /// 用于占位图这类「不值得占磁盘、但重复请求会很浪费」的内容。
    /// 比如一张 404 的海报：每次滚动经过都会重新打一次服务器，而它永远不会变成
    /// 真图（真图出现时 tag 会变，缓存键也随之变化，不会读到旧的占位图）。
    ///
    /// - Parameters:
    ///   - image: 图片。
    ///   - key: 缓存键。
    ///   - pixelSize: 真实像素尺寸（用于计费）。
    public func storeMemoryOnly(_ image: NSImage, forKey key: String, pixelSize: CGSize) {
        memory.insert(image, forKey: key, cost: Self.cost(for: pixelSize))
    }

    /// 清空磁盘缓存，并等待删除完成。
    public func clearDisk() async {
        await disk.removeAll()
    }

    /// 当前磁盘占用（字节）。
    ///
    /// 每次都重新枚举目录，返回的是**真实值**而不是估算值。
    public func currentDiskUsage() async -> Int64 {
        await disk.usage()
    }

    /// 等待所有排队的磁盘写入落盘。
    ///
    /// 正常请求路径**不需要**调用它；退出前刷新、或测试里验证「清内存后仍能命中磁盘」时用。
    public func flushDiskWrites() async {
        await disk.flush()
    }

    /// 当前内存占用（字节，按像素成本估算）。
    public var memoryUsage: Int {
        memory.totalCost
    }

    /// 指定键当前的内存成本（字节）。
    ///
    /// - Parameter key: 缓存键。
    /// - Returns: 成本；不在内存缓存里返回 `nil`。
    public func memoryCost(forKey key: String) -> Int? {
        memory.cost(forKey: key)
    }

    /// 按像素尺寸算内存成本：每像素 4 字节（sRGB 解码格式）。
    ///
    /// 依据（✅）：WWDC18 416 "iOS Memory Deep Dive" 原文 ——「the memory use is related to
    /// the dimensions of the image, not its file size」，并给出算例
    /// `2048 × 1536 × 4 bytes ≈ 10 MB`。
    /// <https://developer.apple.com/videos/play/wwdc2018/416/>
    ///
    /// 这是**估算**而非精确值：`CGImage` 实际字节数还取决于 `bitsPerComponent` 与
    /// `bytesPerRow` 对齐。但缓存只需要一个可比较的量级，4 字节/像素与 Apple 的官方
    /// 口径一致，且偏保守（对齐后只会更大）。
    ///
    /// - Parameter pixelSize: 像素尺寸。
    /// - Returns: 字节数。
    public static func cost(for pixelSize: CGSize) -> Int {
        max(0, Int(pixelSize.width * pixelSize.height * 4))
    }
}

// MARK: - 内存缓存

/// 带确定性 LRU 淘汰的 `NSCache` 包装。
///
/// `NSCache` 本身线程安全，但「淘汰顺序不保证」。这里额外用锁维护访问顺序，
/// 插入后立刻按最久未访问淘汰，保证上限可预测（见 ``ImageCache`` 的说明）。
final class ImageMemoryCache: @unchecked Sendable {
    private let storage = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var costs: [String: Int] = [:]
    /// LRU 顺序：末尾是最近访问的。
    private var order: [String] = []
    private var total = 0
    private let limit: Int

    /// 创建内存缓存。
    ///
    /// - Parameter limit: 成本上限（字节）；`0` 表示不限。
    init(limit: Int) {
        self.limit = limit
        storage.totalCostLimit = limit
        storage.name = "dev.prism.images.memory"
    }

    /// 当前总成本。
    var totalCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    /// 指定键的成本。
    func cost(forKey key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard storage.object(forKey: key as NSString) != nil else { return nil }
        return costs[key]
    }

    /// 读取并把键移到 LRU 末尾。
    func image(forKey key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = storage.object(forKey: key as NSString) else {
            // NSCache 可能已自行淘汰：同步清账本，避免成本虚高。
            forget(key)
            return nil
        }
        touch(key)
        return image
    }

    /// 写入并触发淘汰。
    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = max(0, cost)
        forget(key)
        storage.setObject(image, forKey: key as NSString, cost: normalized)
        costs[key] = normalized
        order.append(key)
        total += normalized
        trim()
    }

    /// 清空。
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAllObjects()
        costs.removeAll()
        order.removeAll()
        total = 0
    }

    // MARK: 私有（调用方已持锁）

    /// 把键移到末尾。
    private func touch(_ key: String) {
        if let index = order.lastIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    /// 清掉某个键的账本（不碰 `NSCache`）。
    private func forget(_ key: String) {
        if let existing = costs.removeValue(forKey: key) {
            total -= existing
        }
        order.removeAll { $0 == key }
    }

    /// 超限时从最久未访问的一端淘汰。
    ///
    /// 至少保留一张：如果单张图本身就超过上限，淘汰它只会让下一次请求重新下载，
    /// 不解决问题。保留最近使用的一张更符合直觉。
    private func trim() {
        guard limit > 0 else { return }
        while total > limit, order.count > 1, let oldest = order.first {
            order.removeFirst()
            if let cost = costs.removeValue(forKey: oldest) {
                total -= cost
            }
            storage.removeObject(forKey: oldest as NSString)
        }
    }
}
