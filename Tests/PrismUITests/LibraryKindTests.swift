import Testing
import EmbyAPI
import PrismCore
@testable import PrismUI

/// ``LibraryKind``：把服务端 `CollectionType` 翻译成客户端行为。
///
/// 这层替代了早期「按库名里的『剧 / tv / series』猜类型、猜不中一律当电影」的做法。
/// 猜错的后果是用户点开纪录片库、合集库、自定义命名的剧集库时全都进了电影栏。
@Suite("LibraryKind")
struct LibraryKindTests {
    // MARK: 服务端类型映射

    @Test("movies 映射到电影库")
    func moviesCollectionType() {
        let kind = LibraryKind(collectionType: .movies)

        #expect(kind == .movies)
        #expect(kind.itemTypes == [.movie])
        #expect(kind.mediaKind == .video)
        #expect(kind.title == "电影")
    }

    @Test("tvshows 映射到剧集库")
    func tvShowsCollectionType() {
        let kind = LibraryKind(collectionType: .tvShows)

        #expect(kind == .series)
        #expect(kind.itemTypes == [.series])
        #expect(kind.mediaKind == .video)
        #expect(kind.title == "剧集")
    }

    @Test("boxsets 映射到合集库，且不会被当成电影")
    func boxSetsCollectionType() {
        let kind = LibraryKind(collectionType: LibraryType(rawValue: "boxsets"))

        #expect(kind == .boxsets)
        #expect(kind.itemTypes == [.boxSet])
        #expect(kind.title == "合集")
        #expect(kind.sidebarItem == nil)
    }

    @Test("music 映射到音乐库并使用音频大类")
    func musicCollectionType() {
        let kind = LibraryKind(collectionType: .music)

        #expect(kind == .music)
        #expect(kind.mediaKind == .audio)
        #expect(kind.itemTypes == [.musicAlbum])
        #expect(kind.countUnit == "张")
    }

    @Test("books 映射到图书库")
    func booksCollectionType() {
        let kind = LibraryKind(collectionType: .books)

        #expect(kind == .books)
        #expect(kind.mediaKind == .book)
        #expect(kind.itemTypes == [.book])
    }

    @Test("缺少 CollectionType 的混合库不限制条目类型")
    func mixedLibraryHasNoTypeFilter() {
        let kind = LibraryKind(collectionType: nil)

        #expect(kind == .mixed)
        #expect(kind.itemTypes.isEmpty)
        #expect(kind.mediaKind == .video)
        #expect(kind.sidebarItem == nil)
    }

    @Test("未知 CollectionType 不崩溃、按混合库处理")
    func unknownCollectionTypeFallsBackToMixed() {
        let kind = LibraryKind(collectionType: LibraryType(rawValue: "something-new"))

        #expect(kind == .mixed)
    }

    @Test("类型匹配不区分大小写")
    func collectionTypeIsCaseInsensitive() {
        #expect(LibraryKind(collectionType: LibraryType(rawValue: "TVShows")) == .series)
        #expect(LibraryKind(collectionType: LibraryType(rawValue: "MOVIES")) == .movies)
    }

    // MARK: 侧边栏归属

    @Test("只有电影与剧集库有固定侧边栏归属")
    func sidebarOwnership() {
        #expect(LibraryKind.movies.sidebarItem == .movies)
        #expect(LibraryKind.series.sidebarItem == .series)
        #expect(LibraryKind.boxsets.sidebarItem == nil)
        #expect(LibraryKind.music.sidebarItem == nil)
        #expect(LibraryKind.mixed.sidebarItem == nil)
    }

    // MARK: 旧路由兼容

    @Test("由 ItemType 兼容映射")
    func itemTypeMapping() {
        #expect(LibraryKind(itemType: .series) == .series)
        #expect(LibraryKind(itemType: .movie) == .movies)
        #expect(LibraryKind(itemType: .boxSet) == .boxsets)
        #expect(LibraryKind(itemType: .musicAlbum) == .music)
        #expect(LibraryKind(itemType: .book) == .books)
        #expect(LibraryKind(itemType: .photo) == .photos)
    }
}
