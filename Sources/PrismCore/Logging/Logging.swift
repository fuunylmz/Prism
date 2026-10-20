import Foundation

/// 日志级别。
///
/// 顺序即严重程度（`debug < info < warning < error`），
/// 因此实现了 `Comparable`，方便按阈值过滤。
public enum LogLevel: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// 调试细节，仅开发期开启。
    case debug = 0
    /// 常规流程节点（发起请求、状态切换）。
    case info = 1
    /// 可恢复的异常（重试、降级）。
    case warning = 2
    /// 失败，需要用户或开发者介入。
    case error = 3

    /// 便于日志里显示的短名（`DEBUG`、`INFO`、`WARN`、`ERROR`）。
    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    /// 比较两个级别的严重程度。
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 日志协议。
///
/// 契约签名固定为三个参数：级别、消息、结构化元数据。
/// 实现方（``OSLogger`` / 测试替身）负责脱敏、格式化与落盘。
public protocol Logging: Sendable {
    /// 写入一条日志。
    ///
    /// - Parameters:
    ///   - level: 日志级别。
    ///   - msg: 消息正文。
    ///   - metadata: 结构化键值对（会自动脱敏）。
    func log(_ level: LogLevel, _ msg: String, metadata: [String: String])
}

extension Logging {
    /// 写一条不带元数据的日志。
    ///
    /// - Parameters:
    ///   - level: 日志级别。
    ///   - msg: 消息正文。
    public func log(_ level: LogLevel, _ msg: String) {
        log(level, msg, metadata: [:])
    }

    /// 写一条 `debug` 日志。
    public func debug(_ msg: String, metadata: [String: String] = [:]) {
        log(.debug, msg, metadata: metadata)
    }

    /// 写一条 `info` 日志。
    public func info(_ msg: String, metadata: [String: String] = [:]) {
        log(.info, msg, metadata: metadata)
    }

    /// 写一条 `warning` 日志。
    public func warning(_ msg: String, metadata: [String: String] = [:]) {
        log(.warning, msg, metadata: metadata)
    }

    /// 写一条 `error` 日志。
    public func error(_ msg: String, metadata: [String: String] = [:]) {
        log(.error, msg, metadata: metadata)
    }
}
