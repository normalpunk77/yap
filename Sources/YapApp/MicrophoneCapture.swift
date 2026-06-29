@preconcurrency import AVFoundation
import CoreAudio
import YapCore
import ObjCExceptionCatcher

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

final class MicrophoneCapture: AudioCapturer, @unchecked Sendable {
    /// Optional live input level in 0...1, emitted per audio buffer (off the main
    /// thread). Set before `start`; used to drive the HUD waveform.
    var onLevel: (@Sendable (Double) -> Void)?

    private let engine = AVAudioEngine()
    private let targetRate: Double = 16000
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    // Audio chunks flow through ONE ordered stream (see start): the tap thread only
    // enqueues; a single consumer task awaits `onChunk` strictly in order.
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var deliveryTask: Task<Void, Never>?
    // Tracks whether capture is active regardless of whether we are actually delivering
    // chunks. Route-change recovery needs this in level-only meter mode too.
    private var sessionActive = false
    // Observes mid-session audio route/device changes so capture can resume instead of
    // silently freezing (see start). Held for the session, removed in stop.
    private var configObserver: NSObjectProtocol?

    func start(onChunk: @escaping @Sendable (Data) async -> Void) async throws {
        try await start(onChunk: onChunk, deliverChunks: true)
    }

    func start(onChunk: @escaping @Sendable (Data) async -> Void,
               deliverChunks: Bool) async throws {
        try await requestPermission()

        let input = engine.inputNode
        // Defensive: a tap left from a previous start() (or a double toggle) makes
        // installTap throw an UNCAUGHT NSException -> SIGABRT (app crash). Clear first.
        input.removeTap(onBus: 0)
        // Capture from the user's chosen mic, defaulting to the built-in one rather than
        // whatever is the system default input. Recording through a Bluetooth headset's
        // mic (AirPods) forces it out of A2DP (stereo music) into HFP (mono call mode), so
        // the user's music drops out the moment dictation starts. Pinning the built-in
        // device keeps the headset in music mode. Best-effort: falls back to the default
        // input if the chosen device isn't found/settable.
        Self.preferSelectedInput(on: input)
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: targetRate,
                                     channels: 1,
                                     interleaved: false)!
        // Built lazily from the first buffer's REAL format (see resampleToMonoFloat):
        // the live hardware rate can differ from what we read here and can change
        // mid-stream — Bluetooth mics (AirPods) flip between 24 and 48 kHz.
        converter = nil

        // One serial pipe instead of a Task per buffer. Spawning `Task { await onChunk }`
        // per buffer runs the sends CONCURRENTLY, so under load (e.g. App Nap throttling
        // right after idle) chunks can reach the socket out of order and garble the
        // transcript. A single consumer draining an ordered stream guarantees FIFO and
        // avoids per-buffer task churn. The tap thread only does a cheap, lock-free yield.
        let continuation: AsyncStream<Data>.Continuation?
        if deliverChunks {
            let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            chunkContinuation = cont
            continuation = cont
            // Coalesce the small per-tap buffers (~43 ms at 48 kHz) into ~100 ms chunks
            // before sending: ElevenLabs recommends 0.1–1 s chunks, and fewer/larger frames
            // mean fewer base64+JSON encodes and WS sends. The leftover (<100 ms) is flushed
            // when the stream ends (on stop), so the tail of speech is never dropped.
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
        } else {
            continuation = nil
        }

        try installTap(on: input, deliverChunks: deliverChunks, continuation: continuation)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // The engine failed to start AFTER the tap + stream were set up — tear them down so
            // we don't leak the tap, an open HAL session, and a delivery task that waits forever.
            input.removeTap(onBus: 0)
            chunkContinuation?.finish()
            chunkContinuation = nil
            deliveryTask = nil
            throw error
        }
        sessionActive = true

        // A mid-session route/device change (plug/unplug headphones, switch input)
        // makes AVAudioEngine STOP itself — capture would then freeze silently while the
        // aura stays lit. Observe that and restart the engine on the new route, reinstalling
        // the tap because the engine's I/O unit can be rebuilt under us.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterRouteChange() }
    }

    /// Resume capture after the engine stopped on a configuration change. No-op if the
    /// engine is already running. If it can't be restarted, end the chunk stream so the
    /// session stops cleanly rather than hanging on a dead microphone.
    private func restartAfterRouteChange() {
        guard sessionActive, !engine.isRunning else { return }
        let input = engine.inputNode
        // Re-assert the chosen mic on the NEW route — otherwise a Bluetooth device that
        // just connected mid-session would capture us and (when the default is built-in)
        // flip into low-quality call mode, dropping the user's music.
        input.removeTap(onBus: 0)
        Self.preferSelectedInput(on: input)
        do {
            try installTap(on: input,
                           deliverChunks: chunkContinuation != nil,
                           continuation: chunkContinuation)
            engine.prepare()
            try engine.start()
        } catch {
            chunkContinuation?.finish()
            chunkContinuation = nil
            deliveryTask = nil
            sessionActive = false
        }
    }

    private func installTap(on input: AVAudioInputNode,
                            deliverChunks: Bool,
                            continuation: AsyncStream<Data>.Continuation?) throws {
        // Use the selected device's nominal sample rate when available, but keep the tap
        // installation itself centralized so route-change recovery can reinstall it after
        // AVAudioEngine rebuilds its I/O unit.
        guard let device = Self.resolveInputDevice(),
              let tapSampleRate = AudioInputDevices.nominalSampleRate(for: device),
              tapSampleRate > 0 else {
            throw CaptureError.noInput
        }
        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: tapSampleRate,
                                      channels: 1,
                                      interleaved: false)!
        // ocec_perform stays as the last-resort net: any residual NSException becomes an error.
        var tapError: NSError?
        let installed = ocec_perform({
            // Capture the continuation by value (it's Sendable) rather than reading
            // self.chunkContinuation from the audio thread — that would race with stop()
            // nil-ing it. A yield after finish() is a safe no-op.
            input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self, continuation, deliverChunks] buffer, _ in
                guard let self else { return }
                // Funnel the body through the shim: an NSException on the audio thread (e.g.
                // AVAudioConverter choking on a malformed buffer after a route glitch) would
                // otherwise SIGABRT — the shim above only guards the installTap CALL, not these
                // per-buffer callbacks. A fault here drops a buffer instead of crashing.
                _ = ocec_perform({
                    if deliverChunks {
                        guard let samples = self.resampleToMonoFloat(buffer) else { return }
                        continuation?.yield(PCM16.fromFloat(samples))
                        self.onLevel?(Self.rmsLevel(samples))
                    } else if let onLevel = self.onLevel {
                        // Meter-only (no chunk delivery): get the level cheaply from the buffer
                        // directly, resampling only as a fallback.
                        if let level = Self.rmsLevel(buffer) {
                            onLevel(level)
                        } else if let samples = self.resampleToMonoFloat(buffer) {
                            onLevel(Self.rmsLevel(samples))
                        }
                    }
                }, nil)
            }
        }, &tapError)
        guard installed else {
            input.removeTap(onBus: 0)
            chunkContinuation?.finish()
            chunkContinuation = nil
            deliveryTask = nil
            sessionActive = false
            throw CaptureError.tapFailed(tapError?.localizedDescription ?? "installTap raised")
        }
    }

    /// Point the engine's input at the user's chosen mic (or the built-in one by
    /// default), best-effort. No-op on failure, leaving the system default input.
    private static func preferSelectedInput(on input: AVAudioInputNode) {
        guard var device = resolveInputDevice(), let unit = input.audioUnit else { return }
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0,
                             &device,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// The live device ID to capture from: the user's chosen mic when it's still
    /// present, otherwise the built-in mic (nil only if neither exists).
    private static func resolveInputDevice() -> AudioDeviceID? {
        if let uid = AppConfig.preferredInputDeviceUID,
           let device = AudioInputDevices.deviceID(forUID: uid) {
            return device
        }
        return AudioInputDevices.builtIn()?.id
    }

    func stop() async {
        sessionActive = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        // Close the pipe BEFORE stopping the engine: a route-change notification already queued
        // on the main thread could otherwise see `chunkContinuation != nil` and `!engine.isRunning`
        // mid-teardown and try to restart the engine we're tearing down.
        chunkContinuation?.finish()
        chunkContinuation = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Do NOT await the drain here: the consumer flushes its <100ms tail on its own, and
        // awaiting it would couple finalize to the WebSocket send — on a wedged network that parks
        // finalize for the whole socket timeout, and BEFORE DictationController arms its
        // finalize-timeout backstop (it's set up after this returns). The flush delay + finalize
        // timeout in DictationController bound the tail wait instead.
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
        // Rebuild the converter whenever the live input format changes (e.g. a
        // Bluetooth route switch), so it always matches the buffers we receive.
        if let existing = converter,
           existing.inputFormat.sampleRate == buffer.format.sampleRate,
           existing.inputFormat.channelCount == buffer.format.channelCount,
           // Also match the sample TYPE: a device swap (USB) can deliver Int16/Int32 instead of
           // Float32 at the same rate/channels — a converter built for the old type would garble
           // or drop the audio.
           existing.inputFormat.commonFormat == buffer.format.commonFormat {
            // reuse
        } else {
            let made = AVAudioConverter(from: buffer.format, to: targetFormat)
            // Downsampling the mic (typically 48 kHz) to 16 kHz with the default
            // converter quality lets high frequencies ALIAS into the speech band and
            // smears consonants — which makes the model mishear standard words. Force a
            // proper anti-aliased, highest-quality sample-rate conversion so the 16 kHz
            // we send is clean (what speech models are trained on).
            made?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            made?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = made
        }
        guard let converter else { return nil }
        let ratio = targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        // `convert`'s input block is @Sendable, but AVAudioConverter invokes it
        // synchronously on this thread — so feeding `buffer` exactly once via a captured
        // flag is safe. nonisolated(unsafe) tells Swift 6 we vouch for that.
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
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

    enum CaptureError: Error { case micDenied, noInput, tapFailed(String) }
}
