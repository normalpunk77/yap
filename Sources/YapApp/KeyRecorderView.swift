import AppKit
import SwiftUI
import YapCore

/// A click-to-record shortcut field for SwiftUI. Captures the next key combo through the
/// responder chain (the view becomes first responder and receives `keyDown` directly) — it
/// installs **no** event monitor or event tap, so it only ever sees keys aimed at this
/// field, never global input. Requires at least one modifier; Escape cancels.
struct KeyRecorder: NSViewRepresentable {
    let current: HotKeyShortcut
    let onCapture: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onCapture = onCapture
        view.shortcut = current
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onCapture = onCapture
        if !view.isRecording { view.shortcut = current }   // reflect external changes / reverts
    }
}

final class ShortcutRecorderView: NSView {
    var onCapture: ((HotKeyShortcut) -> Void)?
    var shortcut: HotKeyShortcut = .defaultShortcut { didSet { needsDisplay = true } }
    private(set) var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            isRecording = true
            window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    // ⌘-combos arrive as key equivalents; swallow them while recording so they don't fire
    // menu items (e.g. ⌘W closing the window) instead of being captured.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        _ = handle(event)
    }

    /// Consume the event: capture a valid combo, or cancel on Escape. Returns true when
    /// handled (always, while recording) so the key never leaks to other responders.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 /* esc */ && flags.isEmpty {
            stopRecording()
            return true
        }
        let candidate = HotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.carbonModifiers(flags),
            keyLabel: Self.keyLabel(for: event))
        // A bare key (no modifier) would fire the global hotkey while you simply type it.
        guard candidate.hasModifier, !candidate.keyLabel.isEmpty else {
            NSSound.beep()      // stay in recording mode, wait for a valid combo
            return true
        }
        shortcut = candidate
        stopRecording()
        onCapture?(candidate)
        return true
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= HotKeyShortcut.cmdKey }
        if flags.contains(.option)  { m |= HotKeyShortcut.optionKey }
        if flags.contains(.shift)   { m |= HotKeyShortcut.shiftKey }
        if flags.contains(.control) { m |= HotKeyShortcut.controlKey }
        return m
    }

    static func keyLabel(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        // Drop control characters AND the 0xF700-0xF8FF function-key private-use area:
        // unmapped function/navigation keys emit those, which render as INVISIBLE
        // glyphs — the shortcut worked but Settings and the menu showed a blank label.
        let printable = chars.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0xF700 ... 0xF8FF).contains($0.value)
        }
        return printable ? chars : ""
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = isRecording ? "Type a shortcut…" : shortcut.display
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}
