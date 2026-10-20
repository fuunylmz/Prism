import Foundation
import Testing
@testable import PrismCore

@Suite("AppSettings 持久化", .serialized)
@MainActor
struct AppSettingsTests {
    /// 每个用例用独立 suite，测完清理。
    private func makeDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "app.prism.tests.\(name).\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("prism.settings.") {
            defaults.removeObject(forKey: key)
        }
    }

    @Test("默认值符合契约")
    func defaults() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.preferredQuality == .auto)
        #expect(settings.maxBitrateMbps == 0)
        #expect(settings.preferredAudioLanguage == nil)
        #expect(settings.preferredSubtitleLanguage == nil)
        #expect(settings.subtitleMode == .foreign)
        #expect(settings.subtitleScale == 1.0)
        #expect(settings.subtitleBackground == false)
        #expect(settings.seekStepSeconds == 10)
        #expect(settings.autoPlayNextEpisode == true)
        #expect(settings.language == .system)
    }

    @Test("修改后写入 UserDefaults，重建实例能读回")
    func persistence() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let first = AppSettings(defaults: defaults)
        first.preferredQuality = .p1080
        first.maxBitrateMbps = 25
        first.preferredAudioLanguage = "zh"
        first.preferredSubtitleLanguage = "en"
        first.subtitleMode = .always
        first.subtitleScale = 1.5
        first.subtitleBackground = true
        first.seekStepSeconds = 30
        first.autoPlayNextEpisode = false
        first.language = .zhHans

        // 模拟进程重启：新建实例从同一 suite 读回
        let second = AppSettings(defaults: defaults)
        #expect(second.preferredQuality == .p1080)
        #expect(second.maxBitrateMbps == 25)
        #expect(second.preferredAudioLanguage == "zh")
        #expect(second.preferredSubtitleLanguage == "en")
        #expect(second.subtitleMode == .always)
        #expect(second.subtitleScale == 1.5)
        #expect(second.subtitleBackground == true)
        #expect(second.seekStepSeconds == 30)
        #expect(second.autoPlayNextEpisode == false)
        #expect(second.language == .zhHans)
    }

    @Test("subtitleScale 钳制在 0.5...2.0")
    func subtitleScaleClamping() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let settings = AppSettings(defaults: defaults)
        settings.subtitleScale = 5.0
        #expect(settings.subtitleScale == 2.0)
        settings.subtitleScale = 0.1
        #expect(settings.subtitleScale == 0.5)

        // 钳制后的值被持久化
        #expect(AppSettings(defaults: defaults).subtitleScale == 0.5)
    }

    @Test("seekStepSeconds 只接受 5/10/30")
    func seekStepValidation() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let settings = AppSettings(defaults: defaults)
        settings.seekStepSeconds = 15
        #expect(settings.seekStepSeconds == AppSettings.defaultSeekStepSeconds)

        settings.seekStepSeconds = 5
        #expect(settings.seekStepSeconds == 5)
        #expect(AppSettings(defaults: defaults).seekStepSeconds == 5)
    }

    @Test("maxBitrateMbps 不接受负值")
    func bitrateValidation() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let settings = AppSettings(defaults: defaults)
        settings.maxBitrateMbps = -10
        #expect(settings.maxBitrateMbps == 0)
        #expect(AppSettings(defaults: defaults).maxBitrateMbps == 0)
    }

    @Test("reset() 恢复默认值并覆盖已落盘的值")
    func reset() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let settings = AppSettings(defaults: defaults)
        settings.preferredQuality = .p720
        settings.subtitleMode = .never
        settings.language = .en
        settings.subtitleScale = 1.8
        settings.seekStepSeconds = 30

        settings.reset()

        #expect(settings.preferredQuality == .auto)
        #expect(settings.subtitleMode == .foreign)
        #expect(settings.language == .system)
        #expect(settings.subtitleScale == 1.0)
        #expect(settings.seekStepSeconds == 10)

        // 重建后仍是默认值
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.preferredQuality == .auto)
        #expect(reloaded.language == .system)
        #expect(reloaded.seekStepSeconds == 10)
    }

    @Test("非法持久化值降级为默认值")
    func invalidPersistedValues() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        defaults.set("not-a-quality", forKey: "prism.settings.preferredQuality")
        defaults.set("not-a-mode", forKey: "prism.settings.subtitleMode")
        defaults.set("not-a-language", forKey: "prism.settings.language")
        defaults.set(99, forKey: "prism.settings.seekStepSeconds")
        defaults.set(9.0, forKey: "prism.settings.subtitleScale")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.preferredQuality == .auto)
        #expect(settings.subtitleMode == .foreign)
        #expect(settings.language == .system)
        #expect(settings.seekStepSeconds == 10)
        #expect(settings.subtitleScale == 2.0) // 9.0 被钳到上限
    }

    @Test("枚举可 Codable / CaseIterable")
    func enums() throws {
        #expect(QualityPreset.allCases.count == 4)
        #expect(SubtitleMode.allCases.count == 4)
        #expect(AppLanguage.allCases.count == 3)
        #expect(QualityPreset.p1080.targetHeight == 1080)
        #expect(QualityPreset.auto.targetHeight == nil)
        #expect(AppLanguage.zhHans.locale?.identifier == "zh-Hans")
        #expect(AppLanguage.system.locale == nil)

        let data = try JSONEncoder().encode(QualityPreset.p720)
        #expect(String(decoding: data, as: UTF8.self) == "\"p720\"")
    }

    @Test("removeAllPersistedValues 清空本实例写入的键")
    func removeAll() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let settings = AppSettings(defaults: defaults)
        settings.preferredQuality = .p1080
        settings.removeAllPersistedValues()

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.preferredQuality == .auto)
    }
}

@Suite("工具类型")
struct UtilityTests {
    @Test("DeviceID 首次生成、之后稳定、reset 后可重建")
    func deviceIDStability() throws {
        let suite = "app.prism.tests.deviceid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { DeviceID.reset(in: defaults) }

        let first = DeviceID.current(in: defaults)
        let second = DeviceID.current(in: defaults)
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)

        DeviceID.reset(in: defaults)
        let third = DeviceID.current(in: defaults)
        #expect(third != first)
        #expect(UUID(uuidString: third) != nil)
    }

    @Test("HostInfo.deviceName 非空")
    func hostInfo() {
        #expect(!HostInfo.deviceName.isEmpty)
        #expect(!HostInfo.operatingSystemVersion.isEmpty)
    }

    @Test("LoadState 状态机")
    func loadState() {
        #expect(LoadState<[Int]>.idle.value == nil)
        #expect(LoadState<[Int]>.loading.isLoading)
        #expect(LoadState<[Int]>.loading.isSettled == false)
        #expect(LoadState<[Int]>.loaded([1]).value == [1])
        #expect(LoadState<[Int]>.empty.isEmpty)
        #expect(LoadState<[Int]>.empty.isSettled)
        #expect(LoadState<[Int]>.failed(.timeout).error == .timeout)
        #expect(LoadState<[Int]>.failed(.timeout).value == nil)

        #expect([Int]().loadState == .empty)
        #expect([1, 2].loadState == .loaded([1, 2]))
    }

    @Test("Debouncer 合并连续触发，只执行最后一次")
    func debouncerCoalesces() async throws {
        let debouncer = Debouncer(interval: .milliseconds(50))
        let counter = Counter()

        for _ in 0..<10 {
            await debouncer.schedule { await counter.increment() }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await counter.value == 1)
    }

    @Test("Debouncer flush 立即执行并取消挂起任务")
    func debouncerFlush() async throws {
        let debouncer = Debouncer(interval: .seconds(5))
        let counter = Counter()

        await debouncer.schedule { await counter.increment() }
        await debouncer.flush { await counter.increment() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await counter.value == 1)
    }

    @Test("Debouncer cancel 后不执行")
    func debouncerCancel() async throws {
        let debouncer = Debouncer(interval: .milliseconds(30))
        let counter = Counter()

        await debouncer.schedule { await counter.increment() }
        await debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await counter.value == 0)
    }

    @Test("ClockProviding 两种实现")
    func clocks() {
        let fixed = FixedClock(now: Date(timeIntervalSince1970: 1_000))
        #expect(fixed.now == Date(timeIntervalSince1970: 1_000))
        #expect(SystemClock().now.timeIntervalSince1970 > 0)
    }
}

/// 测试用的线程安全计数器。
private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
