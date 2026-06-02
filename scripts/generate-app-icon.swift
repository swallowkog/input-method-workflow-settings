#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let outputPath = arguments.first ?? "assets/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)
let variantArgument = arguments.dropFirst().first
let previewDirectory = arguments.dropFirst(2).first.map { URL(fileURLWithPath: $0, isDirectory: true) }
let fileManager = FileManager.default

try fileManager.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

if let previewDirectory {
    try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
}

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("input-method-agent-icon-\(UUID().uuidString)")
let iconsetURL = tempRoot.appendingPathComponent("AppIcon.iconset")

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer {
    try? fileManager.removeItem(at: tempRoot)
}

struct IconSpec {
    let filename: String
    let pixels: Int
}

let specs = [
    IconSpec(filename: "icon_16x16.png", pixels: 16),
    IconSpec(filename: "icon_16x16@2x.png", pixels: 32),
    IconSpec(filename: "icon_32x32.png", pixels: 32),
    IconSpec(filename: "icon_32x32@2x.png", pixels: 64),
    IconSpec(filename: "icon_128x128.png", pixels: 128),
    IconSpec(filename: "icon_128x128@2x.png", pixels: 256),
    IconSpec(filename: "icon_256x256.png", pixels: 256),
    IconSpec(filename: "icon_256x256@2x.png", pixels: 512),
    IconSpec(filename: "icon_512x512.png", pixels: 512),
    IconSpec(filename: "icon_512x512@2x.png", pixels: 1024)
]

enum AppIconVariant: String {
    case bopomofo = "B1"
    case zhuyin = "B2"

    static func resolved(from rawValue: String?) -> AppIconVariant {
        guard let rawValue else { return .bopomofo }
        switch rawValue.uppercased() {
        case "B2", "A", "ZH", "ZHUYIN", "注":
            return .zhuyin
        default:
            return .bopomofo
        }
    }

    var glyph: String {
        switch self {
        case .bopomofo:
            return "ㄅ"
        case .zhuyin:
            return "注"
        }
    }

    var glyphFontSize: CGFloat {
        switch self {
        case .bopomofo:
            return 76
        case .zhuyin:
            return 62
        }
    }

    var latinFontSize: CGFloat {
        switch self {
        case .bopomofo:
            return 76
        case .zhuyin:
            return 62
        }
    }

    var targetChipWidth: CGFloat {
        switch self {
        case .bopomofo:
            return 120
        case .zhuyin:
            return 130
        }
    }

    var previewName: String {
        switch self {
        case .bopomofo:
            return "AppIcon-B1-A-switch-Bopomofo"
        case .zhuyin:
            return "AppIcon-B2-A-switch-Zhu"
        }
    }
}

let variant = AppIconVariant.resolved(from: variantArgument)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func font(named names: [String], size: CGFloat, weight: NSFont.Weight) -> NSFont {
    for name in names {
        if let font = NSFont(name: name, size: size) {
            return font
        }
    }
    return NSFont.systemFont(ofSize: size, weight: weight)
}

func drawCenteredText(
    _ text: String,
    in rect: CGRect,
    fontSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    fontNames: [String] = []
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let selectedFont = font(named: fontNames, size: fontSize, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: selectedFont,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()
    let drawRect = CGRect(
        x: rect.minX,
        y: rect.midY - textSize.height / 2,
        width: rect.width,
        height: textSize.height
    )
    attributed.draw(in: drawRect)
}

func drawRoundedFill(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    roundedRect(rect, radius: radius).fill()
}

func drawSwitchArrow(in rect: CGRect, scale: CGFloat) {
    let strokeColor = color(0.03, 0.36, 0.44)
    strokeColor.setStroke()

    let topY = rect.midY + 13 * scale
    let bottomY = rect.midY - 13 * scale
    let leftX = rect.minX + 12 * scale
    let rightX = rect.maxX - 12 * scale
    let head = 15 * scale
    let lineWidth = 8 * scale

    let top = NSBezierPath()
    top.move(to: CGPoint(x: leftX, y: topY))
    top.line(to: CGPoint(x: rightX, y: topY))
    top.lineWidth = lineWidth
    top.lineCapStyle = .round
    top.stroke()

    let topHead = NSBezierPath()
    topHead.move(to: CGPoint(x: rightX - head, y: topY + head * 0.72))
    topHead.line(to: CGPoint(x: rightX, y: topY))
    topHead.line(to: CGPoint(x: rightX - head, y: topY - head * 0.72))
    topHead.lineWidth = lineWidth
    topHead.lineCapStyle = .round
    topHead.lineJoinStyle = .round
    topHead.stroke()

    let bottom = NSBezierPath()
    bottom.move(to: CGPoint(x: rightX, y: bottomY))
    bottom.line(to: CGPoint(x: leftX, y: bottomY))
    bottom.lineWidth = lineWidth
    bottom.lineCapStyle = .round
    bottom.stroke()

    let bottomHead = NSBezierPath()
    bottomHead.move(to: CGPoint(x: leftX + head, y: bottomY + head * 0.72))
    bottomHead.line(to: CGPoint(x: leftX, y: bottomY))
    bottomHead.line(to: CGPoint(x: leftX + head, y: bottomY - head * 0.72))
    bottomHead.lineWidth = lineWidth
    bottomHead.lineCapStyle = .round
    bottomHead.lineJoinStyle = .round
    bottomHead.stroke()
}

func drawKeyboard(scale: CGFloat) {
    let keyboardRect = CGRect(x: 174 * scale, y: 236 * scale, width: 676 * scale, height: 400 * scale)
    let keyboard = roundedRect(keyboardRect, radius: 86 * scale)

    let keyboardShadow = NSShadow()
    keyboardShadow.shadowColor = color(0.00, 0.03, 0.06, 0.22)
    keyboardShadow.shadowBlurRadius = 20 * scale
    keyboardShadow.shadowOffset = NSSize(width: 0, height: -9 * scale)
    keyboardShadow.set()
    NSGradient(colors: [
        color(0.98, 1.0, 1.0),
        color(0.86, 0.95, 0.98)
    ])?.draw(in: keyboard, angle: 90)
    NSShadow().set()

    color(1, 1, 1, 0.76).setStroke()
    keyboard.lineWidth = 6 * scale
    keyboard.stroke()

    let mainKey = color(0.06, 0.17, 0.23, 0.88)
    let numpadKey = color(0.00, 0.68, 0.80, 0.98)
    let numpadPanel = roundedRect(CGRect(x: 618 * scale, y: 296 * scale, width: 194 * scale, height: 294 * scale), radius: 48 * scale)
    color(0.76, 0.95, 0.97, 0.38).setFill()
    numpadPanel.fill()

    for rect in [
        CGRect(x: 244, y: 506, width: 82, height: 48),
        CGRect(x: 356, y: 506, width: 82, height: 48),
        CGRect(x: 468, y: 506, width: 82, height: 48),
        CGRect(x: 244, y: 424, width: 82, height: 48),
        CGRect(x: 356, y: 424, width: 82, height: 48),
        CGRect(x: 468, y: 424, width: 82, height: 48),
        CGRect(x: 302, y: 338, width: 288, height: 56)
    ] {
        drawRoundedFill(rect.applying(CGAffineTransform(scaleX: scale, y: scale)), radius: 18 * scale, fill: mainKey)
    }

    for rect in [
        CGRect(x: 652, y: 506, width: 56, height: 48),
        CGRect(x: 736, y: 506, width: 56, height: 48),
        CGRect(x: 652, y: 424, width: 56, height: 48),
        CGRect(x: 736, y: 424, width: 56, height: 48),
        CGRect(x: 652, y: 342, width: 56, height: 48),
        CGRect(x: 736, y: 342, width: 56, height: 48),
        CGRect(x: 652, y: 278, width: 140, height: 44)
    ] {
        drawRoundedFill(rect.applying(CGAffineTransform(scaleX: scale, y: scale)), radius: 16 * scale, fill: numpadKey)
    }
}

func drawSwitchPill(scale: CGFloat, variant: AppIconVariant) {
    let badgeRect = CGRect(x: 262 * scale, y: 676 * scale, width: 500 * scale, height: 148 * scale)
    let badge = roundedRect(badgeRect, radius: 72 * scale)
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = color(0.00, 0.04, 0.07, 0.20)
    badgeShadow.shadowBlurRadius = 16 * scale
    badgeShadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
    badgeShadow.set()
    NSGradient(colors: [
        color(1, 1, 1, 0.96),
        color(0.89, 0.97, 1, 0.94)
    ])?.draw(in: badge, angle: 90)
    NSShadow().set()
    color(1, 1, 1, 0.80).setStroke()
    badge.lineWidth = 5 * scale
    badge.stroke()

    let chipHeight: CGFloat = 74
    let aChipWidth: CGFloat = 106
    let arrowWidth: CGFloat = 76
    let gap: CGFloat = 20
    let totalControlsWidth = aChipWidth + gap + arrowWidth + gap + variant.targetChipWidth
    let controlsStartX = 512 - totalControlsWidth / 2
    let aChip = CGRect(x: controlsStartX * scale, y: 714 * scale, width: aChipWidth * scale, height: chipHeight * scale)
    let arrowRect = CGRect(x: (controlsStartX + aChipWidth + gap) * scale, y: 714 * scale, width: arrowWidth * scale, height: chipHeight * scale)
    let targetChip = CGRect(x: (controlsStartX + aChipWidth + gap + arrowWidth + gap) * scale, y: 714 * scale, width: variant.targetChipWidth * scale, height: chipHeight * scale)

    drawRoundedFill(aChip, radius: 27 * scale, fill: color(0.02, 0.45, 0.56))
    drawRoundedFill(targetChip, radius: 27 * scale, fill: color(0.90, 0.98, 1))
    let targetBorder = roundedRect(targetChip, radius: 27 * scale)
    targetBorder.lineWidth = 3 * scale
    color(0.02, 0.46, 0.57, 0.30).setStroke()
    targetBorder.stroke()

    drawCenteredText("A", in: aChip, fontSize: variant.latinFontSize * scale, weight: .bold, color: color(0.94, 1, 1))
    drawSwitchArrow(in: arrowRect, scale: scale)

    let fontNames: [String]
    switch variant {
    case .bopomofo:
        fontNames = ["PingFangTC-Semibold", "PingFang TC Semibold", "PingFangTC-Regular", "Heiti TC"]
    case .zhuyin:
        fontNames = ["PingFangTC-Semibold", "PingFang TC Semibold", "Heiti TC"]
    }

    drawCenteredText(
        variant.glyph,
        in: targetChip,
        fontSize: variant.glyphFontSize * scale,
        weight: .bold,
        color: color(0.03, 0.32, 0.40),
        fontNames: fontNames
    )
}

func drawIcon(pixels: Int, variant: AppIconVariant) -> NSImage {
    let size = CGFloat(pixels)
    let scale = size / 1024
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let canvas = CGRect(x: 58 * scale, y: 58 * scale, width: 908 * scale, height: 908 * scale)
    let base = roundedRect(canvas, radius: 218 * scale)
    NSGraphicsContext.saveGraphicsState()
    let baseShadow = NSShadow()
    baseShadow.shadowColor = color(0.00, 0.02, 0.04, 0.34)
    baseShadow.shadowBlurRadius = 46 * scale
    baseShadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    baseShadow.set()
    NSGradient(colors: [
        color(0.02, 0.07, 0.11),
        color(0.03, 0.29, 0.40),
        color(0.00, 0.64, 0.74)
    ])?.draw(in: base, angle: 135)
    NSGraphicsContext.restoreGraphicsState()

    let glass = roundedRect(canvas.insetBy(dx: 24 * scale, dy: 24 * scale), radius: 194 * scale)
    color(1, 1, 1, 0.11).setStroke()
    glass.lineWidth = 6 * scale
    glass.stroke()

    drawKeyboard(scale: scale)
    drawSwitchPill(scale: scale, variant: variant)

    NSGraphicsContext.current?.flushGraphics()
    image.unlockFocus()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(url.lastPathComponent)")
    }

    try pngData.write(to: url)
}

for spec in specs {
    let image = drawIcon(pixels: spec.pixels, variant: variant)
    try writePNG(image, to: iconsetURL.appendingPathComponent(spec.filename))

    if let previewDirectory {
        let previewURL = previewDirectory.appendingPathComponent("\(variant.previewName)-\(spec.pixels).png")
        try writePNG(image, to: previewURL)
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]

try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}
