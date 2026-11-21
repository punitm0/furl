#!/usr/bin/env swift
// Renders the DMG window background (InstallHandoff board, "DMG window · 660 × 400 pt") at 1x and 2x.
// Finder draws the two icons and their names on top: Furl.app at (170,196), Applications at (490,196).
//
//   swift scripts/make_dmg_background.swift [version] [output-folder]
//
// Defaults: the version in scripts/build_app.sh's Info.plist, and Resources/dmg. scripts/make_dmg.sh
// runs this with the built app's version, so the footer always matches the build.
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = CommandLine.arguments

/// CFBundleShortVersionString as written in build_app.sh, so the committed images match the source.
func versionFromBuildScript() -> String {
    let script = (try? String(contentsOf: root.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)) ?? ""
    let lines = script.components(separatedBy: "\n")
    guard let key = lines.firstIndex(where: { $0.contains("<key>CFBundleShortVersionString</key>") }),
          key + 1 < lines.count else { return "1.0.0" }
    let value = lines[key + 1]
    guard let start = value.range(of: "<string>"), let end = value.range(of: "</string>") else { return "1.0.0" }
    return String(value[start.upperBound..<end.lowerBound])
}

let version = arguments.count > 1 && !arguments[1].isEmpty ? arguments[1] : versionFromBuildScript()
let outputFolder = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : root.appendingPathComponent("Resources/dmg")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Board colours (fixed: the DMG is drawn before any theme exists).
let ground = color(0xF5F5F2), ink = color(0x1A1A1A), inkSecondary = color(0x4A4A47)
let sweep = color(0x0B7A5E), footerFill = color(0xEEEEEA), footerLine = color(0xE3E3DE), dot = color(0x8A8F8C)

let width: CGFloat = 660, height: CGFloat = 400

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
}

/// Draws a line whose CSS line box starts at `top` (line-height normal), centred on `centerX`.
func draw(_ string: NSAttributedString, centerX: CGFloat, top: CGFloat) {
    let size = string.size()
    string.draw(at: NSPoint(x: (centerX - size.width / 2).rounded(), y: top))
}

func drawLeft(_ string: NSAttributedString, x: CGFloat, middleY: CGFloat) -> CGFloat {
    let size = string.size()
    string.draw(at: NSPoint(x: x, y: (middleY - size.height / 2).rounded()))
    return size.width
}

func renderBackground() {
    ground.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    draw(text("Furl", font(24, .bold), ink), centerX: width / 2, top: 34)
    draw(text("Drag Furl to Applications to install", font(14), inkSecondary), centerX: width / 2, top: 70)

    // The dashed arrow, unchanged from 1.3: a curve whose dashes get shorter, a dot, then the chevron.
    sweep.setStroke()
    sweep.setFill()
    let curve = NSBezierPath()
    curve.move(to: NSPoint(x: 254.5, y: 195))
    curve.curve(to: NSPoint(x: 364, y: 182.5), controlPoint1: NSPoint(x: 290, y: 172), controlPoint2: NSPoint(x: 330, y: 170))
    curve.setLineDash([42, 16, 17, 16, 7, 14, 0.5, 100], count: 8, phase: 0)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 404.5, y: 184))
    head.line(to: NSPoint(x: 413.5, y: 195))
    head.line(to: NSPoint(x: 404.5, y: 206))
    for path in [curve, head] {
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    NSBezierPath(ovalIn: NSRect(x: 378 - 2.8, y: 187 - 2.8, width: 5.6, height: 5.6)).fill()

    // New in 1.4.0: what to do after the drag, centred under the arrow at y 222–238.
    draw(text("Then open Furl from Applications", font(12.5, .semibold), sweep), centerX: width / 2, top: 222)

    draw(text("Furl is open source and not notarized yet, so macOS asks you to approve it once.", font(11.5, .semibold), ink),
         centerX: width / 2, top: 302)
    let help = NSMutableAttributedString(attributedString: text("Saw “Furl” Not Opened? Click Done, then ", font(11.5), inkSecondary))
    help.append(text("System Settings › Privacy & Security › Open Anyway", font(11.5, .bold), ink))
    help.append(text(".", font(11.5), inkSecondary))
    draw(help, centerX: width / 2, top: 322)

    // Footer: 46 pt bar with a hairline on top.
    let footerTop = height - 46
    footerFill.setFill()
    NSRect(x: 0, y: footerTop, width: width, height: 46).fill()
    footerLine.setFill()
    NSRect(x: 0, y: footerTop, width: width, height: 1).fill()
    let middle = footerTop + 23.5
    var x: CGFloat = 20
    for part in [text("Version \(version)", font(11.5, .bold), ink), text("·", font(11.5), dot),
                 text("Private · Offline", font(11.5), sweep)] {
        x += drawLeft(part, x: x, middleY: middle) + 8
    }
    let link = text("getfurl.app/install", font(11.5, .bold), sweep)
    let label = text("Install help", font(11.5), inkSecondary)
    let linkX = width - 20 - link.size().width
    _ = drawLeft(link, x: linkX, middleY: middle)
    _ = drawLeft(label, x: linkX - 8 - label.size().width, middleY: middle)
}

func png(scale: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    // Flipped, so every coordinate reads like the board's CSS (y grows downwards).
    let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = flipped
    flipped.cgContext.translateBy(x: 0, y: height)
    flipped.cgContext.scaleBy(x: 1, y: -1)
    renderBackground()
    NSGraphicsContext.restoreGraphicsState()
    let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
    return srgb.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
try png(scale: 1).write(to: outputFolder.appendingPathComponent("dmg-background.png"))
try png(scale: 2).write(to: outputFolder.appendingPathComponent("dmg-background@2x.png"))
print("Wrote dmg-background.png and @2x (Version \(version)) to \(outputFolder.path)")
