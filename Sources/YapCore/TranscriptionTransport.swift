import Foundation

public protocol TranscriptionSocket: Sendable {
    /// Send a JSON control/data frame as TEXT (ElevenLabs chunks, Deepgram control msgs).
    func send(_ data: Data) async throws
    /// Send raw bytes as a BINARY frame (Deepgram audio). Explicit so silent PCM — which
    /// is valid UTF-8 (null bytes) — is never misframed as text.
    func sendBinary(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public extension TranscriptionSocket {
    // Default keeps existing conformers (e.g. test fakes that only need text) source-compatible.
    func sendBinary(_ data: Data) async throws { try await send(data) }
}

public protocol TranscriptionClient: Sendable {
    func sendChunk(_ pcm16: Data) async throws
    func sendCommit() async throws
    func events() -> AsyncStream<TranscriptEvent>
    /// Close the transport at the end of a session. Called on every teardown so no
    /// socket/connection is left to be reclaimed implicitly by deallocation.
    func close() async
    /// Attach context to the NEXT chunk only (used after a reconnect so the model
    /// resumes coherently across the gap). Implementations send it once, then clear it.
    func primePreviousText(_ text: String)
}
