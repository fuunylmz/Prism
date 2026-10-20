import Foundation
import PrismCore

/// 演示模式的**假媒体库**：一个连贯、可浏览、可播放的 Emby 库。
///
/// ## 规模
///
/// - 3 个媒体库视图：电影（26 部）、剧集（8 部 / 19 季 / 148 集）、合集（3 个套装）
/// - 全部条目都有标题、年份、中文简介、评分、类型标签、时长、图片 tag
/// - 观看状态三态齐全：未看 / 看到一半（`playbackPosition`）/ 已看完
///
/// ## 三个设计约束
///
/// 1. **id 必须跨启动稳定**：用 ``stableID(_:)``（FNV-1a）从作品名派生，
///    而不是 `UUID()`。否则每次启动海报颜色都变、`UserDefaults` 里的播放进度也会对不上。
/// 2. **图片不依赖网络**：`imageTags` 只是占位 tag，真正的图由 ``DemoArtwork`` 按 id 现画。
/// 3. **数据是纯静态的**：``catalog`` 只构建一次，所有条目都是不可变的 `MediaItem`，
///    因此可以安全地被任意 actor 并发读取。
///
/// 字段口径与 ``Fixtures`` 里的录制样例保持一致（同样的 `ServerId`、同样的 id 风格、
/// 同样的 `RunTimeTicks` 单位），这样「切到真实服务器」时 UI 不会遇到形态差异。
public enum DemoLibrary {

    // MARK: - 身份常量

    /// 演示服务器 id。与 ``Fixtures`` 里的录制样例保持一致。
    public static let serverId = "6f1a2c3d4e5b6789a0b1c2d3e4f50617"

    /// 演示服务器名。
    public static let serverName = "Living Room Emby"

    /// 演示用户 id。与 ``Fixtures/authenticate`` 里的 `User.Id` 一致。
    public static let userId = "8a1f0b2c3d4e5f60718293a4b5c6d7e8"

    /// 演示用户名。
    public static let userName = "alice"

    /// 电影库视图 id（与 ``Fixtures/views`` 一致）。
    public static let moviesLibraryId = "1f2e3d4c5b6a79880716253443526170"

    /// 剧集库视图 id（与 ``Fixtures/views`` 一致）。
    public static let tvShowsLibraryId = "2a3b4c5d6e7f80910a2b3c4d5e6f7081"

    /// 合集库视图 id（演示库独有）。
    public static let collectionsLibraryId = "4d5e6f708192a3b4c5d6e7f8091021b3"

    // MARK: - 时间基准

    /// 所有「入库时间 / 上次播放时间」的参照点。
    ///
    /// 取进程启动时刻而不是写死日期：这样「最新添加」永远看起来是最近的，
    /// 演示不会因为日期久远而显得像陈年数据。同一进程内恒定，排序结果可复现。
    public static let referenceDate = Date()

    // MARK: - 对外目录

    /// 顶层媒体库视图。
    public static var views: [MediaView] { catalog.views }

    /// 电影库内的电影（26 部）。
    public static var movies: [MediaItem] { catalog.movies }

    /// 剧集库内的剧（8 部）。
    public static var series: [MediaItem] { catalog.series }

    /// 合集库内的套装（3 个）。
    public static var collections: [MediaItem] { catalog.collections }

    /// 全部单集（148 集）。
    public static var episodes: [MediaItem] { catalog.episodes }

    /// 全部季（19 季）。
    public static var seasons: [MediaItem] { catalog.seasons }

    /// 所有可被 `/Users/{id}/Items` 命中的条目（电影 + 剧 + 季 + 集 + 合集）。
    public static var allItems: [MediaItem] { catalog.allItems }

    /// 按 id 查条目（含电影 / 剧 / 季 / 集 / 合集）。
    ///
    /// - Parameter id: 条目 id。
    /// - Returns: 条目；不存在时为 `nil`。
    public static func item(id: String) -> MediaItem? {
        catalog.itemIndex[id]
    }

    /// 某剧的全部单集，按「季号 → 集号」升序。
    ///
    /// - Parameter seriesId: 剧 id。
    /// - Returns: 单集数组；剧不存在时为空数组。
    public static func episodes(ofSeries seriesId: String) -> [MediaItem] {
        catalog.episodesBySeries[seriesId] ?? []
    }

    /// 某剧的全部季，按季号升序。
    ///
    /// - Parameter seriesId: 剧 id。
    /// - Returns: 季数组；剧不存在时为空数组。
    public static func seasons(ofSeries seriesId: String) -> [MediaItem] {
        catalog.seasonsBySeries[seriesId] ?? []
    }

    /// 某合集包含的条目。
    ///
    /// - Parameter collectionId: 合集 id。
    /// - Returns: 成员条目；不是合集或合集为空时返回空数组。
    public static func members(ofCollection collectionId: String) -> [MediaItem] {
        catalog.collectionMembers[collectionId] ?? []
    }

    /// 某条目的演职员（仅详情接口会带）。
    ///
    /// - Parameter itemId: 条目 id。
    /// - Returns: 演职员数组；该条目没有演职员数据时为 `nil`。
    public static func people(forItemId itemId: String) -> [Person]? {
        catalog.people[itemId]
    }

    /// 把列表条目补成「详情形态」：加上 `People` 与 `MediaSources`。
    ///
    /// 真实 Emby 的列表接口不返回这两个字段（`Fields` 不传就没有），只有
    /// `/Users/{id}/Items/{itemId}` 才返回。演示模式必须保持同样的形态，
    /// 否则 UI 会在列表里误以为「已经有媒体源了」。
    ///
    /// - Parameter item: 列表形态的条目。
    /// - Returns: 详情形态的条目。
    public static func detailCopy(of item: MediaItem) -> MediaItem {
        MediaItem(
            id: item.id,
            name: item.name,
            type: item.type,
            serverId: item.serverId,
            productionYear: item.productionYear,
            runTime: item.runTime,
            overview: item.overview,
            officialRating: item.officialRating,
            communityRating: item.communityRating,
            genres: item.genres,
            imageTags: item.imageTags,
            backdropTags: item.backdropTags,
            userData: item.userData,
            seriesId: item.seriesId,
            seasonId: item.seasonId,
            indexNumber: item.indexNumber,
            parentIndexNumber: item.parentIndexNumber,
            seriesName: item.seriesName,
            mediaSources: mediaSources(for: item),
            people: people(forItemId: item.id) ?? [],
            childCount: item.childCount,
            originalTitle: item.originalTitle,
            dateCreated: item.dateCreated,
            premiereDate: item.premiereDate,
            isFolder: item.isFolder
        )
    }

    // MARK: - id 与 tag

    /// 由种子派生一个 Emby 风格的 32 位十六进制 id。
    ///
    /// - Parameter seed: 种子（如 `"movie:Blade Runner 2049"`）。
    /// - Returns: 32 位小写十六进制字符串。
    public static func stableID(_ seed: String) -> String {
        let first = DemoArtwork.stableHash(seed)
        let second = DemoArtwork.stableHash(seed + "#prism-demo")
        return String(format: "%016lx%016lx", first, second)
    }

    /// 由种子派生一个图片缓存 tag（Emby 的 `ImageTags` 取值形态）。
    ///
    /// - Parameter seed: 种子。
    /// - Returns: 32 位小写十六进制字符串。
    public static func imageTag(_ seed: String) -> String {
        stableID("tag:" + seed)
    }

    // MARK: - 数据规格

    /// 观看状态。
    private enum WatchState: Sendable {
        /// 没看过。
        case unwatched
        /// 看到一半，关联值是进度（0...1）。
        case inProgress(Double)
        /// 已看完。
        case finished
    }

    /// 电影的数据规格。
    private struct MovieSpec: Sendable {
        /// 展示标题（中英混合）。
        let title: String
        /// 原始标题（用于搜索与 id 派生）。
        let originalTitle: String
        /// 出品年份。
        let year: Int
        /// 中文简介（2-3 句）。
        let overview: String
        /// 社区评分（0...10）。
        let rating: Double
        /// 类型标签。
        let genres: [String]
        /// 时长（分钟）。
        let runtimeMinutes: Int
        /// 分级。
        let certificate: String
        /// 导演。
        let director: String
        /// 主演。
        let cast: [String]
        /// 观看状态。
        let watch: WatchState
        /// 入库于几天前。
        let addedDaysAgo: Int
        /// 所属合集名（`nil` 表示不属于任何合集）。
        let collection: String?
    }

    /// 一季的数据规格。
    private struct SeasonSpec: Sendable {
        /// 季主题（第二季起会作为集名前缀）。
        let arc: String
        /// 每集标题（数量即集数）。
        let episodeTitles: [String]
    }

    /// 剧集的数据规格。
    private struct SeriesSpec: Sendable {
        /// 展示标题。
        let title: String
        /// 原始标题。
        let originalTitle: String
        /// 首播年份。
        let year: Int
        /// 中文简介。
        let overview: String
        /// 社区评分。
        let rating: Double
        /// 类型标签。
        let genres: [String]
        /// 分级。
        let certificate: String
        /// 主创。
        let creator: String
        /// 主演。
        let cast: [String]
        /// 各季。
        let seasons: [SeasonSpec]
        /// 入库于几天前。
        let addedDaysAgo: Int
        /// 看到哪一集（季号、集号、进度）；`nil` 表示没开始看。
        let watching: (season: Int, episode: Int, progress: Double)?
        /// 已经看完的集数（从第 1 季第 1 集开始连续计）。
        let finishedEpisodes: Int
    }

    // MARK: - 电影数据

    /// 26 部电影。标题中英混合，简介为中文 2-3 句。
    private static let movieSpecs: [MovieSpec] = [
        MovieSpec(
            title: "银翼杀手 2049", originalTitle: "Blade Runner 2049", year: 2017,
            overview: "复制人警探 K 在追查一桩旧案时，挖出了一个足以颠覆社会秩序的秘密。线索把他引向失踪三十年的前代银翼杀手德卡德。记忆与真实之间的界线，在雨夜里一点点融化。",
            rating: 8.1, genres: ["Science Fiction", "Drama", "Thriller"], runtimeMinutes: 163,
            certificate: "R", director: "丹尼斯·维伦纽瓦", cast: ["瑞恩·高斯林", "哈里森·福特", "安娜·德·阿玛斯"],
            watch: .inProgress(0.36), addedDaysAgo: 12, collection: "科幻精选"
        ),
        MovieSpec(
            title: "星际穿越", originalTitle: "Interstellar", year: 2014,
            overview: "地球濒临枯竭，一支探险队穿过虫洞去寻找人类可以迁徙的新家园。库珀与女儿墨菲之间跨越数十年的约定，被时间膨胀拉扯成两种完全不同的岁月。爱能否穿过五维空间，是这部影片最后的赌注。",
            rating: 8.6, genres: ["Science Fiction", "Adventure", "Drama"], runtimeMinutes: 169,
            certificate: "PG-13", director: "克里斯托弗·诺兰", cast: ["马修·麦康纳", "安妮·海瑟薇", "杰西卡·查斯坦"],
            watch: .finished, addedDaysAgo: 30, collection: "科幻精选"
        ),
        MovieSpec(
            title: "千与千寻", originalTitle: "Spirited Away", year: 2001,
            overview: "十岁的千寻误入神灵的世界，父母被变成猪，她只能在汤屋里打工求生。名字被夺走之后，她必须记住自己是谁，才能把家人带回人间。",
            rating: 9.3, genres: ["Animation", "Fantasy", "Adventure"], runtimeMinutes: 125,
            certificate: "PG", director: "宫崎骏", cast: ["柊瑠美", "入野自由", "夏木真理"],
            watch: .unwatched, addedDaysAgo: 5, collection: "动画之夜"
        ),
        MovieSpec(
            title: "盗梦空间", originalTitle: "Inception", year: 2010,
            overview: "柯布靠潜入他人梦境窃取秘密为生，这一次的任务却是「植入」一个念头。梦境一层层下坠，时间被拉长成几十年，回家的路也越来越模糊。",
            rating: 8.8, genres: ["Science Fiction", "Action", "Thriller"], runtimeMinutes: 148,
            certificate: "PG-13", director: "克里斯托弗·诺兰", cast: ["莱昂纳多·迪卡普里奥", "约瑟夫·高登-莱维特", "艾伦·佩吉"],
            watch: .inProgress(0.62), addedDaysAgo: 21, collection: "科幻精选"
        ),
        MovieSpec(
            title: "寄生虫", originalTitle: "Parasite", year: 2019,
            overview: "住在半地下室的一家人，靠伪造学历一个个混进富豪宅邸工作。两个阶层的距离，被一场暴雨冲得再也藏不住。",
            rating: 8.5, genres: ["Drama", "Thriller"], runtimeMinutes: 132,
            certificate: "R", director: "奉俊昊", cast: ["宋康昊", "李善均", "曹如晶"],
            watch: .finished, addedDaysAgo: 44, collection: "华语佳作"
        ),
        MovieSpec(
            title: "花样年华", originalTitle: "In the Mood for Love", year: 2000,
            overview: "1960 年代的香港，两户邻居发现各自的伴侣有了婚外情。他们在狭窄的楼梯与面摊之间反复相遇，把克制演成了最深的表白。",
            rating: 8.1, genres: ["Drama", "Romance"], runtimeMinutes: 98,
            certificate: "PG", director: "王家卫", cast: ["梁朝伟", "张曼玉"],
            watch: .unwatched, addedDaysAgo: 9, collection: "华语佳作"
        ),
        MovieSpec(
            title: "疯狂的麦克斯：狂暴之路", originalTitle: "Mad Max: Fury Road", year: 2015,
            overview: "末世荒漠里，弗瑞奥萨带着一群逃亡的女性驾驶战车穿越沙暴。麦克斯被迫卷入这场追逐，唯一的方向是向前。",
            rating: 8.1, genres: ["Action", "Science Fiction", "Adventure"], runtimeMinutes: 120,
            certificate: "R", director: "乔治·米勒", cast: ["汤姆·哈迪", "查理兹·塞隆", "尼古拉斯·霍尔特"],
            watch: .unwatched, addedDaysAgo: 3, collection: nil
        ),
        MovieSpec(
            title: "你的名字。", originalTitle: "Your Name.", year: 2016,
            overview: "住在乡下的三叶与东京少年泷，在梦里交换了身体。当彗星划过夜空，他们必须在时间与空间里找到彼此。",
            rating: 8.4, genres: ["Animation", "Romance", "Fantasy"], runtimeMinutes: 106,
            certificate: "PG", director: "新海诚", cast: ["神木隆之介", "上白石萌音"],
            watch: .finished, addedDaysAgo: 60, collection: "动画之夜"
        ),
        MovieSpec(
            title: "布达佩斯大饭店", originalTitle: "The Grand Budapest Hotel", year: 2014,
            overview: "传奇礼宾员古斯塔夫与门童零，卷入一幅名画与一份遗产的争夺。粉色的饭店像一座即将熄灭的旧欧洲。",
            rating: 8.1, genres: ["Comedy", "Drama", "Adventure"], runtimeMinutes: 99,
            certificate: "R", director: "韦斯·安德森", cast: ["拉尔夫·费因斯", "托尼·雷沃罗利", "西尔莎·罗南"],
            watch: .unwatched, addedDaysAgo: 16, collection: nil
        ),
        MovieSpec(
            title: "沙丘", originalTitle: "Dune", year: 2021,
            overview: "厄拉科斯星球上的香料，牵动着整个帝国的命运。少年保罗在家族覆灭后走进沙漠，去成为他并不想成为的那个人。",
            rating: 8.0, genres: ["Science Fiction", "Adventure"], runtimeMinutes: 155,
            certificate: "PG-13", director: "丹尼斯·维伦纽瓦", cast: ["提莫西·查拉梅", "丽贝卡·弗格森", "奥斯卡·伊萨克"],
            watch: .inProgress(0.18), addedDaysAgo: 7, collection: "科幻精选"
        ),
        MovieSpec(
            title: "无间道", originalTitle: "Infernal Affairs", year: 2002,
            overview: "警方卧底与黑帮内鬼，在同一座城市里互相追捕对方的影子。天台上的那句「我想做个好人」，成了港片最锋利的一句台词。",
            rating: 9.2, genres: ["Drama", "Crime", "Thriller"], runtimeMinutes: 101,
            certificate: "R", director: "刘伟强", cast: ["刘德华", "梁朝伟", "黄秋生"],
            watch: .finished, addedDaysAgo: 75, collection: "华语佳作"
        ),
        MovieSpec(
            title: "让子弹飞", originalTitle: "Let the Bullets Fly", year: 2010,
            overview: "土匪张麻子劫下赴任的县长，索性冒名进了鹅城。黄四郎的碉楼与他的枪，在鹅城的街上来回试探。",
            rating: 8.7, genres: ["Comedy", "Action", "Drama"], runtimeMinutes: 132,
            certificate: "R", director: "姜文", cast: ["姜文", "葛优", "周润发"],
            watch: .unwatched, addedDaysAgo: 26, collection: "华语佳作"
        ),
        MovieSpec(
            title: "瞬息全宇宙", originalTitle: "Everything Everywhere All at Once", year: 2022,
            overview: "洗衣店老板娘伊芙琳在报税途中，被卷进一场跨越多元宇宙的追杀。她要对抗的终极反派，其实是自己的女儿。",
            rating: 8.3, genres: ["Science Fiction", "Comedy", "Action"], runtimeMinutes: 139,
            certificate: "R", director: "关家永", cast: ["杨紫琼", "关继威", "许玮伦"],
            watch: .finished, addedDaysAgo: 38, collection: nil
        ),
        MovieSpec(
            title: "地心引力", originalTitle: "Gravity", year: 2013,
            overview: "太空碎片摧毁了空间站，宇航员瑞安只剩下一具破损的返回舱。在绝对的寂静里，她必须抓住每一次呼吸。",
            rating: 7.9, genres: ["Science Fiction", "Thriller"], runtimeMinutes: 91,
            certificate: "PG-13", director: "阿方索·卡隆", cast: ["桑德拉·布洛克", "乔治·克鲁尼"],
            watch: .unwatched, addedDaysAgo: 19, collection: "科幻精选"
        ),
        MovieSpec(
            title: "牯岭街少年杀人事件", originalTitle: "A Brighter Summer Day", year: 1991,
            overview: "1960 年代的台北，少年小四在帮派与家庭之间找不到自己的位置。青春被时代压碎的声音，安静得让人发慌。",
            rating: 8.9, genres: ["Drama", "Crime"], runtimeMinutes: 237,
            certificate: "R", director: "杨德昌", cast: ["张震", "杨静怡", "张国柱"],
            watch: .unwatched, addedDaysAgo: 52, collection: "华语佳作"
        ),
        MovieSpec(
            title: "海边的曼彻斯特", originalTitle: "Manchester by the Sea", year: 2016,
            overview: "李回到故乡处理哥哥的后事，被迫重新面对那场他从未原谅自己的意外。有些伤痛不会痊愈，只能带着它继续活。",
            rating: 8.4, genres: ["Drama"], runtimeMinutes: 137,
            certificate: "R", director: "肯尼斯·洛纳根", cast: ["卡西·阿弗莱克", "米歇尔·威廉姆斯", "卢卡斯·赫奇斯"],
            watch: .inProgress(0.74), addedDaysAgo: 11, collection: nil
        ),
        MovieSpec(
            title: "蜘蛛侠：平行宇宙", originalTitle: "Spider-Man: Into the Spider-Verse", year: 2018,
            overview: "迈尔斯被一只放射性蜘蛛咬中，成了布鲁克林的第二个蜘蛛侠。多元宇宙打开后，五个世界的蜘蛛侠挤进了同一个纽约。",
            rating: 8.6, genres: ["Animation", "Action", "Science Fiction"], runtimeMinutes: 117,
            certificate: "PG", director: "鲍勃·佩尔西凯蒂", cast: ["沙梅克·摩尔", "杰克·约翰逊", "海莉·斯坦菲尔德"],
            watch: .finished, addedDaysAgo: 33, collection: "动画之夜"
        ),
        MovieSpec(
            title: "大佛普拉斯", originalTitle: "The Great Buddha+", year: 2017,
            overview: "捡破烂的肚财和门卫菜埔，靠偷看老板的行车记录仪打发夜晚。画面里出现的东西，把他们的世界彻底掀翻。",
            rating: 8.2, genres: ["Drama", "Comedy"], runtimeMinutes: 102,
            certificate: "R", director: "黄信尧", cast: ["庄益增", "陈竹昇", "戴立忍"],
            watch: .unwatched, addedDaysAgo: 14, collection: "华语佳作"
        ),
        MovieSpec(
            title: "疯狂的石头", originalTitle: "Crazy Stone", year: 2006,
            overview: "一块翡翠引来三拨各怀鬼胎的人，在重庆的旧厂房里撞成一团。每个人都算得很精，每个人都差了一步。",
            rating: 8.6, genres: ["Comedy", "Crime"], runtimeMinutes: 98,
            certificate: "PG-13", director: "宁浩", cast: ["郭涛", "刘桦", "黄渤"],
            watch: .finished, addedDaysAgo: 48, collection: "华语佳作"
        ),
        MovieSpec(
            title: "降临", originalTitle: "Arrival", year: 2016,
            overview: "十二个外星飞行器降临地球，语言学家露易丝试图读懂它们的文字。学会一门语言，也就学会了它看待时间的方式。",
            rating: 8.0, genres: ["Science Fiction", "Drama", "Mystery"], runtimeMinutes: 116,
            certificate: "PG-13", director: "丹尼斯·维伦纽瓦", cast: ["艾米·亚当斯", "杰瑞米·雷纳", "福里斯特·惠特克"],
            watch: .unwatched, addedDaysAgo: 2, collection: "科幻精选"
        ),
        MovieSpec(
            title: "燃烧", originalTitle: "Burning", year: 2018,
            overview: "送货的少年偶遇旧日同学，又认识了她的神秘男友本。一座塑料大棚的消失，成了所有疑问的起点。",
            rating: 7.9, genres: ["Drama", "Mystery"], runtimeMinutes: 148,
            certificate: "R", director: "李沧东", cast: ["刘亚仁", "史蒂文·元", "全钟瑞"],
            watch: .unwatched, addedDaysAgo: 24, collection: nil
        ),
        MovieSpec(
            title: "卧虎藏龙", originalTitle: "Crouching Tiger, Hidden Dragon", year: 2000,
            overview: "李慕白想退出江湖，却因一把青冥剑再次被卷回恩怨。竹林上的追逐，说的其实是压抑了一生的心事。",
            rating: 8.3, genres: ["Action", "Drama", "Romance"], runtimeMinutes: 120,
            certificate: "PG-13", director: "李安", cast: ["周润发", "杨紫琼", "章子怡"],
            watch: .finished, addedDaysAgo: 66, collection: "华语佳作"
        ),
        MovieSpec(
            title: "心灵奇旅", originalTitle: "Soul", year: 2020,
            overview: "爵士钢琴师乔在梦想成真的前夜掉进了下水道，醒来时已经是一缕灵魂。他必须教会 22 号「活着的意义」，才换得回自己的生命。",
            rating: 8.7, genres: ["Animation", "Fantasy", "Music"], runtimeMinutes: 100,
            certificate: "PG", director: "彼特·道格特", cast: ["杰米·福克斯", "蒂娜·菲"],
            watch: .unwatched, addedDaysAgo: 6, collection: "动画之夜"
        ),
        MovieSpec(
            title: "一一", originalTitle: "Yi Yi", year: 2000,
            overview: "台北一个普通家庭在一年里经历了婚礼、满月与葬礼。小男孩洋洋拿着相机，拍下所有大人看不见的后脑勺。",
            rating: 8.9, genres: ["Drama", "Family"], runtimeMinutes: 173,
            certificate: "PG-13", director: "杨德昌", cast: ["吴念真", "金燕玲", "李凯莉"],
            watch: .unwatched, addedDaysAgo: 41, collection: "华语佳作"
        ),
        MovieSpec(
            title: "边境杀手", originalTitle: "Sicario", year: 2015,
            overview: "FBI 探员凯特被借调到边境特别行动组，去追捕一个墨西哥毒枭。她很快发现，规则在国境线上就已经失效。",
            rating: 7.9, genres: ["Action", "Crime", "Thriller"], runtimeMinutes: 121,
            certificate: "R", director: "丹尼斯·维伦纽瓦", cast: ["艾米莉·布朗特", "本尼西奥·德尔·托罗", "乔什·布洛林"],
            watch: .inProgress(0.45), addedDaysAgo: 17, collection: nil
        ),
        MovieSpec(
            title: "月球", originalTitle: "Moon", year: 2009,
            overview: "在月球背面的单人基地里，山姆即将结束三年的合约。他遇见了一个和自己一模一样的人。",
            rating: 7.9, genres: ["Science Fiction", "Mystery"], runtimeMinutes: 97,
            certificate: "R", director: "邓肯·琼斯", cast: ["山姆·洛克威尔", "凯文·史派西"],
            watch: .unwatched, addedDaysAgo: 28, collection: "科幻精选"
        )
    ]

    // MARK: - 剧集数据

    /// 8 部剧，共 19 季、148 集。
    private static let seriesSpecs: [SeriesSpec] = [
        SeriesSpec(
            title: "雾港谜案", originalTitle: "Fog Harbor", year: 2021,
            overview: "一座常年被雾笼罩的港口城市，每隔七年就会有一艘船无声无息地消失。刑警队长沈砚接手旧案时，发现所有卷宗都被同一个人签过字。",
            rating: 8.6, genres: ["Mystery", "Crime", "Drama"], certificate: "TV-MA",
            creator: "陈叙", cast: ["沈砚", "周未晚", "老吴"],
            seasons: [
                SeasonSpec(arc: "暗流", episodeTitles: ["雾中来客", "灯塔守夜人", "失踪的船票", "第七码头", "潮汐表", "旧照片", "雨夜证词", "退潮"]),
                SeasonSpec(arc: "回响", episodeTitles: ["沉船", "空号", "黑潮", "访客", "断线", "回声", "底舱", "出港"])
            ],
            addedDaysAgo: 8, watching: (season: 1, episode: 3, progress: 0.42), finishedEpisodes: 2
        ),
        SeriesSpec(
            title: "长安十二时辰", originalTitle: "The Longest Day in Chang'an", year: 2019,
            overview: "上元节前夕，突厥狼卫潜入长安，图谋在灯会当夜焚城。死囚张小敬被临时起用，只有十二个时辰把这座城从火里拉回来。",
            rating: 8.3, genres: ["Historical", "Mystery", "Action"], certificate: "TV-14",
            creator: "曹盾", cast: ["雷佳音", "易烊千玺", "周一围"],
            seasons: [
                SeasonSpec(arc: "上元", episodeTitles: ["开市", "狼卫", "望楼", "火雷", "靖安司", "长安十二时", "灯楼", "破晓"]),
                SeasonSpec(arc: "西市", episodeTitles: ["胡商", "暗渠", "铜钱", "夜禁", "西市口", "驿马", "曲江", "天明"])
            ],
            addedDaysAgo: 15, watching: nil, finishedEpisodes: 0
        ),
        SeriesSpec(
            title: "黑镜", originalTitle: "Black Mirror", year: 2011,
            overview: "每一集都是一个独立的故事，讲技术如何把人的欲望放大成灾难。它不预言未来，只是把当下往前推半步。",
            rating: 8.7, genres: ["Science Fiction", "Drama", "Thriller"], certificate: "TV-MA",
            creator: "查理·布鲁克", cast: ["丹尼尔·卡卢亚", "布莱丝·达拉斯·霍华德", "乔恩·哈姆"],
            seasons: [
                SeasonSpec(arc: "预言", episodeTitles: ["国歌", "一千五百万", "你的全部历史", "白色圣诞", "记忆回放", "评分人生"]),
                SeasonSpec(arc: "算法", episodeTitles: ["社交评分", "云端爱人", "复制意识", "电子蜜蜂", "沉默的海", "最后一次登录"]),
                SeasonSpec(arc: "断层", episodeTitles: ["数字来世", "滤镜", "无人驾驶", "假新闻", "离线", "黑镜"])
            ],
            addedDaysAgo: 4, watching: nil, finishedEpisodes: 2
        ),
        SeriesSpec(
            title: "硅谷", originalTitle: "Silicon Valley", year: 2014,
            overview: "几个住在同一栋房子里的程序员，用一个压缩算法闯进了硅谷的食物链。融资、内斗、发布会，每一步都荒诞得像真的。",
            rating: 8.5, genres: ["Comedy"], certificate: "TV-MA",
            creator: "迈克·乔吉", cast: ["托马斯·米德蒂奇", "T·J·米勒", "库梅尔·南贾尼"],
            seasons: [
                SeasonSpec(arc: "种子轮", episodeTitles: ["压缩算法", "车库创业", "投资人", "演示日", "服务器", "股权", "加班", "上线"]),
                SeasonSpec(arc: "A 轮", episodeTitles: ["融资", "专利", "招聘", "内测", "竞品", "裁员", "收购", "发布会"]),
                SeasonSpec(arc: "退出", episodeTitles: ["董事会", "数据泄露", "迁移", "诉讼", "开源", "估值", "敲钟", "尾声"])
            ],
            addedDaysAgo: 22, watching: (season: 1, episode: 5, progress: 0.15), finishedEpisodes: 4
        ),
        SeriesSpec(
            title: "深夜食堂", originalTitle: "Midnight Diner", year: 2009,
            overview: "东京小巷里一家只在深夜营业的小店，菜单上只有猪肉汤。老板说，想吃什么都可以点，只要我会做。",
            rating: 8.9, genres: ["Drama", "Slice of Life"], certificate: "TV-PG",
            creator: "松冈锭司", cast: ["小林薰", "绫田俊树", "松重丰"],
            seasons: [
                SeasonSpec(arc: "宵夜", episodeTitles: ["猪肉汤", "猫饭", "茶泡饭", "鸡蛋卷", "红香肠", "梅干", "拉面", "关东煮", "清酒", "打烊"]),
                SeasonSpec(arc: "夜归", episodeTitles: ["炸鸡", "咖喱饭", "玉子烧", "冷面", "烤鱼", "豆腐", "甜酒", "年糕", "便当", "天亮"])
            ],
            addedDaysAgo: 10, watching: nil, finishedEpisodes: 0
        ),
        SeriesSpec(
            title: "怪奇物语", originalTitle: "Stranger Things", year: 2016,
            overview: "1983 年，印第安纳州的小镇上有个男孩凭空消失。他的朋友们在森林里找到一个剃着平头、会念力的女孩。",
            rating: 8.7, genres: ["Science Fiction", "Horror", "Mystery"], certificate: "TV-14",
            creator: "达菲兄弟", cast: ["米莉·博比·布朗", "薇诺娜·瑞德", "大卫·哈伯"],
            seasons: [
                SeasonSpec(arc: "颠倒世界", episodeTitles: ["消失的男孩", "枫树街", "十一号", "逆世界", "圣诞灯", "实验室", "魔王", "门"]),
                SeasonSpec(arc: "暗影", episodeTitles: ["万圣节", "南瓜地", "新同学", "隧道", "影子", "录像带", "蜂群", "关闸"]),
                SeasonSpec(arc: "星庭", episodeTitles: ["商场", "冰淇淋店", "苏联人", "磁铁", "密室", "血肉", "篝火", "独立日"])
            ],
            addedDaysAgo: 1, watching: (season: 1, episode: 1, progress: 0.75), finishedEpisodes: 0
        ),
        SeriesSpec(
            title: "请回答 1988", originalTitle: "Reply 1988", year: 2015,
            overview: "1988 年首尔双门洞的一条胡同，五户人家把日子过成了一家人。没有大事件，只有搬家、考试和冬天的第一场雪。",
            rating: 9.7, genres: ["Drama", "Family", "Comedy"], certificate: "TV-14",
            creator: "申元浩", cast: ["李惠利", "朴宝剑", "柳俊烈"],
            seasons: [
                SeasonSpec(arc: "双门洞", episodeTitles: ["搬家", "泡菜", "围棋", "考试", "初雪", "胡同", "生日", "成年"]),
                SeasonSpec(arc: "那年", episodeTitles: ["重逢", "旧照", "高考", "告白", "远行", "婚礼", "老屋", "再见"])
            ],
            addedDaysAgo: 18, watching: nil, finishedEpisodes: 1
        ),
        SeriesSpec(
            title: "白色巨塔", originalTitle: "The White Tower", year: 2003,
            overview: "大学医院里，两个同期医生走向了完全相反的路：一个追逐权力，一个守着医者的底线。白色巨塔里没有真正的赢家。",
            rating: 9.1, genres: ["Drama", "Medical"], certificate: "TV-MA",
            creator: "西谷弘", cast: ["唐泽寿明", "江口洋介", "黑木瞳"],
            seasons: [
                SeasonSpec(arc: "白色", episodeTitles: ["查房", "手术", "论文", "派系", "误诊", "听证", "塔顶"]),
                SeasonSpec(arc: "裂缝", episodeTitles: ["复职", "官司", "证词", "同僚", "病历", "和解", "落幕"])
            ],
            addedDaysAgo: 35, watching: nil, finishedEpisodes: 0
        )
    ]

    // MARK: - 合集

    /// 合集定义：名称 + 中文简介。
    ///
    /// 成员关系由 ``MovieSpec/collection`` 单向声明，避免「合集里列了 A、A 却说自己不在合集里」
    /// 这种两份数据打架的情况。
    private static let collectionSpecs: [(name: String, overview: String)] = [
        (
            "科幻精选",
            "从赛博都市到沙丘荒漠，七部把「如果」推到极限的电影。适合一口气看完，再怀疑一会儿现实。"
        ),
        (
            "华语佳作",
            "两岸三地的九部代表作，从港片黄金年代到当代作者电影。每一部都值得单独拿出来重看一遍。"
        ),
        (
            "动画之夜",
            "四部画风完全不同、但都适合深夜独自观看的动画。看完会想给很久没联系的人发条消息。"
        )
    ]

    // MARK: - 目录构建

    /// 一次性构建好的只读目录。
    private struct Catalog: Sendable {
        let views: [MediaView]
        let movies: [MediaItem]
        let series: [MediaItem]
        let collections: [MediaItem]
        let episodes: [MediaItem]
        let seasons: [MediaItem]
        let allItems: [MediaItem]
        let itemIndex: [String: MediaItem]
        let episodesBySeries: [String: [MediaItem]]
        let seasonsBySeries: [String: [MediaItem]]
        let collectionMembers: [String: [MediaItem]]
        let people: [String: [Person]]
    }

    /// 全局唯一的目录实例（首次访问时构建）。
    private static let catalog: Catalog = buildCatalog()

    /// 构建整个演示库。
    ///
    /// - Returns: 完整的只读目录。
    private static func buildCatalog() -> Catalog {
        var movies: [MediaItem] = []
        var people: [String: [Person]] = [:]

        for (index, spec) in movieSpecs.enumerated() {
            let item = makeMovie(spec, index: index)
            movies.append(item)
            people[item.id] = makePeople(director: spec.director, cast: spec.cast)
        }

        var series: [MediaItem] = []
        var episodes: [MediaItem] = []
        var seasons: [MediaItem] = []
        var episodesBySeries: [String: [MediaItem]] = [:]
        var seasonsBySeries: [String: [MediaItem]] = [:]

        for (seriesIndex, spec) in seriesSpecs.enumerated() {
            let seriesID = stableID("series:" + spec.originalTitle)
            let seriesEpisodes = makeEpisodes(spec, seriesID: seriesID)
            let seriesSeasons = makeSeasons(spec, seriesID: seriesID)
            let seriesItem = makeSeries(spec, seriesID: seriesID, episodes: seriesEpisodes, index: seriesIndex)

            series.append(seriesItem)
            episodes.append(contentsOf: seriesEpisodes)
            seasons.append(contentsOf: seriesSeasons)
            episodesBySeries[seriesID] = seriesEpisodes
            seasonsBySeries[seriesID] = seriesSeasons
            people[seriesID] = makePeople(director: spec.creator, cast: spec.cast)
        }

        var collections: [MediaItem] = []
        var collectionMembers: [String: [MediaItem]] = [:]
        for (index, spec) in collectionSpecs.enumerated() {
            let members = zip(movieSpecs, movies)
                .filter { $0.0.collection == spec.name }
                .map { $0.1 }
            let collection = makeCollection(spec, members: members, index: index)
            collections.append(collection)
            collectionMembers[collection.id] = members
        }

        var itemIndex: [String: MediaItem] = [:]
        for item in movies + series + seasons + episodes + collections {
            itemIndex[item.id] = item
        }

        let views = makeViews(
            movies: movies,
            series: series,
            collections: collections,
            episodes: episodes
        )

        return Catalog(
            views: views,
            movies: movies,
            series: series,
            collections: collections,
            episodes: episodes,
            seasons: seasons,
            allItems: movies + series + seasons + episodes + collections,
            itemIndex: itemIndex,
            episodesBySeries: episodesBySeries,
            seasonsBySeries: seasonsBySeries,
            collectionMembers: collectionMembers,
            people: people
        )
    }

    /// 构建媒体库视图。
    ///
    /// - Parameters:
    ///   - movies: 电影。
    ///   - series: 剧。
    ///   - collections: 合集。
    ///   - episodes: 单集（用于统计未看数）。
    /// - Returns: 三个视图。
    private static func makeViews(
        movies: [MediaItem],
        series: [MediaItem],
        collections: [MediaItem],
        episodes: [MediaItem]
    ) -> [MediaView] {
        let unplayedMovies = movies.filter { !$0.userData.played }.count
        let unplayedEpisodes = episodes.filter { !$0.userData.played }.count

        let movieView = MediaView(
            item: MediaItem(
                id: moviesLibraryId,
                name: "电影",
                type: .collectionFolder,
                serverId: serverId,
                overview: "演示库中的 \(movies.count) 部电影，含科幻、剧情、动画与华语佳作。",
                imageTags: [.primary: imageTag("view:movies")],
                backdropTags: [imageTag("view:movies:backdrop")],
                userData: UserItemData(
                    playbackPosition: .zero,
                    playCount: 0,
                    isFavorite: false,
                    played: false,
                    lastPlayedDate: nil,
                    unplayedItemCount: unplayedMovies
                ),
                childCount: movies.count,
                dateCreated: referenceDate.addingTimeInterval(-90 * 86_400),
                isFolder: true
            ),
            collectionType: .movies
        )

        let tvView = MediaView(
            item: MediaItem(
                id: tvShowsLibraryId,
                name: "剧集",
                type: .collectionFolder,
                serverId: serverId,
                overview: "演示库中的 \(series.count) 部剧，共 \(episodes.count) 集。",
                imageTags: [.primary: imageTag("view:tvshows")],
                backdropTags: [imageTag("view:tvshows:backdrop")],
                userData: UserItemData(
                    playbackPosition: .zero,
                    playCount: 0,
                    isFavorite: false,
                    played: false,
                    lastPlayedDate: nil,
                    unplayedItemCount: unplayedEpisodes
                ),
                childCount: series.count,
                dateCreated: referenceDate.addingTimeInterval(-88 * 86_400),
                isFolder: true
            ),
            collectionType: .tvShows
        )

        // `boxsets` 是 Emby 服务端的 `CollectionType` 取值之一（与 `movies` / `tvshows` 同级）。
        // ◐ 官方 Browsing-the-Library 文档列出的取值里没有逐条列出 `boxsets`，
        //   但 Emby 服务端的 `CollectionType` 常量确实包含它；
        //   验证方法：对真实服务器请求 `GET /Users/{id}/Views`，观察合集库的 `CollectionType` 字段。
        let collectionView = MediaView(
            item: MediaItem(
                id: collectionsLibraryId,
                name: "合集",
                type: .collectionFolder,
                serverId: serverId,
                overview: "按主题打包的 \(collections.count) 个套装。",
                imageTags: [.primary: imageTag("view:collections")],
                backdropTags: [imageTag("view:collections:backdrop")],
                userData: .empty,
                childCount: collections.count,
                dateCreated: referenceDate.addingTimeInterval(-86 * 86_400),
                isFolder: true
            ),
            collectionType: LibraryType(rawValue: "boxsets")
        )

        return [movieView, tvView, collectionView]
    }

    // MARK: - 条目构建

    /// 构建一部电影。
    ///
    /// - Parameters:
    ///   - spec: 数据规格。
    ///   - index: 在数组中的序号（用于错开入库时间）。
    /// - Returns: 电影条目。
    private static func makeMovie(_ spec: MovieSpec, index: Int) -> MediaItem {
        let id = stableID("movie:" + spec.originalTitle)
        let runtime = Ticks(seconds: Double(spec.runtimeMinutes) * 60)
        let userData = makeUserData(
            state: spec.watch,
            runtime: runtime,
            seed: id,
            daysAgo: spec.addedDaysAgo
        )
        return MediaItem(
            id: id,
            name: spec.title,
            type: .movie,
            serverId: serverId,
            productionYear: spec.year,
            runTime: runtime,
            overview: spec.overview,
            officialRating: spec.certificate,
            communityRating: spec.rating,
            genres: spec.genres,
            imageTags: [.primary: imageTag(id + ":primary")],
            backdropTags: [imageTag(id + ":backdrop")],
            userData: userData,
            originalTitle: spec.originalTitle,
            dateCreated: referenceDate.addingTimeInterval(-Double(spec.addedDaysAgo + index) * 86_400),
            premiereDate: premiereDate(year: spec.year, seed: id),
            isFolder: false
        )
    }

    /// 构建一部剧。
    ///
    /// - Parameters:
    ///   - spec: 数据规格。
    ///   - seriesID: 剧 id。
    ///   - episodes: 该剧的全部单集（用于统计）。
    ///   - index: 在数组中的序号。
    /// - Returns: 剧条目。
    private static func makeSeries(
        _ spec: SeriesSpec,
        seriesID: String,
        episodes: [MediaItem],
        index: Int
    ) -> MediaItem {
        let watched = episodes.filter(\.userData.played)
        let lastPlayed = watched.compactMap(\.userData.lastPlayedDate).max()
        return MediaItem(
            id: seriesID,
            name: spec.title,
            type: .series,
            serverId: serverId,
            productionYear: spec.year,
            runTime: episodes.first?.runTime,
            overview: spec.overview,
            officialRating: spec.certificate,
            communityRating: spec.rating,
            genres: spec.genres,
            imageTags: [.primary: imageTag(seriesID + ":primary")],
            backdropTags: [imageTag(seriesID + ":backdrop")],
            userData: UserItemData(
                playbackPosition: .zero,
                playCount: watched.count,
                isFavorite: index % 4 == 0,
                played: !episodes.isEmpty && watched.count == episodes.count,
                lastPlayedDate: lastPlayed,
                unplayedItemCount: episodes.count - watched.count
            ),
            childCount: episodes.count,
            originalTitle: spec.originalTitle,
            dateCreated: referenceDate.addingTimeInterval(-Double(spec.addedDaysAgo + index) * 86_400),
            premiereDate: premiereDate(year: spec.year, seed: seriesID),
            isFolder: true
        )
    }

    /// 构建一部剧的全部季。
    ///
    /// - Parameters:
    ///   - spec: 数据规格。
    ///   - seriesID: 剧 id。
    /// - Returns: 季数组（按季号升序）。
    private static func makeSeasons(_ spec: SeriesSpec, seriesID: String) -> [MediaItem] {
        spec.seasons.enumerated().map { seasonIndex, season in
            let seasonNumber = seasonIndex + 1
            let seasonID = stableID("season:\(seriesID):\(seasonNumber)")
            return MediaItem(
                id: seasonID,
                name: "第 \(seasonNumber) 季 · \(season.arc)",
                type: .season,
                serverId: serverId,
                productionYear: spec.year + seasonIndex,
                overview: "《\(spec.title)》第 \(seasonNumber) 季「\(season.arc)」，共 \(season.episodeTitles.count) 集。",
                officialRating: spec.certificate,
                communityRating: spec.rating,
                genres: spec.genres,
                imageTags: [.primary: imageTag(seasonID + ":primary")],
                backdropTags: [imageTag(seasonID + ":backdrop")],
                userData: .empty,
                seriesId: seriesID,
                indexNumber: seasonNumber,
                seriesName: spec.title,
                childCount: season.episodeTitles.count,
                dateCreated: referenceDate.addingTimeInterval(-Double(spec.addedDaysAgo + seasonIndex) * 86_400),
                isFolder: true
            )
        }
    }

    /// 构建一部剧的全部单集。
    ///
    /// 集名前缀规则：第 1 季直接用主题词，第 2 季起加季主题做前缀（`暗流·沉船`），
    /// 这样 148 集不会出现重名，也不用手写 148 个标题。
    ///
    /// - Parameters:
    ///   - spec: 数据规格。
    ///   - seriesID: 剧 id。
    /// - Returns: 单集数组（按季号 → 集号升序）。
    private static func makeEpisodes(_ spec: SeriesSpec, seriesID: String) -> [MediaItem] {
        var result: [MediaItem] = []
        for (seasonIndex, season) in spec.seasons.enumerated() {
            let seasonNumber = seasonIndex + 1
            let seasonID = stableID("season:\(seriesID):\(seasonNumber)")
            for (episodeIndex, theme) in season.episodeTitles.enumerated() {
                let episodeNumber = episodeIndex + 1
                let episodeID = stableID("episode:\(seriesID):\(seasonNumber):\(episodeNumber)")
                let name = seasonNumber == 1 ? theme : "\(season.arc)·\(theme)"
                let runtime = Ticks(seconds: Double(episodeRuntimeMinutes(seed: episodeID)) * 60)
                result.append(
                    MediaItem(
                        id: episodeID,
                        name: name,
                        type: .episode,
                        serverId: serverId,
                        productionYear: spec.year + seasonIndex,
                        runTime: runtime,
                        overview: episodeOverview(
                            seriesTitle: spec.title,
                            season: seasonNumber,
                            episode: episodeNumber,
                            arc: season.arc,
                            theme: theme,
                            seed: episodeID
                        ),
                        officialRating: spec.certificate,
                        communityRating: spec.rating,
                        genres: spec.genres,
                        imageTags: [.primary: imageTag(episodeID + ":primary")],
                        backdropTags: [imageTag(episodeID + ":backdrop")],
                        userData: episodeUserData(
                            spec: spec,
                            season: seasonNumber,
                            episode: episodeNumber,
                            runtime: runtime,
                            seed: episodeID
                        ),
                        seriesId: seriesID,
                        seasonId: seasonID,
                        indexNumber: episodeNumber,
                        parentIndexNumber: seasonNumber,
                        seriesName: spec.title,
                        dateCreated: referenceDate.addingTimeInterval(
                            -Double(spec.addedDaysAgo + seasonIndex) * 86_400
                                + Double(episodeIndex) * 3_600
                        ),
                        premiereDate: premiereDate(year: spec.year + seasonIndex, seed: episodeID),
                        isFolder: false
                    )
                )
            }
        }
        return result
    }

    /// 构建一个合集套装。
    ///
    /// - Parameters:
    ///   - spec: 合集定义。
    ///   - members: 成员条目。
    ///   - index: 序号。
    /// - Returns: 合集条目。
    private static func makeCollection(
        _ spec: (name: String, overview: String),
        members: [MediaItem],
        index: Int
    ) -> MediaItem {
        let id = stableID("collection:" + spec.name)
        let runtime = Ticks(
            seconds: members.compactMap(\.runTime?.seconds).reduce(0, +)
        )
        return MediaItem(
            id: id,
            name: spec.name,
            type: .boxSet,
            serverId: serverId,
            runTime: runtime,
            overview: spec.overview,
            genres: Array(Set(members.flatMap(\.genres))).sorted(),
            imageTags: [.primary: imageTag(id + ":primary")],
            backdropTags: [imageTag(id + ":backdrop")],
            userData: .empty,
            childCount: members.count,
            dateCreated: referenceDate.addingTimeInterval(-Double(60 + index * 5) * 86_400),
            isFolder: true
        )
    }

    // MARK: - 用户数据

    /// 按观看状态生成 `UserItemData`。
    ///
    /// - Parameters:
    ///   - state: 观看状态。
    ///   - runtime: 总时长。
    ///   - seed: 用于错开「上次播放时间」。
    ///   - daysAgo: 入库于几天前。
    /// - Returns: 用户数据。
    private static func makeUserData(
        state: WatchState,
        runtime: Ticks,
        seed: String,
        daysAgo: Int
    ) -> UserItemData {
        let hash = DemoArtwork.stableHash(seed)
        switch state {
        case .unwatched:
            return .empty
        case let .inProgress(progress):
            // 上次播放时间落在「入库之后、现在之前」，保证「继续观看」的排序有层次。
            let offsetHours = Double(hash % 48)
            return UserItemData(
                playbackPosition: Ticks(seconds: runtime.seconds * progress),
                playCount: 0,
                isFavorite: false,
                played: false,
                lastPlayedDate: referenceDate.addingTimeInterval(
                    -(offsetHours * 3_600 + Double(daysAgo) * 60)
                ),
                unplayedItemCount: nil
            )
        case .finished:
            return UserItemData(
                playbackPosition: .zero,
                playCount: Int(hash % 3) + 1,
                isFavorite: hash % 5 == 0,
                played: true,
                lastPlayedDate: referenceDate.addingTimeInterval(-Double(daysAgo) * 86_400),
                unplayedItemCount: nil
            )
        }
    }

    /// 生成单集的用户数据：前 `finishedEpisodes` 集已看完，`watching` 指向的那一集看到一半。
    ///
    /// - Parameters:
    ///   - spec: 剧集规格。
    ///   - season: 季号。
    ///   - episode: 集号。
    ///   - runtime: 该集时长。
    ///   - seed: 该集 id。
    /// - Returns: 用户数据。
    private static func episodeUserData(
        spec: SeriesSpec,
        season: Int,
        episode: Int,
        runtime: Ticks,
        seed: String
    ) -> UserItemData {
        // 把「第几集」折算成一个线性序号，便于和 finishedEpisodes 比较。
        var linearIndex = 0
        for (index, seasonSpec) in spec.seasons.enumerated() {
            if index + 1 < season {
                linearIndex += seasonSpec.episodeTitles.count
            } else {
                linearIndex += episode - 1
                break
            }
        }

        let hash = DemoArtwork.stableHash(seed)
        if linearIndex < spec.finishedEpisodes {
            return UserItemData(
                playbackPosition: .zero,
                playCount: 1,
                isFavorite: false,
                played: true,
                lastPlayedDate: referenceDate.addingTimeInterval(
                    -Double(spec.addedDaysAgo) * 86_400 - Double(linearIndex) * 3_600
                ),
                unplayedItemCount: nil
            )
        }

        if let watching = spec.watching,
           watching.season == season,
           watching.episode == episode {
            return UserItemData(
                playbackPosition: Ticks(seconds: runtime.seconds * watching.progress),
                playCount: 0,
                isFavorite: false,
                played: false,
                lastPlayedDate: referenceDate.addingTimeInterval(-Double(hash % 20) * 3_600),
                unplayedItemCount: nil
            )
        }

        return .empty
    }

    /// 生成演职员。
    ///
    /// - Parameters:
    ///   - director: 导演 / 主创。
    ///   - cast: 主演名单。
    ///   - seed: 条目 id（用于派生人物 id）。
    /// - Returns: 演职员数组。
    private static func makePeople(director: String, cast: [String]) -> [Person] {
        var result: [Person] = [
            Person(
                id: stableID("person:" + director),
                name: director,
                role: nil,
                type: "Director",
                primaryImageTag: imageTag("person:" + director)
            )
        ]
        for name in cast {
            result.append(
                Person(
                    id: stableID("person:" + name),
                    name: name,
                    role: nil,
                    type: "Actor",
                    primaryImageTag: imageTag("person:" + name)
                )
            )
        }
        return result
    }

    // MARK: - 详情补全

    /// 为条目构造媒体源（仅详情接口使用）。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 媒体源数组；不可播放的条目（合集 / 剧 / 季）返回空数组。
    private static func mediaSources(for item: MediaItem) -> [MediaSource] {
        guard item.type.isPlayable else { return [] }
        let sourceID = stableID("source:" + item.id)
        let runTime = item.runTime
        return [
            MediaSource(
                id: sourceID,
                name: item.name + " - 1080p",
                container: "mkv",
                runTime: runTime,
                bitrate: 8_000_000,
                size: Int64((runTime?.seconds ?? 0) * 1_000_000),
                isRemote: false,
                directStreamUrl: "/videos/\(item.id)/stream?Static=true&MediaSourceId=\(sourceID)&PlaySessionId=\(stableID("session:" + item.id))",
                transcodingUrl: nil,
                playSessionId: stableID("session:" + item.id),
                mediaStreams: [
                    MediaStream(
                        index: 0,
                        type: .video,
                        codec: "h264",
                        language: nil,
                        displayTitle: "1080p H.264",
                        isDefault: true,
                        height: 1080,
                        width: 1920,
                        videoRange: "SDR",
                        bitRate: 7_000_000,
                        profile: "High"
                    ),
                    MediaStream(
                        index: 1,
                        type: .audio,
                        codec: "aac",
                        language: "chi",
                        displayTitle: "国语 AAC 立体声 (默认)",
                        isDefault: true,
                        channels: 2,
                        displayLanguage: "国语",
                        channelLayout: "stereo",
                        sampleRate: 48_000,
                        bitRate: 192_000,
                        profile: "LC"
                    ),
                    MediaStream(
                        index: 2,
                        type: .subtitle,
                        codec: "subrip",
                        language: "chi",
                        displayTitle: "简体中文 (SRT)",
                        isDefault: false,
                        isTextSubtitleStream: true,
                        supportsExternalStream: true,
                        displayLanguage: "简体中文"
                    )
                ],
                supportsDirectPlay: true,
                supportsDirectStream: true,
                supportsTranscoding: true,
                videoType: "VideoFile",
                protocolName: "File",
                defaultAudioStreamIndex: 1,
                defaultSubtitleStreamIndex: -1
            )
        ]
    }

    // MARK: - 小工具

    /// 由年份与种子派生一个首播时间（当年 1-12 月之间的某一天）。
    ///
    /// - Parameters:
    ///   - year: 年份。
    ///   - seed: 种子。
    /// - Returns: 首播时间。
    private static func premiereDate(year: Int, seed: String) -> Date {
        let hash = DemoArtwork.stableHash(seed)
        let dayOfYear = Int(hash % 365)
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        let startOfYear = Calendar(identifier: .gregorian).date(from: components) ?? referenceDate
        return startOfYear.addingTimeInterval(Double(dayOfYear) * 86_400)
    }

    /// 由种子派生单集时长（40...59 分钟）。
    ///
    /// - Parameter seed: 单集 id。
    /// - Returns: 分钟数。
    private static func episodeRuntimeMinutes(seed: String) -> Int {
        40 + Int(DemoArtwork.stableHash(seed) % 20)
    }

    /// 生成单集简介。
    ///
    /// - Parameters:
    ///   - seriesTitle: 剧名。
    ///   - season: 季号。
    ///   - episode: 集号。
    ///   - arc: 季主题。
    ///   - theme: 集主题。
    ///   - seed: 单集 id。
    /// - Returns: 中文简介。
    private static func episodeOverview(
        seriesTitle: String,
        season: Int,
        episode: Int,
        arc: String,
        theme: String,
        seed: String
    ) -> String {
        let tails = [
            "所有线索都指向了同一个方向，但没有人愿意先说出口。",
            "这一集把上季留下的疑问翻了个面，答案反而更远了。",
            "平静的一天里埋着两处伏笔，第二处要等到最后五分钟才显形。",
            "有人做了一个无法收回的决定，关系从此再也回不到从前。",
            "叙事在两条时间线之间来回切换，直到最后一个镜头才对上。",
            "看似无关的插曲，其实补上了主角性格里最关键的一块。",
            "雨停之后，所有人都装作什么都没发生过。",
            "收尾留了一个不响的悬念，下一集才会听见回声。"
        ]
        let tail = tails[Int(DemoArtwork.stableHash(seed) % UInt64(tails.count))]
        return "《\(seriesTitle)》第 \(season) 季「\(arc)」第 \(episode) 集：\(theme)。\(tail)"
    }
}
