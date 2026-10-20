import Foundation
import PrismCore

/// 可注入的等待器，让重试退避在测试里不真的睡。
///
/// 重试逻辑**不允许**直接调用 `Task.sleep`：那样测试只能靠「等两秒」来验证，
/// 既慢又抖。这里把「等待」抽成协议，生产用 ``TaskSleeper``，测试注入立即返回的实现。
public protocol RetrySleeping: Sendable {
    /// 等待指定秒数。
    ///
    /// - Parameter seconds: 秒数，可能为 0。
    func sleep(seconds: TimeInterval) async
}

/// 基于 `Task.sleep` 的实现（生产用）。
public struct TaskSleeper: RetrySleeping {
    /// 创建默认等待器。
    public init() {}

    /// 等待指定秒数；任务被取消时提前返回（取消由调用方检查）。
    ///
    /// - Parameter seconds: 秒数。
    public func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// 重试策略：**只**重试「幂等且可恢复」的失败。
///
/// 允许重试：
/// - ``PrismCore/EmbyError/timeout``（请求超时）
/// - ``PrismCore/EmbyError/serverUnreachable(_:)``（连不上主机）
/// - `5xx`（``PrismCore/EmbyError/server(status:message:)`` 且状态码 500...599）
///
/// **绝不**重试：
/// - `401` / `403` / `404`：重试多少次结果都一样，401 还应触发登出；
/// - 解码失败（``PrismCore/EmbyError/decoding(_:)``）：服务器已经回了 200，
///   再发一次只会再拿到同样解不开的字节；
/// - 非幂等方法：见下。
///
/// ## 为什么按「方法 + 路径」判断幂等
///
/// ``EmbyEndpoint`` 是冻结契约，没有 `isIdempotent` 声明，因此本层按
/// **HTTP 方法**推导：只有 `GET` 可重试。`POST` 一律不重试 —— 这正好覆盖
/// 两类最危险的请求：
/// - `POST /Sessions/Playing` / `.../Progress` / `.../Stopped`：重复上报会让
///   服务器把播放进度写成两条甚至来回跳；
/// - `POST /Users/AuthenticateByName`：重复登录会生成多个会话/设备记录。
///
/// 另外显式维护 ``nonIdempotentPathPrefixes`` 作为「方法判断之外」的保险：
/// 将来若允许重试某个非 GET 方法，也不会误伤这两个前缀。
///
/// ## 退避与抖动
///
/// 最多 2 次重试，基准间隔 0.5s、1.5s，每次乘一个 `1 ± jitterRatio` 的系数。
/// 抖动由**注入的时钟**推导（而不是 `Double.random`），因此用
/// ``PrismCore/FixedClock`` 时结果可复现，测试可以断言区间。
public struct RetryPolicy: Sendable {
    /// 默认策略：最多 2 次重试，0.5s / 1.5s，±20% 抖动。
    public static let `default` = RetryPolicy()

    /// 明确不可重试的路径前缀（与 ``isIdempotent(_:)`` 的方法判断互为补充）。
    ///
    /// - `/Sessions/Playing*`：播放进度上报（非幂等）。
    /// - `/Users/AuthenticateByName`：登录（会创建会话）。
    public static let nonIdempotentPathPrefixes = [
        "/Sessions/Playing",
        "/Users/AuthenticateByName"
    ]

    /// 最大重试次数（不含首次请求）。默认 2，即总请求数最多 3。
    public let maxRetries: Int

    /// 各次重试的基准间隔（秒）；重试次数超出数组长度时沿用最后一个。
    public let baseDelays: [TimeInterval]

    /// 抖动幅度，`0.2` 表示实际间隔在基准值的 80%...120% 之间。
    public let jitterRatio: Double

    /// 用于推导抖动的时钟（同时保证测试可复现）。
    public let clock: any ClockProviding

    /// 创建策略。
    ///
    /// - Parameters:
    ///   - maxRetries: 最大重试次数，默认 2。
    ///   - baseDelays: 各次重试的基准间隔，默认 `[0.5, 1.5]`。
    ///   - jitterRatio: 抖动幅度，默认 0.2。
    ///   - clock: 抖动种子来源，默认 `SystemClock()`。
    public init(
        maxRetries: Int = 2,
        baseDelays: [TimeInterval] = [0.5, 1.5],
        jitterRatio: Double = 0.2,
        clock: any ClockProviding = SystemClock()
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelays = baseDelays.isEmpty ? [0.5, 1.5] : baseDelays
        self.jitterRatio = min(max(0, jitterRatio), 1)
        self.clock = clock
    }

    /// 是否应该重试。
    ///
    /// - Parameters:
    ///   - error: 归一化后的错误。
    ///   - endpoint: 出错的端点（用于幂等判断）。
    /// - Returns: `true` 表示可以再发一次。
    public func shouldRetry(_ error: EmbyError, for endpoint: EmbyEndpoint) -> Bool {
        guard Self.isIdempotent(endpoint) else { return false }
        switch error {
        case .timeout, .serverUnreachable:
            return true
        case let .server(status, _):
            return (500...599).contains(status)
        case .invalidURL, .unauthorized, .forbidden, .notFound, .decoding, .cancelled, .unknown:
            return false
        }
    }

    /// 第 `index` 次重试前应等待的秒数（含抖动）。
    ///
    /// - Parameter index: 从 0 开始的重试序号（第 1 次重试为 0）。
    /// - Returns: 等待秒数，落在 `base × (1 ± jitterRatio)` 内。
    public func delay(forRetry index: Int) -> TimeInterval {
        let base = baseDelays[min(max(0, index), baseDelays.count - 1)]
        let unit = Self.unitFraction(seed: clock.now, index: index)
        let factor = 1 + jitterRatio * (unit * 2 - 1)
        return max(0, base * factor)
    }

    /// 端点是否幂等（可安全重发）。
    ///
    /// - Parameter endpoint: 端点。
    /// - Returns: 仅 `GET` 且不在 ``nonIdempotentPathPrefixes`` 里时为 `true`。
    public static func isIdempotent(_ endpoint: EmbyEndpoint) -> Bool {
        guard endpoint.method == .get else { return false }
        return !nonIdempotentPathPrefixes.contains { endpoint.path.hasPrefix($0) }
    }

    /// 由时间戳与序号推导一个 `0..<1` 的确定性小数（SplitMix64）。
    ///
    /// 用确定性哈希而非 `Double.random`，是为了让 ``PrismCore/FixedClock``
    /// 下的退避序列可复现 —— 否则测试只能断言一个很宽的区间。
    ///
    /// - Parameters:
    ///   - seed: 时间种子。
    ///   - index: 重试序号。
    /// - Returns: `0..<1` 的小数。
    private static func unitFraction(seed: Date, index: Int) -> Double {
        let millis = UInt64(bitPattern: Int64((seed.timeIntervalSince1970 * 1000).rounded()))
        var state = millis &+ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        state = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        state = (state ^ (state >> 27)) &* 0x94D0_49BB_1331_11EB
        state ^= (state >> 31)
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}
