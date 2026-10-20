import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import PrismCore
import os

/// 演示模式用的**合成视频**：首次启动时用 `AVAssetWriter` 现做一个 30 秒的样片。
///
/// ## 为什么不打包一个 mp4 进仓库
///
/// 一段 30 秒的 1080p 样片至少几 MB，而且二进制文件进了 git 就再也删不掉。
/// 用 `AVAssetWriter` 现场合成：仓库零体积、内容可版本化（改代码就改样片），
/// 而且能顺带验证「编码 → 落盘 → 播放器读取」这条链路。
///
/// ## 产物
///
/// - 位置：`FileManager.cachesDirectory/<bundleId>/demo/sample.mp4`
///   （非沙盒进程解析为 `~/Library/Caches/...`；本 App 开了 App Sandbox，
///   实际落在 `~/Library/Containers/app.prism.Prism/Data/Library/Caches/...`，
///   两者都可写。见 `App/Prism.entitlements` 的 `com.apple.security.app-sandbox`。）
/// - 规格：H.264 / 960×540 / 10 fps / 30 秒 + AAC 单声道静音音轨
/// - 画面：按时间推进的渐变 + 时间码文字（`PRISM DEMO 00:12.3`）
///
/// ## 两个必须记住的实现坑（本机实测，2026-10-21）
///
/// 1. **不能在主线程合成**：在 `@MainActor` 上跑同一个循环时，写到第 17~35 帧后
///    `isReadyForMoreMediaData` 会永远返回 `false`，进程挂死。放到
///    `DispatchQueue.global` 上跑则 30 秒视频不到 1 秒就能编完。
/// 2. **音轨与视频轨必须并发喂数据**：如果先喂完视频再喂音频，视频输入会在
///    第 35 帧左右卡住（音频输入是空的，writer 不推进）。正确做法是两个队列
///    同时写入，各自 `markAsFinished()`，最后 `finishWriting`。
///
/// ## 失败策略
///
/// 合成失败**绝不崩溃**：记录日志并返回 `nil`，播放器自行显示错误态。
/// 演示模式的意义是「没有服务器也能看界面」，不该因为编码器不可用而挂掉整个 App。
///
/// 参考文档：
/// - `AVAssetWriter`：<https://developer.apple.com/documentation/avfoundation/avassetwriter>
/// - `AVAssetWriterInputPixelBufferAdaptor`：<https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor>
/// - `CMAudioSampleBufferCreateReadyWithPacketDescriptions`：<https://developer.apple.com/documentation/coremedia/cmaudiosamplebuffercreatereadywithpacketdescriptions(allocator:databuffer:formatdescription:samplecount:presentationtimestamp:packetdescriptions:samplebufferout:)>
/// - `AVVideoCodecType.h264`：<https://developer.apple.com/documentation/avfoundation/avvideocodectype/h264>
public actor DemoPlaybackAsset {

    /// 共享实例：使用默认缓存目录。
    public static let shared = DemoPlaybackAsset()

    /// 样片时长（秒）。
    public static let durationSeconds = 30

    /// 样片分辨率。
    public static let videoSize = CGSize(width: 960, height: 540)

    /// 样片帧率。
    public static let frameRate = 10

    /// 存放样片的目录。
    public let directory: URL

    /// 日志出口。
    private let logger: any Logging

    /// 正在进行的合成任务（用于合并并发请求，避免重复编码）。
    private var inFlight: Task<URL?, Never>?

    /// 创建一个样片提供者。
    ///
    /// - Parameters:
    ///   - directory: 样片目录；`nil` 时使用 `~/Library/Caches/<bundleId>/demo`。
    ///     测试应传入工作区内的临时目录，避免污染用户缓存。
    ///   - logger: 日志出口；`nil` 时使用 `demo` 分类的 ``PrismCore/OSLogger``。
    public init(directory: URL? = nil, logger: (any Logging)? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.logger = logger ?? OSLogger(category: "demo")
    }

    /// 样片的最终路径（不一定存在）。
    public var videoURL: URL {
        directory.appendingPathComponent("sample.mp4", isDirectory: false)
    }

    /// 取样片路径；文件不存在时现场合成。
    ///
    /// 已存在且非空时直接返回，不重复编码。多个调用并发进来时共享同一次合成。
    ///
    /// - Returns: 可播放的视频文件路径；合成失败时为 `nil`（调用方应展示错误态）。
    /// - Throws: 目前不抛错——合成失败通过返回值 `nil` 表达。保留 `async throws`
    ///   是为了与真实「下载 / 解包样片」的实现保持同一签名。
    public func sampleVideoURL() async throws -> URL? {
        if let existing = existingVideoURL() {
            return existing
        }
        if let inFlight {
            return await inFlight.value
        }

        let target = videoURL
        let directory = self.directory
        let logger = self.logger
        let task = Task<URL?, Never> {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                logger.error("演示视频目录创建失败：\(error.localizedDescription)")
                return nil
            }

            let temporary = directory.appendingPathComponent("sample-\(UUID().uuidString).mp4")
            let failure = await Self.render(to: temporary)
            if let failure {
                try? FileManager.default.removeItem(at: temporary)
                logger.error("演示视频合成失败：\(failure)")
                return nil
            }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temporary, to: target)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                logger.error("演示视频落盘失败：\(error.localizedDescription)")
                return nil
            }
            logger.info("演示视频已生成", metadata: ["path": target.lastPathComponent])
            return target
        }

        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// 删除已生成的样片（调试用：想重新合成时调用）。
    public func reset() {
        try? FileManager.default.removeItem(at: videoURL)
    }

    // MARK: - 路径

    /// 默认缓存目录：`~/Library/Caches/<bundleId>/demo`。
    ///
    /// - Returns: 目录 URL（不保证已创建）。
    public static func defaultDirectory() -> URL {
        // 测试进程（swift test）里 `Bundle.main.bundleIdentifier` 是测试宿主或 nil，
        // 用固定兜底值保证路径稳定。
        let bundleID = Bundle.main.bundleIdentifier ?? "app.prism.Prism"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
    }

    /// 已存在且可用的样片路径。
    ///
    /// - Returns: 文件路径；不存在或大小为 0 时为 `nil`。
    private func existingVideoURL() -> URL? {
        let url = videoURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            // 上次合成中断留下的空文件：删掉重来。
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    // MARK: - 合成

    /// 在后台队列上执行合成。
    ///
    /// 必须离开主线程（见类型文档里的「实现坑 1」）。
    ///
    /// - Parameter url: 输出路径。
    /// - Returns: 失败原因；成功时为 `nil`。
    private static func render(to url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let failure = synthesize(to: url)
                continuation.resume(returning: failure)
            }
        }
    }

    /// 同步合成一段 30 秒样片。
    ///
    /// - Parameter url: 输出路径。
    /// - Returns: 失败原因；成功时为 `nil`。
    private static func synthesize(to url: URL) -> String? {
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        let fps = frameRate
        let totalFrames = fps * durationSeconds

        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            return "创建 AVAssetWriter 失败：\(error.localizedDescription)"
        }

        // MARK: 视频轨
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_200_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(videoInput) else { return "writer 拒绝视频轨" }
        writer.add(videoInput)

        // MARK: 音轨（静音）
        let sampleRate = 44_100.0
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        guard writer.canAdd(audioInput) else { return "writer 拒绝音轨" }
        writer.add(audioInput)

        guard writer.startWriting() else {
            return "startWriting 失败：\(writer.error?.localizedDescription ?? "未知")"
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: 静音 PCM 的格式描述
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let audioFormat = formatDescription else {
            return "音频格式描述创建失败（\(formatStatus)）"
        }

        // MARK: 并发喂数据
        //
        // 音轨在独立队列上写，视频轨在当前（后台）线程写。**顺序不能反**：
        // 先喂完一条再喂另一条会让 writer 卡死（见类型文档里的「实现坑 2」）。
        let group = DispatchGroup()
        let audioResult = OSAllocatedUnfairLock<String?>(initialState: nil)
        // `AVAssetWriterInput` 不是 `Sendable`，但它在本方法内被独占使用：
        // 音轨队列是唯一写入方，视频轨走另一个 input，且 `group.wait()` 保证
        // 两者在 `finishWriting` 之前都已结束。这里用显式的「不检查」包装表达该不变式。
        let sharedAudioInput = UncheckedSendable(value: audioInput)

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = appendSilence(
                to: sharedAudioInput.value,
                format: audioFormat,
                sampleRate: sampleRate,
                seconds: durationSeconds
            )
            sharedAudioInput.value.markAsFinished()
            audioResult.withLock { $0 = failure }
            group.leave()
        }

        let videoFailure = appendFrames(
            to: adaptor,
            input: videoInput,
            width: width,
            height: height,
            fps: fps,
            totalFrames: totalFrames
        )
        videoInput.markAsFinished()
        group.wait()

        if let videoFailure {
            writer.cancelWriting()
            return videoFailure
        }
        if let audioFailure = audioResult.withLock({ $0 }) {
            writer.cancelWriting()
            return audioFailure
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            return "finishWriting 超时"
        }
        guard writer.status == .completed else {
            return "writer 状态异常：\(writer.status.rawValue)，\(writer.error?.localizedDescription ?? "未知")"
        }
        return nil
    }

    /// 逐帧写入画面。
    ///
    /// - Parameters:
    ///   - adaptor: 像素缓冲适配器。
    ///   - input: 视频输入。
    ///   - width: 宽。
    ///   - height: 高。
    ///   - fps: 帧率。
    ///   - totalFrames: 总帧数。
    /// - Returns: 失败原因；成功时为 `nil`。
    private static func appendFrames(
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        width: Int,
        height: Int,
        fps: Int,
        totalFrames: Int
    ) -> String? {
        // 输入长时间不就绪就放弃，避免无限等待把调用方挂死。
        var stalledPolls = 0
        let stallLimit = 8_000

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                stalledPolls += 1
                if stalledPolls > stallLimit {
                    return "视频输入在第 \(frame) 帧处长时间不就绪"
                }
                usleep(1_000)
            }
            guard let pool = adaptor.pixelBufferPool else { return "像素缓冲池不可用" }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer else {
                return "像素缓冲分配失败（第 \(frame) 帧）"
            }
            drawFrame(
                into: buffer,
                width: width,
                height: height,
                frame: frame,
                fps: fps,
                totalFrames: totalFrames
            )
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                return "第 \(frame) 帧写入失败"
            }
        }
        return nil
    }

    /// 画一帧：渐变背景 + 时间码。
    ///
    /// - Parameters:
    ///   - buffer: 目标像素缓冲。
    ///   - width: 宽。
    ///   - height: 高。
    ///   - frame: 帧序号。
    ///   - fps: 帧率。
    ///   - totalFrames: 总帧数。
    private static func drawFrame(
        into buffer: CVPixelBuffer,
        width: Int,
        height: Int,
        frame: Int,
        fps: Int,
        totalFrames: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return }

        let phase = Double(frame) / Double(max(totalFrames - 1, 1))

        // 渐变：随播放进度缓慢偏移，肉眼能看出「画面在动」。
        let top = CGColor(red: 0.08 + 0.22 * phase, green: 0.06, blue: 0.38 - 0.12 * phase, alpha: 1)
        let bottom = CGColor(red: 0.58 - 0.22 * phase, green: 0.14 + 0.10 * phase, blue: 0.44, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [top, bottom] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: CGPoint(x: CGFloat(width), y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // 进度条：让「播到哪儿了」一眼可见。
        let progressWidth = CGFloat(width) * CGFloat(phase)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        context.fill(CGRect(x: 0, y: 0, width: progressWidth, height: CGFloat(height) * 0.012))

        // 时间码文字。
        let seconds = Double(frame) / Double(fps)
        let text = String(format: "PRISM DEMO  %05.1fs", seconds)
        let fontSize = CGFloat(height) * 0.11
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.46)
        CTLineDraw(line, context)
    }

    /// 写入静音音轨（16-bit 单声道 PCM → AAC）。
    ///
    /// - Parameters:
    ///   - input: 音频输入。
    ///   - format: PCM 格式描述。
    ///   - sampleRate: 采样率。
    ///   - seconds: 时长。
    /// - Returns: 失败原因；成功时为 `nil`。
    private static func appendSilence(
        to input: AVAssetWriterInput,
        format: CMAudioFormatDescription,
        sampleRate: Double,
        seconds: Int
    ) -> String? {
        let chunkSize = 1_024
        let zeros = [UInt8](repeating: 0, count: chunkSize * 2)
        let totalSamples = Int(sampleRate * Double(seconds))
        var written = 0
        var stalledPolls = 0

        while written < totalSamples {
            guard input.isReadyForMoreMediaData else {
                stalledPolls += 1
                if stalledPolls > 8_000 { return "音频输入长时间不就绪" }
                usleep(1_000)
                continue
            }
            let count = min(chunkSize, totalSamples - written)
            let bytes = Array(zeros.prefix(count * 2))

            var block: CMBlockBuffer?
            let status = bytes.withUnsafeBytes { raw -> OSStatus in
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: bytes.count,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: bytes.count,
                    flags: 0,
                    blockBufferOut: &block
                )
                guard let block, let baseAddress = raw.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: bytes.count
                )
            }
            guard status == noErr, let block else { return "音频数据块创建失败（\(status)）" }

            var sample: CMSampleBuffer?
            let presentationTime = CMTime(
                value: CMTimeValue(written),
                timescale: CMTimeScale(sampleRate)
            )
            let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: count,
                presentationTimeStamp: presentationTime,
                packetDescriptions: nil,
                sampleBufferOut: &sample
            )
            guard sampleStatus == noErr, let sample else {
                return "音频采样缓冲创建失败（\(sampleStatus)）"
            }
            guard input.append(sample) else { return "音频采样写入失败" }
            written += count
        }
        return nil
    }
}

// MARK: - 并发包装

/// 把一个非 `Sendable` 值显式标记为可跨并发域传递。
///
/// 只在本文件内使用，且每一处都附带了「为什么安全」的不变式说明。
/// 它不做任何同步——同步责任在调用方。
private struct UncheckedSendable<Value>: @unchecked Sendable {
    /// 被包装的值。
    let value: Value
}
