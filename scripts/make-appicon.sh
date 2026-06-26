#!/usr/bin/env bash
# Generate Resources/AppIcon.icns from an emoji rendered on the brand gradient.
# Usage:  bash scripts/make-appicon.sh [emoji]
# Example: bash scripts/make-appicon.sh 🗣️
set -euo pipefail
cd "$(dirname "$0")/.."

EMOJI="${1:-🎙️}"
ICONSET="Resources/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Render every iconset size natively (no downscaling) with AppKit. The emoji draws in
# full color via Apple Color Emoji regardless of the requested font.
YAP_EMOJI="$EMOJI" YAP_ICONSET="$ICONSET" swift - <<'SWIFT'
import AppKit

let emoji = ProcessInfo.processInfo.environment["YAP_EMOJI"] ?? "🎙️"
let outDir = ProcessInfo.processInfo.environment["YAP_ICONSET"] ?? "Resources/AppIcon.iconset"

// Brand gradient — matches the menu-bar waveform / recording aura.
let brand = NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.85, blue: 0.96, alpha: 1),  // electric cyan
    NSColor(srgbRed: 0.27, green: 0.52, blue: 1.00, alpha: 1),  // electric blue
    NSColor(srgbRed: 0.61, green: 0.36, blue: 1.00, alpha: 1),  // ultraviolet
])!

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),   ("icon_16x16@2x", 32),
    ("icon_32x32", 32),   ("icon_32x32@2x", 64),
    ("icon_128x128", 128),("icon_128x128@2x", 256),
    ("icon_256x256", 256),("icon_256x256@2x", 512),
    ("icon_512x512", 512),("icon_512x512@2x", 1024),
]

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let size = CGFloat(px)
    // ~10% transparent margin around an Apple-style rounded square (squircle).
    let margin = size * 0.10
    let square = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = square.width * 0.2237
    let clip = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
    clip.addClip()
    brand.draw(in: square, angle: -90)

    // Centered emoji at ~58% of the square; nudged up slightly for optical centering.
    let fontSize = square.width * 0.58
    let str = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
    let textSize = str.size()
    let point = NSPoint(x: (size - textSize.width) / 2,
                        y: (size - textSize.height) / 2 + size * 0.02)
    str.draw(at: point)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in sizes {
    guard let data = render(px) else { fputs("failed \(name)\n", stderr); continue }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
SWIFT

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"   # intermediate; only the .icns is kept/committed
echo "Wrote Resources/AppIcon.icns ($EMOJI)"
