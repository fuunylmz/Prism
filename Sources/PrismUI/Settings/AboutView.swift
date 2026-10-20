import AppKit
import PrismCore
import SwiftUI

// MARK: - 关于

/// 关于面板：版本、项目链接、开源许可、第三方组件与免责声明。
///
/// ## 信息从哪来
///
/// - 版本号优先读 `Bundle.main` 的 `CFBundleShortVersionString` / `CFBundleVersion`，
///   读不到时回退 ``PrismCore/Prism/version``（SPM 测试、预览里 `Bundle.main` 不是 App 包）；
/// - 图标用 `NSApplicationIcon`，取不到时退化为 SF Symbol，**不**强解包；
/// - 第三方组件是 `THIRD-PARTY-NOTICES.md` 的**人工摘要**（该文件不随 App 打包，
///   所以只能硬编码关键项）。增删依赖时这里必须同步更新。
struct AboutView: View {
    /// 项目主页。
    static let projectURL = URL(string: "https://github.com/fuunylmz/Prism")
    /// 许可证在线地址（App 包内不一定带 LICENSE 文件）。
    static let licenseURL = URL(string: "https://github.com/fuunylmz/Prism/blob/main/LICENSE")
    /// 问题反馈地址。
    static let issuesURL = URL(string: "https://github.com/fuunylmz/Prism/issues")

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            header
            linkSection
            updateSection
            componentsSection
            disclaimerSection
        }
    }

    // MARK: 头部

    /// 图标 + 名称 + 版本 + 一句话定位。
    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            icon
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: appName)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)

                Text(verbatim: versionLine)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)

                Text("第三方 Emby 客户端 · GPL-3.0")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// 应用图标：优先系统图标，取不到时用 SF Symbol。
    @ViewBuilder
    private var icon: some View {
        if let image = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .fill(Palette.accent.opacity(0.18))
                .overlay {
                    Image(systemName: "prism")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Palette.accent)
                }
        }
    }

    // MARK: 链接

    private var linkSection: some View {
        SettingsSection("链接") {
            linkRow("项目主页", url: Self.projectURL, detail: "源代码、发布说明与路线图")
            linkRow("问题反馈", url: Self.issuesURL, detail: "报告 Bug 或提出功能建议")
            licenseRow
        }
    }

    /// 一行外链：标题 + 说明 + 右侧箭头。
    ///
    /// - Parameters:
    ///   - title: 链接标题。
    ///   - url: 目标地址。
    ///   - detail: 补充说明。
    /// - Returns: 可点击的行。
    private func linkRow(_ title: LocalizedStringKey, url: URL?, detail: LocalizedStringKey) -> some View {
        SettingsRow(title, description: detail) {
            if let url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("在浏览器中打开")
                .accessibilityLabel(Text(title))
            } else {
                Text(verbatim: "—")
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// 许可证行：优先打开包内 LICENSE，否则打开 GitHub 上的全文。
    private var licenseRow: some View {
        SettingsRow(
            "许可证",
            description: "GPL-3.0。Prism 的完整源码随二进制一并提供，满足 GPL 的源码义务。",
            showsDivider: false
        ) {
            Button("查看 LICENSE") {
                openLicense()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("打开 GPL-3.0 全文")
        }
    }

    /// 打开许可证全文。
    ///
    /// 打包进 App 时用包内文件；SwiftPM / 预览环境没有该文件，退回 GitHub 上的副本。
    private func openLicense() {
        if let bundled = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
            NSWorkspace.shared.open(bundled)
            return
        }
        if let url = Self.licenseURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 更新

    private var updateSection: some View {
        SettingsSection("更新", footer: "自动更新依赖 Sparkle 与签名后的发布包，属于 v1.1 范围。") {
            SettingsRow("检查更新", description: "当前版本不包含更新检查；新版本需要手动下载。", showsDivider: false) {
                Button("检查更新") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                    .help("v1.1 接入 Sparkle 后可用")
            }
        }
    }

    // MARK: 第三方组件

    private var componentsSection: some View {
        SettingsSection(
            "开源组件",
            footer: "完整声明与许可证全文见仓库根目录的 THIRD-PARTY-NOTICES.md。"
        ) {
            ForEach(Self.thirdPartyComponents) { component in
                componentRow(component)
            }
        }
    }

    /// 一个第三方组件行。
    ///
    /// - Parameter component: 组件描述。
    /// - Returns: 名称 + 许可证 + 用途 + 源码链接。
    private func componentRow(_ component: ThirdPartyComponent) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(verbatim: component.name)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)

                    Text(verbatim: component.license)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Palette.textPrimary.opacity(0.06))
                        }
                }

                Text(component.purpose)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = component.url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("打开 \(component.name) 源码仓库")
                .accessibilityLabel("打开 \(component.name) 源码仓库")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
                .padding(.leading, Spacing.md)
                .accessibilityHidden(true)
        }
    }

    // MARK: 免责声明

    private var disclaimerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("免责声明")
                .font(Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.textSecondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            SettingsNote("Prism 是独立开发的第三方客户端，与 Emby LLC 无任何关联，未获其背书或赞助。Emby 是 Emby LLC 的商标；Dolby、Dolby Vision、Dolby Atmos 是 Dolby Laboratories 的商标。本项目中出现的名称仅用于说明兼容性。")

            SettingsNote("v1.0 已知限制：不支持画中画与 AirPlay 投送，不支持音乐库与 Live TV，Dolby Vision 以 HDR10 呈现。", kind: .warning)
        }
    }

    // MARK: 元数据

    /// 应用名称。
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Prism"
    }

    /// 「版本 0.1.0（1）」；取不到 build 号时只显示版本。
    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Prism.version
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return "版本 \(short)（\(build)）"
        }
        return "版本 \(short)"
    }

    /// 第三方组件摘要（与 `THIRD-PARTY-NOTICES.md` 同步）。
    private static let thirdPartyComponents: [ThirdPartyComponent] = [
        ThirdPartyComponent(
            name: "AetherEngine",
            license: "LGPL-3.0",
            purpose: "播放引擎：FFmpeg 解复用 + VideoToolbox 解码 + AVPlayer 处理 Dolby Vision / Atmos。",
            url: URL(string: "https://github.com/superuser404notfound/AetherEngine")
        ),
        ThirdPartyComponent(
            name: "FFmpegBuild",
            license: "LGPL-3.0",
            purpose: "FFmpeg 二进制发行（AetherEngine 的解复用与解码后端），未启用 GPL 组件。",
            url: URL(string: "https://github.com/superuser404notfound/FFmpegBuild")
        ),
        ThirdPartyComponent(
            name: "LibDovi",
            license: "LGPL-3.0",
            purpose: "Dolby Vision RPU 元数据处理。",
            url: URL(string: "https://github.com/superuser404notfound/LibDovi")
        ),
        ThirdPartyComponent(
            name: "GRDB.swift",
            license: "MIT",
            purpose: "SQLite 封装，用于媒体元数据与播放进度缓存。",
            url: URL(string: "https://github.com/groue/GRDB.swift")
        ),
        ThirdPartyComponent(
            name: "Nuke",
            license: "MIT",
            purpose: "图片加载与缓存（海报、背景图）。",
            url: URL(string: "https://github.com/kean/Nuke")
        )
    ]
}

// MARK: - 组件模型

/// 关于页展示的第三方组件。
struct ThirdPartyComponent: Identifiable {
    /// 组件名。
    let name: String
    /// 许可证标识（如 `LGPL-3.0` / `MIT`）。
    let license: String
    /// 用途说明（`LocalizedStringKey` 以便将来进 String Catalog）。
    let purpose: LocalizedStringKey
    /// 源码地址；`nil` 时不显示外链图标。
    let url: URL?

    /// `Identifiable` 要求。
    var id: String { name }
}

// MARK: - 预览

#Preview("关于 · 深色") {
    ScrollView {
        AboutView()
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 860)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("关于 · 浅色") {
    ScrollView {
        AboutView()
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 860)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
}
