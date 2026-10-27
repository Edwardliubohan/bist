#!/usr/bin/env python3
import pathlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


root = pathlib.Path(__file__).resolve().parents[1]
output = root / "build/BrandAssets"
native = (root / "Sources/BistFace.swift").read_text()
exporter = (root / "scripts/make-icon.swift").read_text()
svg = ET.parse(root / "Assets/bist-mark.svg").getroot()
namespace = {"svg": "http://www.w3.org/2000/svg"}


def control_points(source):
    block = re.search(r"let controlPoints: \[CGPoint\] = \[(.*?)\n    \]", source, re.S)[1]
    return [tuple(map(float, point)) for point in re.findall(r"CGPoint\(x: ([\d.]+), y: ([\d.]+)\)", block)]


points = control_points(native)
assert len(points) == 7
assert points == control_points(exporter)
assert svg.attrib["viewBox"] == "0 0 24 24"
assert svg.find("svg:title", namespace).text == "bist"
assert svg.attrib["role"] == "img"
assert all(element.tag.split("}")[-1] not in {"script", "image", "animate", "animateTransform", "foreignObject"}
           for element in svg.iter())
assert all(not key.endswith("href") for element in svg.iter() for key in element.attrib)
for identifier, expected in [("orbit-upper", points), ("orbit-lower", [(24 - point[0], 24 - point[1]) for point in points])]:
    group = svg.find(f".//svg:g[@id='{identifier}']", namespace)
    path = group.find("svg:path", namespace).attrib["d"]
    assert re.findall(r"[A-Za-z]", path) == ["M", "C", "C"]
    actual = list(map(float, re.findall(r"[\d.]+", path)))
    assert len(actual) == 14
    assert all(abs(first - second) < 0.000001 for first, second in zip(actual, sum((list(point) for point in expected), [])))
orbit = svg.find("svg:g", namespace)
assert orbit.attrib["stroke-width"] == "4.5"
assert orbit.attrib["stroke-linecap"] == orbit.attrib["stroke-linejoin"] == "round"
assert "lineWidth: size * 4.5 / 24" in native and "context.setLineWidth(4.5)" in exporter
gradient = svg.find("svg:defs/svg:linearGradient", namespace)
assert gradient.attrib["gradientUnits"] == "userSpaceOnUse"
assert [gradient.attrib[key] for key in ["x1", "y1", "x2", "y2"]] == ["4", "3", "20", "21"]
assert "UnitPoint(x: 4 / 24, y: 3 / 24)" in native
assert "UnitPoint(x: 20 / 24, y: 21 / 24)" in native
assert "start: CGPoint(x: 4, y: 3), end: CGPoint(x: 20, y: 21)" in exporter
for stop in gradient:
    color = stop.attrib["stop-color"]
    red, green, blue = [int(color[index:index + 2], 16) for index in [1, 3, 5]]
    assert f"red: {red} / 255, green: {green} / 255, blue: {blue} / 255" in native
    assert f"srgbRed: {red} / 255, green: {green} / 255, blue: {blue} / 255" in exporter
assert [stop.attrib["offset"] for stop in gradient] == ["0", "0.5", "1"]
assert ".easeOut(duration: 0.16)" in native
assert "reduceMotion || systemReduceMotion" in native
assert "!motionDisabled && isHovered ? 9 : 0" in native
assert "transaction.disablesAnimations = true" in native
animated = ET.parse(root / "Assets/bist-mark-animated.svg").getroot()
assert [p.attrib["d"] for p in animated.findall(".//svg:path", namespace)] == [p.attrib["d"] for p in svg.findall(".//svg:path", namespace)]
assert not any(e.tag.split("}")[-1] in {"script", "image", "foreignObject"} for e in animated.iter())
assert all(not key.endswith("href") for element in animated.iter() for key in element.attrib)
assert "prefers-reduced-motion" in animated.find("svg:style", namespace).text
print("SVG/native/export path, stroke, gradient, accessibility, and motion contracts pass", flush=True)

subprocess.run(["xcrun", "swift", "-module-cache-path", str(root / "build/module-cache"),
                str(root / "scripts/make-icon.swift"), str(output)], check=True)

renderer = r'''
import AppKit
import SwiftUI
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func bytes(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

// ImageRenderer can round gradient RGB channels differently on identical
// renders (observed at 16px). Alpha must remain exact: it captures geometry.
func sameMark(_ first: CGImage, _ second: CGImage) -> Bool {
    guard first.width == second.width, first.height == second.height else { return false }
    let firstBytes = bytes(first)
    let secondBytes = bytes(second)
    return firstBytes.indices.allSatisfy { index in
        abs(Int(firstBytes[index]) - Int(secondBytes[index])) <= (index % 4 == 3 ? 0 : 1)
    }
}

@MainActor func render(_ pixels: Int, hover: Bool = false, expanded: Bool = false,
                       localReduce: Bool = false) -> CGImage {
    let renderer = ImageRenderer(content: BistFace(size: CGFloat(pixels), isHovered: hover,
                                                  isExpanded: expanded, reduceMotion: localReduce))
    renderer.scale = 1
    return renderer.cgImage!
}

func save(_ image: CGImage, _ name: String) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
}

@MainActor func verify() throws {
for pixels in [16, 24, 48] {
    let rest = render(pixels)
    let hover = render(pixels, hover: true)
    precondition(sameMark(rest, render(pixels)), "Repeated rest render differs")
    precondition(sameMark(hover, render(pixels, hover: true, expanded: true)), "Expanded hover differs from compact hover")
    precondition(sameMark(rest, render(pixels, hover: true, localReduce: true)), "Local reduced motion moves")
    precondition(sameMark(rest, render(pixels, expanded: true)), "Expanded resting orientation differs")
    precondition(sameMark(rest, render(pixels, hover: true, expanded: true, localReduce: true)), "Expanded reduced motion moves")
    let restBytes = bytes(rest)
    let hoverBytes = bytes(hover)
    precondition(stride(from: 3, to: restBytes.count, by: 4).contains {
        restBytes[$0] != hoverBytes[$0]
    }, "Hover has no geometry response")
    try save(rest, "native-mark-\(pixels)-rest.png")
    try save(hover, "native-mark-\(pixels)-hover.png")
    let referenceURL = output.appendingPathComponent("mark-\(pixels)-rest.png")
    let reference = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(referenceURL as CFURL, nil)!, 0, nil)!
    let nativeBytes = bytes(rest)
    let referenceBytes = bytes(reference)
    let error = zip(nativeBytes, referenceBytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    let meanError = Double(error) / Double(nativeBytes.count)
    var alphaError = 0
    var interiorError = 0
    for index in stride(from: 0, to: nativeBytes.count, by: 4) {
        alphaError += abs(Int(nativeBytes[index + 3]) - Int(referenceBytes[index + 3]))
        if nativeBytes[index + 3] == 255 && referenceBytes[index + 3] == 255 {
            for channel in 0..<3 {
                interiorError = max(interiorError, abs(Int(nativeBytes[index + channel]) - Int(referenceBytes[index + channel])))
            }
        }
    }
    let meanAlphaError = Double(alphaError) / Double(pixels * pixels)
    print("Native/export \(pixels)px mean RGBA: \(meanError), mean alpha: \(meanAlphaError), max interior color: \(interiorError) / 255")
    precondition(meanError < 6 && meanAlphaError < 8 && interiorError <= 6, "Native/export rendering diverged beyond antialias tolerance")
}

let icon = CGImageSourceCreateWithURL(output.appendingPathComponent("bist.icns") as CFURL, nil)!
precondition(CGImageSourceGetCount(icon) == 10)
var dimensions: [Int] = []
var representations = [String: [UInt8]]()
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = output.appendingPathComponent("bist.iconset/icon_\(points)x\(points)\(suffix).png")
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        representations["\(points * scale)-\(72 * scale)"] = bytes(image)
    }
}
for index in 0..<10 {
    let image = CGImageSourceCreateImageAtIndex(icon, index, nil)!
    precondition(image.width == image.height)
    dimensions.append(image.width)
    let properties = CGImageSourceCopyPropertiesAtIndex(icon, index, nil)! as NSDictionary
    let dpi = (properties[kCGImagePropertyDPIWidth] as! NSNumber).intValue
    precondition(bytes(image) == representations["\(image.width)-\(dpi)"], "ICNS representation differs from PNG")
}
precondition(dimensions.sorted() == [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024])

let sheet = CGContext(data: nil, width: 648, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.interpolationQuality = .none
for (row, gray): (Int, CGFloat) in [(0, 0.96), (1, 0.10)] {
    let rowY = CGFloat((1 - row) * 180)
    sheet.setFillColor(CGColor(gray: gray, alpha: 1))
    sheet.fill(CGRect(x: 0, y: rowY, width: 648, height: 180))
    for (column, pixels) in [16, 24, 48].enumerated() {
        for state in 0..<3 {
            let image = render(pixels, hover: state == 1, expanded: state == 2)
            let center = CGFloat(column * 216 + state * 68 + 40)
            sheet.draw(image, in: CGRect(x: center - CGFloat(pixels) / 2, y: rowY + 120,
                                        width: CGFloat(pixels), height: CGFloat(pixels)))
            sheet.draw(image, in: CGRect(x: center - 28, y: rowY + 34, width: 56, height: 56))
        }
    }
}
try save(sheet.makeImage()!, "native-mark-size-qa.png")
print("Native hover/rest/expanded/local reduced-motion renders and all 10 ICNS dimensions + PNG pixel parity pass")
}
try MainActor.assumeIsolated { try verify() }
'''

with tempfile.TemporaryDirectory(prefix="bist-logo-") as temporary:
    directory = pathlib.Path(temporary)
    source = directory / "main.swift"
    source.write_text(renderer)
    binary = directory / "logo-check"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "build/module-cache"),
                    str(source), str(root / "Sources/BistFace.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(output)], check=True)
print(f"Native contact sheet: {output / 'native-mark-size-qa.png'}")
