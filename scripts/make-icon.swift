#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO

// Native, dependency-free exports of the same 24-unit geometry as BistFace.
// Usage: xcrun swift -module-cache-path build/module-cache scripts/make-icon.swift build/BrandAssets
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/BrandAssets", isDirectory: true)
let fileManager = FileManager.default
let iconset = output.appendingPathComponent("bist.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

func faceImage(pixels: Int, response: CGFloat = 0, background: CGColor? = nil) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "bist.icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate icon renderer."])
    }
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 24, y: -CGFloat(pixels) / 24)
    let outlineWidth = max(24 * 1.4 / CGFloat(pixels), 2.15)
    let frame = CGRect(x: 1.5 + outlineWidth / 2, y: 1.5 + outlineWidth / 2,
                       width: 21 - outlineWidth, height: 21 - outlineWidth)
    let outline = CGPath(roundedRect: frame, cornerWidth: 6.5 - outlineWidth / 2,
                         cornerHeight: 6.5 - outlineWidth / 2, transform: nil)
    context.addPath(outline)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(outlineWidth)
    context.drawPath(using: .fillStroke)

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(max(24 * 1.5 / CGFloat(pixels), 2.3))
    for x: CGFloat in [8.7, 15.3] {
        context.move(to: CGPoint(x: x + response * 0.2, y: 8.7 - response * 0.15))
        context.addLine(to: CGPoint(x: x + response * 0.2, y: 10.1 + response * 0.1))
    }
    context.move(to: CGPoint(x: 9.2, y: 14.9 - response * 0.2))
    context.addLine(to: CGPoint(x: 10.7, y: 15.8 + response * 0.3))
    context.addLine(to: CGPoint(x: 13.0, y: 15.8 + response * 0.3))
    context.addLine(to: CGPoint(x: 14.8, y: 14.5 - response * 0.4))
    context.strokePath()
    guard let image = context.makeImage() else {
        throw NSError(domain: "bist.icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not finish icon renderer."])
    }
    return image
}

func save(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "bist.icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon PNG."])
    }
    try data.write(to: url, options: .atomic)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try save(faceImage(pixels: points * scale), to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

for pixels in [16, 24, 48] {
    for (name, gray): (String, CGFloat) in [("light", 0.96), ("dark", 0.10)] {
        for (state, response): (String, CGFloat) in [("rest", 0), ("hover", 0.55), ("expanded", 1)] {
            try save(faceImage(pixels: pixels, response: response, background: CGColor(gray: gray, alpha: 1)),
                     to: output.appendingPathComponent("face-\(pixels)-\(name)-\(state).png"))
        }
    }
}

// A native contact sheet shows real 16/24/48-pixel renders, enlarged with nearest
// interpolation for inspection alongside their actual-size equivalents.
let sheetWidth = 432
let sheetHeight = 312
let sheetSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let sheet = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                      bytesPerRow: 0, space: sheetSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(CGColor(gray: 0.96, alpha: 1))
sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
sheet.interpolationQuality = .none
for (row, gray): (Int, CGFloat) in [(0, 0.96), (1, 0.10)] {
    let rowY = CGFloat((1 - row) * 156)
    sheet.setFillColor(CGColor(gray: gray, alpha: 1))
    sheet.fill(CGRect(x: 0, y: rowY, width: CGFloat(sheetWidth), height: 156))
    for (column, pixels) in [16, 24, 48].enumerated() {
        let image = try faceImage(pixels: pixels)
        let x = CGFloat(column * 144)
        sheet.draw(image, in: CGRect(x: x + 72 - CGFloat(pixels) / 2, y: rowY + 106, width: CGFloat(pixels), height: CGFloat(pixels)))
        sheet.draw(image, in: CGRect(x: x + 24, y: rowY + 10, width: 96, height: 96))
    }
}
try save(sheet.makeImage()!, to: output.appendingPathComponent("face-size-qa.png"))

let iconURL = output.appendingPathComponent("bist.icns")
guard let destination = CGImageDestinationCreateWithURL(iconURL as CFURL, "com.apple.icns" as CFString, 10, nil) else {
    throw NSError(domain: "bist.icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create native ICNS destination."])
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        CGImageDestinationAddImage(destination, try faceImage(pixels: points * scale),
                                  [kCGImagePropertyDPIWidth: 72 * scale,
                                   kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    }
}
guard CGImageDestinationFinalize(destination),
      let verified = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
      CGImageSourceGetCount(verified) == 10 else {
    throw NSError(domain: "bist.icon", code: 5, userInfo: [NSLocalizedDescriptionKey: "Native ICNS export did not verify."])
}
print("Created \(iconURL.path) with 10 verified representations")
print("Small-size light/dark previews: \(output.appendingPathComponent("face-size-qa.png").path)")
