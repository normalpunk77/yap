import Foundation

/// A global hotkey: a virtual key code plus a Carbon modifier mask, with a display label.
///
/// Kept provider-/UI-neutral and pure so it can be unit-tested. `keyCode` and `modifiers`
/// are exactly what Carbon's `RegisterEventHotKey` expects; `keyLabel` is the printable name
/// of the key (e.g. "S", "Space", "F5") captured when the user records it.
public struct HotKeyShortcut: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    // Carbon modifier bits (HIToolbox), declared here so this type has no Carbon dependency.
    public static let cmdKey: UInt32 = 0x0100
    public static let shiftKey: UInt32 = 0x0200
    public static let optionKey: UInt32 = 0x0800
    public static let controlKey: UInt32 = 0x1000
    public static let allModifiers = cmdKey | shiftKey | optionKey | controlKey

    /// kVK_ANSI_S = 0x01. The default dictation hotkey is ⌥S.
    public static let defaultShortcut = HotKeyShortcut(keyCode: 0x01, modifiers: optionKey, keyLabel: "S")

    /// True when at least one modifier is held — required so a bare key can't fire the
    /// hotkey while the user is simply typing that key.
    public var hasModifier: Bool { modifiers & Self.allModifiers != 0 }

    /// Menu-bar / Settings label, in Apple's canonical modifier order ⌃⌥⇧⌘ then the key.
    public var display: String {
        var s = ""
        if modifiers & Self.controlKey != 0 { s += "⌃" }
        if modifiers & Self.optionKey != 0 { s += "⌥" }
        if modifiers & Self.shiftKey != 0 { s += "⇧" }
        if modifiers & Self.cmdKey != 0 { s += "⌘" }
        return s + keyLabel
    }
}
