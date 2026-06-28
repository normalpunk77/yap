import Foundation

public protocol AudioCapturer: Sendable {
    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws
    func stop() async
}

public enum DictationState: Equatable, Sendable {
    case idle
    case listening(String)
    case finalizing
    case error(String)
}

/// Toggle-driven dictation that runs for an unbounded duration until the user
/// stops it. ElevenLabs realtime emits `committed_transcript` on its own (on
/// pauses and on the ~36s auto-commit); those segments are ACCUMULATED and the
/// session keeps running. Only the user's second toggle finalizes: it stops the
/// mic, flushes the last in-flight audio, sends an explicit commit, and waits for
/// the final segment before producing the full text. This mirrors Spokenly —
/// pressing stop immediately after fast speech still transcribes the tail.
public actor DictationController {
    private let capturer: AudioCapturer
    private let clientFactory: @Sendable () throws -> TranscriptionClient
    private let trailingCaptureNanos: UInt64
    private let flushDelayNanos: UInt64
    private let finalizeTimeoutNanos: UInt64
    private let reconnectBackoffNanos: UInt64
    private let maxReconnects = 3
    private var reconnectAttempts = 0

    private var onState: (@Sendable (DictationState) -> Void)?
    private var onResult: (@Sendable (String) -> Void)?

    private var client: TranscriptionClient?
    private var eventTask: Task<Void, Never>?
    private var finalizeTimeoutTask: Task<Void, Never>?
    private var capturing = false
    // True only while `start()` is bringing a session up. Its `await`s run with the
    // state already at `.listening`, so without this a second fast toggle would read
    // `.listening` and finalize a half-started session. Toggles are ignored meanwhile.
    private var starting = false

    private var committedText = ""
    private var partial = ""
    public private(set) var state: DictationState = .idle

    // `trailingCaptureSeconds`: keep the mic running this long AFTER the user hits stop, before
    // closing capture — so a word spoken right up to the keypress is still recorded (the audio
    // for it hasn't been captured yet at the instant of the press). Defaults to 0 here (tests
    // opt in); the app sets ~0.25s.
    // `flushDelaySeconds`: how long to let the last in-flight audio reach the server after the
    // mic stops, before sending the commit. `finalizeTimeoutSeconds`: a SAFETY-NET cap — the
    // final segment normally arrives on its own and delivers immediately (see `handle`), so a
    // generous value adds no latency in the common case; it only bounds the rare "provider went
    // silent" stop. These must stay generous: a too-short timeout (the 0.1/0.4 regression) fired
    // before Deepgram's `Finalize` flush result arrived, truncating the spoken tail.
    public init(
        capturer: AudioCapturer,
        clientFactory: @escaping @Sendable () throws -> TranscriptionClient,
        trailingCaptureSeconds: Double = 0,
        flushDelaySeconds: Double = 0.25,
        finalizeTimeoutSeconds: Double = 3.0,
        reconnectBackoffSeconds: Double = 0.5
    ) {
        self.capturer = capturer
        self.clientFactory = clientFactory
        self.trailingCaptureNanos = UInt64(max(0, trailingCaptureSeconds) * 1_000_000_000)
        self.flushDelayNanos = UInt64(max(0, flushDelaySeconds) * 1_000_000_000)
        self.finalizeTimeoutNanos = UInt64(max(0, finalizeTimeoutSeconds) * 1_000_000_000)
        self.reconnectBackoffNanos = UInt64(max(0, reconnectBackoffSeconds) * 1_000_000_000)
    }

    public func setHandlers(onState: @escaping @Sendable (DictationState) -> Void,
                            onResult: @escaping @Sendable (String) -> Void) {
        self.onState = onState
        self.onResult = onResult
    }

    public func toggle() async {
        if starting { return }   // debounce taps while a session is still coming up
        switch state {
        case .idle, .error: await start()
        case .listening: await finalize()
        case .finalizing:
            // Pressing again during the finalize safety window means "I'm done waiting —
            // start the next dictation now." Deliver what we've accumulated and immediately
            // bring up a fresh session, instead of swallowing the tap (which felt like a
            // cooldown: the aura was already off but the second round wouldn't start). Hold
            // `starting` across both steps so an interleaved tap can't double-fire `start()`.
            starting = true
            defer { starting = false }
            await finishAndDeliver()
            await start()
        }
    }

    /// Stop the session and discard the transcript without delivering it.
    public func cancel() async {
        await teardown()
        setState(.idle)
    }

    private var displayText: String {
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPartial.isEmpty else { return committedText }
        return committedText.isEmpty ? trimmedPartial : committedText + " " + trimmedPartial
    }

    private func setState(_ newState: DictationState) {
        state = newState
        onState?(newState)
    }

    private func start() async {
        starting = true
        defer { starting = false }
        committedText = ""
        partial = ""
        reconnectAttempts = 0
        do {
            let client = try clientFactory()
            self.client = client
            startEventLoop(for: client)
            // Route chunks through the actor (not a captured client) so a reconnect can
            // swap `self.client` and audio keeps flowing to the live connection.
            try await capturer.start { [weak self] chunk in
                await self?.forwardChunk(chunk)
            }
            capturing = true
            // Signal "listening" only once capture is truly live, so a failed start
            // (missing key, unavailable mic) goes straight to `.error` without first
            // flashing the recording indicator on screen.
            setState(.listening(""))
        } catch {
            await teardown()
            setState(.error("\(error)"))
        }
    }

    private func startEventLoop(for client: TranscriptionClient) {
        eventTask = Task { [weak self] in
            for await event in client.events() {
                await self?.handle(event)
            }
        }
    }

    private func forwardChunk(_ chunk: Data) async {
        try? await client?.sendChunk(chunk)
    }

    private func finalize() async {
        setState(.finalizing)
        // Keep the mic open briefly so a word spoken right up to the keypress is still captured
        // (its audio isn't recorded yet at the instant of the press). Chunks keep flowing to the
        // live client during this window via `forwardChunk`.
        if trailingCaptureNanos > 0 { try? await Task.sleep(nanoseconds: trailingCaptureNanos) }
        await stopCapture()
        // Let the last in-flight audio chunk reach the server before committing,
        // so the tail of fast speech still gets transcribed.
        if flushDelayNanos > 0 { try? await Task.sleep(nanoseconds: flushDelayNanos) }
        do {
            try await client?.sendCommit()
        } catch {
            // Don't discard a whole dictation if the final commit packet fails (e.g. the
            // socket just dropped): deliver whatever we've already accumulated.
            await finishAndDeliver()
            return
        }
        // Safety net: if the final committed segment never arrives, finish with
        // whatever we have rather than hanging in `finalizing`.
        finalizeTimeoutTask = Task { [weak self, finalizeTimeoutNanos] in
            try? await Task.sleep(nanoseconds: finalizeTimeoutNanos)
            await self?.forceFinish()
        }
    }

    private func stopCapture() async {
        guard capturing else { return }
        capturing = false
        await capturer.stop()
    }

    private func appendCommitted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedText = committedText.isEmpty ? trimmed : committedText + " " + trimmed
    }

    private func handle(_ event: TranscriptEvent) async {
        switch event {
        case .partial(let text):
            reconnectAttempts = 0   // a live event proves the connection recovered
            partial = text
            if case .listening = state { setState(.listening(displayText)) }
        case .committed(let text):
            reconnectAttempts = 0
            appendCommitted(text)
            partial = ""
            if case .finalizing = state {
                await finishAndDeliver()
            } else if case .listening = state {
                setState(.listening(displayText))
            }
        case .failed(let error):
            // A dropped connection while still listening is recoverable: reconnect and
            // keep the mic running. Fatal errors (auth, quota, bad input) are not.
            if case .socketClosed = error, case .listening = state, capturing {
                await reconnect()
            } else if case .socketClosed = error, case .finalizing = state {
                // The socket dropped during finalize — the realtime server commonly closes
                // it right after the commit, sometimes before the final committed segment
                // reaches us. Don't throw the dictation away with a "Connection closed"
                // error: deliver what we've accumulated, same as the sendCommit-failure
                // path and the finalize timeout.
                await finishAndDeliver()
            } else {
                Diag.conn.error("fatal stream error → stopping: \(String(describing: error), privacy: .public)")
                await teardown()
                setState(.error("\(error)"))
            }
        }
    }

    /// Bring up a fresh connection after a transient drop, without stopping the mic.
    /// Gives up (→ error) after `maxReconnects` consecutive failures.
    private func reconnect() async {
        reconnectAttempts += 1
        guard reconnectAttempts <= maxReconnects else {
            Diag.conn.error("reconnect gave up after \(self.maxReconnects) attempts — surfacing 'Connection closed'")
            await teardown()
            setState(.error("socketClosed"))
            return
        }
        Diag.conn.error("stream dropped mid-dictation — reconnecting (attempt \(self.reconnectAttempts)/\(self.maxReconnects))")
        // Drop the dead client and its event loop; the mic keeps capturing (chunks are
        // harmlessly discarded while `client` is nil during the gap).
        eventTask?.cancel()
        eventTask = nil
        await client?.close()
        client = nil
        try? await Task.sleep(nanoseconds: UInt64(reconnectAttempts) * reconnectBackoffNanos)
        // The user may have stopped (or it was torn down) during the backoff.
        guard case .listening = state, capturing else { return }
        do {
            let client = try clientFactory()
            self.client = client
            // Feed the tail of what we have so the model resumes coherently across the
            // gap (≤50 chars per the docs); the next forwarded chunk carries it.
            let tail = Self.contextTail(of: committedText)
            if !tail.isEmpty { client.primePreviousText(tail) }
            startEventLoop(for: client)
        } catch {
            await teardown()
            setState(.error("\(error)"))
        }
    }

    /// The last whole words of `text`, capped to `maxChars`, trimmed to a word boundary
    /// so the model never gets a mid-word fragment as context.
    private static func contextTail(of text: String, maxChars: Int = 50) -> String {
        guard text.count > maxChars else { return text }
        let tail = String(text.suffix(maxChars))
        if let space = tail.firstIndex(of: " ") {
            return String(tail[tail.index(after: space)...])
        }
        return tail
    }

    private func forceFinish() async {
        if case .finalizing = state { await finishAndDeliver() }
    }

    private func finishAndDeliver() async {
        // Deliver EXACTLY once. This is reachable from two triggers — the `.committed`
        // handler and the finalize timeout (`forceFinish`). Because `teardown()` below
        // suspends, a second trigger could otherwise re-enter while we're still
        // `.finalizing` and paste the transcript twice. Leaving `.finalizing`
        // synchronously here — before any `await` — makes any re-entrant call a no-op.
        guard case .finalizing = state else { return }
        // Deliver committed text PLUS any uncommitted trailing partial. Using only
        // committedText here dropped the last words when the final commit didn't arrive
        // before the timeout — the "it doesn't always paste the tail" bug.
        let result = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        setState(.idle)
        await teardown()
        if !result.isEmpty { onResult?(result) }
    }

    private func teardown() async {
        eventTask?.cancel()
        eventTask = nil
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        await stopCapture()
        await client?.close()
        client = nil
        partial = ""
        committedText = ""
        reconnectAttempts = 0
    }
}
