#!/usr/bin/env swift
//
// export-symbol-layers.swift — export SF Symbols as filled, transparent PNG
// layers for use in Icon Composer.
//
// Unlike SF Symbols' own SVG export (which wraps the glyph in guide layers and
// often renders with no fill), this bakes each symbol into a solid,
// transparent-background PNG at 1024px with an explicit colour — exactly what
// Icon Composer wants to drop in as a layer.
//
//     ./scripts/export-symbol-layers.swift
//
// Writes into scripts/icon-layers/ .

import AppKit

let outDir = "scripts/icon-layers"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let pixels = 1024

/// name, weight, palette colours, and how much of the canvas the glyph fills
/// (0–1). For multi-layer symbols the palette maps layer-by-layer: for
/// `power.circle.fill` that's [glyph, disc], so the power glyph is white and
/// the surrounding disc is dark.
let layers: [(symbol: String, file: String, weight: NSFont.Weight, colors: [NSColor], fill: CGFloat)] = [
    ("power.circle.fill", "power.png", .regular, [.white, NSColor.black.withAlphaComponent(0.85)], 0.86),
    ("nosign", "nosign.png", .bold, [.systemRed], 0.92),
]

func render(symbol: String, weight: NSFont.Weight, colors: [NSColor], fill: CGFloat) -> Data {
    let px = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("bitmap alloc failed") }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let config = NSImage.SymbolConfiguration(pointSize: px * fill, weight: weight)
        .applying(.init(paletteColors: colors))
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(config) else {
        fatalError("missing SF Symbol: \(symbol)")
    }

    // Centre the glyph in the square canvas.
    let s = img.size
    let scale = min(px / s.width, px / s.height) * fill
    let w = s.width * scale, h = s.height * scale
    let rect = NSRect(x: (px - w) / 2, y: (px - h) / 2, width: w, height: h)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

    ctx.flushGraphics()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    return png
}

for layer in layers {
    let data = render(symbol: layer.symbol, weight: layer.weight, colors: layer.colors, fill: layer.fill)
    let path = "\(outDir)/\(layer.file)"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
print("Done. Drag these into Icon Composer as layers.")
