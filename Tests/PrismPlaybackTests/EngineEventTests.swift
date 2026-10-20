import Foundation
import PrismCore
import Testing
@testable import PrismPlayback

// MARK: - A 层：纯逻辑（不碰引擎）

@Suite("PlaybackEvent 的等值语义")
struct EngineEventTests {
    private func failure(_ kind: PlaybackFailure.Kind = .load) -> PlaybackFailure {
        PlaybackFailure(kind: kind, message: "boom")
    }

    @Test("相同负载的事件相等，不同负载不等")
    func equality() {
        #expect(PlaybackEvent.stateChanged(.playing) == .stateChanged(.playing))
        #expect(PlaybackEvent.stateChanged(.playing) != .stateChanged(.paused))
        #expect(PlaybackEvent.durationChanged(Ticks(seconds: 10)) == .durationChanged(Ticks(seconds: 10)))
        #expect(PlaybackEvent.durationChanged(Ticks(seconds: 10)) != .durationChanged(Ticks(seconds: 11)))
        #expect(PlaybackEvent.bufferChanged(0.5) == .bufferChanged(0.5))
        #expect(PlaybackEvent.bufferChanged(0.5) != .bufferChanged(0.25))
        #expect(PlaybackEvent.ended == .ended)
        #expect(PlaybackEvent.failed(failure()) == .failed(failure()))
        #expect(PlaybackEvent.failed(failure()) != .failed(failure(.network)))
    }

    @Test("跨 case 永不相等")
    func crossCase() {
        #expect(PlaybackEvent.ended != .stateChanged(.ended))
        #expect(PlaybackEvent.stateChanged(.idle) != .bufferChanged(0))
        #expect(PlaybackEvent.failed(failure()) != .stateChanged(.failed(failure())))
    }

    @Test("positionChanged 携带位置与时长，且按时长区分")
    func positionChanged() {
        let a = PlaybackEvent.positionChanged(Ticks(seconds: 3), duration: Ticks(seconds: 10))
        let b = PlaybackEvent.positionChanged(Ticks(seconds: 3), duration: Ticks(seconds: 11))
        let c = PlaybackEvent.positionChanged(Ticks(seconds: 3), duration: Ticks(seconds: 10))
        #expect(a == c)
        #expect(a != b)
        #expect(a.position == Ticks(seconds: 3))
        #expect(a.state == nil)
        #expect(PlaybackEvent.stateChanged(.buffering).state == .buffering)
    }

    @Test("tracksChanged 按轨道数组逐项比较")
    func tracksChanged() {
        let audio = TrackInfo(id: 1, kind: .audio, title: "English", codec: "aac")
        let subtitle = TrackInfo(id: 2, kind: .subtitle, title: "English", codec: "subrip", isTextSubtitle: true)
        let left = PlaybackEvent.tracksChanged(audio: [audio], subtitle: [subtitle])
        let right = PlaybackEvent.tracksChanged(audio: [audio], subtitle: [subtitle])
        let reordered = PlaybackEvent.tracksChanged(audio: [], subtitle: [subtitle])
        #expect(left == right)
        #expect(left != reordered)
    }

    @Test("subtitleCues 按 cue 的 id / 时间轴 / 正文比较")
    func subtitleCues() {
        let cue = SubtitleCue(id: 1, start: Ticks(seconds: 1), end: Ticks(seconds: 2), body: .text("hi"))
        let same = SubtitleCue(id: 1, start: Ticks(seconds: 1), end: Ticks(seconds: 2), body: .text("hi"))
        let otherText = SubtitleCue(id: 1, start: Ticks(seconds: 1), end: Ticks(seconds: 2), body: .text("yo"))
        #expect(PlaybackEvent.subtitleCues([cue]) == .subtitleCues([same]))
        #expect(PlaybackEvent.subtitleCues([cue]) != .subtitleCues([otherText]))
    }

    @Test("PlaybackState 的终态 / 活跃判定")
    func statePredicates() {
        #expect(PlaybackState.idle.isTerminal == false)
        #expect(PlaybackState.loading.isActive)
        #expect(PlaybackState.playing.isActive)
        #expect(PlaybackState.paused.isActive)
        #expect(PlaybackState.buffering.isActive)
        #expect(PlaybackState.ended.isTerminal)
        #expect(PlaybackState.ended.isActive == false)
        #expect(PlaybackState.failed(failure()).isTerminal)
        #expect(PlaybackState.playing.failure == nil)
        #expect(PlaybackState.failed(failure()).failure == failure())
    }

    @Test("PlaybackFailure 的分类与可恢复标记参与等值")
    func failureEquality() {
        let a = PlaybackFailure(kind: .network, message: "timeout", isRecoverable: true)
        let b = PlaybackFailure(kind: .network, message: "timeout", isRecoverable: true)
        let c = PlaybackFailure(kind: .network, message: "timeout", isRecoverable: false)
        #expect(a == b)
        #expect(a != c)
        #expect(a.errorDescription == "timeout")
    }
}

// MARK: - 事件桥

@Suite("EventBridge：Combine 出口的 AsyncStream 桥")
struct EngineEventBridgeTests {
    @Test("按顺序送达，finish 后流结束")
    func deliversInOrder() async {
        let bridge = PlaybackEventBridge()
        bridge.yield(.stateChanged(.loading))
        bridge.yield(.stateChanged(.playing))
        bridge.yield(.durationChanged(Ticks(seconds: 10)))
        bridge.finish()

        var received: [PlaybackEvent] = []
        for await event in bridge.events {
            received.append(event)
        }
        #expect(received == [
            .stateChanged(.loading),
            .stateChanged(.playing),
            .durationChanged(Ticks(seconds: 10))
        ])
    }

    @Test("背压策略保留最新事件，不会无限积压")
    func keepsNewest() async {
        let bridge = PlaybackEventBridge(bufferingPolicy: .bufferingNewest(2))
        for index in 0..<5 {
            bridge.yield(.bufferChanged(Double(index)))
        }
        bridge.finish()

        var received: [Double] = []
        for await event in bridge.events {
            if case .bufferChanged(let value) = event {
                received.append(value)
            }
        }
        #expect(received == [3, 4])
    }

    @Test("finish 之后 yield 是安全的空操作")
    func yieldAfterFinish() async {
        let bridge = PlaybackEventBridge()
        bridge.yield(.ended)
        bridge.finish()
        bridge.yield(.stateChanged(.playing))

        var count = 0
        for await _ in bridge.events { count += 1 }
        #expect(count == 1)
    }
}

// MARK: - 位置闸门（坑 2）

@Suite("位置闸门：切音轨期间冻结进度")
struct EnginePositionGateTests {
    @Test("冻结期间不产生位置事件，解冻后补发一次")
    func freezeAndThaw() {
        var gate = PlaybackPositionGate()
        gate.setDuration(Ticks(seconds: 10))

        let first = gate.accept(position: Ticks(seconds: 9), duration: Ticks(seconds: 10))
        #expect(first == .positionChanged(Ticks(seconds: 9), duration: Ticks(seconds: 10)))

        gate.freeze()
        // 模拟引擎重建期间 sourceTime 归零（实测 9.073 → 0.000 → 9.072）
        #expect(gate.accept(position: .zero, duration: Ticks(seconds: 10)) == nil)
        #expect(gate.accept(position: Ticks(seconds: 9.05), duration: Ticks(seconds: 10)) == nil)

        // 解冻时时钟可能还是 0（实测 t+0.101s 仍为 0），必须取冻结前的有效值
        let thawed = gate.thaw(clockPosition: .zero)
        #expect(thawed == .positionChanged(Ticks(seconds: 9), duration: Ticks(seconds: 10)))
        #expect(gate.isFrozen == false)
    }

    @Test("解冻时若时钟已经追上，用更大的那个")
    func thawUsesClockWhenAhead() {
        var gate = PlaybackPositionGate()
        gate.setDuration(Ticks(seconds: 10))
        _ = gate.accept(position: Ticks(seconds: 4), duration: Ticks(seconds: 10))
        gate.freeze()
        let thawed = gate.thaw(clockPosition: Ticks(seconds: 4.4))
        #expect(thawed == .positionChanged(Ticks(seconds: 4.4), duration: Ticks(seconds: 10)))
    }

    @Test("位置与时长都没变时不重复发事件，force 可以强制发")
    func deduplicates() {
        var gate = PlaybackPositionGate()
        #expect(gate.accept(position: .zero, duration: .zero) != nil)   // 第一次总是发
        #expect(gate.accept(position: .zero, duration: .zero) == nil)   // 完全没变
        #expect(gate.accept(position: .zero, duration: .zero, force: true) != nil)
        #expect(gate.accept(position: Ticks(seconds: 1), duration: .zero) != nil)
    }

    @Test("reset 之后重新开始")
    func reset() {
        var gate = PlaybackPositionGate()
        _ = gate.accept(position: Ticks(seconds: 5), duration: Ticks(seconds: 10))
        gate.freeze()
        gate.reset()
        #expect(gate.isFrozen == false)
        #expect(gate.position == .zero)
        #expect(gate.duration == .zero)
        #expect(gate.accept(position: .zero, duration: .zero) != nil)
    }
}

// MARK: - 字幕时间轴（坑 4）

@Suite("字幕延迟：偏移计算与时间轴闸门")
struct EngineSubtitleDelayTests {
    private func cue(_ start: Double, _ end: Double, id: Int = 1) -> SubtitleCue {
        SubtitleCue(id: id, start: Ticks(seconds: start), end: Ticks(seconds: end), body: .text("x"))
    }

    @Test("正延迟把 cue 整体后移")
    func positiveDelay() throws {
        let shifted = try #require(cue(1, 2).shifted(by: 0.5))
        #expect(shifted.start == Ticks(seconds: 1.5))
        #expect(shifted.end == Ticks(seconds: 2.5))
        #expect(shifted.id == 1)
    }

    @Test("负延迟把 cue 整体前移，并把起点钳到 0")
    func negativeDelay() throws {
        let shifted = try #require(cue(1, 2).shifted(by: -0.5))
        #expect(shifted.start == Ticks(seconds: 0.5))
        #expect(shifted.end == Ticks(seconds: 1.5))

        let clamped = try #require(cue(0.2, 2).shifted(by: -0.5))
        #expect(clamped.start == .zero)              // 钳到 0，不会变成负时间
        #expect(clamped.end == Ticks(seconds: 1.5))
    }

    @Test("整条 cue 被推到 0 之前时丢弃")
    func dropsFullyAdvancedCue() {
        #expect(cue(0.1, 0.3).shifted(by: -0.5) == nil)
        #expect(cue(0.1, 0.3).shifted(by: 0.5) != nil)
    }

    @Test("0 与非法延迟原样返回")
    func identityAndInvalid() {
        let original = cue(1, 2)
        #expect(original.shifted(by: 0) == original)
        #expect(original.shifted(by: .nan) == original)
        #expect(original.shifted(by: .infinity) == original)
    }

    @Test("延迟只改时间轴，正文 / 位置 / id 全部保留")
    func preservesPayload() throws {
        let placement = SubtitleCue.Placement(alignment: 7, position: .init(x: 0.5, y: 0.1))
        let rich = SubtitleCue(
            id: 42,
            start: Ticks(seconds: 4),
            end: Ticks(seconds: 6),
            body: .richText([.init(text: "red", color: .init(r: 255, g: 0, b: 0), isBold: true)]),
            placement: placement
        )
        let shifted = try #require(rich.shifted(by: 1))
        #expect(shifted.start == Ticks(seconds: 5))
        #expect(shifted.end == Ticks(seconds: 7))
        #expect(shifted.body == rich.body)
        #expect(shifted.placement == placement)
        #expect(shifted.id == 42)
    }

    @Test("闸门：设置延迟后 shiftedCues 才偏移")
    func gateAppliesDelay() {
        var gate = SubtitleTimelineGate()
        gate.update(cues: [cue(1, 2, id: 1), cue(3, 4, id: 2)])
        #expect(gate.shiftedCues.map(\.start) == [Ticks(seconds: 1), Ticks(seconds: 3)])

        let firstChange = gate.setDelay(0.5)
        #expect(firstChange)
        #expect(gate.shiftedCues.map(\.start) == [Ticks(seconds: 1.5), Ticks(seconds: 3.5)])

        // 重复设置同一值不算变化（调用方据此决定是否重发 cue）
        let repeated = gate.setDelay(0.5)
        #expect(repeated == false)
        // 非法值被忽略，保持原值
        let invalid = gate.setDelay(.nan)
        #expect(invalid == false)
        #expect(gate.delay == 0.5)
    }

    @Test("闸门 reset 清空延迟与 cue")
    func gateReset() {
        var gate = SubtitleTimelineGate()
        gate.update(cues: [cue(1, 2)])
        _ = gate.setDelay(2)
        gate.reset()
        #expect(gate.delay == 0)
        #expect(gate.cues.isEmpty)
        #expect(gate.shiftedCues.isEmpty)
    }
}
