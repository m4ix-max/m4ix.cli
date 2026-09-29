import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift generate-icon.swift output.png\n", stderr)
    exit(2)
}

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create icon context\n", stderr)
    exit(1)
}

// NoA 2.0 Elevate: a single ink field, a paper prompt, and one signal cursor.
// The outer radius follows the macOS app-icon silhouette; the artwork is flat.
func color(_ hex: UInt32) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255
    let green = CGFloat((hex >> 8) & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    return CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
}

let ink = color(0x141414)
let paper = color(0xebeaea)
let signal = color(0xe8fa51)

let plate = CGRect(x: 64, y: 64, width: 896, height: 896)
context.addPath(CGPath(roundedRect: plate, cornerWidth: 184, cornerHeight: 184, transform: nil))
context.setFillColor(ink)
context.fillPath()

// A single strong terminal prompt stays legible even at 16 px.
context.move(to: CGPoint(x: 250, y: 664))
context.addLine(to: CGPoint(x: 462, y: 512))
context.addLine(to: CGPoint(x: 250, y: 360))
context.setLineWidth(100)
context.setLineCap(.butt)
context.setLineJoin(.miter)
context.setMiterLimit(4)
context.setStrokeColor(paper)
context.strokePath()

context.setFillColor(signal)
context.fill(CGRect(x: 555, y: 319, width: 215, height: 76))

guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
