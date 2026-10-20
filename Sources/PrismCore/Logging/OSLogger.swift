import Foundation
import os

/// 基于 `os.Logger` 的日志实现。
///
/// 特性：
/// - 走 Apple 统一日志系统，可在 Console.app / `log stream` 里按 subsystem 过滤；
/// - **写入前强制脱敏**（``Redactor``），令牌与密码不会落到日志里；
/// - 低于 `minimumLevel` 的日志直接丢弃，避免 Debug 期刷屏；
/// - 元数据按 `key=value` 拼接后以 `.public` 隐私级别输出（因为此时已脱敏）。
///
/// ```swift
/// let logger = OSLogger(subsystem: Prism.bundleIdentifier, category: "network")
/// logger.info("GET /Users/Me", metadata: ["token": session.accessToken]) // token 落盘为 ***
/// ```
public struct OSLogger: Logging {
    /// 底层 `os.Logger`。
    private let logger: Logger
    /// 低于该级别的日志被丢弃。
    private let minimumLevel: LogLevel

    /// 使用默认 subsystem（`Prism.bundleIdentifier`）创建。
    ///
    /// - Parameters:
    ///   - category: 分类名（`network`、`playback`、`ui`…）。
    ///   - minimumLevel: 最低输出级别，默认 `info`。
    public init(category: String, minimumLevel: LogLevel = .info) {
        self.init(subsystem: Prism.bundleIdentifier, category: category, minimumLevel: minimumLevel)
    }

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - subsystem: 子系统标识，通常用 bundle id。
    ///   - category: 分类名。
    ///   - minimumLevel: 最低输出级别。
    public init(subsystem: String, category: String, minimumLevel: LogLevel = .info) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.minimumLevel = minimumLevel
    }

    /// 写入一条日志（自动脱敏 + 级别过滤）。
    ///
    /// - Parameters:
    ///   - level: 日志级别。
    ///   - msg: 消息正文。
    ///   - metadata: 结构化键值对。
    public func log(_ level: LogLevel, _ msg: String, metadata: [String: String]) {
        guard level >= minimumLevel else { return }

        let safeMessage = Redactor.redact(msg)
        let safeMetadata = Redactor.redact(metadata: metadata)
        let line = Self.compose(safeMessage, metadata: safeMetadata)

        switch level {
        case .debug:
            logger.debug("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        }
    }

    /// 把消息与元数据拼成一行：`msg key1=value1 key2=value2`。
    ///
    /// - Parameters:
    ///   - message: 已脱敏的消息。
    ///   - metadata: 已脱敏的元数据。
    /// - Returns: 单行日志文本（key 排序保证稳定）。
    static func compose(_ message: String, metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return message }
        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return message + " " + pairs
    }
}

/// 丢弃一切日志的空实现。
///
/// 用于测试与 `#Preview`，避免污染日志系统。
public struct NoopLogger: Logging {
    /// 创建空实现。
    public init() {}

    /// 什么都不做。
    ///
    /// - Parameters:
    ///   - level: 忽略。
    ///   - msg: 忽略。
    ///   - metadata: 忽略。
    public func log(_ level: LogLevel, _ msg: String, metadata: [String: String]) {}
}
