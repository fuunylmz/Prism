import AppKit
import SwiftUI
import Testing
@testable import PrismUI

/// 轨道菜单的布局：高度封顶 + 可滚动。
///
/// 守的是一条真实故障：多语种片源有 20+ 条字幕轨时，菜单容器（纯 `VStack`、
/// 无滚动容器、无高度上限）会被撑出屏幕，内容被裁掉，滚轮完全无效。
@Suite("轨道菜单布局")
@MainActor
struct TrackMenuSnapshotTests {
    private func makeTracks(count: Int) -> [PlayerTrack] {
        let languages = [
            "spa", "baq", "fin", "fil", "fra", "glg", "heb", "hrv",
            "hun", "ind", "ita", "kor", "may", "nob", "dut", "pol",
            "por", "rus", "swe", "tha", "tur", "vie", "chi", "eng", "jpn"
        ]
        return (0..<count).map { index in
            PlayerTrack(
                index: index + 3,
                kind: .subtitle,
                language: languages[index % languages.count],
                codec: "subrip",
                isForced: index % 5 == 0
            )
        }
    }

    /// 用 `ImageRenderer` 测量视图尺寸。
    ///
    /// 注意：它**不绘制** `ScrollView` 的内容（滚动区会渲染成空白），
    /// 所以这里只用它验证「外框尺寸是否被封顶」，滚动行为由
    /// ``ScrollableMenuList/clampedHeight(for:)`` 的纯函数测试保证。
    ///
    /// - Parameter view: 待测视图。
    /// - Returns: 渲染尺寸。
    private func measure(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("渲染失败")
            throw CancellationError()
        }
        return image.size
    }

    @Test("25 条字幕轨的菜单高度被限制在屏幕内")
    func manyTracksAreClamped() throws {
        let menu = SubtitleTrackMenu(
            tracks: makeTracks(count: 25),
            selectedIndex: 7,
            delay: 0.3,
            onSelect: { _ in },
            onAdjustDelay: { _ in },
            onResetDelay: {}
        )
        .prismTheme(PrismTheme(appearance: .dark))
        .background(Palette.surfaceElevated)

        let size = try measure(menu)

        // 屏幕高 752pt 时面板必须明显矮于屏幕，否则会被裁掉。
        #expect(size.height < 700)
        #expect(size.width > 0)
        // 也必须真的封了顶：25 行完整展开会超过 1000pt。
        #expect(size.height < 460)
        print("25 轨菜单尺寸：\(size.width) x \(size.height)")
    }

    // MARK: 高度夹取

    @Test("内容高度按上限夹取：多了滚动，少了贴合")
    func clampedHeight() {
        // 25 条字幕轨约 1100pt：必须封顶，否则面板被撑出屏幕、滚轮失效。
        #expect(ScrollableMenuList<EmptyView>.clampedHeight(for: 1100) == 320)
        // 单条轨道：贴合内容，不留空白。
        #expect(ScrollableMenuList<EmptyView>.clampedHeight(for: 46) == 46)
        // 测量失败（NaN / 无穷）时回落到上限，而不是 0 或崩溃。
        #expect(ScrollableMenuList<EmptyView>.clampedHeight(for: .nan) == 320)
        #expect(ScrollableMenuList<EmptyView>.clampedHeight(for: .infinity) == 320)
        // 0 高度给 1pt，避免 `frame(height: 0)` 造成的布局告警。
        #expect(ScrollableMenuList<EmptyView>.clampedHeight(for: 0) == 1)
    }

    // MARK: 真实窗口中的滚动能力

    @Test("25 条字幕轨在真实窗口里确实可滚动")
    func manyTracksAreActuallyScrollable() throws {
        let menu = SubtitleTrackMenu(
            tracks: makeTracks(count: 25),
            selectedIndex: 7,
            delay: 0,
            onSelect: { _ in },
            onAdjustDelay: { _ in },
            onResetDelay: {}
        )
        .prismTheme(PrismTheme(appearance: .dark))

        let host = NSHostingView(rootView: menu)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // 不调用 `window.close()`：在测试进程里销毁承载 SwiftUI 的无边框窗口会
        // 触发 AppKit 的段错误（已实测）。进程退出时窗口自然回收。

        let scrollView = try #require(
            Self.firstScrollView(in: host),
            "菜单里应当有一个 NSScrollView，否则滚轮无从生效"
        )

        let visible = scrollView.contentView.bounds.height
        let document = scrollView.documentView?.frame.height ?? 0

        // 关键断言：文档比可视区高 → 滚动条有效、滚轮能滚。
        #expect(document > visible, "文档高度 \(document) 应大于可视高度 \(visible)")
        // 同时可视区必须被封顶，否则面板会撑出屏幕。
        #expect(visible <= 320.5, "可视高度 \(visible) 应被限制在 320pt 内")
        print("滚动区：可视 \(visible)，文档 \(document)")
    }

    /// 在视图层级里找第一个 `NSScrollView`。
    ///
    /// - Parameter view: 根视图。
    /// - Returns: 找到的滚动视图；没有则为 `nil`。
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    @Test("单条音轨的菜单贴合内容，不留大片空白")
    func singleTrackHugsContent() throws {
        let menu = AudioTrackMenu(
            tracks: [PlayerTrack(index: 1, kind: .audio, language: "jpn", codec: "aac", channels: 2)],
            selectedIndex: 1,
            onSelect: { _ in }
        )
        .prismTheme(PrismTheme(appearance: .dark))
        .background(Palette.surfaceElevated)

        let size = try measure(menu)

        // 内容少时贴合内容，不该留一大片空白。
        #expect(size.height < 220)
        print("单轨菜单尺寸：\(size.width) x \(size.height)")
    }
}
