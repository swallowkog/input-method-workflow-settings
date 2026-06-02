#!/usr/bin/env swift
import AppKit
import Foundation

enum MenuIconState: String, CaseIterable {
    case active
    case paused
    case permissionNeeded
    case disabled

    var filename: String {
        switch self {
        case .active:
            return "menuIcon_active"
        case .paused:
            return "menuIcon_paused"
        case .permissionNeeded:
            return "menuIcon_permissionNeeded"
        case .disabled:
            return "menuIcon_disabled"
        }
    }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/menu-bar-icons", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(state: MenuIconState, size: CGFloat) -> NSImage {
    let scale = size / 24
    let image = NSImage(size: NSSize(width: size, height: 18 * scale), flipped: false) { _ in
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: 18 * scale).fill()

        func r(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.origin.x * scale, y: rect.origin.y * scale, width: rect.width * scale, height: rect.height * scale)
        }

        let baseAlpha: CGFloat = state == .disabled ? 0.50 : 1.0
        let inkBase: NSColor = state == .permissionNeeded ? NSColor(calibratedWhite: 0.38, alpha: 1.0) : .black
        let ink = inkBase.withAlphaComponent(baseAlpha)
        ink.setStroke()
        ink.setFill()

        let keyboardPath = roundedRect(r(NSRect(x: 2.1, y: 3.2, width: 19.8, height: 11.2)), radius: 2.7 * scale)
        keyboardPath.lineWidth = 1.45 * scale
        keyboardPath.stroke()

        let keys = [
            NSRect(x: 5.2, y: 10.0, width: 2.2, height: 1.35),
            NSRect(x: 8.7, y: 10.0, width: 2.2, height: 1.35),
            NSRect(x: 12.2, y: 10.0, width: 2.2, height: 1.35),
            NSRect(x: 5.2, y: 7.55, width: 2.2, height: 1.35),
            NSRect(x: 8.7, y: 7.55, width: 2.2, height: 1.35),
            NSRect(x: 12.2, y: 7.55, width: 2.2, height: 1.35),
            NSRect(x: 5.2, y: 5.0, width: 9.4, height: 1.35),
            NSRect(x: 16.3, y: 10.0, width: 1.85, height: 1.35),
            NSRect(x: 18.65, y: 10.0, width: 1.65, height: 1.35),
            NSRect(x: 16.3, y: 7.55, width: 1.85, height: 1.35),
            NSRect(x: 18.65, y: 7.55, width: 1.65, height: 1.35),
            NSRect(x: 16.3, y: 5.0, width: 4.05, height: 1.35)
        ]

        for rect in keys {
            roundedRect(r(rect), radius: 0.65 * scale).fill()
        }

        let markerColor: NSColor = state == .permissionNeeded ? .systemRed : inkBase
        markerColor.setStroke()
        markerColor.setFill()
        switch state {
        case .active:
            break
        case .paused:
            for rect in [
                NSRect(x: 18.2, y: 12.6, width: 1.25, height: 4.5),
                NSRect(x: 20.6, y: 12.6, width: 1.25, height: 4.5)
            ] {
                roundedRect(r(rect), radius: 0.62 * scale).fill()
            }
        case .permissionNeeded:
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 20.6 * scale, y: 17.0 * scale))
            mark.line(to: NSPoint(x: 20.6 * scale, y: 13.4 * scale))
            mark.lineWidth = 1.7 * scale
            mark.lineCapStyle = .round
            mark.stroke()
            NSBezierPath(ovalIn: r(NSRect(x: 19.75, y: 11.2, width: 1.7, height: 1.7))).fill()
        case .disabled:
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3.2 * scale, y: 3.4 * scale))
            slash.line(to: NSPoint(x: 21.0 * scale, y: 15.0 * scale))
            slash.lineWidth = 1.75 * scale
            slash.lineCapStyle = .round
            slash.stroke()
        }

        return true
    }
    image.isTemplate = state != .permissionNeeded
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

for state in MenuIconState.allCases {
    for size in [16, 18, 20, 32, 36, 40] {
        let image = drawIcon(state: state, size: CGFloat(size))
        try writePNG(image, to: outputDirectory.appendingPathComponent("\(state.filename)_\(size).png"))
    }
}
