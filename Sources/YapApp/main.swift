import AppKit

// Single-instance guard. Two copies of Yap would each register the SAME global hotkey, and
// macOS delivers a global hotkey to EVERY process that registered it — so one keypress drives
// both, and the dictation is transcribed and pasted twice (the "it pastes twice" bug). Refuse
// to be the second instance: hand focus to the one already running and exit before we install
// the hotkey or any menu-bar item. Matched by bundle id, so a stray dev build and the installed
// app (both `com.yap`) can't coexist either.
if let bundleID = Bundle.main.bundleIdentifier {
    let me = ProcessInfo.processInfo.processIdentifier
    let existing = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .first { $0.processIdentifier != me && !$0.isTerminated }
    if let existing {
        _ = existing.activate()
        exit(0)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
