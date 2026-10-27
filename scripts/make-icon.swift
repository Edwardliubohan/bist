#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/BrandAssets", isDirectory: true)
let fileManager = FileManager.default
let iconset = output.appendingPathComponent("bist.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

func markImage(pixels: Int, response: CGFloat = 0, background: CGColor? = nil) throws -> CGImage {
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
    let controlPoints: [CGPoint] = [
        CGPoint(x: 8.25, y: 5.504809),
        CGPoint(x: 10.570508, y: 4.165064),
        CGPoint(x: 13.429492, y: 4.165064),
        CGPoint(x: 15.75, y: 5.504809),
        CGPoint(x: 18.070508, y: 6.844555),
        CGPoint(x: 19.5, y: 9.320508),
        CGPoint(x: 19.5, y: 12)
    ]
    let colors = [
        CGColor(srgbRed: 255 / 255, green: 194 / 255, blue: 138 / 255, alpha: 1),
        CGColor(srgbRed: 245 / 255, green: 138 / 255, blue: 61 / 255, alpha: 1),
        CGColor(srgbRed: 201 / 255, green: 83 / 255, blue: 27 / 255, alpha: 1)
    ]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 0.5, 1])!
    for index in 0..<2 {
        func point(_ position: Int) -> CGPoint {
            let source = controlPoints[position]
            return index == 1 ? CGPoint(x: 24 - source.x, y: 24 - source.y) : source
        }
        context.saveGState()
        context.translateBy(x: 12, y: 12)
        context.rotate(by: (index == 0 ? response : -response) * .pi / 180)
        context.translateBy(x: -12, y: -12)
        context.move(to: point(0))
        context.addCurve(to: point(3), control1: point(1), control2: point(2))
        context.addCurve(to: point(6), control1: point(4), control2: point(5))
        context.setLineWidth(4.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 4, y: 3), end: CGPoint(x: 20, y: 21),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
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
        try save(markImage(pixels: points * scale), to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

for pixels in [16, 24, 48] {
    for (state, response): (String, CGFloat) in [("rest", 0), ("hover", 3), ("expanded", 0)] {
        try save(markImage(pixels: pixels, response: response),
                 to: output.appendingPathComponent("mark-\(pixels)-\(state).png"))
    }
    for (name, gray): (String, CGFloat) in [("light", 0.96), ("dark", 0.10)] {
        for (state, response): (String, CGFloat) in [("rest", 0), ("hover", 3), ("expanded", 0)] {
            try save(markImage(pixels: pixels, response: response, background: CGColor(gray: gray, alpha: 1)),
                     to: output.appendingPathComponent("mark-\(pixels)-\(name)-\(state).png"))
        }
    }
}

let sheetWidth = 648
let sheetHeight = 360
let sheetSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let sheet = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                      bytesPerRow: 0, space: sheetSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(CGColor(gray: 0.96, alpha: 1))
sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
sheet.interpolationQuality = .none
for (row, gray): (Int, CGFloat) in [(0, 0.96), (1, 0.10)] {
    let rowY = CGFloat((1 - row) * 180)
    sheet.setFillColor(CGColor(gray: gray, alpha: 1))
    sheet.fill(CGRect(x: 0, y: rowY, width: CGFloat(sheetWidth), height: 180))
    for (column, pixels) in [16, 24, 48].enumerated() {
        let x = CGFloat(column * 216)
        for (stateIndex, response): (Int, CGFloat) in [(0, 0), (1, 3), (2, 0)] {
            let image = try markImage(pixels: pixels, response: response)
            let center = x + CGFloat(stateIndex * 68) + 40
            sheet.draw(image, in: CGRect(x: center - CGFloat(pixels) / 2, y: rowY + 120,
                                        width: CGFloat(pixels), height: CGFloat(pixels)))
            sheet.draw(image, in: CGRect(x: center - 28, y: rowY + 34, width: 56, height: 56))
        }
    }
}
try save(sheet.makeImage()!, to: output.appendingPathComponent("mark-size-qa.png"))

let iconURL = output.appendingPathComponent("bist.icns")
guard let destination = CGImageDestinationCreateWithURL(iconURL as CFURL, "com.apple.icns" as CFString, 10, nil) else {
    throw NSError(domain: "bist.icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create native ICNS destination."])
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        CGImageDestinationAddImage(destination, try markImage(pixels: points * scale),
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
print("Small-size light/dark previews: \(output.appendingPathComponent("mark-size-qa.png").path)")
