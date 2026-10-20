# Prism 本地化（中 / 英）

> 工单：T4.3 中英文本地化。本文件是**唯一事实来源**：key 清单、译文、每个替换点的位置与改法都在这里。
>
> **状态**：String Catalog 已落地并通过 SwiftPM 资源编译验证（见 §10）；**代码替换尚未执行**——
> 按工单要求，替换动作留给主管统一做，避免与并行代理冲突。

---

## 0. 交付物

| 文件 | 内容 | 状态 |
|---|---|---|
| `Sources/PrismUI/Resources/Localizable.xcstrings` | UI 文案 319 个 key（zh-Hans + en） | ✅ 新建 |
| `Sources/PrismCore/Resources/Localizable.xcstrings` | `EmbyError` 文案 11 个 key（zh-Hans + en） | ✅ 新建 |
| `Package.swift` | PrismCore target 加一行 `resources: [.process("Resources")]` | ✅ 只加这一行 |
| `docs/LOCALIZATION.md` | 本文件 | ✅ 新建 |
| 33 个 `.swift` 文件的替换 | 360 处，清单见 §7 | ⏳ 待执行 |

- PrismUI catalog：**319** 个 key
- PrismCore catalog：**11** 个 key
- 合计：**330** 个 key，每个都有 `zh-Hans` 与 `en` 两条 `state: translated` 译文（无空值）
- 替换点：**360** 处，分布在 **33** 个文件
- 含格式化占位符（`%@` / `%lld` / `%.1f` / 位置参数）的 key：**45** 个

---

## 1. 必须先决策的一件事：catalog 放在哪个 bundle

这不是风格问题，而是**能不能查到字符串**的问题。

`Text("key")`、`LocalizedStringKey("key")`、`String(localized: "key")` 默认都查 **`Bundle.main`**。
而 SwiftPM 会把 `Sources/PrismUI/Resources/` 编译进 **`Prism_PrismUI.bundle`**（实测路径：
`.build/debug/Prism_PrismUI.bundle/Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings`），
这个 bundle 挂在 `Bundle.module` 上，**不是** `Bundle.main`。

所以只有两条路：

### 路线 A：只放在 PrismUI / PrismCore 的包里

每次查找都必须显式传 `bundle: .module`：

```swift
Text("home.continueWatching", bundle: .module)
.help(Text("player.speedHint", bundle: .module))
String(localized: String.LocalizationValue("library.loadFailed"), bundle: .module)
```

**代价（很大）**：

- `LocalizedStringKey` **不携带 bundle**。凡是「返回 `LocalizedStringKey`」或「参数类型是 `LocalizedStringKey`」的地方
  （`StateViews.defaultTitle(for:)`、`StateEmptyView(title:message:actionTitle:)`、
  `ErrorStateView(retryTitle:)`、`PrismPrimaryButton(_:)`、`Section(_:)` ……）最终都会被 `Text(key)` 用 `Bundle.main` 解析，
  **查不到**。要把这些 API 的参数类型从 `LocalizedStringKey` 改成 `Text`，牵连 DesignSystem / AppShell 的一批调用点。
- `EmbyError.userMessage`（PrismCore）要逐个 case 加 `bundle: .module`，共 11 处。
- 以上两类文件正是**并行代理正在改的** `DesignSystem/` 与 `AppShell/`。

### 路线 B（推荐）：以 App 主 bundle 为准，包内保留同源副本

1. 把 `Sources/PrismUI/Resources/Localizable.xcstrings` 与 `Sources/PrismCore/Resources/Localizable.xcstrings`
   **各复制一份到 `App/`**（例如合并成一份 `App/Localizable.xcstrings`）。
   `project.yml` 的 `sources: - path: App` 会自动把它当资源收进 App target，**不需要改 `project.yml`**，
   只需跑一次 `./scripts/bootstrap.sh`（`xcodegen generate`）。
2. Xcode 会把它编译成 `Prism.app/Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings`，
   于是 **`Bundle.main` 就能查到**：
   - `Text("key")` / `LocalizedStringKey("key")` / `String(localized: "key")` 全部开箱可用；
   - `EmbyError.userMessage` **一行都不用改**（它现在的 `bundle` 默认就是 `.main`）；
   - DesignSystem 里那批 `LocalizedStringKey` API **一个都不用动**。
3. PrismUI / PrismCore 包内保留的那份副本继续服务 `swift build` / `swift test` / `#Preview`
   （这些场景没有 App bundle，只有 `Bundle.module`）。

**为什么推荐 B**：替换点仍然是 360 处，但每一处都只是「把中文字面量换成 key」这一个动作，
不牵动任何组件签名、不碰并行代理的文件、也不需要给 `EmbyError` 加参数。

**B 的唯一成本**：catalog 有两份物理副本，必须保证同步。建议加一个 CI 校验脚本
（后续工单，`scripts/check-localization.sh`）：两份 JSON 的 `strings` 键集合与取值必须完全相等，
否则构建失败。**在脚本落地之前，以本文件 §6 的 key 表为准，`Sources/PrismUI/Resources/` 下那份是母本。**

> ⚠️ 若主管坚持路线 A，§7 清单里的每一处写法都要再包一层 `bundle: .module`，
> 并额外完成「`LocalizedStringKey` → `Text`」的 API 改造（不在本清单范围内）。

---

## 2. key 命名规范

`<模块>.<语义>`，全小写，驼峰分段，**只用 ASCII**（不用中文 key，避免 Xcode 编辑器与 diff 的编码噪声）。

| 前缀 | 覆盖范围 | 例子 |
|---|---|---|
| `common.` | 跨模块复用的通用词（重试 / 取消 / 刷新 / 播放 / 设置） | `common.retry` |
| `nav.` `route.` | 侧边栏条目、窗口标题 | `nav.movies` `route.window.player` |
| `state.` | 三态视图（空 / 加载） | `state.empty.title` |
| `error.` | 错误标题与错误正文 | `error.timeout` `error.notFound.title` |
| `player.` `track.` | 播放器控制条、菜单、错误 | `player.speed` `track.subtitleDelay` |
| `language.` | 语言显示名 | `language.ja` |
| `home.` `library.` `detail.` `search.` | 各页面 | `library.filter.genre` |
| `server.` `navigation.` `appshell.` `commands.` | 服务器胶囊、导航状态、菜单命令 | `server.signOut` |
| `settings.tab.` | 设置分栏标题 | `settings.tab.playback` |
| `keyboard.` | 播放器键位说明（当前仅 `#Preview` 可见） | `keyboard.playPause` |

补充约定：

- **同一句中文只允许有一个 key**。「播放」在 8 个地方出现，全部指向 `common.play`；
  「该季暂无剧集」两处都指向 `detail.noEpisodes`。不要为了「以后可能不一样」而复制 key。
- **带参数的 key 用位置参数**（`%1$lld` / `%2$@`），否则英文语序一变就错位。
  已按此处理的有 `home.episode.marker`、`home.remaining.hoursMinutes`、`search.resultCount`、
  `server.name.role`、`error.server.withMessage`、`library.count.summary`。
- **`%%` 表示字面百分号**：`library.item.progress` 是 `已观看 %lld%%`（`String(format:)` 语义）。
- `comment` 字段只给翻译者看不出来的 key 写（约 40 个），说明参数含义或出现位置。

---

## 3. 翻译约定

- **英文**：动宾短语、句首大写、不加句号（按钮 / 标签 / 菜单）；完整句子（错误正文、空态说明）才用句号。
- **中文**：保持现有硬编码文案**一字不改**——catalog 里的 `zh-Hans` 值就是当前代码里的字面量，
  这样替换后中文界面零回归。`「」` 与 `…` 也原样保留。
- **术语**：

  | 中文 | English |
  |---|---|
  | 媒体库 | library |
  | 剧集（整部剧） | TV show / series |
  | 单集 | episode |
  | 季 | season |
  | 演职员 | Cast & Crew |
  | 音轨 | audio track |
  | 字幕 | subtitles |
  | 直通 | passthrough |
  | 标记为已看 | mark as watched |

- **不要翻译**：`Emby`、`Finder`、`macOS`、`ASS`、`mpv`、`HDR`、`4K`、`SDR`。
- **快捷键符号保留原样**：`⌘` `⌥` `⇧` `←` `→` `↑` `↓` `↵` `Esc`。英文写成 `Play (Space)`、`Back (Esc)`，
  组合键写成 `Previous episode (⌘←)`（符号跨语言通用，不译）。

---

## 4. 五种替换模式

以下按**路线 B** 书写（不传 `bundle:`）。走路线 A 时，每个 `Text(...)` 都要补 `bundle: .module`。

### 4.1 视图里的字面量

```swift
// 前
Text("最近搜索")
Button("重试") { … }
Label("刷新", systemImage: "arrow.clockwise")
// 后
Text("search.recent.title")
Button("common.retry") { … }
Label("common.refresh", systemImage: "arrow.clockwise")
```

`Text` / `Button` / `Label` / `Section` / `ProgressView` 的 `LocalizedStringKey` 重载都吃 key，直接换字符串即可。

### 4.2 修饰符

```swift
.help("player.speedHint")                       // .help(_: LocalizedStringKey)
.accessibilityLabel("common.more")              // .accessibilityLabel(_: LocalizedStringKey)
.accessibilityHint("detail.episode.playHint")
```

若某个重载编译器不接受（不同 SDK 版本有差异），退化成 `Text("key")`：
`.help(Text("player.speedHint"))`。

### 4.3 返回 `String` 的计算属性 / 枚举

```swift
// 前
case .resume: "继续观看"
// 后
case .resume: String(localized: "home.continueWatching")
```

`Route.title`、`SortOption.title`、`NavigationModel.status.title`、`CastRow` 的职务名、
`ServerPill.roleDescription` 都是这个模式。

> 这类 `String` **在调用时才求值**（每次 body 重算都会重新查表），因此语言切换后能立刻跟上；
> 但一旦被存进 `@State` 或缓存，就不会再更新（见 §5）。

### 4.4 带插值 / 格式化

```swift
// 前
Text("全部 \(items.count) 项")
// 后
Text(String(format: String(localized: "home.allItems"), items.count))

// 前
let marker = "第 \(season) 季 第 \(episode) 集"
// 后
let marker = String(format: String(localized: "home.episode.marker"), season, episode)

// 前
String(format: "%.1f 分", rating)
// 后
String(format: String(localized: "library.item.rating"), rating)
```

> 语义 key 不能像 `LocalizedStringKey` 那样靠插值自动生成占位符，必须显式 `String(format:)`。
> 参数顺序按 catalog 里的位置参数写死（`%1$` `%2$`），不要依赖参数出现顺序。

### 4.5 自定义组件的标题参数

```swift
// 前
StateEmptyView(title: "这个媒体库还是空的", message: "…", actionTitle: "刷新") { … }
// 后
StateEmptyView(title: "library.empty.title", message: "library.empty.message", actionTitle: "common.refresh") { … }
```

参数类型已经是 `LocalizedStringKey`，直接传 key 字符串即可（**路线 B 下**成立；
路线 A 下这些组件的签名必须改成 `Text`）。

### 4.6 语言名映射表（`TrackMenu.swift:164-179`）——特殊处理

现在是 `static let` 字典，值在**类型初始化时**求值一次，之后永远不变。
替换时要把它从常量表改成按需求值：

```swift
// 前
private static let names: [String: String] = ["zh": "中文", …]
// 后
private static func localizedName(for code: String) -> String? {
    let key: String
    switch code {
    case "zh", "zho", "chi": key = "language.zh"
    case "zh-cn", "zh-hans": key = "language.zhHans"
    …
    default: return nil
    }
    return String(localized: String.LocalizationValue(key))
}
```

（`language.*` 共 17 个 key；`zh-hans`/`zh-cn` 共用 `language.zhHans`，`zh-tw`/`zh-hant` 共用 `language.zhHant`。）

---

## 5. 语言切换机制与已知限制

### 5.1 现状

`AppSettings.language: AppLanguage`（`.system` / `.zhHans` / `.en`）**已经存在并持久化**，
`AppLanguage.locale` 也已经能给出 `Locale(identifier: "zh-Hans" | "en")`。

但**全仓没有任何地方把它注入 SwiftUI 环境**：

```bash
grep -rn 'environment(\.locale' Sources/ App/    # 无结果
```

也就是说：catalog 齐了，语言仍然**只跟随系统**。设置页里那个「语言」选择器目前是空转的。

### 5.2 接线方案（后续工单）

```swift
// RootView（或 AppShellView）最外层
.environment(\.locale, settings.language.locale ?? Locale.automatic)
```

- `\.locale` 会影响 `Text(LocalizedStringKey)` 与 `String(localized:locale:)` 的解析语言，
  但**必须让视图重新求值**才会生效。
- 想让「切换即生效」100% 可靠，最稳的做法是给根视图挂 `.id(settings.language)` 强制重建。
  代价是当前导航栈会被重置（可以接受：回到首页），但语言切换本身就是低频操作。

### 5.3 已知限制（v1.0 建议直接告诉用户「重启后生效」）

| 限制 | 原因 | 缓解 |
|---|---|---|
| 切换语言后部分文案不更新 | 已经算好的 `String`（存进 `@State`、缓存、`static let`）不会重新查表 | 提示重启，或 `.id(settings.language)` 重建根视图 |
| `EmbyError.userMessage` 可能不跟随 `.environment(\.locale)` | `LocalizedStringResource.locale` 默认取 `.current`（进程级），与 SwiftUI 环境 locale 的关系**本工单未验证** | 若实测不跟随，改成 `String(localized:locale:)`；或接受「错误文案跟随系统语言」 |
| 非中英系统落到英文 | catalog 的 `sourceLanguage = zh-Hans`，但 SwiftPM 产出的 bundle `CFBundleDevelopmentRegion = en` | 路线 B 下由 App 的 `Info.plist` 决定，见下 |
| `CFBundleDevelopmentRegion` 是 `zh_CN`（旧标识） | `App/Info.plist:5-6` 写的是 `zh_CN`，而 catalog 的 `sourceLanguage` 是 `zh-Hans` | 建议改成 `zh-Hans`，或补 `CFBundleLocalizations = [zh-Hans, en]`；否则「没有匹配语言时回退到哪个 lproj」的行为不可预测 |
| 单测 / `swift run` 里没有 App bundle | 路线 B 的文案在 App bundle 里 | 保留 `Sources/PrismUI/Resources/` 那份同源副本，并在测试里显式传 `bundle: .module` |
| `#Preview` 里的假数据仍是中文 | 属于设计稿，不本地化 | 不影响发布 |

---

## 6. 完整 key 对照表

### 6.1 PrismUI（319 个）

`位置` 列是**建议替换点**（`文件:行号`，相对仓库根，已省略 `Sources/PrismUI/` 前缀）。

| key | 中文 | English | 位置 |
|---|---|---|---|
| `appshell.back` | 返回（⌘[） | Back (⌘[) | PrismUI/AppShell/AppShellView.swift:128 |
| `appshell.detailColumn.hide` | 隐藏详情栏 | Hide details | PrismUI/AppShell/AppShellView.swift:139<br>PrismUI/AppShell/AppShellView.swift:140<br>PrismUI/AppShell/Commands.swift:129 |
| `appshell.detailColumn.show` | 显示详情栏 | Show details | PrismUI/AppShell/AppShellView.swift:139<br>PrismUI/AppShell/AppShellView.swift:140<br>PrismUI/AppShell/Commands.swift:129 |
| `appshell.searchPrompt` | 搜索影片、剧集、演员 | Search movies, shows, and people | PrismUI/AppShell/AppShellView.swift:66 |
| `commands.addServer` | 添加服务器… | Add Server… | PrismUI/AppShell/Commands.swift:82 |
| `commands.addServer.disabled` | 添加服务器流程由连接向导接入后启用 | Available once the connection wizard is wired up | PrismUI/AppShell/Commands.swift:86 |
| `commands.switchServer` | 切换服务器… | Switch Server… | PrismUI/AppShell/Commands.swift:76 |
| `commands.toggleSidebar.hide` | 隐藏边栏 | Hide Sidebar | PrismUI/AppShell/Commands.swift:123 |
| `commands.toggleSidebar.show` | 显示边栏 | Show Sidebar | PrismUI/AppShell/Commands.swift:123 |
| `common.back` | 返回 | Back | PrismUI/AppShell/AppShellView.swift:129<br>PrismUI/AppShell/Commands.swift:119<br>PrismUI/Player/PlayerView.swift:372 |
| `common.cancel` | 取消 | Cancel | PrismUI/AppShell/ServerPill.swift:51<br>PrismUI/Player/PlayerView.swift:284 |
| `common.clearAll` | 清除全部 | Clear All | PrismUI/Library/FilterBar.swift:120<br>PrismUI/Library/FilterBar.swift:515<br>PrismUI/Search/RecentSearchesView.swift:133 |
| `common.close` | 关闭 | Close | PrismUI/Detail/MovieDetailView.swift:412<br>PrismUI/Library/LibraryView.swift:233 |
| `common.collapse` | 收起 | Show less | PrismUI/Detail/MovieDetailView.swift:326<br>PrismUI/Home/HomeView.swift:381<br>PrismUI/Home/HomeView.swift:390 |
| `common.done` | 完成 | Done | PrismUI/Library/FilterBar.swift:526 |
| `common.expand` | 展开 | Show more | PrismUI/Detail/MovieDetailView.swift:326 |
| `common.itemCount` | %lld 项 | %lld items | PrismUI/Home/HomeSections.swift:519<br>PrismUI/Search/SearchView.swift:509 |
| `common.more` | 更多 | More | PrismUI/Detail/MovieDetailView.swift:176<br>PrismUI/Detail/MovieDetailView.swift:177 |
| `common.play` | 播放 | Play | PrismUI/DesignSystem/PosterCard.swift:191<br>PrismUI/Home/HomeSections.swift:390<br>PrismUI/Library/LibraryGridView.swift:266<br>PrismUI/Library/LibraryGridView.swift:505<br>PrismUI/Library/LibraryGridView.swift:506 |
| `common.refresh` | 刷新 | Refresh | PrismUI/Home/HomeView.swift:110<br>PrismUI/Home/HomeView.swift:143<br>PrismUI/Library/LibraryView.swift:191 |
| `common.retry` | 重试 | Retry | PrismUI/DesignSystem/StateViews.swift:95<br>PrismUI/Detail/DetailScreen.swift:60<br>PrismUI/Home/HomeView.swift:324<br>PrismUI/Library/LibraryView.swift:216<br>PrismUI/Player/PlayerView.swift:376 |
| `common.settings` | 设置 | Settings | PrismUI/AppShell/Route.swift:97<br>PrismUI/AppShell/SidebarView.swift:194 |
| `common.settingsMenu` | 设置… | Settings… | PrismUI/AppShell/Commands.swift:65<br>PrismUI/AppShell/ServerPill.swift:153 |
| `common.settingsShortcut` | 设置（⌘,） | Settings (⌘,) | PrismUI/AppShell/SidebarView.swift:225 |
| `common.versionBadge` | 版本 %@ | Version %@ | PrismUI/AppShell/ServerPill.swift:368<br>PrismUI/AppShell/SidebarView.swift:134 |
| `detail.cast.role.composer` | 作曲 | Composer | PrismUI/Detail/CastRow.swift:146 |
| `detail.cast.role.director` | 导演 | Director | PrismUI/Detail/CastRow.swift:143 |
| `detail.cast.role.producer` | 制片 | Producer | PrismUI/Detail/CastRow.swift:145 |
| `detail.cast.role.writer` | 编剧 | Writer | PrismUI/Detail/CastRow.swift:144 |
| `detail.collapseA11y` | 收起简介 | Hide synopsis | PrismUI/Detail/MovieDetailView.swift:332 |
| `detail.continueWatching` | 继续观看 | Continue watching | PrismUI/Detail/EpisodeRow.swift:197<br>PrismUI/Detail/MovieDetailView.swift:198 |
| `detail.continueWatching.code` | 继续观看 %@ | Continue watching %@ | PrismUI/Detail/MovieDetailView.swift:196 |
| `detail.copyTitle` | 复制标题 | Copy title | PrismUI/Detail/MovieDetailView.swift:159 |
| `detail.episode.nextUp` | 接下来观看 | Next up | PrismUI/Detail/EpisodeRow.swift:229 |
| `detail.episode.notAired` | 未播出 | Not aired yet | PrismUI/Detail/EpisodeRow.swift:123 |
| `detail.episode.notAiredHint` | 该集尚未播出 | This episode hasn't aired yet | PrismUI/Detail/EpisodeRow.swift:72 |
| `detail.episode.playHint` | 播放这一集 | Play this episode | PrismUI/Detail/EpisodeRow.swift:72 |
| `detail.episode.played` | 已看完 | Watched | PrismUI/Detail/EpisodeRow.swift:228 |
| `detail.episodeCount` | 共 %lld 集 | %lld episodes | PrismUI/Detail/SeriesDetailView.swift:226 |
| `detail.expandA11y` | 展开简介 | Show synopsis | PrismUI/Detail/MovieDetailView.swift:332 |
| `detail.favorite` | 收藏 | Favorite | PrismUI/Detail/MovieDetailView.swift:152 |
| `detail.favorited` | 已收藏 | Favorited | PrismUI/Detail/MovieDetailView.swift:152 |
| `detail.loading` | 正在加载详情 | Loading details | PrismUI/Detail/DetailPlaceholder.swift:56 |
| `detail.markWatched` | 标记已看 | Mark as watched | PrismUI/Detail/MovieDetailView.swift:144 |
| `detail.noEpisodes` | 该季暂无剧集 | No episodes in this season | PrismUI/Detail/MovieDetailView.swift:209<br>PrismUI/Detail/SeriesDetailView.swift:273 |
| `detail.notFound.message` | 它可能已从服务器上移除。 | It may have been removed from the server. | PrismUI/Detail/DetailScreen.swift:59 |
| `detail.notFound.title` | 找不到这个条目 | This item wasn't found | PrismUI/Detail/DetailScreen.swift:58 |
| `detail.play` | 播放 | Play | PrismUI/Detail/MovieDetailView.swift:189 |
| `detail.refresh` | 刷新详情 | Refresh details | PrismUI/Detail/MovieDetailView.swift:162 |
| `detail.replay` | 重新播放 | Play again | PrismUI/Detail/MovieDetailView.swift:193 |
| `detail.replay.code` | 重新观看 %@ | Watch %@ again | PrismUI/Detail/MovieDetailView.swift:201 |
| `detail.replay.plain` | 重新观看 | Watch again | PrismUI/Detail/MovieDetailView.swift:203 |
| `detail.resumeFrom` | 从 %@ 继续 | Resume from %@ | PrismUI/Detail/MovieDetailView.swift:191 |
| `detail.season.picker` | 季选择 | Season picker | PrismUI/Detail/SeasonPicker.swift:91 |
| `detail.section.cast` | 演职员 | Cast & Crew | PrismUI/Detail/MovieDetailView.swift:81<br>PrismUI/Detail/SeriesDetailView.swift:111 |
| `detail.section.similar` | 相似推荐 | More Like This | PrismUI/Detail/MovieDetailView.swift:89<br>PrismUI/Detail/SeriesDetailView.swift:119 |
| `detail.tab.episodes` | 剧集 | Episodes | PrismUI/Detail/SeriesDetailView.swift:78 |
| `detail.watched` | 已看 | Watched | PrismUI/Detail/MovieDetailView.swift:144 |
| `detail.watchedCount` | 已看 %lld 集 | %lld watched | PrismUI/Detail/SeriesDetailView.swift:227 |
| `error.cancelled.title` | 操作已取消 | Cancelled | PrismUI/DesignSystem/StateViews.swift:178 |
| `error.decoding.title` | 无法读取服务器数据 | Unreadable server data | PrismUI/DesignSystem/StateViews.swift:174 |
| `error.forbidden.title` | 没有访问权限 | No permission | PrismUI/DesignSystem/StateViews.swift:168 |
| `error.invalidURL.title` | 服务器地址无效 | Invalid server address | PrismUI/DesignSystem/StateViews.swift:164 |
| `error.notFound.title` | 找不到内容 | Not found | PrismUI/DesignSystem/StateViews.swift:170 |
| `error.server.title` | 服务器出错了 | Server error | PrismUI/DesignSystem/StateViews.swift:176 |
| `error.serverUnreachable.title` | 无法连接到服务器 | Can't reach the server | PrismUI/DesignSystem/StateViews.swift:172 |
| `error.unauthorized.title` | 登录已失效 | Session expired | PrismUI/DesignSystem/StateViews.swift:166 |
| `error.unknown.title` | 出了点问题 | Something went wrong | PrismUI/DesignSystem/StateViews.swift:180 |
| `home.allItems` | 全部 %lld 项 | All %lld items | PrismUI/Home/HomeView.swift:373 |
| `home.continueWatching` | 继续观看 | Continue Watching | PrismUI/Home/HomeViewModel.swift:27 |
| `home.empty.message` | 服务器上还没有媒体，或还没有观看记录。在 Emby 中添加媒体库后刷新即可。 | There is no media on the server yet, or nothing has been watched. Add a library in Emby, then refresh. | PrismUI/Home/HomeView.swift:142 |
| `home.episode.badge` | 下一集 | Next | PrismUI/Home/HomeSections.swift:240 |
| `home.episode.marker` | 第 %1$lld 季 第 %2$lld 集 | S%1$lld E%2$lld | PrismUI/Home/ContinueWatchingCard.swift:229<br>PrismUI/Home/HomeSections.swift:277 |
| `home.latest` | 最新添加 | Recently Added | PrismUI/Home/HomeViewModel.swift:29 |
| `home.libraries` | 媒体库 | Media Libraries | PrismUI/Home/HomeSections.swift:450<br>PrismUI/Home/HomeViewModel.swift:30 |
| `home.loadFailed` | 首页数据加载失败 | Failed to load home data | PrismUI/Home/HomeViewModel.swift:360 |
| `home.nextUp` | 接下来 | Next Up | PrismUI/Home/HomeViewModel.swift:28 |
| `home.partialFailure` | 部分内容加载失败 | Some sections failed to load | PrismUI/Home/HomeViewModel.swift:184 |
| `home.partialFailure.named` | %@加载失败 | %@ failed to load | PrismUI/Home/HomeViewModel.swift:185 |
| `home.refreshA11y` | 刷新首页 | Refresh home | PrismUI/Home/HomeView.swift:114 |
| `home.refreshHelp` | 刷新（⌘R） | Refresh (⌘R) | PrismUI/Home/HomeView.swift:113 |
| `home.refreshing` | 正在刷新首页 | Refreshing home | PrismUI/Home/HomeView.swift:104<br>PrismUI/Home/HomeView.swift:105 |
| `home.remaining.hours` | 剩余 %lld 小时 | %lld hr left | PrismUI/Home/ContinueWatchingCard.swift:254 |
| `home.remaining.hoursMinutes` | 剩余 %1$lld 小时 %2$lld 分钟 | %1$lld hr %2$lld min left | PrismUI/Home/ContinueWatchingCard.swift:254 |
| `home.remaining.lessThanMinute` | 剩余不到 1 分钟 | Less than a minute left | PrismUI/Home/ContinueWatchingCard.swift:246 |
| `home.remaining.minutes` | 剩余 %lld 分钟 | %lld min left | PrismUI/Home/ContinueWatchingCard.swift:256 |
| `home.resumeA11y` | 继续播放 | Resume playback | PrismUI/Home/ContinueWatchingCard.swift:173 |
| `home.viewAll` | 查看全部 | View All | PrismUI/Home/HomeSections.swift:100<br>PrismUI/Home/HomeSections.swift:111<br>PrismUI/Home/HomeSections.swift:112 |
| `keyboard.cycleAudio` | 循环切换音轨 | Cycle audio tracks | PrismUI/Player/KeyboardController.swift:225 |
| `keyboard.exitAndClose` | 退出全屏 → 关闭播放器 | Exit full screen → close the player | PrismUI/Player/KeyboardController.swift:223 |
| `keyboard.fixed` | 固定 | Fixed | PrismUI/Player/KeyboardController.swift:433 |
| `keyboard.fullScreen` | 进入 / 退出全屏 | Enter / exit full screen | PrismUI/Player/KeyboardController.swift:222 |
| `keyboard.jump` | 跳转到 0% – 90% | Jump to 0% – 90% | PrismUI/Player/KeyboardController.swift:229 |
| `keyboard.mute` | 静音 | Mute | PrismUI/Player/KeyboardController.swift:221 |
| `keyboard.playPause` | 播放 / 暂停 | Play / Pause | PrismUI/Player/KeyboardController.swift:215 |
| `keyboard.prevNextEpisode` | 上一集 / 下一集 | Previous / next episode | PrismUI/Player/KeyboardController.swift:230 |
| `keyboard.seek10` | 后退 / 前进 10 秒 | Back / forward 10 seconds | PrismUI/Player/KeyboardController.swift:218 |
| `keyboard.seek30` | 后退 / 前进 30 秒 | Back / forward 30 seconds | PrismUI/Player/KeyboardController.swift:217 |
| `keyboard.seek5` | 后退 / 前进 5 秒 | Back / forward 5 seconds | PrismUI/Player/KeyboardController.swift:216 |
| `keyboard.speed` | 加速 / 减速 0.25× | Speed up / slow down 0.25× | PrismUI/Player/KeyboardController.swift:231 |
| `keyboard.speedMpv` | 加速 / 减速 0.25×（mpv 习惯） | Speed up / slow down 0.25× (mpv style) | PrismUI/Player/KeyboardController.swift:232 |
| `keyboard.subtitleDelay` | 字幕延迟 ∓0.1 秒 | Subtitle delay ∓0.1 s | PrismUI/Player/KeyboardController.swift:226 |
| `keyboard.subtitleDelayMpv` | 字幕延迟 ∓0.1 秒（mpv 习惯） | Subtitle delay ∓0.1 s (mpv style) | PrismUI/Player/KeyboardController.swift:227 |
| `keyboard.subtitleDelayReset` | 字幕延迟归零 | Reset subtitle delay to zero | PrismUI/Player/KeyboardController.swift:228 |
| `keyboard.subtitlesToggle` | 字幕显示 / 隐藏 | Show / hide subtitles | PrismUI/Player/KeyboardController.swift:224 |
| `keyboard.volume1` | 音量 ±1% | Volume ±1% | PrismUI/Player/KeyboardController.swift:220 |
| `keyboard.volume5` | 音量 ±5% | Volume ±5% | PrismUI/Player/KeyboardController.swift:219 |
| `language.ar` | 阿拉伯语 | Arabic | PrismUI/Player/TrackMenu.swift:178 |
| `language.de` | 德语 | German | PrismUI/Player/TrackMenu.swift:171 |
| `language.en` | 英语 | English | PrismUI/Player/TrackMenu.swift:167 |
| `language.es` | 西班牙语 | Spanish | PrismUI/Player/TrackMenu.swift:172 |
| `language.fr` | 法语 | French | PrismUI/Player/TrackMenu.swift:170 |
| `language.hi` | 印地语 | Hindi | PrismUI/Player/TrackMenu.swift:179 |
| `language.it` | 意大利语 | Italian | PrismUI/Player/TrackMenu.swift:173 |
| `language.ja` | 日语 | Japanese | PrismUI/Player/TrackMenu.swift:168 |
| `language.ko` | 韩语 | Korean | PrismUI/Player/TrackMenu.swift:169 |
| `language.pt` | 葡萄牙语 | Portuguese | PrismUI/Player/TrackMenu.swift:175 |
| `language.ru` | 俄语 | Russian | PrismUI/Player/TrackMenu.swift:174 |
| `language.th` | 泰语 | Thai | PrismUI/Player/TrackMenu.swift:176 |
| `language.vi` | 越南语 | Vietnamese | PrismUI/Player/TrackMenu.swift:177 |
| `language.yue` | 粤语 | Cantonese | PrismUI/Player/TrackMenu.swift:166 |
| `language.zh` | 中文 | Chinese | PrismUI/Player/TrackMenu.swift:164 |
| `language.zhHans` | 中文（简） | Chinese (Simplified) | PrismUI/Player/TrackMenu.swift:164<br>PrismUI/Player/TrackMenu.swift:165 |
| `language.zhHant` | 中文（繁） | Chinese (Traditional) | PrismUI/Player/TrackMenu.swift:165 |
| `library.allLoaded` | 已全部加载 | All items loaded | PrismUI/Library/LibraryGridView.swift:253<br>PrismUI/Library/LibraryGridView.swift:258 |
| `library.context.details` | 查看详情 | View details | PrismUI/Library/LibraryGridView.swift:281 |
| `library.context.favorite` | 收藏 | Add to favorites | PrismUI/Library/LibraryGridView.swift:277 |
| `library.context.markPlayed` | 标记为已看 | Mark as watched | PrismUI/Library/LibraryGridView.swift:273 |
| `library.context.markUnplayed` | 标记为未看 | Mark as unwatched | PrismUI/Library/LibraryGridView.swift:275 |
| `library.context.resume` | 从上次位置继续 | Resume from where you left off | PrismUI/Library/LibraryGridView.swift:268 |
| `library.context.showInFinder` | 在 Finder 中显示 | Show in Finder | PrismUI/Library/LibraryGridView.swift:282 |
| `library.context.showInFinderUnavailable` | v1.1 提供（需要服务端返回文件路径） | Available in v1.1 (requires the server to return a file path) | PrismUI/Library/LibraryGridView.swift:284 |
| `library.context.unfavorite` | 取消收藏 | Remove from favorites | PrismUI/Library/LibraryGridView.swift:277 |
| `library.count.summary` | 共 %1$lld %2$@ | %1$lld %2$@ | PrismUI/Library/FilterBar.swift:111 |
| `library.count.unit` | 部 | titles | PrismUI/AppShell/AppShellView.swift:222<br>PrismUI/Library/FilterBar.swift:50<br>PrismUI/Library/LibraryView.swift:64 |
| `library.dismissError` | 关闭错误提示 | Dismiss error | PrismUI/Library/LibraryView.swift:234 |
| `library.empty.message` | 在 Emby 服务器中添加内容后，回到这里刷新即可。 | Add content on the Emby server, then come back and refresh. | PrismUI/Library/LibraryView.swift:190 |
| `library.empty.title` | 这个媒体库还是空的 | This library is empty | PrismUI/Library/LibraryView.swift:189 |
| `library.filter.active` | 筛选（已启用 %lld 项） | Filter (%lld active) | PrismUI/Library/FilterBar.swift:252 |
| `library.filter.activeA11y` | 筛选，已启用 %lld 项 | Filter, %lld active | PrismUI/Library/FilterBar.swift:253 |
| `library.filter.anyRating` | 不限 | Any | PrismUI/Library/FilterBar.swift:507 |
| `library.filter.clearAll` | 清除全部筛选 | Clear all filters | PrismUI/Library/FilterBar.swift:128<br>PrismUI/Library/FilterBar.swift:522 |
| `library.filter.clearAllHelp` | 清除全部筛选条件 | Clear all filters | PrismUI/Library/FilterBar.swift:127 |
| `library.filter.genre` | 类型 | Genre | PrismUI/Library/FilterBar.swift:371 |
| `library.filter.genreEmpty` | 暂无可选类型：媒体库加载后会出现在这里。 | No genres yet. They appear here once the library loads. | PrismUI/Library/FilterBar.swift:374 |
| `library.filter.minRating` | 评分下限 | Minimum rating | PrismUI/Library/FilterBar.swift:483 |
| `library.filter.title` | 筛选 | Filter | PrismUI/Library/FilterBar.swift:252<br>PrismUI/Library/FilterBar.swift:253<br>PrismUI/Library/FilterBar.swift:319 |
| `library.filter.watchState` | 观看状态 | Watch status | PrismUI/Library/FilterBar.swift:349<br>PrismUI/Library/FilterBar.swift:352 |
| `library.filter.yearFrom` | 从 | From | PrismUI/Library/FilterBar.swift:442 |
| `library.filter.yearRange` | 年份范围 | Year range | PrismUI/Library/FilterBar.swift:427 |
| `library.filter.yearRangeLimit` | 限制年份范围 | Limit by year | PrismUI/Library/FilterBar.swift:430 |
| `library.filter.yearTo` | 到 | To | PrismUI/Library/FilterBar.swift:445 |
| `library.filteredEmpty.action` | 清除筛选 | Clear filters | PrismUI/Library/LibraryView.swift:181 |
| `library.filteredEmpty.message` | 试试放宽筛选条件，或清除全部筛选。 | Try loosening the filters, or clear them all. | PrismUI/Library/LibraryView.swift:180 |
| `library.filteredEmpty.title` | 没有符合条件的内容 | No matching items | PrismUI/Library/LibraryView.swift:179 |
| `library.grid.empty.message` | 换一个筛选条件，或刷新后重试。 | Try another filter, or refresh and try again. | PrismUI/Library/LibraryGridView.swift:119 |
| `library.grid.empty.title` | 没有可显示的内容 | Nothing to show | PrismUI/Library/LibraryGridView.swift:118 |
| `library.item.played` | 已观看 | Watched | PrismUI/Library/LibraryGridView.swift:538 |
| `library.item.progress` | 已观看 %lld%% | %lld%% watched | PrismUI/Library/LibraryGridView.swift:516 |
| `library.item.rating` | %.1f 分 | %.1f | PrismUI/Library/LibraryGridView.swift:537 |
| `library.item.unplayed` | 未观看 | Unwatched | PrismUI/Library/LibraryGridView.swift:538 |
| `library.item.unwatchedEpisodes` | %lld 集未看 | %lld episodes unwatched | PrismUI/DesignSystem/PosterCard.swift:249<br>PrismUI/Library/LibraryGridView.swift:529 |
| `library.item.watched` | 已看 | Watched | PrismUI/DesignSystem/PosterCard.swift:237<br>PrismUI/Library/LibraryGridView.swift:511 |
| `library.item.year` | %lld 年 | %lld | PrismUI/Library/LibraryGridView.swift:536 |
| `library.loadFailed` | 加载媒体库失败 | Couldn't load the library | PrismUI/Library/LibraryView.swift:161 |
| `library.loadingMore` | 正在加载更多… | Loading more… | PrismUI/Library/LibraryGridView.swift:241 |
| `library.loadingMoreA11y` | 正在加载更多 | Loading more | PrismUI/Library/LibraryGridView.swift:251 |
| `library.sort.help` | 排序：%@ | Sort: %@ | PrismUI/Library/FilterBar.swift:184<br>PrismUI/Library/FilterBar.swift:185 |
| `library.sort.rating` | 评分 | Rating | PrismUI/Library/SortOption.swift:51 |
| `library.sort.recentlyAdded` | 最近添加 | Recently Added | PrismUI/Library/SortOption.swift:48 |
| `library.sort.runtime` | 时长 | Duration | PrismUI/Library/SortOption.swift:52 |
| `library.sort.titleAscending` | 标题 A-Z | Title A-Z | PrismUI/Library/SortOption.swift:49 |
| `library.sort.year` | 年份 | Year | PrismUI/Library/SortOption.swift:50 |
| `library.watchState.all` | 全部 | All | PrismUI/Library/FilterSet.swift:48 |
| `library.watchState.unwatched` | 未看 | Unwatched | PrismUI/Library/FilterSet.swift:49 |
| `library.watchState.watched` | 已看 | Watched | PrismUI/Library/FilterSet.swift:50 |
| `nav.downloads` | 下载 | Downloads | PrismUI/AppShell/Route.swift:96 |
| `nav.home` | 首页 | Home | PrismUI/AppShell/Commands.swift:96<br>PrismUI/AppShell/Route.swift:92 |
| `nav.movies` | 电影 | Movies | PrismUI/AppShell/Commands.swift:100<br>PrismUI/AppShell/Route.swift:93 |
| `nav.search` | 搜索 | Search | PrismUI/AppShell/Commands.swift:108<br>PrismUI/AppShell/Route.swift:95 |
| `nav.section.media` | 媒体库 | Media | PrismUI/AppShell/SidebarView.swift:31 |
| `nav.section.tools` | 工具 | Tools | PrismUI/AppShell/SidebarView.swift:37 |
| `nav.series` | 剧集 | TV Shows | PrismUI/AppShell/Commands.swift:104<br>PrismUI/AppShell/Route.swift:94 |
| `nav.settings.a11y` | 设置，快捷键 ⌘, | Settings, shortcut ⌘, | PrismUI/AppShell/SidebarView.swift:226 |
| `nav.sidebar.item.shortcut` | %@，快捷键 %@ | %@, shortcut %@ | PrismUI/AppShell/SidebarView.swift:172 |
| `nav.sidebar.item.shortcutWithHint` | %@（%@） | %@ (%@) | PrismUI/AppShell/SidebarView.swift:164 |
| `nav.sidebar.item.unavailableShort` | %@，v1.1 提供 | %@, available in v1.1 | PrismUI/AppShell/SidebarView.swift:169 |
| `navigation.noServer` | 未连接服务器 | No server connected | PrismUI/AppShell/NavigationModel.swift:203 |
| `navigation.noUser` | 未登录 | Not signed in | PrismUI/AppShell/NavigationModel.swift:208 |
| `navigation.nowPlaying` | 正在播放 | Now Playing | PrismUI/AppShell/AppShellView.swift:60<br>PrismUI/DesignSystem/PosterCard.swift:323<br>PrismUI/DesignSystem/PosterCard.swift:336 |
| `navigation.status.connected` | 已连接 | Connected | PrismUI/AppShell/NavigationModel.swift:25 |
| `navigation.status.connecting` | 正在连接… | Connecting… | PrismUI/AppShell/NavigationModel.swift:26 |
| `navigation.status.offline` | 离线 | Offline | PrismUI/AppShell/NavigationModel.swift:28 |
| `navigation.status.unauthorized` | 需要重新登录 | Sign in again | PrismUI/AppShell/NavigationModel.swift:27 |
| `navigation.status.unsupported` | 服务器版本不受支持 | Unsupported server version | PrismUI/AppShell/NavigationModel.swift:29 |
| `player.a11y.player` | 播放器 | Player | PrismUI/Player/PlayerView.swift:162 |
| `player.audioTracksHint` | 音轨（A 循环切换） | Audio track (A cycles) | PrismUI/Player/PlayerControls.swift:302 |
| `player.backHint` | 返回（Esc） | Back (Esc) | PrismUI/Player/PlayerView.swift:213 |
| `player.buffering` | 正在缓冲… | Buffering… | PrismUI/Player/PlayerView.swift:306 |
| `player.bufferingA11y` | 正在缓冲 | Buffering | PrismUI/Player/PlayerView.swift:317 |
| `player.cancelPlayback` | 取消播放 | Cancel playback | PrismUI/Player/PlayerView.swift:289 |
| `player.cannotPlay` | 无法播放该文件 | This file can't be played | PrismUI/Player/PlayerView.swift:359<br>PrismUI/Player/PlayerView.swift:391 |
| `player.durationUnknown` | 时长未知 | Duration unknown | PrismUI/Player/ProgressSlider.swift:309 |
| `player.enterFullScreen` | 进入全屏（F） | Enter full screen (F) | PrismUI/Player/PlayerControls.swift:214 |
| `player.error.cancelled` | 播放已取消。 | Playback was cancelled. | PrismUI/Player/PlayerView.swift:522 |
| `player.error.decodeFailed` | 解码失败，文件可能已损坏。 | Decoding failed. The file may be corrupted. | PrismUI/Player/PlayerView.swift:520 |
| `player.error.disconnected` | 连接已中断，请检查网络后重试。 | The connection was interrupted. Check your network and try again. | PrismUI/Player/PlayerView.swift:516 |
| `player.error.noAccess` | 无法打开这个文件，可能是服务器拒绝或地址已失效。 | This file couldn't be opened. The server may have refused it, or the link has expired. | PrismUI/Player/PlayerView.swift:514 |
| `player.error.unknown` | 发生了未知错误，请重试或换个版本。 | An unknown error occurred. Try again or choose another version. | PrismUI/Player/PlayerView.swift:524 |
| `player.error.unsupported` | 这个文件用了不支持的编码或容器，换个版本试试。 | This file uses an unsupported codec or container. Try another version. | PrismUI/Player/PlayerView.swift:518 |
| `player.exitFullScreen` | 退出全屏（Esc） | Exit full screen (Esc) | PrismUI/Player/PlayerControls.swift:214 |
| `player.finished` | 播放结束 | Playback finished | PrismUI/Player/PlayerView.swift:328 |
| `player.mute` | 静音 | Mute | PrismUI/Player/PlayerControls.swift:239<br>PrismUI/Player/PlayerControls.swift:280 |
| `player.nextEpisode` | 下一集 | Next Episode | PrismUI/Player/PlayerView.swift:333 |
| `player.nextEpisodeHint` | 下一集（⌘→） | Next episode (⌘→) | PrismUI/Player/PlayerControls.swift:163 |
| `player.pauseHint` | 暂停（空格） | Pause (Space) | PrismUI/Player/PlayerControls.swift:153 |
| `player.pictureInPicture` | 画中画 | Picture in Picture | PrismUI/Player/PlayerControls.swift:204<br>PrismUI/Player/PlayerControls.swift:208 |
| `player.pictureInPictureUnavailable` | 当前引擎未暴露画中画接口 | The current engine does not expose Picture in Picture | PrismUI/Player/PlayerControls.swift:208 |
| `player.playHint` | 播放（空格） | Play (Space) | PrismUI/Player/PlayerControls.swift:153 |
| `player.playbackTime` | 播放时间 | Playback time | PrismUI/Player/PlayerControls.swift:188 |
| `player.preparing` | 正在准备播放… | Preparing playback… | PrismUI/Player/PlayerView.swift:280 |
| `player.preparingA11y` | 正在准备播放 | Preparing playback | PrismUI/Player/PlayerView.swift:297 |
| `player.previousEpisodeHint` | 上一集（⌘←） | Previous episode (⌘←) | PrismUI/Player/PlayerControls.swift:158 |
| `player.progress` | 播放进度 | Playback progress | PrismUI/Player/ProgressSlider.swift:174 |
| `player.speed` | 播放速度 | Playback speed | PrismUI/Player/PlayerControls.swift:361<br>PrismUI/Player/PlayerControls.swift:391 |
| `player.speedHint` | 播放速度（> / < 调整） | Playback speed (> / < adjusts) | PrismUI/Player/PlayerControls.swift:350 |
| `player.subtitlesHint` | 字幕（S 开关） | Subtitles (S toggles) | PrismUI/Player/PlayerControls.swift:323 |
| `player.timeWithUnknownDuration` | %@，总时长未知 | %@, duration unknown | PrismUI/Player/PlayerControls.swift:192 |
| `player.unmute` | 取消静音 | Unmute | PrismUI/Player/PlayerControls.swift:239<br>PrismUI/Player/PlayerControls.swift:280 |
| `player.volume` | 音量 | Volume | PrismUI/Player/PlayerControls.swift:295 |
| `player.volumeDown` | 音量 −5% | Volume −5% | PrismUI/Player/PlayerControls.swift:241 |
| `player.volumeHint` | 音量（M 静音） | Volume (press M to mute) | PrismUI/Player/PlayerControls.swift:231 |
| `player.volumeMutedHint` | 音量（已静音，M 取消静音） | Volume (muted, press M to unmute) | PrismUI/Player/PlayerControls.swift:231 |
| `player.volumeUp` | 音量 +5% | Volume +5% | PrismUI/Player/PlayerControls.swift:240 |
| `player.waitingForEngine` | 等待播放引擎… | Waiting for the playback engine… | PrismUI/Player/PlayerView.swift:178 |
| `root.preparingDemo` | 正在准备演示数据… | Preparing demo data… | PrismUI/RootView.swift:28 |
| `route.window.detail` | 详情 | Details | PrismUI/AppShell/Route.swift:184 |
| `route.window.downloads` | 下载 | Downloads | PrismUI/AppShell/Route.swift:182 |
| `route.window.home` | 首页 | Home | PrismUI/AppShell/Route.swift:174 |
| `route.window.library` | 媒体库 | Library | PrismUI/AppShell/Route.swift:179 |
| `route.window.movie` | 电影 | Movies | PrismUI/AppShell/Route.swift:177 |
| `route.window.player` | 正在播放 | Now Playing | PrismUI/AppShell/Route.swift:185 |
| `route.window.search` | 搜索 | Search | PrismUI/AppShell/Route.swift:181 |
| `route.window.series` | 剧集 | TV Shows | PrismUI/AppShell/Route.swift:178 |
| `search.clear` | 清除搜索 | Clear search | PrismUI/Search/SearchView.swift:421 |
| `search.empty.hint` | 在工具栏搜索框输入关键词，或按 ⌘F 聚焦搜索框。 | Type a keyword in the toolbar search field, or press ⌘F to focus it. | PrismUI/Search/SearchView.swift:171 |
| `search.failed` | 搜索失败 | Search failed | PrismUI/Search/SearchView.swift:447 |
| `search.hint.open` | 打开 | Open | PrismUI/Search/SearchView.swift:458 |
| `search.hint.play` | 播放 | Play | PrismUI/Search/SearchView.swift:459 |
| `search.hint.select` | 选择 | Select | PrismUI/Search/SearchView.swift:457 |
| `search.hintsA11y` | 键盘：上下键选择，回车打开，Command 加回车播放 | Keyboard: arrows to select, Return to open, Command-Return to play | PrismUI/Search/SearchView.swift:465 |
| `search.kind.episode` | 单集 | Episode | PrismUI/Search/SearchResultItem.swift:39 |
| `search.kind.movie` | 电影 | Movie | PrismUI/Search/SearchResultItem.swift:37 |
| `search.kind.person` | 人物 | Person | PrismUI/Search/SearchResultItem.swift:40 |
| `search.kind.series` | 剧集 | Series | PrismUI/Search/SearchResultItem.swift:38 |
| `search.minLength` | 至少输入 %lld 个字符 | Type at least %lld characters | PrismUI/Search/SearchView.swift:234 |
| `search.minLength.hint` | 再输入一些关键词，就能开始搜索。 | Add a few more characters to start searching. | PrismUI/Search/SearchView.swift:238 |
| `search.noResults` | 没有找到「%@」 | No results for “%@” | PrismUI/Search/SearchView.swift:409 |
| `search.placeholder` | 搜索电影、剧集、演员 | Search movies, shows, and people | PrismUI/Search/SearchView.swift:166 |
| `search.popular` | 热门推荐 | Popular | PrismUI/Search/SearchView.swift:190 |
| `search.popular.empty` | 热门推荐将在接入服务端统计后显示。 | Popular searches appear once server-side analytics is connected. | PrismUI/Search/SearchView.swift:193 |
| `search.recent.clearAllHelp` | 清除全部最近搜索 | Clear all recent searches | PrismUI/Search/RecentSearchesView.swift:142<br>PrismUI/Search/RecentSearchesView.swift:143 |
| `search.recent.clickToSearch` | 点击直接搜索 | Click to search | PrismUI/Search/RecentSearchesView.swift:96 |
| `search.recent.delete` | 从最近搜索中删除 | Remove from recent searches | PrismUI/Search/RecentSearchesView.swift:187 |
| `search.recent.deleteA11y` | 删除最近搜索 %@ | Remove %@ from recent searches | PrismUI/Search/RecentSearchesView.swift:188 |
| `search.recent.empty` | 还没有搜索记录。输入关键词后，最近搜过的内容会出现在这里。 | No searches yet. After you search, recent queries appear here. | PrismUI/Search/RecentSearchesView.swift:118 |
| `search.recent.title` | 最近搜索 | Recent Searches | PrismUI/Search/RecentSearchesView.swift:63<br>PrismUI/Search/RecentSearchesView.swift:75 |
| `search.resultCount` | 「%@」共 %2$lld 个结果 | %2$lld results for “%1$@” | PrismUI/Search/SearchView.swift:316 |
| `search.resultsA11y` | 搜索结果 | Search results | PrismUI/Search/SearchView.swift:311 |
| `search.searching` | 正在搜索「%@」… | Searching for “%@”… | PrismUI/Search/SearchView.swift:254 |
| `search.searchingA11y` | 正在搜索 | Searching | PrismUI/Search/SearchView.swift:263 |
| `search.section.episodes` | 单集 | Episodes | PrismUI/Search/SearchView.swift:359 |
| `search.section.movies` | 电影 | Movies | PrismUI/Search/SearchView.swift:273 |
| `search.section.people` | 人物 | People | PrismUI/Search/SearchView.swift:380 |
| `search.section.series` | 剧集 | TV Shows | PrismUI/Search/SearchView.swift:276 |
| `search.suggestion.actor` | 试试搜索演员名，例如「汤姆·汉克斯」 | Try searching an actor's name, such as “Tom Hanks” | PrismUI/Search/SearchView.swift:416 |
| `search.suggestion.library` | 确认该内容已经在 Emby 媒体库中 | Make sure the item is in your Emby library | PrismUI/Search/SearchView.swift:417 |
| `search.suggestion.spelling` | 检查拼写，或换一个更短的关键词 | Check the spelling, or try a shorter keyword | PrismUI/Search/SearchView.swift:415 |
| `search.term.help` | 搜索「%@」 | Search for “%@” | PrismUI/Search/RecentSearchesView.swift:172<br>PrismUI/Search/SearchView.swift:222 |
| `server.current` | 当前服务器 | Current server | PrismUI/AppShell/ServerPill.swift:367 |
| `server.menu.manage` | 管理服务器… | Manage servers… | PrismUI/AppShell/ServerPill.swift:228 |
| `server.name.role` | %1$@ · %2$@ | %1$@ · %2$@ | PrismUI/AppShell/ServerPill.swift:198 |
| `server.name.unauthenticated` | %@ · 未登录 | %@ · Not signed in | PrismUI/AppShell/ServerPill.swift:196 |
| `server.notConnected` | 尚未连接服务器 | No server connected | PrismUI/AppShell/ServerPill.swift:210 |
| `server.pill.a11y` | 当前服务器 %@，%@ | Current server %@, %@ | PrismUI/AppShell/ServerPill.swift:56 |
| `server.pill.help` | 服务器：%@（⌘⇧S） | Server: %@ (⌘⇧S) | PrismUI/AppShell/ServerPill.swift:55 |
| `server.role.admin` | 管理员 | Administrator | PrismUI/AppShell/ServerPill.swift:198 |
| `server.role.user` | 用户 | User | PrismUI/AppShell/ServerPill.swift:198 |
| `server.signOut` | 退出登录 | Sign out | PrismUI/AppShell/Commands.swift:88<br>PrismUI/AppShell/ServerPill.swift:48<br>PrismUI/AppShell/ServerPill.swift:159 |
| `server.signOut.message` | 将清除本机保存的登录信息，服务器上的数据不受影响。 | This clears the saved sign-in on this Mac. Data on the server is not affected. | PrismUI/AppShell/ServerPill.swift:53 |
| `server.signOut.title` | 退出登录？ | Sign out? | PrismUI/AppShell/ServerPill.swift:44 |
| `server.title` | 服务器 | Server | PrismUI/AppShell/ServerPill.swift:203 |
| `server.unavailable` | %@（v1.1 提供） | %@ (available in v1.1) | PrismUI/AppShell/ServerPill.swift:360 |
| `settings.tab.about` | 关于 | About | PrismUI/AppShell/Route.swift:153 |
| `settings.tab.appearance` | 外观 | Appearance | PrismUI/AppShell/Route.swift:151 |
| `settings.tab.network` | 网络 | Network | PrismUI/AppShell/Route.swift:150 |
| `settings.tab.playback` | 播放 | Playback | PrismUI/AppShell/Route.swift:148 |
| `settings.tab.servers` | 服务器 | Servers | PrismUI/AppShell/Route.swift:152 |
| `settings.tab.subtitles` | 字幕 | Subtitles | PrismUI/AppShell/Route.swift:149 |
| `state.empty.title` | 这里还什么都没有 | Nothing here yet | PrismUI/DesignSystem/StateViews.swift:38<br>PrismUI/Home/HomeView.swift:141 |
| `state.loading.a11y` | 正在加载 | Loading | PrismUI/DesignSystem/StateViews.swift:246<br>PrismUI/DesignSystem/StateViews.swift:263 |
| `track.assWarning` | 复杂 ASS 特效（淡入淡出、描边）可能丢失 | Complex ASS effects (fades, outlines) may be lost | PrismUI/Player/TrackMenu.swift:315 |
| `track.channels.count` | %lld 声道 | %lld channels | PrismUI/Player/TrackMenu.swift:124 |
| `track.channels.mono` | 单声道 | Mono | PrismUI/Player/TrackMenu.swift:119 |
| `track.channels.stereo` | 立体声 | Stereo | PrismUI/Player/TrackMenu.swift:120 |
| `track.default` | 默认 | Default | PrismUI/Player/TrackMenu.swift:226<br>PrismUI/Player/TrackMenu.swift:304 |
| `track.external` | 外挂 | External | PrismUI/Player/TrackMenu.swift:147 |
| `track.footer.passthrough` | 直通 · 引擎解码 | Passthrough · engine decode | PrismUI/Player/TrackMenu.swift:233 |
| `track.internal` | 内嵌 | Embedded | PrismUI/Player/TrackMenu.swift:147 |
| `track.language.unknown` | 未知语言 | Unknown language | PrismUI/Player/TrackMenu.swift:92 |
| `track.menu.audio` | 音轨 | Audio | PrismUI/Player/TrackMenu.swift:217 |
| `track.menu.audioEmpty` | 该视频只有一条音轨 | This video has only one audio track | PrismUI/Player/TrackMenu.swift:219 |
| `track.menu.subtitles` | 字幕 | Subtitles | PrismUI/Player/TrackMenu.swift:286 |
| `track.menu.subtitlesEmpty` | 该视频没有字幕 | This video has no subtitles | PrismUI/Player/TrackMenu.swift:296 |
| `track.menu.subtitlesOff` | 关闭字幕 | Subtitles off | PrismUI/Player/TrackMenu.swift:288 |
| `track.menu.subtitlesOffDetail` | 不显示任何字幕 | Show no subtitles | PrismUI/Player/TrackMenu.swift:289 |
| `track.subtitleDelay` | 字幕延迟 | Subtitle delay | PrismUI/Player/TrackMenu.swift:327 |
| `track.subtitleDelayReset` | 重置延迟 | Reset delay | PrismUI/Player/TrackMenu.swift:347 |
| `track.subtitleDelayResetA11y` | 重置字幕延迟 | Reset subtitle delay | PrismUI/Player/TrackMenu.swift:352 |

### 6.2 PrismCore（11 个）

这 11 个 key 由 `EmbyError.userMessage` 使用，**代码里已经有 key 与中文 `defaultValue`**，
只需 catalog 条目（已建）。路线 B 下**不需要改 `EmbyError.swift`**；路线 A 下每个 case 加 `bundle: .module`。

| key | 中文 | English | 位置 |
|---|---|---|---|
| `error.cancelled` | 操作已取消。 | The operation was cancelled. | `EmbyError.swift`（见 §6.2） |
| `error.decoding` | 服务器返回了无法识别的数据。 | The server returned data that could not be read. | `EmbyError.swift`（见 §6.2） |
| `error.forbidden` | 没有权限访问该内容。 | You do not have permission to access this content. | `EmbyError.swift`（见 §6.2） |
| `error.invalidURL` | 服务器地址无效。 | The server address is invalid. | `EmbyError.swift`（见 §6.2） |
| `error.notFound` | 找不到请求的内容。 | The requested content could not be found. | `EmbyError.swift`（见 §6.2） |
| `error.server` | 服务器出错了（%lld）。 | The server reported an error (%lld). | `EmbyError.swift`（见 §6.2） |
| `error.server.withMessage` | 服务器出错了（%1$lld）：%2$@ | The server reported an error (%1$lld): %2$@ | `EmbyError.swift`（见 §6.2） |
| `error.serverUnreachable` | 无法连接到服务器：%@ | Unable to reach the server: %@ | `EmbyError.swift`（见 §6.2） |
| `error.timeout` | 连接超时，请检查网络后重试。 | The connection timed out. Please try again. | `EmbyError.swift`（见 §6.2） |
| `error.unauthorized` | 登录已失效，请重新登录。 | Your session has expired. Please sign in again. | `EmbyError.swift`（见 §6.2） |
| `error.unknown` | 发生未知错误。 | An unknown error occurred. | `EmbyError.swift`（见 §6.2） |

---

## 7. 替换执行清单（按文件分组）

共 **360 处 / 33 个文件**。按优先级排序：**P0**（用户主路径，必做）→ **P1**（重要）→ **P2**（可后做）。

`形式` 列对应 §4 的模式：`Text` / `Button` / `Label` / `help` / `a11y` / `String` / `format` / `Key` / `init` / `C`。

> 行号是**当前 HEAD 的行号**。替换时请按「原文」列定位，不要只信行号——并行代理可能已经改动过文件。

#### `Sources/PrismUI/AppShell/ServerPill.swift`  ·  16 处 · P0

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 44 | .confirmationDialog("退出登录？") | `server.signOut.title` | init |
| 48 | Button("退出登录", role: .destructive) | `server.signOut` | Button |
| 51 | Button("取消", role: .cancel) | `common.cancel` | Button |
| 53 | Text("将清除本机保存的登录信息，服务器上的数据不受影响。") | `server.signOut.message` | Text |
| 55 | .help("服务器：\(model.currentServerName)（⌘⇧S）") | `server.pill.help` | help |
| 56 | .accessibilityLabel("当前服务器 \(...)，\(...)") | `server.pill.a11y` | a11y |
| 153 | ServerMenuRow(title: "设置…") | `common.settingsMenu` | init |
| 159 | title: "退出登录" | `server.signOut` | init |
| 196 | "\(model.currentServerName) · 未登录" | `server.name.unauthenticated` | String |
| 198 | "\(... ) · \(管理员/用户)" | `server.name.role / server.role.admin / server.role.user` | String |
| 203 | Text("服务器") | `server.title` | Text |
| 210 | Text("尚未连接服务器") | `server.notConnected` | Text |
| 228 | title: "管理服务器…" | `server.menu.manage` | init |
| 360 | .help(isEnabled ? title : "\(title)（v1.1 提供）") | `server.unavailable` | help |
| 367 | parts.append("当前服务器") | `server.current` | String |
| 368 | parts.append("版本 \(badge)") | `common.versionBadge` | String |

#### `Sources/PrismUI/AppShell/SidebarView.swift`  ·  9 处 · P0

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 31 | Section("媒体库") | `nav.section.media` | init |
| 37 | Section("工具") | `nav.section.tools` | init |
| 134 | .accessibilityLabel("版本 \(badge)") | `common.versionBadge` | a11y |
| 164 | "\(item.title)（\(hint)）" | `nav.sidebar.item.shortcutWithHint` | String |
| 169 | "\(item.title)，v1.1 提供" | `nav.sidebar.item.unavailableShort` | String |
| 172 | "\(item.title)，快捷键 \(hint)" | `nav.sidebar.item.shortcut` | String |
| 194 | Text("设置") | `common.settings` | Text |
| 225 | .help("设置（⌘,）") | `common.settingsShortcut` | help |
| 226 | .accessibilityLabel("设置，快捷键 ⌘,") | `nav.settings.a11y` | a11y |

#### `Sources/PrismUI/DesignSystem/StateViews.swift`  ·  13 处 · P0

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 38 | title: LocalizedStringKey = "这里还什么都没有" | `state.empty.title` | Key |
| 95 | retryTitle: LocalizedStringKey = "重试" | `common.retry` | Key |
| 164 | "服务器地址无效" | `error.invalidURL.title` | Key |
| 166 | "登录已失效" | `error.unauthorized.title` | Key |
| 168 | "没有访问权限" | `error.forbidden.title` | Key |
| 170 | "找不到内容" | `error.notFound.title` | Key |
| 172 | "无法连接到服务器" | `error.serverUnreachable.title` | Key |
| 174 | "无法读取服务器数据" | `error.decoding.title` | Key |
| 176 | "服务器出错了" | `error.server.title` | Key |
| 178 | "操作已取消" | `error.cancelled.title` | Key |
| 180 | "出了点问题" | `error.unknown.title` | Key |
| 246 | Text("正在加载") | `state.loading.a11y` | Text |
| 263 | Text("正在加载") | `state.loading.a11y` | Text |

#### `Sources/PrismUI/Player/PlayerControls.swift`  ·  19 处 · P0

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 153 | accessibilityLabel: isPlaying ? "暂停（空格）" : "播放（空格）" | `player.pauseHint / player.playHint` | a11y |
| 158 | "上一集（⌘←）" | `player.previousEpisodeHint` | a11y |
| 163 | "下一集（⌘→）" | `player.nextEpisodeHint` | a11y |
| 188 | Text("播放时间") | `player.playbackTime` | a11y |
| 192 | "\(model.position.formatted)，总时长未知" | `player.timeWithUnknownDuration` | format |
| 204 | "画中画" | `player.pictureInPicture` | a11y |
| 208 | isPiPAvailable ? "画中画" : "当前引擎未暴露画中画接口" | `player.pictureInPicture / player.pictureInPictureUnavailable` | help |
| 214 | isFullScreen ? "退出全屏（Esc）" : "进入全屏（F）" | `player.exitFullScreen / player.enterFullScreen` | a11y |
| 231 | isMuted ? "音量（已静音，M 取消静音）" : "音量（M 静音）" | `player.volumeMutedHint / player.volumeHint` | a11y |
| 239 | Button(isMuted ? "取消静音" : "静音") | `player.unmute / player.mute` | Button |
| 240 | Button("音量 +5%") | `player.volumeUp` | Button |
| 241 | Button("音量 −5%") | `player.volumeDown` | Button |
| 280 | Button(isMuted ? "取消静音" : "静音") | `player.unmute / player.mute` | Button |
| 295 | Text("音量") | `player.volume` | a11y |
| 302 | "音轨（A 循环切换）" | `player.audioTracksHint` | a11y |
| 323 | "字幕（S 开关）" | `player.subtitlesHint` | a11y |
| 350 | "播放速度（> / < 调整）" | `player.speedHint` | a11y |
| 361 | Text("播放速度") | `player.speed` | Text |
| 391 | Text("播放速度") | `player.speed` | a11y |

#### `Sources/PrismUI/Player/PlayerView.swift`  ·  21 处 · P0

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 162 | Text("播放器") | `player.a11y.player` | a11y |
| 178 | Text("等待播放引擎…") | `player.waitingForEngine` | Text |
| 213 | "返回（Esc）" | `player.backHint` | a11y |
| 280 | Text("正在准备播放…") | `player.preparing` | Text |
| 284 | Button("取消") | `common.cancel` | Button |
| 289 | .accessibilityLabel("取消播放") | `player.cancelPlayback` | a11y |
| 297 | Text("正在准备播放") | `player.preparingA11y` | a11y |
| 306 | Text("正在缓冲…") | `player.buffering` | Text |
| 317 | Text("正在缓冲") | `player.bufferingA11y` | a11y |
| 328 | Text("播放结束") | `player.finished` | Text |
| 333 | PrismPrimaryButton("下一集", systemImage: "forward.end.fill") | `player.nextEpisode` | Button |
| 359 | Text("无法播放该文件") | `player.cannotPlay` | Text |
| 372 | PrismSecondaryButton("返回") | `common.back` | Button |
| 376 | PrismPrimaryButton("重试", systemImage: "arrow.clockwise") | `common.retry` | Button |
| 391 | Text("无法播放该文件") | `player.cannotPlay` | a11y |
| 514 | "无法打开这个文件，可能是服务器拒绝或地址已失效。" | `player.error.noAccess` | String |
| 516 | "连接已中断，请检查网络后重试。" | `player.error.disconnected` | String |
| 518 | "这个文件用了不支持的编码或容器，换个版本试试。" | `player.error.unsupported` | String |
| 520 | "解码失败，文件可能已损坏。" | `player.error.decodeFailed` | String |
| 522 | "播放已取消。" | `player.error.cancelled` | String |
| 524 | "发生了未知错误，请重试或换个版本。" | `player.error.unknown` | String |

#### `Sources/PrismUI/Player/TrackMenu.swift`  ·  34 处 · P0

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 92 | "未知语言" | `track.language.unknown` | String |
| 119 | "单声道" | `track.channels.mono` | String |
| 120 | "立体声" | `track.channels.stereo` | String |
| 124 | "\(channels) 声道" | `track.channels.count` | format |
| 147 | isExternal ? "外挂" : "内嵌" | `track.external / track.internal` | String |
| 164 | "zh" / "zho" / "chi" / "zh-cn" → 中文 / 中文（简） | `language.zh / language.zhHans` | C |
| 165 | "zh-hans" / "zh-tw" / "zh-hant" | `language.zhHans / language.zhHant` | C |
| 166 | "yue" / "cantonese" → 粤语 | `language.yue` | C |
| 167 | "en" / "eng" → 英语 | `language.en` | C |
| 168 | "ja" / "jpn" → 日语 | `language.ja` | C |
| 169 | "ko" / "kor" → 韩语 | `language.ko` | C |
| 170 | "fr" / "fra" / "fre" → 法语 | `language.fr` | C |
| 171 | "de" / "deu" / "ger" → 德语 | `language.de` | C |
| 172 | "es" / "spa" → 西班牙语 | `language.es` | C |
| 173 | "it" / "ita" → 意大利语 | `language.it` | C |
| 174 | "ru" / "rus" → 俄语 | `language.ru` | C |
| 175 | "pt" / "por" → 葡萄牙语 | `language.pt` | C |
| 176 | "th" / "tha" → 泰语 | `language.th` | C |
| 177 | "vi" / "vie" → 越南语 | `language.vi` | C |
| 178 | "ar" / "ara" → 阿拉伯语 | `language.ar` | C |
| 179 | "hi" / "hin" → 印地语 | `language.hi` | C |
| 217 | PlayerMenuContainer(title: "音轨") | `track.menu.audio` | init |
| 219 | PlayerMenuEmptyRow(text: "该视频只有一条音轨") | `track.menu.audioEmpty` | init |
| 226 | badge: track.isDefault ? "默认" : nil | `track.default` | init |
| 233 | Text(footerNote ?? "直通 · 引擎解码") | `track.footer.passthrough` | Text |
| 286 | PlayerMenuContainer(title: "字幕") | `track.menu.subtitles` | init |
| 288 | title: "关闭字幕" | `track.menu.subtitlesOff` | init |
| 289 | detail: "不显示任何字幕" | `track.menu.subtitlesOffDetail` | init |
| 296 | PlayerMenuEmptyRow(text: "该视频没有字幕") | `track.menu.subtitlesEmpty` | init |
| 304 | badge: track.isDefault ? "默认" : nil | `track.default` | init |
| 315 | Text("复杂 ASS 特效（淡入淡出、描边）可能丢失") | `track.assWarning` | Text |
| 327 | Text("字幕延迟") | `track.subtitleDelay` | Text |
| 347 | Button("重置延迟") | `track.subtitleDelayReset` | Button |
| 352 | .accessibilityLabel("重置字幕延迟") | `track.subtitleDelayResetA11y` | a11y |

#### `Sources/PrismUI/AppShell/AppShellView.swift`  ·  7 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 60 | model.isPlayerPresented ? "正在播放" : model.contentRoute.title | `navigation.nowPlaying` | String |
| 66 | prompt: Text("搜索影片、剧集、演员") | `appshell.searchPrompt` | Text |
| 128 | .help("返回（⌘[）") | `appshell.back` | help |
| 129 | .accessibilityLabel("返回") | `common.back` | a11y |
| 139 | .help(model.showsDetailColumn ? "隐藏详情栏" : "显示详情栏") | `appshell.detailColumn.hide / appshell.detailColumn.show` | help |
| 140 | .accessibilityLabel(model.showsDetailColumn ? "隐藏详情栏" : "显示详情栏") | `appshell.detailColumn.hide / appshell.detailColumn.show` | a11y |
| 222 | countUnit: type == .series ? "部" : "部" | `library.count.unit` | init |

#### `Sources/PrismUI/AppShell/Commands.swift`  ·  12 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 65 | Button("设置…") | `common.settingsMenu` | Button |
| 76 | Button("切换服务器…") | `commands.switchServer` | Button |
| 82 | Button("添加服务器…") | `commands.addServer` | Button |
| 86 | .help("添加服务器流程由连接向导接入后启用") | `commands.addServer.disabled` | help |
| 88 | Button("退出登录") | `server.signOut` | Button |
| 96 | Button("首页") { … } | `nav.home` | Button |
| 100 | Button("电影") { … } | `nav.movies` | Button |
| 104 | Button("剧集") { … } | `nav.series` | Button |
| 108 | Button("搜索") { … } | `nav.search` | Button |
| 119 | Button("返回") { … } | `common.back` | Button |
| 123 | Button(model?.isSidebarVisible == false ? "显示边栏" : "隐藏边栏") | `commands.toggleSidebar.show / commands.toggleSidebar.hide` | Button |
| 129 | Button(… ? "显示详情栏" : "隐藏详情栏") | `appshell.detailColumn.show / appshell.detailColumn.hide` | Button |

#### `Sources/PrismUI/AppShell/NavigationModel.swift`  ·  7 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 25 | case .connected: "已连接" | `navigation.status.connected` | String |
| 26 | case .connecting: "正在连接…" | `navigation.status.connecting` | String |
| 27 | case .unauthorized: "需要重新登录" | `navigation.status.unauthorized` | String |
| 28 | case .offline: "离线" | `navigation.status.offline` | String |
| 29 | case .unsupported: "服务器版本不受支持" | `navigation.status.unsupported` | String |
| 203 | currentServer?.name ?? "未连接服务器" | `navigation.noServer` | String |
| 208 | currentUser?.name ?? "未登录" | `navigation.noUser` | String |

#### `Sources/PrismUI/AppShell/Route.swift`  ·  20 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 92 | case .home: "首页" | `nav.home` | Key |
| 93 | case .movies: "电影" | `nav.movies` | Key |
| 94 | case .series: "剧集" | `nav.series` | Key |
| 95 | case .search: "搜索" | `nav.search` | Key |
| 96 | case .downloads: "下载" | `nav.downloads` | Key |
| 97 | case .settings: "设置" | `common.settings` | Key |
| 148 | case .playback: "播放" | `settings.tab.playback` | Key |
| 149 | case .subtitles: "字幕" | `settings.tab.subtitles` | Key |
| 150 | case .network: "网络" | `settings.tab.network` | Key |
| 151 | case .appearance: "外观" | `settings.tab.appearance` | Key |
| 152 | case .servers: "服务器" | `settings.tab.servers` | Key |
| 153 | case .about: "关于" | `settings.tab.about` | Key |
| 174 | case .home: "首页" | `route.window.home` | Key |
| 177 | case .movie: "电影" | `route.window.movie` | Key |
| 178 | case .series: "剧集" | `route.window.series` | Key |
| 179 | default: "媒体库" | `route.window.library` | Key |
| 181 | case .search: "搜索" | `route.window.search` | Key |
| 182 | case .downloads: "下载" | `route.window.downloads` | Key |
| 184 | case .detail: "详情" | `route.window.detail` | Key |
| 185 | case .player: "正在播放" | `route.window.player` | Key |

#### `Sources/PrismUI/Detail/CastRow.swift`  ·  4 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 143 | case "director": return "导演" | `detail.cast.role.director` | String |
| 144 | case "writer", "screenplay": return "编剧" | `detail.cast.role.writer` | String |
| 145 | case "producer": return "制片" | `detail.cast.role.producer` | String |
| 146 | case "composer": return "作曲" | `detail.cast.role.composer` | String |

#### `Sources/PrismUI/Detail/DetailPlaceholder.swift`  ·  1 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 56 | Text("正在加载详情") | `detail.loading` | a11y |

#### `Sources/PrismUI/Detail/DetailScreen.swift`  ·  3 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 58 | title: "找不到这个条目" | `detail.notFound.title` | init |
| 59 | message: "它可能已从服务器上移除。" | `detail.notFound.message` | init |
| 60 | actionTitle: "重试" | `common.retry` | init |

#### `Sources/PrismUI/Detail/EpisodeRow.swift`  ·  5 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 72 | Text(isPlayable ? "播放这一集" : "该集尚未播出") | `detail.episode.playHint / detail.episode.notAiredHint` | a11y |
| 123 | Text("未播出") | `detail.episode.notAired` | Text |
| 197 | Text("继续观看") | `detail.continueWatching` | Text |
| 228 | parts.append("已看完") | `detail.episode.played` | String |
| 229 | parts.append("接下来观看") | `detail.episode.nextUp` | String |

#### `Sources/PrismUI/Detail/MovieDetailView.swift`  ·  19 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 81 | DetailSection(title: "演职员") | `detail.section.cast` | init |
| 89 | DetailSection(title: "相似推荐") | `detail.section.similar` | init |
| 144 | title: isPlayed ? "已看" : "标记已看" | `detail.watched / detail.markWatched` | init |
| 152 | title: isFavorite ? "已收藏" : "收藏" | `detail.favorited / detail.favorite` | init |
| 159 | Button("复制标题", systemImage: "doc.on.doc") | `detail.copyTitle` | Button |
| 162 | Button("刷新详情", systemImage: "arrow.clockwise") | `detail.refresh` | Button |
| 176 | .help("更多") | `common.more` | help |
| 177 | Text("更多") | `common.more` | a11y |
| 189 | return "播放" | `detail.play` | String |
| 191 | return "从 \(position.formatted) 继续" | `detail.resumeFrom` | format |
| 193 | return "重新播放" | `detail.replay` | String |
| 196 | return "继续观看 \(code)" | `detail.continueWatching.code` | format |
| 198 | return "继续观看" | `detail.continueWatching` | String |
| 201 | return "重新观看 \(code)" | `detail.replay.code` | format |
| 203 | return "重新观看" | `detail.replay.plain` | String |
| 209 | return "该季暂无剧集" | `detail.noEpisodes` | String |
| 326 | Button(isExpanded ? "收起" : "展开") | `common.collapse / common.expand` | Button |
| 332 | Text(isExpanded ? "收起简介" : "展开简介") | `detail.collapseA11y / detail.expandA11y` | a11y |
| 412 | Button("关闭", action: onDismiss) | `common.close` | Button |

#### `Sources/PrismUI/Detail/SeasonPicker.swift`  ·  1 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 91 | Text("季选择") | `detail.season.picker` | a11y |

#### `Sources/PrismUI/Detail/SeriesDetailView.swift`  ·  6 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 78 | Text("剧集") | `detail.tab.episodes` | Text |
| 111 | DetailSection(title: "演职员") | `detail.section.cast` | init |
| 119 | DetailSection(title: "相似推荐") | `detail.section.similar` | init |
| 226 | parts.append("共 \(content.episodes.count) 集") | `detail.episodeCount` | format |
| 227 | parts.append("已看 \(content.watchedEpisodeCount) 集") | `detail.watchedCount` | format |
| 273 | Text("该季暂无剧集") | `detail.noEpisodes` | Text |

#### `Sources/PrismUI/Home/ContinueWatchingCard.swift`  ·  5 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 173 | Text("继续播放") | `home.resumeA11y` | a11y |
| 229 | "第 \(season) 季 第 \(episode) 集" | `home.episode.marker` | format |
| 246 | "剩余不到 1 分钟" | `home.remaining.lessThanMinute` | String |
| 254 | "剩余 \(hours) 小时 \(minutes) 分钟" / "剩余 \(hours) 小时" | `home.remaining.hoursMinutes / home.remaining.hours` | String |
| 256 | "剩余 \(minutes) 分钟" | `home.remaining.minutes` | String |

#### `Sources/PrismUI/Home/HomeSections.swift`  ·  8 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 100 | Text("查看全部") | `home.viewAll` | Text |
| 111 | .help("查看全部") | `home.viewAll` | help |
| 112 | Text("查看全部") | `home.viewAll` | a11y |
| 240 | badge: "下一集" | `home.episode.badge` | init |
| 277 | let marker = "第 \(season) 季 第 \(episode) 集" | `home.episode.marker` | format |
| 390 | Text("播放") | `common.play` | a11y |
| 450 | Text("媒体库") | `home.libraries` | Text |
| 519 | Text("\(count) 项") | `common.itemCount` | Text |

#### `Sources/PrismUI/Home/HomeView.swift`  ·  12 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 104 | .help("正在刷新首页") | `home.refreshing` | help |
| 105 | Text("正在刷新首页") | `home.refreshing` | a11y |
| 110 | Label("刷新", systemImage: "arrow.clockwise") | `common.refresh` | Label |
| 113 | .help("刷新（⌘R）") | `home.refreshHelp` | help |
| 114 | Text("刷新首页") | `home.refreshA11y` | a11y |
| 141 | title: "这里还什么都没有" | `state.empty.title` | init |
| 142 | message: "服务器上还没有媒体，或还没有观看记录。…" | `home.empty.message` | init |
| 143 | actionTitle: "刷新" | `common.refresh` | init |
| 324 | Button("重试", action: onRetry) | `common.retry` | Button |
| 373 | Text("全部 \(items.count) 项") | `home.allItems` | Text |
| 381 | Text("收起") | `common.collapse` | Text |
| 390 | Text("收起") | `common.collapse` | a11y |

#### `Sources/PrismUI/Home/HomeViewModel.swift`  ·  7 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 27 | case .resume: "继续观看" | `home.continueWatching` | Key |
| 28 | case .nextUp: "接下来" | `home.nextUp` | Key |
| 29 | case .latest: "最新添加" | `home.latest` | Key |
| 30 | case .libraries: "媒体库" | `home.libraries` | Key |
| 184 | "部分内容加载失败" | `home.partialFailure` | String |
| 185 | "\(names.joined(separator: "、"))加载失败" | `home.partialFailure.named` | format |
| 360 | .unknown("首页数据加载失败") | `home.loadFailed` | String |

#### `Sources/PrismUI/Library/FilterBar.swift`  ·  23 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 50 | countUnit: String = "部" | `library.count.unit` | init |
| 111 | "共 \(totalCount) \(countUnit)" | `library.count.summary` | format |
| 120 | Button("清除全部") | `common.clearAll` | Button |
| 127 | .help("清除全部筛选条件") | `library.filter.clearAllHelp` | help |
| 128 | Text("清除全部筛选") | `library.filter.clearAll` | a11y |
| 184 | .help("排序：\(sort.title)") | `library.sort.help` | help |
| 185 | Text(verbatim: "排序：\(sort.title)") | `library.sort.help` | a11y |
| 252 | isActive ? "筛选（已启用 \(badgeCount) 项）" : "筛选" | `library.filter.active / library.filter.title` | help |
| 253 | Text(isActive ? "筛选，已启用 \(badgeCount) 项" : "筛选") | `library.filter.activeA11y / library.filter.title` | a11y |
| 319 | Text("筛选") | `library.filter.title` | Text |
| 349 | sectionTitle("观看状态") | `library.filter.watchState` | init |
| 352 | "观看状态" | `library.filter.watchState` | init |
| 371 | sectionTitle("类型") | `library.filter.genre` | init |
| 374 | Text("暂无可选类型：媒体库加载后会出现在这里。") | `library.filter.genreEmpty` | Text |
| 427 | sectionTitle("年份范围") | `library.filter.yearRange` | init |
| 430 | "限制年份范围" | `library.filter.yearRangeLimit` | init |
| 442 | yearStepper(title: "从", …) | `library.filter.yearFrom` | init |
| 445 | yearStepper(title: "到", …) | `library.filter.yearTo` | init |
| 483 | sectionTitle("评分下限") | `library.filter.minRating` | init |
| 507 | guard let rating = … else { return "不限" } | `library.filter.anyRating` | String |
| 515 | Button("清除全部") | `common.clearAll` | Button |
| 522 | Text("清除全部筛选") | `library.filter.clearAll` | a11y |
| 526 | Button("完成") | `common.done` | Button |

#### `Sources/PrismUI/Library/FilterSet.swift`  ·  3 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 48 | case .all: "全部" | `library.watchState.all` | Key |
| 49 | case .unwatched: "未看" | `library.watchState.unwatched` | Key |
| 50 | case .watched: "已看" | `library.watchState.watched` | Key |

#### `Sources/PrismUI/Library/LibraryGridView.swift`  ·  22 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 118 | title: "没有可显示的内容" | `library.grid.empty.title` | init |
| 119 | message: "换一个筛选条件，或刷新后重试。" | `library.grid.empty.message` | init |
| 241 | Text("正在加载更多…") | `library.loadingMore` | Text |
| 251 | Text("正在加载更多") | `library.loadingMoreA11y` | a11y |
| 253 | Text("已全部加载") | `library.allLoaded` | Text |
| 258 | Text("已全部加载") | `library.allLoaded` | a11y |
| 266 | Button("播放") | `common.play` | Button |
| 268 | Button("从上次位置继续") | `library.context.resume` | Button |
| 273 | Button("标记为已看") | `library.context.markPlayed` | Button |
| 275 | Button("标记为未看") | `library.context.markUnplayed` | Button |
| 277 | Button(isFavorite ? "取消收藏" : "收藏") | `library.context.unfavorite / library.context.favorite` | Button |
| 281 | Button("查看详情") | `library.context.details` | Button |
| 282 | Button("在 Finder 中显示") | `library.context.showInFinder` | Button |
| 284 | .help("v1.1 提供（需要服务端返回文件路径）") | `library.context.showInFinderUnavailable` | help |
| 505 | .help("播放") | `common.play` | help |
| 506 | Text("播放") | `common.play` | a11y |
| 511 | Text("已看") | `library.item.watched` | a11y |
| 516 | Text("已观看 \(Int((item.progress * 100).rounded()))%") | `library.item.progress` | a11y |
| 529 | parts.append("\(count) 集未看") | `library.item.unwatchedEpisodes` | format |
| 536 | parts.append("\(year) 年") | `library.item.year` | format |
| 537 | String(format: "%.1f 分", rating) | `library.item.rating` | format |
| 538 | parts.append(played ? "已观看" : "未观看") | `library.item.played / library.item.unplayed` | String |

#### `Sources/PrismUI/Library/LibraryView.swift`  ·  11 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 64 | countUnit: String = "部" | `library.count.unit` | init |
| 161 | title: "加载媒体库失败" | `library.loadFailed` | init |
| 179 | title: "没有符合条件的内容" | `library.filteredEmpty.title` | init |
| 180 | message: "试试放宽筛选条件，或清除全部筛选。" | `library.filteredEmpty.message` | init |
| 181 | actionTitle: "清除筛选" | `library.filteredEmpty.action` | init |
| 189 | title: "这个媒体库还是空的" | `library.empty.title` | init |
| 190 | message: "在 Emby 服务器中添加内容后，回到这里刷新即可。" | `library.empty.message` | init |
| 191 | actionTitle: "刷新" | `common.refresh` | init |
| 216 | Button("重试") | `common.retry` | Button |
| 233 | .help("关闭") | `common.close` | help |
| 234 | Text("关闭错误提示") | `library.dismissError` | a11y |

#### `Sources/PrismUI/Library/SortOption.swift`  ·  5 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 48 | case .recentlyAdded: "最近添加" | `library.sort.recentlyAdded` | Key |
| 49 | case .titleAscending: "标题 A-Z" | `library.sort.titleAscending` | Key |
| 50 | case .year: "年份" | `library.sort.year` | Key |
| 51 | case .rating: "评分" | `library.sort.rating` | Key |
| 52 | case .runtime: "时长" | `library.sort.runtime` | Key |

#### `Sources/PrismUI/RootView.swift`  ·  1 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 28 | ProgressView("正在准备演示数据…") | `root.preparingDemo` | init |

#### `Sources/PrismUI/Search/RecentSearchesView.swift`  ·  10 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 63 | Text("最近搜索") | `search.recent.title` | a11y |
| 75 | Text("最近搜索") | `search.recent.title` | Text |
| 96 | Text("点击直接搜索") | `search.recent.clickToSearch` | Text |
| 118 | Text("还没有搜索记录。输入关键词后，最近搜过的内容会出现在这里。") | `search.recent.empty` | Text |
| 133 | Text("清除全部") | `common.clearAll` | Text |
| 142 | .help("清除全部最近搜索") | `search.recent.clearAllHelp` | help |
| 143 | Text("清除全部最近搜索") | `search.recent.clearAllHelp` | a11y |
| 172 | .help(Text(verbatim: "搜索「\(term)」")) | `search.term.help` | help |
| 187 | .help("从最近搜索中删除") | `search.recent.delete` | help |
| 188 | Text(verbatim: "删除最近搜索 \(term)") | `search.recent.deleteA11y` | a11y |

#### `Sources/PrismUI/Search/SearchResultItem.swift`  ·  4 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 37 | case .movie: "电影" | `search.kind.movie` | Key |
| 38 | case .series: "剧集" | `search.kind.series` | Key |
| 39 | case .episode: "单集" | `search.kind.episode` | Key |
| 40 | case .person: "人物" | `search.kind.person` | Key |

#### `Sources/PrismUI/Search/SearchView.swift`  ·  26 处 · P1

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 166 | Text("搜索电影、剧集、演员") | `search.placeholder` | Text |
| 171 | Text("在工具栏搜索框输入关键词，或按 ⌘F 聚焦搜索框。") | `search.empty.hint` | Text |
| 190 | sectionHeader("热门推荐", systemImage: "flame", …) | `search.popular` | init |
| 193 | Text("热门推荐将在接入服务端统计后显示。") | `search.popular.empty` | Text |
| 222 | .help(Text(verbatim: "搜索「\(term)」")) | `search.term.help` | help |
| 234 | Text("至少输入 \(viewModel.minimumQueryLength) 个字符") | `search.minLength` | Text |
| 238 | Text("再输入一些关键词，就能开始搜索。") | `search.minLength.hint` | Text |
| 254 | Text("正在搜索「\(viewModel.trimmedQuery)」…") | `search.searching` | Text |
| 263 | Text("正在搜索") | `search.searchingA11y` | a11y |
| 273 | posterSection("电影", …) | `search.section.movies` | init |
| 276 | posterSection("剧集", …) | `search.section.series` | init |
| 311 | Text("搜索结果") | `search.resultsA11y` | a11y |
| 316 | Text("「\(viewModel.trimmedQuery)」共 \(results.totalCount) 个结果") | `search.resultCount` | Text |
| 359 | sectionHeader("单集", …) | `search.section.episodes` | init |
| 380 | sectionHeader("人物", …) | `search.section.people` | init |
| 409 | Text("没有找到「\(viewModel.trimmedQuery)」") | `search.noResults` | Text |
| 415 | suggestion("检查拼写，或换一个更短的关键词") | `search.suggestion.spelling` | init |
| 416 | suggestion("试试搜索演员名，例如「汤姆·汉克斯」") | `search.suggestion.actor` | init |
| 417 | suggestion("确认该内容已经在 Emby 媒体库中") | `search.suggestion.library` | init |
| 421 | PrismSecondaryButton("清除搜索", systemImage: "xmark.circle") | `search.clear` | Button |
| 447 | title: "搜索失败" | `search.failed` | init |
| 457 | hintItem("↑ ↓", "选择") | `search.hint.select` | init |
| 458 | hintItem("↵", "打开") | `search.hint.open` | init |
| 459 | hintItem("⌘↵", "播放") | `search.hint.play` | init |
| 465 | Text("键盘：上下键选择，回车打开，Command 加回车播放") | `search.hintsA11y` | a11y |
| 509 | Text(verbatim: "\(count) 项") | `common.itemCount` | Text |

#### `Sources/PrismUI/DesignSystem/PosterCard.swift`  ·  5 处 · P2

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 191 | Text("播放") | `common.play` | a11y |
| 237 | Text("已看") | `library.item.watched` | a11y |
| 249 | Text("\(count) 集未看") | `library.item.unwatchedEpisodes` | a11y |
| 323 | Text("正在播放") | `navigation.nowPlaying` | Text |
| 336 | Text("正在播放") | `navigation.nowPlaying` | a11y |

#### `Sources/PrismUI/Player/KeyboardController.swift`  ·  19 处 · P2

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 215 | PlayerKeyBinding(keys: "空格 / K", action: "播放 / 暂停") | `keyboard.playPause` | init |
| 216 | action: "后退 / 前进 5 秒" | `keyboard.seek5` | init |
| 217 | action: "后退 / 前进 30 秒" | `keyboard.seek30` | init |
| 218 | action: "后退 / 前进 10 秒" | `keyboard.seek10` | init |
| 219 | action: "音量 ±5%" | `keyboard.volume5` | init |
| 220 | action: "音量 ±1%" | `keyboard.volume1` | init |
| 221 | action: "静音" | `keyboard.mute` | init |
| 222 | action: "进入 / 退出全屏" | `keyboard.fullScreen` | init |
| 223 | action: "退出全屏 → 关闭播放器" | `keyboard.exitAndClose` | init |
| 224 | action: "字幕显示 / 隐藏" | `keyboard.subtitlesToggle` | init |
| 225 | action: "循环切换音轨" | `keyboard.cycleAudio` | init |
| 226 | action: "字幕延迟 ∓0.1 秒" | `keyboard.subtitleDelay` | init |
| 227 | action: "字幕延迟 ∓0.1 秒（mpv 习惯）" | `keyboard.subtitleDelayMpv` | init |
| 228 | action: "字幕延迟归零" | `keyboard.subtitleDelayReset` | init |
| 229 | action: "跳转到 0% – 90%" | `keyboard.jump` | init |
| 230 | action: "上一集 / 下一集" | `keyboard.prevNextEpisode` | init |
| 231 | action: "加速 / 减速 0.25×" | `keyboard.speed` | init |
| 232 | action: "加速 / 减速 0.25×（mpv 习惯）" | `keyboard.speedMpv` | init |
| 433 | Text("固定") | `keyboard.fixed` | Text |

#### `Sources/PrismUI/Player/ProgressSlider.swift`  ·  2 处 · P2

| 行 | 原文 | key | 形式 |
|---:|---|---|---|
| 174 | Text("播放进度") | `player.progress` | a11y |
| 309 | return Text("时长未知") | `player.durationUnknown` | Text |

---

## 8. 如何添加新语言

1. **在 Xcode 里加**（推荐）：打开 `Sources/PrismUI/Resources/Localizable.xcstrings`，
   左下角 `+` → 选语言（如 `ja`）→ 逐条填译文。Xcode 会维护 `localizations` 结构与 `state`。
2. **手改 JSON**：给每个 key 的 `localizations` 加一段：

   ```json
   "ja" : {
     "stringUnit" : { "state" : "translated", "value" : "…" }
   }
   ```

   `state` 取值：`translated` / `needs_review` / `new` / `stale`。**空 value 或 state 不是 `translated`
   的条目会被当作未翻译**，运行时回退到 `sourceLanguage`（本 catalog 是 `zh-Hans`）——注意回退的是**中文**，
   不是英文。所以新增语言必须补齐全部 319 + 11 条。
3. 在 `AppLanguage` 枚举里加 case（`Sources/PrismCore/Settings/AppSettings.swift`），
   并在 `locale` 里返回对应 `Locale`。
4. 路线 B 下把新 catalog 同步到 `App/`（§1 的副本机制）。
5. 不需要改 `Package.swift`：`.process("Resources")` 会自动收进新增的 `.lproj`。

**新增一个 key 的流程**：先在 catalog 里加（key + zh-Hans + en + comment），
再用 `Text("新key")` 替换硬编码——**不要反过来**，否则中间态会出现「显示成 key」的界面。

---

## 9. 未覆盖内容（有意为之）与后续工单

| 内容 | 位置 | 为什么不做 |
|---|---|---|
| 预览假数据 | `Detail/DetailPreviewData.swift`（45 处）、`Library/LibraryPreviewSupport.swift`（38）、`DesignSystem/PreviewSupport.swift`（34）、`Home/HomePreviewData.swift`（33）、`Search/SearchPreviews.swift`（23）、`AppShell/AppShellPreviews.swift`（11） | `#Preview` 专用，不进产品 |
| 占位页 | `AppShell/PlaceholderScreens.swift`（30 处） | 会被真实页面替换；若 1.0 前仍未替换，再补一组 `placeholder.*` |
| 日志与开发者注释 | 各 `logger.*` / `///` | 不需要翻译 |
| `SessionStoreError` 文案 | `Sources/PrismData/Session/SecureStore.swift:66-89`，4 个 key（`error.sessionStore.*`） | 属于 PrismData；接法同 PrismCore（catalog + `bundle: .module` 或走路线 B 的主 bundle）。**路线 B 下建议直接把这 4 条并进主 catalog，代码不用改** |
| 播放协商错误 | `Sources/PrismPlayback/Negotiation/PlaybackPlan.swift:129` 的 `localizedDescription` | 目前是硬编码技术文案，不是面向用户的正式错误 |
| 演示数据生成器 | `Sources/EmbyAPI/Demo/DemoPlaybackAsset.swift` | 仅 demo 模式，错误串只进日志 |

---

## 10. 验证记录

| 项 | 命令 / 方式 | 结果 |
|---|---|---|
| `.xcstrings` 是合法 JSON | `python3 -m json.tool Sources/PrismUI/Resources/Localizable.xcstrings` | ✅ |
| SwiftPM 能编译 catalog | `swift build --target PrismCore --disable-sandbox --cache-path .build/cache` | ✅ 产出 `Prism_PrismCore.bundle/Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings` |
| 编译产物内容正确 | `plutil -p …/en.lproj/Localizable.strings` | ✅ `"error.timeout" => "The connection timed out. Please try again."` 等 11 条 |
| key 无重复 | 生成脚本对每个 key 断言 `not in` | ✅ 319 + 11 全唯一 |
| 无空翻译 | 生成脚本断言 zh / en 均非空 | ✅ |
| key 与清单双向一致 | 脚本比对「清单引用集合」与「catalog 键集合」 | ✅ 319 = 319，无孤儿、无缺失 |
| `swift build --target PrismUI` 零 error | `swift build --target PrismUI --disable-sandbox --cache-path .build/cache` | ✅ `Build complete!`（期间曾被 `Settings/` 施工中的 7 个 error 短暂阻塞，与本工单无关；Settings 落地后复验通过） |
| 未新增 / 修改任何 `.swift` | `git status --short` | ✅ 只有 2 个新建 `.xcstrings` + `Package.swift` 一行 + 本文件 |

---

## 附：维护提醒

- catalog 的 `sourceLanguage` 固定为 `zh-Hans`，`version` 为 `1.0`。**不要手改这两个字段**，Xcode 会重写。
- 所有条目带 `"extractionState": "manual"`：这样即使代码里暂时还没有 `Text("key")`，
  Xcode 的「提取」也不会把条目删掉。**替换全部完成后**可以去掉这个字段（让 Xcode 接管增删）。
- 新增 key 时保持文件按 key 字母序（生成脚本已 `sort_keys`），减少 diff 噪声。
