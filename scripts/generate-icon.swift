#!/usr/bin/env swift
//
// Procedurally render the Typeforme app icon at every macOS-required size,
// drop the PNGs into Resources/AppIcon.iconset/, then iconutil packages the
// final .icns. Re-run any time the design changes.
//
// Design: deep indigo→violet diagonal gradient on a macOS-style squircle, with
// a clean white SF-Symbol-style microphone (pill body + U cradle + stem + base).
//
import Foundation
import AppKit

// Logical size in points + scale factor → pixel size on disk.
let logicalSizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let scriptURL  = URL(fileURLWithPath: CommandLine.arguments[0])
let projectURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = projectURL.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // 1. Squircle background — macOS app icon corner radius ≈ 22.5% of size.
    let cornerR = s * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Diagonal gradient: deep indigo → violet.
    let bgColors: CFArray = [
        CGColor(red: 0.24, green: 0.20, blue: 0.78, alpha: 1.0),  // #3D33C7-ish indigo
        CGColor(red: 0.56, green: 0.30, blue: 0.96, alpha: 1.0),  // #8F4DF5 violet
    ] as CFArray
    if let g = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            g,
            start: CGPoint(x: 0,         y: s),         // top-left
            end:   CGPoint(x: s,         y: 0),         // bottom-right
            options: []
        )
    }

    // Soft top-left highlight (subtle radial wash).
    let glowColors: CFArray = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    if let g = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(
            g,
            startCenter: CGPoint(x: s * 0.30, y: s * 0.85), startRadius: 0,
            endCenter:   CGPoint(x: s * 0.30, y: s * 0.85), endRadius: s * 0.60,
            options: []
        )
    }
    ctx.restoreGState()

    // 2. Microphone body — rounded pill, white.
    let micCx     = s * 0.50
    let micW      = s * 0.30
    let micH      = s * 0.36
    let micTop    = s * 0.80
    let micBot    = micTop - micH
    let micRect   = CGRect(x: micCx - micW / 2, y: micBot, width: micW, height: micH)
    let micCornerR = micW / 2  // fully-rounded ends

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: micRect, cornerWidth: micCornerR, cornerHeight: micCornerR, transform: nil))
    ctx.fillPath()

    // 3. U-shaped cradle below the mic.
    let strokeW = s * 0.045
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)

    let cradleR  = s * 0.20
    let cradleCy = micBot - s * 0.02  // arc center slightly below mic body
    ctx.addArc(
        center: CGPoint(x: micCx, y: cradleCy),
        radius: cradleR,
        startAngle: 0,             // 3 o'clock
        endAngle:   .pi,           // 9 o'clock
        clockwise:  true           // go through 6 o'clock (the bottom)
    )
    ctx.strokePath()

    // 4. Vertical stem from bottom of cradle down to base.
    let stemTop = cradleCy - cradleR
    let stemBot = s * 0.16
    ctx.move(to: CGPoint(x: micCx, y: stemTop))
    ctx.addLine(to: CGPoint(x: micCx, y: stemBot))
    ctx.strokePath()

    // 5. Horizontal base line.
    let baseW = s * 0.20
    ctx.move(to: CGPoint(x: micCx - baseW / 2, y: stemBot))
    ctx.addLine(to: CGPoint(x: micCx + baseW / 2, y: stemBot))
    ctx.strokePath()

    // Emit PNG.
    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

for (logical, scale) in logicalSizes {
    let pixel = logical * scale
    let name  = scale == 1 ? "icon_\(logical)x\(logical).png"
                           : "icon_\(logical)x\(logical)@\(scale)x.png"
    let url   = iconsetURL.appendingPathComponent(name)
    guard let png = renderIcon(pixelSize: pixel) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: url)
    print("wrote \(name) (\(pixel)px)")
}

print("\nNext: iconutil -c icns \(iconsetURL.path) -o \(projectURL.path)/Resources/AppIcon.icns")
