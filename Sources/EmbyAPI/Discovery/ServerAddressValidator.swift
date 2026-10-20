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
/// 补充规则：
/// - 显式写出的端口**原样保留**（`http://host:80` 不会被改写成 `http://host`）；
///   只有「显式 scheme + 隐式端口」才交给 scheme 默认值，URL 保持干净。
/// - 主机名统一转小写（DNS 大小写不敏感，避免同一台服务器产生两条记录）。
/// - 显式 scheme 时允许 `http://user:pass@host` 形式的 userinfo（会被丢弃，
///   本项目不做 Basic 认证）；没有 scheme 时出现 `@` 视为非法输入（更可能是邮箱）。
/// - 输入里的 query / fragment 一律丢弃，只保留路径前缀。
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
        // 主机名大小写不敏感，统一小写，避免同一台服务器因大小写产生两条记录。
        let host = hostPort.host.lowercased()
        guard isValidHost(host) else { return nil }

        let explicitPort = hostPort.port.flatMap { $0.isEmpty ? nil : $0 }
        let port: Int
        if let explicitPort {
            guard let value = parsePort(explicitPort) else { return nil }
            port = value
        } else if hadExplicitScheme {
            // 显式写了 scheme 却没写端口：尊重 scheme 的默认端口（80 / 443）。
            port = scheme == "https" ? httpsDefaultPort : httpDefaultPort
        } else {
            // 什么都没写：按 Emby 出厂默认端口猜。
            port = defaultPort
        }

        // 6) 组装 URL
        var components = URLComponents()
        components.scheme = scheme
        if host.contains(":") {
            // IPv6 字面量必须带方括号，否则 URLComponents 会返回 nil。
            components.percentEncodedHost = "[\(host)]"
        } else {
            // 用 `host`（而非 `percentEncodedHost`）让 Foundation 处理 IDN → punycode。
            components.host = host
        }
        // 只有「用户显式写了端口」或「端口是我们猜出来的」才写进 URL；
        // 显式 scheme + 隐式端口时交给 scheme 默认值，URL 更干净
        // （`https://emby.example.com` 不会变成 `https://emby.example.com:443`）。
        if explicitPort != nil || !hadExplicitScheme {
            components.port = port
        }
        // ⚠️ 必须用编码后的路径：`percentEncodedPath` 的 setter 对含空格 / 非 ASCII
        // 的字符串会直接触发 Foundation 断言崩溃（不是抛错），用户粘贴
        // `http://host/my emby` 就能让 App 崩掉。
        components.percentEncodedPath = percentEncode(path: path)

        guard let url = components.url, url.host() != nil else { return nil }
        return Parsed(url: url, scheme: scheme, host: host, port: port, path: path)
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

    /// 把路径归一化：去掉所有尾部 `/`，保证以 `/` 开头（或为空串）。
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

    /// 把任意路径编码成合法的 percent-encoded 路径，**保留已有的 `%XX` 转义**。
    ///
    /// 为什么需要它：`URLComponents.percentEncodedPath` 的 setter 会校验字符串，
    /// 含空格或非 ASCII 时直接 `fatalError`（实测崩溃，见 `DiscoveryAddressValidatorTests`）。
    /// 先用 `path` setter 编码会把用户已经写好的 `%20` 二次编码成 `%2520`，同样不对，
    /// 所以这里自己做：只编码需要编码的字符，合法的转义原样保留。
    ///
    /// - Parameter path: 原始路径（`""` 或 `/` 开头）。
    /// - Returns: 只含 URI 路径合法字符的字符串。
    private static func percentEncode(path: String) -> String {
        guard !path.isEmpty else { return "" }

        // 先把 `%` 排除在允许集合外，单独按「合法转义 / 裸百分号」判断。
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%")

        var result = ""
        var pending = ""
        func flushPending() {
            guard !pending.isEmpty else { return }
            result += pending.addingPercentEncoding(withAllowedCharacters: allowed) ?? pending
            pending = ""
        }

        let characters = Array(path)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let isEscape = character == "%"
                && index + 2 < characters.count
                && characters[index + 1].isHexDigit
                && characters[index + 2].isHexDigit
            if isEscape {
                flushPending()
                result.append(contentsOf: characters[index...(index + 2)])
                index += 3
                continue
            }
            pending.append(character)
            index += 1
        }
        flushPending()
        return result
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

    /// 校验显式写出的端口。
    ///
    /// - Parameter raw: 端口原文（调用方已排除空串）。
    /// - Returns: 端口；非纯数字或越界时为 `nil`。
    private static func parsePort(_ raw: String) -> Int? {
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
    /// 刻意**不接受 IDN（中文域名）**：媒体服务器的地址几乎不可能是中文域名，
    /// 出现非 ASCII 字符基本等于输错或粘贴了乱码，此时立刻报「地址无效」
    /// 比让用户等一次 DNS 超时体验更好。确有 IDN 需求时填 punycode（`xn--…`）即可。
    ///
    /// - Parameter host: 主机部分（IPv6 不带方括号）。
    /// - Returns: 是否可接受。
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }

        // IPv6 字面量：只允许十六进制、冒号、`%zone`。
        if host.contains(":") {
            let allowed = CharacterSet(charactersIn: "0123456789abcdef:.%")
            let colons = host.filter { $0 == ":" }.count
            return colons >= 2 && host.unicodeScalars.allSatisfy(allowed.contains)
        }

        // 主机名 / IPv4：只允许 ASCII 字母数字与 `-` `.` `_`。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return false }

        // 至少含一个字母或数字，排除 `.`、`...`、`-` 这类纯符号输入。
        return host.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
