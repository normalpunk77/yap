import AppKit
import YapCore

/// Drives on-device dictation through the Parakeet daemon — the parallel of the cloud
/// `DictationController`. The hotkey toggles recording over the daemon's Unix socket; the
/// daemon (run with `--clipboard`) owns the mic, does VAD, transcribes on stop, and copies
/// the text to the clipboard, which we then paste at the cursor.
@MainActor
final class ParakeetController {
    private let manager = ParakeetManager.shared
    private var recording = false

    /// Whether a recording session is currently active (so the hotkey path can skip the
    /// microphone gate when the press is a stop, not a start).
    var isRecording: Bool { recording }

    /// Recording started/stopped — drives the aura.
    var onRecording: ((Bool) -> Void)?
    /// A user-facing error (engine not set up, daemon failed to start).
    var onError: ((String) -> Void)?

    func toggle() async {
        recording ? await stop() : await start()
    }

    func shutdown() { manager.stopDaemon() }

    private func start() async {
        guard manager.isReady else {
            onError?("Parakeet isn't set up yet. Open Settings → Parakeet and let it finish building and downloading the model.")
            return
        }
        do {
            try await manager.ensureDaemonRunning()
        } catch {
            onError?((error as? ParakeetError)?.message ?? "\(error)")
            return
        }
        manager.sendDaemonCommand("start")
        recording = true
        onRecording?(true)
    }

    private func stop() async {
        recording = false
        let clipboardBefore = NSPasteboard.general.changeCount
        manager.sendDaemonCommand("stop")
        // The daemon transcribes (~0.5 s) then copies the text to the clipboard. Paste it as
        // soon as it lands; give up after a few seconds (no speech / silence).
        for _ in 0 ..< 120 {
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50 ms × 120 ≈ 6 s
            if NSPasteboard.general.changeCount != clipboardBefore {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                onRecording?(false)
                if !text.isEmpty { Paster.pasteAtCursor(text) }
                return
            }
        }
        onRecording?(false)
    }
}
