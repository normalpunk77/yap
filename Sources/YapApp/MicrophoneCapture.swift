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

final class MicrophoneCapture: NSObject, AudioCapturer, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Optional live input level in 0...1, emitted per audio buffer (off the main
    /// thread). Set before `start`; used to drive the HUD waveform.
    var onLevel: (@Sendable (Double) -> Void)?

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.yap.microphone-capture.output")
    private let targetRate: Double = 16000
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    // Audio chunks flow through ONE ordered stream. The capture delegate only enqueues;
    // a single consumer task awaits `onChunk` strictly in order.
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var deliveryTask: Task<Void, Never>?
    // Tracks whether capture is active regardless of whether we are actually delivering
    // chunks. Route-change recovery needs this in level-only meter mode too.
    private var sessionActive = false
    private var activeInput: AVCaptureDeviceInput?
    private var activeOutput: AVCaptureAudioDataOutput?
    private var configObservers: [NSObjectProtocol] = []

    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws {
        try await start(onChunk: onChunk, deliverChunks: true)
    }

    func start(onChunk: @escaping @Sendable (Data) async -> Void,
               deliverChunks: Bool) async throws {
        try await requestPermission()

        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: targetRate,
                                     channels: 1,
                                     interleaved: false)!
        // Built lazily from the first buffer's REAL format. The live hardware rate can
        // differ from what we read here and can change mid-stream.
        converter = nil

        if deliverChunks {
            let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
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

        do {
            try configureSession()
            session.startRunning()
        } catch {
            chunkContinuation?.finish()
            chunkContinuation = nil
            deliveryTask = nil
            teardownSessionConfiguration()
            throw error
        }

        sessionActive = true
        installObservers()
    }

    /// Resume capture after the session stopped on a configuration change or runtime error.
    /// No-op if the session is already running. If it can't be restarted, end the chunk stream
    /// so the session stops cleanly rather than hanging on a dead microphone.
    private func restartAfterRouteChange() {
        guard sessionActive, !session.isRunning else { return }
        do {
            try configureSession()
            session.startRunning()
        } catch {
            chunkContinuation?.finish()
            chunkContinuation = nil
            deliveryTask = nil
            sessionActive = false
        }
    }

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
        configObservers = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
                self?.restartAfterRouteChange()
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
                self?.restartAfterRouteChange()
            }
        ]
    }

    private func removeObservers() {
        guard !configObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for observer in configObservers {
            center.removeObserver(observer)
        }
        configObservers.removeAll(keepingCapacity: true)
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
        return devices.first(where: { $0.deviceType == .microphone }) ?? AVCaptureDevice.default(for: .audio)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sessionActive else { return }
        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

        if chunkContinuation != nil {
            guard let samples = resampleToMonoFloat(buffer) else { return }
            chunkContinuation?.yield(PCM16.fromFloat(samples))
            self.onLevel?(Self.rmsLevel(samples))
        } else if let onLevel = self.onLevel {
            if let level = Self.rmsLevel(buffer) {
                onLevel(level)
            } else if let samples = resampleToMonoFloat(buffer) {
                onLevel(Self.rmsLevel(samples))
            }
        }
    }

    func stop() async {
        sessionActive = false
        removeObservers()
        chunkContinuation?.finish()
        chunkContinuation = nil
        session.stopRunning()
        teardownSessionConfiguration()
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
