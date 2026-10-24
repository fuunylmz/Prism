import AppKit
import PrismCore
import PrismPlayback
import SwiftUI

struct SubtitleOverlay: View {
    let cues: [SubtitleCue]
    let position: Ticks

    @Bindable private var settings: AppSettings

    init(cues: [SubtitleCue], position: Ticks, settings: AppSettings = .shared) {
        self.cues = cues
        self.position = position
        self._settings = Bindable(wrappedValue: settings)
    }

    var body: some View {
        GeometryReader { proxy in
            let activeCues = SubtitleCue.active(at: position, in: cues)

            ZStack(alignment: .bottom) {
                ForEach(activeCues) { cue in
                    cueView(cue, in: proxy.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: activeText))
        .accessibilityHidden(activeText.isEmpty)
    }

    @ViewBuilder
    private func cueView(_ cue: SubtitleCue, in size: CGSize) -> some View {
        if case let .image(bitmap) = cue.body {
            bitmapView(bitmap, in: size)
        } else {
            let placement = cue.placement
            let anchor = Self.anchor(for: placement?.alignment)

            Group {
                if let point = placement?.position {
                    cueLabel(cue, canvasHeight: size.height, anchor: anchor)
                        .frame(maxWidth: size.width * 0.9, alignment: anchor)
                        .position(
                            x: min(max(point.x, 0.05), 0.95) * size.width,
                            y: min(max(point.y, 0.04), 0.96) * size.height
                        )
                } else {
                    cueLabel(cue, canvasHeight: size.height, anchor: anchor)
                        .frame(maxWidth: size.width * 0.9, alignment: anchor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
                        .padding(.horizontal, size.width * 0.05)
                        .padding(.vertical, verticalInset(for: anchor, height: size.height))
                }
            }
        }
    }

    private func bitmapView(_ bitmap: SubtitleBitmap, in size: CGSize) -> some View {
        let canvasWidth = bitmap.canvasWidth > 0 ? bitmap.canvasWidth : size.width
        let canvasHeight = bitmap.canvasHeight > 0 ? bitmap.canvasHeight : size.height
        let scale = min(size.width / canvasWidth, size.height / canvasHeight)
        let videoWidth = canvasWidth * scale
        let videoHeight = canvasHeight * scale
        let videoOriginX = (size.width - videoWidth) / 2
        let videoOriginY = (size.height - videoHeight) / 2
        let frame = CGRect(
            x: videoOriginX + bitmap.x * scale,
            y: videoOriginY + bitmap.y * scale,
            width: bitmap.width * scale,
            height: bitmap.height * scale
        )

        return SubtitleBitmapView(bitmap: bitmap)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func cueLabel(_ cue: SubtitleCue, canvasHeight: CGFloat, anchor: Alignment) -> some View {
        subtitleText(cue, canvasHeight: canvasHeight)
            .frame(maxWidth: .infinity, alignment: anchor)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, settings.subtitleBackground ? 3 : 0)
            .background {
                if settings.subtitleBackground {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.68))
                }
            }
    }

    @ViewBuilder
    private func subtitleText(_ cue: SubtitleCue, canvasHeight: CGFloat) -> some View {
        let baseSize = max(18, min(54, canvasHeight * 44 / 1080 * settings.subtitleScale))

        renderedText(cue.body, baseSize: baseSize)
            .font(.system(size: baseSize, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.95), radius: max(1, baseSize * 0.045), x: 0, y: 1)
            .shadow(color: .black.opacity(0.9), radius: 0, x: 1, y: 0)
            .shadow(color: .black.opacity(0.9), radius: 0, x: -1, y: 0)
            .shadow(color: .black.opacity(0.9), radius: 0, x: 0, y: -1)
    }

    private func renderedText(_ body: SubtitleCue.Body, baseSize: CGFloat) -> Text {
        switch body {
        case let .text(value):
            Text(verbatim: value)
        case let .richText(runs):
            runs.reduce(Text("")) { result, run in
                var part = Text(verbatim: run.text)
                if run.isBold { part = part.bold() }
                if run.isItalic { part = part.italic() }
                if run.isUnderlined { part = part.underline() }
                if run.isStruckThrough { part = part.strikethrough() }
                if let color = run.color {
                    part = part.foregroundColor(Color(subtitleColor: color))
                }
                if let fontName = run.fontName {
                    part = part.font(.custom(fontName, size: baseSize))
                } else if let fontSize = run.fontSize, fontSize > 0 {
                    let scaledSize = CGFloat(fontSize) * baseSize / 44
                    part = part.font(.system(size: max(10, min(96, scaledSize))))
                }
                return result + part
            }
        case .image:
            Text("")
        }
    }

    private var activeText: String {
        SubtitleCue.active(at: position, in: cues)
            .compactMap(\.text)
            .joined(separator: "\n")
    }

    private func verticalInset(for alignment: Alignment, height: CGFloat) -> CGFloat {
        if alignment == .bottom || alignment == .bottomLeading || alignment == .bottomTrailing {
            return max(24, height * 48 / 1080)
        }
        if alignment == .top || alignment == .topLeading || alignment == .topTrailing {
            return max(24, height * 32 / 1080)
        }
        return 0
    }

    private static func anchor(for value: Int?) -> Alignment {
        switch value {
        case 1: .bottomLeading
        case 2: .bottom
        case 3: .bottomTrailing
        case 4: .leading
        case 5, 6: .center
        case 7: .topLeading
        case 8: .top
        case 9: .topTrailing
        default: .bottom
        }
    }
}

private struct SubtitleBitmapView: View {
    let bitmap: SubtitleBitmap
    @State private var image: NSImage?

    init(bitmap: SubtitleBitmap) {
        self.bitmap = bitmap
        self._image = State(initialValue: NSImage(data: bitmap.pngData))
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        }
    }
}

private extension Color {
    init(subtitleColor: SubtitleColor) {
        self.init(
            .sRGB,
            red: Double(subtitleColor.r) / 255,
            green: Double(subtitleColor.g) / 255,
            blue: Double(subtitleColor.b) / 255,
            opacity: Double(subtitleColor.a) / 255
        )
    }
}

#Preview("播放器字幕") {
    ZStack {
        LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
        SubtitleOverlay(
            cues: [
                SubtitleCue(
                    id: 1,
                    start: Ticks(seconds: 0),
                    end: Ticks(seconds: 5),
                    body: .text("字幕会跟随播放时间显示")
                )
            ],
            position: Ticks(seconds: 2)
        )
    }
    .frame(width: 960, height: 540)
    .environment(\.colorScheme, .dark)
}
