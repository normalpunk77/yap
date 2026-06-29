import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Paster {
    @MainActor
    private static var pendingClipboardRestoreTasks: [UUID: Task<Void, Never>] = [:]
    @MainActor
    private static var pendingClipboardRestoreSnapshot: ClipboardSnapshot?
    @MainActor
    private static var pendingClipboardRestoreWriteCount: Int?

    /// Copies `text` to the clipboard and pastes it at the current cursor via a synthesized ⌘V.
    /// When Accessibility is not trusted, the clipboard is left untouched and a manual fallback
    /// explains how to copy the transcript instead of silently destroying the user's prior data.
    /// When trusted, the user's previous clipboard is restored after the paste.
    @MainActor
    static func pasteAtCursor(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        trustChecker: @MainActor () -> Bool = promptForAccessibility,
        fallback: @MainActor (String) -> Void = presentAccessibilityDeniedFallback
    ) {
        let pb = pasteboard
        // Snapshot the entire clipboard payload so we can put it back after the paste.
        let previous = ClipboardSnapshot(pasteboard: pb)
        // Not trusted for Accessibility → we can't synthesize the paste. Leave the transcript on
        // the clipboard untouched and show a manual fallback instead of overwriting what the
        // user already had copied.
        guard trustChecker() else {
            fallback(text)
            return
        }
        let changeCountBeforeWrite = pb.changeCount
        pb.clearContents()
        pb.setString(text, forType: .string)
        let writeCount = pb.changeCount
        synthesizeCommandV()
        // Restore the user's previous clipboard once the paste has consumed ours, so dictating
        // doesn't silently wipe what they had copied. The short delay lets the synthesized ⌘V
        // read our string first.
        guard let previous else { return }
        let snapshotToRestore: ClipboardSnapshot
        if let existingSnapshot = pendingClipboardRestoreSnapshot,
           let existingWriteCount = pendingClipboardRestoreWriteCount,
           changeCountBeforeWrite == existingWriteCount {
            snapshotToRestore = existingSnapshot
        } else {
            snapshotToRestore = previous
        }
        let token = UUID()
        pendingClipboardRestoreSnapshot = snapshotToRestore
        pendingClipboardRestoreWriteCount = writeCount
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            defer {
                pendingClipboardRestoreTasks[token] = nil
                if pendingClipboardRestoreTasks.isEmpty {
                    pendingClipboardRestoreSnapshot = nil
                    pendingClipboardRestoreWriteCount = nil
                }
            }
            // Only restore if OUR transcript is still on the clipboard. If a second dictation or
            // another app wrote in the meantime (changeCount moved), leave theirs untouched
            // instead of clobbering it with a stale value.
            guard pb.changeCount == writeCount else { return }
            pb.clearContents()
            _ = pb.writeObjects(snapshotToRestore.restoredItems())
        }
        pendingClipboardRestoreTasks[token] = task
    }

    /// True when the process may post synthetic key events. When not yet trusted,
    /// macOS shows the Accessibility dialog (which adds the app to the list).
    @discardableResult
    @MainActor
    static func promptForAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    private static func presentAccessibilityDeniedFallback(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility access required"
        alert.informativeText = "Yap couldn't auto-paste, so your clipboard was left untouched. Use Copy Transcript to place the transcript on the clipboard, or grant Accessibility to restore automatic pasting."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.string = text
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy Transcript")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    @MainActor
    private static func synthesizeCommandV() {
        // Use a PRIVATE event-source state, not `.combinedSessionState`. The default hotkey is
        // ⌥S: if the user is still physically holding ⌥ when delivery fires, a combined-state
        // source merges that live ⌥ into our event, so the target app receives ⌥⌘V ("Paste and
        // Match Style") instead of ⌘V. A private state carries only the flags we set below.
        let source = CGEventSource(stateID: .privateState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }

    @MainActor
    static var hasPendingClipboardRestore: Bool {
        !pendingClipboardRestoreTasks.isEmpty
    }

    @MainActor
    static func waitForPendingClipboardRestore() async {
        let tasks = Array(pendingClipboardRestoreTasks.values)
        for task in tasks {
            await task.value
        }
    }
}
