import AppKit

// Writing to a pipe whose reader has gone (e.g. the `nc` we spawn to talk to the Parakeet
// daemon exits early) raises SIGPIPE, whose default action kills the whole app. Ignore it so
// such a write fails locally (EPIPE) instead of taking the process down.
signal(SIGPIPE, SIG_IGN)

// Single-instance guard. Two copies of Yap would each register the SAME global hotkey, and
// macOS delivers a global hotkey to EVERY process that registered it — so one keypress drives
// both, and the dictation is transcribed and pasted twice (the "it pastes twice" bug). Hold an
// exclusive flock on a lockfile for the whole process lifetime: the OS frees it when the process
// dies (even on crash / SIGKILL), so a wedged-but-alive instance keeps it (we defer to it) while
// a dead one frees it (we take over) — closing the wedged-sibling and simultaneous-launch gaps an
// NSRunningApplication snapshot leaves open. Fail OPEN if the lock can't be created, so a
// filesystem quirk never makes the app unlaunchable.
let yapSupport = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Yap", isDirectory: true)
try? FileManager.default.createDirectory(at: yapSupport, withIntermediateDirectories: true)
func runningYapSibling() -> NSRunningApplication? {
    guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .first { $0.processIdentifier != me && !$0.isTerminated }
}

let lockFD = open(yapSupport.appendingPathComponent("yap.lock").path, O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 {
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        // Another live instance holds the lock — defer to it and bow out before we install the
        // hotkey or a menu-bar item. Keep `lockFD` open otherwise (closing releases the lock; the
        // OS reclaims it on exit).
        runningYapSibling()?.activate()
        exit(0)
    }
} else if let sibling = runningYapSibling() {
    // Couldn't even create the lockfile (rare). Don't blindly become a second instance and
    // re-register the hotkey — defer to a running one if there is one. Fail open (proceed) only
    // when there is demonstrably no sibling to defer to.
    sibling.activate()
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
