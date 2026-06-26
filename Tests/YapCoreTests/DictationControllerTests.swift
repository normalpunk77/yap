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

final class ScriptedClient: TranscriptionClient, @unchecked Sendable {
    private let cont: AsyncStream<TranscriptEvent>.Continuation
    private let stream: AsyncStream<TranscriptEvent>
    private(set) var commits = 0
    private(set) var chunks = 0
    private(set) var closes = 0
    private(set) var primedText: String?
    var commitError: Error?
    init() { (stream, cont) = AsyncStream.makeStream() }
    func emit(_ e: TranscriptEvent) { cont.yield(e) }
    func sendChunk(_ pcm16: Data) async throws { chunks += 1 }
    func sendCommit() async throws { commits += 1; if let commitError { throw commitError } }
    func close() async { closes += 1 }
    func primePreviousText(_ text: String) { primedText = text }
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
