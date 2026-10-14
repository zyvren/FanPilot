// Draws the FanPilot app icon at every size macOS wants and writes a .iconset folder.
//
//   swift scripts/make_icon.swift /path/to/AppIcon.iconset [assets/logo-FanPilot.png]
//   iconutil -c icns /path/to/AppIcon.iconset -o AppIcon.icns
//
// With a logo PNG (the app's artwork by zyvren), the logo's rounded-square body is cut out and
// re-masked to the standard macOS icon shape. Without one, a fallback icon is drawn: a blue-to-teal
// rounded square with the SF Symbol "fan.fill" in white.

import AppKit

guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("usage: make_icon.swift OUTPUT.iconset [LOGO.png]\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// The logo's opaque body, cropped, plus the colour used to back any translucent edge pixels.
struct Logo {
    let image: CGImage
    let backing: NSColor
}

/// Finds the logo's body: the rows and columns that are substantially opaque. The exported PNG has a
/// sparse, noisy halo around the square (left over from background removal); those stray pixels never
/// make up a meaningful share of a row or column, so a 10% threshold separates them from the body.
func loadLogo(_ path: String) -> Logo? {
    guard let source = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let width = source.width, height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Bitmap rows run top to bottom here, the same orientation CGImage.cropping(to:) uses.
    var rowCounts = [Int](repeating: 0, count: height), columnCounts = [Int](repeating: 0, count: width)
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 230 {
            rowCounts[y] += 1
            columnCounts[x] += 1
        }
    }
    func extent(_ counts: [Int]) -> ClosedRange<Int>? {
        let floor = Double(counts.max() ?? 0) * 0.1
        guard floor > 0, let first = counts.firstIndex(where: { Double($0) >= floor }),
              let last = counts.lastIndex(where: { Double($0) >= floor }) else { return nil }
        return first...last
    }
    guard let rows = extent(rowCounts), let columns = extent(columnCounts),
          let body = source.cropping(to: CGRect(x: columns.lowerBound, y: rows.lowerBound,
                                                width: columns.count, height: rows.count)) else { return nil }

    // Backing colour: the average of a band just inside the body's left and right edges.
    var sum = (r: 0.0, g: 0.0, b: 0.0), samples = 0.0
    let inset = max(4, columns.count / 40)
    for y in stride(from: rows.lowerBound + rows.count / 4, to: rows.upperBound - rows.count / 4, by: 4) {
        for x in [columns.lowerBound + inset, columns.upperBound - inset] {
            let i = (y * width + x) * 4
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.9 else { continue }
            sum.r += Double(pixels[i]) / 255 / a
            sum.g += Double(pixels[i + 1]) / 255 / a
            sum.b += Double(pixels[i + 2]) / 255 / a
            samples += 1
        }
    }
    let backing = samples > 0
        ? NSColor(deviceRed: sum.r / samples, green: sum.g / samples, blue: sum.b / samples, alpha: 1)
        : NSColor(deviceRed: 0.05, green: 0.25, blue: 0.85, alpha: 1)
    return Logo(image: body, backing: backing)
}

let logo: Logo? = CommandLine.arguments.count == 3 ? loadLogo(CommandLine.arguments[2]) : nil
if CommandLine.arguments.count == 3 && logo == nil {
    FileHandle.standardError.write(Data("could not read the logo at \(CommandLine.arguments[2])\n".utf8))
    exit(1)
}

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = CGFloat(pixels)
    // macOS icons leave a margin around the shape (about 10%) for the shadow.
    let shape = NSRect(x: canvas * 0.1, y: canvas * 0.1, width: canvas * 0.8, height: canvas * 0.8)
    let radius = shape.width * 0.2237
    let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = canvas * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    if let logo {
        // Fill the shape first so translucent edge pixels of the artwork sit on its own blue, then
        // draw the logo scaled to fill the shape (aspect-preserving; the slight excess is clipped).
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        logo.backing.setFill()
        path.fill()
        let scale = max(shape.width / CGFloat(logo.image.width), shape.height / CGFloat(logo.image.height))
        let drawn = NSSize(width: CGFloat(logo.image.width) * scale, height: CGFloat(logo.image.height) * scale)
        let target = NSRect(x: shape.midX - drawn.width / 2, y: shape.midY - drawn.height / 2,
                            width: drawn.width, height: drawn.height)
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(logo.image, in: target)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1),
                                       NSColor(calibratedRed: 0.05, green: 0.72, blue: 0.78, alpha: 1)])!
    gradient.draw(in: path, angle: -60)

    // Soft highlight on the upper half.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: shape.minX, y: shape.midY, width: shape.width, height: shape.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The fan symbol, white, centered.
    let pointSize = shape.width * 0.52
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = symbol.size
        let target = NSRect(x: shape.midX - size.width / 2, y: shape.midY - size.height / 2,
                            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        glow.shadowBlurRadius = canvas * 0.015
        glow.shadowOffset = NSSize(width: 0, height: -canvas * 0.008)
        glow.set()
        symbol.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

    return rep.representation(using: .png, properties: [:])
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
