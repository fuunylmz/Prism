import SwiftUI

enum PageMetrics {
    static let sectionSpacing: CGFloat = 40
    static let sectionHeaderSpacing: CGFloat = Spacing.md

    static func horizontalInset(for width: CGFloat) -> CGFloat {
        width >= 1200 ? Spacing.xxl : Spacing.xl
    }
}

struct PrismSectionHeader<Trailing: View>: View {
    private let title: String
    private let systemImage: String?
    private let count: Int?
    private let trailing: Trailing

    init(
        _ title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }

                Text(verbatim: title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                if let count {
                    Text(verbatim: "\(count)")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Spacing.xs + 2)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.surfaceElevated))
                        .accessibilityLabel(Text(verbatim: "\(count) 项"))
                }
            }

            Spacer(minLength: Spacing.sm)
            trailing
        }
        .frame(minHeight: 24)
    }
}
