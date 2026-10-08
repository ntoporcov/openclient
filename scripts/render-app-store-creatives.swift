#!/usr/bin/env swift
import AppKit

// Dedicated ASC creative placements; run from any directory with `swift <script>`.
// Real app captures are scaled intact. Output is opaque sRGB PNG.
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("fastlane/creatives")
let captures = root.appendingPathComponent("fastlane/screenshots/en_US")
let blue = NSColor(srgbRed: 0.48, green: 0.78, blue: 1, alpha: 1)

func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: height - y - h, width: w, height: h)
}

func label(_ value: String, _ frame: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let text = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
    let bounds = text.boundingRect(with: NSSize(width: frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    precondition(bounds.height <= frame.height, "Text overflow: \(value)")
    text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func screen(_ name: String, x: CGFloat, top: CGFloat, height: CGFloat, angle: CGFloat, canvasHeight: CGFloat) {
    let url = captures.appendingPathComponent("iPhone-18-Pro-Max-gallery-\(name).png")
    guard let image = NSImage(contentsOf: url) else { fatalError("Missing capture: \(url.path)") }
    let width = height * image.size.width / image.size.height
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = AffineTransform(translationByX: x + width / 2, byY: canvasHeight - top - height / 2)
    (transform as NSAffineTransform).concat()
    let rotation = NSAffineTransform()
    rotation.rotate(byDegrees: angle)
    rotation.concat()
    let frame = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.65)
    shadow.shadowBlurRadius = 75
    shadow.shadowOffset = NSSize(width: 0, height: -35)
    shadow.set()
    NSColor(white: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: frame.insetBy(dx: -13, dy: -13), xRadius: 78, yRadius: 78).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: 66, yRadius: 66).addClip()
    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
}

let copy: [(String, String, String)] = [
    ("en-US", "Your OpenCode.\nAnywhere.", "Your server. Your projects.\nNative on iPhone and iPad."),
    ("pt-BR", "Seu OpenCode.\nOnde estiver.", "Seu servidor. Seus projetos.\nNativo no iPhone e iPad."),
    ("it", "Il tuo OpenCode.\nOvunque.", "Il tuo server. I tuoi progetti.\nNativo su iPhone e iPad.")
]

for (locale, headline, subtitle) in copy {
    let directory = output.appendingPathComponent(locale)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for header in [true, false] {
        let width = 3840
        let height = header ? 1646 : 2560
        let h = CGFloat(height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("No canvas") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGradient(starting: NSColor(srgbRed: 0.025, green: 0.045, blue: 0.085, alpha: 1),
                   ending: NSColor(srgbRed: 0.105, green: 0.07, blue: 0.19, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -30)
        // Quiet orbital lines tie the composition to the existing gallery.
        for radius in [CGFloat(1100), 1420, 1770] {
            blue.withAlphaComponent(0.12).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: 2750 - radius, y: h / 2 - radius, width: radius * 2, height: radius * 2))
            path.lineWidth = 3
            path.stroke()
        }
        if header {
            screen("06-sessions", x: 1950, top: 200, height: 1320, angle: -8, canvasHeight: h)
            screen("04-grouping", x: 1240, top: 120, height: 1410, angle: 5, canvasHeight: h)
        } else {
            let top: CGFloat = 610
            label("OpenClient", box(250, top, 1650, 130, h), size: 90, weight: .semibold, color: blue)
            label(headline, box(240, top + 210, 1730, 580, h), size: locale == "it" ? 195 : 215, weight: .bold, color: .white)
            label(subtitle, box(250, top + 790, 1600, 230, h), size: 66, weight: .regular, color: NSColor(white: 0.74, alpha: 1))
            screen("06-sessions", x: 2770, top: 570, height: 1700, angle: -7, canvasHeight: h)
            screen("04-grouping", x: 1960, top: 280, height: 1940, angle: 5, canvasHeight: h)
        }
        guard let image = context.makeImage() else { fatalError("No image") }
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = bitmap.representation(using: .png, properties: [:])!
        let check = NSBitmapImageRep(data: data)!
        precondition(!check.hasAlpha && check.pixelsWide == width && check.pixelsHigh == height)
        let name = header ? "header-3840x1646.png" : "search-results-3840x2560.png"
        try data.write(to: directory.appendingPathComponent(name))
        print("Created \(locale)/\(name)")
    }
}
