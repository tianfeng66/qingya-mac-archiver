// 生成 App 图标，直接拼 .icns（不依赖 iconutil）
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = size
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.36, blue: 0.93, alpha: 1)
    ])!.draw(in: body, angle: -90)

    // 顶部高光
    NSGraphicsContext.current?.saveGraphicsState()
    let gloss = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
                             xRadius: s * 0.225, yRadius: s * 0.225)
    gloss.setClip()
    NSColor.white.withAlphaComponent(0.14).setFill()
    gloss.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // 盒子：白色圆角矩形 + 盒盖
    let boxW = s * 0.52, boxH = s * 0.40
    let cx = s / 2
    let boxRect = NSRect(x: cx - boxW / 2, y: s * 0.22, width: boxW, height: boxH)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: boxRect, xRadius: s * 0.045, yRadius: s * 0.045).fill()
    let lidRect = NSRect(x: cx - boxW * 0.56, y: boxRect.maxY - s * 0.005, width: boxW * 1.12, height: s * 0.11)
    NSBezierPath(roundedRect: lidRect, xRadius: s * 0.035, yRadius: s * 0.035).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // 拉链：中间一列交错的齿
    let zipColor = NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.92, alpha: 1)
    zipColor.setFill()
    let toothW = s * 0.05, toothH = s * 0.026
    var y = lidRect.maxY - toothH * 1.6
    var left = true
    while y > boxRect.minY + s * 0.13 {
        let x = left ? cx - toothW : cx
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: toothW, height: toothH),
                     xRadius: toothH * 0.35, yRadius: toothH * 0.35).fill()
        y -= toothH * 1.25
        left.toggle()
    }

    // 拉头
    let pullW = s * 0.085, pullH = s * 0.12
    let pull = NSBezierPath(roundedRect: NSRect(x: cx - pullW / 2, y: boxRect.minY + s * 0.035, width: pullW, height: pullH),
                            xRadius: pullW * 0.45, yRadius: pullW * 0.45)
    pull.fill()
    NSColor.white.setFill()
    let hole = s * 0.03
    NSBezierPath(ovalIn: NSRect(x: cx - hole / 2, y: boxRect.minY + s * 0.055, width: hole, height: hole)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(size: CGFloat) -> Data {
    let rep = drawIcon(size: size)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

/// .icns：magic + 总长度 + 若干 (类型, 长度, PNG 数据) 块。
func makeICNS() -> Data {
    let chunks: [(String, CGFloat)] = [
        ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
        ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
        ("ic09", 512), ("ic10", 1024)
    ]
    var cache: [CGFloat: Data] = [:]
    var body = Data()
    for (type, size) in chunks {
        let payload = cache[size] ?? png(size: size)
        cache[size] = payload
        guard !payload.isEmpty else { continue }
        body.append(contentsOf: Array(type.utf8))
        var length = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(payload)
    }
    var out = Data("icns".utf8)
    var total = UInt32(body.count + 8).bigEndian
    withUnsafeBytes(of: &total) { out.append(contentsOf: $0) }
    out.append(body)
    return out
}

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "./AppIcon.icns"
try makeICNS().write(to: URL(fileURLWithPath: outPath))
if args.count > 2 { try png(size: 512).write(to: URL(fileURLWithPath: args[2])) }
print("icon written to \(outPath)")
