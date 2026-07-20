import AppKit

// Renders LocalFlow's app icon: a white SF Symbol on an indigo→violet
// rounded-rect, inset within the 1024px canvas the way macOS app icons are.
// Writes a PNG to argv[1] (default icon-1024.png); make-icon.sh turns it into
// the .iconset sizes and an .icns. Run via `swift make-icon.swift out.png [symbol]`.
//
// The companion "Check Model Updates" launcher shares this background on
// purpose — same family — and differs by glyph, so the two are told apart by
// silhouette at Dock size: mic mass vs refresh ring.

let canvas: CGFloat = 1024
let inset: CGFloat = 100 // macOS icon art sits inside the canvas, not edge-to-edge
let symbolName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mic.fill"

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let bg = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let radius = bg.width * 0.2237 // Apple's continuous-corner ratio, approximated
NSBezierPath(roundedRect: bg, xRadius: radius, yRadius: radius).addClip()

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.45, blue: 0.98, alpha: 1), // indigo
    NSColor(srgbRed: 0.58, green: 0.36, blue: 0.95, alpha: 1), // violet
])!
gradient.draw(in: bg, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: bg.width * 0.52, weight: .regular)
if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
   let mic = base.withSymbolConfiguration(config) {
    let s = mic.size
    // SF Symbols are template (black) images; tint to white via source-atop.
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    mic.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2,
                           width: s.width, height: s.height))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
do {
    try png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
