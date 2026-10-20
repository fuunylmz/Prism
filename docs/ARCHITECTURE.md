# Prism 架构与接口契约

> 本文件是**冻结契约**。任何代理不得擅自修改这里的签名；确需变更，先向主管提交变更请求。
> 版本 v1.0 ｜ 对应 ROADMAP M0

---

## 0. 分层与依赖方向

```
PrismApp (App/)
   └── PrismUI
         ├── PrismCore
         ├── EmbyAPI ──→ PrismCore
         ├── PrismData ─→ PrismCore, EmbyAPI
         └── PrismPlayback → PrismCore, EmbyAPI
```

**铁律**
- 依赖只能向下，禁止反向或环状。
- `PrismPlayback` **依赖 EmbyAPI**（协商层要用 `DeviceProfile` / `PlaybackInfoResponse`），
  但**不得**依赖 `PrismUI` / `PrismData`。
- `PrismUI` 之外的模块不得 import SwiftUI（`PrismPlayback` 只通过 `PlaybackEngine.renderView`
  暴露一个 `AnyView`，且该属性由 UI 侧消费）。
- 所有跨模块传值类型必须 `Sendable`。

---

## 1. PrismCore

### 1.1 时间与数值

```swift
/// Emby 的时间单位是 tick（1 tick = 100ns，10,000,000 ticks = 1s）。
public struct Ticks: Sendable, Hashable, Codable, Comparable {
    public let rawValue: Int64
    public init(_ rawValue: Int64)
    public init(seconds: Double)
    public var seconds: Double { get }
    public var timeInterval: TimeInterval { get }
    public var formatted: String        // "1:23:45" / "23:45"
    public var remainingFormatted: String
    public static func + (Ticks, Ticks) -> Ticks
    public static func - (Ticks, Ticks) -> Ticks
}
```

### 1.2 核心模型（均 `Sendable, Codable, Identifiable, Hashable`）

```swift
public struct EmbyUser: ... {
    public let id: String
    public let name: String
    public let serverId: String
    public let isAdministrator: Bool
    public let primaryImageTag: String?
}

public struct MediaItem: ... {
    public let id: String
    public let name: String
    public let type: ItemType          // movie, series, season, episode, boxSet, playlist, folder...
    public let serverId: String
    public let productionYear: Int?
    public let runTime: Ticks?
    public let overview: String?
    public let officialRating: String?
    public let communityRating: Double?
    public let genres: [String]
    public let imageTags: [ImageKind: String]     // primary/backdrop/logo/thumb
    public let backdropTags: [String]
    public let userData: UserItemData
    public let seriesId: String?
    public let seasonId: String?
    public let indexNumber: Int?        // 集号
    public let parentIndexNumber: Int?  // 季号
    public let seriesName: String?
    public let mediaSources: [MediaSource]
    public let people: [Person]?        // 仅详情接口返回
    public let childCount: Int?
}

public struct UserItemData: Sendable, Codable, Hashable {
    public var playbackPosition: Ticks
    public var playCount: Int
    public var isFavorite: Bool
    public var played: Bool
    public var lastPlayedDate: Date?
    public var unplayedItemCount: Int?
}

public struct MediaSource: Sendable, Codable, Hashable {
    public let id: String
    public let name: String?
    public let container: String?       // mkv / mp4 / ts
    public let runTime: Ticks?
    public let bitrate: Int?
    public let size: Int64?
    public let isRemote: Bool
    public let directStreamUrl: String?
    public let transcodingUrl: String?
    public let playSessionId: String?
    public let mediaStreams: [MediaStream]
    public let supportsDirectPlay: Bool
    public let supportsDirectStream: Bool
    public let supportsTranscoding: Bool
}

public struct MediaStream: Sendable, Codable, Hashable {
    public let index: Int
    public let type: StreamType        // video/audio/subtitle/embeddedImage
    public let codec: String?
    public let language: String?
    public let displayTitle: String?
    public let isDefault: Bool
    public let isExternal: Bool
    public let height: Int?
    public let width: Int?
    public let channels: Int?
    public let videoRange: String?     // SDR / HDR
    public let deliveryUrl: String?    // 外挂字幕/音轨直取地址
}
```

### 1.3 服务与错误

```swift
public enum EmbyError: Error, Sendable, Equatable {
    case invalidURL
    case unauthorized                  // 401 → 触发登出
    case forbidden
    case notFound
    case serverUnreachable(String)
    case timeout
    case decoding(String)
    case server(status: Int, message: String?)
    case cancelled
    case unknown(String)
    public var userMessage: LocalizedStringResource { get }   // 中英文案
    public var isRecoverable: Bool { get }
}

public protocol ClockProviding: Sendable { var now: Date { get } }
public protocol Logging: Sendable { func log(_ level: LogLevel, _ msg: String, metadata: [String: String]) }
```

### 1.4 设置

```swift
@MainActor @Observable
public final class AppSettings {
    public static let shared: AppSettings
    public var preferredQuality: QualityPreset        // auto / original / 1080p / 720p
    public var maxBitrateMbps: Int
    public var preferredAudioLanguage: String?
    public var preferredSubtitleLanguage: String?
    public var subtitleMode: SubtitleMode             // always / forced / foreign / never
    public var subtitleScale: Double                  // 0.5...2.0
    public var subtitleBackground: Bool
    public var seekStepSeconds: Int                   // 5/10/30
    public var autoPlayNextEpisode: Bool
    public var language: AppLanguage                  // system / zhHans / en
    public func reset()
}
```

---

## 2. EmbyAPI

### 2.1 客户端

```swift
public struct ClientIdentity: Sendable {
    public let appName: String        // "Prism"
    public let appVersion: String
    public let deviceName: String     // Host.current().localizedName
    public let deviceId: String       // 持久化于 UserDefaults，首次生成 UUID
}

public actor EmbyClient {
    public init(server: ServerConnection, identity: ClientIdentity, session: URLSession = .shared)

    /// 统一出口：自动拼接 server.baseURL、注入鉴权头、解析错误、日志脱敏
    public func send<T: Decodable>(_ endpoint: EmbyEndpoint) async throws -> T
    public func send(_ endpoint: EmbyEndpoint) async throws            // 无返回体
    public func data(_ endpoint: EmbyEndpoint) async throws -> Data    // 图片/流
    public func setAccessToken(_ token: String?)
}

public protocol EmbyEndpoint: Sendable {
    var path: String { get }                       // "/Users/{userId}/Items"
    var method: HTTPMethod { get }                 // .get default
    var query: [String: String] { get }
    var body: Data? { get }                        // 已编码的 JSON 字节
    var contentType: String? { get }
    var requiresAuth: Bool { get }
    var timeout: TimeInterval? { get }
    var cachePolicy: URLRequest.CachePolicy { get }
}
```

> **已实现且冻结**：`Sources/EmbyAPI/Transport/EmbyEndpoint.swift`（主管维护，代理只读）。
> 其中 `body` 用 `Data?` 而非 `Encodable?` —— Swift 6 下 `any Encodable` 不是 `Sendable`，
> 无法安全穿过 `EmbyClient` 的 actor 边界。端点用 `EmbyJSON.encode(_:)` 自行编码。

### 2.2 端点集（P0）

| 方法 | 路径 | 用途 |
|---|---|---|
| `publicInfo()` | `/System/Info/Public` | 连接校验、服务器名/版本 |
| `authenticate(username:password:)` | `/Users/AuthenticateByName` | 登录拿 AccessToken |
| `user(id:)` | `/Users/{Id}` | **恢复会话（首选）** ✅ Emby 有此端点 |
| `currentUser()` | `/Users/Me` | 恢复会话（**回退**）⚠️ 见下方说明 |
| `views(userId:)` | `/Users/{id}/Views` | 媒体库列表 |
| `items(userId:query:)` | `/Users/{id}/Items` | 浏览/搜索/筛选/分页 |
| `resume(userId:)` | `/Users/{id}/Items/Resume` | 继续观看 |
| `latest(userId:parentId:)` | `/Users/{id}/Items/Latest` | 最新添加 |
| `nextUp(userId:seriesId:)` | `/Shows/NextUp` | 接下来 |
| `itemDetail(userId:itemId:)` | `/Users/{id}/Items/{itemId}` | 详情 |
| `episodes(seriesId:seasonId:)` | `/Shows/{id}/Episodes` | 季集 |
| `similar(userId:itemId:)` | `/Items/{id}/Similar` | 相似 |
| `playbackInfo(itemId:profile:)` | `/Items/{id}/PlaybackInfo` | 协商 |
| `image(itemId:kind:tag:size:)` | `/Items/{id}/Images/{kind}` | 图片 |
| `reportStart/Progress/Stop` | `/Sessions/Playing*` | 进度上报 |
| `markPlayed/markFavorite` | `/Users/{id}/PlayedItems|FavoriteItems/{itemId}` | 标记 |

#### ⚠️ `/Users/Me` 是 Jellyfin 端点，Emby 没有（主管已核实）

2026-10-21 由 T1.3 代理提出、主管独立复核，结论一致：

| 证据 | 结果 |
|---|---|
| Emby Reference 候选页 `getUsersMe.html` / `getUsersMeQuery.html` 等 7 个名字 | **全部 404** |
| Emby OpenAPI 的 32 条 `/Users` 路径 | **无 `/Users/Me`** |
| `GET /Users/{Id}` 的 Reference 页 | **200**（`UserService/getUsersById.html`） |
| Jellyfin OpenAPI | **有 `/Users/Me`** |

**因此恢复会话的顺序必须是：**

1. 本地已有 `userId` → `GET /Users/{Id}`（Emby 支持）
2. 失败（404/500）→ 再试 `GET /Users/Me`（Jellyfin 兼容）
3. 都失败 → 视为 token 失效，回登录页

**不要把 `/Users/Me` 当作唯一路径**，否则连 Emby 4.8 会启动即失败。

> 实现位置：`Sources/EmbyAPI/Endpoints/` 已提供 `UserByIdEndpoint` 与 `user(id:)` 回退；
> `PrismData` 的会话恢复链路按上述顺序调用。

### 2.3 服务器发现
```swift
public struct DiscoveredServer: Sendable, Identifiable {
    public let id: String        // "\(address):\(port)"
    public let name: String
    public let address: String
    public let port: Int
    public var baseURL: URL
}

public actor ServerDiscovery {
    /// UDP 7359 广播 "who is EmbyServer?"，收集 3s 内的响应
    public func discover(timeout: Duration) -> AsyncStream<DiscoveredServer>
    /// 手动地址：补全 scheme/端口，校验 /System/Info/Public
    public func validate(urlString: String) async throws -> (ServerConnection, PublicServerInfo)
}
```

---

## 3. PrismPlayback

```swift
public enum PlaybackMethod: Sendable { case directPlay, directStream, transcode }

public struct PlaybackRequest: Sendable {
    public let url: URL
    public let method: PlaybackMethod
    public let headers: [String: String]      // 必须携带 Emby 鉴权头
    public let startPosition: Ticks
    public let externalSubtitles: [SubtitleTrack]
    public let audioStreamIndex: Int?
    public let subtitleStreamIndex: Int?
}

public enum PlaybackState: Sendable, Equatable {
    case idle, loading, playing, paused, buffering, ended
    case failed(PlaybackFailure)
}

public enum PlaybackEvent: Sendable {
    case stateChanged(PlaybackState)
    case positionChanged(Ticks, duration: Ticks)
    case durationChanged(Ticks)
    case bufferChanged(Double)              // 0...1
    case tracksChanged(audio: [TrackInfo], subtitle: [TrackInfo])
    case ended
    case failed(PlaybackFailure)
}

public protocol PlaybackEngine: AnyObject, Sendable {
    @MainActor var renderView: AnyView { get }        // 直接塞进 SwiftUI 的 body
    func load(_ request: PlaybackRequest) async throws
    func play() async
    func pause() async
    func seek(to position: Ticks) async
    func setRate(_ rate: Double) async
    func setVolume(_ volume: Double) async           // 0...1
    func selectAudioTrack(_ index: Int) async
    func selectSubtitleTrack(_ index: Int?) async    // nil = 关闭
    func setSubtitleDelay(_ seconds: Double) async
    func setSubtitleStyle(_ style: SubtitleStyle) async
    func setSubtitleFile(_ url: URL?) async          // 外挂
    func stop() async
    var events: AsyncStream<PlaybackEvent> { get }
}
```

**事件规则**
- `positionChanged` 至少 4Hz，UI 侧自行节流。
- 所有 `events` 在 `@MainActor` 消费，引擎内部不得直接触碰 UI。
- `stop()` 后引擎必须回到 `idle` 且释放解码器。

### 3.1 引擎实现：AetherEngine 映射（`AetherEngineAdapter`）

v1.0 的实现类是 `AetherEngineAdapter`，内部持有 AetherEngine 的 `player`。
**铁律：`import AetherEngine` 只允许出现在 `Sources/PrismPlayback/Engine/AetherEngineAdapter.swift` 一个文件里**
（CI 用 `grep -rl "import AetherEngine" --include=*.swift | grep -v AetherEngineAdapter` 检查）。

> **下表由主管直接读 AetherEngine 7.44.0 源码逐条核对**（`.spike/engine/.build/checkouts/AetherEngine/`），
> 比官方 README 更可靠——README 漏写了多条已存在的 API。
> `AetherEngine.swift` 行号对应 tag `7.44.0`。

| 我们的协议 | AetherEngine 实际 API | 状态 |
|---|---|---|
| `load(_:)` | `try await player.load(url:startPosition:options:)`，`options.httpHeaders` 收 Emby 鉴权头 | ✅ 直接映射 |
| `play()` / `pause()` | `player.play()` / `player.pause()` | ✅ 直接映射 |
| `seek(to:)` | `await player.seek(to: seconds)` （还有 `seek(toSourceTime:)`） | ✅ 直接映射 |
| `setRate(_:)` | `player.setRate(_:)`（`Float`，上限 `player.maxSupportedRate`） | ✅ 上限实测 **2.0**（视频）；音频 3.0 |
| `setVolume(_:)` | **`player.volume: Float`（源码 line 7302，get/set 均在，0.0–1.0）** | ✅ **上一版文档误判为缺口，实际存在** |
| `selectAudioTrack(_:)` | `player.selectAudioTrack(index: Int)`（line 7388） | ✅ 直接映射 |
| `selectSubtitleTrack(_:)` | 见 §3.2（需按字幕来源分路径） | ◐ 需适配 |
| `setSubtitleDelay(_:)` | `player.setSoftwareSubtitleDelay(_ seconds: Double)`（line 801） | ✅ 存在；**仅作用于软件字幕合成路径**，需在文档注释写明 |
| `setSubtitleStyle(_:)` | **无引擎 API** | ❌ 缺口，见 §3.3 |
| `setSubtitleFile(_:)` | 外部文件作为一等字幕轨注册 | ◐ 需适配 |
| `events` | `player.$state` / `$errorInfo` 是 **Combine `@Published`** | ◐ 需桥接为 `AsyncStream`，见 §3.2 |
| `renderView` | `AetherPlayerSurface(engine:)`（SwiftUI）/ `AetherPlayerView`（AppKit）+ `player.bind(view:)` | ✅ SwiftUI 直接嵌入 |
| 音轨/字幕列表 | `player.subtitleTracks`（`[TrackInfo]`）等 | ✅ |
| 缓冲进度 | `player.bufferedPosition`、`player.clock` | ✅ |
| 是否可 seek | `player.canSeek` | ✅ |
| `stop()` | `player.stop(resetDisplayCriteria:finalTeardown:)` | ✅ |

### 3.2 Combine → AsyncStream 桥接（必须做）

AetherEngine 用 Combine `@Published`，我们的契约要求 `AsyncStream<PlaybackEvent>`。
桥接时注意 **`AnyCancellable` 不是 `Sendable`**，不能直接存进 actor 属性：

```swift
// 正确做法：用 Task 持有订阅，或用 AsyncPublisher
for await state in player.$state.values { ... }
```

`player.$state.values` 是 `AsyncPublisher`，在 Swift 6 严格并发下可直接 `for await`。
**优先用它，避免手写 `sink` + `AnyCancellable`。**

### 3.3 三个真实缺口（源码核实，不是猜的）

| 缺口 | 事实 | 应对 |
|---|---|---|
| **字幕样式** | 引擎只给 `$subtitleCues`（cue 自带样式），**无用户偏好 API**（字号/颜色/描边/位置） | **这其实是优势**：字幕由我们自己绘制，样式完全可控。代价是 ASS 复杂排版不如 libass。UI 侧按我们的 `SubtitleStyle` 自己渲染 |
| **macOS 无 Now Playing 会话** | `audioNowPlayingSession` / `ownsVideoNowPlayingSession` / `videoNowPlayingSession` / `setVideoNowPlayingInfo` / `setAudioNowPlayingInfo` **全部被 `#if os(tvOS) \|\| os(iOS)` 门控**，macOS 上不存在 | **T3.5 仍是我们的工作**：用 `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` 自行实现。注意 `setExternalMetadata(_:)` **未被门控**，在 macOS 可用，AVKit 会把它作为 Now Playing 信息再发布 |
| **PiP** | `pictureInPictureActive`（line 813）与 `softwarePiPSource`（line 955）**未被平台门控** → macOS 可用 | ✅ 可用。但请注意 **macOS 26.4 上 `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)` 有已知缩放 bug**（软解路径受影响），原生路径不受影响 |

**AirPlay 在 macOS 上的支持情况：未查到确证**（源码中未发现 `allowsExternalPlayback` 或 `AVRoutePickerView` 的公开用法）。
标注 ⚠️【待验证】，在 T1.8 spike 中用 `AVRoutePickerView` 实测。

### 3.4 部署门槛（硬约束）

AetherEngine 7.x 要求：**macOS 15+ / Swift 6.4 / Xcode 27.0+ / 至少 macOS 26.2 SDK**。
最后一条来自 `VTRegisterSupplementalVideoDecoderIfAvailable`（iOS/tvOS 26.2 API，需在编译期存在）。
本机 Xcode 27.1 满足；**CI 镜像必须跟上，否则无法构建**。

### 3.5 实测行为（T1.8 spike，2026-10-21，macOS 27.0 / arm64）

完整报告见 [research/playback-spike-results.md](research/playback-spike-results.md)。以下是**必须在实现中处理**的结论：

#### ✅ 已通过

| 项 | 实测值 |
|---|---|
| MKV 起播 | **92 ms**（`load()` 返回 87ms 后 `playing`） |
| seek 精度 | 播放中与暂停中均 **误差 0.000s** |
| 视频路径 | `videoRoute=loopback backend=native`（MKV 走 demuxer → 本地 HLS-fMP4 → AVPlayer） |
| 离屏渲染 | `bind(view:)` 给离屏 `NSView` 即可，`load` 不要求上屏 |
| PiP | `isPictureInPictureSupported()=true`，**无需窗口**，`isPossible` 在 0.2s 后为 true |
| Swift 6 | Prism 侧 4 个 target **0 warning**，负向对照证明严格并发检查生效 |
| 体积 | .app 未压缩 **21.5 MB**，压缩后 **~8.1 MB**（zip/tar 双工具互证） |

#### ⚠️ 必须在适配层处理的三个坑

**坑 1：`duration` 在 `load()` 返回瞬间是 0**
实测 `load()` 返回时 `player.duration == 0`，**61ms 后**才变成真实值。
→ UI 若在 `load` 返回后立刻读 `duration`，进度条会闪 `00:00`。
**处理**：观察 `player.$duration`，或等首个 `.playing` 事件后再显示时长。

**坑 2：切音轨会触发 143ms 重建，且 `sourceTime` 归零约 86ms**
实测 `selectAudioTrack` 后 `$state` 走一次 `.loading`（143ms），同时
`clock.sourceTime` 出现 `9.073 → 0.000（约 86ms）→ 9.072` 的跳变。
→ 若进度条直绑 `sourceTime`，**切音轨会闪一下 0**。
**处理**：`.loading` 期间冻结进度显示（保留最后一次有效值），不要直绑。

**坑 3：ASS 覆盖标签只支持一部分**
源码 `Subtitles/SubtitleRectText.swift` 明确列出支持集：
`\c` / `\1c`（BGR）/ `\b` / `\i` / `\u` / `\s` / `\fn` / `\fs` / `\r` / `\an` / `\pos` / `\N` / `\n` / `\h`。
**明确不支持**（源码注释原文「left alone」）：`\fad`（淡入淡出）、`\bord`（描边）、`\shad`（阴影）、`\fscx` / `\fsc`（缩放）、`\fsp`（字距）、`\iclip`。
实测确认：`\pos(960,120)` → `(0.5, 0.1111)` 精确、`\an7` → alignment 7、`\c&H0000FF&` → `#FF0000`（BGR→RGB 正确）、`\b1` → bold。
**但 `\fad` 被完全丢弃，样式级 `Alignment` 也不映射到 placement**（只有行内 `\an`/`\pos` 生效）。

→ **对字幕 UI 的影响**：简单字幕（SRT/基本 ASS）够用；**带特效的动漫 ASS 会丢失淡入淡出与描边**。这是选型已知代价，v1.0 接受；若后续成为问题，可在自绘层补渲染。

**坑 4：`setSoftwareSubtitleDelay` 不影响 `$subtitleCues`**
该 API **只作用于 software PiP 合成路径**。Prism 自绘字幕时，
**必须自己对 `clock.sourceTime` 施加偏移**，不能依赖引擎。

#### 命令行工具特别注意

`AetherEngine` 是 `@MainActor`。Swift 的 `async main` 走 `dispatch_main()`，
**只排空主队列、不跑 CFRunLoop**，AVPlayer 的 periodic observer 永不触发 →
`clock.sourceTime` 永远停在 0，看起来像「播放没起来」。
命令行工具必须用 `RunLoop.main.run(until:)` 泵主线程。
（GUI App 无此问题，但写诊断工具时会踩。）

---

## 4. PrismData

```swift
public actor MediaCache {           // GRDB
    public func upsert(items: [MediaItem], serverId: String) throws
    public func items(query: CacheQuery) throws -> [MediaItem]
    public func item(id: String) throws -> MediaItem?
    public func saveProgress(_ p: PlaybackProgress) throws
    public func progress(itemId: String) throws -> PlaybackProgress?
    public func pendingProgress() throws -> [PlaybackProgress]   // 离线补报
    public func purge(serverId: String) throws
}

public protocol ImageLoading: Sendable {
    func image(for request: ImageRequest) async throws -> PlatformImage
    func prefetch(_ requests: [ImageRequest], limit: Int) async
    func clearMemoryCache()
}

public actor SessionStore {          // Keychain + UserDefaults
    public func save(_ session: AuthSession) throws
    public func loadAll() throws -> [AuthSession]
    public func active() throws -> AuthSession?
    public func remove(serverId: String) throws
}

public actor ProgressReporter {      // 依赖 EmbyClient + MediaCache
    public func start(itemId:item:method:position:) async
    public func tick(position:isPaused:) async
    public func stop(position:) async
    public func flushPending() async     // 启动时补报离线进度
}
```

---

## 5. PrismUI

### 5.1 设计系统 token（`DesignSystem/Tokens.swift`）

```swift
enum Spacing { static let xs: CGFloat = 4; sm = 8; md = 12; lg = 16; xl = 24; xxl = 32 }
enum Radius  { static let card: CGFloat = 10; poster = 8; panel = 14 }
enum Typography { static let titleLarge, title, headline, body, caption, monoTime }
enum Palette { static let accent, surface, surfaceElevated, separator, textPrimary, textSecondary, scrim }
enum Motion  { static let quick: Double = 0.15; standard = 0.25; slow = 0.4 }
```

### 5.2 路由

```swift
public enum Route: Hashable, Sendable {
    case home
    case library(id: String, type: ItemType)
    case search
    case downloads
    case settings(SettingsTab)
    case detail(itemId: String)
    case player(itemId: String, mediaSourceId: String?, resumeAt: Ticks)
}
```

### 5.3 视图模型规范

```swift
@MainActor @Observable
public final class LibraryViewModel {
    public private(set) var state: LoadState<[MediaItem]>   // idle/loading/loaded/empty/failed(EmbyError)
    public private(set) var isLoadingMore: Bool
    public var sort: SortOption
    public var filters: FilterSet
    public func loadFirstPage() async
    public func loadMoreIfNeeded(currentItem: MediaItem) async
    public func refresh() async
}
```

**规则**：VM 不 import SwiftUI；VM 通过构造注入 `EmbyClient` 与 `MediaCache` 协议，便于预览与测试。

---

## 6. 演示模式（Demo Mode）

由于真实服务器由用户后置提供，v1 开发期必须内置可切换的 **Demo Mode**：

- 启动参数 `-DemoMode YES` 或设置项「演示模式」启用。
- `Sources/EmbyAPI/Fixtures/` 存放录制的 JSON（Views/Items/Resume/Detail/Episodes/PlaybackInfo）。
- `MockEmbyClient` 实现与 `EmbyClient` 相同的调用面，按端点返回 fixture，可注入延迟与错误（`.timeout` / `.unauthorized` / 空库）。
- Demo 播放使用打包进 App 的 5 秒测试视频（H.264 + 内嵌 ASS 字幕），走真实 `MPVEngine`，保证播放链路可验证。
- **手动地址登录始终是一等公民**：欢迎页第一屏就有「输入服务器地址」，不依赖发现。

---

## 7. 测试约定

- 每个模块一个测试 target：`PrismCoreTests` / `EmbyAPITests` / `PrismDataTests` / `PrismPlaybackTests`。
- 网络测试一律走 `URLProtocol` 桩，禁止真实网络。
- 解码测试用 `Sources/EmbyAPI/Fixtures/*.json`，字段缺失必须不崩（全部 optional 或自定义 `init(from:)` 兜底）。
- UI 用 `#Preview` 覆盖三态：有数据 / 空 / 错误。
