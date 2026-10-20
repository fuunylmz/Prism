import Foundation
import PrismCore
import Testing
@testable import PrismPlayback

@Suite("PlaybackRequest 与配套值类型")
struct EngineRequestTests {
    @Test("默认值：空头、零位置、无外挂字幕、无轨道选择")
    func defaults() {
        let request = PlaybackRequest(url: URL(string: "https://demo.local/videos/1/stream")!, method: .directStream)
        #expect(request.headers.isEmpty)
        #expect(request.startPosition == .zero)
        #expect(request.externalSubtitles.isEmpty)
        #expect(request.audioStreamIndex == nil)
        #expect(request.subtitleStreamIndex == nil)
        #expect(request.method == .directStream)
    }

    @Test("PlaybackMethod 复用 Negotiation 的定义（不在 Engine 下重复定义）")
    func reusesNegotiationMethod() {
        // 三种方式都能构造，且 isStreamCopy 语义来自 Negotiation 层
        #expect(PlaybackMethod.directPlay.isStreamCopy)
        #expect(PlaybackMethod.directStream.isStreamCopy)
        #expect(PlaybackMethod.transcode.isStreamCopy == false)
        #expect(PlaybackMethod.transcode.embyPlayMethod == "Transcode")
    }

    @Test("SubtitleTrack 按扩展名推断格式")
    func formatInference() {
        func track(_ path: String) -> SubtitleTrack {
            SubtitleTrack(id: path, url: URL(fileURLWithPath: path))
        }
        #expect(track("/a/b.srt").format == .srt)
        #expect(track("/a/b.ASS").format == .ass)
        #expect(track("/a/b.ssa").format == .ssa)
        #expect(track("/a/b.vtt").format == .vtt)
        #expect(track("/a/b.sup").format == .pgs)
        #expect(track("/a/b.unknown").format == .other)
    }

    @Test("显式 format 覆盖扩展名推断")
    func explicitFormatWins() {
        let track = SubtitleTrack(
            id: "1",
            url: URL(fileURLWithPath: "/tmp/download.bin"),
            title: "简体中文",
            language: "chi",
            format: .ass,
            isForced: true
        )
        #expect(track.format == .ass)
        #expect(track.title == "简体中文")
        #expect(track.language == "chi")
        #expect(track.isForced)
    }

    @Test("SubtitleStyle 默认值：白字黑边、底部、不覆盖作者排版")
    func styleDefaults() {
        let style = SubtitleStyle.default
        #expect(style.fontName == nil)
        #expect(style.primaryColor == .white)
        #expect(style.outlineColor == .black)
        #expect(style.alignment == .bottom)
        #expect(style.overrideEmbeddedASS == false)
        #expect(style.outlineWidth > 0)
        #expect(style.backgroundColor.a == 0)   // 默认不画背景
    }

    @Test("SubtitleColor 等值按 RGBA 全通道比较")
    func colorEquality() {
        #expect(SubtitleColor(r: 1, g: 2, b: 3, a: 4) == SubtitleColor(r: 1, g: 2, b: 3, a: 4))
        #expect(SubtitleColor(r: 1, g: 2, b: 3, a: 4) != SubtitleColor(r: 1, g: 2, b: 3, a: 5))
        #expect(SubtitleColor.white != SubtitleColor.black)
    }
}
