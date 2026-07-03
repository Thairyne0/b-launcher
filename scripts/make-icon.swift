#!/usr/bin/env swift
//
// make-icon.swift
//
// One-shot generator for Resources/AppIcon.icns.
// Run manually with: swift scripts/make-icon.swift
// The resulting .icns is committed to the repo; colleagues do NOT need to
// re-run this at build time. make-app.sh just copies the committed asset.
//
// Draws (offscreen, no window):
//   - rounded-rect "squircle-ish" background, vertical gradient
//     deep slate #1E293B (top) -> #0B1220 (bottom)
//   - subtle inner top highlight band (white @ 6% opacity)
//   - centered white SF Symbol ("play.stack.fill", falling back to
//     "play.square.stack" then "play.fill") at ~52% of icon size
//

import AppKit
import Foundation

// MARK: - Config

let sizes = [16, 32, 64, 128, 256, 512, 1024]

let topColor = NSColor(srgbRed: 0x1E / 255.0, green: 0x29 / 255.0, blue: 0x3B / 255.0, alpha: 1.0)
let bottomColor = NSColor(srgbRed: 0x0B / 255.0, green: 0x12 / 255.0, blue: 0x20 / 255.0, alpha: 1.0)

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = repoRoot.appendingPathComponent("Resources")
let iconsetDir = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
let icnsOutput = resourcesDir.appendingPathComponent("AppIcon.icns")

// MARK: - Symbol lookup with fallback chain

func resolveSymbolImage(pointSize: CGFloat) -> NSImage {
    let candidates = ["play.stack.fill", "play.square.stack", "play.fill"]
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

    for name in candidates {
        if let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
           let configured = base.withSymbolConfiguration(config) {
            print("Using SF Symbol: \(name)")
            return configured
        }
    }
    fatalError("No usable SF Symbol found among fallbacks: \(candidates)")
}

// MARK: - Drawing

func drawIcon(size: Int) -> NSBitmapImageRep {
    let dim = CGFloat(size)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not allocate NSBitmapImageRep for size \(size)")
    }
    rep.size = NSSize(width: dim, height: dim)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not create graphics context for size \(size)")
    }
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 0, y: 0, width: dim, height: dim)
    let cornerRadius = dim * 0.22

    // Background squircle-ish rounded rect, clipped, filled with vertical gradient.
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    bgPath.addClip()

    if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
        gradient.draw(in: rect, angle: 90) // top -> bottom
    }

    // Subtle inner top highlight band (white ~6% opacity), simple thin band near the top.
    let highlightHeight = dim * 0.18
    let highlightRect = NSRect(x: 0, y: dim - highlightHeight, width: dim, height: highlightHeight)
    NSColor.white.withAlphaComponent(0.06).setFill()
    highlightRect.fill(using: .sourceOver)

    // Foreground SF Symbol, centered, white, ~52% of icon size.
    let symbolPointSize = dim * 0.52
    let symbolImage = resolveSymbolImage(pointSize: symbolPointSize)
    let symbolSize = symbolImage.size
    let scale = (dim * 0.52) / max(symbolSize.width, symbolSize.height)
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let drawOrigin = NSPoint(x: (dim - drawSize.width) / 2.0, y: (dim - drawSize.height) / 2.0)

    symbolImage.draw(
        in: NSRect(origin: drawOrigin, size: drawSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func pngData(from rep: NSBitmapImageRep) -> Data {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    return data
}

// MARK: - Main

let fm = FileManager.default

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

// Standard iconutil naming: base sizes 16, 32, 128, 256, 512, each with an @2x
// variant that is twice the pixel dimensions (still named for the base size).
struct IconSlot {
    let baseSize: Int
    let pixelSize: Int
    let suffix: String // "" or "@2x"
}

let slots: [IconSlot] = [
    IconSlot(baseSize: 16, pixelSize: 16, suffix: ""),
    IconSlot(baseSize: 16, pixelSize: 32, suffix: "@2x"),
    IconSlot(baseSize: 32, pixelSize: 32, suffix: ""),
    IconSlot(baseSize: 32, pixelSize: 64, suffix: "@2x"),
    IconSlot(baseSize: 128, pixelSize: 128, suffix: ""),
    IconSlot(baseSize: 128, pixelSize: 256, suffix: "@2x"),
    IconSlot(baseSize: 256, pixelSize: 256, suffix: ""),
    IconSlot(baseSize: 256, pixelSize: 512, suffix: "@2x"),
    IconSlot(baseSize: 512, pixelSize: 512, suffix: ""),
    IconSlot(baseSize: 512, pixelSize: 1024, suffix: "@2x"),
]

// Render each distinct pixel size once, then write it out for every slot that needs it.
var renderedBySize: [Int: Data] = [:]
for size in sizes {
    let rep = drawIcon(size: size)
    renderedBySize[size] = pngData(from: rep)
    print("Rendered \(size)x\(size)")
}

for slot in slots {
    guard let data = renderedBySize[slot.pixelSize] else {
        fatalError("Missing rendered data for pixel size \(slot.pixelSize) (needed by icon_\(slot.baseSize)x\(slot.baseSize)\(slot.suffix).png)")
    }
    let filename = "icon_\(slot.baseSize)x\(slot.baseSize)\(slot.suffix).png"
    let outURL = iconsetDir.appendingPathComponent(filename)
    try data.write(to: outURL)
}

// Run iconutil to produce the .icns from the .iconset directory.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsOutput.path]

try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

try? fm.removeItem(at: iconsetDir)

print("OK: \(icnsOutput.path)")
