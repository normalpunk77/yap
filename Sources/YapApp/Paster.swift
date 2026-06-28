import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Paster {
    /// Copies `text` to the clipboard and pastes it at the current cursor via a
    /// synthesized ⌘V. The clipboard copy always happens; the paste only fires
    /// when the app is trusted for Accessibility (otherwise the text is left on
    /// the clipboard and the system prompt is shown so the user can enable it).
    static func pasteAtCursor(_ text: String) {
        let pb = NSPasteboard.general
        // Snapshot whatever the user had copied (plain text only) so we can put it back after.
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Not trusted for Accessibility → we can't synthesize the paste. Leave the transcript on
        // the clipboard so the user can paste it by hand, and DON'T restore (that would discard
        // the very text they need).
        guard promptForAccessibility() else { return }
        synthesizeCommandV()
        // Restore the user's previous clipboard once the paste has consumed ours, so dictating
        // doesn't silently wipe what they had copied. Plain-text only — richer content
        // (files/images) can't be preserved through this path. The short delay lets the
        // synthesized ⌘V read our string first.
        guard let previous else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pb.clearContents()
            pb.setString(previous, forType: .string)
        }
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
