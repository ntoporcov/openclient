#!/usr/bin/env swift
import AppKit

// Run from the repository root after GalleryScreenshotUITests.
// Artwork uses real simulator captures without repainting the app UI.
struct Slide {
    let id: String
    let feature: String
    let headline: String
    let subtitle: String
    let accent: NSColor
    var draftSource: String? = nil
}

let slides = [
    Slide(id: "01-overview", feature: "OPENCLIENT", headline: "Your OpenCode.\nAnywhere.",
          subtitle: "OpenCode V1 + V2, native on iPhone and iPad.\nYour projects and conversations, wherever you are.", accent: .init(srgbRed: 0.50, green: 0.79, blue: 1, alpha: 1)),
    Slide(id: "02-delivery", feature: "QUEUE + STEER", headline: "Next step.\nNew direction.",
          subtitle: "Queue what comes next. Steer what’s happening now.\nHold Send to choose your move.", accent: .init(srgbRed: 0.74, green: 0.64, blue: 1, alpha: 1)),
    Slide(id: "03-side-question", feature: "SIDE QUESTIONS", headline: "Ask on\nthe side.",
          subtitle: "Get a quick answer without adding to the chat\nor interrupting the work.", accent: .init(srgbRed: 0.48, green: 0.89, blue: 0.79, alpha: 1)),
    Slide(id: "04-grouping", feature: "OPTIONAL ACTIVITY GROUPS", headline: "Less noise.\nMore focus.",
          subtitle: "Bring tools, reasoning, and context together.\nExpand the details whenever you need them.", accent: .init(srgbRed: 1, green: 0.73, blue: 0.48, alpha: 1)),
    Slide(id: "05-customization", feature: "CHAT CUSTOMIZATION", headline: "Your chat.\nYour style.",
          subtitle: "Choose your accent, bubble style, and level of detail.\nMake OpenClient feel like you.", accent: .init(srgbRed: 0.93, green: 0.61, blue: 0.84, alpha: 1)),
    Slide(id: "06-sessions", feature: "PROJECT CONVERSATIONS", headline: "Pick up where\nyou left off.",
          subtitle: "Keep conversations organized by project.\nPin the work you want close at hand.", accent: .init(srgbRed: 0.50, green: 0.79, blue: 1, alpha: 1), draftSource: "07-sessions"),
    Slide(id: "07-models", feature: "MODELS + AGENTS", headline: "Start with\nyour setup.",
          subtitle: "Choose your project, agent, model, and reasoning.\nThen turn your next idea into a conversation.", accent: .init(srgbRed: 0.74, green: 0.64, blue: 1, alpha: 1), draftSource: "05-new-session"),
    Slide(id: "08-permissions", feature: "IN-CHAT APPROVALS", headline: "The next move\nis yours.",
          subtitle: "Review permission requests right in the chat.\nApprove once, allow always, or say no.", accent: .init(srgbRed: 1, green: 0.73, blue: 0.48, alpha: 1), draftSource: "09-permission"),
    Slide(id: "09-questions", feature: "KEEP THE WORK MOVING", headline: "A quick choice.\nA clear path.",
          subtitle: "Answer your assistant’s questions in place.\nGive the work the direction it needs.", accent: .init(srgbRed: 0.48, green: 0.89, blue: 0.79, alpha: 1), draftSource: "10-question"),
    Slide(id: "10-widgets", feature: "HOME SCREEN WIDGETS", headline: "Your work.\nAt a glance.",
          subtitle: "See recent sessions and what needs your attention.\nKeep your projects within easy reach.", accent: .init(srgbRed: 0.93, green: 0.61, blue: 0.84, alpha: 1), draftSource: "16-recent-widget"),
]

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("fastlane/screenshots/en_US")
let output = root.appendingPathComponent("fastlane/gallery/en-US")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func canvas(_ size: NSSize, draw: () throws -> Void) throws -> NSBitmapImageRep {
    // Quartz requires a supported drawing format. A 24-bit RGB NSBitmapImageRep
    // can encode a PNG but cannot create the AppKit drawing context, yielding black.
    // RGBX is a supported opaque 32-bit canvas; the unused byte is not alpha.
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("Could not create gallery drawing context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    try draw()
    guard let image = context.makeImage() else { fatalError("Could not capture gallery canvas") }
    return NSBitmapImageRep(cgImage: image)
}

func validatedPNG(_ rep: NSBitmapImageRep) -> Data {
    guard let data = rep.representation(using: .png, properties: [:]),
          let decoded = NSBitmapImageRep(data: data) else { fatalError("Could not encode gallery PNG") }
    precondition(!decoded.hasAlpha, "Gallery PNG must be opaque")
    precondition(decoded.pixelsWide == rep.pixelsWide && decoded.pixelsHigh == rep.pixelsHigh,
                 "Gallery PNG dimensions changed during encoding")
    // Check the encoded artifact, not just the drawing commands or image headers.
    // A dark gallery still has bright headline/UI pixels and a varied palette.
    var colors = Set<Int>()
    var brightest: CGFloat = 0
    for y in stride(from: 0, to: decoded.pixelsHigh, by: max(1, decoded.pixelsHigh / 100)) {
        for x in stride(from: 0, to: decoded.pixelsWide, by: max(1, decoded.pixelsWide / 100)) {
            guard let color = decoded.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            brightest = max(brightest, max(r, max(g, b)))
            colors.insert((Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255))
        }
    }
    precondition(colors.count > 32 && brightest > 0.7, "Blank or invalid gallery PNG; refusing to upload")
    return data
}

func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat, in size: NSSize) -> NSRect {
    NSRect(x: x, y: size.height - top - height, width: width, height: height)
}

func text(_ value: String, frame: NSRect, font: NSFont, color: NSColor, spacing: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = spacing
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    let string = NSAttributedString(string: value, attributes: attributes)
    let needed = string.boundingRect(with: NSSize(width: frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    precondition(needed.height <= frame.height + 2, "Text overflow: \(value)")
    string.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func render(_ slide: Slide, ipad: Bool) throws -> URL {
    let size = ipad ? NSSize(width: 2064, height: 2752) : NSSize(width: 1320, height: 2868)
    let prefix = ipad ? "iPad-Pro-13-inch-(M5)" : "iPhone-18-Pro-Max"
    var source = sources.appendingPathComponent("\(prefix)-gallery-\(slide.id).png")
    if !FileManager.default.fileExists(atPath: source.path),
       CommandLine.arguments.contains("--existing-captures"), let fallback = slide.draftSource {
        source = sources.appendingPathComponent("\(prefix)-\(fallback).png")
        print("Draft source: \(source.lastPathComponent)")
    }
    guard let screenshot = NSImage(contentsOf: source) else { fatalError("Missing capture: \(source.path)") }
    let rep = try canvas(size) {
        NSGradient(starting: NSColor(srgbRed: 0.045, green: 0.055, blue: 0.085, alpha: 1),
                   ending: NSColor(srgbRed: 0.095, green: 0.085, blue: 0.15, alpha: 1))!.draw(in: NSRect(origin: .zero, size: size), angle: -70)
        slide.accent.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: rect(size.width * 0.25, size.height * 0.38, size.width * 1.4, size.width * 1.4, in: size)).fill()
        slide.accent.withAlphaComponent(0.16).setStroke()
        let arc = NSBezierPath(ovalIn: rect(-size.width * 0.7, -size.width * 0.65, size.width * 1.3, size.width * 1.3, in: size))
        arc.lineWidth = 2
        arc.stroke()

        let left: CGFloat = ipad ? 100 : 92
        text(slide.feature, frame: rect(left, ipad ? 130 : 110, ipad ? 1100 : 1140, 60, in: size),
             font: .systemFont(ofSize: ipad ? 34 : 30, weight: .bold), color: slide.accent)
        text(slide.headline, frame: rect(left, 200, ipad ? 1800 : 1140, 290, in: size),
             font: .systemFont(ofSize: 116, weight: .bold), color: .init(white: 0.97, alpha: 1), spacing: 0)
        text(slide.subtitle,
             frame: rect(left, 520, ipad ? 1800 : 1140, 170, in: size),
             font: .systemFont(ofSize: ipad ? 43 : 40, weight: .regular), color: .init(white: 0.75, alpha: 1), spacing: 8)

        let width: CGFloat = ipad && screenshot.size.width > screenshot.size.height ? 1840 : (ipad ? 1420 : 920)
        let imageHeight = width * screenshot.size.height / screenshot.size.width
        let imageRect = rect((size.width - width) / 2, 750, width, imageHeight, in: size)
        let border = imageRect.insetBy(dx: -12, dy: -12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 48
        shadow.shadowOffset = NSSize(width: 0, height: -22)
        shadow.set()
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: border, xRadius: ipad ? 44 : 68, yRadius: ipad ? 44 : 68).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: ipad ? 32 : 56, yRadius: ipad ? 32 : 56).addClip()
        screenshot.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        text("OpenClient", frame: rect(left, size.height - 74, 500, 40, in: size), font: .systemFont(ofSize: 26, weight: .medium), color: .init(white: 0.65, alpha: 1))
    }
    let url = output.appendingPathComponent("\(ipad ? "iPad" : "iPhone")-\(slide.id).png")
    try validatedPNG(rep).write(to: url)
    return url
}

func renderDuo(_ slide: Slide) throws {
    let source = sources.appendingPathComponent("iPhone-Duo-gallery-\(slide.id).png")
    guard let screenshot = NSImage(contentsOf: source),
          let sourceBitmap = NSBitmapImageRep(data: try Data(contentsOf: source)) else { fatalError("Missing Duo capture: \(source.path)") }
    let size = NSSize(width: sourceBitmap.pixelsWide, height: sourceBitmap.pixelsHigh)
    precondition([NSSize(width: 1398, height: 2034), NSSize(width: 2007, height: 2853)].contains(size), "Unexpected Duo portrait dimensions: \(size)")
    let rep = try canvas(size) {
        NSGradient(starting: NSColor(srgbRed: 0.045, green: 0.055, blue: 0.085, alpha: 1),
                   ending: NSColor(srgbRed: 0.095, green: 0.085, blue: 0.15, alpha: 1))!.draw(in: NSRect(origin: .zero, size: size), angle: -70)
        let scale = size.width / 1398
        text(slide.feature, frame: rect(90 * scale, 70 * scale, 1200 * scale, 48 * scale, in: size),
             font: .systemFont(ofSize: 26 * scale, weight: .bold), color: slide.accent)
        text(slide.headline, frame: rect(86 * scale, 142 * scale, 1220 * scale, 240 * scale, in: size),
             font: .systemFont(ofSize: 96 * scale, weight: .bold), color: .white)
        text(slide.subtitle, frame: rect(90 * scale, 405 * scale, 1220 * scale, 110 * scale, in: size),
             font: .systemFont(ofSize: 32 * scale, weight: .regular), color: .init(white: 0.75, alpha: 1), spacing: 5)
        let imageHeight = size.height - 600 * scale
        let imageWidth = imageHeight * size.width / size.height
        let frame = rect((size.width - imageWidth) / 2, 550 * scale, imageWidth, imageHeight, in: size)
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: -8, dy: -8), xRadius: 36, yRadius: 36).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30).addClip()
        screenshot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    try validatedPNG(rep).write(to: output.appendingPathComponent("iPhone-Duo-\(slide.id).png"))
}

if CommandLine.arguments.contains("--duo-only") {
    for slide in slides { try renderDuo(slide) }
    let sheet = try canvas(NSSize(width: 1500, height: 900)) {
        for (index, slide) in slides.enumerated() {
            let image = NSImage(contentsOf: output.appendingPathComponent("iPhone-Duo-\(slide.id).png"))!
            image.draw(in: NSRect(x: (index % 5) * 300, y: (1 - index / 5) * 450, width: 300, height: 450))
        }
    }
    try validatedPNG(sheet).write(to: output.appendingPathComponent("iPhone-Duo-contact-sheet.png"))
    print("Rendered \(slides.count) iPhone Duo gallery images in \(output.path)")
} else {
for ipad in [false, true] {
    let images = try slides.map { try render($0, ipad: ipad) }
    let thumb = ipad ? NSSize(width: 412.8, height: 550.4) : NSSize(width: 264, height: 573.6)
    let rows = (images.count + 4) / 5
    let sheet = try canvas(NSSize(width: thumb.width * 5, height: thumb.height * CGFloat(rows))) {
        for (index, url) in images.enumerated() {
            NSImage(contentsOf: url)!.draw(in: NSRect(x: CGFloat(index % 5) * thumb.width, y: CGFloat(rows - 1 - index / 5) * thumb.height, width: thumb.width, height: thumb.height))
        }
    }
    try validatedPNG(sheet).write(to: output.appendingPathComponent("\(ipad ? "iPad" : "iPhone")-contact-sheet.png"))
}
print("Rendered \(slides.count * 2) gallery images and two contact sheets in \(output.path)")
}
