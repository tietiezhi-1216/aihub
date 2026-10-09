import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]

func render(_ pixels: Int, to url: URL) throws {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let scale = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let base = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 210, yRadius: 210)
    NSColor(deviceRed: 0.07, green: 0.085, blue: 0.095, alpha: 1).setFill()
    base.fill()
    NSColor(deviceRed: 0.53, green: 0.88, blue: 0.74, alpha: 0.14).setStroke()
    base.lineWidth = 6
    base.stroke()
    let heights: [CGFloat] = [94, 172, 298, 204, 424, 544, 346, 228, 392, 264, 150, 90]
    for (index, height) in heights.enumerated() {
        let x = 202 + CGFloat(index) * 53
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: (1024 - height) / 2, width: 27, height: height), xRadius: 13.5, yRadius: 13.5)
        NSColor(deviceRed: 0.53, green: 0.88, blue: 0.74, alpha: 1).setFill()
        bar.fill()
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AIHubIcon", code: 1)
    }
    try png.write(to: url)
}

for size in sizes {
    try render(size, to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2, to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
