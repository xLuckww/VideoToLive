// 生成 VideoToLive 的 App 图标：Resources/AppIcon.icns 与 Resources/AppIcon.png（1024 母版）。
// 运行：swift Scripts/make-icon.swift
//
// 设计：浅雾蓝渐变的 macOS 圆角方形底，中间是 Live Photo 的同心圆
// （外圈虚点、内圈实线），圆心换成播放三角——「视频 → 实况」。
// 16/32px 用简化版：去掉虚点外圈、加粗线条，缩小后才不会糊。
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS 图标用的「连续圆角」近似：超椭圆 |x|^n + |y|^n = 1。
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func render(size: Int, simplified: Bool) -> CGImage {
    let s = CGFloat(size)
    let k = s / 1024  // 以 1024 画布为设计单位
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 图标主体：Apple 网格规定 1024 画布内主体约 824，四周留白放阴影
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = squircle(in: body)

    // 柔和投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: rgb(0x2A4A66, 0.22))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xE6EEF5))
    ctx.fillPath()
    ctx.restoreGState()

    // 底色：上浅下略深的雾蓝渐变
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [rgb(0xF7FAFD), rgb(0xD6E3EE)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    // 顶部一抹高光，让底板有一点点立体感
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.midY + 80 * k), options: [])
    ctx.restoreGState()

    // 细描边，浅色桌面上轮廓才清楚
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.7))
    ctx.setLineWidth(max(1, 3 * k))
    ctx.strokePath()

    let center = CGPoint(x: body.midX, y: body.midY)
    let accent = rgb(0x4F84B1)

    // 外圈：虚点环（简化版省略）
    if !simplified {
        let radius = 292 * k
        let dots = 44
        let dotRadius = 11 * k
        ctx.setFillColor(rgb(0x4F84B1, 0.55))
        for i in 0..<dots {
            let angle = CGFloat(i) / CGFloat(dots) * 2 * .pi
            let p = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            ctx.fillEllipse(in: CGRect(x: p.x - dotRadius, y: p.y - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2))
        }
    }

    // 内圈：实线环
    let ringRadius = (simplified ? 250 : 212) * k
    ctx.setStrokeColor(accent)
    ctx.setLineWidth((simplified ? 58 : 30) * k)
    ctx.strokeEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                 width: ringRadius * 2, height: ringRadius * 2))

    // 圆心：圆角播放三角。几何中心略向右偏，视觉上才居中
    let tri = (simplified ? 230 : 168) * k
    let optical = tri * 0.12
    let p1 = CGPoint(x: center.x - tri * 0.5 + optical, y: center.y + tri * 0.58)
    let p2 = CGPoint(x: center.x - tri * 0.5 + optical, y: center.y - tri * 0.58)
    let p3 = CGPoint(x: center.x + tri * 0.55 + optical, y: center.y)
    let triangle = CGMutablePath()
    let corner = tri * 0.14
    triangle.move(to: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2))
    triangle.addArc(tangent1End: p2, tangent2End: p3, radius: corner)
    triangle.addArc(tangent1End: p3, tangent2End: p1, radius: corner)
    triangle.addArc(tangent1End: p1, tangent2End: p2, radius: corner)
    triangle.closeSubpath()

    ctx.saveGState()
    ctx.addPath(triangle)
    ctx.clip()
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0x6A9CC7), rgb(0x3F72A0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: center.x, y: center.y + tri),
                           end: CGPoint(x: center.x, y: center.y - tri), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("写出失败：\(url.path)") }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil 要求的文件名与像素尺寸
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    writePNG(render(size: pixels, simplified: pixels <= 32),
             to: iconset.appendingPathComponent("\(name).png"))
}
writePNG(render(size: 1024, simplified: false), to: resources.appendingPathComponent("AppIcon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil 失败") }
print("已生成 Resources/AppIcon.icns 与 Resources/AppIcon.png")
