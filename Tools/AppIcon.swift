import AppKit
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(red: 0.12, green: 0.21, blue: 0.33, alpha: 1), ending: NSColor(red: 0.04, green: 0.09, blue: 0.15, alpha: 1))!.draw(in: background, angle: 80)
    for (x, color) in [(CGFloat(320), NSColor(red: 0.44, green: 0.85, blue: 0.79, alpha: 1)), (CGFloat(704), NSColor(red: 1, green: 0.72, blue: 0.43, alpha: 1))] {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 102, y: 560, width: 204, height: 204)).fill()
        NSBezierPath(roundedRect: NSRect(x: x - 148, y: 250, width: 296, height: 256), xRadius: 115, yRadius: 115).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let bases = [16, 32, 128, 256, 512]
    if bases.contains(size) { try png.write(to: target.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 && bases.contains(size/2) { try png.write(to: target.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
