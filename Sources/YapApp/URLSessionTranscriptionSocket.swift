import Foundation
import YapCore

final class URLSessionTranscriptionSocket: NSObject, TranscriptionSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let provider: String
    private let startedAt = Date()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(request: URLRequest, provider: String) {
        self.provider = provider
        super.init()
        // Own the session with `self` as delegate so the WebSocket open/close lifecycle is
        // observable — the close CODE is the single most telling clue for a dropped stream.
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        self.task = session.webSocketTask(with: request)
        Diag.conn.info("\(self.provider, privacy: .public): connecting…")
        task.resume()
    }

    static func make(apiKey: String,
                     model: String = "scribe_v2_realtime",
                     sampleRate: Int = 16000,
                     keyterms: [String] = [],
                     noVerbatim: Bool = false) -> URLSessionTranscriptionSocket {
        var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [URLQueryItem(name: "model_id", value: model)]
        // VAD is the strategy ElevenLabs recommends for microphone streaming: the server
        // auto-commits transcript segments at natural silence boundaries, which the docs
        // say gives the best results. Param name + enum are from the official AsyncAPI
        // spec; we keep the documented VAD defaults (1.5 s silence / 0.4 threshold). Our
        // explicit commit on stop still flushes the tail if the user stops mid-phrase.
        items.append(URLQueryItem(name: "commit_strategy", value: "vad"))
        if noVerbatim { items.append(URLQueryItem(name: "no_verbatim", value: "true")) }
        for term in keyterms where !term.isEmpty {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return URLSessionTranscriptionSocket(request: req, provider: "ElevenLabs")
    }

    /// Deepgram live STT. Audio is sent as raw `linear16` binary frames (our PCM16 as-is);
    /// control (Finalize/CloseStream) goes as text. Nova-3 + punctuation + interim
    /// results, with endpointing so segments finalize on natural pauses.
    static func makeDeepgram(apiKey: String,
                             model: String = "nova-3",
                             sampleRate: Int = 16000,
                             keyterms: [String] = [],
                             language: String = "multi") -> URLSessionTranscriptionSocket {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        // Without `language`, Deepgram defaults to English and garbles other languages.
        // "multi" is Nova-3 code-switching (it/en/es/fr/de/… in one utterance); Deepgram
        // recommends a tighter 100 ms endpointing for it, vs 200 ms for a single language.
        let endpointing = language == "multi" ? "100" : "200"
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            // `punctuate`, NOT `smart_format`: smart_format also converts spoken numbers and
            // ordinals to digits (Italian "prima" → "1ª"), which is wrong for faithful
            // dictation. punctuate keeps punctuation + capitalization and leaves words as
            // spoken. (Number-to-digit conversion, if wanted, is the AI cleanup's job.)
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: endpointing),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
        ]
        // Nova-3 keyterm prompting reuses the same custom dictionary as ElevenLabs.
        for term in keyterms where !term.isEmpty {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return URLSessionTranscriptionSocket(request: req, provider: "Deepgram")
    }

    func send(_ data: Data) async throws {
        // JSON control/data goes as a text frame.
        if let json = String(data: data, encoding: .utf8) {
            try await task.send(.string(json))
        } else {
            try await task.send(.data(data))
        }
    }

    func sendBinary(_ data: Data) async throws {
        // Always a binary frame — never the UTF-8 heuristic above (silent PCM is valid
        // UTF-8 and would otherwise be misframed as a text/control message).
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        do {
            let message = try await task.receive()
            switch message {
            case .data(let d): return d
            case .string(let s): return Data(s.utf8)
            @unknown default: return Data()
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let mapped = Self.classify(receiveFailure: error, responseStatus: status)
            if mapped == .socketClosed {
                Diag.conn.info("\(self.provider, privacy: .public): receive ended (status \(status.map(String.init) ?? "none", privacy: .public)): \(Diag.describe(error), privacy: .public)")
            } else {
                Diag.conn.error("\(self.provider, privacy: .public): receive failed (status \(status.map(String.init) ?? "—", privacy: .public)) → \(String(describing: mapped), privacy: .public)")
            }
            throw mapped
        }
    }

    /// Maps a `receive()` failure to a transcription error.
    ///
    /// A successful WebSocket upgrade leaves the task's response as HTTP **101 Switching
    /// Protocols**. So a *non-101* status means the handshake itself was rejected (401 key,
    /// 400 params, 403 no model access, 404 endpoint) — a fatal error worth surfacing, since
    /// retrying it would fail identically. A **101** status (the handshake succeeded) with a
    /// receive failure means the stream dropped *after* a good handshake: a transient
    /// mid-dictation drop the controller recovers from by reconnecting, so report
    /// `.socketClosed`. With no HTTP response at all the connection never established — a
    /// Wi-Fi blip, DNS hiccup, or captive portal. That too must be `.socketClosed`
    /// (retryable): surfacing it as fatal made a mid-dictation outage discard the whole
    /// accumulated transcript on the FIRST reconnect attempt, bypassing the bounded
    /// reconnect/backoff loop entirely.
    static func classify(receiveFailure error: Error, responseStatus: Int?) -> TranscriptionError {
        if let status = responseStatus {
            if status == 101 { return .socketClosed }
            return .unknown("HTTP \(status)")
        }
        return .socketClosed
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        // Invalidate the session too: a URLSession is not reclaimed just because its
        // task ends, so without this each dictation would leave one behind. This
        // releases it deterministically — no accumulation across many sessions.
        session.finishTasksAndInvalidate()
    }

    // MARK: - URLSessionWebSocketDelegate (diagnostics only)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        Diag.conn.info("\(self.provider, privacy: .public): WebSocket opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let secs = Date().timeIntervalSince(startedAt)
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "—"
        // closeCode 1000=normal, 1001=going away, 1006=abnormal (no close frame / network
        // drop), 1011=server error, 4xxx=provider-specific (auth/quota/protocol).
        switch closeCode {
        case .normalClosure, .goingAway:
            Diag.conn.info("\(self.provider, privacy: .public): WebSocket closed code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public) after \(secs, format: .fixed(precision: 1))s")
        default:
            Diag.conn.error("\(self.provider, privacy: .public): WebSocket closed code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public) after \(secs, format: .fixed(precision: 1))s")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Diag.conn.error("\(self.provider, privacy: .public): transport error: \(Diag.describe(error), privacy: .public)")
    }
}
