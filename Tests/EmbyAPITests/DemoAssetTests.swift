import AVFoundation
import Foundation
import Testing
import PrismCore
@testable import EmbyAPI

/// 程序化封面图与合成视频的测试。
@Suite("演示模式：素材生成")
struct DemoAssetTests {

    // MARK: - 哈希与色相

    @Test("FNV-1a 哈希固定且稳定")
    func stableHashIsFixed() {
        // 同一输入恒定；不同输入不同。
        #expect(DemoArtwork.stableHash("abc") == DemoArtwork.stableHash("abc"))
        #expect(DemoArtwork.stableHash("abc") != DemoArtwork.stableHash("abd"))
        // FNV-1a 64 位对空串的已知值。
        #expect(DemoArtwork.stableHash("") == 0xcbf2_9ce4_8422_2325)
    }

    @Test("色相落在 0..<1，且不同 id 会分散")
    func hueRangeAndSpread() {
        let ids = DemoLibrary.allItems.map { $0.id }
        let hues = ids.map { DemoArtwork.hue(for: $0) }
        #expect(hues.allSatisfy { $0 >= 0 && $0 < 1 })
        // 至少要有 10 种不同的色相，否则海报会糊成一片。
        #expect(Set(hues.map { Int($0 * 100) }).count >= 10)
    }

    // MARK: - 图片生成

    @Test("生成的海报尺寸正确、非空")
    func artworkSize() {
        let image = DemoArtwork.image(
            seed: "movie:test",
            kind: .primary,
            size: CGSize(width: 320, height: 480),
            title: "测试影片"
        )
        #expect(image.size == CGSize(width: 320, height: 480))
        #expect(image.representations.isEmpty == false)
    }

    @Test("同一 seed 生成像素一致的图")
    func artworkIsDeterministic() throws {
        let size = CGSize(width: 64, height: 96)
        let first = DemoArtwork.image(seed: "movie:stable", kind: .primary, size: size, title: "稳定")
        let second = DemoArtwork.image(seed: "movie:stable", kind: .primary, size: size, title: "稳定")

        let firstData = try #require(first.tiffRepresentation)
        let secondData = try #require(second.tiffRepresentation)
        #expect(firstData == secondData)
    }

    @Test("不同 seed 生成不同的图")
    func artworkDiffersBySeed() throws {
        let size = CGSize(width: 64, height: 96)
        let a = DemoArtwork.image(seed: "movie:a", kind: .primary, size: size)
        let b = DemoArtwork.image(seed: "movie:b", kind: .primary, size: size)

        let aData = try #require(a.tiffRepresentation)
        let bData = try #require(b.tiffRepresentation)
        #expect(aData != bData)
    }

    @Test("非法尺寸被钳制，不会崩溃")
    func artworkClampsSize() {
        let zero = DemoArtwork.image(seed: "x", size: .zero)
        #expect(zero.size.width >= 1)
        #expect(zero.size.height >= 1)

        let huge = DemoArtwork.image(seed: "x", size: CGSize(width: 99_999, height: 99_999))
        #expect(huge.size.width <= DemoArtwork.maximumDimension)
        #expect(huge.size.height <= DemoArtwork.maximumDimension)

        let negative = DemoArtwork.image(seed: "x", size: CGSize(width: -10, height: -10))
        #expect(negative.size.width >= 1)
    }

    @Test("三类图片（海报 / 背景 / logo）都能生成")
    func artworkKinds() {
        for kind in [ImageKind.primary, .backdrop, .thumb, .logo] {
            let image = DemoArtwork.image(
                seed: "kind:\(kind.rawValue)",
                kind: kind,
                size: CGSize(width: 120, height: 80)
            )
            #expect(image.size.width == 120)
        }
    }

    // MARK: - 视频合成

    @Test("合成 30 秒样片，并校验时长 / 轨道 / 可播放")
    func synthesizeSampleVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-demo-tests-\(UUID().uuidString)", isDirectory: true)
        let asset = DemoPlaybackAsset(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try #require(await asset.sampleVideoURL())
        #expect(FileManager.default.fileExists(atPath: url.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 0)

        let avAsset = AVURLAsset(url: url)
        let duration = try await avAsset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - Double(DemoPlaybackAsset.durationSeconds)) < 0.5)

        let tracks = try await avAsset.load(.tracks)
        #expect(tracks.count == 2)

        let videoTrack = try #require(tracks.first { $0.mediaType == .video })
        let naturalSize = try await videoTrack.load(.naturalSize)
        #expect(naturalSize == DemoPlaybackAsset.videoSize)

        let audioTrack = try #require(tracks.first { $0.mediaType == .audio })
        #expect(audioTrack.trackID > 0)

        #expect(try await avAsset.load(.isPlayable))
    }

    @Test("样片已存在时直接复用，不重复合成")
    func reusesExistingSample() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-demo-tests-\(UUID().uuidString)", isDirectory: true)
        let asset = DemoPlaybackAsset(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(await asset.sampleVideoURL())
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: first.path)
        let firstDate = try #require(firstAttributes[.modificationDate] as? Date)

        let second = try #require(await asset.sampleVideoURL())
        #expect(first == second)

        let secondAttributes = try FileManager.default.attributesOfItem(atPath: second.path)
        let secondDate = try #require(secondAttributes[.modificationDate] as? Date)
        #expect(firstDate == secondDate, "第二次调用不应重新编码")
    }

    @Test("reset 之后可以重新生成")
    func resetRemovesSample() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-demo-tests-\(UUID().uuidString)", isDirectory: true)
        let asset = DemoPlaybackAsset(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(await asset.sampleVideoURL())
        await asset.reset()
        #expect(!FileManager.default.fileExists(atPath: first.path))

        let second = try #require(await asset.sampleVideoURL())
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("默认目录落在 ~/Library/Caches/<bundleId>/demo")
    func defaultDirectoryLayout() {
        let directory = DemoPlaybackAsset.defaultDirectory()
        #expect(directory.lastPathComponent == "demo")
        #expect(directory.deletingLastPathComponent().lastPathComponent == (Bundle.main.bundleIdentifier ?? "app.prism.Prism"))
        #expect(directory.path.contains("Caches") || directory.path.contains("Temporary"))
    }
}
