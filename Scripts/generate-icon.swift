#!/usr/bin/env swift
// Renders Sweep's app icon: macOS squircle, mint→azure gradient, sparkles glyph.
// Usage: swift Scripts/generate-icon.swift <output-directory>

import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Assets.xcassets/AppIcon.appiconset"

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Standard macOS icon grid: artwork ~82% of canvas, centered squircle.
    let margin = canvas * 0.098
    let rect = NSRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Soft drop shadow.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = canvas * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.008)
    shadow.set()
    NSColor.black.withAlphaComponent(0.28).setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Gradient body.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.66, alpha: 1),
        NSColor(calibratedRed: 0.22, green: 0.52, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.32, blue: 0.95, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -60)

    // Subtle inner highlight arc at the top.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let highlight = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.28),
        ending: NSColor.white.withAlphaComponent(0.0)
    )!
    let highlightRect = NSRect(x: rect.minX, y: rect.midY + rect.height * 0.12, width: rect.width, height: rect.height * 0.4)
    highlight.draw(in: highlightRect, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Sparkles glyph.
    let config = NSImage.SymbolConfiguration(pointSize: canvas * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let scale = min(rect.width * 0.62 / symbolSize.width, rect.height * 0.62 / symbolSize.height)
        let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
        let origin = NSPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2
        )
        // Glyph shadow for depth.
        NSGraphicsContext.current?.saveGraphicsState()
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        glyphShadow.shadowBlurRadius = canvas * 0.012
        glyphShadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.006)
        glyphShadow.set()
        symbol.draw(in: NSRect(origin: origin, size: drawSize))
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        fatalError("Could not rasterize icon")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let resized = resample(rep: rep, pixels: pixels),
          let png = resized.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

func resample(rep: NSBitmapImageRep, pixels: Int) -> NSBitmapImageRep? {
    guard let target = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    target.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return target
}

let master = drawIcon(canvas: 1024)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let path = "\(outputDir)/icon_\(size).png"
    writePNG(master, pixels: size, to: path)
    print("wrote \(path)")
}
print("done")
