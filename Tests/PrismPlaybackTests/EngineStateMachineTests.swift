import Foundation
import PrismCore
import Testing
@testable import PrismPlayback

@Suite("播放状态机：合法 / 非法迁移")
struct EngineStateMachineTests {
    private func failure() -> PlaybackFailure {
        PlaybackFailure(kind: .network, message: "timeout", isRecoverable: true)
    }

    @Test("正常链路：idle → loading → playing → paused → playing → ended")
    func happyPath() {
        var machine = PlaybackStateMachine()
        #expect(machine.state == .idle)

        #expect(machine.apply(.loading) == .accepted)
        #expect(machine.state == .loading)

        #expect(machine.apply(.playing) == .accepted)
        #expect(machine.state == .playing)

        #expect(machine.apply(.paused) == .accepted)
        #expect(machine.state == .paused)

        #expect(machine.apply(.playing) == .accepted)
        #expect(machine.state == .playing)

        #expect(machine.apply(.ended) == .accepted)
        #expect(machine.state == .ended)
    }

    @Test("非法迁移被丢弃：ended → playing / paused / loading")
    func endedIsTerminal() {
        var machine = PlaybackStateMachine(initial: .ended)
        #expect(machine.apply(.playing) == .rejected)
        #expect(machine.apply(.paused) == .rejected)
        #expect(machine.apply(.loading) == .rejected)
        #expect(machine.apply(.buffering) == .rejected)
        #expect(machine.state == .ended)
        // 终态只能回 idle（stop）或失败
        #expect(machine.apply(.idle) == .accepted)
    }

    @Test("非法迁移被丢弃：failed → playing")
    func failedIsTerminal() {
        var machine = PlaybackStateMachine(initial: .failed(failure()))
        #expect(machine.apply(.playing) == .rejected)
        #expect(machine.apply(.paused) == .rejected)
        #expect(machine.state.failure == failure())
        // 重播必须先 load（failed → loading 合法）或 stop（→ idle）
        #expect(machine.apply(.loading) == .accepted)
    }

    @Test("非法迁移被丢弃：idle → playing（没加载就播放）")
    func idleCannotPlay() {
        var machine = PlaybackStateMachine()
        #expect(machine.apply(.playing) == .rejected)
        #expect(machine.apply(.paused) == .rejected)
        #expect(machine.apply(.ended) == .rejected)
        #expect(machine.state == .idle)
        #expect(machine.apply(.loading) == .accepted)
    }

    @Test("切音轨重建：playing → loading → playing 必须合法（坑 2）")
    func audioTrackRebuildIsLegal() {
        var machine = PlaybackStateMachine(initial: .playing)
        #expect(machine.apply(.loading) == .accepted)
        #expect(machine.apply(.playing) == .accepted)

        var paused = PlaybackStateMachine(initial: .paused)
        #expect(paused.apply(.loading) == .accepted)
        #expect(paused.apply(.paused) == .accepted)
    }

    @Test("缓冲：playing ↔ buffering")
    func buffering() {
        var machine = PlaybackStateMachine(initial: .playing)
        #expect(machine.apply(.buffering) == .accepted)
        #expect(machine.apply(.playing) == .accepted)
        #expect(machine.apply(.buffering) == .accepted)
        #expect(machine.apply(.paused) == .accepted)
    }

    @Test("同状态迁移是 unchanged，不是 rejected")
    func unchanged() {
        var machine = PlaybackStateMachine(initial: .playing)
        #expect(machine.apply(.playing) == .unchanged)
        #expect(machine.state == .playing)
        #expect(machine.canTransition(to: .playing))
    }

    @Test("canTransition 与 apply 结论一致")
    func canTransitionMatchesApply() {
        let states: [PlaybackState] = [
            .idle, .loading, .playing, .paused, .buffering, .ended, .failed(failure())
        ]
        for from in states {
            for to in states {
                var machine = PlaybackStateMachine(initial: from)
                let predicted = machine.canTransition(to: to)
                let result = machine.apply(to)
                #expect((result != .rejected) == predicted, "\(from) → \(to) 的判定不一致")
            }
        }
    }

    @Test("force 跳过规则，只给会话重置用")
    func forceBypassesRules() {
        var machine = PlaybackStateMachine(initial: .ended)
        machine.force(.idle)
        #expect(machine.state == .idle)
    }

    @Test("任意状态都能失败，失败后能重新加载")
    func failureFromAnyActiveState() {
        for from in [PlaybackState.loading, .playing, .paused, .buffering] {
            var machine = PlaybackStateMachine(initial: from)
            #expect(machine.apply(.failed(failure())) == .accepted)
            #expect(machine.apply(.idle) == .accepted)
            #expect(machine.apply(.loading) == .accepted)
        }
    }
}
