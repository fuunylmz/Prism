import Testing
@testable import PrismData

@Suite("PrismData 骨架自检")
struct PrismDataTests {
    @Test("可访问 PrismData")
    func moduleIsReachable() {
        #expect(true)
    }
}
