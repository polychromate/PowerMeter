import AppKit
import CoreGraphics
import Foundation

// 生成 App 图标：圆角渐变底 + 白色电池图形
let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))

// 背景透明
ctx.clear(rect)

// 圆角矩形（macOS 图标留白）
let inset: CGFloat = 82
let body = rect.insetBy(dx: inset, dy: inset)
let radius: CGFloat = 190
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()

// 渐变
let colors = [
    CGColor(red: 0.17, green: 0.47, blue: 0.96, alpha: 1.0),
    CGColor(red: 0.36, green: 0.28, blue: 0.92, alpha: 1.0)
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY),
                       options: [])

// 顶部高光
let highlight = CGGradient(colorsSpace: colorSpace,
                           colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
                                    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                           locations: [0, 1])!
ctx.drawLinearGradient(highlight,
                       start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.midY),
                       options: [])
ctx.restoreGState()

// 电池图形
let batteryWidth: CGFloat = 430
let batteryHeight: CGFloat = 210
let batteryRect = CGRect(x: (CGFloat(size) - batteryWidth) / 2 - 24,
                         y: (CGFloat(size) - batteryHeight) / 2,
                         width: batteryWidth, height: batteryHeight)
let batteryPath = CGPath(roundedRect: batteryRect, cornerWidth: 48, cornerHeight: 48, transform: nil)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.setLineWidth(26)
ctx.addPath(batteryPath)
ctx.strokePath()

// 电池正极
let capRect = CGRect(x: batteryRect.maxX + 12, y: batteryRect.midY - 44, width: 34, height: 88)
let capPath = CGPath(roundedRect: capRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.addPath(capPath)
ctx.fillPath()

// 电量填充 72%
let fillWidth = (batteryRect.width - 52) * 0.72
let fillRect = CGRect(x: batteryRect.minX + 26,
                      y: batteryRect.minY + 26,
                      width: fillWidth, height: batteryRect.height - 52)
let fillPath = CGPath(roundedRect: fillRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
ctx.addPath(fillPath)
ctx.fillPath()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try png.write(to: outDir.appendingPathComponent("icon_1024.png"))
print("wrote \(outDir.appendingPathComponent("icon_1024.png").path)")
