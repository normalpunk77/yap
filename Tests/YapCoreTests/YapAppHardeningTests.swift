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
            trustChecker: { true },
            fallback: { _ in }
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
            trustChecker: { true },
            fallback: { _ in }
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        Paster.pasteAtCursor(
            "second transcript",
            pasteboard: pasteboard,
            trustChecker: { true },
            fallback: { _ in }
        )

        await Paster.waitForPendingClipboardRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
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
    func testNominalSampleRateIsReadableForBuiltInMic() throws {
        guard let mic = AudioInputDevices.builtIn() else {
            throw XCTSkip("No built-in microphone available on this machine")
        }

        let rate = AudioInputDevices.nominalSampleRate(for: mic.id)
        XCTAssertNotNil(rate)
        XCTAssertGreaterThan(rate ?? 0, 0)
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
