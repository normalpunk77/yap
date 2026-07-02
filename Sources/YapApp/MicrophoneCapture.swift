@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import YapCore

private actor FlushWaitState {
    private var finished = false
    private(set) var timedOut = false

    func complete(timedOut: Bool) -> Bool {
        guard !finished else { return false }
        finished = true
        self.timedOut = timedOut
        return true
    }

    func isTimedOut() -> Bool { timedOut }
}

/// Concurrency model — three domains touch this object, so every bit of shared
/// mutable state is confined or locked:
///  - `sessionQueue` (serial) owns ALL AVCaptureSession mutations: configure, start,
///    stop, recovery. Nothing else calls into the session, so a stop can never
///    interleave with a route-change restart (that interleaving used to leave the mic
///    engaged after dictation ended — orange dot stuck on).
///  - `outputQueue` (serial) receives the capture callbacks; it only READS the shared
///    flags/closures (via `stateLock`) and owns `converter`/`targetFormat`.
///  - Callers (actor executor threads) go through `stateLock` for the flags and hop
///    onto `sessionQueue` for session work. In particular `stop()` detaches the
///    delegate and stops the session BEFORE releasing `chunkContinuation` — nilling a
///    strong var while the delegate thread still yields into it was an ARC race
///    (intermittent over/under-release crashes).
final class MicrophoneCapture: NSObject, AudioCapturer, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.yap.microphone-capture.session")
    private let outputQueue = DispatchQueue(label: "com.yap.microphone-capture.output")
    private let stateLock = NSLock()
    private let targetRate: Double = 16000

    // outputQueue-confined (rebuilt from the first buffer's REAL format; the live
    // hardware rate can differ from what we read at start and can change mid-stream).
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!

    // stateLock-guarded.
    private var _onLevel: (@Sendable (Double) -> Void)?
    private var _onCaptureFailure: (@Sendable () -> Void)?
    private var _chunkContinuation: AsyncStream<Data>.Continuation?
    private var _sessionActive = false
    private var configObservers: [NSObjectProtocol] = []

    // sessionQueue-confined.
    private var activeInput: AVCaptureDeviceInput?
    private var activeOutput: AVCaptureAudioDataOutput?

    // Caller-side only (the controller actor serializes start/flush-wait/stop).
    private var deliveryTask: Task<Void, Never>?

    /// Optional live input level in 0...1, emitted per audio buffer (off the main
    /// thread). Set before `start`; used to drive the HUD waveform.
    var onLevel: (@Sendable (Double) -> Void)? {
        get { stateLock.withLock { _onLevel } }
        set { stateLock.withLock { _onLevel = newValue } }
    }

    /// Fired (once, off the main thread) when capture dies irrecoverably mid-session —
    /// the input device vanished and no fallback could be brought up. Lets the owner
    /// end the dictation instead of listening forever to a dead mic.
    var onCaptureFailure: (@Sendable () -> Void)? {
        get { stateLock.withLock { _onCaptureFailure } }
        set { stateLock.withLock { _onCaptureFailure = newValue } }
    }

    private var chunkContinuation: AsyncStream<Data>.Continuation? {
        get { stateLock.withLock { _chunkContinuation } }
        set { stateLock.withLock { _chunkContinuation = newValue } }
    }

    private var sessionActive: Bool {
        get { stateLock.withLock { _sessionActive } }
        set { stateLock.withLock { _sessionActive = newValue } }
    }

    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws {
        try await start(onChunk: onChunk, deliverChunks: true)
    }

    func start(onChunk: @escaping @Sendable (Data) async -> Void,
               deliverChunks: Bool) async throws {
        try await requestPermission()

        // Publish the per-session conversion state through the callback queue so the
        // delegate never sees a half-initialized converter setup.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: targetRate,
                                   channels: 1,
                                   interleaved: false)!
        outputQueue.sync {
            targetFormat = format
            converter = nil
        }

        if deliverChunks {
            // Bounded buffer: if the consumer ever wedges, drop the newest instead of
            // growing without limit (1024 ≈ far beyond any real drain hiccup).
            let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(1024))
            chunkContinuation = cont
            // Coalesce the small per-buffer chunks into ~100 ms frames before sending:
            // fewer frames mean fewer JSON/base64 encodes and WS sends.
            let flushBytes = Int(targetRate) * 2 / 10   // 100 ms of 16-bit mono @ 16 kHz
            deliveryTask = Task {
                var pending = Data()
                for await chunk in stream {
                    pending.append(chunk)
                    if pending.count >= flushBytes {
                        await onChunk(pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                if !pending.isEmpty { await onChunk(pending) }
            }
        }

        let configError: Error? = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configureSession()
                    session.startRunning()
                    continuation.resume(returning: nil)
                } catch {
                    teardownSessionConfiguration()
                    continuation.resume(returning: error)
                }
            }
        }
        if let configError {
            let cont = chunkContinuation
            chunkContinuation = nil
            cont?.finish()
            deliveryTask = nil
            throw configError
        }

        sessionActive = true
        installObservers()
    }

    /// Re-evaluate the input after a device/route event, on the session queue. Covers:
    /// the selected mic vanished (fall back per policy), the user's preferred mic came
    /// back (honor the choice again), or the session died on a runtime error (restart).
    /// If no input can be brought up at all, end the chunk stream and report the
    /// failure so the session stops cleanly rather than hanging on a dead microphone.
    private func scheduleSessionRecovery() {
        sessionQueue.async { [self] in
            guard sessionActive else { return }
            let wantedUID = AudioInputDevices.preferredDictationInputUID()
            let currentUID = activeInput?.device.uniqueID
            if session.isRunning, let wantedUID, wantedUID == currentUID { return }
            do {
                try configureSession()
                session.startRunning()
            } catch {
                Diag.conn.error("mic recovery failed — ending capture: \(Diag.describe(error), privacy: .public)")
                failCapture()
            }
        }
    }

    /// sessionQueue-only. Irrecoverable input loss: stop delivering, tell the owner.
    private func failCapture() {
        let (cont, failureHandler): (AsyncStream<Data>.Continuation?, (@Sendable () -> Void)?) =
            stateLock.withLock {
                let c = _chunkContinuation
                _chunkContinuation = nil
                _sessionActive = false
                return (c, _onCaptureFailure)
            }
        cont?.finish()
        failureHandler?()
    }

    /// sessionQueue-only.
    private func configureSession() throws {
        session.stopRunning()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        teardownSessionConfiguration()

        guard let uid = AudioInputDevices.preferredDictationInputUID(),
              let device = Self.captureDevice(forUID: uid) else {
            throw CaptureError.noInput
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.noInput }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw CaptureError.noInput }
        session.addOutput(output)

        activeInput = input
        activeOutput = output
    }

    /// sessionQueue-only.
    private func teardownSessionConfiguration() {
        if let activeOutput {
            activeOutput.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(activeOutput)
            self.activeOutput = nil
        }
        if let activeInput {
            session.removeInput(activeInput)
            self.activeInput = nil
        }
    }

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
                self?.scheduleSessionRecovery()
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
                self?.scheduleSessionRecovery()
            },
            // A session whose device disappears does NOT reliably raise a runtime error —
            // it can keep "running" with a dead input. Watch the device list itself:
            // disappearance falls back per policy, reappearance restores the user's choice.
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleSessionRecovery()
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleSessionRecovery()
            }
        ]
        stateLock.withLock { configObservers = observers }
    }

    private func removeObservers() {
        let observers = stateLock.withLock { () -> [NSObjectProtocol] in
            let current = configObservers
            configObservers = []
            return current
        }
        guard !observers.isEmpty else { return }
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private static func captureDevice(forUID uid: String) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if let matched = devices.first(where: { $0.uniqueID == uid }) {
            return matched
        }
        // The chosen UID isn't visible to AVFoundation (device raced away, HAL↔AVF skew).
        // Fall back along the SAME preference order as the picker policy — never to the
        // raw system default, which can silently be the very AirPods the policy avoids.
        let ranked = AudioInputDevices.all().sorted { a, b in
            rank(a) < rank(b)
        }
        for candidate in ranked where candidate.uid != uid {
            if let device = devices.first(where: { $0.uniqueID == candidate.uid }) {
                return device
            }
        }
        return nil
    }

    private static func rank(_ device: AudioInputDevice) -> Int {
        if device.isBuiltIn { return 0 }
        if device.isVirtual { return 3 }   // loopbacks record silence — dead last
        return device.isBluetooth ? 2 : 1
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // One locked snapshot per buffer; the yield/level calls run outside the lock.
        let (active, continuation, level) = stateLock.withLock {
            (_sessionActive, _chunkContinuation, _onLevel)
        }
        guard active else { return }
        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

        if let continuation {
            guard let samples = resampleToMonoFloat(buffer) else { return }
            continuation.yield(PCM16.fromFloat(samples))
            level?(Self.rmsLevel(samples))
        } else if let level {
            if let rms = Self.rmsLevel(buffer) {
                level(rms)
            } else if let samples = resampleToMonoFloat(buffer) {
                level(Self.rmsLevel(samples))
            }
        }
    }

    func stop() async {
        // Claim THIS session's continuation synchronously at entry: stop() suspends
        // below, and a successor start() can legitimately run during that await (the
        // tap-during-finalize restart). Reading the property after resuming would grab
        // — and kill — the successor's fresh continuation, silently muting its whole
        // dictation. The flag flip in the same critical section makes the delegate
        // no-op immediately.
        let cont: AsyncStream<Data>.Continuation? = stateLock.withLock {
            _sessionActive = false
            let claimed = _chunkContinuation
            _chunkContinuation = nil
            return claimed
        }
        removeObservers()
        // Stop the session and detach the delegate BEFORE finishing the continuation.
        // (Releasing it while the delegate was still yielding into it from outputQueue
        // was an unsynchronized ARC handoff: intermittent crashes.)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                session.stopRunning()
                teardownSessionConfiguration()
                continuation.resume()
            }
        }
        cont?.finish()
    }

    func waitForPendingAudioFlush(timeoutNanos: UInt64) async {
        guard let task = deliveryTask else { return }
        guard timeoutNanos > 0 else {
            await task.value
            deliveryTask = nil
            return
        }

        let state = FlushWaitState()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await task.value
                if await state.complete(timedOut: false) {
                    continuation.resume()
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                if await state.complete(timedOut: true) {
                    continuation.resume()
                }
            }
        }
        if await state.isTimedOut() {
            task.cancel()
        }
        deliveryTask = nil
    }

    /// outputQueue-only (delegate callback path).
    private func resampleToMonoFloat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let targetFormat else { return nil }
        // Rebuild the converter whenever the live input format changes so it always
        // matches the buffers we receive.
        if let existing = converter,
           existing.inputFormat.sampleRate == buffer.format.sampleRate,
           existing.inputFormat.channelCount == buffer.format.channelCount,
           existing.inputFormat.commonFormat == buffer.format.commonFormat {
            // reuse
        } else {
            let made = AVAudioConverter(from: buffer.format, to: targetFormat)
            // Downsampling the mic to 16 kHz with the default converter quality lets
            // high frequencies alias into the speech band and smear consonants.
            made?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            made?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = made
        }
        guard let converter else { return nil }
        let ratio = targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int32.max else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    private static func rmsLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return min(Double(rms) * 8.0, 1.0)
    }

    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0 ..< channelCount {
            let samples = channels[channel]
            for frame in 0 ..< frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        let rms = (sum / Float(frameCount * channelCount)).squareRoot()
        return min(Double(rms) * 8.0, 1.0)
    }

    private func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw CaptureError.micDenied }
        default:
            throw CaptureError.micDenied
        }
    }

    enum CaptureError: Error { case micDenied, noInput }
}
