import EmbyAPI
import Foundation
import PrismCore
import Testing

@testable import PrismPlayback

// MARK: - 三端点

@Suite("ProgressReporter：三个上报端点")
struct ProgressReporterEndpointTests {
    @Test("start 发 POST /Sessions/Playing，body 带 ItemId / MediaSourceId / PlayMethod / PositionTicks")
    func startPostsToPlaying() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: Ticks(seconds: 120))

        #expect(server.requestCount == 1)
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/Sessions/Playing")
        #expect(request.string("ItemId") == "item-1")
        #expect(request.string("MediaSourceId") == "source-1")
        #expect(request.string("PlaySessionId") == "session-1")
        #expect(request.string("PlayMethod") == "DirectPlay")
        #expect(request.integer("PositionTicks") == Ticks(seconds: 120).rawValue)

        let started = await reporter.isStarted
        #expect(started)
    }

    @Test("PlayMethod 跟随 PlaybackMethod：directStream / transcode 映射正确")
    func playMethodFollowsPlaybackMethod() async throws {
        for (method, expected) in [
            (PlaybackMethod.directPlay, "DirectPlay"),
            (PlaybackMethod.directStream, "DirectStream"),
            (PlaybackMethod.transcode, "Transcode")
        ] {
            let server = ProgressStubServer()
            let client = await ProgressTestFactory.client(for: server)
            let reporter = ProgressTestFactory.reporter(
                client: client,
                clock: MutableClock(),
                method: method
            )
            await reporter.start(position: .zero)
            let request = try #require(server.requests.first)
            #expect(request.string("PlayMethod") == expected)
        }
    }

    @Test("report 发 POST /Sessions/Playing/Progress，EventName = TimeUpdate")
    func reportPostsToProgress() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        clock.advance(by: 10)
        await reporter.report(position: Ticks(seconds: 10), isPaused: false)

        #expect(server.requestCount == 2)
        let request = try #require(server.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/Sessions/Playing/Progress")
        #expect(request.string("EventName") == "TimeUpdate")
        #expect(request.bool("IsPaused") == false)
        #expect(request.string("PlayMethod") == "DirectPlay")
        #expect(request.integer("PositionTicks") == Ticks(seconds: 10).rawValue)
    }

    /// **核心回归测试**：停止上报必须是 14 字段的 `PlaybackStopInfo`，
    /// 不能因为「官方文档说 Stopped 与 Start 完全相同」就误用 30 字段结构。
    ///
    /// 断言分三层：
    /// 1. 路径是 `/Sessions/Playing/Stopped`；
    /// 2. 请求体的**全部 key 是 14 字段 schema 的子集**（将来有人往 `PlaybackStopReport`
    ///    里加字段，这条会先失败）；
    /// 3. 逐个点名 8 个「绝不该出现」的字段，失败信息直接说出是哪个字段漏了进来。
    @Test("stop 发 POST /Sessions/Playing/Stopped，且 body 里没有 PlayMethod / IsPaused")
    func stopPostsToStoppedWithoutProgressFields() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        clock.advance(by: 5)
        await reporter.stop(position: Ticks(seconds: 5))

        #expect(server.requestCount == 2)
        let stopped = try #require(server.requests.last)
        #expect(stopped.httpMethod == "POST")
        #expect(stopped.path == "/Sessions/Playing/Stopped")

        // 必需字段。
        #expect(stopped.string("ItemId") == "item-1")
        #expect(stopped.string("MediaSourceId") == "source-1")
        #expect(stopped.string("PlaySessionId") == "session-1")
        #expect(stopped.integer("PositionTicks") == Ticks(seconds: 5).rawValue)

        // ② 整个 key 集合必须是 `PlaybackStopInfo` 14 字段的子集。
        //    来源：https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html
        let documentedStopKeys: Set<String> = [
            "ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks",
            "Failed", "IsAutomated", "NextMediaType", "LiveStreamId",
            "PlaylistIndex", "PlaylistLength", "PlaylistItemId",
            "NowPlayingQueue", "SessionId", "Item"
        ]
        #expect(
            stopped.bodyKeys.isSubset(of: documentedStopKeys),
            "Stopped 请求体出现 schema 外字段：\(stopped.bodyKeys.subtracting(documentedStopKeys).sorted())"
        )

        // ③ 点名反证：这些字段只存在于 Start / Progress（30 字段）里。
        let forbidden: Set<String> = [
            "PlayMethod", "IsPaused", "CanSeek", "VolumeLevel",
            "AudioStreamIndex", "SubtitleStreamIndex", "EventName", "RunTimeTicks"
        ]
        let leaked = stopped.bodyKeys.intersection(forbidden)
        #expect(leaked.isEmpty, "Stopped 请求体不该包含：\(leaked.sorted())")

        // 对照组：同一个会话的 start 请求**确实**有这些字段——证明两组结构真的不同。
        let started = try #require(server.requests.first)
        #expect(started.path == "/Sessions/Playing")
        #expect(started.string("PlayMethod") == "DirectPlay")
        #expect(started.bool("IsPaused") == false)
        #expect(started.bodyKeys.isSuperset(of: ["PlayMethod", "IsPaused", "ItemId", "PositionTicks"]))
    }
}

// MARK: - 节流与去重

@Suite("ProgressReporter：节流 / 交互 / 去重")
struct ProgressReporterThrottleTests {
    @Test("10 秒节流：10 秒内连续 report 10 次只发 1 次")
    func throttlesToOncePerInterval() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        // 引擎以 1Hz 推位置，共 10 秒；每次都超过 1 秒去重阈值，只有时间窗口能拦。
        for step in 1...10 {
            clock.advance(by: 1)
            await reporter.report(position: Ticks(seconds: Double(step)), isPaused: false)
        }

        let progressCount = server.requests.filter { $0.path == "/Sessions/Playing/Progress" }.count
        #expect(progressCount == 1, "10 秒内应只发 1 次 Progress，实际 \(progressCount) 次")
        #expect(server.requestCount == 2, "总计应为 start + 1 次 progress")
    }

    @Test("交互立即上报：暂停不等 10 秒")
    func pauseReportsImmediately() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        clock.advance(by: 2)
        await reporter.report(position: Ticks(seconds: 2), isPaused: true)

        #expect(server.requestCount == 2)
        let pause = try #require(server.requests.last)
        #expect(pause.path == "/Sessions/Playing/Progress")
        #expect(pause.string("EventName") == "Pause")
        #expect(pause.bool("IsPaused") == true)

        // 恢复同样立即，且 EventName 是 Unpause。
        clock.advance(by: 2)
        await reporter.report(position: Ticks(seconds: 2), isPaused: false)
        #expect(server.requestCount == 3)
        #expect(server.requests.last?.string("EventName") == "Unpause")
        #expect(server.requests.last?.bool("IsPaused") == false)
    }

    @Test("切音轨 / 切字幕：位置没变也必须发")
    func trackChangeReportsImmediately() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: Ticks(seconds: 3))
        await reporter.reportInteraction(.audioTrackChange, position: Ticks(seconds: 3), isPaused: false)

        #expect(server.requestCount == 2)
        #expect(server.requests.last?.string("EventName") == "AudioTrackChange")

        await reporter.reportInteraction(.subtitleTrackChange, position: Ticks(seconds: 3), isPaused: false)
        #expect(server.requestCount == 3)
        #expect(server.requests.last?.string("EventName") == "SubtitleTrackChange")
    }

    @Test("去重：位置只变 0.5 秒 → 跳过（即使 10 秒窗口已过）")
    func deduplicatesTinyPositionChanges() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        clock.advance(by: 11)
        await reporter.report(position: Ticks(seconds: 0.5), isPaused: false)
        #expect(server.requestCount == 1, "位置只变 0.5s 应被去重")

        // 位置变化超过 1 秒、且 10 秒窗口已过 → 发。
        clock.advance(by: 1)
        await reporter.report(position: Ticks(seconds: 3), isPaused: false)
        #expect(server.requestCount == 2)
        #expect(server.requests.last?.integer("PositionTicks") == Ticks(seconds: 3).rawValue)
    }

    @Test("seek：位置跳变远超已流逝时间 → 立即上报，EventName 仍是 TimeUpdate")
    func seekReportsImmediately() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        clock.advance(by: 2)
        await reporter.report(position: Ticks(seconds: 2), isPaused: false)
        #expect(server.requestCount == 1, "正常播放 2 秒应被节流")

        clock.advance(by: 1)
        await reporter.report(position: Ticks(seconds: 600), isPaused: false)
        #expect(server.requestCount == 2, "seek 后应立即上报")
        #expect(server.requests.last?.string("EventName") == "TimeUpdate")
        #expect(server.requests.last?.integer("PositionTicks") == Ticks(seconds: 600).rawValue)
    }

    @Test("暂停期间位置不动：不会反复上报")
    func pausedDoesNotSpam() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: Ticks(seconds: 5))
        clock.advance(by: 1)
        await reporter.report(position: Ticks(seconds: 5), isPaused: true)   // Pause，立即
        #expect(server.requestCount == 2)

        for _ in 0..<5 {
            clock.advance(by: 10)
            await reporter.report(position: Ticks(seconds: 5), isPaused: true)
        }
        #expect(server.requestCount == 2, "暂停期间位置不变，不该再发")
    }
}

// MARK: - 离线补报

@Suite("ProgressReporter：离线补报")
struct ProgressReporterOfflineTests {
    @Test("网络失败 → 入队；恢复后 drain() 发出")
    func queuesOnFailureAndDrains() async throws {
        let server = ProgressStubServer(.offline())
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: Ticks(seconds: 30))
        #expect(server.requestCount == 1, "请求发出去了，但失败")

        let queued = await reporter.pendingReportCount()
        #expect(queued == 1, "失败的上报应进队列，实际 \(queued) 条")

        server.setOnline()
        await reporter.drain()

        let remaining = await reporter.pendingReportCount()
        #expect(remaining == 0)
        #expect(server.requestCount == 2)
        let replayed = try #require(server.requests.last)
        #expect(replayed.path == "/Sessions/Playing")
        #expect(replayed.string("ItemId") == "item-1")
        #expect(replayed.integer("PositionTicks") == Ticks(seconds: 30).rawValue)
    }

    @Test("下次成功上报时顺带补报积压条目")
    func successfulReportFlushesQueue() async throws {
        let server = ProgressStubServer(.offline())
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: Ticks(seconds: 30))
        var queued = await reporter.pendingReportCount()
        #expect(queued == 1)

        server.setOnline()
        clock.advance(by: 10)
        await reporter.report(position: Ticks(seconds: 40), isPaused: false)

        queued = await reporter.pendingReportCount()
        #expect(queued == 0, "成功上报后应把积压补掉")
        #expect(
            server.requests.map(\.path) == [
                "/Sessions/Playing",
                "/Sessions/Playing/Progress",
                "/Sessions/Playing"
            ]
        )
    }

    @Test("stop 失败也入队，补报时仍走 Stopped 端点（不是 Progress）")
    func failedStopReplaysToStoppedEndpoint() async throws {
        let server = ProgressStubServer()
        let client = await ProgressTestFactory.client(for: server)
        let clock = MutableClock()
        let reporter = ProgressTestFactory.reporter(client: client, clock: clock)

        await reporter.start(position: .zero)
        server.setOffline()
        await reporter.stop(position: Ticks(seconds: 42))

        let queued = await reporter.pendingReportCount()
        #expect(queued == 1)

        server.setOnline()
        await reporter.drain()

        let replayed = try #require(server.requests.last)
        #expect(replayed.path == "/Sessions/Playing/Stopped")
        #expect(replayed.integer("PositionTicks") == Ticks(seconds: 42).rawValue)
        let leaked = replayed.bodyKeys.intersection(["PlayMethod", "IsPaused"])
        #expect(leaked.isEmpty, "补报的 stop 也不该带 30 字段结构的字段：\(leaked.sorted())")
    }
}
