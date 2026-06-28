import Foundation

public final class ElevenLabsRealtimeClient: TranscriptionClient, @unchecked Sendable {
    private let socket: TranscriptionSocket
    private let sampleRate: Int
    private let encoder = JSONEncoder()
    // Set by primePreviousText, consumed by the next sendChunk. Only ever touched from
    // the DictationController actor (prime on reconnect, send on the next chunk), so it
    // needs no extra locking.
    private var pendingPreviousText: String?

    public init(socket: TranscriptionSocket, sampleRate: Int) {
        self.socket = socket
        self.sampleRate = sampleRate
    }

    public func primePreviousText(_ text: String) {
        pendingPreviousText = text
    }

    public func sendChunk(_ pcm16: Data) async throws {
        let prev = pendingPreviousText
        pendingPreviousText = nil
        let frame = InputAudioChunk(audioBase64: pcm16.base64EncodedString(),
                                    sampleRate: sampleRate, previousText: prev)
        try await socket.send(try encoder.encode(frame))
    }

    public func sendCommit() async throws {
        // Per the realtime STT docs a commit is an input_audio_chunk with empty
        // audio and commit=true — not a standalone "commit" message_type.
        let frame = InputAudioChunk(audioBase64: "", sampleRate: sampleRate, commit: true)
        try await socket.send(try encoder.encode(frame))
    }

    public func close() async {
        await socket.close()
    }

    public func events() -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task { [socket] in
                // One decoder for the whole stream — partial transcripts arrive many
                // times a second while speaking; the default `decode` arg would
                // otherwise allocate a fresh JSONDecoder per inbound message.
                let decoder = JSONDecoder()
                do {
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        if data.isEmpty {
                            Diag.conn.error("ElevenLabs: empty inbound frame → server closed the stream")
                            continuation.yield(.failed(.socketClosed)); break
                        }
                        // A frame we can't decode (missing `message_type`, an unknown shape, or a
                        // brand-new server message during an API rollout) is ONE bad message, not a
                        // reason to abort the whole dictation — skip it and keep listening. Real API
                        // errors arrive as the decoded `.error` case below and still propagate.
                        let parsed: ElevenLabsResponse
                        do {
                            parsed = try ElevenLabsResponse.decode(data, decoder: decoder)
                        } catch {
                            Diag.conn.error("ElevenLabs: skipping undecodable frame: \(Diag.describe(error), privacy: .public)")
                            continue
                        }
                        switch parsed {
                        case .partial(let t): continuation.yield(.partial(t))
                        case .committed(let t): continuation.yield(.committed(t))
                        case .error(let e): continuation.yield(.failed(e))
                        case .ignored: continue
                        }
                    }
                } catch let e as TranscriptionError {
                    Diag.conn.error("ElevenLabs stream error: \(String(describing: e), privacy: .public)")
                    continuation.yield(.failed(e))
                } catch {
                    Diag.conn.error("ElevenLabs socket dropped: \(Diag.describe(error), privacy: .public)")
                    continuation.yield(.failed(.socketClosed))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
