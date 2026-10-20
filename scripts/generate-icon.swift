#!/usr/bin/env swift
//
//  generate-icon.swift
//  Prism — macOS app icon generator
//
//  Draws every macOS app-icon size with CoreGraphics and writes them into
//  App/Assets.xcassets/AppIcon.appiconset/, plus the matching Contents.json.
//  No design-tool dependency, no external assets: the icon is pure geometry.
//
//  Usage (from the repo root):
//      swift scripts/generate-icon.swift
//
//  Design: "prism refraction". A white beam enters a glass prism from the
//  left, bends inside it, and leaves the right face as a violet→cyan→gold
//  spectrum fan. See docs/ICON.md for the rationale and the macOS 26/27
//  icon-shape rules this file deliberately follows (full-bleed square, no
//  self-drawn corners, fully opaque edges).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design space
//
// All coordinates below are expressed in a 1024×1024 "design space" with the
// origin at the top-left and y growing downwards (the context is flipped to
// match). Every output size is that space scaled by size/1024, so the artwork
// is identical at all sizes except for the deliberate per-size simplification
// in `style(for:)`.

let D: CGFloat = 1024

// MARK: - Palette

enum Palette {
    static let bgTop: UInt32    = 0x1E1B36
    static let bgMid: UInt32    = 0x171A2E
    static let bgBottom: UInt32 = 0x0A0E1B

    static let violet: UInt32 = 0x7B5CFF
    static let cyan: UInt32   = 0x3EC6FF

    /// Spectrum, ordered violet → gold. Matches the brand violet/cyan pair.
    static let spectrum: [UInt32] = [0x8B5CF6, 0x5B7CFF, 0x3EC6FF, 0x4FE3C1, 0xFFD166]
}

// MARK: - Geometry

enum Geo {
    /// Prism (isosceles triangle, apex up). Content stays inside a ~11% margin.
    static let apex = CGPoint(x: 500, y: 276)
    static let bl   = CGPoint(x: 288, y: 694)
    static let br   = CGPoint(x: 712, y: 694)

    /// Incoming beam: horizontal, enters the left face.
    static let beamY: CGFloat = 470
    /// Where the refracted beam leaves the right face.
    static let exitY: CGFloat = 566

    /// Spectrum fan: apex on the right face, spreading to the right and fading out.
    static let fanFarX: CGFloat = 912
    static let fanTopY: CGFloat = 386
    static let fanBotY: CGFloat = 728

    static func xOnLeftFace(_ y: CGFloat) -> CGFloat {
        apex.x + (bl.x - apex.x) * (y - apex.y) / (bl.y - apex.y)
    }

    static func xOnRightFace(_ y: CGFloat) -> CGFloat {
        apex.x + (br.x - apex.x) * (y - apex.y) / (br.y - apex.y)
    }

    static var entry: CGPoint { CGPoint(x: xOnLeftFace(beamY), y: beamY) }
    static var exit: CGPoint { CGPoint(x: xOnRightFace(exitY), y: exitY) }

    static var prismPath: CGPath {
        let p = CGMutablePath()
        p.move(to: apex)
        p.addLine(to: bl)
        p.addLine(to: br)
        p.closeSubpath()
        return p
    }
}

// MARK: - Per-size style

/// Detail level for one raster size. Small icons drop the decoration that
/// would otherwise turn into grey mush: no glow, no specular streak, fewer
/// spectrum bands, and strokes clamped to a minimum number of *device* pixels
/// so they survive the downscale.
struct Style {
    let px: Int
    /// Design units per device pixel at this size.
    var unit: CGFloat { D / CGFloat(px) }

    let bands: Int
    let separators: Bool
    let glow: Bool
    let specular: Bool
    let beamStartX: CGFloat

    let strokeW: CGFloat
    let beamW: CGFloat
    let innerBeamW: CGFloat
    let sepW: CGFloat
    let glowW: CGFloat

    /// Glass body fill, apex → base. Small icons need a much brighter body,
    /// otherwise the prism reads as a thin wireframe at 16 px.
    let fillTop: CGFloat
    let fillBottom: CGFloat
    /// Fade window for the far end of the spectrum fan, in design units.
    let fadeFrom: CGFloat
    let fadeTo: CGFloat
}

func style(for px: Int) -> Style {
    // `w(design, min:)` = at least `min` device pixels, otherwise the design width.
    func w(_ design: CGFloat, _ min: CGFloat) -> CGFloat { max(design, min * D / CGFloat(px)) }

    switch px {
    case ..<24:
        // 16×16: prism outline + one beam + a single spectrum wedge. Nothing else.
        return Style(px: px, bands: 1, separators: false, glow: false, specular: false,
                     beamStartX: 168,
                     strokeW: w(9, 1.6), beamW: w(9, 1.6), innerBeamW: w(7, 1.2),
                     sepW: 0, glowW: 0,
                     fillTop: 0.34, fillBottom: 0.16,
                     fadeFrom: 800, fadeTo: 960)
    case ..<48:
        // 32×32: prism + beam + 3 spectrum bands, no bloom.
        return Style(px: px, bands: 3, separators: true, glow: false, specular: false,
                     beamStartX: 152,
                     strokeW: w(9, 2.0), beamW: w(9, 1.9), innerBeamW: w(7, 1.4),
                     sepW: w(4, 1.0), glowW: 0,
                     fillTop: 0.28, fillBottom: 0.11,
                     fadeFrom: 780, fadeTo: 950)
    case ..<96:
        // 64×64: full 5-band spectrum, still no bloom/specular.
        return Style(px: px, bands: 5, separators: true, glow: false, specular: false,
                     beamStartX: 140,
                     strokeW: w(9, 2.4), beamW: w(9, 2.2), innerBeamW: w(7, 1.7),
                     sepW: w(4, 1.1), glowW: 0,
                     fillTop: 0.23, fillBottom: 0.09,
                     fadeFrom: 760, fadeTo: 945)
    case ..<200:
        // 128×128: add the beam bloom; keep it single-pass.
        return Style(px: px, bands: 5, separators: true, glow: true, specular: false,
                     beamStartX: 132,
                     strokeW: w(9, 2.8), beamW: w(9, 2.6), innerBeamW: w(7, 2.1),
                     sepW: w(5, 1.3), glowW: w(34, 5.5),
                     fillTop: 0.21, fillBottom: 0.07,
                     fadeFrom: 740, fadeTo: 940)
    default:
        // 256 / 512 / 1024: everything, including the specular streak.
        return Style(px: px, bands: 5, separators: true, glow: true, specular: true,
                     beamStartX: 122,
                     strokeW: w(10, 3.4), beamW: w(10, 3.2), innerBeamW: w(8, 2.6),
                     sepW: w(7, 1.5), glowW: w(38, 6.5),
                     fillTop: 0.20, fillBottom: 0.05,
                     fadeFrom: 700, fadeTo: 930)
    }
}

// MARK: - Color helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func c(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: sRGB, components: [r, g, b, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map(\.1) as CFArray,
               locations: stops.map(\.0))!
}

// MARK: - Drawing

/// Horizontal alpha ramp, used to let the spectrum fan dissolve into the
/// background instead of ending on a hard vertical edge.
func horizontalFadeMask(from x0: CGFloat, to x1: CGFloat) -> CGImage {
    let w = 512, h = 4
    let gray = CGColorSpaceCreateDeviceGray()
    let m = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: 0, space: gray,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let g = CGGradient(colorsSpace: gray,
                       colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                       locations: [0, 1])!
    m.drawLinearGradient(g,
                         start: CGPoint(x: CGFloat(w) * x0 / D, y: 0),
                         end: CGPoint(x: CGFloat(w) * x1 / D, y: 0),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    return m.makeImage()!
}

func drawBackground(_ ctx: CGContext, _ s: Style) {
    ctx.saveGState()

    let bg = gradient([
        (0.00, c(Palette.bgTop)),
        (0.52, c(Palette.bgMid)),
        (1.00, c(Palette.bgBottom)),
    ])
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: D),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Violet bloom behind the prism, cyan counter-bloom top-right: keeps the
    // flat background from reading as a dead rectangle behind the glass.
    let violet = gradient([(0, c(Palette.violet, 0.34)), (1, c(Palette.violet, 0))])
    ctx.drawRadialGradient(violet,
                           startCenter: CGPoint(x: 470, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 540), endRadius: 640,
                           options: [])

    let cyan = gradient([(0, c(Palette.cyan, 0.14)), (1, c(Palette.cyan, 0))])
    ctx.drawRadialGradient(cyan,
                           startCenter: CGPoint(x: 930, y: 210), startRadius: 0,
                           endCenter: CGPoint(x: 930, y: 210), endRadius: 560,
                           options: [])

    ctx.restoreGState()
}

func drawPrismBody(_ ctx: CGContext, _ s: Style) {
    let path = Geo.prismPath

    // Glass body: a faint white wash, brightest at the apex.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let glass = gradient([
        (0.00, c(0xFFFFFF, s.fillTop)),
        (0.55, c(0xFFFFFF, (s.fillTop + s.fillBottom) / 2)),
        (1.00, c(0xFFFFFF, s.fillBottom)),
    ])
    ctx.drawLinearGradient(glass,
                           start: CGPoint(x: 0, y: Geo.apex.y),
                           end: CGPoint(x: 0, y: Geo.bl.y),
                           options: [])
    ctx.restoreGState()
}

func drawBeam(_ ctx: CGContext, _ s: Style) {
    let entry = Geo.entry
    let start = CGPoint(x: s.beamStartX, y: Geo.beamY)

    ctx.saveGState()
    ctx.setLineCap(.round)

    if s.glow {
        // Wide, soft halo around the incoming light.
        ctx.setStrokeColor(c(0xFFFFFF, 0.07))
        ctx.setLineWidth(s.glowW)
        ctx.move(to: start)
        ctx.addLine(to: entry)
        ctx.strokePath()

        ctx.setStrokeColor(c(Palette.violet, 0.16))
        ctx.setLineWidth(s.glowW * 0.55)
        ctx.move(to: start)
        ctx.addLine(to: entry)
        ctx.strokePath()
    }

    // Core beam.
    ctx.setStrokeColor(c(0xFFFFFF, 0.97))
    ctx.setLineWidth(s.beamW)
    ctx.move(to: start)
    ctx.addLine(to: entry)
    ctx.strokePath()

    ctx.restoreGState()
}

/// The refracted segment inside the prism: same light, bent downwards.
func drawInnerBeam(_ ctx: CGContext, _ s: Style) {
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(c(0xFFFFFF, 0.82))
    ctx.setLineWidth(s.innerBeamW)
    ctx.move(to: Geo.entry)
    ctx.addLine(to: Geo.exit)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawPrismEdge(_ ctx: CGContext, _ s: Style) {
    ctx.saveGState()
    ctx.setLineJoin(.round)
    if s.specular {
        // Soft violet halo so the glass separates from the dark background.
        ctx.setShadow(offset: .zero, blur: 30, color: c(0xA98BFF, 0.50))
    }
    ctx.addPath(Geo.prismPath)
    ctx.setStrokeColor(c(0xFFFFFF, 0.93))
    ctx.setLineWidth(s.strokeW)
    ctx.strokePath()
    ctx.restoreGState()

    // Specular streak just inside the left face — only where it can be seen.
    if s.specular {
        let inset: CGFloat = 16
        let y0 = Geo.apex.y + 96
        let y1 = Geo.bl.y - 88
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(c(0xFFFFFF, 0.30))
        ctx.setLineWidth(s.strokeW * 0.55)
        ctx.move(to: CGPoint(x: Geo.xOnLeftFace(y0) + inset, y: y0))
        ctx.addLine(to: CGPoint(x: Geo.xOnLeftFace(y1) + inset, y: y1))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func drawSpectrum(_ ctx: CGContext, _ s: Style) {
    let e = Geo.exit
    let far = Geo.fanFarX
    let top = Geo.fanTopY
    let bottom = Geo.fanBotY

    let fan = CGMutablePath()
    fan.move(to: e)
    fan.addLine(to: CGPoint(x: far, y: top))
    fan.addLine(to: CGPoint(x: far, y: bottom))
    fan.closeSubpath()

    let mask = horizontalFadeMask(from: s.fadeFrom, to: s.fadeTo)
    let canvas = CGRect(x: 0, y: 0, width: D, height: D)

    // Fan body. `plusLighter` makes the spectrum add light to the dark
    // background instead of sitting on top of it like paint.
    ctx.saveGState()
    ctx.clip(to: canvas, mask: mask)
    ctx.addPath(fan)
    ctx.clip()
    ctx.setBlendMode(.plusLighter)
    let n = Palette.spectrum.count
    let stops: [(CGFloat, CGColor)] = Palette.spectrum.enumerated().map {
        (CGFloat($0.offset) / CGFloat(n - 1), c($0.element))
    }
    ctx.drawLinearGradient(gradient(stops),
                           start: CGPoint(x: 0, y: top),
                           end: CGPoint(x: 0, y: bottom),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Dark gaps between the bands read as the spectrum being split apart.
    if s.separators, s.bands > 1 {
        ctx.saveGState()
        ctx.clip(to: canvas, mask: mask)
        ctx.addPath(fan)
        ctx.clip()
        ctx.setBlendMode(.normal)
        ctx.setLineCap(.butt)
        for i in 1..<s.bands {
            let f = CGFloat(i) / CGFloat(s.bands)
            let y = top + (bottom - top) * f
            ctx.move(to: e)
            ctx.addLine(to: CGPoint(x: far, y: y))
        }
        ctx.setStrokeColor(c(0x05070D, 0.72))
        ctx.setLineWidth(s.sepW)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Bloom where the light leaves the glass.
    if s.glow {
        ctx.saveGState()
        let bloom = gradient([(0, c(0xFFFFFF, 0.55)), (0.45, c(0x9B7BFF, 0.18)), (1, c(Palette.violet, 0))])
        ctx.drawRadialGradient(bloom,
                               startCenter: e, startRadius: 0,
                               endCenter: e, endRadius: 150,
                               options: [])
        ctx.restoreGState()
    }
}

// MARK: - Render

func render(size px: Int) -> (image: CGImage, edgeAlpha: (Int, Int, Int, Int)) {
    let n = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip into design space: origin top-left, y down.
    ctx.translateBy(x: 0, y: n)
    ctx.scaleBy(x: n / D, y: -n / D)

    let s = style(for: px)

    drawBackground(ctx, s)
    drawPrismBody(ctx, s)
    drawBeam(ctx, s)
    drawInnerBeam(ctx, s)
    drawPrismEdge(ctx, s)
    drawSpectrum(ctx, s)

    let image = ctx.makeImage()!

    // macOS 26+ only treats an icon as "native" when every edge pixel is
    // fully opaque; anything softer gets wrapped in the system squircle.
    let stride = ctx.bytesPerRow
    let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func alpha(_ x: Int, _ y: Int) -> Int { Int(buf[y * stride + x * 4 + 3]) }
    let corners = (alpha(0, 0), alpha(px - 1, 0), alpha(0, px - 1), alpha(px - 1, px - 1))

    return (image, corners)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1, nil) else {
        throw NSError(domain: "icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    let props: [CFString: Any] = [
        kCGImagePropertyDPIWidth: 72,
        kCGImagePropertyDPIHeight: 72,
        kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0],
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot finalize \(url.path)"])
    }
}

// MARK: - Output plan

struct Entry {
    let size: String
    let scale: String
    let px: Int
    var filename: String {
        let base = "icon_\(size)"
        return scale == "1x" ? "\(base).png" : "\(base)@\(scale).png"
    }
}

let plan: [Entry] = [
    Entry(size: "16x16", scale: "1x", px: 16),
    Entry(size: "16x16", scale: "2x", px: 32),
    Entry(size: "32x32", scale: "1x", px: 32),
    Entry(size: "32x32", scale: "2x", px: 64),
    Entry(size: "128x128", scale: "1x", px: 128),
    Entry(size: "128x128", scale: "2x", px: 256),
    Entry(size: "256x256", scale: "1x", px: 256),
    Entry(size: "256x256", scale: "2x", px: 512),
    Entry(size: "512x512", scale: "1x", px: 512),
    Entry(size: "512x512", scale: "2x", px: 1024),
]

let contentsJSON = """
{
  "images" : [
\(plan.map { entry in
    """
        {
          "filename" : "\(entry.filename)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)",
          "size" : "\(entry.size)"
        }
    """
}.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: - Main

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let outDir = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

guard fm.fileExists(atPath: root.appendingPathComponent("App/Assets.xcassets").path) else {
    FileHandle.standardError.write(Data("run this from the repo root (Prism/)\n".utf8))
    exit(1)
}

try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

// Only the distinct pixel sizes are rendered; duplicate entries reuse the file.
var rendered: [Int: CGImage] = [:]
var failures = 0

print("Prism icon → \(outDir.path)")
for entry in plan {
    let url = outDir.appendingPathComponent(entry.filename)
    let (image, corners) = rendered[entry.px].map { ($0, (255, 255, 255, 255)) }
        ?? render(size: entry.px)
    rendered[entry.px] = image
    try writePNG(image, to: url)

    let opaque = corners.0 == 255 && corners.1 == 255 && corners.2 == 255 && corners.3 == 255
    if !opaque { failures += 1 }
    print(String(format: "  %-22@ %4d×%-4d  corners α=%d,%d,%d,%d %@",
                 entry.filename as NSString, entry.px, entry.px,
                 corners.0, corners.1, corners.2, corners.3,
                 opaque ? "✓" : "✗ NOT OPAQUE"))
}

try contentsJSON.write(to: outDir.appendingPathComponent("Contents.json"),
                       atomically: true, encoding: .utf8)

print("wrote Contents.json (\(plan.count) entries)")
if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) size(s) have non-opaque edge pixels\n".utf8))
    exit(2)
}
print("done.")
