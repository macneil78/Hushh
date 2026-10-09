// Draws Hush's app icon into App/Assets.xcassets/AppIcon.appiconset.
// Run from the repository root: swift scripts/make-icon.swift
//
// A dusk gradient with a speech bubble whose three dots fade out: a conversation, quietly.
// Full-bleed, because macOS rounds the corners itself. No Telegram paper plane (the API terms
// forbid using Telegram's logo).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func drawIcon(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Draw on a 1024-point canvas with the origin at the top left.
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: 0, y: -1024)

    // Background: indigo to teal, corner to corner.
    let background = CGGradient(colorsSpace: space, colors: [color(0x4A5BD6), color(0x2BA9A0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
    // A soft glow, top left.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 260, y: 220), startRadius: 0, endCenter: CGPoint(x: 260, y: 220), endRadius: 620, options: [])

    // The speech bubble, with a small tail at the bottom left. Body and tail are filled
    // separately inside one layer, so they merge into one shape with a single shadow.
    let body = CGPath(roundedRect: CGRect(x: 202, y: 292, width: 620, height: 420), cornerWidth: 190, cornerHeight: 190, transform: nil)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 300, y: 640))
    tail.addQuadCurve(to: CGPoint(x: 252, y: 818), control: CGPoint(x: 316, y: 772))
    tail.addQuadCurve(to: CGPoint(x: 470, y: 690), control: CGPoint(x: 380, y: 790))
    tail.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0x101840, 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(color(0xF7F9FC))  // opaque, so the overlap doesn't show
    for shape in [body, tail] {
        context.addPath(shape)
        context.fillPath()
    }
    context.endTransparencyLayer()
    context.restoreGState()

    // Three dots, fading: the conversation going quiet.
    for (index, alpha) in [1.0, 0.6, 0.28].enumerated() {
        let center = CGPoint(x: 392 + CGFloat(index) * 120, y: 502)
        context.addEllipse(in: CGRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80))
        context.setFillColor(color(0x4552C9, alpha))
        context.fillPath()
    }
    return context.makeImage()!
}

let directory = URL(filePath: "App/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = directory.appending(path: "icon_\(size).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(size: size), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

// Each macOS slot: (point size, scale, pixel file).
let slots: [(Int, Int, Int)] = [(16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64), (128, 1, 128), (128, 2, 256), (256, 1, 256), (256, 2, 512), (512, 1, 512), (512, 2, 1024)]
let images = slots.map { points, scale, pixels in
    #"    { "idiom" : "mac", "size" : "\#(points)x\#(points)", "scale" : "\#(scale)x", "filename" : "icon_\#(pixels).png" }"#
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: directory.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
try "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n".write(
    to: directory.deletingLastPathComponent().appending(path: "Contents.json"), atomically: true, encoding: .utf8
)
print("Wrote \(directory.path)")
