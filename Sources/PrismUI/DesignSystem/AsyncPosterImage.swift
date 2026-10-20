import AppKit
import Foundation
import SwiftUI

// MARK: - 加载协议

/// 海报图片加载器协议。
///
/// **这是一层可替换的抽象**：v1.0 先用 ``PassthroughImageLoader``（`URLSession` 直连），
/// 等主管统一引入 Nuke 后，只需新增一个实现了本协议的 `NukeImageLoader`，
/// 在 App 根部注入即可，所有调用点（``PosterCard`` / 详情页）无需改动。
///
/// 协议要求 `Sendable`：加载器会被放进 SwiftUI Environment，可能被多个视图并发读取，
/// 因此实现内部的可变状态必须自己保证线程安全（例如用 actor 或 NSCache）。
public protocol PosterImageLoading: Sendable {
    /// 取一张图。
    ///
    /// - Parameters:
    ///   - url: 图片地址（Emby 的 `/Items/{id}/Images/Primary?...`）。
    ///   - targetSize: 期望的显示尺寸（pt），供实现方做降采样或选择合适档位；
    ///     无法利用时实现方可忽略。
    /// - Returns: 解码好的图片。
    /// - Throws: 网络错误、HTTP 非 2xx、解码失败等。
    func image(for url: URL, targetSize: CGSize) async throws -> NSImage
}

/// 图片加载过程中的错误。
public enum PosterImageError: Error, Sendable, Equatable {
    /// HTTP 响应不是 2xx。
    case httpStatus(Int)
    /// 拿到的字节无法解码成图片。
    case decodingFailed
    /// 没有可用的图片（例如 ``PlaceholderImageLoader``）。
    case unavailable
}

// MARK: - 过渡实现

/// 过渡用的直连加载器：`URLSession` 下载 + `NSImage` 解码。
///
/// **只作过渡**，刻意保持最小实现：
/// - 不做内存缓存（依赖 `URLSession` 的 HTTP 缓存），避免在 `Sendable` 结构体里
///   塞非线程安全的 `NSCache`；
/// - 不做降采样（`targetSize` 仅记录在协议里，留给 Nuke 实现）；
/// - 不重试，失败由 ``AsyncPosterImage`` 展示占位图。
public struct PassthroughImageLoader: PosterImageLoading {
    private let session: URLSession

    /// 创建直连加载器。
    ///
    /// - Parameter session: 下载用的会话，默认 `.shared`；测试时可注入自定义配置。
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 下载并解码一张图。
    ///
    /// - Parameters:
    ///   - url: 图片地址。
    ///   - targetSize: 期望尺寸（本实现忽略，留给 Nuke 做降采样）。
    /// - Returns: 解码好的图片。
    /// - Throws: 网络错误、``PosterImageError/httpStatus(_:)`` 或
    ///   ``PosterImageError/decodingFailed``。
    public func image(for url: URL, targetSize: CGSize) async throws -> NSImage {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PosterImageError.httpStatus(http.statusCode)
        }
        guard let image = NSImage(data: data) else {
            throw PosterImageError.decodingFailed
        }
        return image
    }
}

/// 永远拿不到图的加载器，用于 `#Preview` 与「确定没有海报」的场景。
///
/// 协议签名要求返回 `NSImage`（非可选），因此「返回 nil」在这里表达为
/// 抛出 ``PosterImageError/unavailable``；``AsyncPosterImage`` 收到错误后显示占位图。
public struct PlaceholderImageLoader: PosterImageLoading {
    /// 创建占位加载器。
    public init() {}

    /// 恒定失败：总是抛 ``PosterImageError/unavailable``，让调用方展示占位图。
    ///
    /// - Parameters:
    ///   - url: 图片地址（忽略）。
    ///   - targetSize: 期望尺寸（忽略）。
    /// - Throws: 总是 ``PosterImageError/unavailable``。
    public func image(for url: URL, targetSize: CGSize) async throws -> NSImage {
        throw PosterImageError.unavailable
    }
}

// MARK: - 环境注入

private struct PosterImageLoaderKey: EnvironmentKey {
    static let defaultValue: any PosterImageLoading = PassthroughImageLoader()
}

public extension EnvironmentValues {
    /// 当前使用的海报图片加载器。
    ///
    /// 默认是 ``PassthroughImageLoader``；预览里换成 ``PlaceholderImageLoader``，
    /// 将来换成 Nuke 实现。通过 ``SwiftUI/View/posterImageLoader(_:)`` 注入。
    var posterImageLoader: any PosterImageLoading {
        get { self[PosterImageLoaderKey.self] }
        set { self[PosterImageLoaderKey.self] = newValue }
    }
}

public extension View {
    /// 注入海报图片加载器。
    ///
    /// - Parameter loader: 任意 ``PosterImageLoading`` 实现。
    /// - Returns: 已注入的视图。
    func posterImageLoader(_ loader: any PosterImageLoading) -> some View {
        environment(\.posterImageLoader, loader)
    }
}

// MARK: - 视图

/// 异步海报图。
///
/// 三态：加载中显示骨架、失败显示占位图（**不是空白**）、成功显示图片。
/// 加载器通过 Environment 注入，便于预览与后续替换成 Nuke。
///
/// ```swift
/// AsyncPosterImage(url: item.posterURL, targetSize: CGSize(width: 300, height: 450))
///     .aspectRatio(2.0 / 3.0, contentMode: .fit)
/// ```
///
/// 视图本身不设固定尺寸：它填满父容器并裁剪，比例由调用方用
/// `.aspectRatio(2.0 / 3.0, contentMode: .fit)` 决定。
public struct AsyncPosterImage: View {
    /// 加载阶段。
    private enum Phase {
        case loading
        case success(NSImage)
        case failure
    }

    /// 请求标识：URL 或尺寸变化时重新加载。
    private struct LoadKey: Hashable {
        let url: URL?
        let width: Int
        let height: Int
    }

    private let url: URL?
    private let targetSize: CGSize
    private let contentMode: ContentMode
    private let showsSkeleton: Bool
    private let placeholderText: String?

    @Environment(\.posterImageLoader) private var loader
    @State private var phase: Phase

    /// 创建异步海报图。
    ///
    /// - Parameters:
    ///   - url: 图片地址；`nil` 时直接显示占位图。
    ///   - targetSize: 传给加载器的期望尺寸，默认 300×450（2:3）。
    ///   - contentMode: 图片填充方式，默认 `.fill`（配合父容器的 `clipped()`）。
    ///   - showsSkeleton: 加载中是否显示骨架块；`false` 时显示小菊花。
    ///   - placeholderText: 占位图上显示的文字（通常传标题首字）。
    ///     对应 UX 文档 S05「部分失败（图片）：海报占位 = 标题首字 + 取色背景」；
    ///     `nil` 时只显示图片符号。
    public init(
        url: URL?,
        targetSize: CGSize = CGSize(width: 300, height: 450),
        contentMode: ContentMode = .fill,
        showsSkeleton: Bool = true,
        placeholderText: String? = nil
    ) {
        self.url = url
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.showsSkeleton = showsSkeleton
        self.placeholderText = placeholderText
        _phase = State(initialValue: url == nil ? .failure : .loading)
    }

    public var body: some View {
        ZStack {
            Palette.surfaceElevated

            switch phase {
            case .loading:
                if showsSkeleton {
                    SkeletonView(cornerRadius: 0)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case let .success(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder
            }
        }
        .clipped()
        .task(id: loadKey) {
            await load()
        }
    }

    private var loadKey: LoadKey {
        LoadKey(
            url: url,
            width: Int(targetSize.width.rounded()),
            height: Int(targetSize.height.rounded())
        )
    }

    /// 加载失败 / 无图时的占位：淡淡的底 + 首字（或图片符号），避免出现「一块空白」。
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.surfaceElevated, Palette.surface],
                startPoint: .top,
                endPoint: .bottom
            )

            if let placeholderText, let initial = placeholderText.first {
                Text(String(initial))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textSecondary.opacity(0.55))
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func load() async {
        guard let url else {
            phase = .failure
            return
        }

        phase = .loading
        do {
            let image = try await loader.image(for: url, targetSize: targetSize)
            guard !Task.isCancelled else { return }
            phase = .success(image)
        } catch is CancellationError {
            // 取消通常意味着 URL 变了或视图消失，保留当前画面，避免闪一下占位图。
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure
        }
    }
}

// MARK: - 预览

private struct AsyncPosterImagePreviewBoard: View {
    private let successURL = URL(string: "https://preview.prism.invalid/poster/ok.jpg")
    private let failureURL = URL(string: "https://preview.prism.invalid/poster/fail.jpg")

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            column("成功") {
                AsyncPosterImage(url: successURL)
            }
            column("失败") {
                AsyncPosterImage(url: failureURL)
            }
            column("无图") {
                AsyncPosterImage(url: nil)
            }
        }
        .padding(Spacing.xl)
        .background(Palette.surface)
    }

    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: Spacing.sm) {
            content()
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: 130)
                .clipShape(RoundedRectangle(cornerRadius: Radius.poster, style: .continuous))
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

#Preview("AsyncPosterImage · 深色") {
    AsyncPosterImagePreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

#Preview("AsyncPosterImage · 浅色") {
    AsyncPosterImagePreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
        .environment(\.posterImageLoader, PreviewImageLoader())
}

// MARK: - 与数据层的桥接

// `PosterImageLoading` 定义在 PrismUI（依赖方向 PrismUI → PrismData），
// 而 `EmbyImageLoader` 在 PrismData。协议遵循必须由**下游模块**补：
// 这是 Swift 允许的「给外部类型补协议遵循」，不需要把协议下沉、
// 也不需要造 adapter struct。
//
// 前置条件：`EmbyImageLoader.image(for:targetSize:)` 的方法签名必须与本协议逐字一致
// （已由 `PrismData/Images/EmbyImageLoader.swift` 保证）。
#if canImport(PrismData)
import PrismData

extension EmbyImageLoader: PosterImageLoading {}
#endif
