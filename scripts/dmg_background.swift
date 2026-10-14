// Renders the DMG window background: the artwork scaled to the window, plus an arrow from the app
// icon to the Applications shortcut so it is obvious the app should be dragged there.
//
//   swift scripts/dmg_background.swift SOURCE.png OUTPUT.png WIDTH_PT HEIGHT_PT SCALE FROM_X TO_X Y
//
// Coordinates are in window points with a top-left origin (the same space Finder uses for icon
// positions); SCALE is 1 for the standard image and 2 for the Retina one.

import AppKit

let args = CommandLine.arguments
guard args.count == 9,
      let widthPt = Double(args[3]), let heightPt = Double(args[4]), let scale = Double(args[5]),
      let fromX = Double(args[6]), let toX = Double(args[7]), let arrowY = Double(args[8]),
      let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: dmg_background.swift SOURCE OUTPUT WIDTH HEIGHT SCALE FROM_X TO_X Y\n".utf8))
    exit(2)
}

let pixelsWide = Int(widthPt * scale), pixelsHigh = Int(heightPt * scale)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
source.draw(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))

// Points with a top-left origin -> bitmap pixels with a bottom-left origin.
func point(_ x: Double, _ y: Double) -> NSPoint {
    NSPoint(x: x * scale, y: (heightPt - y) * scale)
}

// A gently arched arrow: it reads as "move this over there" better than a flat line.
let start = point(fromX, arrowY)
let end = point(toX, arrowY)
let control = point((fromX + toX) / 2, arrowY - 26)
let shaft = NSBezierPath()
shaft.move(to: start)
shaft.curve(to: end, controlPoint1: control, controlPoint2: control)
shaft.lineWidth = 5 * scale
shaft.lineCapStyle = .round

// Arrowhead aligned with the curve's direction at its end (from the control point to the tip).
let angle = atan2(end.y - control.y, end.x - control.x)
let headLength = 18 * scale, spread = 0.5
let head = NSBezierPath()
head.move(to: NSPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread)))
head.line(to: end)
head.line(to: NSPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread)))
head.lineWidth = 5 * scale
head.lineCapStyle = .round
head.lineJoinStyle = .round

// Soft white glow under a crisp white stroke, so it stays visible on every shade of the blue.
let glow = NSShadow()
glow.shadowColor = NSColor(calibratedRed: 0.55, green: 0.85, blue: 1, alpha: 0.9)
glow.shadowBlurRadius = 10 * scale
glow.shadowOffset = .zero
glow.set()
NSColor.white.withAlphaComponent(0.95).setStroke()
shaft.stroke()
head.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
