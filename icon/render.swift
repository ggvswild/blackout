import AppKit

// 浅色底上的黑圆。一只圆眼睛带着瞳孔，另一只眨成一条，下面一抹歪笑。
// 很小的尺寸只留眨眼，省掉瞳孔和笑容，否则会糊成一团。

private let design: CGFloat = 1024

private func drawIcon(into ctx: CGContext, bufferSide: Int, outputSide: Int) {
    let scale = CGFloat(bufferSide) / design
    let canvas = CGFloat(bufferSide)
    ctx.setFillColor(NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    let ink = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1)
    let diameter = canvas * 0.70
    let origin = (canvas - diameter) / 2
    ctx.setFillColor(ink.cgColor)
    ctx.fillEllipse(in: CGRect(x: origin, y: origin, width: diameter, height: diameter))

    func capsule(cx: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat, degrees: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: cx * scale, y: cy * scale)
        ctx.rotate(by: degrees * .pi / 180)
        let w = width * scale
        let h = height * scale
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let radius = min(w, h) / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    func smile(cx: CGFloat, cy: CGFloat, width: CGFloat, drop: CGFloat, lift: CGFloat, thickness: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: cx * scale, y: cy * scale)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(thickness * scale)
        ctx.setLineCap(.round)
        let w = width * scale
        ctx.move(to: CGPoint(x: -w / 2, y: 0))
        ctx.addQuadCurve(
            to: CGPoint(x: w / 2, y: lift * scale),
            control: CGPoint(x: w * 0.08, y: -drop * scale)
        )
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 坐标是 1024 画布、左下角为原点。小尺寸只留睁眼和眨眼。
    if outputSide < 128 {
        capsule(cx: 445, cy: 575, width: 168, height: 188, degrees: -6, color: .white)
        capsule(cx: 670, cy: 655, width: 196, height: 70, degrees: 4, color: .white)
    } else {
        capsule(cx: 455, cy: 585, width: 150, height: 162, degrees: -8, color: .white)
        capsule(cx: 492, cy: 562, width: 48, height: 54, degrees: -8, color: ink)
        capsule(cx: 660, cy: 655, width: 148, height: 46, degrees: 7, color: .white)
        smile(cx: 545, cy: 455, width: 168, drop: 72, lift: 22, thickness: 26)
    }
}

private func renderImage(outputSide: Int) -> CGImage {
    let bufferSide = outputSide < 256 ? outputSide * 4 : outputSide
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: bufferSide,
        height: bufferSide,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("无法创建画布\n", stderr)
        exit(1)
    }
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, bufferSide: bufferSide, outputSide: outputSide)
    guard let full = ctx.makeImage() else {
        fputs("无法导出图像\n", stderr)
        exit(1)
    }
    if bufferSide == outputSide { return full }

    guard let small = CGContext(
        data: nil,
        width: outputSide,
        height: outputSide,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("无法创建缩小画布\n", stderr)
        exit(1)
    }
    small.interpolationQuality = .high
    small.draw(full, in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
    guard let image = small.makeImage() else {
        fputs("无法缩小图像\n", stderr)
        exit(1)
    }
    return image
}

private func pngData(_ image: CGImage) -> Data {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("无法编码 PNG\n", stderr)
        exit(1)
    }
    return data
}

private func writePNG(_ image: CGImage, to url: URL) {
    try! pngData(image).write(to: url)
}

guard CommandLine.arguments.count > 1 else {
    fputs("用法: render <输出目录>\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

let master = renderImage(outputSide: 1024)
writePNG(master, to: root.appendingPathComponent("blackout-icon.png"))

let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for side in [16, 32, 128, 256, 512] {
    writePNG(renderImage(outputSide: side), to: iconset.appendingPathComponent("icon_\(side)x\(side).png"))
    writePNG(renderImage(outputSide: side * 2), to: iconset.appendingPathComponent("icon_\(side)x\(side)@2x.png"))
}

// 一排放大后的小尺寸，用来看眼睛在 16/32/64 上还在不在。
let samples = [16, 32, 64, 128].map { renderImage(outputSide: $0) }
let cell = 160
let gap = 24
let sheetW = gap + samples.count * (cell + gap)
let sheetH = gap + cell + gap
let sheetSpace = CGColorSpaceCreateDeviceRGB()
guard let sheet = CGContext(
    data: nil,
    width: sheetW,
    height: sheetH,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: sheetSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("无法创建预览\n", stderr)
    exit(1)
}
sheet.setFillColor(NSColor(srgbRed: 0.75, green: 0.75, blue: 0.77, alpha: 1).cgColor)
sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
sheet.interpolationQuality = .none
for (index, image) in samples.enumerated() {
    let x = gap + index * (cell + gap)
    sheet.draw(image, in: CGRect(x: x, y: gap, width: cell, height: cell))
}
writePNG(sheet.makeImage()!, to: root.appendingPathComponent("preview-small.png"))
print(root.path)
