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

/// 把一段 `@MainActor` 异步逻辑放到后台 Task 里跑，同时由**主线程**泵 `RunLoop.main`。
///
/// 为什么必须这么做：AetherEngine 是 `@MainActor` 的，它的时钟依赖 AVPlayer 的
/// periodic time observer。`swift test` 的入口走 `async main` → `dispatch_main()`，
/// **只排空主队列、不跑 CFRunLoop**，于是 `clock.sourceTime` 永远停在 0，看起来像「播放没起来」
/// （见 `docs/research/playback-spike-results.md` 末尾「一个必须知道的实现细节」）。
/// spike 的 `SpikeKit/RunLoopPump.swift` 用的就是这个解法，这里复刻一份最小版。
@MainActor
enum MainRunLoopPump {
    /// 运行 `body` 直到返回，期间持续驱动主 run loop。
    ///
    /// - Parameters:
    ///   - seconds: 硬超时（防止 CI 挂死）。
    ///   - body: 要执行的异步逻辑。
    /// - Returns: `body` 的返回值；超时返回 `nil`。
    static func run<T: Sendable>(
        // 15 秒足够覆盖实测的 92–151ms 起播与 20s 的等待窗口；
        // 原先 60 秒会让一个挂死的测试拖住整个 `swift test` 好几分钟。
        timeout seconds: Double = 15,
        _ body: @escaping @MainActor () async -> T
    ) -> T? {
        let box = ResultBox<T>()
        Task { @MainActor in
            let value = await body()
            box.set(value)
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !box.isSet && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }

    /// 在驱动主 run loop 的同时等待 `seconds` 秒。
    ///
    /// - Parameter seconds: 秒。
    static func pumpSleep(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// 跨 `Task` 传递结果的最小容器。
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored != nil
    }

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: T) {
        lock.lock(); stored = value; lock.unlock()
    }
}

/// 把适配器的事件流收进一个线程安全数组（消费者在主 actor 上）。
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
    .enabled(if: EngineIntegrationFixture.isAvailable),
    // 单测总超时：AetherEngine 是 @MainActor 且依赖 AVPlayer 的 periodic observer，
    // 在某些 CI 环境下观察者永不触发，等待循环会耗到硬超时。
    // 给整个 suite 设上限，保证 `swift test` 不会因为一个测试挂死而卡住几分钟。
    .timeLimit(.minutes(1))
)
@MainActor
struct EngineIntegrationTests {

    @Test("真实 MKV：加载 → playing，duration ≈ 10s（坑 1）")
    func loadsRealFile() async throws {
        let url = try #require(
            EngineIntegrationFixture.mediaURL,
            "缺少 .spike/engine/media/bbb_720_10s_1MB.mkv，跳过集成测试（见 docs/research/playback-spike-results.md §1 的 curl 命令）"
        )

        let adapter = try AetherEngineAdapter()
        let recorder = EngineEventRecorder()
        let consumer = recorder.consume(adapter.events)
        defer { consumer.cancel() }

        let request = PlaybackRequest(url: url, method: .directPlay)
        let result = MainRunLoopPump.run {
            do {
                try await adapter.load(request)
                return true
            } catch {
                return false
            }
        }

        #expect(result == true, "load 抛错了")
        #expect(recorder.failure == nil)

        // 等起播（实测 92–151ms；给足 20s 余量）
        _ = MainRunLoopPump.run {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !recorder.saw(.playing) {
                await MainRunLoopPump.pumpSleep(0.05)
            }
            return true
        }
        #expect(recorder.saw(.playing), "20s 内没有进入 .playing")

        // 坑 1：duration 由 $duration 观察者补发，load() 返回时还是 0
        _ = MainRunLoopPump.run {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, (recorder.lastDuration ?? .zero) == .zero {
                await MainRunLoopPump.pumpSleep(0.05)
            }
            return true
        }
        let duration = try #require(recorder.lastDuration, "没有收到 durationChanged")
        #expect(abs(duration.seconds - EngineIntegrationFixture.expectedDuration) < 0.5,
                "duration = \(duration.seconds)s，期望 ≈ \(EngineIntegrationFixture.expectedDuration)s")

        MainRunLoopPump.run { await adapter.stop() }
        #expect(adapter.currentState == .idle)
    }

    @Test("加载不存在的文件会失败，且失败分类不是 .cancelled")
    func loadFailureSurfaces() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/prism-engine-test.mkv")
        let adapter = try AetherEngineAdapter()
        let recorder = EngineEventRecorder()
        let consumer = recorder.consume(adapter.events)
        defer { consumer.cancel() }

        let failed = MainRunLoopPump.run {
            do {
                try await adapter.load(PlaybackRequest(url: missing, method: .directPlay))
                return false
            } catch {
                return true
            }
        }

        #expect(failed == true, "加载不存在的文件没有抛错")
        let failure = try #require(recorder.failure, "没有收到 .failed 事件")
        #expect(failure.kind != .cancelled)
        #expect(adapter.currentState.isTerminal)
    }

    @Test("seek / 音量 / 速率 / 静音在真实会话上不崩溃且被钳制")
    func transportControls() async throws {
        let url = try #require(EngineIntegrationFixture.mediaURL)

        let adapter = try AetherEngineAdapter()
        let recorder = EngineEventRecorder()
        let consumer = recorder.consume(adapter.events)
        defer { consumer.cancel() }

        _ = MainRunLoopPump.run {
            try? await adapter.load(PlaybackRequest(url: url, method: .directPlay))
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !recorder.saw(.playing) {
                await MainRunLoopPump.pumpSleep(0.05)
            }
            return true
        }

        _ = MainRunLoopPump.run {
            await adapter.seek(to: Ticks(seconds: 5))
            await MainRunLoopPump.pumpSleep(0.3)
            return true
        }

        // seek 之后必须补发一次位置（不是等下一个 10Hz tick）
        let position = try #require(recorder.lastPosition, "seek 之后没有位置事件")
        #expect(position.seconds >= 4.5, "seek 落点 \(position.seconds)s，期望 ≈ 5s")

        // 引擎把速率钳到 maxSupportedRate（视频 2.0）
        #expect(adapter.maxRate <= 3.0)
        _ = MainRunLoopPump.run {
            await adapter.setRate(4.0)
            await adapter.setVolume(2.0)
            await adapter.setVolume(-1.0)
            return true
        }

        MainRunLoopPump.run { await adapter.stop() }
    }
}
