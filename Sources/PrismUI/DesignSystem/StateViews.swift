import SwiftUI
import PrismCore

// MARK: - 空态

/// 空态视图：图标 + 标题 + 说明 + 可选主操作。
///
/// 文案按 `docs/research/ux-benchmark.md` §3.0 的「空态三件套」设计：
/// 一句解释 + 一个明确的下一步动作，不要只留一句「暂无数据」。
///
/// ```swift
/// EmptyStateView(
///     systemImage: "rectangle.on.rectangle.slash",
///     title: "媒体库是空的",
///     message: "在 Emby 中添加媒体库后刷新。",
///     actionTitle: "刷新"
/// ) { viewModel.refresh() }
/// ```
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let actionTitle: LocalizedStringKey?
    private let actionSystemImage: String?
    private let action: (() -> Void)?

    /// 创建空态视图。
    ///
    /// - Parameters:
    ///   - systemImage: SF Symbol 名，默认 `rectangle.on.rectangle.slash`。
    ///   - title: 主标题。
    ///   - message: 补充说明，可选。
    ///   - actionTitle: 主操作按钮标题；为 `nil` 时不显示按钮。
    ///   - actionSystemImage: 主操作按钮的 SF Symbol，可选。
    ///   - action: 主操作回调；`actionTitle` 非空时才会使用。
    public init(
        systemImage: String = "rectangle.on.rectangle.slash",
        title: LocalizedStringKey = "这里还什么都没有",
        message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        actionSystemImage: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.action = action
    }

    public var body: some View {
        StateContentLayout(
            systemImage: systemImage,
            title: title,
            message: message,
            iconColor: Palette.textSecondary
        ) {
            if let actionTitle, let action {
                PrismPrimaryButton(actionTitle, systemImage: actionSystemImage, action: action)
            }
        }
    }
}

// MARK: - 错误态

/// 错误态视图：图标 + 标题 + 原因 + 重试按钮。
///
/// **文案来源**：原因直接用 ``PrismCore/EmbyError/userMessage``。该属性是
/// `LocalizedStringResource`，key 与中英文案由 PrismCore 统一维护
/// （中文为默认值，English 文案在 String Catalog 建条目后即可自动切换），
/// 因此这里**不再自行拼错误字符串**，避免两处文案不一致。
///
/// **重试按钮**：只有 `error.isRecoverable == true` 且传入了 `onRetry` 才显示——
/// 401/403/404/解码失败重试多少次都不会变好，给按钮只会误导用户。
public struct ErrorStateView: View {
    private let error: EmbyError
    private let title: LocalizedStringKey?
    private let retryTitle: LocalizedStringKey
    private let onRetry: (() -> Void)?
    private let showsTechnicalDetail: Bool

    /// 创建错误态视图。
    ///
    /// - Parameters:
    ///   - error: 统一的 Emby 错误。
    ///   - title: 标题；`nil` 时按错误类型自动给一个（如「无法连接到服务器」）。
    ///   - retryTitle: 重试按钮标题，默认「重试」。
    ///   - onRetry: 重试回调；错误不可恢复时即使传入也不会显示按钮。
    ///   - showsTechnicalDetail: 是否显示 `debugDescription`（排障用，默认关闭）。
    public init(
        error: EmbyError,
        title: LocalizedStringKey? = nil,
        retryTitle: LocalizedStringKey = "重试",
        onRetry: (() -> Void)? = nil,
        showsTechnicalDetail: Bool = false
    ) {
        self.error = error
        self.title = title
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        self.showsTechnicalDetail = showsTechnicalDetail
    }

    public var body: some View {
        StateContentLayout(
            systemImage: Self.symbol(for: error),
            title: title ?? Self.defaultTitle(for: error),
            message: nil,
            iconColor: Palette.textSecondary
        ) {
            VStack(spacing: Spacing.md) {
                Text(error.userMessage)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if showsTechnicalDetail {
                    Text(verbatim: error.debugDescription)
                        .font(Typography.monoTime)
                        .foregroundStyle(Palette.textSecondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if error.isRecoverable, let onRetry {
                    PrismPrimaryButton(retryTitle, systemImage: "arrow.clockwise", action: onRetry)
                        .padding(.top, Spacing.xs)
                }
            }
        }
        .help(showsTechnicalDetail ? Text(verbatim: error.debugDescription) : Text(""))
    }

    /// 按错误类型选图标（全部是长期存在的 SF Symbol，避免系统版本差异）。
    private static func symbol(for error: EmbyError) -> String {
        switch error {
        case .invalidURL:
            "link"
        case .unauthorized, .forbidden:
            "lock.fill"
        case .notFound:
            "questionmark.folder"
        case .serverUnreachable, .timeout:
            "wifi.exclamationmark"
        case .decoding:
            "doc.questionmark"
        case .server:
            "server.rack"
        case .cancelled:
            "xmark.circle"
        case .unknown:
            "exclamationmark.triangle"
        }
    }

    /// 默认标题：说清「发生了什么」，具体原因交给 `userMessage`。
    private static func defaultTitle(for error: EmbyError) -> LocalizedStringKey {
        switch error {
        case .invalidURL:
            "服务器地址无效"
        case .unauthorized:
            "登录已失效"
        case .forbidden:
            "没有访问权限"
        case .notFound:
            "找不到内容"
        case .serverUnreachable, .timeout:
            "无法连接到服务器"
        case .decoding:
            "无法读取服务器数据"
        case .server:
            "服务器出错了"
        case .cancelled:
            "操作已取消"
        case .unknown:
            "出了点问题"
        }
    }
}

// MARK: - 加载态

/// 加载态视图：骨架屏或菊花。
///
/// 按 UX 文档 §3.0：列表/网格默认用**骨架屏**（保留布局，避免内容出现时跳动），
/// 只有「预计 300ms 内完成」的短操作才用菊花。
public struct LoadingStateView: View {
    /// 加载态样式。
    public enum Style: Sendable, Hashable {
        /// 居中菊花（适合按钮级、短操作）。
        case spinner
        /// 海报网格骨架。
        case posterGrid(count: Int)
        /// 列表行骨架（左图右文）。
        case list(rows: Int)
    }

    private let style: Style
    private let message: LocalizedStringKey?

    /// 创建加载态视图。
    ///
    /// - Parameters:
    ///   - style: 样式，默认 ``Style/spinner``。
    ///   - message: 菊花下方的说明文字，可选。
    public init(style: Style = .spinner, message: LocalizedStringKey? = nil) {
        self.style = style
        self.message = message
    }

    public var body: some View {
        switch style {
        case .spinner:
            VStack(spacing: Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                if let message {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .posterGrid(count):
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Spacing.lg)],
                spacing: Spacing.xl
            ) {
                ForEach(0..<max(count, 1), id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SkeletonView(cornerRadius: Radius.poster)
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        SkeletonView().frame(height: 14)
                        SkeletonView().frame(width: 64, height: 11)
                    }
                }
            }
            .padding(Spacing.xl)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("正在加载"))

        case let .list(rows):
            VStack(spacing: Spacing.md) {
                ForEach(0..<max(rows, 1), id: \.self) { _ in
                    HStack(spacing: Spacing.md) {
                        SkeletonView(cornerRadius: Radius.poster)
                            .frame(width: 96, height: 54)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            SkeletonView().frame(height: 14)
                            SkeletonView().frame(width: 120, height: 11)
                        }
                    }
                }
            }
            .padding(Spacing.xl)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("正在加载"))
        }
    }
}

// MARK: - LoadState 映射

/// 把 ``PrismCore/LoadState`` 映射成「加载中 / 有数据 / 空 / 错误」四种画面。
///
/// 一般不需要直接使用本类型，用 ``SwiftUI/View/stateView(_:emptyState:onRetry:content:)``
/// 更方便（它把当前视图当作加载中占位）。
public struct LoadStateView<Value: Sendable & Equatable, Placeholder: View, Content: View>: View {
    private let state: LoadState<Value>
    private let emptyState: EmptyStateView
    private let onRetry: (() -> Void)?
    private let placeholder: Placeholder
    private let content: (Value) -> Content

    /// 创建状态容器。
    ///
    /// - Parameters:
    ///   - state: 视图模型给出的加载状态。
    ///   - emptyState: 空态画面，默认 ``EmptyStateView``。
    ///   - onRetry: 错误可恢复时的重试回调。
    ///   - placeholder: `.idle` / `.loading` 时显示的占位视图（通常是骨架屏）。
    ///   - content: `.loaded` 时的内容构建器。
    public init(
        state: LoadState<Value>,
        emptyState: EmptyStateView = EmptyStateView(),
        onRetry: (() -> Void)? = nil,
        @ViewBuilder placeholder: () -> Placeholder,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.emptyState = emptyState
        self.onRetry = onRetry
        self.placeholder = placeholder()
        self.content = content
    }

    public var body: some View {
        switch state {
        case .idle, .loading:
            placeholder
        case let .loaded(value):
            content(value)
        case .empty:
            emptyState
        case let .failed(error):
            ErrorStateView(error: error, onRetry: onRetry)
        }
    }
}

public extension View {
    /// 以当前视图为「加载中占位」，按 ``PrismCore/LoadState`` 切换四态。
    ///
    /// ```swift
    /// LoadingStateView(style: .posterGrid(count: 12))
    ///     .stateView(viewModel.state, onRetry: { Task { await viewModel.refresh() } }) { items in
    ///         PosterGrid(items: items)
    ///     }
    /// ```
    ///
    /// - Parameters:
    ///   - state: 视图模型状态。
    ///   - emptyState: 空态画面。
    ///   - onRetry: 可恢复错误的重试回调。
    ///   - content: 有数据时的内容构建器。
    /// - Returns: 按状态切换后的视图。
    func stateView<Value: Sendable & Equatable>(
        _ state: LoadState<Value>,
        emptyState: EmptyStateView = EmptyStateView(),
        onRetry: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Value) -> some View
    ) -> some View {
        LoadStateView(
            state: state,
            emptyState: emptyState,
            onRetry: onRetry,
            placeholder: { self },
            content: content
        )
    }
}

// MARK: - 共用排版

/// 空态 / 错误态共用的纵向排版，保证两者视觉节奏一致。
private struct StateContentLayout<Actions: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let iconColor: Color
    let actions: Actions

    init(
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey?,
        iconColor: Color,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.iconColor = iconColor
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text(title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 预览

#Preview("空态 · 深色") {
    EmptyStateView(
        systemImage: "rectangle.on.rectangle.slash",
        title: "媒体库是空的",
        message: "在 Emby 中添加媒体库后，回到这里刷新即可。",
        actionTitle: "刷新",
        actionSystemImage: "arrow.clockwise"
    ) {}
    .prismTheme(PrismTheme(appearance: .dark))
    .background(Palette.surface)
    .frame(width: 520, height: 360)
}

#Preview("空态 · 浅色") {
    EmptyStateView(
        systemImage: "rectangle.on.rectangle.slash",
        title: "媒体库是空的",
        message: "在 Emby 中添加媒体库后，回到这里刷新即可。",
        actionTitle: "刷新",
        actionSystemImage: "arrow.clockwise"
    ) {}
    .prismTheme(PrismTheme(appearance: .light))
    .background(Palette.surface)
    .frame(width: 520, height: 360)
}

#Preview("错误态 · 深色") {
    ErrorStateView(error: .serverUnreachable("连接被拒绝"), onRetry: {})
        .prismTheme(PrismTheme(appearance: .dark))
        .background(Palette.surface)
        .frame(width: 520, height: 360)
}

#Preview("错误态 · 浅色") {
    ErrorStateView(error: .timeout, onRetry: {}, showsTechnicalDetail: true)
        .prismTheme(PrismTheme(appearance: .light))
        .background(Palette.surface)
        .frame(width: 520, height: 400)
}

#Preview("加载态 · 深色") {
    LoadingStateView(style: .posterGrid(count: 6))
        .prismTheme(PrismTheme(appearance: .dark))
        .background(Palette.surface)
        .frame(width: 620, height: 520)
}

#Preview("加载态 · 浅色") {
    LoadingStateView(style: .list(rows: 5))
        .prismTheme(PrismTheme(appearance: .light))
        .background(Palette.surface)
        .frame(width: 520, height: 400)
}
