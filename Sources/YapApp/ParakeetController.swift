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
    /// The in-flight clipboard-polling task from the current `stop()`. Held so a new `start()`
    /// can cancel it — otherwise a stale poller from a previous (e.g. silent) session could fire
    /// `onText` into the NEXT dictation, pasting the wrong transcript.
    private var pollTask: Task<Void, Never>?

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
        recording ? await stop() : await start()
    }

    func shutdown() { manager.stopDaemon() }

    private func start() async {
        // Cancel any clipboard poller still running from a previous stop() (e.g. a silent
        // session waiting out its timeout) so it can't deliver into this new dictation.
        pollTask?.cancel()
        pollTask = nil
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
        manager.sendDaemonCommand("start")
    }

    private func stop() async {
        recording = false
        // Recording has ended — drop the aura (and the level meter) immediately, regardless of
        // whether any speech was captured. Otherwise a press-without-speaking left the aura lit
        // for the whole no-speech timeout below.
        onRecording?(false)
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount
        manager.sendDaemonCommand("stop")
        // The daemon transcribes (~0.5 s) then copies the text to the clipboard. Poll for it in a
        // cancellable task so a fresh start() can abandon this wait. Give up after ~6 s (silence).
        let task = Task { [weak self] in
            for _ in 0 ..< 120 {
                try? await Task.sleep(nanoseconds: 50_000_000)   // 50 ms × 120 ≈ 6 s
                if Task.isCancelled { return }
                guard pb.changeCount != countBefore else { continue }
                let text = pb.string(forType: .string) ?? ""
                // A change-count bump after we sent "stop" is the daemon's transcript copy.
                // Deliver the first non-empty result. Do NOT also require it to differ from the
                // prior clipboard: a legitimately repeated dictation ("ok" then "ok") copies the
                // SAME string and must still be delivered, not dropped as a duplicate.
                if !text.isEmpty {
                    if Task.isCancelled { return }   // a fresh start() may have cancelled us
                    self?.onText?(text)
                    return
                }
            }
        }
        pollTask = task
        await task.value
    }
}
