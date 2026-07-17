#!/usr/bin/env swift
// Renders the DMG window background (2x for Retina): soft light canvas,
// brand gradient glow, app name, and an arrow hinting drag-to-Applications.
// Usage: swift Scripts/generate-dmg-background.swift <output.png>

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/dmg-background.png"
let width: CGFloat = 1120   // 560pt @2x
let height: CGFloat = 800   // 400pt @2x

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Base
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Soft gradient glow top-left
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.66, alpha: 0.25),
    NSColor(calibratedRed: 0.22, green: 0.52, blue: 1.00, alpha: 0.10),
    NSColor(calibratedRed: 0.22, green: 0.52, blue: 1.00, alpha: 0.0),
])!
glow.draw(fromCenter: NSPoint(x: width * 0.22, y: height * 0.85), radius: 0,
          toCenter: NSPoint(x: width * 0.22, y: height * 0.85), radius: width * 0.55,
          options: [])

// Title
let title = "Sweep" as NSString
title.draw(
    at: NSPoint(x: 80, y: height - 170),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1),
    ]
)
let subtitle = "Drag to Applications to install" as NSString
subtitle.draw(
    at: NSPoint(x: 82, y: height - 214),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
    ]
)

// Arrow between icon positions (icons sit at y≈185pt from top → 2x)
let arrowY = height - 185 * 2 - 10
let path = NSBezierPath()
path.move(to: NSPoint(x: 400, y: arrowY))
path.line(to: NSPoint(x: 660, y: arrowY))
path.lineWidth = 10
path.lineCapStyle = .round
NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
path.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 630, y: arrowY + 26))
head.line(to: NSPoint(x: 668, y: arrowY))
head.line(to: NSPoint(x: 630, y: arrowY - 26))
head.lineWidth = 10
head.lineCapStyle = .round
head.lineJoinStyle = .round
NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
head.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode background")
}
// Tag as 144dpi so Finder treats it as 560x400pt @2x.
rep.size = NSSize(width: width / 2, height: height / 2)
guard let png2x = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode background")
}
_ = png
try! png2x.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
