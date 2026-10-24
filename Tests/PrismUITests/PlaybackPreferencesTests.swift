import Foundation
import Testing
import EmbyAPI
import PrismCore
import PrismPlayback
@testable import PrismUI

/// 设置页的播放选项必须真的影响协商与起播。
///
/// 这里守的是一条真实发生过的缺陷：`PlaybackCoordinator` 曾经直接构造
/// `PlaybackPreferences()`，导致「限制峰值码率」「首选音轨语言」这些设置
/// 对真实播放**零影响**——用户改了设置，行为完全不变。
@Suite("PlaybackPreferences（设置映射）")
@MainActor
struct PlaybackPreferencesTests {
    /// 造一份独立的设置存储，避免污染开发机的真实偏好。
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "test.prism.playback.\(UUID().uuidString)")!)
    }

    @Test("默认设置：不限制码率、不干预语言")
    func defaultsDoNotConstrain() {
        let preferences = PlaybackPreferences(appSettings: makeSettings())

        #expect(preferences.maxBitrateMbps == 0)
        #expect(preferences.preferredAudioLanguage == nil)
        #expect(preferences.preferredSubtitleLanguage == nil)
        #expect(preferences.preferDirectPlay)
    }

    @Test("手动填写的码率上限生效")
    func manualBitrateLimitIsApplied() {
        let settings = makeSettings()
        settings.maxBitrateMbps = 12

        let preferences = PlaybackPreferences(appSettings: settings)

        #expect(preferences.maxBitrateMbps == 12)
    }

    @Test("画质预设会换算成码率上限")
    func qualityPresetBecomesBitrate() {
        let settings = makeSettings()
        settings.preferredQuality = .p720

        let preferences = PlaybackPreferences(appSettings: settings)

        #expect(preferences.maxBitrateMbps == QualityPreset.p720.suggestedBitrateMbps)
    }

    @Test("预设与手填同时存在时取更严格的那个")
    func stricterLimitWins() {
        let settings = makeSettings()
        settings.preferredQuality = .p1080 // 20 Mbps
        settings.maxBitrateMbps = 6

        let preferences = PlaybackPreferences(appSettings: settings)

        #expect(preferences.maxBitrateMbps == 6)
    }

    @Test("首选语言会传给协商层，并归一化成小写")
    func preferredLanguagesArePassedThrough() {
        let settings = makeSettings()
        settings.preferredAudioLanguage = " CHI "
        settings.preferredSubtitleLanguage = "zh-Hans"

        let preferences = PlaybackPreferences(appSettings: settings)

        #expect(preferences.preferredAudioLanguage == "chi")
        #expect(preferences.preferredSubtitleLanguage == "zh-hans")
    }

    @Test("字幕自动模式和界面语言会传给播放协商")
    func subtitleModeAndInterfaceLanguageArePassedThrough() {
        let settings = makeSettings()
        settings.subtitleMode = .forced
        settings.language = .zhHans

        let preferences = PlaybackPreferences(appSettings: settings)

        #expect(preferences.subtitleMode == .forced)
        #expect(preferences.interfaceLanguage == "chi")
    }

    @Test("空字符串等同于「不干预」，不是「只选空语言」")
    func blankLanguageIsNil() {
        let settings = makeSettings()
        settings.preferredAudioLanguage = "   "

        let preferences = PlaybackPreferences(appSettings: settings)

        #expect(preferences.preferredAudioLanguage == nil)
    }

    // MARK: 设备档案码率

    @Test("码率换算：设置里的 Mbps 变成设备档案的 bps")
    func bitrateConversion() {
        let settings = makeSettings()
        settings.maxBitrateMbps = 20

        #expect(PlaybackCoordinator.streamingBitrateLimit(from: settings) == 20_000_000)
    }

    @Test("没有任何限制时回落到默认上限，而不是 0（0 会被服务端当成「不许播」）")
    func bitrateFallsBackToDefault() {
        let settings = makeSettings()

        let limit = PlaybackCoordinator.streamingBitrateLimit(from: settings)

        #expect(limit == 120_000_000)
        #expect(limit > 0)
    }
}
