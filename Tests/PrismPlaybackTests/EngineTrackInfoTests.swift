import Foundation
import PrismCore
import Testing
@testable import PrismPlayback

@Suite("TrackInfo：从 Emby MediaStream 映射")
struct EngineTrackInfoTests {
    private func stream(
        index: Int,
        type: StreamType,
        codec: String? = nil,
        language: String? = nil,
        displayTitle: String? = nil,
        channels: Int? = nil,
        isDefault: Bool = false,
        isExternal: Bool = false,
        isForced: Bool = false,
        isTextSubtitleStream: Bool = false
    ) -> MediaStream {
        MediaStream(
            index: index,
            type: type,
            codec: codec,
            language: language,
            displayTitle: displayTitle,
            isDefault: isDefault,
            isExternal: isExternal,
            channels: channels,
            isForced: isForced,
            isTextSubtitleStream: isTextSubtitleStream
        )
    }

    @Test("音频轨映射到 .audio，声道 / 语言 / 默认标记都带过来")
    func audio() throws {
        let info = try #require(TrackInfo(stream: stream(
            index: 1,
            type: .audio,
            codec: "aac",
            language: "eng",
            displayTitle: "English AAC 5.1 (Default)",
            channels: 6,
            isDefault: true
        )))
        #expect(info.id == 1)
        #expect(info.kind == .audio)
        #expect(info.title == "English AAC 5.1 (Default)")
        #expect(info.language == "eng")
        #expect(info.codec == "aac")
        #expect(info.channels == 6)
        #expect(info.isDefault)
        #expect(info.isTextSubtitle == false)
    }

    @Test("文本字幕轨映射到 .subtitle 且 isTextSubtitle 为 true")
    func textSubtitle() throws {
        let info = try #require(TrackInfo(stream: stream(
            index: 3,
            type: .subtitle,
            codec: "subrip",
            language: "chi",
            displayTitle: "简体中文",
            isTextSubtitleStream: true
        )))
        #expect(info.id == 3)
        #expect(info.kind == .subtitle)
        #expect(info.codec == "subrip")
        #expect(info.isTextSubtitle)
    }

    @Test("图形字幕（PGS）映射为 .subtitle 但 isTextSubtitle 为 false")
    func bitmapSubtitle() throws {
        let info = try #require(TrackInfo(stream: stream(
            index: 4,
            type: .subtitle,
            codec: "hdmv_pgs_subtitle",
            isTextSubtitleStream: false
        )))
        #expect(info.kind == .subtitle)
        #expect(info.isTextSubtitle == false)
    }

    @Test("服务器没填 IsTextSubtitleStream 时按 codec 兜底")
    func textFallbackByCodec() throws {
        let ass = try #require(TrackInfo(stream: stream(index: 5, type: .subtitle, codec: "ass")))
        #expect(ass.isTextSubtitle)
        let pgs = try #require(TrackInfo(stream: stream(index: 6, type: .subtitle, codec: "dvd_subtitle")))
        #expect(pgs.isTextSubtitle == false)
    }

    @Test("视频轨 / 附件 / 内嵌图片 / 数据轨不产生 TrackInfo")
    func nonPlayableStreamsAreDropped() {
        #expect(TrackInfo(stream: stream(index: 0, type: .video, codec: "h264")) == nil)
        #expect(TrackInfo(stream: stream(index: 7, type: .attachment, codec: "ttf")) == nil)
        #expect(TrackInfo(stream: stream(index: 8, type: .embeddedImage, codec: "mjpeg")) == nil)
        #expect(TrackInfo(stream: stream(index: 9, type: .data, codec: nil)) == nil)
        #expect(TrackInfo(stream: stream(index: 10, type: .unknown("Mystery"))) == nil)
    }

    @Test("外挂字幕 / 强制字幕的标记透传")
    func externalAndForced() throws {
        let info = try #require(TrackInfo(stream: stream(
            index: 100_000,
            type: .subtitle,
            codec: "ass",
            isExternal: true,
            isForced: true,
            isTextSubtitleStream: true
        )))
        #expect(info.isExternal)
        #expect(info.isForced)
        #expect(info.isTextSubtitle)
    }

    @Test("displayTitle 缺失时回退到 MediaStream.displayName")
    func titleFallback() throws {
        let info = try #require(TrackInfo(stream: stream(
            index: 2,
            type: .audio,
            codec: "ac3",
            language: "jpn"
        )))
        #expect(info.title == "jpn · ac3")
    }

    @Test("codec 名单分类")
    func codecClassification() {
        #expect(TrackInfo.isBitmapSubtitleCodec("hdmv_pgs_subtitle"))
        #expect(TrackInfo.isBitmapSubtitleCodec("PGS"))
        #expect(TrackInfo.isBitmapSubtitleCodec("dvb_subtitle"))
        #expect(TrackInfo.isBitmapSubtitleCodec("subrip") == false)
        #expect(TrackInfo.isBitmapSubtitleCodec(nil) == false)

        #expect(TrackInfo.isTextSubtitleCodec("subrip"))
        #expect(TrackInfo.isTextSubtitleCodec("ASS"))
        #expect(TrackInfo.isTextSubtitleCodec("webvtt"))
        #expect(TrackInfo.isTextSubtitleCodec("hdmv_pgs_subtitle") == false)
        #expect(TrackInfo.isTextSubtitleCodec(nil) == false)
    }

    @Test("等值按全部字段比较，id 相同但类型不同即不等")
    func equality() {
        let a = TrackInfo(id: 1, kind: .audio, title: "A", codec: "aac")
        let b = TrackInfo(id: 1, kind: .audio, title: "A", codec: "aac")
        let c = TrackInfo(id: 1, kind: .subtitle, title: "A", codec: "aac")
        #expect(a == b)
        #expect(a != c)
        #expect(a.id == 1)
    }
}
