// Code-drawn Finder background and small document icons. No app bundle changes.
import AppKit
import UniformTypeIdentifiers

let stage = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artwork = stage.appendingPathComponent(".artwork", isDirectory: true)
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func label(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (text as NSString).draw(in: NSRect(x: 24, y: 580 - top - 34, width: 712, height: 34), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink, .paragraphStyle: style
    ])
}
for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 760 * scale, pixelsHigh: 580 * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 760, height: 580)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [color(0xFFF2F7), color(0xFBFCFF), color(0xEAF3FF)])!
        .draw(in: NSRect(x: 0, y: 0, width: 760, height: 580), angle: 15)
    label("欢迎使用 LiveCopilot", top: 35, size: 25, weight: .semibold, ink: color(0x25272D))
    label("将右侧的 LiveCopilot 拖到左侧 Applications 中安装", top: 76, size: 14, weight: .regular, ink: color(0x646975))
    // A leftward arrow follows the exact app → destination direction.
    color(0x7796C4).setStroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 429, y: 375)); arrow.line(to: NSPoint(x: 331, y: 375))
    arrow.move(to: NSPoint(x: 347, y: 390)); arrow.line(to: NSPoint(x: 331, y: 375)); arrow.line(to: NSPoint(x: 347, y: 360))
    arrow.stroke()
    label("拖动安装 · Drag to install", top: 230, size: 12, weight: .medium, ink: color(0x717C8D))
    color(0xDFE4EC).setStroke()
    let divider = NSBezierPath(); divider.lineWidth = 1
    divider.move(to: NSPoint(x: 78, y: 243)); divider.line(to: NSPoint(x: 682, y: 243)); divider.stroke()
    label("安装后，请从 Applications 打开 LiveCopilot", top: 295, size: 12, weight: .regular, ink: color(0x646975))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: artwork.appendingPathComponent(name))
}

// Finder has one icon size per folder. Transparent padding keeps supplementary
// documents visually small while retaining native selectable file icons/labels.
for name in ["Install - 安装说明.txt", "LICENSE.txt", "ReleaseInfo.txt"] {
    let path = stage.appendingPathComponent(name).path
    let document = NSWorkspace.shared.icon(for: .plainText)
    let icon = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
        document.draw(in: NSRect(x: 46, y: 0, width: 36, height: 36), from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    guard NSWorkspace.shared.setIcon(icon, forFile: path, options: []) else {
        fatalError("Could not set supplemental document icon: \(name)")
    }
}
