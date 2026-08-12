#!/usr/bin/env swift
// Draws Qopy's source icon (full-bleed).
//
//     swift scripts/draw-icon.swift assets/icon.png
//
// Mask to a macOS squircle:
//
//     swift scripts/make-icon.swift --full-bleed assets/icon.png Mac/Qopy/Qopy.icns
//     swift scripts/make-icon.swift --full-bleed assets/icon.png assets/app-icon.png 384

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: draw-icon.swift <out.png>\n".utf8))
    exit(2)
}
let destination = URL(fileURLWithPath: arguments[1])
let size = 1024
let S = CGFloat(size)

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("draw-icon: no context\n".utf8))
    exit(1)
}

// Soft slate gradient, edge to edge.
let colors = [
    NSColor(srgbRed: 0.50, green: 0.57, blue: 0.64, alpha: 1).cgColor,
    NSColor(srgbRed: 0.30, green: 0.36, blue: 0.43, alpha: 1).cgColor,
] as CFArray
if let gradient = CGGradient(colorsSpace: ctx.colorSpace, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: S),
        end: CGPoint(x: S, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

/// Classic QR finder: outer ring + inner eye. Drawn as filled shapes (no strokes)
/// so edges stay crisp at every icon size.
func drawFinder(center: CGPoint, outer: CGFloat) {
    let ring: CGFloat = outer * 0.16
    let gap: CGFloat = outer * 0.14
    let eye = outer - (ring + gap) * 2
    let radius: CGFloat = outer * 0.12

    func roundedRect(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    let outerRect = CGRect(x: center.x - outer / 2, y: center.y - outer / 2, width: outer, height: outer)
    let holeRect = outerRect.insetBy(dx: ring, dy: ring)
    let eyeRect = CGRect(x: center.x - eye / 2, y: center.y - eye / 2, width: eye, height: eye)

    // Outer rounded square
    ctx.addPath(roundedRect(outerRect))
    // Punch the middle (even-odd)
    ctx.addPath(roundedRect(holeRect))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath(using: .evenOdd)

    // Inner eye
    ctx.addPath(roundedRect(eyeRect))
    ctx.fillPath()
}

let outer: CGFloat = 250
let inset: CGFloat = 220
drawFinder(center: CGPoint(x: inset + outer / 2, y: S - inset - outer / 2), outer: outer) // TL
drawFinder(center: CGPoint(x: S - inset - outer / 2, y: S - inset - outer / 2), outer: outer) // TR
drawFinder(center: CGPoint(x: inset + outer / 2, y: inset + outer / 2), outer: outer) // BL

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("draw-icon: encode failed\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: destination)
print("wrote \(destination.path)")
