import Foundation
import PrismCore
import Testing
@testable import PrismPlayback

// MARK: - B 层：集成（需要真实视频 + 主 run loop，可跳过）

/// 集成测试的素材与环境探测。
///
/// 素材来自 T1.8 spike：`.spike/engine/media/bbb_720_10s_1MB.mkv`
/// （H.264 1280×720，**无音轨**，10.000s，939 KB，见 `docs/research/playback-spike-results.md` §1）。
/// `.spike/` 被 `.gitignore` 忽略，所以**新克隆的仓库里没有它**——测试会自动跳过。
enum EngineIntegrationFixture {
    /// 素材路径（相对仓库根）。
    static var mediaURL: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PrismPlaybackTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let url = root
            .appendingPathComponent(".spike")
            .appendingPathComponent("engine")
            .appendingPathComponent("media")
            .appendingPathComponent("bbb_720_10s_1MB.mkv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 素材是否可用（作为 `.enabled(if:)` 的开关）。
    static var isAvailable: Bool { mediaURL != nil }

    /// 期望时长（秒）。ffprobe 实测 `duration=10.000000`。
    static let expectedDuration: Double = 10
}

/// 在异步上下文里等待某个条件成立。
///
/// 为什么不再泵 `RunLoop.main`：spike 的 `RunLoopPump` 是给**命令行可执行文件**用的
/// （`async main` → `dispatch_main()` 不跑 CFRunLoop，必须主线程手动泵）。
/// Swift Testing 里测试体本身就是主 actor 上的异步任务，同步阻塞主线程会让
/// `Task { @MainActor }` 的续体永远排不上，实测表现是「一条事件都收不到」。
/// 所以这里改成纯异步等待：让出主 actor，由测试进程自己的 run loop 驱动 AVPlayer 的观察者。
///
/// - Parameters:
///   - seconds: 最长等待时间。
///   - condition: 条件。
/// - Returns: 条件是否在超时前成立。
@MainActor
func waitUntil(timeout seconds: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// 把适配器的事件流收进一个数组（消费者在主 actor 上）。
@MainActor
final class EngineEventRecorder {
    private(set) var events: [PlaybackEvent] = []

    /// 起一个消费者任务。
    ///
    /// - Parameter stream: 事件流。
    /// - Returns: 消费任务（测试结束时取消）。
    func consume(_ stream: AsyncStream<PlaybackEvent>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            for await event in stream {
                self?.events.append(event)
            }
        }
    }

    /// 是否收到过某个状态。
    ///
    /// - Parameter state: 目标状态。
    func saw(_ state: PlaybackState) -> Bool {
        events.contains { $0.state == state }
    }

    /// 收到过的最后一个时长。
    var lastDuration: Ticks? {
        for event in events.reversed() {
            switch event {
            case .durationChanged(let duration): return duration
            case .positionChanged(_, let duration) where duration > .zero: return duration
            default: continue
            }
        }
        return nil
    }

    /// 收到过的最后一个位置。
    var lastPosition: Ticks? {
        for event in events.reversed() {
            if case .positionChanged(let position, _) = event { return position }
        }
        return nil
    }

    /// 收到过的音轨列表。
    var audioTracks: [TrackInfo] {
        for event in events.reversed() {
            if case .tracksChanged(let audio, _) = event { return audio }
        }
        return []
    }

    /// 是否收到过失败。
    var failure: PlaybackFailure? {
        for event in events {
            if case .failed(let failure) = event { return failure }
        }
        return nil
    }
}

@Suite(
    "AetherEngineAdapter 集成（B 层，缺素材时跳过）",
    .enabled(if: EngineIntegrationFixture.isAvailable)
)
@MainActor
struct EngineIntegrationTests {

    @Test("真实 MKV：加载 → playing，duration ≈ 10s（坑 1）", .timeLimit(.minutes(1)))
    func loadsRealFile() async throws {
        let url = try #require(
            EngineIntegrationFixture.mediaURL,
            "缺少 .spike/engine/media/bbb_720_10s_1MB.mkv，跳过集成测试（见 docs/research/playback-spike-results.md §1 的 curl 命令）"
        )

        let adapter = try AetherEngineAdapter()
        let recorder = EngineEventRecorder()
        let consumer = recorder.consume(adapter.events)
        defer { consumer.cancel() }

        try await adapter.load(PlaybackRequest(url: url, method: .directPlay))
        #expect(recorder.failure == nil)

        // 起播：实测 92–151ms，给足 20s 余量
        let playing = await waitUntil(timeout: 20) { recorder.saw(.playing) }
        #expect(playing, "20s 内没有进入 .playing")

        // 坑 1：duration 由 $duration 观察者补发，load() 返回时还是 0
        _ = await waitUntil(timeout: 10) { (recorder.lastDuration ?? .zero) > .zero }
        let duration = try #require(recorder.lastDuration, "没有收到 durationChanged")
        #expect(
            abs(duration.seconds - EngineIntegrationFixture.expectedDuration) < 0.5,
            "duration = \(duration.seconds)s，期望 ≈ \(EngineIntegrationFixture.expectedDuration)s"
        )

        await adapter.stop()
        #expect(adapter.currentState == .idle)
    }

    @Test("加载不存在的文件会失败，且失败分类不是 .cancelled", .timeLimit(.minutes(1)))
    func loadFailureSurfaces() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/prism-engine-test.mkv")
        let adapter = try AetherEngineAdapter()
        let recorder = EngineEventRecorder()
        let consumer = recorder.consume(adapter.events)
        defer { consumer.cancel() }

        var threw = false
        do {
            try await adapter.load(PlaybackRequest(url: missing, method: .directPlay))
        } catch {
            threw = true
        }
        #expect(threw, "加载不存在的文件没有抛错")

        _ = await waitUntil(timeout: 5) { recorder.failure != nil }
        let failure = try #require(recorder.failure, "没有收到 .failed 事件")
        #expect(failure.kind != .cancelled)
        #expect(adapter.currentState.isTerminal)
    }

    @Test("seek 之后补发位置；音量 / 速率被钳制且不崩溃", .timeLimit(.minutes(1)))
    func transportControls() async throws {
        let url = try #require(EngineIntegrationFixture.mediaURL)

        let adapter = try AetherEngineAdapter()
        let recorder = EngineEventRecorder()
        let consumer = recorder.consume(adapter.events)
        defer { consumer.cancel() }

        try await adapter.load(PlaybackRequest(url: url, method: .directPlay))
        _ = await waitUntil(timeout: 20) { recorder.saw(.playing) }

        await adapter.seek(to: Ticks(seconds: 5))
        let landed = await waitUntil(timeout: 10) {
            (recorder.lastPosition ?? .zero).seconds >= 4.5
        }
        let position = try #require(recorder.lastPosition, "seek 之后没有位置事件")
        #expect(landed, "seek 落点 \(position.seconds)s，期望 ≈ 5s")

        // 引擎把速率钳到 maxSupportedRate（视频 2.0）
        #expect(adapter.maxRate <= 3.0)
        await adapter.setRate(4.0)
        await adapter.setVolume(2.0)
        await adapter.setVolume(-1.0)

        await adapter.stop()
        #expect(adapter.currentState == .idle)
    }
}
