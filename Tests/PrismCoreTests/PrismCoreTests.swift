import Testing
@testable import PrismCore

@Suite("PrismCore 骨架自检")
struct PrismCoreTests {
    @Test("版本号与 bundle id 已定义")
    func identity() {
        #expect(!Prism.version.isEmpty)
        #expect(Prism.bundleIdentifier == "app.prism.Prism")
    }
}
