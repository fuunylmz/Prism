import Foundation
import PrismCore
import Testing
@testable import PrismUI

@Suite("首页图片地址")
struct HomeImageResolverTests {
    private let baseURL = URL(string: "https://emby.example.com/emby")!

    @Test("单张 Backdrop tag 不附加 /0")
    func singleBackdropUsesDefaultImageEndpoint() throws {
        let item = MediaItem(
            id: "item-1",
            name: "单张背景",
            type: .episode,
            serverId: "server-1",
            imageTags: [.backdrop: "backdrop-tag", .primary: "primary-tag"]
        )
        let url = try #require(HomeImageResolver(baseURL: baseURL).backdropURL(for: item))

        #expect(url.path == "/emby/Items/item-1/Images/Backdrop")
        #expect(url.query?.contains("tag=backdrop-tag") == true)
    }

    @Test("多张 Backdrop tags 使用第一个图片索引")
    func multipleBackdropsUseIndex() throws {
        let item = MediaItem(
            id: "item-2",
            name: "多张背景",
            type: .episode,
            serverId: "server-1",
            imageTags: [.backdrop: "backdrop-tag"],
            backdropTags: ["backdrop-0", "backdrop-1"]
        )
        let url = try #require(HomeImageResolver(baseURL: baseURL).backdropURL(for: item))

        #expect(url.path == "/emby/Items/item-2/Images/Backdrop/0")
    }

    @Test("单集缺少自身海报时回退到剧集海报来源")
    func episodeUsesSeriesPoster() throws {
        let item = MediaItem(
            id: "episode-1",
            name: "第一集",
            type: .episode,
            serverId: "server-1",
            seriesPrimaryImageTag: "series-tag",
            seriesId: "series-1"
        )
        let url = try #require(HomeImageResolver(baseURL: baseURL).posterURL(for: item))

        #expect(url.path == "/emby/Items/series-1/Images/Primary")
        #expect(url.query?.contains("tag=series-tag") == true)
    }

    @Test("缺少 Thumb 时使用 Primary 图片端点")
    func thumbnailFallsBackToPrimaryEndpoint() throws {
        let item = MediaItem(
            id: "item-primary-only",
            name: "只有海报",
            type: .movie,
            serverId: "server-1",
            imageTags: [.primary: "primary-tag"]
        )
        let url = try #require(HomeImageResolver(baseURL: baseURL).thumbnailURL(for: item))

        #expect(url.path == "/emby/Items/item-primary-only/Images/Primary")
        #expect(url.query?.contains("tag=primary-tag") == true)
    }

    @Test("Primary 缺失时父级 Thumb 保留 Thumb 图片类型")
    func posterUsesParentThumbEndpoint() throws {
        let item = MediaItem(
            id: "item-with-parent-thumb",
            name: "继承横版图",
            type: .episode,
            serverId: "server-1",
            parentThumbItemId: "parent-1",
            parentThumbImageTag: "parent-thumb-tag"
        )
        let url = try #require(HomeImageResolver(baseURL: baseURL).posterURL(for: item))

        #expect(url.path == "/emby/Items/parent-1/Images/Thumb")
        #expect(url.query?.contains("tag=parent-thumb-tag") == true)
    }
}
