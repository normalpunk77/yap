import XCTest
@testable import YapCore

final class FakeCapturer: AudioCapturer, @unchecked Sendable {
    var startCount = 0
    var stopCount = 0
    var onChunk: (@Sendable (Data) async -> Void)?
    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws {
        startCount += 1; self.onChunk = onChunk
    }
    func stop() async { stopCount += 1 }
}

/// A capturer whose `start` blocks until `release()` — lets a test hold a session in
/// its startup window and fire a second toggle into it deterministically.
final class GateCapturer: AudioCapturer, @unchecked Sendable {
    private let q = DispatchQueue(label: "gate")
    private var _startCount = 0
    private var _stopCount = 0
    private var cont: CheckedContinuation<Void, Never>?
    private var released = false

    var startCount: Int { q.sync { _startCount } }
    var stopCount: Int { q.sync { _stopCount } }

    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws {
        q.sync { _startCount += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = q.sync { () -> Bool in
                if released { return true }
                cont = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }
    func stop() async { q.sync { _stopCount += 1 } }
    func release() {
        let c: CheckedContinuation<Void, Never>? = q.sync {
            released = true
            let pending = cont
            cont = nil
            return pending
        }
        c?.resume()
    }
}

final class FlushGateCapturer: AudioCapturer, @unchecked Sendable {
    private let q = DispatchQueue(label: "flush.gate")
    private var _stopCount = 0
    private var flushCont: CheckedContinuation<Void, Never>?
    private var flushReleased = false

    var stopCount: Int { q.sync { _stopCount } }

    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws {}
    func stop() async { q.sync { _stopCount += 1 } }
    func waitForPendingAudioFlush(timeoutNanos: UInt64) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = q.sync { () -> Bool in
                if flushReleased { return true }
                flushCont = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }
    func releaseFlush() {
        let c: CheckedContinuation<Void, Never>? = q.sync {
            flushReleased = true
            let pending = flushCont
            flushCont = nil
            return pending
        }
        c?.resume()
    }
}

final class ScriptedClient: TranscriptionClient, @unchecked Sendable {
    private let cont: AsyncStream<TranscriptEvent>.Continuation
    private let stream: AsyncStream<TranscriptEvent>
    private(set) var commits = 0
    private(set) var chunks = 0
    private(set) var closes = 0
    private(set) var primedText: String?
    var chunkError: Error?
    var commitError: Error?
    init() { (stream, cont) = AsyncStream.makeStream() }
    func emit(_ e: TranscriptEvent) { cont.yield(e) }
    func sendChunk(_ pcm16: Data) async throws {
        chunks += 1
        if let chunkError { throw chunkError }
    }
    func sendCommit() async throws { commits += 1; if let commitError { throw commitError } }
    func close() async { closes += 1 }
    func primePreviousText(_ text: String) { primedText = text }
    func events() -> AsyncStream<TranscriptEvent> { stream }
}

/// A client whose `sendChunk` blocks until `releaseAll()` — holds a flush loop suspended
/// mid-send so a test can prove a second flush can't interleave on the same queue state.
final class GatedChunkClient: TranscriptionClient, @unchecked Sendable {
    private let q = DispatchQueue(label: "gated.chunks")
    private let stream: AsyncStream<TranscriptEvent>
    private let cont: AsyncStream<TranscriptEvent>.Continuation
    private var pendingSends: [CheckedContinuation<Void, Never>] = []
    private var gated = true
    private var _sent: [Data] = []
    var sent: [Data] { q.sync { _sent } }
    init() { (stream, cont) = AsyncStream.makeStream() }
    func sendChunk(_ pcm16: Data) async throws {
        let wait: Bool = q.sync {
            if gated { return true }
            _sent.append(pcm16)
            return false
        }
        guard wait else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.sync { pendingSends.append(c) }
        }
        q.sync { _sent.append(pcm16) }
    }
    func releaseAll() {
        let conts: [CheckedContinuation<Void, Never>] = q.sync {
            gated = false
            let pending = pendingSends
            pendingSends = []
            return pending
        }
        for c in conts { c.resume() }
    }
    func sendCommit() async throws {}
    func close() async {}
    func primePreviousText(_ text: String) {}
    func events() -> AsyncStream<TranscriptEvent> { stream }
}

/// Hands out a fresh `ScriptedClient` per `make()` and keeps them so a test can drive
/// each connection (used for reconnection tests).
final class ClientFactory: @unchecked Sendable {
    private let q = DispatchQueue(label: "factory")
    private var _clients: [ScriptedClient] = []
    var clients: [ScriptedClient] { q.sync { _clients } }
    func make() -> ScriptedClient {
        let c = ScriptedClient()
        q.sync { _clients.append(c) }
        return c
    }
}

final class DictationControllerTests: XCTestCase {
    func testFullHappyPath() async throws {
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)

        let states = StateRecorder()
        let result = ResultBox()
        await controller.setHandlers(
            onState: { s in states.append(s) },
            onResult: { t in result.set(t) }
        )

        await controller.toggle() // idle -> listening
        client.emit(.partial("ci"))
        client.emit(.partial("ciao"))
        try await Task.sleep(nanoseconds: 20_000_000)
        let s1 = await controller.state
        XCTAssertEqual(s1, .listening("ciao"))
        XCTAssertEqual(capturer.startCount, 1)

        await controller.toggle() // listening -> finalizing
        client.emit(.committed("ciao mondo"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(capturer.stopCount, 1)
        XCTAssertEqual(client.commits, 1)
        XCTAssertEqual(result.value, "ciao mondo")
        let sEnd = await controller.state
        XCTAssertEqual(sEnd, .idle)
        // The transport must be closed on teardown — no connection left dangling.
        XCTAssertGreaterThanOrEqual(client.closes, 1)
    }

    func testFinalizeDeliversResultBeforeReturningToIdle() async throws {
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let events = TraceLog()

        await controller.setHandlers(
            onState: { state in
                switch state {
                case .idle:
                    events.append("state:idle")
                case .listening:
                    events.append("state:listening")
                case .finalizing:
                    events.append("state:finalizing")
                case .error:
                    events.append("state:error")
                }
            },
            onResult: { _ in events.append("result") }
        )

        await controller.toggle()
        await controller.toggle()
        client.emit(.committed("ciao mondo"))
        try await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = events.all
        guard let resultIndex = snapshot.firstIndex(of: "result"),
              let idleIndex = snapshot.lastIndex(of: "state:idle") else {
            return XCTFail("missing expected events: \(snapshot)")
        }
        XCTAssertLessThan(resultIndex, idleIndex)
    }

    func testDuplicatePartialDoesNotReemitSameListeningState() async throws {
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let states = StateRecorder()
        await controller.setHandlers(onState: { states.append($0) }, onResult: { _ in })

        await controller.toggle()
        client.emit(.partial("hello"))
        client.emit(.partial("hello"))
        try await waitFor { await controller.state == .listening("hello") }

        let listeningStates = states.all.filter {
            if case .listening("hello") = $0 { return true }
            return false
        }
        XCTAssertEqual(listeningStates.count, 1)
    }

    func testErrorEventMovesToErrorState() async throws {
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })
        await controller.toggle()
        client.emit(.failed(.authenticationFailed))
        try await Task.sleep(nanoseconds: 20_000_000)
        let s = await controller.state
        if case .error = s {} else { XCTFail("expected error state, got \(s)") }
        // Even on the error path the transport is closed during teardown.
        XCTAssertGreaterThanOrEqual(client.closes, 1)
    }

    func testChunkSendFailureReconnectsInsteadOfDroppingSession() async throws {
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(capturer: capturer, clientFactory: { factory.make() },
                                             flushDelaySeconds: 0, reconnectBackoffSeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        await controller.toggle()
        factory.clients[0].chunkError = TranscriptionError.socketClosed
        await capturer.onChunk?(Data([0x01, 0x02, 0x03]))

        try await waitFor { factory.clients.count == 2 }
        let s = await controller.state
        XCTAssertEqual(s, .listening(""))
        XCTAssertEqual(factory.clients[0].chunks, 1)
    }

    func testChunkSendFailureBuffersAudioDuringReconnectGap() async throws {
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(
            capturer: capturer, clientFactory: { factory.make() },
            flushDelaySeconds: 0, reconnectBackoffSeconds: 0.05)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        await controller.toggle()
        factory.clients[0].chunkError = TranscriptionError.socketClosed
        await capturer.onChunk?(Data([0x01, 0x02, 0x03]))
        try await Task.sleep(nanoseconds: 1_000_000)
        await capturer.onChunk?(Data([0x04, 0x05, 0x06]))

        try await waitFor { factory.clients.count == 2 }
        try await waitFor { factory.clients.last?.chunks == 2 }
        let s = await controller.state
        XCTAssertEqual(s, .listening(""))
        XCTAssertEqual(factory.clients[0].chunks, 1)
    }

    func testRapidSecondToggleDuringStartupIsIgnored() async throws {
        // Regression: a fast second ⌥S while a session was still starting up read the
        // already-set `.listening` state and finalized a half-started session. It must
        // be debounced — the session comes up cleanly and stays listening.
        let capturer = GateCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client },
                                             flushDelaySeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        let starting = Task { await controller.toggle() }   // start → blocks in capturer.start
        var waited = 0
        while capturer.startCount == 0 && waited < 200 {
            try await Task.sleep(nanoseconds: 2_000_000); waited += 1
        }
        await controller.toggle()        // second tap mid-startup — must be ignored
        capturer.release()
        await starting.value
        try await Task.sleep(nanoseconds: 10_000_000)

        let s = await controller.state
        XCTAssertEqual(s, .listening(""))   // healthy session, NOT finalizing
        XCTAssertEqual(capturer.startCount, 1)
        XCTAssertEqual(capturer.stopCount, 0)
    }

    func testFinalizeNeverDeliversTwice() async throws {
        // Regression: dictation pasted the SAME transcript twice. `finishAndDeliver` is
        // reachable from both the `.committed` handler and the finalize timeout
        // (`forceFinish`); with the `await teardown()` suspension they could race and
        // both call onResult. The race is narrow, so we stress it many times — buggy
        // code double-delivers on some iterations; the fix delivers exactly once always.
        for _ in 0 ..< 200 {
            let capturer = FakeCapturer()
            let client = ScriptedClient()
            let controller = DictationController(
                capturer: capturer, clientFactory: { client },
                flushDelaySeconds: 0, finalizeTimeoutSeconds: 0)
            let result = ResultBox()
            await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

            await controller.toggle()              // listening
            await controller.toggle()              // finalize → timeout fires ~immediately
            client.emit(.committed("hello world"))  // tail segment races the timeout
            try await Task.sleep(nanoseconds: 2_000_000)

            XCTAssertLessThanOrEqual(result.count, 1, "delivered \(result.count) times")
        }
    }

    func testCommitFailureDeliversAccumulatedText() async throws {
        // If the final commit packet fails (socket just dropped), the accumulated
        // transcript must still be delivered — not thrown away as an error.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        client.commitError = TranscriptionError.socketClosed
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                    // listening
        client.emit(.committed("hello world"))        // accumulated before stop
        try await Task.sleep(nanoseconds: 20_000_000)
        await controller.toggle()                     // finalize → sendCommit throws

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(result.value, "hello world")   // delivered, not lost
        let end = await controller.state
        XCTAssertEqual(end, .idle)                    // graceful, not .error
    }

    func testPressDuringFinalizeDeliversAndRestartsImmediately() async throws {
        // Regression (perceived "cooldown"): after stop the controller stays `.finalizing` for
        // up to the safety timeout. A tap during that window used to be swallowed, so the second
        // dictation wouldn't start until the timeout elapsed. It must instead deliver the
        // accumulated text and bring up a fresh session right away.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(
            capturer: capturer, clientFactory: { factory.make() },
            flushDelaySeconds: 0, finalizeTimeoutSeconds: 3.0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                                  // listening; client[0]
        factory.clients[0].emit(.committed("first round"))
        try await waitFor { await controller.state == .listening("first round") }
        await controller.toggle()                                  // finalize (no tail arrives)
        await controller.toggle()                                  // tap again → deliver + restart

        XCTAssertEqual(result.value, "first round")                // round 1 delivered, not stuck
        let s = await controller.state
        XCTAssertEqual(s, .listening(""))                          // round 2 live immediately
        XCTAssertEqual(capturer.startCount, 2)                     // started again — no cooldown
    }

    func testSocketClosedDuringFinalizeDeliversAccumulatedText() async throws {
        // Regression ("Connection closed" + lost dictation): the realtime server often
        // closes the socket right after the commit — sometimes the `.socketClosed` event
        // lands while we're `.finalizing`, BEFORE the final committed segment. That drop is
        // NOT recoverable-by-reconnect (we're stopping, not listening), but it must still
        // deliver what we've accumulated — like the sendCommit-failure path and the timeout —
        // not surface an error and throw the whole transcript away.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                       // listening
        client.emit(.committed("hello world"))           // accumulated before stop
        try await waitFor { await controller.state == .listening("hello world") }
        await controller.toggle()                        // finalize → arms the timeout
        client.emit(.failed(.socketClosed))              // server drops the socket post-commit
        try await waitFor { result.value != nil }

        XCTAssertEqual(result.value, "hello world")      // delivered, not lost
        let end = await controller.state
        XCTAssertEqual(end, .idle)                       // graceful, not .error
    }

    func testFinalizeDeliversCommittedPlusTrailingPartial() async throws {
        // Regression: stopping with an uncommitted tail still in `partial`, when no final
        // committed segment arrives before the timeout, must deliver committed + partial —
        // not just the committed part (which silently dropped the last words).
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(
            capturer: capturer, clientFactory: { client },
            flushDelaySeconds: 0, finalizeTimeoutSeconds: 0.1)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()             // listening
        client.emit(.committed("hello"))       // committed segment
        client.emit(.partial("world"))         // uncommitted tail, never committed
        // Wait until BOTH events are processed (deterministic — no fixed sleep, so it can't
        // race the async event loop on a slow CI runner, which made this test flaky).
        try await waitFor { await controller.state == .listening("hello world") }
        await controller.toggle()              // finalize; no further committed arrives
        // Wait for the actual DELIVERY, not just `.idle` — finishAndDeliver sets .idle
        // before calling onResult (a teardown awaits in between), so polling state raced.
        try await waitFor { result.value != nil }

        XCTAssertEqual(result.value, "hello world")    // tail kept, not dropped
    }

    /// Poll `cond` until true (or fail). Replaces brittle fixed-duration sleeps in async
    /// timing tests: returns as soon as the expected state is reached, robust under CI load.
    private func waitFor(tries: Int = 300, stepNanos: UInt64 = 10_000_000,
                         _ cond: () async -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< tries {
            if await cond() { return }
            try await Task.sleep(nanoseconds: stepNanos)
        }
        XCTFail("waitFor: condition not met in time", file: file, line: line)
    }

    func testFinalizeWaitsForLateFlushResult() async throws {
        // Regression: the last words spoken right before stop arrive from the provider only
        // AFTER the user toggles stop — Deepgram returns them as the `Finalize` flush result a
        // few hundred ms later. The default finalize timeout must be generous enough to wait for
        // that result; a too-short default (the 0.4s regression) fired `forceFinish` first,
        // delivered nothing/partial, then DISCARDED the late committed → dropped tail. Uses the
        // DEFAULT timeout on purpose: the default itself was the bug.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()   // listening
        await controller.toggle()   // finalize → arms the default timeout
        // Simulate Deepgram's flush round-trip: the final segment lands ~0.5s after stop —
        // longer than the old 0.4s default that truncated, well within a correct one.
        try await Task.sleep(nanoseconds: 500_000_000)
        client.emit(.committed("hello from the tail"))
        try await waitFor { result.value != nil }

        XCTAssertEqual(result.value, "hello from the tail")   // tail kept, not dropped
    }

    func testTrailingCaptureKeepsMicOpenBeforeStop() async throws {
        // The mic must keep recording for `trailingCaptureSeconds` AFTER the stop toggle, so a
        // word spoken right up to the keypress is still captured. Without it, capture stops
        // instantly and that last word's audio is lost.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(
            capturer: capturer, clientFactory: { client },
            trailingCaptureSeconds: 0.2, flushDelaySeconds: 0, finalizeTimeoutSeconds: 0.1)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        await controller.toggle()                       // listening
        let finishing = Task { await controller.toggle() }  // finalize: holds the mic open
        try await Task.sleep(nanoseconds: 60_000_000)   // 60ms — inside the 200ms trailing window
        XCTAssertEqual(capturer.stopCount, 0)           // mic still capturing the tail
        await finishing.value
        XCTAssertEqual(capturer.stopCount, 1)           // stopped only after the window
    }

    func testFinalizeWaitsForPendingAudioFlushBeforeCommit() async throws {
        let capturer = FlushGateCapturer()
        let client = ScriptedClient()
        let controller = DictationController(
            capturer: capturer, clientFactory: { client },
            flushDelaySeconds: 0, finalizeTimeoutSeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        await controller.toggle()   // listening
        let finalizing = Task { await controller.toggle() }

        try await waitFor { capturer.stopCount == 1 }
        XCTAssertEqual(client.commits, 0, "commit must not be sent before the audio flush completes")

        capturer.releaseFlush()
        await finalizing.value

        XCTAssertEqual(client.commits, 1)
    }

    func testReconnectsOnSocketClosedAndPrimesContext() async throws {
        // A mid-listening connection drop must reconnect (not error), keep the accumulated
        // text, and hand the new connection the context tail so the model resumes coherently.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(capturer: capturer, clientFactory: { factory.make() },
                                             flushDelaySeconds: 0, reconnectBackoffSeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        await controller.toggle()                          // listening; client[0]
        factory.clients[0].emit(.committed("hello world"))
        try await Task.sleep(nanoseconds: 20_000_000)
        factory.clients[0].emit(.failed(.socketClosed))    // network drop
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(factory.clients.count, 2)           // a fresh connection came up
        let s = await controller.state
        XCTAssertEqual(s, .listening("hello world"))       // still listening, text kept
        XCTAssertEqual(factory.clients[1].primedText, "hello world")  // context handed over
    }

    func testGivesUpAfterMaxReconnects() async throws {
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(capturer: capturer, clientFactory: { factory.make() },
                                             flushDelaySeconds: 0, reconnectBackoffSeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })
        await controller.toggle()   // listening; client[0]

        // Drop every connection that comes up. After maxReconnects consecutive failures
        // it must give up with an error instead of reconnecting forever.
        for _ in 0 ..< 6 {
            if case .error = await controller.state { break }
            let count = factory.clients.count
            factory.clients.last?.emit(.failed(.socketClosed))
            var waited = 0
            while waited < 60 {
                try await Task.sleep(nanoseconds: 5_000_000)
                if factory.clients.count > count { break }
                if case .error = await controller.state { break }
                waited += 1
            }
        }

        let s = await controller.state
        if case .error = s {} else { XCTFail("expected error after max reconnects, got \(s)") }
        XCTAssertLessThanOrEqual(factory.clients.count, 4)   // initial + at most 3 reconnects
    }

    func testFatalErrorDeliversAccumulatedTranscriptBeforeError() async throws {
        // A fatal mid-session error (quota, auth, session limit) must not throw away
        // what the user already dictated: deliver the accumulated text, THEN error.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                        // listening
        client.emit(.committed("two minutes of speech"))
        try await waitFor { await controller.state == .listening("two minutes of speech") }
        client.emit(.failed(.quotaExceeded))             // fatal mid-session
        try await waitFor { result.value != nil }

        XCTAssertEqual(result.value, "two minutes of speech")   // salvaged, not discarded
        let s = await controller.state
        if case .error = s {} else { XCTFail("expected error state, got \(s)") }
    }

    func testConcurrentChunkForwardsSendEachChunkExactlyOnceInOrder() async throws {
        // Regression: two flush loops interleaving on the actor (reconnect drain vs live
        // capture) shared pendingChunks/pendingChunkIndex across `await sendChunk` — the
        // same chunk went out twice and the final compaction could trap in removeFirst.
        let capturer = FakeCapturer()
        let client = GatedChunkClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })
        await controller.toggle()

        let first = Task { await capturer.onChunk?(Data([0x01])) }   // suspends in gated send
        try await Task.sleep(nanoseconds: 30_000_000)
        let second = Task { await capturer.onChunk?(Data([0x02])) }  // arrives mid-suspension
        try await Task.sleep(nanoseconds: 30_000_000)
        client.releaseAll()
        _ = await first.value
        _ = await second.value
        try await waitFor { client.sent.count >= 2 }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(client.sent, [Data([0x01]), Data([0x02])])   // each chunk exactly once
    }

    func testToggleDuringTrailingCaptureWindowStartsCleanSecondSession() async throws {
        // Regression: a second tap while finalize() slept in the trailing-capture window
        // delivered + restarted, but the STALE finalize then resumed and sabotaged the new
        // session — stopped its mic and sent a Finalize on its client. The next dictation
        // recorded nothing.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(
            capturer: capturer, clientFactory: { factory.make() },
            trailingCaptureSeconds: 0.25, flushDelaySeconds: 0, finalizeTimeoutSeconds: 1.0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                                  // session 1 listening
        factory.clients[0].emit(.committed("first"))
        try await waitFor { await controller.state == .listening("first") }
        let finalizing = Task { await controller.toggle() }        // sleeps in trailing window
        try await Task.sleep(nanoseconds: 60_000_000)              // inside the 250ms window
        await controller.toggle()                                  // tap again → deliver + restart
        try await waitFor { await controller.state == .listening("") }
        await finalizing.value                                     // stale finalize resumes now
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(result.value, "first")
        XCTAssertEqual(capturer.startCount, 2)
        XCTAssertEqual(capturer.stopCount, 1)           // stale finalize must NOT stop mic #2
        let s = await controller.state
        XCTAssertEqual(s, .listening(""))               // session 2 healthy and live
        XCTAssertEqual(factory.clients.count, 2)
        XCTAssertEqual(factory.clients[1].commits, 0)   // no stray Finalize on its client
    }

    func testUnsolicitedCommitDuringPreCommitWindowDoesNotDeliverEarly() async throws {
        // Regression: a provider auto-commit landing between the stop toggle and our
        // Finalize send delivered immediately — skipping the flush that transcribes the
        // trailing words. It must accumulate and deliver only after the real commit.
        let capturer = FlushGateCapturer()
        let client = ScriptedClient()
        let controller = DictationController(
            capturer: capturer, clientFactory: { client },
            flushDelaySeconds: 1.0, finalizeTimeoutSeconds: 2.0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                    // listening
        client.emit(.committed("hello"))
        try await waitFor { await controller.state == .listening("hello") }
        let finalizing = Task { await controller.toggle() }   // blocks in the flush gate
        try await waitFor { capturer.stopCount == 1 }
        client.emit(.committed("world"))             // auto-commit in the pre-commit window
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(result.value, "must not deliver before the Finalize commit is sent")
        XCTAssertEqual(client.commits, 0)

        capturer.releaseFlush()                      // finalize proceeds: sends the commit
        await finalizing.value
        try await waitFor { client.commits == 1 }
        client.emit(.committed("tail"))              // Finalize flush result
        try await waitFor { result.value != nil }
        XCTAssertEqual(result.value, "hello world tail")
    }

    func testSocketDropReconnectHonorsBackoffDelay() async throws {
        // Regression: reconnect() runs inside the event-loop task it has just cancelled,
        // so its `Task.sleep` backoff returned IMMEDIATELY (cancelled context) — reconnect
        // attempts fired back-to-back instead of backing off.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(capturer: capturer, clientFactory: { factory.make() },
                                             flushDelaySeconds: 0, reconnectBackoffSeconds: 0.3)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })
        await controller.toggle()
        factory.clients[0].emit(.failed(.socketClosed))
        try await Task.sleep(nanoseconds: 100_000_000)     // well inside the 300ms backoff
        XCTAssertEqual(factory.clients.count, 1, "reconnect must wait out the backoff, not retry instantly")
        try await waitFor { factory.clients.count == 2 }   // then it does come up
    }

    func testStopDuringReconnectBackoffCommitsOnNewConnectionAndKeepsTail() async throws {
        // Regression: stopping while a reconnect was in its backoff hit `client == nil`,
        // so sendCommit silently "succeeded" and the reconnect bailed on `capturing ==
        // false` — the Finalize never went out and the tail was lost to the timeout.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(
            capturer: capturer, clientFactory: { factory.make() },
            flushDelaySeconds: 0, finalizeTimeoutSeconds: 2.0, reconnectBackoffSeconds: 0.2)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                          // listening; clients[0]
        factory.clients[0].emit(.committed("hello"))
        try await waitFor { await controller.state == .listening("hello") }
        factory.clients[0].emit(.failed(.socketClosed))    // drop → reconnect, 200ms backoff
        try await Task.sleep(nanoseconds: 40_000_000)      // inside the gap (client == nil)
        let finalizing = Task { await controller.toggle() }  // user stops during the gap
        try await waitFor { factory.clients.count == 2 }      // reconnect still lands
        try await waitFor { factory.clients[1].commits == 1 } // and sends the deferred Finalize
        factory.clients[1].emit(.committed("tail"))           // flush result arrives
        try await waitFor { result.value != nil }
        await finalizing.value
        XCTAssertEqual(result.value, "hello tail")
    }

    func testStaleFinalizeTimerFromDeliveredSessionCannotClipTheNextOne() async throws {
        // Regression: finalize() resuming AFTER its session was already delivered (socket
        // dropped during the flush wait) armed a safety timer anyway. That stale timer
        // then force-finished the NEXT session mid-finalize, clipping its tail.
        let capturer = FlushGateCapturer()
        let factory = ClientFactory()
        let controller = DictationController(
            capturer: capturer, clientFactory: { factory.make() },
            flushDelaySeconds: 1.0, finalizeTimeoutSeconds: 0.8)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                          // session 1; clients[0]
        factory.clients[0].emit(.committed("one"))
        try await waitFor { await controller.state == .listening("one") }
        let finalizing = Task { await controller.toggle() }   // blocks in flush gate
        try await waitFor { capturer.stopCount == 1 }
        factory.clients[0].emit(.failed(.socketClosed))    // drop during finalize → deliver now
        try await waitFor { result.value == "one" }
        capturer.releaseFlush()                            // stale finalize resumes post-delivery
        await finalizing.value                             // buggy code arms a stale 0.8s timer

        await controller.toggle()                          // session 2 (gate stays released)
        factory.clients[1].emit(.committed("second"))
        try await waitFor { await controller.state == .listening("second") }
        try await Task.sleep(nanoseconds: 300_000_000)     // run into the stale-timer window
        let secondFinalize = Task { await controller.toggle() }
        try await Task.sleep(nanoseconds: 600_000_000)     // past the stale fire, before our own
        factory.clients[1].emit(.committed("tail"))        // session 2's flush result
        try await waitFor { result.value != nil && result.value != "one" }
        await secondFinalize.value

        XCTAssertEqual(result.value, "second tail")        // tail kept — not clipped early
    }

    func testEmptyFinalizeAckDoesNotWipeAnOutstandingPartial() async throws {
        // Regression guard: a partial left over from a DEAD connection (its final never
        // arrived; its audio was already compacted away, so the new connection can't
        // re-transcribe it) must survive an empty Finalize ack — wiping it delivered
        // committedText only and dropped real words.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(
            capturer: capturer, clientFactory: { factory.make() },
            flushDelaySeconds: 0, finalizeTimeoutSeconds: 2.0, reconnectBackoffSeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()
        factory.clients[0].emit(.committed("hello"))
        factory.clients[0].emit(.partial("world"))
        try await waitFor { await controller.state == .listening("hello world") }
        factory.clients[0].emit(.failed(.socketClosed))     // drop: partial survives locally
        try await waitFor { factory.clients.count == 2 }
        await controller.toggle()                            // stop; only silence in the gap
        try await waitFor { factory.clients[1].commits == 1 }
        factory.clients[1].emit(.committed(""))              // empty Finalize ack
        try await waitFor { result.value != nil }

        XCTAssertEqual(result.value, "hello world")          // partial kept, not wiped
    }

    func testCaptureFailureSalvagesTranscriptAndSurfacesError() async throws {
        // The mic can die irrecoverably mid-dictation (device unplugged, session can't
        // restart). The controller must not sit in `.listening` on a dead mic: salvage
        // what was dictated, then surface the error.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle()                    // listening
        client.emit(.committed("hello"))
        try await waitFor { await controller.state == .listening("hello") }
        await controller.captureFailed()

        XCTAssertEqual(result.value, "hello")        // salvaged
        let s = await controller.state
        if case .error = s {} else { XCTFail("expected error state, got \(s)") }
    }

    func testAudioBacklogIsCappedWhileDisconnected() async throws {
        // With the socket gone (reconnect backoff) chunks buffer in memory. The backlog
        // must be bounded — shed the OLDEST — so a wedged connection can't grow forever.
        let capturer = FakeCapturer()
        let factory = ClientFactory()
        let controller = DictationController(capturer: capturer, clientFactory: { factory.make() },
                                             flushDelaySeconds: 0, reconnectBackoffSeconds: 1.5)
        await controller.setHandlers(onState: { _ in }, onResult: { _ in })

        await controller.toggle()
        factory.clients[0].emit(.failed(.socketClosed))   // → reconnect, 1.5s backoff
        try await Task.sleep(nanoseconds: 50_000_000)     // let the client drop to nil
        let overCap = DictationController.maxBufferedChunks + 50
        for i in 0 ..< overCap {                          // buffered, nothing to send to
            await capturer.onChunk?(Data([UInt8(i % 256)]))
        }
        try await waitFor { factory.clients.count == 2 }  // reconnect lands and drains
        try await waitFor { factory.clients[1].chunks == DictationController.maxBufferedChunks }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.clients[1].chunks, DictationController.maxBufferedChunks)
    }

    func testUnsolicitedCommitAccumulatesAndDoesNotStop() async throws {
        // ElevenLabs auto-commits on pauses / every ~90s. Those segments must be
        // accumulated and the session must keep running — only the user's second
        // toggle finalizes and delivers the full text.
        let capturer = FakeCapturer()
        let client = ScriptedClient()
        let controller = DictationController(capturer: capturer, clientFactory: { client }, flushDelaySeconds: 0)
        let result = ResultBox()
        await controller.setHandlers(onState: { _ in }, onResult: { t in result.set(t) })

        await controller.toggle() // listening
        client.emit(.partial("hello"))
        client.emit(.committed("hello world")) // unsolicited auto-commit
        try await Task.sleep(nanoseconds: 20_000_000)

        // Did NOT paste, still listening with accumulated text shown.
        XCTAssertNil(result.value)
        let mid = await controller.state
        XCTAssertEqual(mid, .listening("hello world"))

        await controller.toggle() // user stops -> finalize
        client.emit(.committed("how are you")) // tail segment from our commit
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(result.value, "hello world how are you")
        let end = await controller.state
        XCTAssertEqual(end, .idle)
    }
}

final class StateRecorder: @unchecked Sendable {
    private let q = DispatchQueue(label: "rec")
    private var items: [DictationState] = []
    func append(_ s: DictationState) { q.sync { items.append(s) } }
    var all: [DictationState] { q.sync { items } }
}
final class ResultBox: @unchecked Sendable {
    private let q = DispatchQueue(label: "res")
    private var v: String?
    private var n = 0
    func set(_ t: String) { q.sync { v = t; n += 1 } }
    var value: String? { q.sync { v } }
    var count: Int { q.sync { n } }
}

final class TraceLog: @unchecked Sendable {
    private let q = DispatchQueue(label: "events")
    private var items: [String] = []

    func append(_ value: String) { q.sync { items.append(value) } }
    var all: [String] { q.sync { items } }
}
