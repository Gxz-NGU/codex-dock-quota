import AppKit
import Foundation

@MainActor func renderGeminiQuota(percent: Int, directory: String) throws {
    guard (0...100).contains(percent) else { throw NSError(domain: "Quota", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效百分比：\(percent)"]) }
    let iconPath = "/Applications/Antigravity IDE.app/Contents/Resources/Antigravity IDE.icns"
    guard let original = NSImage(contentsOfFile: iconPath) else { throw NSError(domain: "Quota", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取 \(iconPath)"]) }
    for decorated in [false, true] {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus()
        original.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
        if decorated {
            NSColor.black.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 16, width: 460, height: 180), xRadius: 28, yRadius: 28).fill()
            let label = "\(percent)%" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 108), .foregroundColor: NSColor.white]
            label.draw(at: NSPoint(x: (512 - label.size(withAttributes: attributes).width) / 2, y: 65), withAttributes: attributes)
            NSColor.gray.setFill()
            NSBezierPath(roundedRect: NSRect(x: 54, y: 42, width: 404, height: 20), xRadius: 10, yRadius: 10).fill()
            if percent > 0 {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: 54, y: 42, width: 404 * Double(percent) / 100, height: 20), xRadius: 10, yRadius: 10).fill()
            }
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Quota", code: 3, userInfo: [NSLocalizedDescriptionKey: "图标渲染失败"])
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(decorated ? "quota.png" : "original.png"), options: .atomic)
    }
}
