import Foundation
import Observation
import PrismCore
import EmbyAPI
import PrismPlayback
import SwiftUI

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

    /// 本次播放的起播位置。
    ///
    /// 用途：引擎刚 attach、还没收到第一条 `.positionChanged` 时 `playerModel.position`
    /// 仍是 0；这时退出会把续播点写成 0，用户「继续观看」的进度就被清掉了。
    private var lastKnownStartPosition: Ticks = .zero

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
    public func play(
        itemId: String,
        mediaSourceId: String? = nil,
        resumeAt: Ticks,
        session: PrismSession
    ) async {
        await stop()

        preparationState = .fetching
        do {
            let item = try await fetchItem(itemId: itemId, session: session)
            title = item.name
            subtitle = subtitleText(for: item)

            preparationState = .negotiating
            let plan = try await makePlan(
                item: item,
                mediaSourceId: mediaSourceId,
                resumeAt: resumeAt,
                session: session
            )
            lastKnownStartPosition = plan.startPosition

            preparationState = .loading
            try await loadIntoEngine(plan: plan, session: session)

            preparationState = .ready
            await startReporting(item: item, plan: plan, session: session)
        } catch {
            let message = (error as? EmbyError).map { String(localized: $0.userMessage) } ?? error.localizedDescription
            preparationState = .failed(message)
            // 引擎没 attach 时 `playerModel.renderView` 是空的，界面只会显示「等待播放引擎…」。
            // 把失败同步给播放器模型，用户才能看到原因和「重试」。
            playerModel.reportPreparationFailure(message)
        }
    }

    /// 停止播放并清理资源。
    ///
    /// 顺序很重要：**先停引擎**（用户已经关掉播放器，声音必须立刻停），
    /// 再发最后一次 `Stopped`。反过来会先 `await` 一次 HTTP POST：
    /// 服务器卡住时默认超时要等 30 秒，那段时间画面已经消失、声音还在放。
    /// 位置在停引擎之前抓快照，保证上报的是最后看到的播放位置。
    public func stop() async {
        let lastPosition = max(playerModel.position, lastKnownStartPosition)
        playerModel.onPositionUpdate = nil
        playerModel.onPlaybackStateChange = nil

        if let engine {
            await playerModel.detach()
            await engine.stop()
            self.engine = nil
        }

        if let reporter {
            self.reporter = nil
            // 上报不阻塞界面：网络失败也只是丢一条统计。
            Task { await reporter.stop(position: lastPosition) }
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
        mediaSourceId: String?,
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

        // `startTimeTicks` 必须一起传：否则服务端总是从 0 建会话，
        // 转码流的第一帧就是片头，客户端再 seek 一次会明显卡顿。
        let info = try await session.client.playbackInfo(
            itemId: item.id,
            userId: session.userId,
            profile: .prismMacOS(),
            startTimeTicks: resumeAt > .zero ? resumeAt : nil,
            mediaSourceId: mediaSourceId
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
        // 转码流的起点由 URL 的 `StartTimeTicks` 决定，引擎再 seek 一次会变成
        // 双重偏移（先跳到起点，再按相对位置跳）。直连 / 直封是静态流，必须由引擎 seek。
        let engineStart: Ticks = plan.method == .transcode ? .zero : plan.startPosition
        let request = PlaybackRequest(
            url: plan.url,
            method: plan.method,
            headers: plan.headers,
            startPosition: engineStart,
            audioStreamIndex: plan.audioStreamIndex,
            subtitleStreamIndex: plan.subtitleStreamIndex
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

        // 位置推进时驱动上报。上报器内部做「10 秒 + 交互即时」的节流与去重，
        // 所以这里可以放心地把引擎 4Hz 的位置全推过去。
        playerModel.onPositionUpdate = { [weak self] position, isPaused in
            guard let self else { return }
            Task { await self.reportPosition(position, isPaused: isPaused) }
        }

        // 暂停 / 恢复必须单独上报：暂停后引擎不再发位置事件，
        // 只靠位置回调永远不会触发 `Pause`，服务器会把续播点一路推到片尾。
        playerModel.onPlaybackStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .paused:
                Task { await self.reportInteraction(.pause) }
            case .playing:
                Task { await self.reportInteraction(.unpause) }
            case .ended:
                // 播完要落一次 Stopped，否则服务器会一直认为会话还在播放。
                Task { await self.finishReporting() }
            case .idle, .loading, .buffering, .failed:
                break
            }
        }
    }

    /// 自然播完时结束会话上报（只发一次，避免与 `stop()` 重复）。
    private func finishReporting() async {
        guard let reporter else { return }
        self.reporter = nil
        await reporter.stop(position: playerModel.position)
    }

    /// 转发一次位置上报。
    private func reportPosition(_ position: Ticks, isPaused: Bool) async {
        await reporter?.report(position: position, isPaused: isPaused)
    }

    /// 上报一次「交互」（暂停 / 恢复 / 跳转 / 切轨）。
    ///
    /// 这些场景位置可能没变，`report` 会被去重规则吞掉，必须走 `reportInteraction`。
    public func reportInteraction(_ event: ProgressEvent) async {
        guard let reporter else { return }
        await reporter.reportInteraction(
            event,
            position: playerModel.position,
            isPaused: playerModel.state == .paused
        )
    }

    private func subtitleText(for item: MediaItem) -> String? {
        guard item.type == .episode else { return nil }
        let season = item.parentIndexNumber ?? 0
        let episode = item.indexNumber ?? 0
        let code = String(format: "S%02dE%02d", season, episode)
        return "\(code) · \(item.name)"
    }
}
