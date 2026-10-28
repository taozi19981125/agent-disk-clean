// 生成 AppIcon.icns：swift scripts/make_icon.swift <输出目录>
// 把 Resources/logo.png 放进苹果标准的白色圆角方块里（1024 画布里 824 的方块，四周留边）
import AppKit
let out = CommandLine.arguments[1]
let logo = NSImage(contentsOfFile: "\(out)/logo.png")!
let set = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let r = NSRect(x: s * 100/1024, y: s * 100/1024, width: s * 824/1024, height: s * 824/1024)
    let path = NSBezierPath(roundedRect: r, xRadius: s * 185/1024, yRadius: s * 185/1024)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = s * 20/1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 8/1024)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // 原图自带白边，铺满方块再稍微放大一点，让字母更饱满
    let inset = -r.width * 0.04
    logo.draw(in: r.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.06).setStroke()
    path.lineWidth = max(s / 512, 0.5)
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "\(out)/AppIcon.icns"]; try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
