import AppKit
import CoreGraphics
import CryptoKit
import Foundation

/// 磁盘图片缓存：把**降采样后的**图片按缓存键的 SHA-256 命名存成 PNG。
///
/// 设计要点：
/// - 所有文件操作都在一条**串行**后台队列上执行：写入不阻塞请求返回，读取也不占用
///   调用方（``EmbyImageLoader`` 是 actor，阻塞它会卡住所有去重与调度）。
/// - 文件名用 SHA-256：缓存键里含 `/`、`?` 等字符，不能直接当文件名；哈希同时把长度固定，
///   避免文件系统对文件名长度的限制。
/// - LRU 用文件的**最后修改时间**做时间戳，读取时显式刷新。不依赖 atime：
///   各卷的 atime 更新策略不同（有的挂载会禁用），拿它做淘汰依据不可靠。
/// - 容量超限时删到上限的 80%，避免每次写入都触发一轮淘汰。
internal final class DiskImageStore: @unchecked Sendable {
    /// 磁盘目录。
    let directory: URL

    /// 容量上限（字节）。
    let limit: Int

    private let queue = DispatchQueue(label: "dev.prism.images.disk", qos: .utility)
    private let fileManager = FileManager.default

    /// 估算的当前占用；`-1` 表示尚未统计（首次写入时补算）。
    ///
    /// 只在 `queue` 上读写，因此不需要额外加锁。
    private var trackedUsage: Int64 = -1

    /// 创建磁盘缓存。
    ///
    /// - Parameters:
    ///   - directory: 存放目录（不存在时在首次写入时创建）。
    ///   - limit: 容量上限（字节）；`0` 表示不限。
    init(directory: URL, limit: Int) {
        self.directory = directory
        self.limit = limit
    }

    // MARK: - 写

    /// 异步写入一张图片（PNG）。
    ///
    /// - Parameters:
    ///   - image: 已降采样的位图。
    ///   - key: 缓存键。
    func write(_ image: CGImage, key: String) {
        queue.async { [self] in
            performWrite(image, key: key)
        }
    }

    /// 等待队列上所有已排队的写入完成。
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                continuation.resume()
            }
        }
    }

    // MARK: - 读

    /// 异步读取原始 PNG 字节，并把文件的修改时间刷新为「现在」（LRU 时间戳）。
    ///
    /// - Parameter key: 缓存键。
    /// - Returns: 文件内容；不存在或读取失败时返回 `nil`。
    func read(key: String) async -> Data? {
        let url = fileURL(for: key)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            queue.async { [self] in
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                touch(url)
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - 维护

    /// 删除单个键对应的文件（解码失败时清理损坏文件）。
    func remove(key: String) async {
        let url = fileURL(for: key)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                try? fileManager.removeItem(at: url)
                continuation.resume()
            }
        }
    }

    /// 清空目录。
    func removeAll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let urls = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for url in urls {
                        try? fileManager.removeItem(at: url)
                    }
                }
                trackedUsage = 0
                continuation.resume()
            }
        }
    }

    /// 真实磁盘占用（字节），每次重新枚举目录。
    func usage() async -> Int64 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int64, Never>) in
            queue.async { [self] in
                continuation.resume(returning: currentUsage())
            }
        }
    }

    // MARK: - 私有（只在 queue 上调用）

    /// 文件地址：`<directory>/<sha256(key)>.png`。
    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).png", isDirectory: false)
    }

    /// 真正写文件（在 `queue` 上执行）。
    private func performWrite(_ image: CGImage, key: String) {
        let url = fileURL(for: key)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                return
            }
            let previousSize = existingSize(of: url)
            try data.write(to: url, options: .atomic)
            touch(url)

            if trackedUsage < 0 {
                trackedUsage = currentUsage()
            } else {
                trackedUsage += Int64(data.count) - previousSize
            }
            trimIfNeeded()
        } catch {
            // 磁盘写失败不影响请求返回：内存缓存已经写好了，下次启动会重新下载。
            // 这里刻意不抛错、不打日志（图片缓存是尽力而为的优化）。
        }
    }

    /// 刷新文件的修改时间，作为 LRU 的「最后访问」时间戳。
    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 已存在的同名文件大小（覆盖写入时用于修正占用统计）。
    private func existingSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else {
            return 0
        }
        return Int64(size)
    }

    /// 目录里所有普通文件的 (地址, 大小, 最后修改时间)。
    private func filesWithMetadata() -> [(url: URL, size: Int64, date: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else {
                return nil
            }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
    }

    /// 重新统计真实占用。
    private func currentUsage() -> Int64 {
        filesWithMetadata().reduce(0) { $0 + $1.size }
    }

    /// 超限时按「最久未访问」删除，直到回落到上限的 80%。
    private func trimIfNeeded() {
        guard limit > 0 else { return }
        if trackedUsage < 0 {
            trackedUsage = currentUsage()
        }
        guard trackedUsage > Int64(limit) else { return }

        let target = Int64(Double(limit) * 0.8)
        var usage = trackedUsage
        for file in filesWithMetadata().sorted(by: { $0.date < $1.date }) {
            guard usage > target else { break }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                usage -= file.size
            }
        }
        trackedUsage = usage
    }
}
