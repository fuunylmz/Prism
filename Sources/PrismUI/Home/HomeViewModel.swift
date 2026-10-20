import Foundation
import Observation
import PrismCore

// MARK: - 分区

/// 首页的四个内容分区。
///
/// 顺序即 `docs/research/ux-benchmark.md` §S04 的固定四段式：
/// 继续观看 → 接下来 → 最新添加 → 媒体库。
public enum HomeSection: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// 继续观看。
    case resume
    /// 接下来（剧集的下一集）。
    case nextUp
    /// 最新添加。
    case latest
    /// 媒体库入口。
    case libraries

    /// `Identifiable` 要求的稳定 id。
    public var id: String { rawValue }

    /// 分区标题（用于分区头与「部分加载失败」提示）。
    public var title: String {
        switch self {
        case .resume: "继续观看"
        case .nextUp: "接下来"
        case .latest: "最新添加"
        case .libraries: "媒体库"
        }
    }
}

// MARK: - 内容

/// 首页一次加载拿到的全部内容。
///
/// 四个数组**互相独立**：某个分区拉取失败时它是空数组，页面仍会显示其他分区
/// （部分成功策略，见 ``HomeViewModel``）。
///
/// - Note: 契约里只写了 `Sendable`，这里额外要求 `Equatable`——
///   ``PrismCore/LoadState`` 的泛型约束就是 `Sendable & Equatable`，
///   没有它无法表达 `LoadState<HomeContent>`。
public struct HomeContent: Sendable, Equatable {
    /// 继续观看。
    public let resume: [MediaItem]
    /// 接下来（剧集下一集）。
    public let nextUp: [MediaItem]
    /// 最新添加。
    public let latest: [MediaItem]
    /// 媒体库入口。
    public let libraries: [MediaItem]

    /// 创建首页内容。
    ///
    /// - Parameters:
    ///   - resume: 继续观看。
    ///   - nextUp: 接下来。
    ///   - latest: 最新添加。
    ///   - libraries: 媒体库入口。
    public init(
        resume: [MediaItem] = [],
        nextUp: [MediaItem] = [],
        latest: [MediaItem] = [],
        libraries: [MediaItem] = []
    ) {
        self.resume = resume
        self.nextUp = nextUp
        self.latest = latest
        self.libraries = libraries
    }

    /// 四个分区是否都为空（决定整页 `.empty`）。
    public var isEmpty: Bool {
        resume.isEmpty && nextUp.isEmpty && latest.isEmpty && libraries.isEmpty
    }

    /// 取某个分区的条目。
    ///
    /// - Parameter section: 分区。
    /// - Returns: 该分区的条目（可能为空）。
    public func items(in section: HomeSection) -> [MediaItem] {
        switch section {
        case .resume: resume
        case .nextUp: nextUp
        case .latest: latest
        case .libraries: libraries
        }
    }
}

// MARK: - 单个分区的拉取结果

/// 一个分区的拉取结果。
///
/// 单独建模而不是用 `Result` 元组，是为了让 `withThrowingTaskGroup` 的元素类型
/// 明确 `Sendable`，并在日志 / 测试里一眼看出是哪个分区失败。
private struct SectionOutcome: Sendable {
    /// 分区。
    let section: HomeSection
    /// 该分区的结果。
    let result: Result<[MediaItem], EmbyError>
}

// MARK: - 视图模型

/// 首页视图模型。
///
/// 职责只有三件事：
/// 1. **并发**拉取四个分区（`withThrowingTaskGroup`）；
/// 2. **部分成功**：任一分区失败不影响其他分区，失败的记进 ``sectionErrors``，
///    页面顶部显示一条内联错误条；
/// 3. 把结果折叠成 ``PrismCore/LoadState``：
///    - 四个都失败 → `.failed`（整页错误 + 重试）；
///    - 四个都成功但全空 → `.empty`；
///    - 其余 → `.loaded`（空分区由视图直接隐藏）。
///
/// 本类型**不 import SwiftUI** 的视图 API（只用到 `Observable`），也不碰网络细节：
/// 数据来自注入的 ``HomeDataSource``。
///
/// ```swift
/// let model = HomeViewModel(dataSource: dataSource)
/// await model.load()          // 首屏
/// await model.refresh()       // ⌘R / 错误条上的「重试」
/// ```
@MainActor
@Observable
public final class HomeViewModel {
    // MARK: 状态

    /// 当前加载状态。
    public private(set) var state: LoadState<HomeContent>

    /// 各分区的失败原因（只记录失败的分区）。
    ///
    /// 非空且 ``state`` 是 `.loaded` 时，页面显示「部分内容加载失败」内联条；
    /// 全部失败时这些错误已经折叠进 ``state`` 的 `.failed`。
    public private(set) var sectionErrors: [HomeSection: EmbyError]

    /// 是否正在刷新（保留旧内容，不显示骨架屏）。
    public private(set) var isRefreshing: Bool

    // MARK: 依赖

    /// 数据源。
    private let dataSource: any HomeDataSource

    /// 是否有一次加载正在进行（防止 `.task` 与 ⌘R 重入）。
    private var isFetching = false

    // MARK: 初始化

    /// 创建视图模型。
    ///
    /// - Parameter dataSource: 首页数据源（真实 / 演示 / 预览实现均可）。
    public init(dataSource: any HomeDataSource) {
        self.dataSource = dataSource
        self.state = .idle
        self.sectionErrors = [:]
        self.isRefreshing = false
    }

    // MARK: 派生状态

    /// 是否处于加载中（首屏骨架或刷新中）。
    public var isLoading: Bool {
        state.isLoading || isRefreshing
    }

    /// 是否存在「部分分区失败」。
    public var hasPartialFailure: Bool {
        !sectionErrors.isEmpty
    }

    /// 「部分内容加载失败」的说明文案。
    ///
    /// 形如「继续观看、接下来加载失败」。按 ``HomeSection/allCases`` 的顺序拼接，
    /// 保证同一组失败每次文案一致。
    public var partialFailureMessage: String {
        let names = HomeSection.allCases
            .filter { sectionErrors[$0] != nil }
            .map(\.title)
        guard !names.isEmpty else { return "部分内容加载失败" }
        return "\(names.joined(separator: "、"))加载失败"
    }

    // MARK: 加载

    /// 首屏加载。
    ///
    /// 已有内容时不再打网络：视图的 `.task` 会因路由切换、窗口重建重复触发，
    /// 已加载过就不必重取。需要强制重取时用 ``refresh()``。
    ///
    /// - Important: `.loading` 时**仍会重试**。一次 `.task` 可能被取消
    ///   （用户切走页面、窗口重建），此时状态会停在 `.loading`；若这里把 `.loading`
    ///   当作「已有人负责」直接返回，页面就会永远停在骨架屏上。用 ``isFetching``
    ///   区分「真的有一次请求在飞」与「上一次被取消了」。
    public func load() async {
        guard !isFetching else { return }
        switch state {
        case .idle, .loading, .failed:
            await reload(showsSkeleton: true)
        case .loaded, .empty:
            return
        }
    }

    /// 刷新（⌘R / 错误条「重试」/ 空态「刷新」）。
    ///
    /// 与 ``load()`` 的区别：**不切回骨架屏**，已有内容保持可见，只在右上角转圈，
    /// 避免刷新时整页闪一下。
    public func refresh() async {
        await reload(showsSkeleton: false)
    }

    /// 真正执行一次拉取。
    ///
    /// - Parameter showsSkeleton: 是否先切到 `.loading`（首屏为 `true`）。
    private func reload(showsSkeleton: Bool) async {
        guard !isFetching else { return }
        isFetching = true
        defer {
            isFetching = false
            isRefreshing = false
        }

        if showsSkeleton {
            state = .loading
        } else {
            isRefreshing = true
        }

        let outcomes = await Self.fetchAll(from: dataSource)

        // 视图消失 / 路由切走导致的取消：保留上一次的画面，不要把状态写成失败。
        guard !Task.isCancelled else { return }

        // 兜底：一个结果都没拿到（理论上只可能是取消）时不要误判成 `.empty`。
        guard !outcomes.isEmpty else { return }

        var content = HomeContent()
        var errors: [HomeSection: EmbyError] = [:]

        for outcome in outcomes {
            switch outcome.result {
            case let .success(items):
                content = Self.merging(items, into: content, for: outcome.section)
            case let .failure(error):
                errors[outcome.section] = error
            }
        }

        sectionErrors = errors

        if errors.count == HomeSection.allCases.count {
            // 四个分区全挂：整页错误（服务器离线 / 令牌失效等），给「重试」。
            state = .failed(Self.primaryError(from: errors))
        } else if content.isEmpty {
            // 全空：新用户没有观看记录，或服务器上一个媒体库都没有。
            state = .empty
        } else {
            state = .loaded(content)
        }
    }

    // MARK: 并发拉取

    /// 并发拉取四个分区，**永不整体失败**。
    ///
    /// 每个子任务自己吞掉错误并返回 ``SectionOutcome``；只有任务取消会向上抛，
    /// 由调用方用 `Task.isCancelled` 判断后保留旧画面。
    ///
    /// - Parameter dataSource: 数据源。
    /// - Returns: 已完成的各分区结果（取消时可能不足四项）。
    private nonisolated static func fetchAll(
        from dataSource: any HomeDataSource
    ) async -> [SectionOutcome] {
        var outcomes: [SectionOutcome] = []
        do {
            try await withThrowingTaskGroup(of: SectionOutcome.self) { group in
                group.addTask {
                    await outcome(.resume) { try await dataSource.resume() }
                }
                group.addTask {
                    await outcome(.nextUp) { try await dataSource.nextUp() }
                }
                group.addTask {
                    await outcome(.latest) { try await dataSource.latest(limit: 20) }
                }
                group.addTask {
                    await outcome(.libraries) { try await dataSource.views() }
                }

                for try await finished in group {
                    outcomes.append(finished)
                }
            }
        } catch {
            // 只会是 CancellationError：保留已拿到的分区，调用方会丢弃这次结果。
        }
        return outcomes
    }

    /// 执行单个分区的拉取并归一化错误。
    ///
    /// - Parameters:
    ///   - section: 分区。
    ///   - operation: 实际请求。
    /// - Returns: 该分区的结果。
    private nonisolated static func outcome(
        _ section: HomeSection,
        _ operation: @Sendable () async throws -> [MediaItem]
    ) async -> SectionOutcome {
        do {
            return SectionOutcome(section: section, result: .success(try await operation()))
        } catch is CancellationError {
            return SectionOutcome(section: section, result: .failure(.cancelled))
        } catch let error as EmbyError {
            return SectionOutcome(section: section, result: .failure(error))
        } catch {
            return SectionOutcome(section: section, result: .failure(.unknown(String(describing: error))))
        }
    }

    /// 把某个分区的结果并进内容对象。
    ///
    /// - Parameters:
    ///   - items: 该分区的条目。
    ///   - content: 已收集的内容。
    ///   - section: 分区。
    /// - Returns: 合并后的内容。
    private nonisolated static func merging(
        _ items: [MediaItem],
        into content: HomeContent,
        for section: HomeSection
    ) -> HomeContent {
        switch section {
        case .resume:
            HomeContent(resume: items, nextUp: content.nextUp, latest: content.latest, libraries: content.libraries)
        case .nextUp:
            HomeContent(resume: content.resume, nextUp: items, latest: content.latest, libraries: content.libraries)
        case .latest:
            HomeContent(resume: content.resume, nextUp: content.nextUp, latest: items, libraries: content.libraries)
        case .libraries:
            HomeContent(resume: content.resume, nextUp: content.nextUp, latest: content.latest, libraries: items)
        }
    }

    /// 从失败集合里挑一个最有代表性的错误给整页错误态。
    ///
    /// 优先级：继续观看（最先展示的分区）→ 最新添加 → 接下来 → 媒体库。
    ///
    /// - Parameter errors: 失败集合（必然非空）。
    /// - Returns: 代表错误。
    private nonisolated static func primaryError(from errors: [HomeSection: EmbyError]) -> EmbyError {
        for section in [HomeSection.resume, .latest, .nextUp, .libraries] {
            if let error = errors[section] { return error }
        }
        return .unknown("首页数据加载失败")
    }
}
