import AppKit
import Foundation
import Testing

import PrismCore
@testable import PrismData

/// 图片管线：缓存、降采样、去重、并发上限、404、取消。
///
/// 全部用 `URLProtocol` 桩，**不碰真实网络**；测试图片由代码生成。
///
/// 用 `.serialized` 串行执行：并发上限与取消相关的断言对时序敏感，
/// 并行跑其他测试会引入噪声（例如 `peakConcurrency` 被无关请求抬高）。
@Suite("图片管线", .serialized)
struct ImagesPipelineTests {
    // MARK: - 1. 缓存命中

    @Test("缓存命中：同一 key 第二次请求不发起网络")
    func cacheHitSkipsNetwork() async throws {
        let png = ImagesTestSupport.png(width: 40, height: 60)
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "m1", tag: "t1", maxWidth: 40, maxHeight: 60)

        let first = try await loader.image(for: request)
        let second = try await loader.image(for: request)

        #expect(mock.requestCount == 1, "第二次必须命中内存缓存，不发起网络")
        #expect(first.size == CGSize(width: 40, height: 60))
        #expect(second.size == first.size)
    }

    // MARK: - 2. tag 失效

    @Test("tag 变化导致缓存失效：同 itemId 不同 tag 会重新请求")
    func tagChangeInvalidatesCache() async throws {
        let png = ImagesTestSupport.png(width: 40, height: 60)
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let old = ImageRequest(itemId: "m1", tag: "t1", maxWidth: 40, maxHeight: 60)
        let new = ImageRequest(itemId: "m1", tag: "t2", maxWidth: 40, maxHeight: 60)

        _ = try await loader.image(for: old)
        _ = try await loader.image(for: old)
        #expect(mock.requestCount == 1)

        _ = try await loader.image(for: new)
        #expect(mock.requestCount == 2, "tag 变了就是另一张图，必须重新下载")

        // 两个 tag 各自留在缓存里，互不覆盖。
        #expect(cache.memoryImage(forKey: old.cacheKey) != nil)
        #expect(cache.memoryImage(forKey: new.cacheKey) != nil)
        #expect(old.cacheKey != new.cacheKey)
    }

    // MARK: - 3. 降采样正确性（核心断言）

    @Test("降采样：2000×3000 的源图请求 200×300，输出 NSImage.size 必须是 200×300")
    func downsamplingProducesRequestedSize() async throws {
        let png = ImagesTestSupport.png(width: 2000, height: 3000)
        try #require(!png.isEmpty, "测试图生成失败")
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "big", tag: "t1", maxWidth: 200, maxHeight: 300)

        let image = try await loader.image(for: request)

        #expect(image.size.width == 200, "实际宽度 \(image.size.width)")
        #expect(image.size.height == 300, "实际高度 \(image.size.height)")
        #expect(mock.requestCount == 1)
    }

    @Test("降采样：保持宽高比，且不放大源图")
    func downsamplingPreservesAspectAndNeverUpscales() throws {
        // 竖图 400×800 放进 200×200 的框 → 100×200（等比，装进框内）
        let data = ImagesTestSupport.png(width: 400, height: 800)
        try #require(!data.isEmpty, "测试图生成失败")
        let decoded = try #require(
            ImageDownsampler.downsample(data, fitting: CGSize(width: 200, height: 200), scale: 1)
        )
        #expect(decoded.pixelSize == CGSize(width: 100, height: 200))

        // 小图放进大框 → 原尺寸，不放大
        let small = ImagesTestSupport.png(width: 50, height: 50)
        let untouched = try #require(
            ImageDownsampler.downsample(small, fitting: CGSize(width: 500, height: 500), scale: 1)
        )
        #expect(untouched.pixelSize == CGSize(width: 50, height: 50))
    }

    @Test("降采样：scale = 2 时 NSImage.size 是像素尺寸的一半")
    func downsamplingAppliesDisplayScale() throws {
        let data = ImagesTestSupport.png(width: 600, height: 900)
        let decoded = try #require(
            ImageDownsampler.downsample(data, fitting: CGSize(width: 600, height: 900), scale: 2)
        )
        #expect(decoded.pixelSize == CGSize(width: 600, height: 900))
        #expect(decoded.image.size == CGSize(width: 300, height: 450))
    }

    @Test("降采样：EXIF 方向 6（顺时针 90°）会被摆正，宽高互换")
    func downsamplingAppliesEXIFOrientation() throws {
        let rotated = try #require(
            ImagesTestSupport.pngWithOrientation(
                ImagesTestSupport.png(width: 40, height: 20),
                orientation: 6
            ),
            "写入 EXIF 方向失败"
        )
        let decoded = try #require(
            ImageDownsampler.downsample(rotated, fitting: CGSize(width: 200, height: 200), scale: 1)
        )
        #expect(decoded.pixelSize == CGSize(width: 20, height: 40), "旋转后宽高必须互换")
    }

    // MARK: - 4. 内存成本

    @Test("内存成本：200×300 的图按 200*300*4 字节计费")
    func memoryCostUsesPixelCount() async throws {
        let png = ImagesTestSupport.png(width: 200, height: 300)
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "cost", tag: "t1", maxWidth: 200, maxHeight: 300)
        _ = try await loader.image(for: request)

        let expected = 200 * 300 * 4
        #expect(cache.memoryCost(forKey: request.cacheKey) == expected)
        #expect(cache.memoryUsage == expected)
        #expect(ImageCache.cost(for: CGSize(width: 200, height: 300)) == expected)
    }

    // MARK: - 5. LRU 淘汰

    @Test("LRU 淘汰：超过内存上限后移除最久未访问的那张")
    func memoryCacheEvictsLeastRecentlyUsed() {
        let cost = 10 * 10 * 4 // 400 字节
        let (cache, directory) = ImagesTestSupport.makeCache(memoryCostLimit: cost * 3)
        defer { ImagesTestSupport.cleanUp(directory) }

        let size = CGSize(width: 10, height: 10)
        func insert(_ key: String) {
            cache.store(PlatformImage(size: size), forKey: key, pixelSize: size)
        }

        insert("A")
        insert("B")
        insert("C")
        #expect(cache.memoryUsage == cost * 3)

        // 访问 A，把它变成「最近使用」。
        #expect(cache.memoryImage(forKey: "A") != nil)

        insert("D")
        #expect(cache.memoryImage(forKey: "B") == nil, "B 是最久未访问的，必须被淘汰")
        #expect(cache.memoryImage(forKey: "A") != nil)
        #expect(cache.memoryImage(forKey: "C") != nil)
        #expect(cache.memoryImage(forKey: "D") != nil)
        #expect(cache.memoryUsage == cost * 3, "淘汰后成本必须回到上限内")
    }

    @Test("clearMemory 清空内存但不动磁盘")
    func clearMemoryKeepsDisk() async throws {
        let png = ImagesTestSupport.png(width: 40, height: 60)
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "clear", tag: "t1", maxWidth: 40, maxHeight: 60)
        _ = try await loader.image(for: request)
        await cache.flushDiskWrites()

        #expect(cache.memoryUsage > 0)
        #expect(await cache.currentDiskUsage() > 0)

        loader.clearMemoryCache()
        #expect(cache.memoryUsage == 0)
        #expect(await cache.currentDiskUsage() > 0)
    }

    // MARK: - 6. 并发去重

    @Test("并发去重：10 个相同 key 的并发请求只发一次网络")
    func concurrentRequestsAreDeduplicated() async throws {
        let png = ImagesTestSupport.png(width: 40, height: 60)
        let mock = ImagesMockServer(.image(png, delay: 0.05))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "same", tag: "t1", maxWidth: 40, maxHeight: 60)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try? await loader.image(for: request)
                }
            }
        }

        #expect(mock.requestCount == 1, "实际发起了 \(mock.requestCount) 次网络请求")
    }

    // MARK: - 7. 并发上限

    @Test("并发上限：20 个不同 key 同时请求，峰值并发不超过 6")
    func concurrentDownloadsAreCapped() async throws {
        let png = ImagesTestSupport.png(width: 40, height: 60)
        let mock = ImagesMockServer(.image(png, delay: 0.05))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let requests = (0..<20).map {
            ImageRequest(itemId: "cap-\($0)", tag: "t1", maxWidth: 40, maxHeight: 60)
        }

        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    _ = try? await loader.image(for: request)
                }
            }
        }

        #expect(mock.requestCount == 20)
        #expect(mock.peakConcurrency <= 6, "峰值并发 \(mock.peakConcurrency) 超过上限 6")
        #expect(mock.peakConcurrency >= 2, "峰值并发只有 \(mock.peakConcurrency)，并发根本没发生，测试无效")
    }

    // MARK: - 8. 404

    @Test("404 返回占位图，不抛错")
    func notFoundReturnsPlaceholder() async throws {
        let mock = ImagesMockServer(.notFound())
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "missing", tag: "t1", maxWidth: 120, maxHeight: 180)

        let image = try await loader.image(for: request)

        #expect(image.size == CGSize(width: 120, height: 180))
        #expect(mock.requestCount == 1)

        // 占位图进内存（避免滚动时反复打必然 404 的请求），但不进磁盘。
        _ = try await loader.image(for: request)
        #expect(mock.requestCount == 1, "第二次应命中占位图缓存")
        #expect(await cache.currentDiskUsage() == 0, "占位图不该占磁盘配额")
    }

    @Test("网络错误向上抛，让 UI 显示重试")
    func networkFailureThrows() async throws {
        let mock = ImagesMockServer(
            ImagesMockResponse(errorCode: .cannotConnectToHost)
        )
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "down", tag: "t1", maxWidth: 40, maxHeight: 60)

        await #expect(throws: EmbyError.self) {
            _ = try await loader.image(for: request)
        }
    }

    // MARK: - 9. 磁盘往返

    @Test("磁盘缓存往返：清内存后仍命中磁盘，不发起网络")
    func diskCacheRoundTrip() async throws {
        let png = ImagesTestSupport.png(width: 80, height: 120)
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let request = ImageRequest(itemId: "disk", tag: "t1", maxWidth: 80, maxHeight: 120)

        _ = try await loader.image(for: request)
        await cache.flushDiskWrites()
        let usage = await cache.currentDiskUsage()
        #expect(usage > 0, "磁盘上应该有文件")

        cache.clearMemory()
        #expect(cache.memoryImage(forKey: request.cacheKey) == nil)

        let reloaded = try await loader.image(for: request)

        #expect(mock.requestCount == 1, "第二次必须命中磁盘，不发网络")
        #expect(reloaded.size == CGSize(width: 80, height: 120))
        #expect(cache.memoryImage(forKey: request.cacheKey) != nil, "磁盘命中后要提升进内存")

        await cache.clearDisk()
        #expect(await cache.currentDiskUsage() == 0)
    }

    @Test("磁盘容量上限：超限时按最久未访问淘汰")
    func diskCacheTrimsToLimit() async throws {
        let (cache, directory) = ImagesTestSupport.makeCache(diskLimit: 2 * 1024)
        defer { ImagesTestSupport.cleanUp(directory) }

        let cgImage = try #require(ImagesTestSupport.makeCGImage(width: 64, height: 64))
        let image = PlatformImage(cgImage: cgImage, size: CGSize(width: 64, height: 64))

        for index in 0..<12 {
            cache.store(image, forKey: "trim-\(index)", pixelSize: CGSize(width: 64, height: 64))
            await cache.flushDiskWrites()
        }

        let usage = await cache.currentDiskUsage()
        #expect(usage <= 2 * 1024, "磁盘占用 \(usage) 超过上限")
    }

    // MARK: - 10. 取消

    @Test("取消 prefetch 后不再发起新请求")
    func cancelledPrefetchIssuesNoRequests() async throws {
        let png = ImagesTestSupport.png(width: 40, height: 60)
        let mock = ImagesMockServer(.image(png, delay: 0.01))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(client: await ImagesTestSupport.client(mock), cache: cache)
        let requests = (0..<40).map {
            ImageRequest(itemId: "cancel-\($0)", tag: "t1", maxWidth: 40, maxHeight: 60)
        }

        let task = Task {
            // 先把自己取消，再进入 prefetch：模拟「页面已经离开」。
            withUnsafeCurrentTask { $0?.cancel() }
            await loader.prefetch(requests, limit: requests.count)
        }
        await task.value

        #expect(mock.requestCount == 0, "已取消的预取不该发起任何请求")
    }

    @Test("预取器：cancel 清空队列并停止 worker")
    func prefetcherCancelClearsQueue() async throws {
        let fake = RecordingImageLoader(delay: .milliseconds(20))
        let prefetcher = ImagePrefetcher(loader: fake, batchSize: 4)
        let requests = (0..<40).map {
            ImageRequest(itemId: "queue-\($0)", tag: "t1", maxWidth: 40, maxHeight: 60)
        }

        await prefetcher.enqueue(requests)
        await prefetcher.cancel()

        #expect(await prefetcher.pendingCount == 0)
        #expect(await prefetcher.isRunning == false)

        let batchesAtCancel = await fake.prefetchBatches.count
        try? await Task.sleep(for: .milliseconds(150))

        #expect(await fake.prefetchBatches.count == batchesAtCancel, "cancel 之后不该再起新批次")
        #expect(batchesAtCancel <= 1, "cancel 之前最多只该跑完一批，实际 \(batchesAtCancel) 批")
    }

    @Test("预取器：同一张图重复入队只保留一份")
    func prefetcherDeduplicatesQueue() async throws {
        let fake = RecordingImageLoader(delay: .milliseconds(1))
        let prefetcher = ImagePrefetcher(loader: fake, batchSize: 8)
        let request = ImageRequest(itemId: "dup", tag: "t1", maxWidth: 40, maxHeight: 60)

        await prefetcher.enqueue([request, request, request])

        #expect(await prefetcher.pendingCount <= 1)

        await prefetcher.waitUntilIdle()
        let keys = await fake.prefetchedKeys
        #expect(keys.filter { $0 == request.cacheKey }.count == 1)
    }

    // MARK: - 请求模型

    @Test("预设尺寸：海报 2:3、背景 16:9、头像 1:1")
    func presetSizes() {
        let poster = ImageRequest.poster(itemId: "m1", tag: "t")
        #expect(poster.kind == .primary)
        #expect(poster.maxWidth * 3 == poster.maxHeight * 2, "海报必须是 2:3")

        let backdrop = ImageRequest.backdrop(itemId: "m1", tag: "t")
        #expect(backdrop.kind == .backdrop)
        #expect(backdrop.maxWidth * 9 == backdrop.maxHeight * 16, "背景必须是 16:9")

        let avatar = ImageRequest.avatar(itemId: "u1", tag: "t")
        #expect(avatar.maxWidth == avatar.maxHeight, "头像必须是 1:1")
    }

    @Test("缓存键不含 host：局域网与公网共用一份缓存")
    func cacheKeyIgnoresHost() {
        let a = ImageRequest(itemId: "m1", tag: "t1", maxWidth: 300, maxHeight: 450)
        let b = ImageRequest(itemId: "m1", tag: "t1", maxWidth: 300, maxHeight: 450)
        #expect(a.cacheKey == b.cacheKey)
        #expect(!a.cacheKey.contains("http"), "缓存键不该带 URL/host")

        // 尺寸也参与键：不同尺寸是不同档位，必须分开缓存。
        let large = ImageRequest(itemId: "m1", tag: "t1", maxWidth: 600, maxHeight: 900)
        #expect(large.cacheKey != a.cacheKey)
    }

    @Test("空 tag 归一为 nil，参与键时是 notag")
    func emptyTagNormalizes() {
        let request = ImageRequest(itemId: "m1", tag: "", maxWidth: 10, maxHeight: 10)
        #expect(request.tag == nil)
        #expect(request.cacheKey.contains("/notag/"))
    }

    // MARK: - URL 入口（PosterImageLoading）

    @Test("URL 入口：同源图片走 EmbyClient，带上鉴权头")
    func urlEntryInjectsAuthHeader() async throws {
        let png = ImagesTestSupport.png(width: 60, height: 90)
        let mock = ImagesMockServer(.image(png))
        let (cache, directory) = ImagesTestSupport.makeCache()
        defer { ImagesTestSupport.cleanUp(directory) }

        let loader = EmbyImageLoader(
            client: await ImagesTestSupport.client(mock),
            cache: cache,
            session: mock.makeSession()
        )
        let url = try #require(URL(string: "http://127.0.0.1:8096/Items/m1/Images/Primary?maxWidth=60&tag=t1"))

        let image = try await loader.image(for: url, targetSize: CGSize(width: 30, height: 45))

        #expect(mock.requestCount == 1)
        let request = try #require(mock.requests.first)
        // 关键断言：走的是 client 而不是裸 URLSession —— 令牌在请求头里，不在 URL 里。
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "TKN-TEST")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Authorization") != nil)
        #expect(request.url?.query?.contains("TKN-TEST") != true, "令牌不该出现在 URL 里")
        // targetSize 30×45 pt × scale 2 = 60×90 px
        #expect(image.size == CGSize(width: 30, height: 45))
    }

    @Test("URL 入口：缓存键剔除凭据参数，令牌轮换不会让缓存失效")
    func urlCacheKeyStripsCredentials() throws {
        let base = "http://h:8096/Items/m1/Images/Primary?maxWidth=300"
        let withToken = try #require(URL(string: base + "&api_key=SECRET-A"))
        let rotated = try #require(URL(string: base + "&api_key=SECRET-B"))
        let size = CGSize(width: 300, height: 450)

        let keyA = EmbyImageLoader.cacheKey(for: withToken, targetSize: size)
        let keyB = EmbyImageLoader.cacheKey(for: rotated, targetSize: size)

        #expect(keyA == keyB, "令牌不同但图相同，缓存键必须一致")
        #expect(!keyA.contains("SECRET"), "缓存键里不能出现令牌")
    }

    @Test("URL → 端点：兼容 /emby 反代前缀；跨域返回 nil")
    func urlToEndpointMapping() throws {
        let base = try #require(URL(string: "http://h:8096/emby"))
        let same = try #require(URL(string: "http://h:8096/emby/Items/m1/Images/Primary?maxWidth=300&tag=t1"))
        let endpoint = try #require(ImageURLEndpoint(url: same, baseURL: base))
        #expect(endpoint.path == "/Items/m1/Images/Primary")
        #expect(endpoint.query["maxWidth"] == "300")
        #expect(endpoint.query["tag"] == "t1")

        // 无前缀基址
        let rootBase = try #require(URL(string: "http://h:8096"))
        let rootEndpoint = try #require(ImageURLEndpoint(url: same, baseURL: rootBase))
        #expect(rootEndpoint.path == "/emby/Items/m1/Images/Primary")

        // 跨域 → nil（退回裸下载）
        let foreign = try #require(URL(string: "https://cdn.example.com/a.jpg"))
        #expect(ImageURLEndpoint(url: foreign, baseURL: base) == nil)

        // 前缀只是字符串相似，不是整段 → nil
        let sibling = try #require(URL(string: "http://h:8096/embyfoo/Items/m1/Images/Primary"))
        #expect(ImageURLEndpoint(url: sibling, baseURL: base) == nil)
    }

    // MARK: - 信号量

    @Test("信号量：高优先级等待者先拿到名额")
    func semaphorePrioritizesHighWaiters() async {
        let semaphore = AsyncSemaphore(limit: 1)
        await semaphore.acquire(priority: .high) // 占满唯一的坑

        let order = OrderRecorder()

        // 先排低优先级，再排高优先级；释放后必须是高优先级先被放行。
        let low = Task {
            await semaphore.acquire(priority: .low)
            await order.append("low")
            semaphore.release()
        }
        // 给 low 一点时间真正进入等待队列。
        try? await Task.sleep(for: .milliseconds(50))

        let high = Task {
            await semaphore.acquire(priority: .high)
            await order.append("high")
            semaphore.release()
        }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(semaphore.waitingCount == 2)

        semaphore.release() // 释放初始占位 → 应先放行 high
        await high.value
        await low.value

        #expect(await order.values == ["high", "low"], "高优先级必须排在低优先级前面")
    }

    @Test("信号量：名额不会泄漏，release 后可用数回到上限")
    func semaphoreDoesNotLeakPermits() async {
        let semaphore = AsyncSemaphore(limit: 3)
        #expect(semaphore.availablePermits == 3)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await semaphore.acquire(priority: .high)
                    semaphore.release()
                }
            }
        }

        #expect(semaphore.availablePermits == 3)
        #expect(semaphore.waitingCount == 0)
    }
}
