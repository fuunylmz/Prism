import Testing
@testable import PrismPlayback

@Suite("PrismPlayback 骨架自检")
struct PrismPlaybackTests {
    @Test("可访问 PrismPlayback")
    func moduleIsReachable() {
        #expect(true)
    }
}
