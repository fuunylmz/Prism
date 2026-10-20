import EmbyAPI

// MARK: - SortOrder 别名

/// ``EmbyAPI/SortOrder`` 的无歧义短名。
///
/// **为什么需要它**：macOS 26 SDK 的 Foundation 新增了 `Foundation.SortOrder`
/// （`SortDescriptor` 用的 `.forward` / `.reverse`）。任何同时 `import Foundation`
/// 与 `import EmbyAPI` 的文件里，裸写 `SortOrder` 都会报：
///
/// ```
/// error: 'SortOrder' is ambiguous for type lookup in this context
/// ```
///
/// 本文件**刻意不 import Foundation**——在这里 `SortOrder` 只有 EmbyAPI 这一个候选，
/// 解析无歧义，于是别名在模块内全局可用。
///
/// 模块限定 `EmbyAPI.SortOrder` 现在也可用（前提是 `EmbyAPI` 模块内**不要**再定义
/// 名为 `EmbyAPI` 的类型，否则模块名会被遮蔽）；但在需要频繁书写的文件里，
/// 短名 ``EmbySortOrder`` 更省事，也顺带把「这是 Emby 的排序方向，不是 Foundation 的」
/// 写进了类型名里。
public typealias EmbySortOrder = SortOrder
