import AppKit
import XCTest
@testable import YapApp
@testable import YapCore

final class ClipboardSnapshotTests: XCTestCase {
    func testRestoredItemsPreserveMultipleRepresentations() throws {
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setString("<b>hello</b>", forType: .html)
        let binaryType = NSPasteboard.PasteboardType("com.example.binary")
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        item.setData(payload, forType: binaryType)

        let snapshot = ClipboardSnapshot(pasteboardItems: [item])
        XCTAssertNotNil(snapshot)
        let restored = snapshot?.restoredItems() ?? []
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].string(forType: .string), "hello")
        XCTAssertEqual(restored[0].string(forType: .html), "<b>hello</b>")
        XCTAssertEqual(restored[0].data(forType: binaryType), payload)
    }

    func testRestoredItemsPreservePropertyListRepresentation() throws {
        let item = NSPasteboardItem()
        let customType = NSPasteboard.PasteboardType("com.example.property-list")
        let payload: NSDictionary = ["kind": "plist", "count": 2]
        item.setPropertyList(payload, forType: customType)

        let snapshot = ClipboardSnapshot(pasteboardItems: [item])
        let restored = snapshot?.restoredItems() ?? []
        XCTAssertEqual(restored.count, 1)
        let restoredPayload = restored[0].propertyList(forType: customType) as? NSDictionary
        XCTAssertEqual(restoredPayload?["kind"] as? String, "plist")
        XCTAssertEqual(restoredPayload?["count"] as? Int, 2)
    }
}

@MainActor
final class PasterTests: XCTestCase {
    func testDeniedAccessibilityLeavesClipboardUntouched() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        var fallbackText: String?
        Paster.pasteAtCursor(
            "new transcript",
            pasteboard: pasteboard,
            trustChecker: { false },
            fallback: { fallbackText = $0 }
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
        XCTAssertEqual(fallbackText, "new transcript")
    }

    func testPendingClipboardRestoreCanBeAwaited() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        Paster.pasteAtCursor(
            "new transcript",
            pasteboard: pasteboard,
            restoreDelayNanos: 50_000_000,
            trustChecker: { true },
            fallback: { _ in },
            synthesizePaste: {}
        )

        XCTAssertTrue(Paster.hasPendingClipboardRestore)
        await Paster.waitForPendingClipboardRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    func testRapidSuccessivePastesStillRestoreTheOriginalClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        Paster.pasteAtCursor(
            "first transcript",
            pasteboard: pasteboard,
            restoreDelayNanos: 100_000_000,
            trustChecker: { true },
            fallback: { _ in },
            synthesizePaste: {}
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        Paster.pasteAtCursor(
            "second transcript",
            pasteboard: pasteboard,
            restoreDelayNanos: 100_000_000,
            trustChecker: { true },
            fallback: { _ in },
            synthesizePaste: {}
        )

        await Paster.waitForPendingClipboardRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    func testSettleTaskCompletesAndKeepsTranscriptWhenPreviousClipboardWasEmpty() async {
        // With nothing to restore, the settle task must still exist (sequenced callers
        // await it to space out successive pastes) and the transcript stays on the
        // clipboard rather than being wiped back to empty.
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let settle = Paster.pasteAtCursor(
            "solo transcript",
            pasteboard: pasteboard,
            restoreDelayNanos: 20_000_000,
            trustChecker: { true },
            fallback: { _ in },
            synthesizePaste: {}
        )

        XCTAssertNotNil(settle)
        await settle?.value
        XCTAssertEqual(pasteboard.string(forType: .string), "solo transcript")
    }
}

final class SettingsInteractionPolicyTests: XCTestCase {
    func testBlocksInputDeviceChangeOnlyForBusyLocalDictation() {
        XCTAssertTrue(SettingsInteractionPolicy.shouldBlockInputDeviceChange(providerIsLocal: true, dictationBusy: true))
        XCTAssertFalse(SettingsInteractionPolicy.shouldBlockInputDeviceChange(providerIsLocal: true, dictationBusy: false))
        XCTAssertFalse(SettingsInteractionPolicy.shouldBlockInputDeviceChange(providerIsLocal: false, dictationBusy: true))
    }

    func testBlocksProviderCommitOnlyWhenChangingProvidersDuringDictation() {
        XCTAssertTrue(
            SettingsInteractionPolicy.shouldBlockProviderCommit(
                current: .elevenLabs,
                selected: .deepgram,
                dictationBusy: true
            )
        )
        XCTAssertFalse(
            SettingsInteractionPolicy.shouldBlockProviderCommit(
                current: .elevenLabs,
                selected: .elevenLabs,
                dictationBusy: true
            )
        )
        XCTAssertFalse(
            SettingsInteractionPolicy.shouldBlockProviderCommit(
                current: .elevenLabs,
                selected: .deepgram,
                dictationBusy: false
            )
        )
    }
}

final class SettingsDraftMergerTests: XCTestCase {
    func testPreservesExistingVertexDraftAcrossRefreshes() {
        XCTAssertEqual(
            SettingsDraftMerger.refreshedVertexServiceAccountJSON(
                currentDraft: "{draft}",
                persisted: "{stored}"
            ),
            "{draft}"
        )
    }

    func testFallsBackToPersistedVertexJSONWhenDraftIsEmpty() {
        XCTAssertEqual(
            SettingsDraftMerger.refreshedVertexServiceAccountJSON(
                currentDraft: "",
                persisted: "{stored}"
            ),
            "{stored}"
        )
    }
}

final class STTSettingsSaveCoordinatorTests: XCTestCase {
    func testLocalProviderUsesVerificationWithoutPersistingAPIKey() {
        XCTAssertEqual(
            STTSettingsSaveCoordinator.verificationResult(for: .parakeetLocal),
            "✓ On-device engine selected"
        )
        XCTAssertFalse(STTSettingsSaveCoordinator.shouldPersistAPIKey(for: .parakeetLocal))
    }

    func testCloudProvidersPersistAPIKey() {
        XCTAssertTrue(STTSettingsSaveCoordinator.shouldPersistAPIKey(for: .elevenLabs))
        XCTAssertTrue(STTSettingsSaveCoordinator.shouldPersistAPIKey(for: .deepgram))
    }
}

@MainActor
final class SettingsSaveCoordinatorTests: XCTestCase {
    func testCommitIfVerifiedOnlyRunsOnSuccess() {
        var committed = 0
        SettingsSaveCoordinator.commitIfVerified("✓ Saved") { committed += 1 }
        XCTAssertEqual(committed, 1)

        SettingsSaveCoordinator.commitIfVerified("✗ Invalid") { committed += 1 }
        XCTAssertEqual(committed, 1)
    }
}

final class AppConfigMigrationTests: XCTestCase {
    func testLegacyDefaultsMigrationCopiesMissingValuesWithoutOverwritingCurrent() {
        let defaults = UserDefaults.standard
        let key = "codex_legacy_migration_\(UUID().uuidString)"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        AppConfig.migrateLegacyUserDefaults(from: [key: "legacy"])
        XCTAssertEqual(defaults.string(forKey: key), "legacy")

        defaults.set("current", forKey: key)
        AppConfig.migrateLegacyUserDefaults(from: [key: "ignored"])
        XCTAssertEqual(defaults.string(forKey: key), "current")
    }
}

final class AudioInputDevicesTests: XCTestCase {
    // The one combination that audibly hurts the user: engaging a BLUETOOTH mic while
    // they listen on Bluetooth knocks the headset from A2DP into HFP call mode. The
    // policy avoids exactly that — and nothing else. A non-Bluetooth mic can never
    // degrade the headset audio, so an explicit selection of one is ALWAYS honored.
    func testAvoidsSelectedBluetoothMicWhenOutputIsBluetooth() {
        let devices = [
            AudioInputDevice(id: 1, uid: "airpods", name: "AirPods", isBuiltIn: false, isBluetooth: true),
            AudioInputDevice(id: 2, uid: "builtin", name: "Mac mic", isBuiltIn: true)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: "airpods",
            defaultOutputIsBluetooth: true
        )

        XCTAssertEqual(uid, "builtin")
    }

    func testHonorsPersistedInputWhenOutputIsNotBluetooth() {
        let devices = [
            AudioInputDevice(id: 1, uid: "usb", name: "USB mic", isBuiltIn: false),
            AudioInputDevice(id: 2, uid: "builtin", name: "Mac mic", isBuiltIn: true)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: "usb",
            defaultOutputIsBluetooth: false
        )

        XCTAssertEqual(uid, "usb")
    }

    func testFallsBackToFirstDeviceWhenBuiltinIsMissing() {
        let devices = [
            AudioInputDevice(id: 1, uid: "usb", name: "USB mic", isBuiltIn: false)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: nil,
            defaultOutputIsBluetooth: false
        )

        XCTAssertEqual(uid, "usb")
    }

    func testHonorsNonBluetoothSelectionEvenWhenOutputIsBluetooth() {
        // Regression (Mac mini / Studio + AirPods): a USB/XLR mic can't push the AirPods
        // into HFP — overriding it (to a built-in mic that doesn't exist there) made
        // every dictation fail with "no input" for the whole desktop-Mac user class.
        let devices = [
            AudioInputDevice(id: 1, uid: "usb", name: "USB mic", isBuiltIn: false)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: "usb",
            defaultOutputIsBluetooth: true
        )

        XCTAssertEqual(uid, "usb")
    }

    func testFallsBackToNonBluetoothInputWhenOutputIsBluetoothAndNoBuiltin() {
        let devices = [
            AudioInputDevice(id: 1, uid: "airpods", name: "AirPods", isBuiltIn: false, isBluetooth: true),
            AudioInputDevice(id: 2, uid: "usb", name: "USB mic", isBuiltIn: false)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: nil,
            defaultOutputIsBluetooth: true
        )

        XCTAssertEqual(uid, "usb")
    }

    func testPrefersRealBluetoothMicOverVirtualLoopbackDevices() {
        // BlackHole/aggregate devices are "inputs" that record silence. With no real
        // wired mic, the REAL Bluetooth mic must win over a virtual device — capturing
        // a loopback would make dictation silently produce nothing.
        let devices = [
            AudioInputDevice(id: 1, uid: "blackhole", name: "BlackHole 2ch", isBuiltIn: false, isVirtual: true),
            AudioInputDevice(id: 2, uid: "airpods", name: "AirPods", isBuiltIn: false, isBluetooth: true)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: nil,
            defaultOutputIsBluetooth: true
        )

        XCTAssertEqual(uid, "airpods")
    }

    func testUsesBluetoothMicAsLastResortWhenItIsTheOnlyInput() {
        // A Mac with ONLY AirPods available must still dictate (HFP is unavoidable
        // there) — failing with "no input" would brick dictation entirely.
        let devices = [
            AudioInputDevice(id: 1, uid: "airpods", name: "AirPods", isBuiltIn: false, isBluetooth: true)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: nil,
            defaultOutputIsBluetooth: true
        )

        XCTAssertEqual(uid, "airpods")
    }

    func testHonorsBluetoothSelectionWhenOutputIsNotBluetooth() {
        // Listening on speakers: capturing from an explicitly chosen Bluetooth mic
        // degrades nothing the user can hear — the explicit choice wins.
        let devices = [
            AudioInputDevice(id: 1, uid: "airpods", name: "AirPods", isBuiltIn: false, isBluetooth: true),
            AudioInputDevice(id: 2, uid: "builtin", name: "Mac mic", isBuiltIn: true)
        ]

        let uid = AudioInputDevices.preferredDictationInputUID(
            devices: devices,
            preferredInputDeviceUID: "airpods",
            defaultOutputIsBluetooth: false
        )

        XCTAssertEqual(uid, "airpods")
    }
}

actor QueueLog {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private struct QueueProcessor: TextPostProcessor {
    let log: QueueLog
    let delayNanos: UInt64

    func process(_ text: String) async throws -> String {
        await log.record("start \(text)")
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        await log.record("finish \(text)")
        return "processed: \(text)"
    }
}

@MainActor
final class DeliveryQueueTests: XCTestCase {
    private struct HangingProcessor: TextPostProcessor {
        func process(_ text: String) async throws -> String {
            while true {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    continue
                }
            }
        }
    }

    func testEnqueueProcessesEveryDeliveryInOrder() async throws {
        var deliveries: [String] = []
        let log = QueueLog()
        var callCount = 0
        let queue = DeliveryQueue(
            makeProcessor: {
                callCount += 1
                return QueueProcessor(log: log, delayNanos: callCount == 1 ? 150_000_000 : 0)
            },
            paste: { deliveries.append($0) }
        )

        queue.enqueue("first")
        queue.enqueue("second")

        try await waitFor { deliveries.count == 2 }
        XCTAssertEqual(deliveries, ["processed: first", "processed: second"])
        let events = await log.snapshot()
        XCTAssertLessThan(
            events.firstIndex(of: "start second") ?? events.endIndex,
            events.firstIndex(of: "finish first") ?? events.endIndex,
            "second delivery should start before the first one finishes"
        )
    }

    func testDrainAwaitsEachPasteBeforeDeliveringTheNext() async throws {
        // Regression: the drain loop burst-pasted ready transcripts synchronously —
        // the second clipboard write landed before the target app consumed the first
        // ⌘V, so the earlier dictation was never pasted (later text pasted twice).
        var events: [String] = []
        let queue = DeliveryQueue(
            makeProcessor: { nil },
            paste: { text in
                events.append("start \(text)")
                try? await Task.sleep(nanoseconds: 80_000_000)
                events.append("end \(text)")
            }
        )

        queue.enqueue("one")
        queue.enqueue("two")

        try await waitFor { events.count == 4 }
        XCTAssertEqual(events, ["start one", "end one", "start two", "end two"])
    }

    func testCancelAndDrainKeepsRawTranscriptOnShutdown() async throws {
        var deliveries: [String] = []
        let log = QueueLog()
        let queue = DeliveryQueue(
            makeProcessor: { QueueProcessor(log: log, delayNanos: 500_000_000) },
            paste: { deliveries.append($0) }
        )

        queue.enqueue("shutdown")
        try await Task.sleep(nanoseconds: 50_000_000)
        await queue.cancelAndDrain()

        XCTAssertEqual(deliveries, ["shutdown"])
    }

    func testCancelAndDrainReturnsRawTextWhenProcessorDoesNotCooperate() async throws {
        var deliveries: [String] = []
        let queue = DeliveryQueue(
            makeProcessor: { HangingProcessor() },
            paste: { deliveries.append($0) }
        )

        queue.enqueue("raw fallback")
        try await Task.sleep(nanoseconds: 50_000_000)

        let start = ContinuousClock.now
        await queue.cancelAndDrain()
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertEqual(deliveries, ["raw fallback"])
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    private func waitFor(tries: Int = 200, stepNanos: UInt64 = 10_000_000,
                         _ cond: @escaping @MainActor () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< tries {
            if cond() { return }
            try await Task.sleep(nanoseconds: stepNanos)
        }
        XCTFail("waitFor: condition not met in time", file: file, line: line)
    }
}

final class DeepgramKeyCheckTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testCheckUsesAuthorizationHeader() async {
        var capturedAuth: String?
        var capturedURL: String?
        var capturedTimeout: TimeInterval?
        MockURLProtocol.handler = { req in
            capturedURL = req.url?.absoluteString
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            capturedTimeout = req.timeoutInterval
            return (200, Data())
        }

        let result = await DeepgramKeyCheck.check("deepgram-key", session: MockURLProtocol.session())
        XCTAssertEqual(capturedURL, "https://api.deepgram.com/v1/projects")
        XCTAssertEqual(capturedAuth, "Token deepgram-key")
        XCTAssertEqual(capturedTimeout ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(result, "✓ Valid key — saved")
    }

    func testCheckReportsInvalidKey() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let result = await DeepgramKeyCheck.check("bad-key", session: MockURLProtocol.session())
        XCTAssertEqual(result, "✗ Invalid key (401)")
    }
}

final class ElevenLabsKeyCheckTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testCheckUsesAuthorizationHeaderAndTimeout() async {
        var capturedKey: String?
        var capturedTimeout: TimeInterval?
        MockURLProtocol.handler = { req in
            capturedKey = req.value(forHTTPHeaderField: "xi-api-key")
            capturedTimeout = req.timeoutInterval
            return (200, Data())
        }

        let result = await ElevenLabsKeyCheck.check("eleven-key", session: MockURLProtocol.session())
        XCTAssertEqual(capturedKey, "eleven-key")
        XCTAssertEqual(capturedTimeout ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(result, "✓ Valid key — saved")
    }
}
