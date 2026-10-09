import AppKit
import CoreText

// 安装盘窗口的底图。图标由访达摆在上面，这里只画标题和中间的箭头。
// 画布按 2x 出图，再标成 144 dpi，窗口用点尺寸时才清晰。

let width = 1360
let height = 840

guard CommandLine.arguments.count > 1 else {
    fputs("用法: render-background <png>\n", stderr)
    exit(2)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("无法创建画布\n", stderr)
    exit(1)
}

ctx.setFillColor(NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

func drawCentered(_ text: String, baseline: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    ctx.textPosition = CGPoint(x: (CGFloat(width) - textWidth) / 2, y: baseline)
    CTLineDraw(line, ctx)
}

drawCentered(
    "安装 Blackout",
    baseline: 700,
    size: 52,
    weight: .semibold,
    color: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
)
drawCentered(
    "把左侧图标拖到右侧的「应用程序」文件夹",
    baseline: 630,
    size: 26,
    weight: .regular,
    color: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
)

// 箭头落在两枚图标中间。图标中心大约在 x = 350 和 x = 1010。
let arrowColor = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1).cgColor
ctx.setStrokeColor(arrowColor)
ctx.setFillColor(arrowColor)
ctx.setLineWidth(8)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 470, y: 360))
ctx.addLine(to: CGPoint(x: 760, y: 360))
ctx.strokePath()
ctx.beginPath()
ctx.move(to: CGPoint(x: 730, y: 400))
ctx.addLine(to: CGPoint(x: 800, y: 360))
ctx.addLine(to: CGPoint(x: 730, y: 320))
ctx.closePath()
ctx.fillPath()

guard let image = ctx.makeImage() else {
    fputs("无法导出图像\n", stderr)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("无法编码 PNG\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try! data.write(to: url)
print(url.path)
