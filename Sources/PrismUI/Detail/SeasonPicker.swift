import PrismCore
import SwiftUI

// MARK: - 季选择器

/// 横向滚动的季选择器（chips）。
///
/// 交互契约（`docs/research/ux-benchmark.md` §S08）：
/// - 选中态用强调色**填充**（对比度由 ``Palette/accent`` 上的自适应前景色保证）；
/// - 季多时横向滚动，切换季时把新选中的 chip **滚到可见**（居中），
///   同时不让列表整体跳动（`withAnimation` + `scrollTo`，而不是重建视图）；
/// - 支持键盘 `←` `→` 切换：焦点在季选择器上时按方向键即换季。
///
/// 键盘处理依赖视图获得焦点：macOS 上先用 Tab / 点击聚焦到季选择器，
/// 之后 `←` `→` 才生效——这符合 HIG「键盘焦点必须先可见」的要求。
///
/// ```swift
/// SeasonPicker(
///     seasons: content.seasons,
///     selectedSeasonId: model.selectedSeasonId,
///     isBusy: model.isLoadingEpisodes,
///     onSelect: { season in await model.selectSeason(season.id) }
/// )
/// ```
public struct SeasonPicker: View {
    private let seasons: [MediaItem]
    private let selectedSeasonId: String?
    private let isBusy: Bool
    private let onSelect: (MediaItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment
    @FocusState private var isFocused: Bool

    /// 创建季选择器。
    ///
    /// - Parameters:
    ///   - seasons: 季列表（调用方已排序）。
    ///   - selectedSeasonId: 当前季 id。
    ///   - isBusy: 是否正在拉取该季的集（chip 上显示小菊花）。
    ///   - onSelect: 选中回调。
    public init(
        seasons: [MediaItem],
        selectedSeasonId: String?,
        isBusy: Bool = false,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.seasons = seasons
        self.selectedSeasonId = selectedSeasonId
        self.isBusy = isBusy
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(seasons) { season in
                        chip(for: season)
                            .id(season.id)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
            .onChange(of: selectedSeasonId) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.standard)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear {
                guard let selectedSeasonId else { return }
                proxy.scrollTo(selectedSeasonId, anchor: .center)
            }
        }
        .focused($isFocused)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("季选择"))
    }

    // MARK: Chip

    private func chip(for season: MediaItem) -> some View {
        let isSelected = season.id == selectedSeasonId
        return Button {
            onSelect(season)
        } label: {
            HStack(spacing: Spacing.xs) {
                if isBusy, isSelected {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(verbatim: season.name)
                    .font(Typography.headline)
                    .lineLimit(1)

                if let unplayed = season.userData.unplayedItemCount, unplayed > 0, !isSelected {
                    Text(verbatim: String(unplayed))
                        .font(.system(.caption2, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.textPrimary.opacity(0.08)))
                }
            }
            .foregroundStyle(isSelected ? selectedForeground : Palette.textPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(isSelected ? Palette.accent : Palette.surfaceElevated)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.clear : Palette.separator,
                        lineWidth: 1
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(season.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 选中 chip 的前景色。
    ///
    /// 强调色可能被用户改成黄色等浅色，固定白字会失去对比度；用与
    /// ``PrismUI/PrismPrimaryButton`` 相同的相对亮度启发式在黑 / 白之间选。
    private var selectedForeground: Color {
        let resolved = Palette.accent.resolve(in: environment)
        let luminance = 0.2126 * Double(resolved.linearRed)
            + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
        return luminance > 0.35 ? .black : .white
    }

    // MARK: 键盘

    /// 按方向键移动选中季。
    ///
    /// - Parameter offset: `-1` 上一季，`1` 下一季。到头则不动（不循环，
    ///   避免「按一下跑到另一头」的意外）。
    private func moveSelection(by offset: Int) {
        guard !seasons.isEmpty else { return }
        let currentIndex = seasons.firstIndex { $0.id == selectedSeasonId } ?? 0
        let nextIndex = currentIndex + offset
        guard seasons.indices.contains(nextIndex) else { return }
        onSelect(seasons[nextIndex])
    }
}

// MARK: - 预览

private struct SeasonPickerPreviewBoard: View {
    @State private var selected = DetailPreviewData.seasons.first?.id

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(verbatim: "选中的季：\(selected ?? "无")")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            SeasonPicker(
                seasons: DetailPreviewData.seasons.sorted(by: DetailViewModel.seasonOrder),
                selectedSeasonId: selected
            ) { season in
                selected = season.id
            }

            SeasonPicker(
                seasons: Array(DetailPreviewData.seasons.sorted(by: DetailViewModel.seasonOrder).prefix(1)),
                selectedSeasonId: selected
            ) { season in
                selected = season.id
            }

            Text(verbatim: "只有一季时也保持同样的外观")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(Spacing.xl)
        .frame(width: 640, alignment: .leading)
        .background(Palette.surface)
    }
}

#Preview("SeasonPicker · 深色") {
    SeasonPickerPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("SeasonPicker · 浅色") {
    SeasonPickerPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
