import Foundation
import PrismCore

/// 手动输入的服务器地址的解析与归一化。
///
/// 这是「手动填地址登录」的关键路径，必须容忍真实用户能粘贴出来的各种形态。
/// 解析是**纯函数**（``normalize(_:)`` / ``parse(_:)``），不发任何网络请求；
/// 发请求校验由 ``ServerProbe`` / ``ServerDiscovery/validate(urlString:)`` 负责。
///
/// ## 默认策略（已文档化，测试覆盖）
///
/// | 输入 | 输出 | 规则 |
/// |---|---|---|
/// | `192.168.1.10` | `http://192.168.1.10:8096` | 无 scheme → `http`；无端口 → `8096` |
/// | `192.168.1.10:8096` | `http://192.168.1.10:8096` | 只补 scheme |
/// | `http://192.168.1.10:8096/` | `http://192.168.1.10:8096` | 去掉尾部 `/` |
/// | `https://emby.example.com` | `https://emby.example.com` | `https` 默认 `443`，**不**补 `8096` |
/// | `http://host/emby` | `http://host/emby` | 保留反代路径前缀 |
/// | `emby.example.com` | `http://emby.example.com:8096` | 见下方「为什么默认 http」 |
///
/// **为什么无 scheme 时默认 `http` 而不是 `https`**：
/// 1. Emby 服务端出厂配置就是 `http://<ip>:8096`，局域网内绝大多数部署没有证书；
/// 2. 自动发现（UDP 7359）返回的 `Address` 也是 `http://...:8096`；
/// 3. 猜错方向时 `https` 连不上是**硬失败**（TLS 握手直接失败），而 `http` 打到
///    `https` 端口通常也会失败——两种都失败，但 `http` 至少命中了最常见的部署形态。
///
/// 显式写了 `https://` 的输入一律尊重用户，不做任何降级或升级。
public enum ServerAddressValidator {
    /// 无 scheme 时使用的默认 scheme。
    public static let defaultScheme = "http"

    /// 无端口且 scheme 为 `http` 时使用的默认端口（Emby 出厂默认端口）。
    ///
    /// ✅ 来源：<https://dev.emby.media/doc/restapi/Locating-the-Server.html>
    /// （发现响应里的 `Address` 形如 `http://192.168.1.10:8096`）。
    public static let defaultPort = 8096

    /// `http` 未显式指定端口时使用的端口。
    public static let httpDefaultPort = 80

    /// `https` 未显式指定端口时使用的端口。
    public static let httpsDefaultPort = 443

    /// 解析成功后的结构化结果。
    public struct Parsed: Sendable, Hashable {
        /// 归一化后的基地址（无尾部 `/`，带 scheme 与端口）。
        public let url: URL
        /// 实际使用的 scheme（`http` 或 `https`）。
        public let scheme: String
        /// 主机部分（不含 scheme 与端口）；IPv6 字面量不带方括号。
        public let host: String
        /// 实际使用的端口。
        public let port: Int
        /// 保留的反代路径前缀；无前缀时为 `""`，否则形如 `"/emby"`。
        public let path: String

        /// 完整初始化。
        public init(url: URL, scheme: String, host: String, port: Int, path: String) {
            self.url = url
            self.scheme = scheme
            self.host = host
            self.port = port
            self.path = path
        }
    }

    /// 把用户输入归一化成可请求的基地址。
    ///
    /// - Parameter input: 用户输入（可含前后空格、换行、全角字符、引号）。
    /// - Returns: 归一化后的 URL。
    /// - Throws: ``PrismCore/EmbyError/invalidURL`` 当输入无法解析成合法的 http(s) 地址。
    public static func normalize(_ input: String) throws -> URL {
        guard let parsed = parse(input) else { throw EmbyError.invalidURL }
        return parsed.url
    }

    /// 解析用户输入，失败返回 `nil`（供发现模块做「尽力而为」的兜底解析）。
    ///
    /// 只接受 `http` / `https`；其余 scheme（`ftp://`、`file://` 等）一律视为非法。
    ///
    /// - Parameter input: 用户输入。
    /// - Returns: 解析结果；非法输入为 `nil`。
    public static func parse(_ input: String) -> Parsed? {
        var text = sanitize(input)
        guard !text.isEmpty else { return nil }

        // 1) scheme
        var scheme = defaultScheme
        var hadExplicitScheme = false
        if let separator = text.range(of: "://") {
            let rawScheme = String(text[text.startIndex..<separator.lowerBound]).lowercased()
            guard rawScheme == "http" || rawScheme == "https" else { return nil }
            scheme = rawScheme
            hadExplicitScheme = true
            text = String(text[separator.upperBound...])
        } else if text.hasPrefix("//") {
            // 协议相对 URL：`//host:8096`
            text = String(text.dropFirst(2))
        }
        guard !text.isEmpty else { return nil }

        // 2) userinfo（`http://user:pass@host:8096`）。
        //    没有显式 scheme 时出现 `@` 更可能是邮箱或粘贴错误，直接判非法。
        if let at = text.lastIndex(of: "@") {
            guard hadExplicitScheme else { return nil }
            text = String(text[text.index(after: at)...])
        }
        guard !text.isEmpty else { return nil }

        // 3) query / fragment：粘贴分享链接时常见，一律丢弃。
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }

        // 4) 反代路径前缀
        var path = ""
        if let slash = text.firstIndex(of: "/") {
            path = String(text[slash...])
            text = String(text[..<slash])
        }
        path = normalizedPath(path)

        // 5) host / port
        guard let hostPort = splitHostPort(text) else { return nil }
        guard isValidHost(hostPort.host) else { return nil }
        guard let port = resolvePort(hostPort.port, scheme: scheme) else { return nil }

        // 6) 组装 URL
        var components = URLComponents()
        components.scheme = scheme
        if hostPort.host.contains(":") {
            // IPv6 字面量必须带方括号，否则 URLComponents 会返回 nil。
            components.percentEncodedHost = "[\(hostPort.host)]"
        } else {
            // 用 `host`（而非 `percentEncodedHost`）让 Foundation 处理 IDN → punycode。
            components.host = hostPort.host
        }
        components.port = port
        components.percentEncodedPath = path

        guard let url = components.url, url.host() != nil else { return nil }
        return Parsed(url: url, scheme: scheme, host: hostPort.host, port: port, path: path)
    }

    // MARK: - 内部步骤

    /// 清洗输入：全角→半角、去掉零宽字符与换行、去掉粘贴常见的包裹引号。
    ///
    /// - Parameter input: 原始输入。
    /// - Returns: 清洗后的字符串（可能为空）。
    static func sanitize(_ input: String) -> String {
        // NFKC 兼容分解：全角数字/冒号/斜杠 → 半角，NBSP → 普通空格。
        var text = input.precomposedStringWithCompatibilityMapping
        for invisible in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] {
            text = text.replacingOccurrences(of: invisible, with: "")
        }
        // Windows 风格的路径分隔符。
        text = text.replacingOccurrences(of: "\\", with: "/")
        // 粘贴多行时混进来的换行/制表符。
        text = text.filter { !$0.isNewline && $0 != "\t" }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 包裹符号：`"http://x"`、`<http://x>`、`“http://x”`。
        let wrappers = CharacterSet(charactersIn: "\"'`<>「」『』《》")
        while let first = text.unicodeScalars.first, wrappers.contains(first) {
            text.removeFirst()
        }
        while let last = text.unicodeScalars.last, wrappers.contains(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把路径前缀归一化：去掉所有尾部 `/`，保证以 `/` 开头（或为空串）。
    ///
    /// - Parameter raw: 原始路径（可能为空）。
    /// - Returns: `""` 或 `"/emby"` 这样的规范形式。
    private static func normalizedPath(_ raw: String) -> String {
        var path = raw
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return "" }
        if !path.hasPrefix("/") { path = "/" + path }
        return path
    }

    /// 从 `host[:port]` / `[v6][:port]` 中拆出主机与端口原文。
    ///
    /// - Parameter text: 已去掉 scheme 与路径的 authority 部分。
    /// - Returns: 主机与端口原文；结构非法时为 `nil`。
    private static func splitHostPort(_ text: String) -> (host: String, port: String?)? {
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (host, nil) }
            guard rest.hasPrefix(":") else { return nil }
            let port = String(rest.dropFirst())
            return (host, port.isEmpty ? nil : port)
        }
        if let colon = text.lastIndex(of: ":") {
            let host = String(text[..<colon])
            let port = String(text[text.index(after: colon)...])
            return (host, port.isEmpty ? nil : port)
        }
        return (text, nil)
    }

    /// 决定实际端口：显式端口优先，否则按 scheme 取默认值。
    ///
    /// - Parameters:
    ///   - raw: 端口原文（`nil` 表示未写端口）。
    ///   - scheme: 实际使用的 scheme。
    /// - Returns: 端口；端口非法（非数字 / 越界）时为 `nil`。
    private static func resolvePort(_ raw: String?, scheme: String) -> Int? {
        guard let raw, !raw.isEmpty else {
            return scheme == "https" ? httpsDefaultPort : httpDefaultPort
        }
        guard raw.count <= 5,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(raw),
              (1...65535).contains(value)
        else { return nil }
        return value
    }

    /// 校验主机部分是否可能是一个合法主机名 / IP。
    ///
    /// 只做「明显不可能」的排除：空白、URL 保留字符、空标签。
    /// 不做 DNS 解析——那是 ``ServerProbe`` 的事。
    ///
    /// - Parameter host: 主机部分（IPv6 不带方括号）。
    /// - Returns: 是否可接受。
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }

        // IPv6 字面量：只允许十六进制、冒号、`%zone`。
        if host.contains(":") {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
            let colons = host.filter { $0 == ":" }.count
            return colons >= 2 && host.unicodeScalars.allSatisfy(allowed.contains)
        }

        // 主机名 / IPv4：排除 URL 保留字符与空白。
        let forbidden = CharacterSet(charactersIn: " /\\?#@&=+;,<>\"'`|^!*()[]{}%$~:")
        guard host.unicodeScalars.allSatisfy({ !forbidden.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return false }

        // 至少含一个字母或数字（允许非 ASCII 的 IDN 字符）。
        return host.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0.value > 0x7F }
    }
}
