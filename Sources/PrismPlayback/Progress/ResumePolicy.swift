import Foundation
import PrismCore

/// 续播（Resume）规则。
///
/// 决定「用户点继续观看时，从哪里开始播」以及「什么时候算看完」。
/// 纯值类型、无副作用，输入 ``PrismCore/MediaItem`` 的 `userData`，输出位置。
///
/// ## 三条规则的依据
///
/// 1. **太短不续播**（``minimumResumePosition``，默认 30 秒）。
///    只看了一两秒就退出，续播反而碍事——几乎所有客户端都这么做
///    （Infuse / Netflix 的阈值在 30 秒量级）。
/// 2. **90% 视为看完**（``completionThreshold``，默认 `0.90`）。
///    Emby 服务端把「是否看完」做成库级配置 `LibraryOptions.MaxResumePct`，
///    默认值 90：进度超过它就不再算「看到一半」，而是直接标记为已播放并移出「继续观看」。
///    - ✅ 字段存在：Emby OpenAPI 的 `Configuration.LibraryOptions` 有
///      `MinResumePct` / `MaxResumePct` / `MinResumeDurationSeconds` 三个 int32 字段
///      （<https://swagger.emby.media/openapi.json>，`info.version = 4.1.1.0`）。
///    - ◐ 默认值 90：官方 Reference 页只给字段类型、不给默认值，90 这个数字来自
///      多份 Emby 服务器 `system.xml` 配置转储（均为 `"MinResumePct":5,"MaxResumePct":90`）
///      以及 Jellyfin 源码常量 `MaxResumePct = 90`。
///    - ⚠️ 反证记录：Emby 官方 Playback-Check-ins 页面
///      （<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>）**通篇没有**
///      「90%」字样，不要把它当作该阈值的出处。
///    - ○ 服务端改过 `MaxResumePct` 时本客户端不会跟随（客户端无从得知该配置）——
///      验证方法：把库的 Max resume percentage 改成 80，观察 `UserData.Played` 与
///      本策略判定是否分叉。
/// 3. **续播回退几秒**（``rewindOnResume``，默认 3 秒）。
///    用户往往在「还记得剧情」的位置退出，从那一刻正着接会漏掉半句台词；
///    回退几秒是 Netflix / Infuse 等客户端的通行做法，体感更自然。
///
/// ## 与 Emby 服务端的分工
///
/// 服务端的 `UserData.Played` 由服务器自己按 90% 规则维护，``PrismCore/UserItemData/played``
/// 是它的快照。本类型**同时**检查 `played` 与「位置 / 时长 ≥ 90%」两个条件，
/// 因为列表接口返回的 `UserData` 可能滞后于服务端刚算出的结果。
///
/// ```swift
/// let policy = ResumePolicy()
/// if let start = policy.resumePosition(for: item) {
///     player.load(request, at: start)
/// }
/// ```
public struct ResumePolicy: Sendable, Equatable {
    /// 低于该位置不提供续播（默认 30 秒）。
    public var minimumResumePosition: Ticks

    /// 完播阈值（`0...1`，默认 `0.90`）。位置 / 时长达到它即视为看完。
    public var completionThreshold: Double

    /// 续播时回退的时长（默认 3 秒），避免错过退出前那一小段。
    public var rewindOnResume: Ticks

    /// 默认策略：30 秒起续、90% 完播、回退 3 秒。
    public static let standard = ResumePolicy()

    /// 创建策略。
    ///
    /// - Parameters:
    ///   - minimumResumePosition: 续播最小位置，默认 30 秒。
    ///   - completionThreshold: 完播阈值，默认 `0.90`。
    ///   - rewindOnResume: 续播回退时长，默认 3 秒。
    public init(
        minimumResumePosition: Ticks = Ticks(seconds: 30),
        completionThreshold: Double = 0.90,
        rewindOnResume: Ticks = Ticks(seconds: 3)
    ) {
        self.minimumResumePosition = minimumResumePosition
        self.completionThreshold = completionThreshold
        self.rewindOnResume = rewindOnResume
    }

    // MARK: - 续播

    /// 计算续播位置。
    ///
    /// 判定顺序：
    /// 1. 服务端标记已看完（`played == true`）→ `nil`（从头播）。
    /// 2. 上次位置低于 ``minimumResumePosition`` → `nil`（等同于没看过）。
    /// 3. 上次位置 / 总时长 ≥ ``completionThreshold`` → `nil`（当作看完，从头播）。
    /// 4. 其余情况 → `上次位置 - rewindOnResume`，且**钳到 0 以上**。
    ///
    /// - Parameter item: 媒体条目（读 `userData.playbackPosition` 与 `runTime`）。
    /// - Returns: 续播位置；`nil` 表示从头播放。
    public func resumePosition(for item: MediaItem) -> Ticks? {
        let position = item.userData.playbackPosition

        if item.userData.played { return nil }
        if position < minimumResumePosition { return nil }

        // 只有拿到有效时长时才做百分比判定；时长未知（直播、未入库条目）不拦。
        if let duration = item.runTime, duration.rawValue > 0,
           isCompleted(position: position, duration: duration) {
            return nil
        }

        let rewound = position - rewindOnResume
        return rewound.rawValue < 0 ? .zero : rewound
    }

    // MARK: - 完播

    /// 判断是否已看完。
    ///
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - duration: 总时长。
    /// - Returns: 位置 / 时长 ≥ ``completionThreshold`` 时为 `true`。
    ///   时长无效（`<= 0`）时恒为 `false`——没有时长就无法谈百分比。
    public func isCompleted(position: Ticks, duration: Ticks) -> Bool {
        guard duration.rawValue > 0 else { return false }
        return progressFraction(position: position, duration: duration) >= completionThreshold
    }

    /// 观看进度（`0...1`）。
    ///
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - duration: 总时长。
    /// - Returns: 进度比例；时长无效时返回 `0`，位置为负时按 `0` 处理，
    ///   位置超过时长时**不**截断（调用方按需 `min(1, …)`）。
    public func progressFraction(position: Ticks, duration: Ticks) -> Double {
        guard duration.rawValue > 0 else { return 0 }
        let clampedPosition = max(0, position.rawValue)
        return Double(clampedPosition) / Double(duration.rawValue)
    }
}
