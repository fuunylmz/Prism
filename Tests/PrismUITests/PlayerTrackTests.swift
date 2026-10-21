import Testing
import PrismPlayback
@testable import PrismUI

/// ``PlayerTrack`` 的菜单文案。
///
/// 守的是一条真实故障：多语种片源常有 20+ 条字幕轨，其中同一语言会出现多条
/// （完整轨 + 强制轨）。菜单早期只显示「语言 · 编码 · 内嵌/外挂」，于是两行
/// 完全一样，用户没法选。同时 `forced` 与容器里的轨道名被丢弃了。
@Suite("PlayerTrack 菜单文案")
struct PlayerTrackTests {
    // MARK: 同语言多轨可区分

    @Test("强制轨会带「强制」标记，与完整轨区分开")
    func forcedTrackIsDistinguishable() {
        let full = PlayerTrack(index: 3, kind: .subtitle, language: "ita", codec: "subrip")
        let forced = PlayerTrack(index: 4, kind: .subtitle, language: "ita", codec: "subrip", isForced: true)

        #expect(full.subtitleDetail == "意大利语 · SRT · 内嵌")
        #expect(forced.subtitleDetail == "意大利语 · SRT · 内嵌 · 强制")
        #expect(full.subtitleDetail != forced.subtitleDetail)
    }

    @Test("轨道名会进入副标题，用来区分同语言的多条轨")
    func trackNameIsShownInDetail() {
        let simplified = PlayerTrack(
            index: 3, kind: .subtitle, language: "chi", title: "简体中文", codec: "subrip"
        )

        #expect(simplified.subtitleDetail.contains("简体中文"))
        // 主标题也用轨道名，避免两行主文案一模一样。
        #expect(simplified.displayName == "简体中文")
    }

    @Test("轨道名与语言名相同时不重复拼接")
    func duplicateTrackNameIsSuppressed() {
        let track = PlayerTrack(
            index: 3, kind: .subtitle, language: "ita", title: "意大利语", codec: "subrip"
        )

        #expect(track.trackName == nil)
        #expect(track.displayName == "意大利语")
        #expect(track.subtitleDetail == "意大利语 · SRT · 内嵌")
    }

    @Test("轨道名就是语言代码时同样不重复")
    func trackNameEqualToLanguageCodeIsSuppressed() {
        let track = PlayerTrack(index: 5, kind: .subtitle, language: "hun", title: "HUN")

        #expect(track.trackName == nil)
        #expect(track.displayName == "HUN")
    }

    @Test("外挂与内嵌仍然区分")
    func externalIsDistinct() {
        let embedded = PlayerTrack(index: 3, kind: .subtitle, language: "eng", codec: "subrip")
        let external = PlayerTrack(
            index: 100_000, kind: .subtitle, language: "eng", codec: "subrip", isExternal: true
        )

        #expect(embedded.subtitleDetail == "英语 · SRT · 内嵌")
        #expect(external.subtitleDetail == "英语 · SRT · 外挂")
    }

    // MARK: 引擎映射

    @Test("从引擎轨道映射时保留 forced 标记")
    func forcedFlagSurvivesMapping() {
        let engineTrack = TrackInfo(
            id: 7,
            kind: .subtitle,
            title: "Signs",
            language: "eng",
            codec: "ass",
            channels: 0,
            isDefault: false,
            isForced: true,
            isExternal: false,
            isTextSubtitle: true
        )

        let track = PlayerTrack(track: engineTrack)

        #expect(track.isForced)
        #expect(track.index == 7)
        #expect(track.subtitleDetail.contains("强制"))
        #expect(track.subtitleDetail.contains("Signs"))
    }

    @Test("音轨沿用「语言 · 声道 · 码率 · 编码」排版")
    func audioDetailUnchanged() {
        let track = PlayerTrack(
            index: 1, kind: .audio, language: "jpn", codec: "dts", channels: 6, bitrate: 1_536_000
        )

        #expect(track.audioDetail == "日语 · 5.1 · 1536 kbps · DTS")
    }
}
