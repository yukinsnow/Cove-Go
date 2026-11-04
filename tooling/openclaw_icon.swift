// Original geometric network icon for this fork (AGPL-3.0).
import AppKit
import Foundation
let folder = CommandLine.arguments[1]
let manifest = URL(fileURLWithPath: folder).appendingPathComponent("Contents.json")
var contents = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
var entries = contents["images"] as! [[String: Any]]
for i in entries.indices {
    let scaleText = entries[i]["scale"] as? String ?? "1x"
    guard let sizeText = entries[i]["size"] as? String,
          let size = Double(sizeText.components(separatedBy: "x")[0]),
          let scale = Double(scaleText.replacingOccurrences(of: "x", with: "")) else { continue }
    let pixels = Int(size * scale)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let t = NSAffineTransform()
    t.scale(by: CGFloat(pixels) / 1024)
    t.concat()
    NSColor(red: 0.06, green: 0.10, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    let points = [NSPoint(x: 270, y: 300), NSPoint(x: 754, y: 300), NSPoint(x: 512, y: 740)]
    NSColor(red: 0.48, green: 0.77, blue: 0.95, alpha: 1).setStroke()
    let lines = NSBezierPath(); lines.lineWidth = 48
    for p in points { lines.move(to: NSPoint(x: 512, y: 460)); lines.line(to: p) }
    lines.stroke()
    NSColor.white.setFill()
    for p in points { NSBezierPath(ovalIn: NSRect(x: p.x-80, y: p.y-80, width: 160, height: 160)).fill() }
    NSColor(red: 1, green: 0.48, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 400, y: 348, width: 224, height: 224)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let name = "openclaw-\(pixels)-\(i).png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    entries[i]["filename"] = name
}
contents["images"] = entries
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
