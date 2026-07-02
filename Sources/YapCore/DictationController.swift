import Foundation

public protocol AudioCapturer: Sendable {
    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws
    func stop() async
    func waitForPendingAudioFlush(timeoutNanos: UInt64) async
}

public extension AudioCapturer {
    func waitForPendingAudioFlush(timeoutNanos: UInt64) async {}
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
    private var reconnecting = false
    private var pendingChunks: [Data] = []
    private var pendingChunkIndex = 0
    // True only while `start()` is bringing a session up. Its `await`s run with the
    // state already at `.listening`, so without this a second fast toggle would read
    // `.listening` and finalize a half-started session. Toggles are ignored meanwhile.
    private var starting = false
    // Monotonic session generation. Bumped by `start()` and `teardown()`. Long-running
    // async paths (finalize, reconnect, the finalize timeout) capture it at entry and
    // re-check after every suspension: on a mismatch they are STALE — a newer session
    // owns the mic/client/state now — and must return without touching anything.
    private var sessionEpoch = 0
    // True once THIS session's Finalize/commit control message actually went out. An
    // unsolicited provider auto-commit landing while `.finalizing` but before the commit
    // was sent must accumulate, NOT deliver — delivering early skips the flush and drops
    // the trailing words still in the pipeline.
    private var commitSent = false
    // Single-flight latch for `flushPendingChunks`: two loops interleaving on the actor
    // (reconnect drain vs live capture) corrupted the shared queue/index across their
    // `await sendChunk` suspensions — duplicate audio and a removeFirst trap.
    private var flushing = false

    private var committedText = ""
    private var partial = ""
    public private(set) var state: DictationState = .idle
    private var finishing = false

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
            // If a delivery is ALREADY in flight (`finishing`), let it land: starting a new
            // session while its teardown is mid-suspension would hand teardown the new
            // session's client/state to destroy.
            if finishing { return }
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
        guard state != newState else { return }
        state = newState
        onState?(newState)
    }

    private func start() async {
        starting = true
        defer { starting = false }
        sessionEpoch += 1
        commitSent = false
        committedText = ""
        partial = ""
        reconnectAttempts = 0
        pendingChunks.removeAll(keepingCapacity: true)
        pendingChunkIndex = 0
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
        pendingChunks.append(chunk)
        guard let client else { return }
        await flushPendingChunks(using: client)
    }

    private func finalize() async {
        // Everything below suspends repeatedly, and a tap during that time legitimately
        // delivers + restarts (the `.finalizing` toggle branch). The epoch pins this call
        // to ITS session: once it moves on, this finalize is stale and must not touch the
        // successor's capture, client, or timers — the old behavior stopped the NEW
        // session's mic and sent a Finalize on its client, so the next dictation recorded
        // nothing.
        let epoch = sessionEpoch
        setState(.finalizing)
        // Keep the mic open briefly so a word spoken right up to the keypress is still captured
        // (its audio isn't recorded yet at the instant of the press). Chunks keep flowing to the
        // live client during this window via `forwardChunk`.
        if trailingCaptureNanos > 0 { try? await Task.sleep(nanoseconds: trailingCaptureNanos) }
        guard epoch == sessionEpoch else { return }
        await stopCapture()
        guard epoch == sessionEpoch else { return }
        // Wait for the capture pipeline to hand off the last buffered audio before we
        // send the commit. This removes the fixed post-stop sleep when the buffer drains
        // quickly, but still bounds the wait by the configured flush budget.
        await capturer.waitForPendingAudioFlush(timeoutNanos: flushDelayNanos)
        guard epoch == sessionEpoch else { return }
        if let client {
            // Drain any backlog buffered during a reconnect gap first, so the commit
            // flushes ALL the audio — not just what happened to be sent already.
            await flushPendingChunks(using: client)
            guard epoch == sessionEpoch else { return }
        }
        if let client {
            do {
                try await client.sendCommit()
                guard epoch == sessionEpoch else { return }
                commitSent = true
            } catch {
                guard epoch == sessionEpoch else { return }
                // Don't discard a whole dictation if the final commit packet fails (e.g. the
                // socket just dropped): deliver whatever we've already accumulated.
                await finishAndDeliver()
                return
            }
        }
        // `client == nil` means a reconnect is mid-backoff: it checks `.finalizing` when
        // it lands and sends the deferred commit itself. The timeout below still bounds
        // the whole wait either way.
        guard epoch == sessionEpoch, case .finalizing = state else { return }
        // Safety net: if the final committed segment never arrives, finish with
        // whatever we have rather than hanging in `finalizing`.
        finalizeTimeoutTask = Task { [weak self, finalizeTimeoutNanos] in
            try? await Task.sleep(nanoseconds: finalizeTimeoutNanos)
            await self?.forceFinish(ifEpoch: epoch)
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
                // Deliver only once OUR commit went out: an unsolicited auto-commit landing
                // in the pre-commit window (stop right after a natural pause) must
                // accumulate — delivering early skips the Finalize flush and drops the
                // trailing words still in the pipeline.
                if commitSent { await finishAndDeliver() }
            } else if case .listening = state {
                setState(.listening(displayText))
            }
        case .failed(let error):
            // A dropped connection while still listening is recoverable: reconnect and
            // keep the mic running. Fatal errors (auth, quota, bad input) are not.
            if case .socketClosed = error {
                if case .listening = state, capturing {
                    await reconnect()
                } else if case .finalizing = state {
                    // The socket dropped during finalize — the realtime server commonly closes
                    // it right after the commit, sometimes before the final committed segment
                    // reaches us. Don't throw the dictation away with a "Connection closed"
                    // error: deliver what we've accumulated, same as the sendCommit-failure
                    // path and the finalize timeout.
                    await finishAndDeliver()
                }
                // Otherwise we've already left the session (delivered → .idle, or cancelled):
                // the server closing the socket afterwards is a NORMAL end-of-dictation close,
                // not a failure. Ignore it instead of flipping a finished dictation to `.error`.
            } else {
                Diag.conn.error("fatal stream error → stopping: \(String(describing: error), privacy: .public)")
                await failSession("\(error)")
            }
        }
    }

    /// Bring up a fresh connection after a transient drop, without stopping the mic.
    /// Gives up (→ error) after `maxReconnects` consecutive failures.
    private func reconnect() async {
        guard !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        let epoch = sessionEpoch
        reconnectAttempts += 1
        guard reconnectAttempts <= maxReconnects else {
            Diag.conn.error("reconnect gave up after \(self.maxReconnects) attempts — surfacing 'Connection closed'")
            await failSession("socketClosed")
            return
        }
        Diag.conn.error("stream dropped mid-dictation — reconnecting (attempt \(self.reconnectAttempts)/\(self.maxReconnects))")
        // Drop the dead client and its event loop; the mic keeps capturing (chunks are
        // harmlessly discarded while `client` is nil during the gap).
        eventTask?.cancel()
        eventTask = nil
        await client?.close()
        client = nil
        await backoffSleep(UInt64(reconnectAttempts) * reconnectBackoffNanos)
        // The user may have stopped (or it was torn down) during the backoff.
        guard epoch == sessionEpoch else { return }
        switch state {
        case .listening:
            guard capturing else { return }
        case .finalizing:
            // The mic already stopped, but the user's stop found `client == nil` and
            // deferred its commit to us — the tail still needs this connection.
            break
        default:
            return
        }
        do {
            let client = try clientFactory()
            self.client = client
            // Feed the tail of what we have so the model resumes coherently across the
            // gap (≤50 chars per the docs); the next forwarded chunk carries it.
            let tail = Self.contextTail(of: committedText)
            if !tail.isEmpty { client.primePreviousText(tail) }
            startEventLoop(for: client)
            await flushPendingChunks(using: client)
            guard epoch == sessionEpoch else { return }
            if case .finalizing = state, !commitSent {
                do {
                    try await client.sendCommit()
                    guard epoch == sessionEpoch else { return }
                    commitSent = true
                } catch {
                    guard epoch == sessionEpoch else { return }
                    await finishAndDeliver()
                }
            }
        } catch {
            guard epoch == sessionEpoch else { return }
            await failSession("\(error)")
        }
    }

    /// Sleep that survives running inside a just-cancelled task. `reconnect()` usually
    /// executes within the event-loop task it has itself cancelled, where a plain
    /// `Task.sleep` returns immediately — which silently turned the reconnect backoff
    /// into a storm of instant retries.
    private func backoffSleep(_ nanos: UInt64) async {
        guard nanos > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached {
                try? await Task.sleep(nanoseconds: nanos)
                continuation.resume()
            }
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

    private func forceFinish(ifEpoch epoch: Int) async {
        // The safety timer belongs to ONE session; a stale one (its session already
        // delivered while finalize was suspended) must not clip the next dictation.
        guard epoch == sessionEpoch, case .finalizing = state else { return }
        await finishAndDeliver()
    }

    private func finishAndDeliver() async {
        // Deliver EXACTLY once. This is reachable from two triggers — the `.committed`
        // handler and the finalize timeout (`forceFinish`). Because `teardown()` below
        // suspends, a second trigger could otherwise re-enter while we're still
        // `.finalizing` and paste the transcript twice. The `finishing` latch makes any
        // re-entrant call a no-op before the first one reaches the suspension point.
        guard case .finalizing = state, !finishing else { return }
        finishing = true
        defer { finishing = false }
        // Deliver committed text PLUS any uncommitted trailing partial. Using only
        // committedText here dropped the last words when the final commit didn't arrive
        // before the timeout — the "it doesn't always paste the tail" bug.
        let result = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        await teardown()
        let epoch = sessionEpoch
        if !result.isEmpty {
            let handler = onResult
            await MainActor.run { handler?(result) }
            // A new session may have started while we delivered on the main actor —
            // its `.listening` must not be clobbered back to `.idle`.
            guard epoch == sessionEpoch else { return }
        }
        setState(.idle)
    }

    /// Tear the session down surfacing `message` — but never at the price of the user's
    /// words: whatever was accumulated is delivered first, THEN the error is shown.
    /// Discarding minutes of dictation because the stream died was itself a data loss.
    private func failSession(_ message: String) async {
        let salvaged = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        await teardown()
        let epoch = sessionEpoch
        if !salvaged.isEmpty {
            let handler = onResult
            await MainActor.run { handler?(salvaged) }
            guard epoch == sessionEpoch else { return }
        }
        setState(.error(message))
    }

    private func teardown() async {
        // A successor session can start while the awaits below are in flight. Bump the
        // epoch and detach everything SYNCHRONOUSLY first, so nothing this teardown
        // still does can touch what the successor sets up.
        sessionEpoch += 1
        eventTask?.cancel()
        eventTask = nil
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        let oldClient = client
        client = nil
        partial = ""
        committedText = ""
        reconnectAttempts = 0
        pendingChunks.removeAll(keepingCapacity: true)
        pendingChunkIndex = 0
        await stopCapture()
        await oldClient?.close()
    }

    private func flushPendingChunks(using client: TranscriptionClient) async {
        // Single-flight: a second caller (live capture vs reconnect drain) returns
        // immediately — the running loop re-reads `pendingChunks.count` each pass and
        // picks up anything appended meanwhile. Interleaved loops shared the queue and
        // index across `await` and double-sent chunks / trapped in removeFirst.
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while pendingChunkIndex < pendingChunks.count {
            // A reconnect/teardown can swap the client while we're suspended in send:
            // this loop then belongs to a dead connection — bail and let the new
            // client's own flush take over (indices are shared, so touching them from
            // a stale loop corrupts the live one).
            guard self.client === client else { return }
            let next = pendingChunks[pendingChunkIndex]
            do {
                try await client.sendChunk(next)
                pendingChunkIndex += 1
            } catch {
                guard self.client === client else { return }
                Diag.conn.error("chunk send failed → reconnecting: \(Diag.describe(error), privacy: .public)")
                if capturing || isFinalizing { await reconnect() }
                return
            }
        }
        if pendingChunkIndex > 0 {
            pendingChunks.removeFirst(pendingChunkIndex)
            pendingChunkIndex = 0
        }
    }

    private var isFinalizing: Bool {
        if case .finalizing = state { return true }
        return false
    }
}
