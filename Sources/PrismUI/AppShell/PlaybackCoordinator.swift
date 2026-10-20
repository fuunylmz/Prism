import Foundation
import Observation
import PrismCore
import EmbyAPI
import PrismPlayback
import SwiftUI

// MARK: - 类型消歧
//
// macOS 27 SDK 的 Foundation 新增了 `Foundation.ProgressReporter`
// （与 Xcode 的进度上报机制相关，`@available(macOS 27, *)`），
// 与本模块依赖的 `PrismPlayback.ProgressReporter` 撞名。
// 用别名固定指向播放层那一个，避免每个使用点都要写模块限定。
private typealias PlaybackProgressReporter = PrismPlayback.ProgressReporter

// MARK: - 播放编排

/// 把「点播放」到「真正出画面」之间的所有环节串起来。
///
/// 链路：
/// ```
/// Route.player(itemId:)
///   → 取 MediaItem + PlaybackInfo          (EmbyClient)
///   → 协商：直连 / 直封 / 转码              (PlaybackNegotiator)
///   → 加载到引擎                            (PlaybackEngine)
///   → 上报进度                              (ProgressReporter)
///   → 驱动 PlayerView                       (PlayerViewModel)
/// ```
///
/// **为什么需要这一层**：`PlayerView` 只认识 `PlayerViewModel`（UI 状态），
/// 引擎只认识 `PlaybackRequest`（URL + 头），协商层只认识 `MediaItem` + `PlaybackInfoResponse`。
/// 这三者之间需要一个编排者，就是这里。放在 `AppShell/` 是因为它同时依赖
/// PrismPlayback 与 PrismUI，属于「外壳级装配」，不属于任何单一页面。
@MainActor
@Observable
public final class PlaybackCoordinator {
    /// 播放器 UI 状态。
    public let playerModel = PlayerViewModel()

    /// 当前加载状态（给 UI 显示「正在准备播放…」）。
    public private(set) var preparationState: PreparationState = .idle

    /// 正在播放的条目标题（给 PlayerView 的标题栏）。
    public private(set) var title: String = ""
    /// 副标题（剧集显示「S01E02 · 集名」）。
    public private(set) var subtitle: String?

    /// 当前引擎（每次播放新建；`stop` 后置空）。
    private var engine: AetherEngineAdapter?
    /// 当前进度上报器。
    private var reporter: PlaybackProgressReporter?

    /// 准备阶段的状态。
    public enum PreparationState: Sendable, Equatable {
        case idle
        case fetching
        case negotiating
        case loading
        case ready
        case failed(String)
    }

    public init() {}

    /// 开始播放一个条目。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - resumeAt: 续播位置；`.zero` 表示从头。
    ///   - session: 当前会话（提供 client / userId / 是否演示）。
    public func play(itemId: String, resumeAt: Ticks, session: PrismSession) async {
        await stop()

        preparationState = .fetching
        do {
            let item = try await fetchItem(itemId: itemId, session: session)
            title = item.name
            subtitle = subtitleText(for: item)

            preparationState = .negotiating
            let plan = try await makePlan(item: item, resumeAt: resumeAt, session: session)

            preparationState = .loading
            try await loadIntoEngine(plan: plan, session: session)

            preparationState = .ready
            await startReporting(item: item, plan: plan, session: session)
        } catch {
            let message = (error as? EmbyError).map { String(localized: $0.userMessage) } ?? error.localizedDescription
            preparationState = .failed(message)
        }
    }

    /// 停止播放并清理资源。
    ///
    /// 顺序很重要：先让引擎 `stop()`（释放解码器），再停止上报（最后一次 `Stopped`），
    /// 否则上报器可能拿不到最终位置。
    public func stop() async {
        if let reporter {
            await reporter.stop(position: playerModel.position)
            self.reporter = nil
        }
        if let engine {
            await playerModel.detach()
            await engine.stop()
            self.engine = nil
        }
        preparationState = .idle
    }

    // MARK: 内部步骤

    private func fetchItem(itemId: String, session: PrismSession) async throws -> MediaItem {
        if session.isDemo {
            return try await DemoEmbyClient.shared.itemDetail(
                userId: DemoDataSources.userId,
                itemId: itemId
            )
        }
        return try await session.client.itemDetail(userId: session.userId, itemId: itemId)
    }

    private func makePlan(
        item: MediaItem,
        resumeAt: Ticks,
        session: PrismSession
    ) async throws -> PlaybackPlan {
        // 演示模式：直接用合成样片，跳过协商（没有真实服务器可协商）。
        if session.isDemo {
            guard let url = try? await DemoPlaybackAsset.shared.sampleVideoURL() else {
                throw EmbyError.notFound
            }
            return PlaybackPlan(
                method: .directPlay,
                url: url,
                headers: [:],
                mediaSourceId: item.id,
                playSessionId: nil,
                startPosition: resumeAt,
                audioStreamIndex: nil,
                subtitleStreamIndex: nil,
                duration: item.runTime,
                reason: .directPlaySupported
            )
        }

        let info = try await session.client.playbackInfo(
            itemId: item.id,
            userId: session.userId,
            profile: .prismMacOS()
        )
        // `baseURL` 是必填：Emby 返回的 DirectStreamUrl / TranscodingUrl 是相对路径，
        // 没有服务器根地址产不出可播的绝对 URL。
        // `authHeaders` 兜底：URL 里没有 api_key 时靠它带上鉴权头。
        let negotiator = PlaybackNegotiator(
            profile: .prismMacOS(),
            settings: PlaybackPreferences(),
            baseURL: session.server.baseURL,
            authHeaders: ["X-Emby-Token": session.accessToken]
        )
        return try negotiator.negotiate(
            item: item,
            info: info,
            startPosition: resumeAt,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
    }

    private func loadIntoEngine(plan: PlaybackPlan, session: PrismSession) async throws {
        let adapter = try AetherEngineAdapter()
        let request = PlaybackRequest(
            url: plan.url,
            method: plan.method,
            headers: plan.headers,
            startPosition: plan.startPosition
        )
        try await adapter.load(request)
        await playerModel.attach(engine: adapter)
        engine = adapter
    }

    private func startReporting(item: MediaItem, plan: PlaybackPlan, session: PrismSession) async {
        // 演示模式不上报（没有真实服务器）。
        guard !session.isDemo else { return }

        let reporter = PlaybackProgressReporter(
            client: session.client,
            userId: session.userId,
            itemId: item.id,
            method: plan.method,
            mediaSourceId: plan.mediaSourceId,
            playSessionId: plan.playSessionId
        )
        await reporter.start(position: plan.startPosition)
        self.reporter = reporter
    }

    private func subtitleText(for item: MediaItem) -> String? {
        guard item.type == .episode else { return nil }
        let season = item.parentIndexNumber ?? 0
        let episode = item.indexNumber ?? 0
        let code = String(format: "S%02dE%02d", season, episode)
        return "\(code) · \(item.name)"
    }
}
