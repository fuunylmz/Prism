import Testing
@testable import EmbyAPI
import PrismCore

@Suite("EmbyAPI 骨架自检")
struct EmbyAPITests {
    @Test("API 前缀与占位标记")
    func placeholder() {
        #expect(EmbyAPI.isPlaceholder)
        #expect(EmbyAPI.apiPathPrefix == "/emby")
    }

    @Test("可访问 PrismCore")
    func linksCore() {
        #expect(!Prism.version.isEmpty)
    }
}
