import Foundation

/// Emby 的时间单位是 tick（.NET `TimeSpan` 的最小单位）。
///
/// 换算关系（已核实）：
/// - `1 tick = 100ns`
/// - `1 ms = 10,000 ticks`
/// - `1 s = 10,000,000 ticks`
///
/// 来源：Microsoft `DateTime.Ticks` / `TimeSpan.Ticks` 文档
/// （<https://learn.microsoft.com/dotnet/api/system.timespan.ticks>）；
/// Emby 的 `RunTimeTicks` / `PlaybackPositionTicks` / `StartPositionTicks` 均为该单位
/// （<https://dev.emby.media/doc/restapi/Item-Information.html>）。
///
/// 该类型是 `Codable` 的，并且**按 `Int64` 裸值编解码**，因此可以直接承接
/// Emby JSON 里的 `"RunTimeTicks": 7200000000` 这类字段。
///
/// ```swift
/// let runtime: Ticks = 8_100_000_000.secondsToTicks   // 13:30
/// runtime.formatted          // "13:30"
/// Ticks(seconds: -5).formatted // "0:00"（负值钳到 0）
/// ```
public struct Ticks: Sendable, Hashable, Comparable, Codable {
    /// 每秒对应的 tick 数。Emby（.NET）固定为 `10_000_000`。
    public static let ticksPerSecond: Int64 = 10_000_000

    /// 零时长。
    public static let zero = Ticks(0)

    /// 原始 tick 值。可能为负（例如相对偏移、未开始播放时的 `-1`）。
    public let rawValue: Int64

    /// 以原始 tick 值构造。
    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// 以秒构造，内部四舍五入到最近的 tick。
    public init(seconds: Double) {
        guard seconds.isFinite else {
            self.rawValue = 0
            return
        }
        self.rawValue = Int64((seconds * Double(Self.ticksPerSecond)).rounded())
    }

    /// 换算成秒。
    public var seconds: Double {
        Double(rawValue) / Double(Self.ticksPerSecond)
    }

    /// 换算成 `TimeInterval`（与 `seconds` 等价，便于直接喂给 AVFoundation / mpv）。
    public var timeInterval: TimeInterval {
        seconds
    }

    /// 是否为负值（例如“还剩 -3 秒”）。
    public var isNegative: Bool {
        rawValue < 0
    }

    /// 播放进度格式：不足 1 小时为 `"23:45"`，否则为 `"1:23:45"`；负值钳到 `"0:00"`。
    public var formatted: String {
        Self.format(seconds: seconds, showSign: false)
    }

    /// 剩余时间格式：负值带前导减号，例如 `"-1:23:45"`；正值不带符号。
    ///
    /// 与 ``formatted`` 的区别只在于保留负号：`formatted` 会把负值钳到 `"0:00"`，
    /// 而这里用 `"-0:45"` 表达“还剩 45 秒”。
    public var remainingFormatted: String {
        Self.format(seconds: seconds, showSign: true)
    }

    /// 格式化：`h:mm:ss`（有小时）或 `m:ss`（无小时）。
    ///
    /// - Parameters:
    ///   - seconds: 秒数，负数会被钳到 0。
    ///   - showSign: 为 `true` 且原值为负时加 `-` 前缀（用于“剩余时间”）。
    private static func format(seconds: Double, showSign: Bool) -> String {
        var finite = seconds.isFinite ? seconds : 0
        if !showSign { finite = max(0, finite) } // formatted 把负值钳到 0
        let total = Int64(abs(finite).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let body = hours > 0
            ? String(format: "%lld:%02lld:%02lld", hours, minutes, secs)
            : String(format: "%lld:%02lld", minutes, secs)
        return (showSign && finite < 0) ? "-" + body : body
    }

    /// 加法。
    public static func + (lhs: Ticks, rhs: Ticks) -> Ticks {
        Ticks(lhs.rawValue + rhs.rawValue)
    }

    /// 减法。
    public static func - (lhs: Ticks, rhs: Ticks) -> Ticks {
        Ticks(lhs.rawValue - rhs.rawValue)
    }

    /// 比较。
    public static func < (lhs: Ticks, rhs: Ticks) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - Codable

    /// 按 `Int64` 裸值解码。
    ///
    /// 绝大多数服务器返回整数；为兼容个别插件把 ticks 写成 `7200000000.0` 的情况，
    /// 整数解码失败时会退化为 `Double` 再取整。两者都失败才抛错。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.rawValue = value
        } else if let value = try? container.decode(Double.self) {
            self.rawValue = Int64(value.rounded())
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Ticks 期望 Int64 裸值"
            )
        }
    }

    /// 按 `Int64` 裸值编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Int64 {
    /// 把 `Int64` 视为 tick 值，转成 ``Ticks``。
    public var ticks: Ticks {
        Ticks(self)
    }
}

extension Double {
    /// 把秒数转成 ``Ticks``（四舍五入到最近的 tick）。
    public var secondsToTicks: Ticks {
        Ticks(seconds: self)
    }
}
