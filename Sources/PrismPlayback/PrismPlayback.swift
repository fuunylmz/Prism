import Foundation
import PrismCore

// MARK: - 模块说明
//
// ⚠️ **不要在本模块里定义名为 `PrismPlayback` 的类型。**
//
// 骨架阶段这里曾有一个 `public enum PrismPlayback { isPlaceholder }` 的占位类型。
// 它造成了与 `EmbyAPI` 完全相同的隐蔽问题：**类型名遮蔽了模块名**，
// 于是下游写 `PrismPlayback.ProgressReporter` 时，编译器会把它解析成
// 「那个 enum 的成员」，报
// `'ProgressReporter' is not a member type of enum 'PrismPlayback.PrismPlayback'`。
//
// 已删除。将来若需要模块级常量，请用别的名字（例如 `PrismPlaybackInfo`），不要占用模块名。
//
// 模块结构：
// - `Engine/`      —— `PlaybackEngine` 协议、事件、状态机、AetherEngine 适配器
// - `Negotiation/` —— 直连 / 直封 / 转码的选路
// - `Progress/`    —— 播放进度上报与续播
