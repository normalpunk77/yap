import AppKit
import YapCore

@MainActor
protocol ParakeetManaging: AnyObject {
    var isReady: Bool { get }
    func ensureDaemonRunning() async throws
    func sendDaemonCommand(_ command: String) -> Bool
    func stopDaemon()
}

protocol ClipboardReading {
    var changeCount: Int { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: ClipboardReading {}

/// Drives on-device dictation through the Parakeet daemon — the parallel of the cloud
/// `DictationController`. The hotkey toggles recording over the daemon's Unix socket; the
/// daemon (run with `--clipboard`) owns the mic, does VAD, transcribes on stop, and copies
/// the text to the clipboard, which we then paste at the cursor.
@MainActor
final class ParakeetController {
    private let manager: ParakeetManaging
    private let clipboard: ClipboardReading
    private var recording = false
    private var starting = false

    init(manager: ParakeetManaging = ParakeetManager.shared,
         clipboard: ClipboardReading = NSPasteboard.general) {
        self.manager = manager
        self.clipboard = clipboard
    }

    /// Whether a recording session is currently active (so the hotkey path can skip the
    /// microphone gate when the press is a stop, not a start).
    var isRecording: Bool { recording }

    /// Recording started/stopped — drives the aura.
    var onRecording: ((Bool) -> Void)?
    /// A user-facing error (engine not set up, daemon failed to start).
    var onError: ((String) -> Void)?
    /// The finished transcript, for the owner to post-process + paste. Replaces the old direct
    /// paste so the local engine shares the cloud delivery path.
    var onText: ((String) -> Void)?

    func toggle() async {
        if starting { return }
        recording ? await stop() : await start()
    }

    func shutdown() { manager.stopDaemon() }

    private func start() async {
        starting = true
        defer { starting = false }
        guard manager.isReady else {
            onError?("Parakeet isn't set up yet. Open Settings → Parakeet and let it finish building and downloading the model.")
            return
        }
        // Show the aura immediately on the keypress — the first start blocks for seconds while
        // the daemon loads the model, and a silent app reads as broken. Revert if it fails.
        recording = true
        onRecording?(true)
        do {
            try await manager.ensureDaemonRunning()
        } catch {
            recording = false
            onRecording?(false)
            onError?((error as? ParakeetError)?.message ?? "\(error)")
            return
        }
        guard manager.sendDaemonCommand("start") else {
            recording = false
            onRecording?(false)
            onError?("The local engine failed to start recording.")
            return
        }
    }

    private func stop() async {
        recording = false
        // Recording has ended — drop the aura (and the level meter) immediately, regardless of
        // whether any speech was captured. Otherwise a press-without-speaking left the aura lit
        // for the whole no-speech timeout below.
        onRecording?(false)
        let clipboardBefore = clipboard.changeCount
        guard manager.sendDaemonCommand("stop") else {
            onError?("The local engine failed to stop recording.")
            return
        }
        if clipboard.changeCount != clipboardBefore {
            let text = clipboard.string(forType: .string) ?? ""
            if !text.isEmpty { onText?(text) }
            return
        }
        // The daemon transcribes (~0.5 s) then copies the text to the clipboard. Paste it as
        // soon as it lands; give up after a few seconds (no speech / silence).
        for _ in 0 ..< 120 {
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50 ms × 120 ≈ 6 s
            if clipboard.changeCount != clipboardBefore {
                let text = clipboard.string(forType: .string) ?? ""
                if !text.isEmpty { onText?(text) }
                return
            }
        }
    }
}
