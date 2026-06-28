import Foundation

/// Deepgram live STT over the same `TranscriptionClient` contract used for ElevenLabs.
/// Audio is sent as raw binary (`linear16`); commit/close are JSON control messages;
/// inbound `Results` frames map to partial/committed events.
public final class DeepgramRealtimeClient: TranscriptionClient, @unchecked Sendable {
    private let socket: TranscriptionSocket

    public init(socket: TranscriptionSocket) {
        self.socket = socket
    }

    public func sendChunk(_ pcm16: Data) async throws {
        try await socket.sendBinary(pcm16)
    }

    public func sendCommit() async throws {
        // Flush buffered audio and emit final results (our "stop").
        try await socket.send(Self.control("Finalize"))
    }

    public func close() async {
        // Ask the server to flush + close cleanly, then tear the socket down.
        try? await socket.send(Self.control("CloseStream"))
        await socket.close()
    }

    public func primePreviousText(_ text: String) {
        // Deepgram has no per-stream "previous text" context message; no-op. Reconnection
        // still works (a fresh stream resumes), just without seeded context.
    }

    public func events() -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            let task = Task { [socket] in
                let decoder = JSONDecoder()
                do {
                    while !Task.isCancelled {
                        let data = try await socket.receive()
                        if data.isEmpty {
                            Diag.conn.error("Deepgram: empty inbound frame → server closed the stream")
                            continuation.yield(.failed(.socketClosed)); break
                        }
                        // An undecodable frame is a single bad/unknown message, NOT a dead
                        // socket — skip it and keep listening. (Routing it to the generic catch
                        // below mislabeled it `.socketClosed`, triggering a pointless reconnect.)
                        let parsed: DeepgramResponse
                        do {
                            parsed = try DeepgramResponse.decode(data, decoder: decoder)
                        } catch {
                            Diag.conn.error("Deepgram: skipping undecodable frame: \(Diag.describe(error), privacy: .public)")
                            continue
                        }
                        switch parsed {
                        case .partial(let t): continuation.yield(.partial(t))
                        case .committed(let t): continuation.yield(.committed(t))
                        case .ignored: continue
                        }
                    }
                } catch let e as TranscriptionError {
                    Diag.conn.error("Deepgram stream error: \(String(describing: e), privacy: .public)")
                    continuation.yield(.failed(e))
                } catch {
                    Diag.conn.error("Deepgram socket dropped: \(Diag.describe(error), privacy: .public)")
                    continuation.yield(.failed(.socketClosed))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func control(_ type: String) -> Data {
        Data(#"{"type":"\#(type)"}"#.utf8)
    }
}
