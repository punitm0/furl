#!/usr/bin/env swift
// Renders the Furl mark, Curl f (Brand board / Theme.swift `SweepMarkRenderer`), into an .iconset
// and packs it with `iconutil`.
//
//   swift scripts/make_icon.swift [output.icns]
//
// Default output: Resources/AppIcon.icns
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Resources/AppIcon.icns")

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Graphite tile, light f, mint curl: the bundled (Finder) icon. In the app the curl follows the theme.
let tileColor = rgb(0x1C1C1C), tileEdge = rgb(0x333331), letter = rgb(0xF2F2EE), mint = rgb(0x5FE3B0)

/// Draws the icon into a square pixel canvas. Below 64 px it uses the bolder small-size glyph
/// (stroke 8), as the Brand board specifies.
func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let size = CGFloat(pixels)
    // macOS icon grid: the tile occupies ~80% of the canvas, leaving room for the shadow.
    let inset = size * 0.1
    let side = size - inset * 2
    let scale = side / 64
    // CoreGraphics is y-up; flip so the maths matches the SVG (y-down).
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    if pixels >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: size * 0.012), blur: size * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
    }
    let tileRect = CGRect(x: inset, y: inset, width: side, height: side)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 14.5 * scale, cornerHeight: 14.5 * scale, transform: nil)
    ctx.addPath(tile)
    ctx.setFillColor(tileColor)
    ctx.fillPath()
    if pixels >= 64 {
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 0.5 * scale, dy: 0.5 * scale),
                           cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
        ctx.setStrokeColor(tileEdge)
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()
    }

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inset + x * scale, y: inset + y * scale) }
    // Paths match SweepMarkRenderer.paths. The context is flipped (y-down), so clockwise: false
    // draws visually clockwise, like the SVG's sweep flag 1.
    let f = CGMutablePath(), curl = CGMutablePath(), bar = CGMutablePath()
    let lineWidth: CGFloat
    if pixels < 64 {
        f.move(to: pt(24, 56)); f.addLine(to: pt(24, 26))
        f.addArc(center: pt(38, 26), radius: 14 * scale, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        curl.move(to: pt(38, 12))
        curl.addArc(center: pt(38, 21), radius: 9 * scale, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        curl.addArc(center: pt(38, 26), radius: 4 * scale, startAngle: .pi / 2, endAngle: .pi * 1.5, clockwise: false)
        bar.move(to: pt(12, 36)); bar.addLine(to: pt(34, 36))
        lineWidth = 8 * scale
    } else {
        f.move(to: pt(26, 52)); f.addLine(to: pt(26, 26))
        f.addArc(center: pt(38, 26), radius: 12 * scale, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        curl.move(to: pt(38, 14))
        curl.addArc(center: pt(38, 21), radius: 7 * scale, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        curl.addArc(center: pt(38, 24.5), radius: 3.5 * scale, startAngle: .pi / 2, endAngle: .pi * 1.5, clockwise: false)
        bar.move(to: pt(17, 34)); bar.addLine(to: pt(35, 34))
        lineWidth = 6 * scale
    }
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (path, color) in [(f as CGPath, letter), (bar, letter), (curl, mint)] {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.strokePath()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Furl-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(output.path)")
