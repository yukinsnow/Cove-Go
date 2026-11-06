// User-approved ocean terminal artwork. Produces opaque iOS icon renditions.
import AppKit
import Foundation
import ImageIO

let folder = CommandLine.arguments[1]
let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("assets/ocean-terminal-master.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Missing ocean terminal icon master")
}
precondition(artwork.width == artwork.height && artwork.width >= 1024,
    "Icon master must be square and at least 1024px")
let manifest = URL(fileURLWithPath: folder).appendingPathComponent("Contents.json")
var contents = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
var entries = contents["images"] as! [[String: Any]]
for i in entries.indices {
    let scaleText = entries[i]["scale"] as? String ?? "1x"
    guard let sizeText = entries[i]["size"] as? String,
          let size = Double(sizeText.components(separatedBy: "x")[0]),
          let scale = Double(scaleText.replacingOccurrences(of: "x", with: "")) else { continue }
    let pixels = Int(size * scale)
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    // Full-bleed square master; iOS supplies the outer corner mask.
    ctx.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    precondition(bitmap.colorAt(x: 0, y: 0) != bitmap.colorAt(x: pixels / 2, y: pixels / 2),
        "App icon must not be blank")
    let name = "ocean-terminal-\(pixels)-\(i).png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    entries[i]["filename"] = name
}
contents["images"] = entries
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
