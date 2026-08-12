#!/usr/bin/env swift
// Draws Qopy's source icon artwork (full-bleed, no floating card).
//
//     swift scripts/draw-icon.swift assets/icon.png
//
// Then mask to a macOS squircle with:
//
//     swift scripts/make-icon.swift --full-bleed assets/icon.png Mac/Qopy/Qopy.icns
//     swift scripts/make-icon.swift --full-bleed assets/icon.png assets/icon-rounded.png 384

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

let bounds = CGRect(x: 0, y: 0, width: S, height: S)

// Soft slate gradient — matches the product tone, fills edge to edge.
let colors = [
    NSColor(srgbRed: 0.48, green: 0.55, blue: 0.62, alpha: 1).cgColor,
    NSColor(srgbRed: 0.32, green: 0.38, blue: 0.45, alpha: 1).cgColor,
] as CFArray
if let gradient = CGGradient(colorsSpace: ctx.colorSpace, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: S),
        end: CGPoint(x: S, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func drawCornerBracket(center: CGPoint, rotationTurns: Int) {
    let box: CGFloat = 210
    let stroke: CGFloat = 36
    let coreInset: CGFloat = 58
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: CGFloat(rotationTurns) * .pi / 2)
    let origin = CGPoint(x: -box / 2, y: -box / 2)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: origin.x, y: origin.y + box))
    path.addLine(to: CGPoint(x: origin.x, y: origin.y))
    path.addLine(to: CGPoint(x: origin.x + box, y: origin.y))
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()

    let coreSize = box - coreInset * 2
    let core = CGRect(x: origin.x + coreInset, y: origin.y + coreInset, width: coreSize, height: coreSize)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: core, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

// Finder triad: TL, TR, BL — classic QR silhouette.
let margin: CGFloat = 280
drawCornerBracket(center: CGPoint(x: margin, y: S - margin), rotationTurns: 0)
drawCornerBracket(center: CGPoint(x: S - margin, y: S - margin), rotationTurns: 1)
drawCornerBracket(center: CGPoint(x: margin, y: margin), rotationTurns: 3)
guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("draw-icon: encode failed\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: destination)
print("wrote \(destination.path)")
