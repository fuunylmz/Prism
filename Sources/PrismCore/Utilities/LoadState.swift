import Foundation

/// 通用加载状态机，供 ViewModel 的 `state` 属性使用。
///
/// 契约里 `LibraryViewModel.state` 是 `LoadState<[MediaItem]>`，取值
/// `idle / loading / loaded / empty / failed(EmbyError)`。这里把 `empty`
/// 单独建模而不是用 `loaded([])`，是为了让 UI 能直接 `switch` 到空态，
/// 不必再写 `if items.isEmpty` 判断。
public enum LoadState<Value: Sendable & Equatable>: Sendable, Equatable {
    /// 尚未开始加载。
    case idle
    /// 加载中（首屏或刷新）。
    case loading
    /// 加载成功且有数据。
    case loaded(Value)
    /// 加载成功但没有数据。
    case empty
    /// 加载失败。
    case failed(EmbyError)

    /// 关联的已加载值；非 `loaded` 状态为 `nil`。
    public var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    /// 是否处于加载中。
    public var isLoading: Bool {
        self == .loading
    }

    /// 是否已有结果（成功、空或失败）。
    public var isSettled: Bool {
        switch self {
        case .idle, .loading: false
        case .loaded, .empty, .failed: true
        }
    }

    /// 失败时的错误；其他状态为 `nil`。
    public var error: EmbyError? {
        if case let .failed(error) = self { return error }
        return nil
    }

    /// 是否为空态。
    public var isEmpty: Bool {
        self == .empty
    }

}

extension LoadState: Hashable where Value: Hashable {}

extension Array where Element: Sendable & Equatable {
    /// 把数组包成 ``LoadState``：非空为 `.loaded`，空为 `.empty`。
    public var loadState: LoadState<[Element]> {
        isEmpty ? .empty : .loaded(self)
    }
}
