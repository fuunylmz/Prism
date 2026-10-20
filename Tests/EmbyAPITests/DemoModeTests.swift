import Foundation
import Testing
import PrismCore
@testable import EmbyAPI

/// 演示模式开关与数据模型的测试。
@Suite("演示模式：开关与数据")
struct DemoModeTests {

    // MARK: - 开关判定

    @Test("环境变量 PRISM_DEMO=1 开启")
    func environmentVariableEnables() {
        #expect(DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": "1"]))
        #expect(DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": "true"]))
        #expect(DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": "YES"]))
        #expect(DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": "on"]))
    }

    @Test("环境变量非真值时不开启")
    func environmentVariableIgnoresFalsey() {
        #expect(!DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": "0"]))
        #expect(!DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": "false"]))
        #expect(!DemoMode.evaluate(arguments: ["Prism"], environment: ["PRISM_DEMO": ""]))
        #expect(!DemoMode.evaluate(arguments: ["Prism"], environment: [:]))
    }

    @Test("启动参数 -DemoMode YES 开启")
    func launchArgumentEnables() {
        #expect(DemoMode.evaluate(arguments: ["Prism", "-DemoMode", "YES"], environment: [:]))
        #expect(DemoMode.evaluate(arguments: ["Prism", "-DemoMode", "1"], environment: [:]))
    }

    @Test("启动参数 -DemoMode NO 显式关闭，即使环境变量为真也优先环境变量")
    func launchArgumentCanDisable() {
        #expect(!DemoMode.evaluate(arguments: ["Prism", "-DemoMode", "NO"], environment: [:]))
        // 环境变量优先级更高：两者同时出现时以环境变量为准。
        #expect(DemoMode.evaluate(arguments: ["Prism", "-DemoMode", "NO"], environment: ["PRISM_DEMO": "1"]))
    }

    @Test("裸 -DemoMode（后面没有值）视为开启")
    func bareLaunchArgumentEnables() {
        #expect(DemoMode.evaluate(arguments: ["Prism", "-DemoMode"], environment: [:]))
        // 后面紧跟另一个 flag，说明没有跟值。
        #expect(DemoMode.evaluate(arguments: ["Prism", "-DemoMode", "-NSDoubleLocalizedStrings"], environment: [:]))
    }

    @Test("常量字面量与文档一致")
    func constantLiterals() {
        #expect(DemoMode.launchArgument == "-DemoMode")
        #expect(DemoMode.environmentVariable == "PRISM_DEMO")
    }

    @Test("isEnabled 与当前进程实际参数一致")
    func isEnabledMatchesProcess() {
        let expected = DemoMode.evaluate(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        #expect(DemoMode.isEnabled == expected)
    }

    // MARK: - 库规模

    @Test("演示库有 3 个媒体库视图，且 CollectionType 正确")
    func libraryViews() throws {
        let views = DemoLibrary.views
        #expect(views.count == 3)

        let movies = try #require(views.first { $0.collectionType == .movies })
        #expect(movies.name == "电影")
        #expect(movies.item.type == .collectionFolder)

        let tv = try #require(views.first { $0.collectionType == .tvShows })
        #expect(tv.name == "剧集")

        let collections = try #require(views.first { $0.collectionType?.rawValue == "boxsets" })
        #expect(collections.name == "合集")
    }

    @Test("至少 24 部电影，且字段齐全")
    func movieScaleAndFields() throws {
        let movies = DemoLibrary.movies
        #expect(movies.count >= 24)
        #expect(movies.count == 26)

        for movie in movies {
            #expect(!movie.name.isEmpty)
            #expect(movie.type == .movie)
            #expect(movie.serverId == DemoLibrary.serverId)
            #expect(movie.productionYear != nil)
            #expect((movie.overview ?? "").count >= 20, "简介太短：\(movie.name)")
            #expect(movie.communityRating != nil)
            #expect(!movie.genres.isEmpty)
            #expect((movie.runTime?.seconds ?? 0) > 0)
            #expect(movie.hasPrimaryImage)
            #expect(movie.primaryBackdropTag != nil)
        }
    }

    @Test("至少 8 部剧，每部 2-3 季，每季 6-10 集")
    func seriesScale() throws {
        let series = DemoLibrary.series
        #expect(series.count >= 8)
        #expect(series.count == 8)

        for show in series {
            let seasons = DemoLibrary.seasons(ofSeries: show.id)
            #expect((2...3).contains(seasons.count), "\(show.name) 季数不对：\(seasons.count)")

            for season in seasons {
                let episodes = DemoLibrary.episodes(ofSeries: show.id)
                    .filter { $0.seasonId == season.id }
                #expect((6...10).contains(episodes.count), "\(show.name) 集数不对：\(episodes.count)")
            }
        }
    }

    @Test("剧集总数与季/集编号自洽")
    func episodeNumbering() {
        let episodes = DemoLibrary.episodes
        #expect(episodes.count == 148)

        for episode in episodes {
            #expect(episode.type == .episode)
            #expect(episode.seriesId != nil)
            #expect(episode.seasonId != nil)
            #expect(episode.seriesName != nil)
            #expect((episode.parentIndexNumber ?? 0) >= 1)
            #expect((episode.indexNumber ?? 0) >= 1)
        }
    }

    @Test("每部剧的 (季号, 集号) 组合唯一")
    func episodeNumbersAreUnique() {
        for show in DemoLibrary.series {
            let episodes = DemoLibrary.episodes(ofSeries: show.id)
            let pairs = Set(episodes.map { "\($0.parentIndexNumber ?? -1)-\($0.indexNumber ?? -1)" })
            #expect(pairs.count == episodes.count, "\(show.name) 存在重复的季集编号")
        }
    }

    @Test("观看状态三态齐全：未看 / 看到一半 / 已看完")
    func watchStates() {
        let all = DemoLibrary.allItems
        #expect(all.contains { $0.userData.played })
        #expect(all.contains { $0.isResumable })
        #expect(all.contains { $0.userData.playbackPosition == .zero && !$0.userData.played })

        // 「继续观看」至少要有几条，否则首页会空。
        let resumable = all.filter { $0.isResumable }
        #expect(resumable.count >= 4)
    }

    @Test("合集有成员，且成员都是电影")
    func collectionMembers() throws {
        #expect(DemoLibrary.collections.count == 3)
        for collection in DemoLibrary.collections {
            let members = DemoLibrary.members(ofCollection: collection.id)
            #expect(!members.isEmpty, "\(collection.name) 没有成员")
            #expect(collection.childCount == members.count)
            #expect(members.allSatisfy { $0.type == .movie })
        }
    }

    @Test("id 稳定：同一作品每次调用得到同一 id")
    func idsAreStable() {
        #expect(DemoLibrary.stableID("movie:Interstellar") == DemoLibrary.stableID("movie:Interstellar"))
        #expect(DemoLibrary.stableID("movie:Interstellar") != DemoLibrary.stableID("movie:Dune"))
        #expect(DemoLibrary.stableID("movie:Interstellar").count == 32)
    }

    @Test("全部 id 唯一（含季与集）")
    func allIdsAreUnique() {
        let ids = DemoLibrary.allItems.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("详情补全会带上 People 与 MediaSources，列表条目不带")
    func detailCopyAddsFields() throws {
        let movie = try #require(DemoLibrary.movies.first)
        #expect(movie.mediaSources.isEmpty)
        #expect(movie.people == nil)

        let detail = DemoLibrary.detailCopy(of: movie)
        #expect(!detail.mediaSources.isEmpty)
        #expect((detail.people ?? []).isEmpty == false)
        #expect(detail.id == movie.id)

        let source = try #require(detail.mediaSources.first)
        #expect(source.supportsDirectPlay)
        #expect(source.mediaStreams.contains { $0.type == .video })
        #expect(source.mediaStreams.contains { $0.type == .audio })
        #expect(source.mediaStreams.contains { $0.type == .subtitle })
    }

    @Test("不可播放的条目（合集）没有媒体源")
    func collectionHasNoMediaSource() throws {
        let collection = try #require(DemoLibrary.collections.first)
        #expect(DemoLibrary.detailCopy(of: collection).mediaSources.isEmpty)
    }
}
