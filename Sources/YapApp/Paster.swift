import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Paster {
    /// Copies `text` to the clipboard and pastes it at the current cursor via a
    /// synthesized ⌘V. We only touch the clipboard after Accessibility trust is
    /// confirmed, so a failed permission prompt does not clobber the user's current
    /// clipboard contents.
    static func pasteAtCursor(_ text: String) {
        guard promptForAccessibility() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        synthesizeCommandV()
    }

    /// True when the process may post synthetic key events. When not yet trusted,
    /// macOS shows the Accessibility dialog (which adds the app to the list).
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
