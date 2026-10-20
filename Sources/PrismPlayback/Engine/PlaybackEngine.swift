import Foundation
import PrismCore
import SwiftUI

/// Prism 的播放引擎抽象（**冻结契约**，见 `docs/ARCHITECTURE.md` §3）。
///
/// 上层（播放器 UI、进度上报、系统能力）只依赖这个协议，不依赖任何具体引擎。
/// v1.0 的唯一实现是 ``AetherEngineAdapter``，它内部持有 AetherEngine；
/// **AetherEngine 的 import 只允许出现在那一个文件里**，协议本身以及它的所有返回值
/// 都不得出现 `OpaquePointer` / `mpv_handle` / AetherEngine 的任何类型。
///
/// ## 事件规则（契约的一部分）
///
/// - ``PlaybackEvent/positionChanged(_:duration:)`` 至少 4Hz；UI 侧自行节流。
/// - 所有 ``events`` 在 `@MainActor` 消费，引擎内部不得直接触碰 UI。
/// - ``stop()`` 后引擎必须回到 ``PlaybackState/idle`` 并释放解码器。
/// - ``events`` 是**单消费者**流：一个 `AsyncStream` 只能被一个 `for await` 消费。
///   需要多处消费时，由上层做一次转发，不要重复读取。
///
/// ## 并发约定
///
/// 协议本身 `Sendable`，但**方法都是 `async`**：调用方从任意上下文 await 即可，
/// 实现内部会自行切到主 actor（AetherEngine 是 `@MainActor` 的）。
/// ``renderView`` 是 `@MainActor` 属性，只能在主 actor 上读。
public protocol PlaybackEngine: AnyObject, Sendable {
    /// 渲染面：直接塞进 SwiftUI 的 `body` 即可（内部已把引擎的图层绑好）。
    ///
    /// - Important: 引擎的 `load()` **不要求**这个视图已经上屏——适配器在初始化时就绑定了一个
    ///   离屏视图（实测见 `docs/research/playback-spike-results.md` §1），所以可以先 `load` 再上屏。
    @MainActor var renderView: AnyView { get }

    /// 加载并起播。
    ///
    /// - Parameter request: 协商好的播放请求（URL、鉴权头、起播位置、外挂字幕…）。
    /// - Throws: ``PlaybackFailure``。失败时 ``events`` 里也会先发一次
    ///   ``PlaybackEvent/failed(_:)``，两条路径任选其一消费即可（不要重复弹窗）。
    ///
    /// - Important: **返回时 `duration` 可能还是 0**（实测 61ms 后才可用，见 §3.5 坑 1）。
    ///   不要在这里同步读时长，等 ``PlaybackEvent/durationChanged(_:)``。
    func load(_ request: PlaybackRequest) async throws

    /// 开始 / 恢复播放。
    func play() async

    /// 暂停。
    func pause() async

    /// 跳转到指定位置（绝对位置，不是相对偏移）。
    func seek(to position: Ticks) async

    /// 设置播放速率（1.0 = 正常）。
    ///
    /// - Note: AetherEngine 会把速率钳到 ``PlaybackEngine`` 实现所支持的上限
    ///   （视频 **2.0**、纯音频 3.0，实测见 §3.1），超出部分静默钳制而不是报错。
    func setRate(_ rate: Double) async

    /// 设置音量（0...1，越界会被钳制）。
    func setVolume(_ volume: Double) async

    /// 切换音轨。
    ///
    /// - Parameter index: 轨道 id（``TrackInfo/id``，即容器内的 stream index），**不是数组下标**。
    ///
    /// - Warning: AetherEngine 切音轨会触发一次管线重建（实测 143ms），期间位置会瞬时归零
    ///   （约 86ms，见 §3.5 坑 2）。适配器会在重建期间发
    ///   ``PlaybackState/loading`` 并冻结 ``PlaybackEvent/positionChanged(_:duration:)``，
    ///   重建结束后补发一次正确位置；UI 不应在此期间自己读引擎时钟。
    func selectAudioTrack(_ index: Int) async

    /// 选择字幕轨。
    ///
    /// - Parameter index: 轨道 id；`nil` 表示关闭字幕。
    func selectSubtitleTrack(_ index: Int?) async

    /// 设置字幕延迟（秒）。正值 = 字幕**延后**出现，负值 = 提前。
    ///
    /// - Important: AetherEngine 的 `setSoftwareSubtitleDelay` **只作用于 software PiP 合成**，
    ///   不影响宿主自绘字幕的 cue 时间轴（§3.5 坑 4）。适配器自己维护偏移量，
    ///   并在发出 ``PlaybackEvent/subtitleCues(_:)`` 时对时间轴施加该偏移，因此这里设置后
    ///   会立刻重发一次当前 cue。
    func setSubtitleDelay(_ seconds: Double) async

    /// 设置字幕样式偏好。
    ///
    /// - Note: AetherEngine **没有**字幕样式 API（§3.3 缺口）。字幕由 Prism 自绘，
    ///   样式由 UI 层消费 ``SubtitleStyle`` 自行渲染；适配器只做保存。
    func setSubtitleStyle(_ style: SubtitleStyle) async

    /// 挂载 / 卸载外挂字幕文件。
    ///
    /// - Parameter url: 字幕文件地址；`nil` 表示关闭当前外挂字幕。
    ///
    /// - Important: 引擎**没有注销外挂轨的 API**：传 `nil` 只是把当前字幕关掉，
    ///   已注册的轨道仍留在 ``PlaybackEvent/tracksChanged(audio:subtitle:)`` 的列表里，
    ///   直到下一次 `load()`。
    func setSubtitleFile(_ url: URL?) async

    /// 停止播放并释放解码器；之后状态回到 ``PlaybackState/idle``。
    func stop() async

    /// 播放事件流。
    ///
    /// 单消费者；适配器销毁时流结束。
    var events: AsyncStream<PlaybackEvent> { get }
}
