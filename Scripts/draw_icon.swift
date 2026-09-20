import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
let colors: [NSColor] = [.systemCyan, .systemGreen, .systemPurple]
for i in 0..<150 {
    let fraction = Double(i) / 149
    let segment = min(1, Int(fraction * 2))
    colors[segment].blended(withFraction: fraction * 2 - Double(segment), of: colors[segment + 1])!.setStroke()
    let path = NSBezierPath(); path.lineWidth = 42; path.lineCapStyle = .round
    path.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 340, startAngle: 38 + fraction * 274, endAngle: 38 + fraction * 274 + 2.2)
    path.stroke()
}
let text = "C" as NSString
let attributes: [NSAttributedString.Key: Any] = [.font:NSFont.systemFont(ofSize: 510, weight: .bold), .foregroundColor:NSColor(calibratedWhite: 0.08, alpha: 1)]
let textSize = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x:(1024-textSize.width)/2, y:(1024-textSize.height)/2 + 15), withAttributes:attributes)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:"App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
