import SwiftUI

// MARK: - 关键词高亮

/// 把查询词在标题中高亮显示的文本视图。
///
/// ## 为什么用 `AttributedString` 而不是拼接 `Text`
///
/// `Text("a") + Text("b")` 的写法有两个硬伤：
/// 1. **多语言断词错误**：按 `String.Index` 硬切会把组合字符（emoji、天城文、
///    带变音符号的拉丁字母）拆坏，渲染出方框或错位；
/// 2. **无法保留整段的排版语义**：拼出来的 `Text` 各自继承修饰符，行距、截断、
///    VoiceOver 朗读会被切碎。
///
/// 这里先在 `String` 上按 `Character` 边界定位匹配区间（`String.range(of:options:range:)`
/// 天然按字符簇工作），再把每一段包成 `AttributedString` 的 run 后**合并成一个**
/// `AttributedString`，最后交给单个 `Text`。因此：
/// - 中文、日文、韩文、emoji、组合字符都不会被切坏；
/// - VoiceOver 仍把整行读成一句话；
/// - 大小写不敏感（`caseInsensitive`），并额外忽略全角 / 半角差异（`widthInsensitive`），
///   这样「ＳＦ」也能匹配「SF」。
///
/// ```swift
/// HighlightedText("银翼杀手 2049", query: "杀手")
///     .font(Typography.body)
/// ```
public struct HighlightedText: View {
    private let text: String
    private let query: String
    private let baseColor: Color
    private let highlightColor: Color

    /// 创建高亮文本。
    ///
    /// - Parameters:
    ///   - text: 原始文本（服务端数据，按原样显示）。
    ///   - query: 查询词；为空时不产生高亮。
    ///   - baseColor: 未命中部分的颜色，默认 ``Palette/textPrimary``。
    ///   - highlightColor: 命中部分的颜色，默认 ``Palette/accent``。
    public init(
        _ text: String,
        query: String,
        baseColor: Color = Palette.textPrimary,
        highlightColor: Color = Palette.accent
    ) {
        self.text = text
        self.query = query
        self.baseColor = baseColor
        self.highlightColor = highlightColor
    }

    public var body: some View {
        Text(attributedText)
    }

    /// 当前构造出的富文本（供预览与排障使用）。
    public var attributedText: AttributedString {
        Self.makeAttributedString(
            text,
            query: query,
            baseColor: baseColor,
            highlightColor: highlightColor
        )
    }

    /// 构造高亮后的富文本。
    ///
    /// 实现要点：
    /// - 每段（未命中 / 命中）都显式设置 `foregroundColor`，不依赖调用方的
    ///   `.foregroundStyle`——否则 run 级属性与视图级修饰符谁生效会随 SwiftUI 版本变化；
    /// - 匹配区间严格按 `Character` 边界推进，绝不按 UTF-8 / UTF-16 偏移切；
    /// - 空查询、空文本、查询比文本长都安全返回，不会死循环。
    ///
    /// - Parameters:
    ///   - text: 原始文本。
    ///   - query: 查询词。
    ///   - baseColor: 未命中部分的颜色。
    ///   - highlightColor: 命中部分的颜色。
    /// - Returns: 可直接交给 `Text(_:)` 的富文本。
    public static func makeAttributedString(
        _ text: String,
        query: String,
        baseColor: Color = Palette.textPrimary,
        highlightColor: Color = Palette.accent
    ) -> AttributedString {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttributedString() }
        guard !keyword.isEmpty else {
            return plainRun(text, color: baseColor)
        }

        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        var result = AttributedString()
        var cursor = text.startIndex
        var didMatch = false

        while cursor < text.endIndex,
              let match = text.range(of: keyword, options: options, range: cursor..<text.endIndex) {
            didMatch = true
            if cursor < match.lowerBound {
                result += plainRun(String(text[cursor..<match.lowerBound]), color: baseColor)
            }
            result += plainRun(String(text[match]), color: highlightColor)
            cursor = match.upperBound
        }

        guard didMatch else { return plainRun(text, color: baseColor) }
        if cursor < text.endIndex {
            result += plainRun(String(text[cursor..<text.endIndex]), color: baseColor)
        }
        return result
    }

    /// 生成一段纯色 run。
    ///
    /// - Parameters:
    ///   - value: 文本片段。
    ///   - color: 该段的颜色。
    /// - Returns: 只带前景色的富文本片段。
    private static func plainRun(_ value: String, color: Color) -> AttributedString {
        var run = AttributedString(value)
        run.foregroundColor = color
        return run
    }
}

// MARK: - 预览

private struct HighlightedTextPreviewBoard: View {
    private let samples: [(String, String)] = [
        ("银翼杀手 2049", "杀手"),
        ("Severance", "sever"),
        ("人生切割术", "切割"),
        ("ＳＦ 全角大写", "sf"),
        ("Amélie · 天使爱美丽", "amélie"),
        ("没有命中的标题", "星球"),
        ("👨‍👩‍👧‍👦 家庭合影", "合影")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(samples, id: \.0) { text, query in
                VStack(alignment: .leading, spacing: 2) {
                    HighlightedText(text, query: query)
                        .font(Typography.body)
                    Text(verbatim: "query: \(query)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420, alignment: .leading)
        .background(Palette.surface)
    }
}

#Preview("关键词高亮 · 深色") {
    HighlightedTextPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("关键词高亮 · 浅色") {
    HighlightedTextPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
