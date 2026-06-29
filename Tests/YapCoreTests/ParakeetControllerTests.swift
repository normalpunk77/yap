import AppKit
import XCTest
@testable import YapApp

@MainActor
final class ParakeetControllerTests: XCTestCase {
    final class FakeClipboard: ClipboardReading {
        var changeCount = 0
        var value = ""
        func string(forType type: NSPasteboard.PasteboardType) -> String? { value }
    }

    final class FakeManager: ParakeetManaging {
        var isReady = true
        var ensureCalls = 0
        var commandCalls: [String] = []
        var startResult = true
        var stopResult = true
        var stopDaemonCalls = 0
        var onStop: (() -> Void)?

        func ensureDaemonRunning() async throws { ensureCalls += 1 }

        func sendDaemonCommand(_ command: String) -> Bool {
            commandCalls.append(command)
            if command == "stop" { onStop?() }
            return command == "start" ? startResult : stopResult
        }

        func stopDaemon() { stopDaemonCalls += 1 }
    }

    final class GateManager: ParakeetManaging, @unchecked Sendable {
        var isReady = true
        var ensureCalls = 0
        var commandCalls: [String] = []
        var startResult = true
        private let q = DispatchQueue(label: "gate.manager")
        private var cont: CheckedContinuation<Void, Never>?

        func ensureDaemonRunning() async throws {
            q.sync { ensureCalls += 1 }
            await withCheckedContinuation { c in q.sync { cont = c } }
        }

        func release() {
            let c: CheckedContinuation<Void, Never>? = q.sync {
                let current = cont
                cont = nil
                return current
            }
            c?.resume()
        }

        func sendDaemonCommand(_ command: String) -> Bool {
            q.sync { commandCalls.append(command) }
            return startResult
        }

        func stopDaemon() {}
    }

    func testFailedStartCommandRollsRecordingBack() async throws {
        let manager = FakeManager()
        manager.startResult = false
        let controller = ParakeetController(manager: manager)

        var recordingStates: [Bool] = []
        var errors: [String] = []
        controller.onRecording = { recordingStates.append($0) }
        controller.onError = { errors.append($0) }

        await controller.toggle()

        XCTAssertEqual(manager.ensureCalls, 1)
        XCTAssertEqual(manager.commandCalls, ["start"])
        XCTAssertEqual(recordingStates, [true, false])
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(errors, ["The local engine failed to start recording."])
    }

    func testFailedStopCommandSkipsClipboardPollingPath() async throws {
        let manager = FakeManager()
        manager.stopResult = false
        let controller = ParakeetController(manager: manager)

        var recordingStates: [Bool] = []
        var deliveredTexts: [String] = []
        var errors: [String] = []
        var sessionEndedCount = 0
        controller.onRecording = { recordingStates.append($0) }
        controller.onText = { deliveredTexts.append($0) }
        controller.onError = { errors.append($0) }
        controller.onSessionEnded = { sessionEndedCount += 1 }

        await controller.toggle() // start
        await controller.toggle() // stop fails immediately

        XCTAssertEqual(manager.commandCalls, ["start", "stop"])
        XCTAssertEqual(recordingStates, [true, false])
        XCTAssertTrue(deliveredTexts.isEmpty)
        XCTAssertEqual(errors, ["The local engine failed to stop recording."])
        XCTAssertEqual(manager.stopDaemonCalls, 1)
        XCTAssertEqual(sessionEndedCount, 1)
        XCTAssertFalse(controller.isRecording)
    }

    func testSuccessfulStopSignalsSessionEndedAfterDeliveryPathCompletes() async throws {
        let clipboard = FakeClipboard()
        let manager = FakeManager()
        manager.onStop = {
            clipboard.changeCount += 1
            clipboard.value = "stopped text"
        }
        let controller = ParakeetController(manager: manager, clipboard: clipboard)

        var deliveredTexts: [String] = []
        var sessionEndedCount = 0
        controller.onText = { deliveredTexts.append($0) }
        controller.onSessionEnded = { sessionEndedCount += 1 }

        await controller.toggle() // start
        await controller.toggle() // stop

        XCTAssertEqual(deliveredTexts, ["stopped text"])
        XCTAssertEqual(sessionEndedCount, 1)
        XCTAssertFalse(controller.isRecording)
    }

    func testRapidSecondToggleDuringStartupIsIgnored() async throws {
        let manager = GateManager()
        let controller = ParakeetController(manager: manager)

        var recordingStates: [Bool] = []
        controller.onRecording = { recordingStates.append($0) }

        let starting = Task { await controller.toggle() }
        try await waitFor { manager.ensureCalls == 1 }
        await controller.toggle()
        manager.release()
        await starting.value

        XCTAssertEqual(manager.commandCalls, ["start"])
        XCTAssertEqual(recordingStates, [true])
        XCTAssertTrue(controller.isRecording)
    }

    private func waitFor(tries: Int = 300, stepNanos: UInt64 = 10_000_000,
                         _ cond: () async -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< tries {
            if await cond() { return }
            try await Task.sleep(nanoseconds: stepNanos)
        }
        XCTFail("waitFor: condition not met in time", file: file, line: line)
    }

    func testStopDetectsClipboardChangeThatHappensDuringStopCommand() async throws {
        let clipboard = FakeClipboard()
        let manager = FakeManager()
        manager.onStop = {
            clipboard.changeCount += 1
            clipboard.value = "stopped text"
        }
        let controller = ParakeetController(manager: manager, clipboard: clipboard)

        var deliveredTexts: [String] = []
        controller.onText = { deliveredTexts.append($0) }

        await controller.toggle() // start
        await controller.toggle() // stop

        XCTAssertEqual(manager.commandCalls, ["start", "stop"])
        XCTAssertEqual(deliveredTexts, ["stopped text"])
    }
}
