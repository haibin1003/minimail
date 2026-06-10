#!/usr/bin/env swift

import Cocoa

// ====== 图标参数 ======
let iconSize: CGFloat = 1024
let outputPath = "./AppIcon.iconset"

// ====== 颜色 ======
// 中国移动主题蓝 + 渐变
let primaryBlue   = NSColor(red: 0.00, green: 0.42, blue: 0.78, alpha: 1.0)
let darkBlue      = NSColor(red: 0.00, green: 0.28, blue: 0.55, alpha: 1.0)
let accentBlue    = NSColor(red: 0.10, green: 0.58, blue: 0.95, alpha: 1.0)
let white         = NSColor.white
let lightGray     = NSColor(white: 0.95, alpha: 1.0)

func createIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)

    // 1. 背景圆角矩形
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: iconSize * 0.22, yRadius: iconSize * 0.22)
    let bgGradient = NSGradient(starting: darkBlue, ending: accentBlue)
    bgGradient?.draw(in: bgPath, angle: -45)
    bgPath.fill()

    // 2. 信封主体 — 白色半透明背景
    let envWidth: CGFloat = iconSize * 0.68
    let envHeight: CGFloat = iconSize * 0.52
    let envX = (iconSize - envWidth) / 2
    let envY = (iconSize - envHeight) / 2 + iconSize * 0.04

    let envRect = CGRect(x: envX, y: envY, width: envWidth, height: envHeight)

    // 信封白色背景
    let envPath = NSBezierPath(roundedRect: envRect, xRadius: iconSize * 0.04, yRadius: iconSize * 0.04)
    white.setFill()
    envPath.fill()

    // 3. 信封边框线（浅蓝灰）
    let borderColor = NSColor(white: 0.78, alpha: 1.0)
    borderColor.setStroke()
    envPath.lineWidth = 3
    envPath.stroke()

    // 4. 信封翻盖线（V 形）
    let flapPath = NSBezierPath()
    flapPath.move(to: NSPoint(x: envX, y: envY + envHeight))
    flapPath.line(to: NSPoint(x: envX + envWidth / 2, y: envY + envHeight * 0.60))
    flapPath.line(to: NSPoint(x: envX + envWidth, y: envY + envHeight))
    flapPath.lineWidth = 3
    accentBlue.withAlphaComponent(0.6).setStroke()
    flapPath.stroke()

    // 5. 信封上的 M 字母
    let textSize: CGFloat = iconSize * 0.36
    let font = NSFont.boldSystemFont(ofSize: textSize)
    let text = "M" as NSString
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: primaryBlue,
    ]
    let textSize2 = text.size(withAttributes: textAttrs)
    let textX = envX + (envWidth - textSize2.width) / 2
    let textY = envY + (envHeight - textSize2.height) / 2 - iconSize * 0.02
    text.draw(at: NSPoint(x: textX, y: textY), withAttributes: textAttrs)

    // 6. 外圈装饰光晕 - 右上小圆点
    let dotRadius: CGFloat = iconSize * 0.06
    let dotCenter = NSPoint(x: iconSize * 0.78, y: iconSize * 0.78)
    let dotPath = NSBezierPath()
    dotPath.appendArc(withCenter: dotCenter, radius: dotRadius, startAngle: 0, endAngle: 360)
    white.withAlphaComponent(0.3).setFill()
    dotPath.fill()

    // 7. 左下小圆点
    let dotCenter2 = NSPoint(x: iconSize * 0.22, y: iconSize * 0.22)
    let dotPath2 = NSBezierPath()
    dotPath2.appendArc(withCenter: dotCenter2, radius: dotRadius * 0.6, startAngle: 0, endAngle: 360)
    white.withAlphaComponent(0.2).setFill()
    dotPath2.fill()

    image.unlockFocus()
    return image
}

// ====== 保存多尺寸 PNG ======
let sizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let icon = createIcon()

// 创建 iconset 目录
try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

for (name, size) in sizes {
    let resize = NSImage(size: NSSize(width: size, height: size))
    resize.lockFocus()
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
              from: NSRect(x: 0, y: 0, width: iconSize, height: iconSize),
              operation: .copy, fraction: 1.0)
    resize.unlockFocus()

    guard let cgImage = resize.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("❌ 无法生成 \(name)")
        continue
    }

    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
        print("❌ 无法编码 \(name)")
        continue
    }

    let filePath = "\(outputPath)/\(name).png"
    try data.write(to: URL(fileURLWithPath: filePath))
    print("✅ 生成 \(name).png  (\(size)x\(size))")
}

print("🎉 所有尺寸 PNG 已生成到 \(outputPath)")
