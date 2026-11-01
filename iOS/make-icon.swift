#!/usr/bin/env swift
import AppKit
import ImageIO

// Composite the existing bist mark onto an opaque iPhone icon background.
let arguments = CommandLine.arguments
let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let mark = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not open the existing bist mark")
}
context.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(mark, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let result = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not encode the phone icon")
}
CGImageDestinationAddImage(output, result, nil)
precondition(CGImageDestinationFinalize(output), "Could not save the phone icon")
