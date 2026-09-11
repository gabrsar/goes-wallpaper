// Removes the caption strip NOAA stamps along the bottom of each frame.
//
// Usage: goes-image trim-caption <in.jpg> <out.jpg>
//
// Prints the number of rows removed. With 0 (no caption found) nothing is
// written. Exit codes: 0 ok, 64 usage, 65 unreadable image, 73 write failed.
//
// The caption is recognised by its shape rather than a fixed height, because
// NOAA sizes it differently for every resolution. Scanning upward from the
// bottom edge, a caption is exactly:
//   near-white padding, then a band of text on white, then near-white padding,
// all within the bottom 8% of the frame. Anything else (bright clouds, black
// space, an all-white image) is left alone. Keep in step with image.sh.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let padFraction = 0.95     // share of a row that must be near-white for padding
let textFraction = 0.30    // minimum near-white share of a row inside the text band
let whiteLevel: UInt8 = 200
let maxScanPixels = 200_000_000  // the largest frames carry no caption

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

/// Near-white share of each of the bottom `band` rows; index 0 is the bottom row.
func bottomProfile(_ image: CGImage, band: Int) -> [Double]? {
    let width = image.width
    let height = image.height
    guard let strip = image.cropping(to: CGRect(x: 0, y: height - band, width: width, height: band)),
          let context = CGContext(data: nil, width: width, height: band, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: band))
    guard let data = context.data else { return nil }

    let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * band)
    let step = max(1, width / 800)
    let samples = (width + step - 1) / step
    var profile: [Double] = []
    // Bitmap memory runs top to bottom, so the last buffer row is the bottom edge.
    for fromBottom in 0..<band {
        let row = pixels + (band - 1 - fromBottom) * context.bytesPerRow
        var white = 0
        var x = 0
        while x < width {
            if row[x] > whiteLevel { white += 1 }
            x += step
        }
        profile.append(Double(white) / Double(samples))
    }
    return profile
}

/// Rows occupied by the caption, or 0 when the bottom does not look like one.
func captionHeight(_ profile: [Double]) -> Int {
    let limit = profile.count
    var k = 0
    guard limit > 0, profile[0] >= padFraction else { return 0 }
    while k < limit && profile[k] >= padFraction { k += 1 }
    guard k < limit else { return 0 }
    var textRows = 0
    while k < limit && profile[k] >= textFraction && profile[k] < padFraction { k += 1; textRows += 1 }
    guard k < limit, textRows > 0, profile[k] >= padFraction else { return 0 }
    while k < limit && profile[k] >= padFraction { k += 1 }
    guard k < limit else { return 0 }
    return k
}

let args = CommandLine.arguments
guard args.count == 4, args[1] == "trim-caption" else {
    fail("usage: goes-image trim-caption <in.jpg> <out.jpg>", 64)
}

let input = URL(fileURLWithPath: args[2])
let output = URL(fileURLWithPath: args[3])

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read image: \(input.path)", 65)
}

if image.width * image.height > maxScanPixels {
    print(0)
    exit(0)
}

let band = max(16, image.height * 8 / 100)
guard band < image.height, let profile = bottomProfile(image, band: band) else {
    print(0)
    exit(0)
}

let rows = captionHeight(profile)
if rows == 0 {
    print(0)
    exit(0)
}

guard let trimmed = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height - rows)),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
    fail("cannot prepare output: \(output.path)", 73)
}
CGImageDestinationAddImage(destination, trimmed, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot write image: \(output.path)", 73)
}
print(rows)
