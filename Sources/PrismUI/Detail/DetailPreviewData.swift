import AppKit
import CoreText
import Foundation
import PrismCore

// MARK: - 预览假数据

/// `#Preview` 用的详情假数据。
///
/// 所有条目都指向 `preview.prism.invalid` 假域名，配合 ``DetailPreviewImageLoader``
/// **完全不联网**。数据刻意覆盖了详情页的所有分支：
///
/// - 电影：带 backdrop + logo + 4K/HDR 片源、看到一半、未收藏；
/// - 剧集：3 季（含特别篇），第 1 季全部看完、第 2 季看到第 3 集 →
///   默认季应定位到「第 2 季」，集列表里第 4 集是「接下来」；
/// - 一集「未播出」（首播时间在未来），用来演示禁用态。
enum DetailPreviewData {
    /// 假服务器 id。
    static let serverId = "preview-server"

    // MARK: 图片地址

    /// 生成假图片地址。
    ///
    /// - Parameters:
    ///   - itemID: 条目 id。
    ///   - kind: 图片类型。
    ///   - tag: 缓存 tag。
    /// - Returns: 假地址。
    static func imageURL(itemID: String, kind: ImageKind, tag: String) -> URL? {
        URL(string: "https://preview.prism.invalid/detail/\(itemID)/\(kind.rawValue.lowercased())?tag=\(tag)")
    }

    // MARK: 电影

    /// 电影：看到一半、带 logo 与 4K/HDR 片源。
    static let movie = MediaItem(
        id: "preview-movie-1",
        name: "银翼杀手 2049",
        type: .movie,
        serverId: serverId,
        productionYear: 2017,
        runTime: Ticks(seconds: 9780),
        overview: """
        一名新一代银翼杀手 K 在执行任务时揭开了一个尘封三十年的秘密：\u{201C}复制人\u{201D}曾经生育过后代。\
        这个发现足以让残存的人类与复制人之间的脆弱秩序彻底崩塌，也让 K 不得不面对自己记忆的真实性。\
        他循着线索找到了隐居多年的前银翼杀手瑞克·戴克，两人一同被卷入一场无法回头的追猎。
        """,
        officialRating: "R",
        communityRating: 8.0,
        genres: ["科幻", "剧情", "悬疑"],
        imageTags: [.primary: "tag-movie-primary", .backdrop: "tag-movie-backdrop", .logo: "tag-movie-logo"],
        backdropTags: ["tag-movie-backdrop"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 2100),
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        ),
        mediaSources: [
            MediaSource(
                id: "source-4k",
                name: "4K HDR",
                container: "mkv",
                runTime: Ticks(seconds: 9780),
                bitrate: 48_000_000,
                size: 51_000_000_000,
                mediaStreams: [
                    MediaStream(
                        index: 0,
                        type: .video,
                        codec: "hevc",
                        height: 2160,
                        width: 3840,
                        videoRange: "HDR10"
                    ),
                    MediaStream(index: 1, type: .audio, codec: "truehd", language: "eng", channels: 8)
                ],
                supportsDirectPlay: true,
                supportsDirectStream: true,
                supportsTranscoding: true
            )
        ],
        people: [
            Person(id: "person-denis", name: "丹尼斯·维伦纽瓦", type: "Director"),
            Person(id: "person-ryan", name: "瑞恩·高斯林", role: "K", type: "Actor", primaryImageTag: "tag-person-ryan"),
            Person(id: "person-harrison", name: "哈里森·福特", role: "瑞克·戴克", type: "Actor", primaryImageTag: "tag-person-harrison"),
            Person(id: "person-ana", name: "安娜·德·阿玛斯", role: "Joi", type: "Actor", primaryImageTag: "tag-person-ana"),
            Person(id: "person-sylvia", name: "西尔维娅·侯克斯", role: "Luv", type: "Actor", primaryImageTag: "tag-person-sylvia"),
            Person(id: "person-roger", name: "罗杰·狄金斯", type: "Writer")
        ]
    )

    /// 电影内容（无季无集）。
    static let movieContent = DetailContent(
        item: movie,
        similar: similarMovies,
        people: DetailViewModel.orderedPeople(movie.people ?? [])
    )

    /// 相似推荐用的电影列表。
    static let similarMovies: [MediaItem] = [
        makeSimilar(id: "sim-1", name: "降临", year: 2016, rating: 7.9),
        makeSimilar(id: "sim-2", name: "沙丘", year: 2021, rating: 8.1),
        makeSimilar(id: "sim-3", name: "星际穿越", year: 2014, rating: 8.6),
        makeSimilar(id: "sim-4", name: "湮灭", year: 2018, rating: 6.9),
        makeSimilar(id: "sim-5", name: "机械姬", year: 2014, rating: 7.7)
    ]

    /// 造一部相似电影。
    ///
    /// - Parameters:
    ///   - id: id。
    ///   - name: 名称。
    ///   - year: 年份。
    ///   - rating: 评分。
    /// - Returns: 条目。
    private static func makeSimilar(id: String, name: String, year: Int, rating: Double) -> MediaItem {
        MediaItem(
            id: id,
            name: name,
            type: .movie,
            serverId: serverId,
            productionYear: year,
            runTime: Ticks(seconds: 7800),
            overview: "相似推荐示例。",
            communityRating: rating,
            genres: ["科幻"],
            imageTags: [.primary: "tag-\(id)-primary"],
            userData: UserItemData(
                playbackPosition: .zero,
                playCount: 0,
                isFavorite: false,
                played: false,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
        )
    }

    // MARK: 剧集

    /// 剧集本身（没有 logo，用来演示「退回文字标题」）。
    static let series = MediaItem(
        id: "preview-series-1",
        name: "人生切割术",
        type: .series,
        serverId: serverId,
        productionYear: 2022,
        overview: """
        一家神秘的公司用手术把员工的工作记忆与生活记忆彻底分离。\
        新员工赫莉入职第一天就发现，自己既走不出这栋楼，也想不起外面的自己是谁。
        """,
        officialRating: "TV-MA",
        communityRating: 8.7,
        genres: ["剧情", "科幻", "悬疑"],
        imageTags: [.primary: "tag-series-primary", .backdrop: "tag-series-backdrop"],
        backdropTags: ["tag-series-backdrop"],
        userData: UserItemData(
            playbackPosition: .zero,
            playCount: 0,
            isFavorite: true,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: 4
        )
    )

    /// 季列表：第 1 季、第 2 季、特别篇。
    static let seasons: [MediaItem] = [
        makeSeason(index: 1, episodeCount: 6, playedCount: 6),
        makeSeason(index: 2, episodeCount: 7, playedCount: 2),
        makeSeason(index: 0, episodeCount: 1, playedCount: 0)
    ]

    /// 造一季。
    ///
    /// - Parameters:
    ///   - index: 季号（0 为特别篇）。
    ///   - episodeCount: 集数。
    ///   - playedCount: 已看集数。
    /// - Returns: 季条目。
    private static func makeSeason(index: Int, episodeCount: Int, playedCount: Int) -> MediaItem {
        MediaItem(
            id: "season-\(index)",
            name: index == 0 ? "特别篇" : "第 \(index) 季",
            type: .season,
            serverId: serverId,
            productionYear: 2022,
            userData: UserItemData(
                playbackPosition: .zero,
                playCount: 0,
                isFavorite: false,
                played: playedCount >= episodeCount,
                lastPlayedDate: nil,
                unplayedItemCount: max(episodeCount - playedCount, 0)
            ),
            seriesId: series.id,
            indexNumber: index,
            childCount: episodeCount
        )
    }

    /// 全部集：第 1 季 6 集（全看完）、第 2 季 7 集（看完 2 集、第 3 集有进度、第 7 集未播出）、
    /// 特别篇 1 集。
    static let allEpisodes: [MediaItem] = {
        var result: [MediaItem] = []
        for index in 1...6 {
            result.append(
                makeEpisode(season: 1, index: index, title: "第 \(index) 集 · 入职", played: true, progressSeconds: 0)
            )
        }
        for index in 1...7 {
            let played = index <= 2
            let progress: Double = index == 3 ? 900 : 0
            let premiereDate = index == 7 ? Date().addingTimeInterval(60 * 60 * 24 * 21) : nil
            result.append(
                makeEpisode(
                    season: 2,
                    index: index,
                    title: episodeTitle(index),
                    played: played,
                    progressSeconds: progress,
                    premiereDate: premiereDate
                )
            )
        }
        result.append(
            makeEpisode(season: 0, index: 1, title: "幕后特辑", played: false, progressSeconds: 0)
        )
        return result
    }()

    /// 第 2 季的集名。
    ///
    /// - Parameter index: 集号。
    /// - Returns: 标题。
    private static func episodeTitle(_ index: Int) -> String {
        switch index {
        case 1: "你好，赫莉"
        case 2: "半环"
        case 3: "永无止境"
        case 4: "你还好吗？"
        case 5: "光学与设计"
        case 6: "反常的礼仪"
        default: "告别"
        }
    }

    /// 造一集。
    ///
    /// - Parameters:
    ///   - season: 季号。
    ///   - index: 集号。
    ///   - title: 集名。
    ///   - played: 是否已看。
    ///   - progressSeconds: 已看秒数。
    ///   - premiereDate: 首播时间（未来时间用来演示「未播出」）。
    /// - Returns: 单集。
    private static func makeEpisode(
        season: Int,
        index: Int,
        title: String,
        played: Bool,
        progressSeconds: Double,
        premiereDate: Date? = nil
    ) -> MediaItem {
        MediaItem(
            id: "s\(season)e\(index)",
            name: title,
            type: .episode,
            serverId: serverId,
            productionYear: 2022,
            runTime: Ticks(seconds: 3300),
            overview: """
            这一集里，马克与同事们继续在\u{201C}分离\u{201D}的楼层里处理那些说不清来历的文件，\
            而楼上的世界开始出现裂缝。
            """,
            communityRating: 8.4,
            genres: ["剧情"],
            imageTags: [.primary: "tag-s\(season)e\(index)-primary", .thumb: "tag-s\(season)e\(index)-thumb"],
            userData: UserItemData(
                playbackPosition: Ticks(seconds: progressSeconds),
                playCount: played ? 1 : 0,
                isFavorite: false,
                played: played,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            ),
            indexNumber: index,
            parentIndexNumber: season,
            seriesName: series.name,
            premiereDate: premiereDate
        )
    }

    /// 剧集内容：默认停在第 2 季（下一集未看所在季）。
    static let seriesContent: DetailContent = {
        let seasonID = DetailViewModel.defaultSeasonID(seasons: seasons, allEpisodes: allEpisodes)
        let season = DetailViewModel.season(withID: seasonID, in: seasons)
        return DetailContent(
            item: series,
            seasons: seasons.sorted(by: DetailViewModel.seasonOrder),
            episodes: DetailViewModel.episodes(in: season, from: allEpisodes),
            similar: similarMovies,
            people: DetailViewModel.orderedPeople(movie.people ?? [])
        )
    }()

    /// 一个季的集（预览用）。
    ///
    /// - Parameter seasonID: 季 id。
    /// - Returns: 该季的集。
    static func episodes(in seasonID: String) -> [MediaItem] {
        let season = seasons.first { $0.id == seasonID }
        return DetailViewModel.episodes(in: season, from: allEpisodes)
    }
}

// MARK: - 预览数据源

/// 预览 / 演示用的数据源：不联网，按 id 返回假数据。
///
/// - `delay` 用来演示骨架屏；
/// - `failure` 非空时所有请求都抛它，用来演示错误态。
struct PreviewDetailDataSource: DetailDataSource {
    /// 人为延迟（演示加载态）。
    var delay: Duration
    /// 是否让请求失败（演示错误态）。
    var failure: EmbyError?

    /// 创建预览数据源。
    ///
    /// - Parameters:
    ///   - delay: 延迟，默认 0。
    ///   - failure: 失败原因，默认 `nil`（成功）。
    init(delay: Duration = .zero, failure: EmbyError? = nil) {
        self.delay = delay
        self.failure = failure
    }

    func itemDetail(itemId: String) async throws -> MediaItem {
        try await wait()
        return itemId == DetailPreviewData.series.id ? DetailPreviewData.series : DetailPreviewData.movie
    }

    func seasons(seriesId: String) async throws -> [MediaItem] {
        try await wait()
        return DetailPreviewData.seasons
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        try await wait()
        guard let seasonId else { return DetailPreviewData.allEpisodes }
        return DetailPreviewData.episodes(in: seasonId)
    }

    func similar(itemId: String) async throws -> [MediaItem] {
        try await wait()
        return DetailPreviewData.similarMovies
    }

    func setPlayed(itemId: String, played: Bool) async throws -> UserItemData {
        try await wait()
        return UserItemData(
            playbackPosition: played ? Ticks.zero : Ticks(seconds: 2100),
            playCount: played ? 1 : 0,
            isFavorite: false,
            played: played,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    }

    func setFavorite(itemId: String, isFavorite: Bool) async throws -> UserItemData {
        try await wait()
        return UserItemData(
            playbackPosition: Ticks(seconds: 2100),
            playCount: 0,
            isFavorite: isFavorite,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    }

    func imageURL(itemId: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL? {
        guard let tag, !tag.isEmpty else { return nil }
        return DetailPreviewData.imageURL(itemID: itemId, kind: kind, tag: tag)
    }

    /// 统一延迟 + 失败注入。
    ///
    /// - Throws: ``PrismCore/EmbyError``。
    private func wait() async throws {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let failure {
            throw failure
        }
    }
}

// MARK: - 预览图片加载器

/// 预览专用图片加载器：按 URL 里的图片类型现场画一张图。
///
/// 为什么不用 `DesignSystem` 的 `PreviewImageLoader`：详情页需要三类特殊图——
/// 16:9 的 backdrop、**透明背景**的 logo、方形头像。统一画成 2:3 渐变会让
/// 头图看起来像被拉扁的海报，logo 更会变成一块不透明色块。
///
/// 全部用 `CGContext` + CoreText 绘制（不依赖 AppKit 绘制上下文，线程安全）。
struct DetailPreviewImageLoader: PosterImageLoading {
    /// 人为延迟，用于观察骨架屏。
    var delay: Duration

    /// 创建加载器。
    ///
    /// - Parameter delay: 延迟，默认 0。
    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func image(for url: URL, targetSize: CGSize) async throws -> NSImage {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        let kind = Self.kind(for: url)
        guard let image = Self.makeImage(kind: kind, seed: Self.seed(for: url)) else {
            throw PosterImageError.decodingFailed
        }
        return image
    }

    /// 从 URL 路径里认出图片类型。
    ///
    /// - Parameter url: 假地址（`…/detail/{id}/{kind}?tag=…`）。
    /// - Returns: 图片类型。
    private static func kind(for url: URL) -> ImageKind {
        let last = url.lastPathComponent
        if last.contains("backdrop") { return .backdrop }
        if last.contains("logo") { return .logo }
        if last.contains("thumb") { return .thumb }
        return .primary
    }

    /// 稳定的种子：同一 URL 每次预览得到同一张图。
    ///
    /// - Parameter url: 地址。
    /// - Returns: 种子。
    private static func seed(for url: URL) -> UInt32 {
        url.absoluteString.unicodeScalars.reduce(UInt32(11)) { partial, scalar in
            partial &* 31 &+ scalar.value
        }
    }

    /// 按类型画图。
    ///
    /// - Parameters:
    ///   - kind: 图片类型。
    ///   - seed: 配色种子。
    /// - Returns: 图片。
    private static func makeImage(kind: ImageKind, seed: UInt32) -> NSImage? {
        switch kind {
        case .backdrop, .thumb:
            return gradientImage(width: 480, height: 270, seed: seed)
        case .logo:
            return logoImage(width: 480, height: 160, seed: seed)
        default:
            return gradientImage(width: 300, height: 450, seed: seed)
        }
    }

    /// 画一张渐变图（海报 / 剧照 / 缩略图通用）。
    ///
    /// - Parameters:
    ///   - width: 宽。
    ///   - height: 高。
    ///   - seed: 配色种子。
    /// - Returns: 图片。
    private static func gradientImage(width: Int, height: Int, seed: UInt32) -> NSImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let hue = CGFloat(seed % 360) / 360
        let start = NSColor(calibratedHue: hue, saturation: 0.68, brightness: 0.30, alpha: 1).cgColor
        let end = NSColor(
            calibratedHue: (hue + 0.10).truncatingRemainder(dividingBy: 1),
            saturation: 0.55,
            brightness: 0.62,
            alpha: 1
        ).cgColor

        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [start, end] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: height),
                end: CGPoint(x: width, y: 0),
                options: []
            )
        }

        // 两个柔光斑，让每张图的构图有区分度。
        context.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        context.fillEllipse(in: CGRect(x: -width / 6, y: height / 2, width: width / 2, height: width / 2))
        context.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: CGRect(x: width / 2, y: -height / 4, width: width / 2, height: width / 2))

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    /// 画一张「透明背景 + 白色字标」的假 logo。
    ///
    /// - Parameters:
    ///   - width: 宽。
    ///   - height: 高。
    ///   - seed: 种子（只用于挑选文案，保证同一地址稳定）。
    /// - Returns: 图片。
    private static func logoImage(width: Int, height: Int, seed: UInt32) -> NSImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // 透明背景：logo 必须能透出底下的 backdrop。
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let words = ["PRISM", "CINEMA", "ORIGINAL", "STUDIO"]
        let text = words[Int(seed % UInt32(words.count))]
        draw(text: text, in: context, size: CGSize(width: width, height: height))

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    /// 用 CoreText 在透明画布上居中画一行白色粗体字。
    ///
    /// - Parameters:
    ///   - text: 文案。
    ///   - context: 画布。
    ///   - size: 画布尺寸。
    private static func draw(text: String, in context: CGContext, size: CGSize) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size.height * 0.42, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: NSColor.white.cgColor,
            kCTKernAttributeName: NSNumber(value: Double(size.height * 0.04))
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (size.width - bounds.width) / 2 - bounds.minX,
            y: (size.height - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }
}
