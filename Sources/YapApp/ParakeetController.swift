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
    func clear()
}

extension NSPasteboard: ClipboardReading {
    func clear() { clearContents() }
}

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
    private var recordingStartedAt: Date?
    /// Poll cadence for the daemon's clipboard hand-off; injectable so tests don't
    /// wait out real seconds.
    var pollIntervalNanos: UInt64 = 50_000_000
    /// The in-flight clipboard-polling task from the current `stop()`. Held so a new `start()`
    /// can cancel it — otherwise a stale poller from a previous (e.g. silent) session could fire
    /// `onText` into the NEXT dictation, pasting the wrong transcript.
    private var pollTask: Task<Void, Never>?

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
    /// Signals that the stop lifecycle finished, whether it produced text or not. The app uses
    /// this to keep provider switching and quit/shutdown blocked until the daemon poller has
    /// actually settled.
    var onSessionEnded: (() -> Void)?

    func toggle() async {
        if starting { return }
        recording ? await stop() : await start()
    }

    /// Abandon an in-flight session WITHOUT delivering — used when the provider is changed under
    /// us, so a recording started on the local engine isn't left orphaned. Safe when idle.
    func cancel() async {
        defer { onSessionEnded?() }
        pollTask?.cancel()
        pollTask = nil
        guard recording else { return }
        recording = false
        onRecording?(false)                    // drops the aura + ends the dictation activity
        _ = manager.sendDaemonCommand("stop")  // tell the daemon to stop capturing; discard result
    }

    func shutdown() { manager.stopDaemon() }

    private func start() async {
        starting = true
        defer { starting = false }
        // Cancel any clipboard poller still running from a previous stop() (e.g. a silent
        // session waiting out its timeout) and AWAIT its exit, so it can't deliver into this new
        // dictation in the narrow window between its cancel and its next cancellation check.
        let oldPoll = pollTask
        pollTask = nil
        oldPoll?.cancel()
        await oldPoll?.value
        guard manager.isReady else {
            onError?("Parakeet isn't set up yet. Open Settings → Parakeet and let it finish building and downloading the model.")
            return
        }
        // Show the aura immediately on the keypress — the first start blocks for seconds while
        // the daemon loads the model, and a silent app reads as broken. Revert if it fails.
        recording = true
        recordingStartedAt = Date()
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

    /// How long to wait for the daemon's transcript, scaled to what was recorded: on-device
    /// transcription time grows with the audio length, and the old fixed 6 s cap silently
    /// dropped every dictation long enough to transcribe slower than that.
    static func pollBudgetSeconds(forRecordingSeconds duration: Double) -> Double {
        min(60, max(10, duration * 0.5))
    }

    private func stop() async {
        defer { onSessionEnded?() }
        recording = false
        let recordedSeconds = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        // Recording has ended — drop the aura (and the level meter) immediately, regardless of
        // whether any speech was captured. Otherwise a press-without-speaking left the aura lit
        // for the whole no-speech timeout below.
        onRecording?(false)
        let countBefore = clipboard.changeCount
        guard manager.sendDaemonCommand("stop") else {
            manager.stopDaemon()
            onError?("The local engine failed to stop recording.")
            return
        }
        // The daemon transcribes then copies the text to the clipboard. Poll for it in a
        // cancellable task so a fresh start() can abandon this wait.
        let budgetNanos = UInt64(Self.pollBudgetSeconds(forRecordingSeconds: recordedSeconds) * 1_000_000_000)
        let polls = max(1, Int(budgetNanos / max(1, pollIntervalNanos)))
        let interval = pollIntervalNanos
        let task = Task { [weak self] in
            for _ in 0 ..< polls {
                if Task.isCancelled { return }
                if let self, self.clipboard.changeCount != countBefore {
                    let observed = self.clipboard.changeCount
                    let text = self.clipboard.string(forType: .string) ?? ""
                    // A change-count bump after we sent "stop" is the daemon's transcript copy.
                    // Deliver the first non-empty result. Do NOT also require it to differ from the
                    // prior clipboard: a legitimately repeated dictation ("ok" then "ok") copies the
                    // SAME string and must still be delivered, not dropped as a duplicate.
                    if !text.isEmpty {
                        if Task.isCancelled { return }   // a fresh start() may have cancelled us
                        // The daemon left the RAW transcript on the clipboard. Clear it before
                        // delivery so the paste path's restore doesn't put that raw text back —
                        // otherwise a later ⌘V would yield the un-cleaned transcript. Only if the
                        // count hasn't moved AGAIN: a newer write is the user's own copy, and
                        // clearing it would destroy their clipboard.
                        if self.clipboard.changeCount == observed {
                            self.clipboard.clear()
                        }
                        self.onText?(text)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: interval)
            }
            // Ran out of budget with no transcript: say so — the silent give-up looked
            // like the app ate the dictation.
            if !Task.isCancelled {
                self?.onError?("The local engine didn't return a transcript in time. Check the daemon log in ~/Library/Application Support/Yap if this keeps happening.")
            }
        }
        pollTask = task
        await task.value
    }
}
