import Foundation
import PrismCore

// MARK: - 模块约定
//
// 本模块（`EmbyAPI`）只允许依赖 `PrismCore`，**不要**反向引用 `PrismUI` / `PrismData`。
//
// ⚠️ **不要在本模块里定义名为 `EmbyAPI` 的类型。**
//
// 骨架阶段这里曾有一个 `public enum EmbyAPI { isPlaceholder, apiPathPrefix }` 的占位类型。
// 它造成了一个非常隐蔽的问题：**类型名 `EmbyAPI` 遮蔽了模块名 `EmbyAPI`**，
// 于是下游写 `EmbyAPI.SortOrder` 时，编译器会把它解析成「那个 enum 的成员」，
// 报 `'SortOrder' is not a member type of enum 'EmbyAPI.EmbyAPI'`。
// 这个错误信息极具误导性，会让人以为是 `SortOrder` 不存在或重复定义。
//
// 已删除该占位类型。将来若需要模块级常量，请用**别的名字**
// （例如 `EmbyAPIConstants`），不要占用模块名。

/// 模块级常量（**故意不叫 `EmbyAPI`**，避免遮蔽模块名）。
public enum EmbyAPIConstants {
    /// Emby 反向代理常见的路径前缀；用户把服务器部署在子路径下时会用到。
    public static let apiPathPrefix = "/emby"
}
