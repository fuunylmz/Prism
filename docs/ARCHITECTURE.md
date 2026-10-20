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
         └── PrismPlayback → PrismCore
```

**铁律**
- 依赖只能向下，禁止反向或环状。`PrismPlayback` 不得 import `EmbyAPI`（播放地址由上层传入）。
- `PrismUI` 之外的模块不得 import SwiftUI（`PrismPlayback` 只暴露 `NSView`）。
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
    var body: Encodable? { get }
    var requiresAuth: Bool { get }
    var timeout: TimeInterval? { get }
}
```

### 2.2 端点集（P0）

| 方法 | 路径 | 用途 |
|---|---|---|
| `publicInfo()` | `/System/Info/Public` | 连接校验、服务器名/版本 |
| `authenticate(username:password:)` | `/Users/AuthenticateByName` | 登录拿 AccessToken |
| `currentUser()` | `/Users/Me` | 恢复会话 |
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
    @MainActor var renderView: NSView { get }        // 嵌入 SwiftUI 的 NSViewRepresentable
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

| 我们的协议 | AetherEngine | 适配要点 |
|---|---|---|
| `load(_:)` | `try await player.load(url:startPosition:options:)` | `PlaybackRequest.headers` → `options.httpHeaders`（Emby 鉴权头） |
| `play()` / `pause()` | `player.play()` / `player.pause()` | 直接映射 |
| `seek(to:)` | `await player.seek(to: seconds)` | `Ticks` → `Double` 秒 |
| `setRate(_:)` | `player.setRate(_:)` | 上限受 `player.maxSupportedRate` 约束（视频 2x） |
| `setVolume(_:)` | **AetherEngine 无音量 API** | 用 `AVAudioEngine`/系统音量或加一层 `MPVolumeView` 等价物 → 标【待验证】 |
| `selectAudioTrack(_:)` | `player.selectAudioTrack(index:)` | 直接用 `MediaStream.index` |
| `selectSubtitleTrack(_:)` | `player.selectSubtitleTrack(index:)` / `clearSubtitle()` | `nil` → `clearSubtitle()` |
| `events` | `player.$state` / `$errorInfo` 是 **Combine `@Published`** | **需要桥接**：`AsyncStream` + `publisher.values`，或用 `for await` |
| `renderView` | `AetherPlayerSurface(engine:)`（SwiftUI）或 `AetherPlayerView`（AppKit） | SwiftUI 直接嵌入，**不需要 `NSViewRepresentable`** |
| 音轨/字幕列表 | `player.subtitleTracks`（`[TrackInfo]`）等 | 映射为我们的 `TrackInfo` |
| 字幕延迟 | `player.subtitleCues` 提供 cue 与位置 | 延迟设置需查实际 API → 标【待验证】 |
| PiP / AirPlay / Now Playing | **引擎原生支持** | 不再需要 T3.5 的自研工作，改为「接线 + 元数据注入」 |

**待验证项**（M3 集成时确认）：音量控制方式、字幕延迟 API、`maxSupportedRate` 的实际约束、
`$state` 的 Combine 桥接在 Swift 6 严格并发下的 `Sendable` 处理。

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
